// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeERC20} from "./mocks/MockFeeERC20.sol";
import {MockFailingERC20} from "./mocks/MockFailingERC20.sol";
import {MockDeficitERC20} from "./mocks/MockDeficitERC20.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";
import {addParams} from "./utils/AddParams.sol";

/// @notice M8 commit 5f (tests only; M8 remains WIP). LIMITATION TESTS: they record behaviour
///         OUTSIDE the supported token model or outside BI-2′'s scope, so that the documented
///         limits (THREAT_MODEL T27, T30, §7.4–§7.6) are executed facts. Nothing here is
///         "supported": a passing test means "the limitation is exactly as documented".
///         TEST_MATRIX B10 (BI-2′ not extended to swap/remove), X06 (trapped liquidity,
///         modes A/B/C, drain), X07 (tax changes after deposit).
contract AMMPoolM8LimitationsTest is Test {
    uint256 internal constant MAX = type(uint256).max;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal surplusRecipient = makeAddr("surplusRecipient");

    AMMPool internal p;
    uint160 internal nextLow = 0x90000;
    uint160 internal nextHigh = type(uint160).max - 0x7000;

    bytes internal mockFailure = abi.encodeWithSelector(MockFailingERC20.MockFailure.selector);

    function _deploy(string memory artifact, bool low) internal returns (address at) {
        at = low ? address(nextLow++) : address(nextHigh--);
        require(at.code.length == 0, "address reused");
        deployCodeTo(artifact, abi.encode("T", "T", uint8(18)), at);
    }

    function _pool(address x, address y, uint256 ix, uint256 iy) internal {
        (address lo, address hi) = x < y ? (x, y) : (y, x);
        p = new AMMPool(lo, hi, surplusRecipient);
        address[3] memory users = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            MockERC20(lo).mint(users[i], 1e30);
            MockERC20(hi).mint(users[i], 1e30);
            vm.startPrank(users[i]);
            MockERC20(lo).approve(address(p), MAX);
            MockERC20(hi).approve(address(p), MAX);
            vm.stopPrank();
        }
        (uint256 a0, uint256 a1) = x < y ? (ix, iy) : (iy, ix);
        vm.prank(alice);
        p.addLiquidity(addParams(a0, a1, 0, alice, block.timestamp));
    }

    function _call(address from, bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.prank(from);
        (ok, ret) = address(p).call(data);
    }

    // ------------------------------------------------------------------
    // X06 — trapped liquidity (token X refuses Pool transfers)
    // ------------------------------------------------------------------

    MockFailingERC20 internal x;
    MockERC20 internal y;

    function _x06Setup() internal {
        x = MockFailingERC20(_deploy("MockFailingERC20.sol:MockFailingERC20", true));
        y = MockERC20(_deploy("MockERC20.sol:MockERC20", false));
        _pool(address(x), address(y), 1_000_000, 1_000_000);
    }

    function _removeAll() internal view returns (bytes memory) {
        return abi.encodeCall(AMMPool.removeLiquidity, (p.balanceOf(alice), 0, 0, alice, block.timestamp));
    }

    /// @dev Mode A: X can still be pulled IN, but the Pool's outbound X transfer reverts.
    ///      Remove fails; Y → X fails; X → Y swaps and NEW DEPOSITS still succeed (a new LP joins a
    ///      pool it cannot leave); ten 100,000-X swaps drain Y from 1,000,000 to 501,008 (the
    ///      model value); restoring X makes exit work again.
    function test_X06_limitation_modeA_outboundRefused_drainAndNewDeposits() public {
        _x06Setup();
        x.setMode(MockFailingERC20.Mode.RevertTransfer);

        (bool ok, bytes memory ret) = _call(alice, _removeAll());
        assertFalse(ok, "remove fails");
        assertEq(ret, mockFailure);
        (ok,) = _call(bob, abi.encodeCall(AMMPool.swapExactInput, (address(y), 1000, 0, bob, block.timestamp)));
        assertFalse(ok, "Y -> X fails (X outbound)");

        (ok,) = _call(bob, abi.encodeCall(AMMPool.addLiquidity, (addParams(1000, MAX, 0, bob, block.timestamp))));
        assertTrue(ok, "a new deposit still succeeds in mode A");
        (ok,) = _call(bob, abi.encodeCall(AMMPool.removeLiquidity, (p.balanceOf(bob), 0, 0, bob, block.timestamp)));
        assertFalse(ok, "and the new LP cannot exit either");

        // undo bob's deposit effect on the numbers: compare with a fresh pool for the drain model
        _x06Setup();
        x.setMode(MockFailingERC20.Mode.RevertTransfer);
        for (uint256 i; i < 10; ++i) {
            vm.prank(carol);
            p.swapExactInput(address(x), 100_000, 0, carol, block.timestamp);
        }
        (uint256 r0, uint256 r1) = p.getReserves();
        assertEq(r0, 2_000_000, "X reserve (untransferable)");
        assertEq(r1, 501_008, "Y drained as in the model");
        uint256 lp = p.balanceOf(alice);
        uint256 S = p.totalSupply();
        emit log_named_uint("alice redeemable Y after drain", lp * r1 / S);
        emit log_named_uint("alice nominal X (cannot be withdrawn)", lp * r0 / S);

        x.setMode(MockFailingERC20.Mode.None);
        (ok,) = _call(alice, _removeAll());
        assertTrue(ok, "restoring X makes exit work again");
    }

    /// @dev Mode B: every X transfer reverts. Remove, both swap directions and deposits fail.
    function test_X06_limitation_modeB_allTransfersRevert() public {
        _x06Setup();
        x.setMode(MockFailingERC20.Mode.RevertAllTransfers);
        (bool ok,) = _call(alice, _removeAll());
        assertFalse(ok, "remove fails");
        (ok,) = _call(bob, abi.encodeCall(AMMPool.swapExactInput, (address(x), 1000, 0, bob, block.timestamp)));
        assertFalse(ok, "X -> Y fails");
        (ok,) = _call(bob, abi.encodeCall(AMMPool.swapExactInput, (address(y), 1000, 0, bob, block.timestamp)));
        assertFalse(ok, "Y -> X fails");
        (ok,) = _call(bob, abi.encodeCall(AMMPool.addLiquidity, (addParams(1000, MAX, 0, bob, block.timestamp))));
        assertFalse(ok, "deposits fail");
        x.setMode(MockFailingERC20.Mode.None);
        (ok,) = _call(alice, _removeAll());
        assertTrue(ok);
    }

    /// @dev Mode C: X's balanceOf reverts. Every Pool operation that reads balances fails,
    ///      including sync and skim; nothing changes.
    function test_X06_limitation_modeC_balanceOfReverts() public {
        _x06Setup();
        x.setMode(MockFailingERC20.Mode.RevertBalanceOf);
        bytes[6] memory calls = [
            _removeAll(),
            abi.encodeCall(AMMPool.swapExactInput, (address(x), 1000, 0, bob, block.timestamp)),
            abi.encodeCall(AMMPool.swapExactInput, (address(y), 1000, 0, bob, block.timestamp)),
            abi.encodeCall(AMMPool.addLiquidity, (addParams(1000, MAX, 0, bob, block.timestamp))),
            abi.encodeCall(AMMPool.sync, ()),
            abi.encodeCall(AMMPool.skim, ())
        ];
        for (uint256 i; i < 6; ++i) {
            (bool ok, bytes memory ret) = _call(i == 0 ? alice : bob, calls[i]);
            assertFalse(ok, "every balance-reading operation fails");
            assertEq(ret, mockFailure);
        }
        x.setMode(MockFailingERC20.Mode.None);
        (bool ok2,) = _call(alice, _removeAll());
        assertTrue(ok2);
    }

    // ------------------------------------------------------------------
    // X07 — tax changes after the deposit
    // ------------------------------------------------------------------

    /// @dev An INCLUSIVE outbound tax switched on after the deposit never triggers A8 (the Pool's
    ///      balance falls by exactly the amount sent); the recipient receives less and MIN-NET
    ///      decides. An EXCLUSIVE outbound extra switched on after the deposit triggers A8
    ///      (OutboundTransferMismatch): the LPs are trapped while it lasts (limitation).
    function test_X07_limitation_taxChangesAfterDeposit() public {
        MockFeeERC20 f = MockFeeERC20(_deploy("MockFeeERC20.sol:MockFeeERC20", true));
        MockERC20 m = MockERC20(_deploy("MockERC20.sol:MockERC20", false));
        _pool(address(f), address(m), 1e21, 1e21);
        uint256 lp = p.balanceOf(alice);
        uint256 S = p.totalSupply();
        (uint256 r0,) = p.getReserves();
        uint256 amount0 = (lp / 2) * r0 / S;

        f.setTax(MockFeeERC20.Path.Transfer, 1000); // inclusive 10% on the Pool's outbound transfer
        (bool ok, bytes memory ret) =
            _call(alice, abi.encodeCall(AMMPool.removeLiquidity, (lp / 2, amount0, 0, alice, block.timestamp)));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(AMMPool.InsufficientNetReceived.selector), "MIN-NET decides, not A8");
        uint256 before = f.balanceOf(alice);
        vm.prank(alice);
        (uint256 net0,) = p.removeLiquidity(lp / 2, 0, 0, alice, block.timestamp);
        assertEq(f.balanceOf(alice) - before, net0);
        assertEq(net0, amount0 - amount0 / 10, "recipient receives 90%");

        f.setTax(MockFeeERC20.Path.Transfer, 0);
        f.setExtra(MockFeeERC20.Path.Transfer, 1000); // exclusive extra on the Pool's outbound transfer
        // Small withdrawal: the Pool can cover amount + 10%, the token succeeds, A8 refuses.
        (ok, ret) = _call(alice, abi.encodeCall(AMMPool.removeLiquidity, (1e18, 0, 0, alice, block.timestamp)));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(AMMPool.OutboundTransferMismatch.selector), "A8 refuses: LPs trapped");
        // Full withdrawal: amount + 10% exceeds the Pool's balance, so the token itself reverts
        // (ERC20InsufficientBalance) before A8 is reached. Trapped either way.
        (ok, ret) =
            _call(alice, abi.encodeCall(AMMPool.removeLiquidity, (p.balanceOf(alice), 0, 0, alice, block.timestamp)));
        assertFalse(ok);
        assertEq(
            bytes4(ret), bytes4(keccak256("ERC20InsufficientBalance(address,uint256,uint256)")), "token-level revert"
        );
    }

    // ------------------------------------------------------------------
    // B10 — BI-2′ is not extended to swap / remove (THREAT_MODEL T30)
    // ------------------------------------------------------------------

    /// @dev A hook token's callback removes 300 units of the Pool's OTHER token, masked by a
    ///      surplus of 1,000, during (a) a swap's inbound transfer and (b) a withdrawal's outbound
    ///      transfer. Both calls SUCCEED and the surplus falls by 300: the residual risk T30,
    ///      recorded as executed fact. (The same pattern in addLiquidity reverts: B09c.)
    function test_B10_limitation_swapAndRemove_maskedForeignLossSucceeds() public {
        ReentrantERC20 h = ReentrantERC20(_deploy("ReentrantERC20.sol:ReentrantERC20", true));
        MockDeficitERC20 d = MockDeficitERC20(_deploy("MockDeficitERC20.sol:MockDeficitERC20", false));
        _pool(address(h), address(d), 1e21, 1e21);
        d.mint(address(p), 1000);

        // (a) swap h -> d; the hook runs in h.transferFrom (inbound)
        h.armWith(
            address(d),
            abi.encodeCall(MockDeficitERC20.slash, (address(p), 300)),
            ReentrantERC20.Hook.TransferFrom,
            false
        );
        vm.prank(bob);
        p.swapExactInput(address(h), 1e18, 0, bob, block.timestamp);
        (, uint256 r1) = p.getReserves();
        assertEq(d.balanceOf(address(p)) - r1, 700, "swap succeeded; surplus fell by 300");

        // (b) remove; the hook runs in h.transfer (outbound)
        h.armWith(
            address(d), abi.encodeCall(MockDeficitERC20.slash, (address(p), 300)), ReentrantERC20.Hook.Transfer, false
        );
        vm.prank(alice);
        p.removeLiquidity(1e18, 0, 0, alice, block.timestamp);
        (, r1) = p.getReserves();
        assertEq(d.balanceOf(address(p)) - r1, 400, "remove succeeded; surplus fell by another 300");
    }
}
