// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {MockDeficitERC20} from "./mocks/MockDeficitERC20.sol";
import {PoolStateFixture} from "./utils/PoolStateFixture.sol";
import {MulDiv512} from "./utils/MulDiv512.sol";
import {addParamsOrdered} from "./utils/AddParams.sol";

/// @notice F1-T2: surplus and deficit accounting under mixed function sequences, per the M6
///         rules of each function (ARCHITECTURE §5.2–§5.5, BI-2 to BI-4; DECISIONS M6-2, M6-4).
///
///         Model (scope of this file). Per token i: b_i = Pool balance, r_i = recorded reserve,
///         s_i = b_i − r_i as a SIGNED value (s_i < 0 is a deficit). Ordinary transfers arrive
///         exactly (`MockDeficitERC20`, Tier 0). External transfers in (`donate`) and balance
///         reductions (`slash`, outside the supported model) happen only as separate test steps,
///         never during a Pool call. Within this scope the transitions are:
///         - donate(x): b += x, r unchanged → s += x.
///         - slash(x): b −= x, r unchanged → s −= x; a deficit exists only if afterwards b < r
///           (x < s: still surplus; x = s: b = r, no deficit; x > s: deficit).
///         - addLiquidity (later, Tier 0): entry requires no deficit in either token (else
///           `ReserveDeficit`); r += net, b += net → s unchanged.
///         - removeLiquidity: no deficit; r −= amount, b −= amount (A8) → s unchanged.
///         - swapExactInput: no deficit; input r, b += a; output r, b −= out → s unchanged.
///         - sync(): per token, if b < r then r := b (s: negative → 0), else no write, no event;
///           a surplus is never absorbed (Gate R=(b)).
///         - skim(): per token, if b > r then send b − r to surplusRecipient (s: positive → 0),
///           else skip; reserves never change; a deficit is left as it is.
///         Recovery from a deficit: `sync()` (lowers r; LPs bear the loss) or an external top-up
///         that brings b back to at least r (r unchanged).
///
///         Outside this file's scope (cited, not re-derived here): balance changes DURING a Pool
///         call. For `addLiquidity` the general identity is
///           s_after − s_before = (b_after − b_before) − net,
///         where net is measured inside the token's own `transferFrom` window; an arrival inside
///         that window is counted in net (the bonus channel of L13b), one outside it stays
///         surplus (B08 add, B09b). A removal during the call that leaves the end balance below
///         start + net reverts `InCallBalanceLoss` (B09c, B09d), even when the call as a whole
///         does not end in a deficit. For swap and remove a foreign in-call gift stays surplus
///         (B08); a foreign in-call loss masked by surplus is NOT detected (B10, THREAT_MODEL T30).
/// @dev Expected values come from the shadow model in this file (MulDiv512 and plain
///      formulas of ARCHITECTURE §6.2–§6.4, never the Pool's code) and, for the deterministic
///      cases, from literal constants of an independent Python model. Every revert is checked
///      with its exact data and full-state rollback (`PoolStateFixture._expectRevertNoChange`).
contract AMMPoolF1SurplusAccountingTest is PoolStateFixture {
    uint256 internal constant S_SEED = 1_414_213; // isqrt(1e6 · 2e6)
    bytes32 internal constant SYNCED_SIG = keccak256("ReserveSynced(address,uint256,uint256)");
    bytes32 internal constant SKIMMED_SIG = keccak256("SurplusSkimmed(address,uint256)");

    /// @dev Shadow model of the Pool and the affected balances.
    struct M {
        uint256 r0;
        uint256 r1;
        uint256 b0;
        uint256 b1;
        uint256 S;
        uint256 aliceLP;
        uint256 bobLP;
        uint256 sr0; // surplusRecipient balances
        uint256 sr1;
        uint256 carol0; // recipient of removals and swaps
        uint256 carol1;
    }

    M internal m;

    function setUp() public override {
        super.setUp(); // seeds (1e6, 2e6) by alice
        m = M(1e6, 2e6, 1e6, 2e6, S_SEED, S_SEED - 1000, 0, 0, 0, 0, 0);
        _check();
    }

    // ------------------------------------------------------------------
    // Model helpers
    // ------------------------------------------------------------------

    function _s(uint256 b, uint256 r) internal pure returns (int256) {
        return int256(b) - int256(r);
    }

    function _deficit() internal view returns (bool) {
        return m.b0 < m.r0 || m.b1 < m.r1;
    }

    /// @dev The Pool and every tracked balance equal the model.
    function _check() internal view {
        (uint256 r0, uint256 r1) = pool.getReserves();
        assertEq(r0, m.r0, "model r0");
        assertEq(r1, m.r1, "model r1");
        assertEq(t0.balanceOf(address(pool)), m.b0, "model b0");
        assertEq(t1.balanceOf(address(pool)), m.b1, "model b1");
        assertEq(pool.totalSupply(), m.S, "model S");
        assertEq(pool.balanceOf(alice), m.aliceLP, "model alice LP");
        assertEq(pool.balanceOf(bob), m.bobLP, "model bob LP");
        assertEq(t0.balanceOf(surplus), m.sr0, "model surplusRecipient token0");
        assertEq(t1.balanceOf(surplus), m.sr1, "model surplusRecipient token1");
        assertEq(t0.balanceOf(carol), m.carol0, "model carol token0");
        assertEq(t1.balanceOf(carol), m.carol1, "model carol token1");
    }

    function _err(bytes4 sel) internal pure returns (bytes memory) {
        return abi.encodePacked(sel);
    }

    // ------------------------------------------------------------------
    // Operations: predict with the model, execute, compare, update the model
    // ------------------------------------------------------------------

    function _donateM(MockDeficitERC20 t, uint256 x) internal {
        int256 sBefore = address(t) == address(t0) ? _s(m.b0, m.r0) : _s(m.b1, m.r1);
        _donate(t, x);
        if (address(t) == address(t0)) m.b0 += x;
        else m.b1 += x;
        _check();
        int256 sAfter = address(t) == address(t0) ? _s(m.b0, m.r0) : _s(m.b1, m.r1);
        assertEq(sAfter, sBefore + int256(x), "donate: s += x");
    }

    function _slashM(MockDeficitERC20 t, uint256 x) internal {
        int256 sBefore = address(t) == address(t0) ? _s(m.b0, m.r0) : _s(m.b1, m.r1);
        _slashPool(t, x);
        if (address(t) == address(t0)) m.b0 -= x;
        else m.b1 -= x;
        _check();
        int256 sAfter = address(t) == address(t0) ? _s(m.b0, m.r0) : _s(m.b1, m.r1);
        assertEq(sAfter, sBefore - int256(x), "slash: s -= x, reserve unchanged");
    }

    /// @dev Step 2 (ARCHITECTURE §6.2) and σ with MulDiv512 only, at the model's state.
    ///      Returns the predicted error (0 = success) for a later Tier 0 deposit without deficit.
    function _predictAdd(uint256 c0, uint256 c1)
        internal
        view
        returns (bytes4 perr, uint256 tg0, uint256 tg1, uint256 sigma)
    {
        (bool over, uint256 q) = MulDiv512.floorMulDiv(c0, m.r1, m.r0);
        if (!over && q <= c1) {
            (tg0, tg1) = (c0, q);
        } else {
            (, q) = MulDiv512.floorMulDiv(c1, m.r0, m.r1);
            (tg0, tg1) = (q, c1);
        }
        if (tg0 == 0 || tg1 == 0) return (AMMPool.InsufficientDepositAmount.selector, 0, 0, 0);
        (, uint256 s0) = MulDiv512.floorMulDiv(tg0, m.S, m.r0);
        (, uint256 s1) = MulDiv512.floorMulDiv(tg1, m.S, m.r1);
        sigma = s0 < s1 ? s0 : s1;
        if (sigma == 0) return (AMMPool.InsufficientShares.selector, 0, 0, 0);
    }

    /// @return ok Whether the deposit succeeded (as predicted).
    function _addM(uint256 c0, uint256 c1, bool t1First)
        internal
        returns (bool ok, uint256 n0, uint256 n1, uint256 sh)
    {
        bytes memory data = abi.encodeCall(
            AMMPool.addLiquidity, (addParamsOrdered(c0, c1, 0, bob, block.timestamp, t1First))
        );
        if (_deficit()) {
            _expectRevertNoChange(bob, data, _err(AMMPool.ReserveDeficit.selector));
            _check();
            return (false, 0, 0, 0);
        }
        (bytes4 perr, uint256 tg0, uint256 tg1, uint256 sigma) = _predictAdd(c0, c1);
        if (perr != bytes4(0)) {
            _expectRevertNoChange(bob, data, _err(perr));
            _check();
            return (false, 0, 0, 0);
        }
        int256 sb0 = _s(m.b0, m.r0);
        int256 sb1 = _s(m.b1, m.r1);
        vm.prank(bob);
        (bool success, bytes memory ret) = address(pool).call(data);
        assertTrue(success, "add must succeed");
        (n0, n1, sh) = abi.decode(ret, (uint256, uint256, uint256));
        assertEq(n0, tg0, "add net0");
        assertEq(n1, tg1, "add net1");
        assertEq(sh, sigma, "add shares");
        m.r0 += tg0;
        m.r1 += tg1;
        m.b0 += tg0;
        m.b1 += tg1;
        m.S += sigma;
        m.bobLP += sigma;
        _check();
        assertEq(_s(m.b0, m.r0), sb0, "add keeps s0");
        assertEq(_s(m.b1, m.r1), sb1, "add keeps s1");
        return (true, n0, n1, sh);
    }

    function _removeM(uint256 shares) internal returns (bool ok, uint256 a0, uint256 a1) {
        bytes memory data = abi.encodeCall(AMMPool.removeLiquidity, (shares, 0, 0, carol, block.timestamp));
        if (_deficit()) {
            _expectRevertNoChange(alice, data, _err(AMMPool.ReserveDeficit.selector));
            _check();
            return (false, 0, 0);
        }
        a0 = shares * m.r0 / m.S; // ARCHITECTURE §6.3, floor
        a1 = shares * m.r1 / m.S;
        if (a0 == 0 || a1 == 0) {
            _expectRevertNoChange(alice, data, _err(AMMPool.InsufficientLiquidityBurned.selector));
            _check();
            return (false, 0, 0);
        }
        int256 sb0 = _s(m.b0, m.r0);
        int256 sb1 = _s(m.b1, m.r1);
        vm.prank(alice);
        (bool success, bytes memory ret) = address(pool).call(data);
        assertTrue(success, "remove must succeed");
        (uint256 n0, uint256 n1) = abi.decode(ret, (uint256, uint256));
        assertEq(n0, a0, "remove amount0");
        assertEq(n1, a1, "remove amount1");
        m.r0 -= a0;
        m.r1 -= a1;
        m.b0 -= a0;
        m.b1 -= a1;
        m.S -= shares;
        m.aliceLP -= shares;
        m.carol0 += a0;
        m.carol1 += a1;
        _check();
        assertEq(_s(m.b0, m.r0), sb0, "remove keeps s0");
        assertEq(_s(m.b1, m.r1), sb1, "remove keeps s1");
        return (true, a0, a1);
    }

    function _swapM(bool zeroForOne, uint256 a) internal returns (bool ok, uint256 out) {
        address tin = zeroForOne ? address(t0) : address(t1);
        bytes memory data = abi.encodeCall(AMMPool.swapExactInput, (tin, a, 0, carol, block.timestamp));
        if (_deficit()) {
            _expectRevertNoChange(bob, data, _err(AMMPool.ReserveDeficit.selector));
            _check();
            return (false, 0);
        }
        (uint256 rin, uint256 rout) = zeroForOne ? (m.r0, m.r1) : (m.r1, m.r0);
        out = a * 9970 * rout / (rin * 10_000 + a * 9970); // ARCHITECTURE §6.4
        if (out == 0) {
            _expectRevertNoChange(bob, data, _err(AMMPool.InsufficientOutputAmount.selector));
            _check();
            return (false, 0);
        }
        int256 sb0 = _s(m.b0, m.r0);
        int256 sb1 = _s(m.b1, m.r1);
        vm.prank(bob);
        (bool success, bytes memory ret) = address(pool).call(data);
        assertTrue(success, "swap must succeed");
        assertEq(abi.decode(ret, (uint256)), out, "swap out");
        if (zeroForOne) {
            m.r0 += a;
            m.b0 += a;
            m.r1 -= out;
            m.b1 -= out;
            m.carol1 += out;
        } else {
            m.r1 += a;
            m.b1 += a;
            m.r0 -= out;
            m.b0 -= out;
            m.carol0 += out;
        }
        _check();
        assertEq(_s(m.b0, m.r0), sb0, "swap keeps s0");
        assertEq(_s(m.b1, m.r1), sb1, "swap keeps s1");
        return (true, out);
    }

    /// @dev sync(): exactly one ReserveSynced per token in deficit (token0 first), nothing else.
    function _syncM() internal {
        bool d0 = m.b0 < m.r0;
        bool d1 = m.b1 < m.r1;
        int256 sb0 = _s(m.b0, m.r0);
        int256 sb1 = _s(m.b1, m.r1);
        uint256 old0 = m.r0;
        uint256 old1 = m.r1;
        vm.recordLogs();
        pool.sync();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 k;
        if (d0) {
            _assertSynced(logs[k++], address(t0), old0, m.b0);
            m.r0 = m.b0;
        }
        if (d1) {
            _assertSynced(logs[k++], address(t1), old1, m.b1);
            m.r1 = m.b1;
        }
        assertEq(logs.length, k, "sync: one event per deficit token only");
        _check();
        assertEq(_s(m.b0, m.r0), d0 ? int256(0) : sb0, "sync: s0 deficit -> 0, surplus kept");
        assertEq(_s(m.b1, m.r1), d1 ? int256(0) : sb1, "sync: s1 deficit -> 0, surplus kept");
    }

    /// @dev skim(): exactly one SurplusSkimmed per token in surplus (token0 first).
    function _skimM() internal {
        bool p0 = m.b0 > m.r0;
        bool p1 = m.b1 > m.r1;
        int256 sb0 = _s(m.b0, m.r0);
        int256 sb1 = _s(m.b1, m.r1);
        vm.recordLogs();
        pool.skim();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 k;
        // Each skim emits the token's Transfer before SurplusSkimmed; filter by signature.
        uint256[2] memory amt;
        address[2] memory tok;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool)) {
                assertEq(logs[i].topics[0], SKIMMED_SIG, "skim: only SurplusSkimmed from the Pool");
                assertLt(k, 2);
                tok[k] = address(uint160(uint256(logs[i].topics[1])));
                amt[k] = abi.decode(logs[i].data, (uint256));
                ++k;
            }
        }
        uint256 j;
        if (p0) {
            assertEq(tok[j], address(t0), "skim event token0");
            assertEq(amt[j++], m.b0 - m.r0, "skim amount0");
            m.sr0 += m.b0 - m.r0;
            m.b0 = m.r0;
        }
        if (p1) {
            assertEq(tok[j], address(t1), "skim event token1");
            assertEq(amt[j++], m.b1 - m.r1, "skim amount1");
            m.sr1 += m.b1 - m.r1;
            m.b1 = m.r1;
        }
        assertEq(k, j, "skim: one event per surplus token only");
        _check();
        assertEq(_s(m.b0, m.r0), p0 ? int256(0) : sb0, "skim: s0 surplus -> 0, deficit kept");
        assertEq(_s(m.b1, m.r1), p1 ? int256(0) : sb1, "skim: s1 surplus -> 0, deficit kept");
    }

    function _assertSynced(Vm.Log memory l, address token, uint256 prev, uint256 next) internal view {
        assertEq(l.emitter, address(pool), "sync event emitter");
        assertEq(l.topics[0], SYNCED_SIG, "ReserveSynced");
        assertEq(address(uint160(uint256(l.topics[1]))), token, "sync event token");
        (uint256 a, uint256 b) = abi.decode(l.data, (uint256, uint256));
        assertEq(a, prev, "previousReserve");
        assertEq(b, next, "newReserve");
    }

    // ------------------------------------------------------------------
    // Deterministic: the four ordinary calls with literal anchors
    // ------------------------------------------------------------------

    /// @dev add (1e4, 3e4) → (1e4, 2e4, 14142); remove 1e5 → (70710, 141421); swap 1e4 token0 in
    ///      → 19743; swap 1e4 token1 in → 4960. Python model at reserves (1e6, 2e6), S = 1,414,213,
    ///      and identically at (999,999, 2e6). Each call runs from the same state.
    function _fourCallsSucceedWithAnchors() internal {
        uint256 snap = vm.snapshotState();
        _addExpect(10_000, 20_000, 14_142);
        vm.revertToState(snap);
        (bool ok2, uint256 a0, uint256 a1) = _removeM(1e5);
        assertTrue(ok2);
        assertEq(a0, 70_710);
        assertEq(a1, 141_421);
        vm.revertToState(snap);
        (bool ok3, uint256 o3) = _swapM(true, 1e4);
        assertTrue(ok3);
        assertEq(o3, 19_743);
        vm.revertToState(snap);
        (bool ok4, uint256 o4) = _swapM(false, 1e4);
        assertTrue(ok4);
        assertEq(o4, 4960);
        vm.revertToState(snap);
    }

    /// @dev The deposit (1e4, 3e4), token0 first, succeeds with the given literal anchors.
    function _addExpect(uint256 e0, uint256 e1, uint256 es) internal {
        (bool ok, uint256 n0, uint256 n1, uint256 sh) = _addM(1e4, 3e4, false);
        assertTrue(ok, "deposit succeeds");
        assertEq(n0, e0, "anchor net0");
        assertEq(n1, e1, "anchor net1");
        assertEq(sh, es, "anchor shares");
    }

    /// @dev The same four calls (same calldata) all revert ReserveDeficit with full rollback.
    function _fourCallsRevertDeficit() internal {
        assertTrue(_deficit(), "precondition: deficit");
        (bool ok,,,) = _addM(1e4, 3e4, false);
        assertFalse(ok);
        (bool ok2,,) = _removeM(1e5);
        assertFalse(ok2);
        (bool ok3,) = _swapM(true, 1e4);
        assertFalse(ok3);
        (bool ok4,) = _swapM(false, 1e4);
        assertFalse(ok4);
    }

    // ------------------------------------------------------------------
    // Deterministic: slash relative to one initial surplus of 500 token0
    // ------------------------------------------------------------------

    /// x < surplus: s0 = 1, no deficit; ordinary calls succeed and keep s0 = 1.
    function test_F1T2_slashBelowSurplus_noDeficit() public {
        _donateM(t0, 500);
        _slashM(t0, 499);
        assertEq(_s(m.b0, m.r0), 1);
        _fourCallsSucceedWithAnchors();
        // sync: no deficit → no write, no event; skim sends the 1 unit.
        _syncM();
        _skimM();
        assertEq(m.sr0, 1);
    }

    /// x = surplus: balance == reserve, which is NOT a deficit (equality passes the entry check).
    function test_F1T2_slashEqualSurplus_balanceEqualsReserve() public {
        _donateM(t0, 500);
        _slashM(t0, 500);
        assertEq(_s(m.b0, m.r0), 0);
        assertFalse(_deficit());
        _fourCallsSucceedWithAnchors();
        _syncM(); // no event
        _skimM(); // no event
        assertEq(m.sr0, 0);
        assertEq(m.r0, 1e6);
    }

    /// x > surplus: deficit of 1; add, remove and both swaps (otherwise valid) revert
    /// ReserveDeficit. Recovery path A: sync lowers reserve0 to 999,999; the same calldata then
    /// succeeds. Recovery path B (same deficit state): an external top-up of 1 restores
    /// b0 = r0 = 1e6 without any reserve change; the same calldata then succeeds.
    function test_F1T2_slashAboveSurplus_deficitAndBothRecoveries() public {
        _donateM(t0, 500);
        _slashM(t0, 501);
        assertEq(_s(m.b0, m.r0), -1);
        _fourCallsRevertDeficit();
        _skimM(); // token0 in deficit, token1 equal: nothing to skim, deficit kept
        uint256 snap = vm.snapshotState();

        // A: sync
        _syncM();
        assertEq(m.r0, 999_999, "sync lowered reserve0 by the deficit");
        assertEq(m.r1, 2e6);
        _fourCallsSucceedWithAnchors();

        // B: top-up from the same deficit state
        vm.revertToState(snap);
        _check();
        _donateM(t0, 1);
        assertEq(m.r0, 1e6, "top-up keeps reserve0");
        assertEq(_s(m.b0, m.r0), 0);
        _fourCallsSucceedWithAnchors();
        _syncM(); // no deficit any more: no event
    }

    // ------------------------------------------------------------------
    // Deterministic: token0 deficit and token1 surplus, sync vs skim from the same state
    // ------------------------------------------------------------------

    /// @dev State: slash 300 token0 (deficit 300), donate 700 token1 (surplus 700).
    ///      sync: ReserveSynced(token0, 1e6, 999,700) only; token1 surplus 700 kept; the deposit
    ///      (1e4, 3e4) then succeeds with (1e4, 20,006, 14,146) (Python model at r = (999,700, 2e6)).
    ///      skim: SurplusSkimmed(token1, 700) only; token0 deficit 300 kept, so deposit and swaps
    ///      still revert ReserveDeficit with rollback; after sync the same deposit gives the same
    ///      numbers. Both orders end in the same state.
    function test_F1T2_deficit0Surplus1_syncVsSkimIndependent() public {
        _slashM(t0, 300);
        _donateM(t1, 700);
        assertEq(_s(m.b0, m.r0), -300);
        assertEq(_s(m.b1, m.r1), 700);
        uint256 snap = vm.snapshotState();

        // Path 1: sync first
        _syncM();
        assertEq(m.r0, 999_700);
        assertEq(m.r1, 2e6);
        assertEq(_s(m.b1, m.r1), 700, "sync keeps token1 surplus");
        assertEq(m.sr1, 0);
        _addExpect(10_000, 20_006, 14_146);
        assertEq(_s(m.b1, m.r1), 700, "deposit keeps token1 surplus");
        _skimM();
        assertEq(m.sr1, 700);
        M memory end1 = m;

        // Path 2: skim first, from the same state
        vm.revertToState(snap);
        _check();
        _skimM();
        assertEq(m.sr1, 700, "skim sent token1 surplus");
        assertEq(m.r0, 1e6, "skim keeps reserve0");
        assertEq(_s(m.b0, m.r0), -300, "skim keeps token0 deficit");
        (bool okA,,,) = _addM(1e4, 3e4, false);
        assertFalse(okA, "deposit still blocked by the token0 deficit");
        (bool okS,) = _swapM(false, 1e4);
        assertFalse(okS, "swap still blocked");
        _syncM();
        _addExpect(10_000, 20_006, 14_146);

        // Same end state either way.
        assertEq(m.r0, end1.r0);
        assertEq(m.r1, end1.r1);
        assertEq(m.b0, end1.b0);
        assertEq(m.b1, end1.b1);
        assertEq(m.S, end1.S);
        assertEq(m.sr0, end1.sr0);
        assertEq(m.sr1, end1.sr1);
    }

    // ------------------------------------------------------------------
    // Fuzz: mixed sequences starting from surplus in both tokens
    // ------------------------------------------------------------------

    /// @dev 16 random steps after an initial surplus in both tokens. Actions: donate, slash,
    ///      top-up of an existing deficit, sync, skim, add (both orders), remove, swap in either
    ///      direction. Slash amounts are biased to s − 1, s, s + 1 when s > 0, and always leave
    ///      b ≥ 1 (so no reserve reaches 0; terminal pools are R14–R22). After every step the Pool
    ///      equals the shadow model, including the signed s_i. Ranges: initial surplus [1, 1e6]
    ///      per token, donations [1, 1e24], deposit caps [1, 1e12], swaps [1, 1e9], removals
    ///      [1, alice's LP]. Uncovered: taxed tokens; in-call side effects (B08–B10).
    function testFuzz_F1T2_mixedSequence(uint256 seed, uint256 g0, uint256 g1) public {
        _donateM(t0, bound(g0, 1, 1e6));
        _donateM(t1, bound(g1, 1, 1e6));
        for (uint256 step; step < 16; ++step) {
            uint256 rnd = uint256(keccak256(abi.encode(seed, step)));
            uint256 action = rnd % 9;
            bool first = (rnd >> 8) % 2 == 0;
            MockDeficitERC20 t = first ? t0 : t1;
            uint256 x = rnd >> 16;
            if (action == 0) {
                _donateM(t, bound(x, 1, 1e24));
            } else if (action == 1) {
                _slashM(t, _slashAmount(t, x));
            } else if (action == 2) {
                // top-up: bring a deficit token back to b = r (else a 1-unit donation)
                (uint256 b, uint256 r) = address(t) == address(t0) ? (m.b0, m.r0) : (m.b1, m.r1);
                _donateM(t, b < r ? r - b : 1);
            } else if (action == 3) {
                _syncM();
            } else if (action == 4) {
                _skimM();
            } else if (action == 5) {
                _addM(bound(x, 1, 1e12), bound(x >> 64, 1, 1e12), first);
            } else if (action == 6) {
                if (m.aliceLP > 0) _removeM(bound(x, 1, m.aliceLP));
            } else {
                _swapM(action == 7, bound(x, 1, 1e9));
            }
        }
    }

    function _slashAmount(MockDeficitERC20 t, uint256 x) internal view returns (uint256 amt) {
        (uint256 b, uint256 r) = address(t) == address(t0) ? (m.b0, m.r0) : (m.b1, m.r1);
        uint256 maxAmt = b - 1; // keep b ≥ 1
        if (b > r) {
            uint256 s = b - r;
            uint256 mode = x % 4;
            amt = mode == 0 ? s - 1 : mode == 1 ? s : mode == 2 ? s + 1 : bound(x >> 2, 0, maxAmt);
        } else {
            amt = bound(x >> 2, 0, maxAmt / 2 + 1);
        }
        if (amt > maxAmt) amt = maxAmt;
    }
}
