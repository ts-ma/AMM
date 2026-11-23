// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {AMMMath} from "../src/libraries/AMMMath.sol";
import {MockDeficitERC20} from "./mocks/MockDeficitERC20.sol";
import {PoolStateFixture} from "./utils/PoolStateFixture.sol";
import {addParams} from "./utils/AddParams.sol";

/// @notice M10 item 2 (TEST_MATRIX R23): mixed state — one token in deficit (balance < reserve,
///         unsupported behaviour modelled by `slash`) while the other token has surplus
///         (balance > reserve, a direct transfer). Rules under test (U4, A2, Gate R=(b), M6-2,
///         M6-4; ARCHITECTURE §5.2–§5.4), with explicit `sync()` kept (student, 2026-11-23):
///         (a) while the deficit exists, add / remove / swap revert `ReserveDeficit` with full
///             rollback, also after a `skim()` (R08 covers the call-level revert; here the
///             sequence skim → still blocked → sync → resumes);
///         (b) `sync()` lowers only the deficit token's reserve, emits exactly one
///             `ReserveSynced`, and never absorbs the other token's surplus;
///         (c) after `sync()` every operation changes reserves only by its own measured
///             amounts, so the surplus stays exactly as donated, and redemptions pay
///             reserve-based amounts: the loss falls only on the deficit token, pro rata;
///         (d) `skim()` then sends exactly the surplus of the surplus token and nothing of the
///             other token.
///         Seed: reserves (1e6, 2e6) from `PoolStateFixture`; deficit 200,000 units, surplus
///         500,000 units; both orientations.
contract AMMPoolMixedDeficitSurplusTest is PoolStateFixture {
    uint256 internal constant DEF = 200_000;
    uint256 internal constant SUR = 500_000;

    function _tok(bool zero) internal view returns (MockDeficitERC20) {
        return zero ? t0 : t1;
    }

    function _surplusOf(bool zero) internal view returns (uint256) {
        (uint256 r0, uint256 r1) = _reserves();
        return zero ? t0.balanceOf(address(pool)) - r0 : t1.balanceOf(address(pool)) - r1;
    }

    function _assertBlocked() internal {
        bytes memory err = abi.encodeWithSelector(AMMPool.ReserveDeficit.selector);
        _expectRevertNoChange(
            alice, abi.encodeCall(AMMPool.addLiquidity, (addParams(1000, 2000, 0, alice, block.timestamp))), err
        );
        _expectRevertNoChange(alice, abi.encodeCall(AMMPool.removeLiquidity, (1000, 0, 0, carol, block.timestamp)), err);
        _expectRevertNoChange(
            bob, abi.encodeCall(AMMPool.swapExactInput, (address(t0), 10_000, 0, carol, block.timestamp)), err
        );
        _expectRevertNoChange(
            bob, abi.encodeCall(AMMPool.swapExactInput, (address(t1), 10_000, 0, carol, block.timestamp)), err
        );
    }

    /// @param deficitIn0 true: token0 in deficit, token1 with surplus; false: the mirror.
    function _run(bool deficitIn0) internal {
        MockDeficitERC20 tD = _tok(deficitIn0);
        MockDeficitERC20 tS = _tok(!deficitIn0);
        (uint256 r0, uint256 r1) = _reserves();
        uint256 rD = deficitIn0 ? r0 : r1;
        uint256 rS = deficitIn0 ? r1 : r0;
        _slashPool(tD, DEF);
        _donate(tS, SUR);

        // (a) blocked, and still blocked after a skim that sends the surplus away.
        _assertBlocked();
        pool.skim();
        assertEq(tS.balanceOf(surplus), SUR, "skim sent the surplus token's surplus");
        assertEq(tD.balanceOf(surplus), 0, "skim sent nothing of the deficit token");
        _assertBlocked();
        _donate(tS, SUR); // surplus again for the rest of the sequence

        // (b) sync lowers only the deficit reserve and emits exactly one event.
        vm.recordLogs();
        pool.sync();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "exactly one ReserveSynced");
        assertEq(logs[0].topics[0], AMMPool.ReserveSynced.selector);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), address(tD), "event for the deficit token");
        (uint256 prevR, uint256 newR) = abi.decode(logs[0].data, (uint256, uint256));
        assertEq(prevR, rD, "previousReserve");
        assertEq(newR, rD - DEF, "newReserve");
        (uint256 s0, uint256 s1) = _reserves();
        assertEq(deficitIn0 ? s0 : s1, rD - DEF, "deficit reserve lowered to the balance");
        assertEq(deficitIn0 ? s1 : s0, rS, "surplus token's reserve unchanged (no absorption)");
        assertEq(_surplusOf(!deficitIn0), SUR, "surplus unchanged by sync");
        assertEq(_surplusOf(deficitIn0), 0, "deficit token now balanced");

        // (c) operations resume; each changes reserves only by its own amounts.
        _swapChecked(address(t0));
        _swapChecked(address(t1));
        _addChecked();
        _removeAllAliceChecked();
        assertEq(_surplusOf(!deficitIn0), SUR, "surplus untouched by every operation");
        assertEq(_surplusOf(deficitIn0), 0, "no surplus created in the deficit token");

        // (d) skim sends exactly the surplus, nothing of the other token.
        uint256 recvS = tS.balanceOf(surplus);
        uint256 recvD = tD.balanceOf(surplus);
        (uint256 q0, uint256 q1) = _reserves();
        pool.skim();
        assertEq(tS.balanceOf(surplus) - recvS, SUR, "skim: exactly the surplus");
        assertEq(tD.balanceOf(surplus), recvD, "skim: nothing of the other token");
        (uint256 e0, uint256 e1) = _reserves();
        assertEq(e0, q0, "skim leaves reserve0");
        assertEq(e1, q1, "skim leaves reserve1");
        assertEq(_surplusOf(true), 0);
        assertEq(_surplusOf(false), 0);
    }

    function _swapChecked(address tokenIn) internal {
        (uint256 r0, uint256 r1) = _reserves();
        bool zf = tokenIn == address(t0);
        uint256 out = AMMMath.getAmountOut(10_000, zf ? r0 : r1, zf ? r1 : r0);
        vm.prank(bob);
        assertEq(pool.swapExactInput(tokenIn, 10_000, 0, carol, block.timestamp), out, "priced from reserves only");
        (uint256 e0, uint256 e1) = _reserves();
        assertEq(e0, zf ? r0 + 10_000 : r0 - out, "reserve0 by own amounts");
        assertEq(e1, zf ? r1 - out : r1 + 10_000, "reserve1 by own amounts");
    }

    function _addChecked() internal {
        (uint256 r0, uint256 r1) = _reserves();
        vm.prank(bob);
        (uint256 n0, uint256 n1,) = pool.addLiquidity(addParams(100_000, 1_000_000, 0, bob, block.timestamp));
        (uint256 e0, uint256 e1) = _reserves();
        assertEq(e0, r0 + n0, "reserve0 += own net");
        assertEq(e1, r1 + n1, "reserve1 += own net");
    }

    /// @dev Loss attribution: alice's redemption is reserve-based (surplus excluded).
    function _removeAllAliceChecked() internal {
        (uint256 r0, uint256 r1) = _reserves();
        uint256 sh = pool.balanceOf(alice);
        uint256 supply = pool.totalSupply();
        vm.prank(alice);
        (uint256 o0, uint256 o1) = pool.removeLiquidity(sh, 0, 0, carol, block.timestamp);
        assertEq(o0, Math.mulDiv(sh, r0, supply), "token0 paid from the reserve only");
        assertEq(o1, Math.mulDiv(sh, r1, supply), "token1 paid from the reserve only");
    }

    function test_R23_mixedDeficit0Surplus1() public {
        _run(true);
    }

    function test_R23_mixedDeficit1Surplus0() public {
        _run(false);
    }

    /// @dev Loss falls only on the deficit token, pro rata: after sync, the per-share reserve
    ///      of the deficit token drops by exactly the slashed amount over S; the other token's
    ///      per-share reserve is unchanged; the surplus is not in either.
    function test_R23_lossOnlyInDeficitTokenProRata() public {
        (uint256 r0, uint256 r1) = _reserves();
        uint256 supply = pool.totalSupply();
        uint256 sh = pool.balanceOf(alice);
        _slashPool(t0, DEF);
        _donate(t1, SUR);
        pool.sync();
        vm.prank(alice);
        (uint256 o0, uint256 o1) = pool.removeLiquidity(sh, 0, 0, carol, block.timestamp);
        assertEq(o0, Math.mulDiv(sh, r0 - DEF, supply), "token0 bears the loss pro rata");
        assertEq(o1, Math.mulDiv(sh, r1, supply), "token1 unaffected; surplus not paid out");
        assertEq(_surplusOf(false), SUR, "surplus still only skim-able");
    }
}
