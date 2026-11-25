// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AMMPool} from "../../src/AMMPool.sol";
import {IAMMPool} from "../../src/interfaces/IAMMPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockDeficitERC20} from "../mocks/MockDeficitERC20.sol";
import {MockFailingERC20} from "../mocks/MockFailingERC20.sol";
import {addParams} from "../utils/AddParams.sol";
import {SnapshotReuseBase} from "./SnapshotReuseBase.sol";

/// EXPERIMENT (TEST_MATRIX §14.9, experiment 1). Observable outcome of a later deposit; the same
/// assertions must hold on the baseline and on the variant commit. Expected values: integer model
/// of the approved formulas (report §5.2; TEST_MATRIX §14.8), not the Solidity code.
contract SnapshotReuseBehaviour is SnapshotReuseBase {
    struct Snap {
        uint256 payer0;
        uint256 payer1;
        uint256 pool0;
        uint256 pool1;
        uint256 res0;
        uint256 res1;
        uint256 supply;
        uint256 lp;
    }

    function _snap(AMMPool pool, address payer) internal view returns (Snap memory s) {
        IERC20 t0 = IERC20(pool.token0());
        IERC20 t1 = IERC20(pool.token1());
        s.payer0 = t0.balanceOf(payer);
        s.payer1 = t1.balanceOf(payer);
        s.pool0 = t0.balanceOf(address(pool));
        s.pool1 = t1.balanceOf(address(pool));
        (s.res0, s.res1) = pool.getReserves();
        s.supply = pool.totalSupply();
        s.lp = pool.balanceOf(payer);
    }

    function _assertSame(Snap memory a, Snap memory b) internal pure {
        assertEq(a.payer0, b.payer0, "payer0");
        assertEq(a.payer1, b.payer1, "payer1");
        assertEq(a.pool0, b.pool0, "pool0");
        assertEq(a.pool1, b.pool1, "pool1");
        assertEq(a.res0, b.res0, "res0");
        assertEq(a.res1, b.res1, "res1");
        assertEq(a.supply, b.supply, "supply");
        assertEq(a.lp, b.lp, "lp");
    }

    /// @dev Successful deposit at the exact bounds: debits, receipts, shares, reserves, event.
    function _expectSuccess(
        AMMPool pool,
        IAMMPool.AddLiquidityParams memory p,
        address payer,
        uint256[2] memory debit,
        uint256[2] memory net,
        uint256 shares
    ) internal {
        Snap memory s = _snap(pool, payer);
        vm.expectEmit(true, true, false, true, address(pool));
        emit AMMPool.LiquidityAdded(payer, payer, net[0], net[1], shares);
        vm.prank(payer);
        (uint256 n0, uint256 n1, uint256 sh) = pool.addLiquidity(p);
        Snap memory e = _snap(pool, payer);
        assertEq(n0, net[0], "net0");
        assertEq(n1, net[1], "net1");
        assertEq(sh, shares, "shares");
        assertEq(s.payer0 - e.payer0, debit[0], "debit0");
        assertEq(s.payer1 - e.payer1, debit[1], "debit1");
        assertEq(e.pool0 - s.pool0, net[0], "pool receipt0");
        assertEq(e.pool1 - s.pool1, net[1], "pool receipt1");
        assertEq(e.res0, s.res0 + net[0], "reserve0 += net0");
        assertEq(e.res1, s.res1 + net[1], "reserve1 += net1");
        assertEq(e.supply, s.supply + shares, "supply");
        assertEq(e.lp, s.lp + shares, "recipient LP");
    }

    function _expectRevert(AMMPool pool, IAMMPool.AddLiquidityParams memory p, address payer, bytes4 err) internal {
        Snap memory s = _snap(pool, payer);
        vm.expectRevert(err);
        vm.prank(payer);
        pool.addLiquidity(p);
        _assertSame(s, _snap(pool, payer));
    }

    // Note: every tightened copy is rebuilt from the scenario function; memory structs alias.

    // ---------------- ORD ----------------

    function _ord(bool token1First) internal {
        IAMMPool.AddLiquidityParams memory p = _ordParams(token1First);
        IAMMPool.AddLiquidityParams memory q = _ordParams(token1First);
        q.maxDebit0 = 1e18 - 1;
        _expectRevert(ord, q, alice, AMMPool.PayerDebitTooHigh.selector);
        q = _ordParams(token1First);
        q.maxDebit1 = 2e18 - 1;
        _expectRevert(ord, q, alice, AMMPool.PayerDebitTooHigh.selector);
        _expectSuccess(ord, p, alice, [uint256(1e18), 2e18], [uint256(1e18), 2e18], 1_414_213_562_373_095_048);
        (uint256 r0, uint256 r1) = ord.getReserves();
        assertEq(r0, 1001e18);
        assertEq(r1, 2002e18);
    }

    function test_ord_token0First_exactBoundsAndTight() public {
        _ord(false);
    }

    function test_ord_token1First_exactBoundsAndTight() public {
        _ord(true);
    }

    // ---------------- L46 (report §5.2) ----------------

    function test_l46_taxedSecond_exactBoundsAndTight() public {
        IAMMPool.AddLiquidityParams memory p = _l46Params(false);
        IAMMPool.AddLiquidityParams memory q = _l46Params(false);
        q.maxDebit0 = 999;
        _expectRevert(l46, q, bob, AMMPool.PayerDebitTooHigh.selector);
        q = _l46Params(false);
        q.maxDebit1 = 1_999;
        _expectRevert(l46, q, bob, AMMPool.PayerDebitTooHigh.selector);
        q = _l46Params(false);
        q.maxExcess0 = 99;
        _expectRevert(l46, q, bob, AMMPool.ExcessContributionTooHigh.selector);
        q = _l46Params(false);
        q.maxExcess1 = 0;
        _expectRevert(l46, q, bob, AMMPool.ExcessContributionTooHigh.selector);
        q = _l46Params(false);
        q.minShares = 1_273;
        _expectRevert(l46, q, bob, AMMPool.InsufficientShares.selector);
        uint256 burned = f1.totalSupply();
        _expectSuccess(l46, p, bob, [uint256(1_000), 2_000], [uint256(1_000), 1_800], 1_272);
        assertEq(burned - f1.totalSupply(), 200, "tax burned");
        (uint256 r0, uint256 r1) = l46.getReserves();
        assertEq(r0, 11_000);
        assertEq(r1, 21_800);
    }

    function test_l46_taxedFirst_exactBoundsAndTight() public {
        IAMMPool.AddLiquidityParams memory p = _l46Params(true);
        IAMMPool.AddLiquidityParams memory q = _l46Params(true);
        q.maxDebit0 = 899;
        _expectRevert(l46, q, bob, AMMPool.PayerDebitTooHigh.selector);
        q = _l46Params(true);
        q.maxDebit1 = 1_999;
        _expectRevert(l46, q, bob, AMMPool.PayerDebitTooHigh.selector);
        q = _l46Params(true);
        q.maxExcess1 = 0;
        _expectRevert(l46, q, bob, AMMPool.ExcessContributionTooHigh.selector);
        q = _l46Params(true);
        q.minShares = 1_273;
        _expectRevert(l46, q, bob, AMMPool.InsufficientShares.selector);
        // maxExcess0 = 0 is already the tightest value: u0 = 900 − ⌈1,272·10,000/14,142⌉ = 0.
        uint256 burned = f1.totalSupply();
        _expectSuccess(l46, p, bob, [uint256(900), 2_000], [uint256(900), 1_800], 1_272);
        assertEq(burned - f1.totalSupply(), 200, "tax burned");
        (uint256 r0, uint256 r1) = l46.getReserves();
        assertEq(r0, 10_900);
        assertEq(r1, 21_800);
    }

    // ---------------- Deficit and error order (production order: token0 read+check, then token1) ----------------

    address internal constant LOW = address(0xA000);
    address internal constant HIGH = address(0xB000);

    /// @dev Pool over (LOW, HIGH); `deficitLow` selects which side is the `MockDeficitERC20` (put in
    ///      deficit by 1 unit) and the other side is `MockFailingERC20` with `RevertBalanceOf` set.
    function _deficitPool(bool deficitLow) internal returns (AMMPool pool) {
        string memory def = "MockDeficitERC20.sol:MockDeficitERC20";
        string memory fail = "MockFailingERC20.sol:MockFailingERC20";
        bytes memory args = abi.encode("X", "X", uint8(18));
        deployCodeTo(deficitLow ? def : fail, args, LOW);
        deployCodeTo(deficitLow ? fail : def, args, HIGH);
        pool = new AMMPool(LOW, HIGH, surplus);
        MockERC20(LOW).mint(alice, 1e30);
        MockERC20(HIGH).mint(alice, 1e30);
        vm.startPrank(alice);
        IERC20(LOW).approve(address(pool), MAX);
        IERC20(HIGH).approve(address(pool), MAX);
        pool.addLiquidity(addParams(1000e18, 2000e18, 0, alice, block.timestamp));
        vm.stopPrank();
        MockDeficitERC20(deficitLow ? LOW : HIGH).slash(address(pool), 1);
        MockFailingERC20(deficitLow ? HIGH : LOW).setMode(MockFailingERC20.Mode.RevertBalanceOf);
    }

    function _deficitCase(bool deficitLow, bool token1First, bytes4 err) internal {
        AMMPool pool = _deficitPool(deficitLow);
        (uint256 r0, uint256 r1) = pool.getReserves();
        uint256 s = pool.totalSupply();
        vm.expectRevert(err);
        vm.prank(alice);
        pool.addLiquidity(
            IAMMPool.AddLiquidityParams(1e18, 2e18, MAX, MAX, MAX, MAX, 0, alice, block.timestamp, token1First)
        );
        (uint256 e0, uint256 e1) = pool.getReserves();
        assertEq(e0, r0);
        assertEq(e1, r1);
        assertEq(pool.totalSupply(), s);
    }

    /// token0 in deficit, token1's balanceOf reverts: the token0 check fires before token1 is read.
    function test_deficit_token0Deficit_token1BalanceReverts_token0First() public {
        _deficitCase(true, false, AMMPool.ReserveDeficit.selector);
    }

    function test_deficit_token0Deficit_token1BalanceReverts_token1First() public {
        _deficitCase(true, true, AMMPool.ReserveDeficit.selector);
    }

    /// token0's balanceOf reverts, token1 in deficit: the token0 read comes first, so its revert wins.
    function test_deficit_token0BalanceReverts_token1Deficit_token0First() public {
        _deficitCase(false, false, MockFailingERC20.MockFailure.selector);
    }

    function test_deficit_token0BalanceReverts_token1Deficit_token1First() public {
        _deficitCase(false, true, MockFailingERC20.MockFailure.selector);
    }
}
