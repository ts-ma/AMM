// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {AMMMath} from "../src/libraries/AMMMath.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";
import {PoolStateFixture} from "./utils/PoolStateFixture.sol";

/// @notice M6 reentrancy and snapshot-integrity suite (THREAT_MODEL T1; DECISIONS M5-6, M6-3,
///         M6-5). TEST_MATRIX X01 (M6 extension) and B08.
///         Both Pool tokens are hook tokens (`ReentrantERC20`, h0 < h1). The token contracts
///         themselves act as attackers: each holds both tokens, approvals and LP, so every
///         re-entrant call would succeed if the guard were missing. Three cases (M5-6):
///         (i)   bubbling — the outer call reverts with the guard error and nothing changes;
///         (ii)  caught + correct transfer — the outer call succeeds and its end state is
///               IDENTICAL to a run without any re-entry attempt;
///         (iii) caught + faulty transfer — the outer call is rejected by A8.
contract AMMPoolSyncSkimReentrancyTest is PoolStateFixture {
    ReentrantERC20 internal h0;
    ReentrantERC20 internal h1;

    bytes internal reentrantErr =
        abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);

    function setUp() public override {
        super.setUp(); // actors and constants; the default Pool is replaced below
        ReentrantERC20 a = new ReentrantERC20("Hook A", "HKA", 18);
        ReentrantERC20 b = new ReentrantERC20("Hook B", "HKB", 18);
        (h0, h1) = address(a) < address(b) ? (a, b) : (b, a);
        pool = new AMMPool(address(h0), address(h1), surplus);

        address[4] memory users = [alice, bob, address(h0), address(h1)];
        for (uint256 i; i < users.length; ++i) {
            h0.mint(users[i], FUND);
            h1.mint(users[i], FUND);
            vm.startPrank(users[i]);
            h0.approve(address(pool), MAX);
            h1.approve(address(pool), MAX);
            vm.stopPrank();
        }
        vm.prank(alice);
        pool.addLiquidity(1e21, 2e21, 0, 0, 0, alice, block.timestamp);
        vm.prank(address(h0));
        pool.addLiquidity(1e20, 2e20, 0, 0, 0, address(h0), block.timestamp);
        vm.prank(address(h1));
        pool.addLiquidity(1e20, 2e20, 0, 0, 0, address(h1), block.timestamp);
    }

    // ------------------------------------------------------------------
    // Payloads and outer calls
    // ------------------------------------------------------------------

    /// @dev Re-entrant calls attempted from a callback: sync, skim, add, remove, swap.
    function _payloads(address attacker) internal view returns (bytes[5] memory p) {
        p[0] = abi.encodeCall(AMMPool.sync, ());
        p[1] = abi.encodeCall(AMMPool.skim, ());
        p[2] = abi.encodeCall(AMMPool.addLiquidity, (1e18, 2e18, 0, 0, 0, attacker, block.timestamp));
        p[3] = abi.encodeCall(AMMPool.removeLiquidity, (1e15, 0, 0, attacker, block.timestamp));
        p[4] = abi.encodeCall(AMMPool.swapExactInput, (address(h0), 1e15, 0, attacker, block.timestamp));
    }

    enum Outer {
        Skim,
        Add,
        Remove,
        SwapIn0,
        SwapIn1
    }

    function _outerCall(Outer o) internal view returns (address caller, bytes memory data) {
        if (o == Outer.Skim) return (address(this), abi.encodeCall(AMMPool.skim, ()));
        if (o == Outer.Add) {
            return (alice, abi.encodeCall(AMMPool.addLiquidity, (1e18, 1e19, 0, 0, 0, alice, block.timestamp)));
        }
        if (o == Outer.Remove) {
            return (alice, abi.encodeCall(AMMPool.removeLiquidity, (1e18, 0, 0, carol, block.timestamp)));
        }
        if (o == Outer.SwapIn0) {
            return (bob, abi.encodeCall(AMMPool.swapExactInput, (address(h0), 1e18, 0, carol, block.timestamp)));
        }
        return (bob, abi.encodeCall(AMMPool.swapExactInput, (address(h1), 1e18, 0, carol, block.timestamp)));
    }

    /// @dev Which token and hook point fire first inside the outer call.
    function _hookOf(Outer o) internal view returns (ReentrantERC20 t, ReentrantERC20.Hook h) {
        if (o == Outer.Skim) return (h0, ReentrantERC20.Hook.Transfer); // h0 has surplus
        if (o == Outer.Add) return (h0, ReentrantERC20.Hook.TransferFrom);
        if (o == Outer.Remove) return (h0, ReentrantERC20.Hook.Transfer);
        if (o == Outer.SwapIn0) return (h0, ReentrantERC20.Hook.TransferFrom);
        return (h1, ReentrantERC20.Hook.TransferFrom);
    }

    function _call(address caller, bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.prank(caller);
        (ok, ret) = address(pool).call(data);
    }

    /// @dev Pre-existing surplus in both tokens, so a re-entrant skim would have a visible
    ///      effect, and `skim()` as the outer call has something to send.
    function _surplus() internal {
        h0.mint(address(pool), 12_345);
        h1.mint(address(pool), 67_890);
    }

    // ------------------------------------------------------------------
    // X01 (M6): bubbling
    // ------------------------------------------------------------------

    function _runBubbling(Outer o, bytes memory payload) internal {
        _surplus();
        (ReentrantERC20 t, ReentrantERC20.Hook h) = _hookOf(o);
        t.armWith(address(pool), payload, h, false);
        (address caller, bytes memory data) = _outerCall(o);
        // The guard error itself proves the callback ran and hit the guard; the token's own
        // `callbackRan` flag is rolled back together with the outer call.
        _expectRevertNoChange(caller, data, reentrantErr);
    }

    /// skim() outbound callback re-entering sync, skim, add, remove, swap: bubbling.
    function test_X01_M6_skimCallback_bubbling() public {
        bytes[5] memory p = _payloads(address(h0));
        for (uint256 i; i < p.length; ++i) {
            uint256 id = vm.snapshotState();
            _runBubbling(Outer.Skim, p[i]);
            vm.revertToState(id);
        }
    }

    /// add, remove and swap (both directions) callbacks re-entering sync / skim: bubbling.
    function test_X01_M6_operationCallbacksIntoSyncSkim_bubbling() public {
        Outer[4] memory outers = [Outer.Add, Outer.Remove, Outer.SwapIn0, Outer.SwapIn1];
        for (uint256 j; j < outers.length; ++j) {
            (ReentrantERC20 t,) = _hookOf(outers[j]);
            bytes[5] memory p = _payloads(address(t));
            for (uint256 i; i < 2; ++i) {
                uint256 id = vm.snapshotState();
                _runBubbling(outers[j], p[i]);
                vm.revertToState(id);
            }
        }
    }

    // ------------------------------------------------------------------
    // X01 (M6): caught + correct transfer
    // ------------------------------------------------------------------

    function _runCaughtCorrect(Outer o, bytes memory payload) internal {
        _surplus();
        (address caller, bytes memory data) = _outerCall(o);
        (ReentrantERC20 t, ReentrantERC20.Hook h) = _hookOf(o);

        // Reference: the same call without any re-entry attempt.
        uint256 id = vm.snapshotState();
        (bool okRef, bytes memory retRef) = _call(caller, data);
        assertTrue(okRef, "reference call succeeds");
        Snap memory clean = _snap();
        vm.revertToState(id);

        t.armWith(address(pool), payload, h, true);
        (bool ok, bytes memory ret) = _call(caller, data);
        assertTrue(ok, "outer call succeeds");
        assertEq(ret, retRef, "same return values");
        assertTrue(t.callbackRan(), "callback ran");
        assertFalse(t.lastCallOk(), "re-entry rejected");
        assertEq(t.lastReturnData(), reentrantErr, "exact guard error");
        _assertSame(clean, _snap());
    }

    function test_X01_M6_skimCallback_caughtCorrect() public {
        bytes[5] memory p = _payloads(address(h0));
        for (uint256 i; i < p.length; ++i) {
            uint256 id = vm.snapshotState();
            _runCaughtCorrect(Outer.Skim, p[i]);
            vm.revertToState(id);
        }
    }

    function test_X01_M6_operationCallbacksIntoSyncSkim_caughtCorrect() public {
        Outer[4] memory outers = [Outer.Add, Outer.Remove, Outer.SwapIn0, Outer.SwapIn1];
        for (uint256 j; j < outers.length; ++j) {
            (ReentrantERC20 t,) = _hookOf(outers[j]);
            bytes[5] memory p = _payloads(address(t));
            for (uint256 i; i < 2; ++i) {
                uint256 id = vm.snapshotState();
                _runCaughtCorrect(outers[j], p[i]);
                vm.revertToState(id);
            }
        }
    }

    // ------------------------------------------------------------------
    // X01 (M6): caught + faulty transfer
    // ------------------------------------------------------------------

    /// The re-entry is swallowed, but the token over-debits the Pool: A8 rejects the skim.
    function test_X01_M6_skimCallback_caughtFaulty_overDebitRejectedByA8() public {
        bytes[5] memory p = _payloads(address(h0));
        for (uint256 i; i < p.length; ++i) {
            uint256 id = vm.snapshotState();
            _surplus();
            h0.armWith(address(pool), p[i], ReentrantERC20.Hook.Transfer, true);
            h0.setFaults(1, 0);
            _expectRevertNoChange(
                address(this),
                abi.encodeCall(AMMPool.skim, ()),
                abi.encodeWithSelector(AMMPool.OutboundTransferMismatch.selector)
            );
            vm.revertToState(id);
        }
    }

    /// Documented limit (THREAT_MODEL T16, DECISIONS M6-4): skim has no MIN-NET, so a short
    /// delivery to surplusRecipient is NOT rejected; the Pool side is still exact (A8).
    function test_X01_M6_skimCallback_caughtShortDeliveryNotChecked() public {
        _surplus();
        h0.armWith(address(pool), abi.encodeCall(AMMPool.skim, ()), ReentrantERC20.Hook.Transfer, true);
        h0.setFaults(0, 5);
        (uint256 r0, uint256 r1) = pool.getReserves();
        pool.skim();
        assertEq(h0.balanceOf(surplus), 12_345 - 5, "recipient short by the withheld amount");
        assertEq(h0.balanceOf(address(pool)), r0, "Pool side exact");
        assertEq(h1.balanceOf(surplus), 67_890);
        (uint256 a0, uint256 a1) = pool.getReserves();
        assertEq(a0, r0);
        assertEq(a1, r1);
    }

    // ------------------------------------------------------------------
    // B08: the first token's transfer donates the OTHER token directly to the Pool
    // ------------------------------------------------------------------

    uint256 internal constant GIFT = 31_337;

    /// @dev Arms `first` so that, at `h`, it transfers GIFT of `other` straight to the Pool.
    function _armDonation(ReentrantERC20 first, ReentrantERC20 other, ReentrantERC20.Hook h) internal {
        first.armWith(address(other), abi.encodeCall(other.transfer, (address(pool), GIFT)), h, false);
    }

    function _surplusOf(ReentrantERC20 t, uint256 reserve) internal view returns (uint256) {
        return t.balanceOf(address(pool)) - reserve;
    }

    /// add: token0's transferFrom donates token1; net1 is still the target, the gift stays surplus.
    function test_B08_addDonationDuringFirstPull() public {
        (uint256 r0, uint256 r1) = pool.getReserves();
        uint256 supply = pool.totalSupply();
        uint256 t1 = Math.mulDiv(1e18, r1, r0); // token0 cap binds: (1e18, 2e18)
        _armDonation(h0, h1, ReentrantERC20.Hook.TransferFrom);
        vm.prank(alice);
        (uint256 n0, uint256 n1, uint256 shares) = pool.addLiquidity(1e18, 1e19, 0, 0, 0, alice, block.timestamp);
        assertTrue(h0.callbackRan());
        assertEq(n0, 1e18);
        assertEq(n1, t1, "donation not counted as input");
        assertEq(shares, Math.min(Math.mulDiv(n0, supply, r0), Math.mulDiv(n1, supply, r1)));
        (uint256 a0, uint256 a1) = pool.getReserves();
        assertEq(a0, r0 + n0);
        assertEq(a1, r1 + n1);
        assertEq(_surplusOf(h1, a1), GIFT, "gift stays surplus (BI-2)");
        assertEq(_surplusOf(h0, a0), 0);
    }

    /// swap token0 in: token0's transferFrom donates token1 (the output token).
    function test_B08_swapIn0DonationDuringPull() public {
        (uint256 r0, uint256 r1) = pool.getReserves();
        uint256 out = AMMMath.getAmountOut(1e18, r0, r1);
        _armDonation(h0, h1, ReentrantERC20.Hook.TransferFrom);
        vm.prank(bob);
        uint256 netOut = pool.swapExactInput(address(h0), 1e18, 0, carol, block.timestamp);
        assertEq(netOut, out);
        (uint256 a0, uint256 a1) = pool.getReserves();
        assertEq(a0, r0 + 1e18);
        assertEq(a1, r1 - out);
        assertEq(_surplusOf(h1, a1), GIFT, "gift stays surplus (BI-2)");
    }

    /// swap token1 in: token1's transferFrom donates token0 (the output token).
    function test_B08_swapIn1DonationDuringPull() public {
        (uint256 r0, uint256 r1) = pool.getReserves();
        uint256 out = AMMMath.getAmountOut(1e18, r1, r0);
        _armDonation(h1, h0, ReentrantERC20.Hook.TransferFrom);
        vm.prank(bob);
        uint256 netOut = pool.swapExactInput(address(h1), 1e18, 0, carol, block.timestamp);
        assertEq(netOut, out);
        (uint256 a0, uint256 a1) = pool.getReserves();
        assertEq(a1, r1 + 1e18);
        assertEq(a0, r0 - out);
        assertEq(_surplusOf(h0, a0), GIFT, "gift stays surplus (BI-2)");
    }

    /// remove: token0's outbound transfer donates token1; token1's push is still exact.
    function test_B08_removeDonationDuringFirstPush() public {
        (uint256 r0, uint256 r1) = pool.getReserves();
        uint256 supply = pool.totalSupply();
        uint256 e0 = Math.mulDiv(1e18, r0, supply);
        uint256 e1 = Math.mulDiv(1e18, r1, supply);
        _armDonation(h0, h1, ReentrantERC20.Hook.Transfer);
        vm.prank(alice);
        (uint256 n0, uint256 n1) = pool.removeLiquidity(1e18, e0, e1, carol, block.timestamp);
        assertTrue(h0.callbackRan());
        assertEq(n0, e0);
        assertEq(n1, e1);
        (uint256 a0, uint256 a1) = pool.getReserves();
        assertEq(a0, r0 - e0);
        assertEq(a1, r1 - e1);
        assertEq(_surplusOf(h1, a1), GIFT, "gift stays surplus (BI-2)");
    }
}
