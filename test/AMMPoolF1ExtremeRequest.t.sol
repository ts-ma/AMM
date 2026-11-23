// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {IAMMPool} from "../src/interfaces/IAMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Wide512} from "./utils/Wide512.sol";
import {MulDiv512} from "./utils/MulDiv512.sol";
import {addParamsOrdered} from "./utils/AddParams.sol";

/// @notice F1-T1 (M8 F1 follow-up tests; THREAT_MODEL T4/T29; DECISIONS M8-2, M8-12).
///         Tier 0 later deposit with an extremely unbalanced request:
///         (a) the FIRST `transferFrom` is the step-2 target of the first-pulled token, in the
///             caller's pull order, and the second one is the other step-2 target (Tier 0:
///             net = target, so no re-plan);
///         (b) the unmatched amount is bounded: u_i < r_i/S + r_i/r_j, i.e. in integers
///             u_i·S·r_j < r_i·(r_j + S) (512-bit);
///         (c) `maxExcess_i` is an absolute bound on u_i (smallest units of token i):
///             `maxExcess = u` passes, `maxExcess = u − 1` reverts `ExcessContributionTooHigh`
///             with no state change.
///         A side whose step-2 target floors to 0 reverts `InsufficientDepositAmount` before
///         any transfer.
/// @dev Independent expectations:
///      - fixed cases: literal constants from an integer Python model of the same steps
///        (init, swap, step 2, σ, u), reported with M8 F1 batch 1;
///      - fuzz: step 2 and σ recomputed with `MulDiv512` (no OpenZeppelin `mulDiv`); the
///        bound (b) is a separate mathematical claim, not a replay of the Pool's code.
///      Proof of (b) (Tier 0, σ not saturated). Let k be the side that attains
///      σ = floor(T_k·S/r_k), so σ > T_k·S/r_k − 1 and u_k ≤ T_k − σ·r_k/S < r_k/S. For the
///      other side j, step 2 gives either T_j = cap_j with T_k = floor(cap_j·r_k/r_j), so
///      T_j < (T_k + 1)·r_j/r_k, or T_j = floor(T_k·r_j/r_k) ≤ T_k·r_j/r_k; either way
///      u_j ≤ T_j − σ·r_j/S < (T_k + 1)·r_j/r_k − (T_k·S/r_k − 1)·r_j/S = r_j/r_k + r_j/S.
///      Fuzz range: initial amounts [1e3, 2^120], one optional swap [1, 2^120], caps
///      [1, 1e30] (two modes force one tiny and one huge cap). Uncovered: taxed tokens
///      (re-plan), saturated σ (Z08).
contract AMMPoolF1ExtremeRequestTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant BIG = 1e30;
    bytes32 internal constant TRANSFER_SIG = keccak256("Transfer(address,address,uint256)");

    address internal alice = makeAddr("alice"); // seeds and swaps
    address internal bob = makeAddr("bob"); // depositor under test
    address internal surplusRecipient = makeAddr("surplusRecipient");

    MockERC20 internal t0;
    MockERC20 internal t1;
    AMMPool internal pool;

    // ------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------

    /// @param swapDir 0 = no swap, 1 = token0 in, 2 = token1 in.
    function _build(uint256 a0, uint256 a1, uint8 swapDir, uint256 swapAmt) internal {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        pool = new AMMPool(address(t0), address(t1), surplusRecipient);
        _fund(alice, 2 ** 122);
        _fund(bob, BIG);
        vm.prank(alice);
        pool.addLiquidity(addParamsOrdered(a0, a1, 0, alice, block.timestamp, false));
        if (swapDir != 0) {
            address tin = swapDir == 1 ? address(t0) : address(t1);
            vm.prank(alice);
            pool.swapExactInput(tin, swapAmt, 0, alice, block.timestamp);
        }
    }

    function _fund(address who, uint256 amount) internal {
        t0.mint(who, amount);
        t1.mint(who, amount);
        vm.startPrank(who);
        t0.approve(address(pool), MAX);
        t1.approve(address(pool), MAX);
        vm.stopPrank();
    }

    function _params(uint256 c0, uint256 c1, bool t1First, uint256 e0, uint256 e1)
        internal
        view
        returns (IAMMPool.AddLiquidityParams memory prm)
    {
        prm = addParamsOrdered(c0, c1, 0, bob, block.timestamp, t1First);
        prm.maxExcess0 = e0;
        prm.maxExcess1 = e1;
    }

    struct State {
        uint256 r0;
        uint256 r1;
        uint256 supply;
        uint256 bobLP;
        uint256 pool0;
        uint256 pool1;
        uint256 bob0;
        uint256 bob1;
    }

    function _state() internal view returns (State memory s) {
        (s.r0, s.r1) = pool.getReserves();
        s.supply = pool.totalSupply();
        s.bobLP = pool.balanceOf(bob);
        s.pool0 = t0.balanceOf(address(pool));
        s.pool1 = t1.balanceOf(address(pool));
        s.bob0 = t0.balanceOf(bob);
        s.bob1 = t1.balanceOf(bob);
    }

    function _assertSame(State memory x, State memory y) internal pure {
        assertEq(x.r0, y.r0, "reserve0");
        assertEq(x.r1, y.r1, "reserve1");
        assertEq(x.supply, y.supply, "supply");
        assertEq(x.bobLP, y.bobLP, "bob LP");
        assertEq(x.pool0, y.pool0, "Pool token0");
        assertEq(x.pool1, y.pool1, "Pool token1");
        assertEq(x.bob0, y.bob0, "bob token0");
        assertEq(x.bob1, y.bob1, "bob token1");
    }

    function _expectRevertNoChange(IAMMPool.AddLiquidityParams memory prm, bytes4 err) internal {
        State memory before = _state();
        vm.prank(bob);
        (bool ok, bytes memory ret) = address(pool).call(abi.encodeCall(AMMPool.addLiquidity, (prm)));
        assertFalse(ok, "must revert");
        assertEq(ret, abi.encodePacked(err), "exact revert data");
        _assertSame(before, _state());
    }

    // ------------------------------------------------------------------
    // Shared assertions
    // ------------------------------------------------------------------

    /// @dev (b): u_i·S·r_j < r_i·(r_j + S), exact in 512 bits.
    function _assertBound(uint256 u, uint256 ri, uint256 rj, uint256 S) internal pure {
        (uint256 lh, uint256 ll) = Wide512.mul(u * S, rj);
        (uint256 rh, uint256 rl) = Wide512.mul(ri, rj + S);
        assertTrue(Wide512.lt(lh, ll, rh, rl), "u_i < r_i/S + r_i/r_j");
    }

    /// @dev (a): the inbound Transfer events from bob come from the tokens in the caller's
    ///      order and carry exactly the step-2 targets; there are exactly two of them.
    function _assertPullOrder(Vm.Log[] memory logs, bool t1First, uint256 tgt0, uint256 tgt1) internal view {
        address[2] memory emitter;
        uint256[2] memory value;
        uint256 k;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.topics.length == 3 && l.topics[0] == TRANSFER_SIG && address(uint160(uint256(l.topics[1]))) == bob) {
                assertLt(k, 2, "exactly two pulls");
                assertEq(address(uint160(uint256(l.topics[2]))), address(pool), "pull destination");
                emitter[k] = l.emitter;
                value[k] = abi.decode(l.data, (uint256));
                ++k;
            }
        }
        assertEq(k, 2, "exactly two pulls");
        (address first, uint256 firstAmt, address second, uint256 secondAmt) =
            t1First ? (address(t1), tgt1, address(t0), tgt0) : (address(t0), tgt0, address(t1), tgt1);
        assertEq(emitter[0], first, "first pulled token");
        assertEq(value[0], firstAmt, "first transferFrom = step-2 target");
        assertEq(emitter[1], second, "second pulled token");
        assertEq(value[1], secondAmt, "second transferFrom = step-2 target");
    }

    // ------------------------------------------------------------------
    // Fixed cases (constants from the independent Python model)
    // ------------------------------------------------------------------

    struct Case {
        uint256 a0;
        uint256 a1;
        uint8 swapDir;
        uint256 swapAmt;
        uint256 c0;
        uint256 c1;
        // expected
        uint256 r0;
        uint256 r1;
        uint256 S;
        uint256 tgt0;
        uint256 tgt1;
        uint256 sigma;
        uint256 u0;
        uint256 u1;
    }

    function _caseA() internal pure returns (Case memory) {
        return Case(1e6, 2e6, 0, 0, 1, BIG, 1e6, 2e6, 1_414_213, 1, 2, 1, 0, 0);
    }

    function _caseB() internal pure returns (Case memory) {
        return Case(2e6, 1e6, 0, 0, BIG, 1, 2e6, 1e6, 1_414_213, 2, 1, 1, 0, 0);
    }

    /// @dev The P3 state of F1-T5/T6: init(1000, 1e9), swap 100 token0 in.
    function _caseC() internal pure returns (Case memory) {
        return Case(1000, 1e9, 1, 100, 1, BIG, 1100, 909_338_911, 1e6, 1, 826_671, 909, 0, 81);
    }

    function _caseD() internal pure returns (Case memory) {
        return Case(1e9, 1000, 2, 100, BIG, 1, 909_338_911, 1100, 1e6, 826_671, 1, 909, 81, 0);
    }

    function _caseE() internal pure returns (Case memory) {
        return Case(
            2 ** 100,
            1e4,
            0,
            0,
            BIG,
            1,
            2 ** 100,
            1e4,
            112_589_990_684_262_400,
            126_765_060_022_822_940_149_670_320,
            1,
            11_258_999_068_426,
            2_702_159_776_421,
            0
        );
    }

    function _caseF() internal pure returns (Case memory) {
        return Case(
            1e4,
            2 ** 100,
            0,
            0,
            1,
            BIG,
            1e4,
            2 ** 100,
            112_589_990_684_262_400,
            1,
            126_765_060_022_822_940_149_670_320,
            11_258_999_068_426,
            0,
            2_702_159_776_421
        );
    }

    /// @dev Step-2 tie at an extreme cap: floor(c0·r1/r0) equals c1 exactly while the division
    ///      leaves a remainder (1e30·2000 mod 3000 = 2000). Step 2 keeps the token0 branch
    ///      (`>` not `>=`), so token0's target is the cap 1e30; the token1 branch would give
    ///      floor(c1·3000/2000) = 1e30 − 1 (C7 mutant).
    function _caseTie() internal pure returns (Case memory) {
        return Case(
            3000,
            2000,
            0,
            0,
            BIG,
            666_666_666_666_666_666_666_666_666_666,
            3000,
            2000,
            2449,
            BIG,
            666_666_666_666_666_666_666_666_666_666,
            816_333_333_333_333_333_333_333_333_332,
            1,
            0
        );
    }

    function _runOk(Case memory c, bool t1First) internal {
        _build(c.a0, c.a1, c.swapDir, c.swapAmt);
        (uint256 r0, uint256 r1) = pool.getReserves();
        assertEq(r0, c.r0, "model r0");
        assertEq(r1, c.r1, "model r1");
        assertEq(pool.totalSupply(), c.S, "model S");

        // (c) maxExcess = u - 1 on a side with u > 0 reverts with no state change.
        if (c.u0 > 0) {
            _expectRevertNoChange(
                _params(c.c0, c.c1, t1First, c.u0 - 1, MAX), AMMPool.ExcessContributionTooHigh.selector
            );
        }
        if (c.u1 > 0) {
            _expectRevertNoChange(
                _params(c.c0, c.c1, t1First, MAX, c.u1 - 1), AMMPool.ExcessContributionTooHigh.selector
            );
        }

        // (a) exactly one transferFrom per token with the step-2 target. Registered after the
        //     reverting attempts above, so only the successful call below is counted.
        vm.expectCall(address(t0), abi.encodeCall(IERC20.transferFrom, (bob, address(pool), c.tgt0)), 1);
        vm.expectCall(address(t1), abi.encodeCall(IERC20.transferFrom, (bob, address(pool), c.tgt1)), 1);
        vm.recordLogs();
        vm.prank(bob);
        // (c) maxExcess = u exactly passes.
        (uint256 n0, uint256 n1, uint256 s) = pool.addLiquidity(_params(c.c0, c.c1, t1First, c.u0, c.u1));
        _assertPullOrder(vm.getRecordedLogs(), t1First, c.tgt0, c.tgt1);

        assertEq(n0, c.tgt0, "net0 = target0 (Tier 0)");
        assertEq(n1, c.tgt1, "net1 = target1 (Tier 0)");
        assertEq(s, c.sigma, "sigma");
        // u recomputed from the call's own outputs with the independent ceil
        assertEq(n0 - MulDiv512.ceilMulDiv(s, c.r0, c.S), c.u0, "u0");
        assertEq(n1 - MulDiv512.ceilMulDiv(s, c.r1, c.S), c.u1, "u1");
        _assertBound(c.u0, c.r0, c.r1, c.S);
        _assertBound(c.u1, c.r1, c.r0, c.S);
        (uint256 rr0, uint256 rr1) = pool.getReserves();
        assertEq(rr0, c.r0 + c.tgt0, "reserve0 += net0 (X1)");
        assertEq(rr1, c.r1 + c.tgt1, "reserve1 += net1 (X1)");
        assertEq(pool.balanceOf(bob), c.sigma, "bob LP");
    }

    function test_F1T1_caseA_token0First() public {
        _runOk(_caseA(), false);
    }

    function test_F1T1_caseA_token1First() public {
        _runOk(_caseA(), true);
    }

    function test_F1T1_caseB_token0First() public {
        _runOk(_caseB(), false);
    }

    function test_F1T1_caseB_token1First() public {
        _runOk(_caseB(), true);
    }

    function test_F1T1_caseC_p3State_token0First() public {
        _runOk(_caseC(), false);
    }

    function test_F1T1_caseC_p3State_token1First() public {
        _runOk(_caseC(), true);
    }

    function test_F1T1_caseD_mirror_token0First() public {
        _runOk(_caseD(), false);
    }

    function test_F1T1_caseD_mirror_token1First() public {
        _runOk(_caseD(), true);
    }

    function test_F1T1_caseE_wideRatio_token0First() public {
        _runOk(_caseE(), false);
    }

    function test_F1T1_caseE_wideRatio_token1First() public {
        _runOk(_caseE(), true);
    }

    function test_F1T1_caseF_wideRatio_token0First() public {
        _runOk(_caseF(), false);
    }

    function test_F1T1_caseF_wideRatio_token1First() public {
        _runOk(_caseF(), true);
    }

    function test_F1T1_step2TieAtExtremeCap_token0First() public {
        _runOk(_caseTie(), false);
    }

    function test_F1T1_step2TieAtExtremeCap_token1First() public {
        _runOk(_caseTie(), true);
    }

    /// @dev The opposite extreme request in each shape floors one step-2 target to 0
    ///      (Python model: InsufficientDepositAmount): revert before any transfer, both orders.
    function test_F1T1_oppositeCapsRevertBeforeAnyTransfer() public {
        Case[6] memory cs = [_caseA(), _caseB(), _caseC(), _caseD(), _caseE(), _caseF()];
        for (uint256 i; i < 6; ++i) {
            Case memory c = cs[i];
            _build(c.a0, c.a1, c.swapDir, c.swapAmt);
            // No transferFrom with bob as `from` on these tokens (prefix match; seeding by
            // alice does not match).
            vm.expectCall(address(t0), abi.encodeWithSelector(IERC20.transferFrom.selector, bob), 0);
            vm.expectCall(address(t1), abi.encodeWithSelector(IERC20.transferFrom.selector, bob), 0);
            for (uint256 o; o < 2; ++o) {
                // the caps swapped: the extreme request that the model rejects
                _expectRevertNoChange(_params(c.c1, c.c0, o == 1, MAX, MAX), AMMPool.InsufficientDepositAmount.selector);
            }
        }
    }

    // ------------------------------------------------------------------
    // Fuzz: (a), (b), (c) against the independent MulDiv512 oracle
    // ------------------------------------------------------------------

    struct F {
        uint256 a0;
        uint256 a1;
        uint8 swapDir;
        uint256 swapAmt;
        uint256 c0;
        uint256 c1;
        uint8 mode;
        bool t1First;
    }

    struct Pred {
        uint256 tgt0;
        uint256 tgt1;
        uint256 sigma;
        uint256 u0;
        uint256 u1;
    }

    /// @dev Step 2 and σ from the documented rule (ARCHITECTURE §6.2, DECISIONS M8-12), with
    ///      MulDiv512 only. tgt = 0 on a side that floors to 0; sigma = 0 if σ floors to 0.
    function _predict(uint256 r0, uint256 r1, uint256 S, uint256 c0, uint256 c1) internal pure returns (Pred memory p) {
        (bool over, uint256 q) = MulDiv512.floorMulDiv(c0, r1, r0);
        if (!over && q <= c1) {
            (p.tgt0, p.tgt1) = (c0, q);
        } else {
            (, q) = MulDiv512.floorMulDiv(c1, r0, r1);
            (p.tgt0, p.tgt1) = (q, c1);
        }
        if (p.tgt0 == 0 || p.tgt1 == 0) return p;
        (, uint256 s0) = MulDiv512.floorMulDiv(p.tgt0, S, r0);
        (, uint256 s1) = MulDiv512.floorMulDiv(p.tgt1, S, r1);
        p.sigma = s0 < s1 ? s0 : s1;
        if (p.sigma == 0) return p;
        p.u0 = p.tgt0 - MulDiv512.ceilMulDiv(p.sigma, r0, S);
        p.u1 = p.tgt1 - MulDiv512.ceilMulDiv(p.sigma, r1, S);
    }

    function testFuzz_F1T1_extremeRequest(F memory f) public {
        f.a0 = bound(f.a0, 1e3, 2 ** 120);
        f.a1 = bound(f.a1, 1e3, 2 ** 120);
        vm.assume(_isqrt(f.a0 * f.a1) > 1000);
        f.swapDir = uint8(bound(f.swapDir, 0, 2));
        f.swapAmt = bound(f.swapAmt, 1, 2 ** 120);
        // Mode 0/1: one cap tiny [1, 1e3], the other huge [1e27, 1e30]; mode 2: both [1, 1e30].
        f.mode = uint8(bound(f.mode, 0, 2));
        if (f.mode == 0) {
            f.c0 = bound(f.c0, 1e27, BIG);
            f.c1 = bound(f.c1, 1, 1e3);
        } else if (f.mode == 1) {
            f.c0 = bound(f.c0, 1, 1e3);
            f.c1 = bound(f.c1, 1e27, BIG);
        } else {
            f.c0 = bound(f.c0, 1, BIG);
            f.c1 = bound(f.c1, 1, BIG);
        }
        _buildFuzz(f);
        (uint256 r0, uint256 r1) = pool.getReserves();
        uint256 S = pool.totalSupply();
        Pred memory p = _predict(r0, r1, S, f.c0, f.c1);

        if (p.tgt0 == 0 || p.tgt1 == 0) {
            vm.expectCall(address(t0), abi.encodeWithSelector(IERC20.transferFrom.selector, bob), 0);
            vm.expectCall(address(t1), abi.encodeWithSelector(IERC20.transferFrom.selector, bob), 0);
            _expectRevertNoChange(_params(f.c0, f.c1, f.t1First, MAX, MAX), AMMPool.InsufficientDepositAmount.selector);
            return;
        }
        if (p.sigma == 0) {
            _expectRevertNoChange(_params(f.c0, f.c1, f.t1First, MAX, MAX), AMMPool.InsufficientShares.selector);
            return;
        }
        // (b) on the oracle's u (a mathematical claim about the documented algorithm) ...
        _assertBound(p.u0, r0, r1, S);
        _assertBound(p.u1, r1, r0, S);
        // ... and (c), which ties the Pool's own u to it: u − 1 reverts, u passes.
        if (p.u0 > 0) {
            _expectRevertNoChange(
                _params(f.c0, f.c1, f.t1First, p.u0 - 1, MAX), AMMPool.ExcessContributionTooHigh.selector
            );
        }
        if (p.u1 > 0) {
            _expectRevertNoChange(
                _params(f.c0, f.c1, f.t1First, MAX, p.u1 - 1), AMMPool.ExcessContributionTooHigh.selector
            );
        }

        vm.expectCall(address(t0), abi.encodeCall(IERC20.transferFrom, (bob, address(pool), p.tgt0)), 1);
        vm.expectCall(address(t1), abi.encodeCall(IERC20.transferFrom, (bob, address(pool), p.tgt1)), 1);
        vm.recordLogs();
        vm.prank(bob);
        (uint256 n0, uint256 n1, uint256 s) = pool.addLiquidity(_params(f.c0, f.c1, f.t1First, p.u0, p.u1));
        _assertPullOrder(vm.getRecordedLogs(), f.t1First, p.tgt0, p.tgt1);
        assertEq(n0, p.tgt0, "net0");
        assertEq(n1, p.tgt1, "net1");
        assertEq(s, p.sigma, "sigma");
        (uint256 rr0, uint256 rr1) = pool.getReserves();
        assertEq(rr0, r0 + n0, "reserve0 += net0");
        assertEq(rr1, r1 + n1, "reserve1 += net1");
    }

    function _buildFuzz(F memory f) internal {
        _build(f.a0, f.a1, 0, 0);
        if (f.swapDir == 0) return;
        address tin = f.swapDir == 1 ? address(t0) : address(t1);
        if (pool.getAmountOut(tin, f.swapAmt) == 0) return; // the swap would revert: keep the no-swap state
        vm.prank(alice);
        pool.swapExactInput(tin, f.swapAmt, 0, alice, block.timestamp);
    }

    function _isqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
