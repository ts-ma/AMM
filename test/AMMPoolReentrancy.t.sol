// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";
import {IAMMPool} from "../src/interfaces/IAMMPool.sol";
import {addParams, addParamsOrdered} from "./utils/AddParams.sol";

/// @dev Callback target for X05: reads the Pool's views while a Pool call is in progress.
contract ReserveProbe {
    function read(AMMPool p)
        external
        view
        returns (uint256 r0, uint256 r1, uint256 supply, uint256 bal0, uint256 bal1)
    {
        (r0, r1) = p.getReserves();
        supply = p.totalSupply();
        bal0 = IERC20(p.token0()).balanceOf(address(p));
        bal1 = IERC20(p.token1()).balanceOf(address(p));
    }
}

/// @notice Reentrancy suite (THREAT_MODEL T1, T13; DECISIONS M5-5, M5-6).
///         TEST_MATRIX S08, W07, X01, X05. A hook token (`ReentrantERC20`, `r`) re-enters the Pool
///         from inside a Pool call, either during the inbound `transferFrom` or the outbound
///         `transfer`. Three cases per scenario (M5-6):
///         (i)   Bubbling: inner re-entry reverts, outer call reverts, all relevant state unchanged;
///         (ii)  Caught + correct transfer: inner re-entry reverts and is swallowed; the outer call
///               succeeds and its end state is IDENTICAL to a run without any re-entry attempt;
///         (iii) Caught + faulty transfer: the outer call is rejected by A8, MIN-NET or (M8)
///               the excess bound, or a short add is accounted by measured net.
///         The attacker (the token contract itself) is funded with both tokens, approvals and LP,
///         so every re-entrant call would succeed if the guard were missing.
contract AMMPoolReentrancyTest is Test {
    uint256 internal constant FUND = 1e30;
    uint256 internal constant MAX = type(uint256).max;

    ReentrantERC20 internal r;
    MockERC20 internal m;
    AMMPool internal pool;
    ReserveProbe internal probe;
    address internal attacker;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    bytes internal reentrantErr =
        abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);

    function setUp() public {
        r = new ReentrantERC20("Hook", "HOOK", 18);
        m = new MockERC20("Plain", "PLN", 18);
        (address lo, address hi) = address(r) < address(m) ? (address(r), address(m)) : (address(m), address(r));
        pool = new AMMPool(lo, hi, makeAddr("surplusRecipient"));
        probe = new ReserveProbe();
        attacker = address(r);

        address[3] memory users = [alice, bob, attacker];
        for (uint256 i; i < 3; ++i) {
            r.mint(users[i], FUND);
            m.mint(users[i], FUND);
            vm.startPrank(users[i]);
            r.approve(address(pool), MAX);
            m.approve(address(pool), MAX);
            vm.stopPrank();
        }
        vm.prank(alice);
        pool.addLiquidity(addParams(1e21, 1e21, 0, alice, block.timestamp));
        vm.prank(bob);
        pool.addLiquidity(addParams(1e20, 1e20, 0, bob, block.timestamp));
        vm.prank(attacker);
        pool.addLiquidity(addParams(1e20, 1e20, 0, attacker, block.timestamp));
    }

    // ------------------------------------------------------------------
    // Calls
    // ------------------------------------------------------------------

    /// @dev Outer calls made by bob. swapIn/add trigger r.transferFrom; swapOut/remove trigger r.transfer.
    function _swapIn(uint256 minOut) internal view returns (bytes memory) {
        return abi.encodeCall(AMMPool.swapExactInput, (address(r), 1e18, minOut, carol, block.timestamp));
    }

    function _swapOut(uint256 minOut) internal view returns (bytes memory) {
        return abi.encodeCall(AMMPool.swapExactInput, (address(m), 1e18, minOut, carol, block.timestamp));
    }

    function _remove(uint256 min0, uint256 min1) internal view returns (bytes memory) {
        return abi.encodeCall(AMMPool.removeLiquidity, (1e19, min0, min1, carol, block.timestamp));
    }

    function _add() internal view returns (bytes memory) {
        return abi.encodeCall(AMMPool.addLiquidity, (addParams(1e18, 1e18, 0, bob, block.timestamp)));
    }

    /// @dev Re-entrant calls made by the token (msg.sender = attacker).
    function _payloads() internal view returns (bytes[3] memory p) {
        p[0] = abi.encodeCall(AMMPool.swapExactInput, (address(m), 1e15, 0, attacker, block.timestamp));
        p[1] = abi.encodeCall(AMMPool.addLiquidity, (addParams(1e18, 1e18, 0, attacker, block.timestamp)));
        p[2] = abi.encodeCall(AMMPool.removeLiquidity, (1e18, 0, 0, attacker, block.timestamp));
    }

    // ------------------------------------------------------------------
    // State snapshot (DECISIONS M5-6: reserves, Pool and user balances, LP, allowances)
    // ------------------------------------------------------------------

    struct Snap {
        uint256 r0;
        uint256 r1;
        uint256 supply;
        uint256[4] lp; // pool, alice, bob, attacker
        uint256[4] balR; // pool, bob, carol, attacker
        uint256[4] balM;
        uint256[4] allow; // bob→pool r, bob→pool m, attacker→pool r, attacker→pool m
    }

    function _snap() internal view returns (Snap memory s) {
        (s.r0, s.r1) = pool.getReserves();
        s.supply = pool.totalSupply();
        address[4] memory lpHolders = [address(pool), alice, bob, attacker];
        address[4] memory holders = [address(pool), bob, carol, attacker];
        for (uint256 i; i < 4; ++i) {
            s.lp[i] = pool.balanceOf(lpHolders[i]);
            s.balR[i] = r.balanceOf(holders[i]);
            s.balM[i] = m.balanceOf(holders[i]);
        }
        s.allow[0] = r.allowance(bob, address(pool));
        s.allow[1] = m.allowance(bob, address(pool));
        s.allow[2] = r.allowance(attacker, address(pool));
        s.allow[3] = m.allowance(attacker, address(pool));
    }

    function _assertSame(Snap memory a, Snap memory b) internal pure {
        assertEq(a.r0, b.r0, "reserve0");
        assertEq(a.r1, b.r1, "reserve1");
        assertEq(a.supply, b.supply, "LP totalSupply");
        for (uint256 i; i < 4; ++i) {
            assertEq(a.lp[i], b.lp[i], "LP balance");
            assertEq(a.balR[i], b.balR[i], "hook-token balance");
            assertEq(a.balM[i], b.balM[i], "plain-token balance");
            assertEq(a.allow[i], b.allow[i], "allowance");
        }
    }

    // ------------------------------------------------------------------
    // Case drivers
    // ------------------------------------------------------------------

    /// @dev (i) Bubbling: outer call fails with exactly the guard's error; nothing changes.
    function _bubble(bytes memory outer, ReentrantERC20.Hook hook, bytes memory payload) internal {
        Snap memory b = _snap();
        r.armWith(address(pool), payload, hook, false);
        vm.prank(bob);
        (bool ok, bytes memory ret) = address(pool).call(outer);
        assertFalse(ok, "outer call must revert");
        assertEq(ret, reentrantErr, "guard error bubbled unchanged");
        _assertSame(b, _snap());
    }

    /// @dev (ii) Caught + correct transfer: end state and return data equal a clean run.
    function _caughtCorrect(bytes memory outer, ReentrantERC20.Hook hook, bytes memory payload) internal {
        uint256 id = vm.snapshotState();
        vm.prank(bob);
        (bool okClean, bytes memory retClean) = address(pool).call(outer);
        assertTrue(okClean, "control run succeeds");
        Snap memory clean = _snap();
        vm.revertToState(id);

        r.armWith(address(pool), payload, hook, true);
        vm.prank(bob);
        (bool ok, bytes memory ret) = address(pool).call(outer);
        assertTrue(ok, "outer call succeeds: transfer correct, every later check passes");
        assertTrue(r.callbackRan(), "re-entry was attempted");
        assertFalse(r.lastCallOk(), "re-entry failed");
        assertEq(r.lastReturnData(), reentrantErr, "re-entry hit the guard");
        assertEq(ret, retClean, "same return values as a clean run");
        _assertSame(clean, _snap());
    }

    /// @dev (iii) Caught + faulty transfer: the Pool's own checks reject the call; nothing changes.
    function _caughtFaulty(
        bytes memory outer,
        ReentrantERC20.Hook hook,
        uint256 extraDebit,
        uint256 withhold,
        bytes memory err
    ) internal {
        r.setFaults(extraDebit, withhold);
        Snap memory b = _snap();
        r.armWith(address(pool), _payloads()[0], hook, true);
        vm.prank(bob);
        (bool ok, bytes memory ret) = address(pool).call(outer);
        assertFalse(ok, "outer call rejected");
        assertEq(ret, err, "rejected by the expected Pool check");
        _assertSame(b, _snap());
    }

    // ------------------------------------------------------------------
    // S08 — reentrancy during swap; X01 — cross-function from swap callbacks
    // ------------------------------------------------------------------

    function test_S08_X01_swapInboundCallback_bubbling() public {
        bytes[3] memory p = _payloads();
        for (uint256 i; i < 3; ++i) {
            _bubble(_swapIn(0), ReentrantERC20.Hook.TransferFrom, p[i]);
        }
    }

    function test_S08_X01_swapOutboundCallback_bubbling() public {
        bytes[3] memory p = _payloads();
        for (uint256 i; i < 3; ++i) {
            _bubble(_swapOut(0), ReentrantERC20.Hook.Transfer, p[i]);
        }
    }

    function test_S08_X01_swapInboundCallback_caughtCorrect() public {
        bytes[3] memory p = _payloads();
        for (uint256 i; i < 3; ++i) {
            _caughtCorrect(_swapIn(0), ReentrantERC20.Hook.TransferFrom, p[i]);
        }
    }

    function test_S08_X01_swapOutboundCallback_caughtCorrect() public {
        bytes[3] memory p = _payloads();
        for (uint256 i; i < 3; ++i) {
            _caughtCorrect(_swapOut(0), ReentrantERC20.Hook.Transfer, p[i]);
        }
    }

    function test_S08_swapOutbound_caughtFaulty_overDebitRejectedByA8() public {
        _caughtFaulty(
            _swapOut(0),
            ReentrantERC20.Hook.Transfer,
            1,
            0,
            abi.encodeWithSelector(AMMPool.OutboundTransferMismatch.selector)
        );
    }

    function test_S08_swapOutbound_caughtFaulty_shortDeliveryRejectedByMinNet() public {
        uint256 q = pool.getAmountOut(address(m), 1e18);
        _caughtFaulty(
            _swapOut(q),
            ReentrantERC20.Hook.Transfer,
            0,
            1,
            abi.encodeWithSelector(AMMPool.InsufficientNetReceived.selector)
        );
    }

    /// @dev Inbound shortfall: the Pool prices the measured (smaller) input, so the output falls
    ///      below a minimum taken from the quote for the full amount — MIN-NET rejects the swap.
    function test_S08_swapInbound_caughtFaulty_shortInputRejectedByMinNet() public {
        uint256 q = pool.getAmountOut(address(r), 1e18);
        _caughtFaulty(
            _swapIn(q),
            ReentrantERC20.Hook.TransferFrom,
            0,
            1,
            abi.encodeWithSelector(AMMPool.InsufficientNetReceived.selector)
        );
    }

    // ------------------------------------------------------------------
    // W07 — reentrancy during withdrawal; X01 — cross-function from withdrawal callback
    // ------------------------------------------------------------------

    function test_W07_X01_removeCallback_bubbling() public {
        bytes[3] memory p = _payloads();
        for (uint256 i; i < 3; ++i) {
            _bubble(_remove(0, 0), ReentrantERC20.Hook.Transfer, p[i]);
        }
    }

    function test_W07_X01_removeCallback_caughtCorrect() public {
        bytes[3] memory p = _payloads();
        for (uint256 i; i < 3; ++i) {
            _caughtCorrect(_remove(0, 0), ReentrantERC20.Hook.Transfer, p[i]);
        }
    }

    function test_W07_remove_caughtFaulty_overDebitRejectedByA8() public {
        _caughtFaulty(
            _remove(0, 0),
            ReentrantERC20.Hook.Transfer,
            1,
            0,
            abi.encodeWithSelector(AMMPool.OutboundTransferMismatch.selector)
        );
    }

    function test_W07_remove_caughtFaulty_shortDeliveryRejectedByMinNet() public {
        (uint256 r0, uint256 r1) = pool.getReserves();
        uint256 s = pool.totalSupply();
        uint256 x0 = 1e19 * r0 / s;
        uint256 x1 = 1e19 * r1 / s;
        _caughtFaulty(
            _remove(x0, x1),
            ReentrantERC20.Hook.Transfer,
            0,
            1,
            abi.encodeWithSelector(AMMPool.InsufficientNetReceived.selector)
        );
    }

    // ------------------------------------------------------------------
    // X01 — cross-function from deposit callback (L24 covers add → add bubbling)
    // ------------------------------------------------------------------

    function test_X01_addCallback_bubbling() public {
        bytes[3] memory p = _payloads();
        for (uint256 i; i < 3; ++i) {
            _bubble(_add(), ReentrantERC20.Hook.TransferFrom, p[i]);
        }
    }

    function test_X01_addCallback_caughtCorrect() public {
        bytes[3] memory p = _payloads();
        for (uint256 i; i < 3; ++i) {
            _caughtCorrect(_add(), ReentrantERC20.Hook.TransferFrom, p[i]);
        }
    }

    /// @dev Migrated in M8 (TEST_MATRIX §3.3) from `test_X01_add_caughtFaulty_shortInputRejectedByNetRange`.
    ///      The `[T, T + 1]` check no longer exists; the kept property is "a short hook-token
    ///      delivery during a caught re-entry never earns shares for tokens that did not arrive".
    ///      (a) With unbounded excess the call succeeds and is accounted by measured net.
    function test_X01_add_caughtFaulty_shortInputAccountedByMeasuredNet() public {
        r.setFaults(0, 2);
        Snap memory b = _snap();
        r.armWith(address(pool), _payloads()[0], ReentrantERC20.Hook.TransferFrom, true);
        vm.prank(bob);
        (uint256 n0, uint256 n1, uint256 s) = pool.addLiquidity(addParams(1e18, 1e18, 0, bob, block.timestamp));
        Snap memory a = _snap();
        assertTrue(r.callbackRan(), "re-entry was attempted");
        assertEq(r.lastReturnData(), reentrantErr, "re-entry hit the guard");
        bool rIs0 = pool.token0() == address(r);
        assertEq(rIs0 ? n0 : n1, 1e18 - 2, "hook token arrived 2 short and is counted as such");
        assertEq(a.r0, b.r0 + n0);
        assertEq(a.r1, b.r1 + n1);
        uint256 s0 = n0 * b.supply / b.r0;
        uint256 s1 = n1 * b.supply / b.r1;
        assertEq(s, s0 < s1 ? s0 : s1, "shares from measured nets");
        assertEq(a.lp[2] - b.lp[2], s);
    }

    /// @dev (b) Hook token pulled second, zero excess allowed: the plain token's 2 unmatched units
    ///      exceed maxExcess = 0, so the Pool's own check rejects the call with full rollback.
    function test_X01_add_caughtFaulty_shortInputRejectedByExcessBound() public {
        IAMMPool.AddLiquidityParams memory prm =
            addParamsOrdered(1e18, 1e18, 0, bob, block.timestamp, pool.token0() == address(r));
        (prm.maxExcess0, prm.maxExcess1) = (0, 0);
        _caughtFaulty(
            abi.encodeCall(AMMPool.addLiquidity, (prm)),
            ReentrantERC20.Hook.TransferFrom,
            0,
            2,
            abi.encodeWithSelector(AMMPool.ExcessContributionTooHigh.selector)
        );
    }

    // ------------------------------------------------------------------
    // X05 — read-only reentrancy demonstration (T13, DECISIONS M5-5)
    // What a callback actually reads mid-call; no `nonReentrantView` is used.
    // ------------------------------------------------------------------

    function _probe(bytes memory outer, ReentrantERC20.Hook hook)
        internal
        returns (uint256 r0, uint256 r1, uint256 supply, uint256 bal0, uint256 bal1)
    {
        r.armWith(address(probe), abi.encodeCall(ReserveProbe.read, (pool)), hook, false);
        vm.prank(bob);
        (bool ok,) = address(pool).call(outer);
        assertTrue(ok);
        assertTrue(r.lastCallOk(), "views are not guarded: the read succeeds mid-call");
        return abi.decode(r.lastReturnData(), (uint256, uint256, uint256, uint256, uint256));
    }

    /// @dev During the inbound pull, everything read is the PRE-CALL state (consistent snapshot).
    function test_X05_midSwapInboundReadsPreCallState() public {
        Snap memory b = _snap();
        (uint256 r0, uint256 r1, uint256 supply, uint256 bal0, uint256 bal1) =
            _probe(_swapIn(0), ReentrantERC20.Hook.TransferFrom);
        assertEq(r0, b.r0, "reserve0 = pre-call");
        assertEq(r1, b.r1, "reserve1 = pre-call");
        assertEq(supply, b.supply);
        (uint256 p0, uint256 p1) = address(r) == pool.token0() ? (b.balR[0], b.balM[0]) : (b.balM[0], b.balR[0]);
        assertEq(bal0, p0, "Pool balances unchanged: the hook runs before the move");
        assertEq(bal1, p1);
    }

    /// @dev During the outbound push, reserves are already POST-SWAP (effects first), while the
    ///      Pool still holds the output (the hook runs before the move): balance = reserve + out.
    function test_X05_midSwapOutboundReadsPostEffectReserves() public {
        uint256 out = pool.getAmountOut(address(m), 1e18);
        (uint256 r0, uint256 r1, uint256 supply, uint256 bal0, uint256 bal1) =
            _probe(_swapOut(0), ReentrantERC20.Hook.Transfer);
        (uint256 f0, uint256 f1) = pool.getReserves();
        assertEq(r0, f0, "reserve0 mid-call = final");
        assertEq(r1, f1, "reserve1 mid-call = final");
        bool rIs0 = address(r) == pool.token0();
        assertEq(rIs0 ? bal0 : bal1, (rIs0 ? f0 : f1) + out, "output not yet sent: balance = reserve + out");
        assertEq(supply, pool.totalSupply());
    }

    /// @dev During a withdrawal's outbound push, the LP burn and both reserve decreases have
    ///      already happened (effects before either transfer), so the reserve / supply ratio read
    ///      mid-call equals the final one.
    function test_X05_midRemoveReadsPostEffectState() public {
        (uint256 r0, uint256 r1, uint256 supply,,) = _probe(_remove(0, 0), ReentrantERC20.Hook.Transfer);
        (uint256 f0, uint256 f1) = pool.getReserves();
        assertEq(r0, f0, "reserve0 mid-call = final");
        assertEq(r1, f1, "reserve1 mid-call = final");
        assertEq(supply, pool.totalSupply(), "LP already burned mid-call");
    }
}
