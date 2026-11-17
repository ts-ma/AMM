// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test, stdError} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AMMMath} from "../src/libraries/AMMMath.sol";
import {AMMMathHarness} from "./harness/AMMMathHarness.sol";
import {Wide512} from "./utils/Wide512.sol";

/// @notice Tests for AMMMath (TEST_MATRIX S02, S03 (maths part), S11/S15 (maths part),
///         S14, Z01 (maths part), Z06 (pure), and the §11.1 test design).
/// @dev Expected values never come from AMMMath itself: the classifier and all property
///      checks are computed independently, with 512-bit products (Wide512) so that the
///      test-side arithmetic cannot overflow.
contract AMMMathTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    // Independent copies of the U1 parameters (deliberately not read from AMMMath).
    uint256 internal constant D = 10_000;
    uint256 internal constant FEE_MUL = 9_970;
    uint256 internal constant FUZZ_MAX = 2 ** 112; // ARCHITECTURE §6.6 fuzz range

    enum Outcome {
        Success,
        ZeroInput,
        ZeroLiquidity,
        Overflow,
        ZeroOutput
    }

    AMMMathHarness internal harness;

    function setUp() public {
        harness = new AMMMathHarness();
    }

    // ------------------------------------------------------------------
    // Independent helpers
    // ------------------------------------------------------------------

    /// @dev x1·y1 < x2·y2, exact in 512 bits.
    function _mulLt(uint256 x1, uint256 y1, uint256 x2, uint256 y2) internal pure returns (bool) {
        (uint256 h1, uint256 l1) = Wide512.mul(x1, y1);
        (uint256 h2, uint256 l2) = Wide512.mul(x2, y2);
        return Wide512.lt(h1, l1, h2, l2);
    }

    /// @dev x1·y1 ≤ x2·y2, exact in 512 bits.
    function _mulLte(uint256 x1, uint256 y1, uint256 x2, uint256 y2) internal pure returns (bool) {
        (uint256 h1, uint256 l1) = Wide512.mul(x1, y1);
        (uint256 h2, uint256 l2) = Wide512.mul(x2, y2);
        return Wide512.lte(h1, l1, h2, l2);
    }

    function _ceilDiv(uint256 x, uint256 y) internal pure returns (uint256) {
        return x / y + (x % y == 0 ? 0 : 1);
    }

    /// @dev Classifies (a, rIn, rOut) in the implementation's check order without calling
    ///      mulDiv and without any overflowing operation (TEST_MATRIX §11.1).
    function _classify(uint256 a, uint256 rIn, uint256 rOut) internal pure returns (Outcome) {
        if (a == 0) return Outcome.ZeroInput;
        if (rIn == 0 || rOut == 0) return Outcome.ZeroLiquidity;
        if (a > MAX / FEE_MUL) return Outcome.Overflow; // a·9970 overflows
        uint256 aFee = a * FEE_MUL;
        if (rIn > MAX / D) return Outcome.Overflow; // rIn·10000 overflows
        uint256 rInD = rIn * D;
        if (rInD > MAX - aFee) return Outcome.Overflow; // rIn·10000 + a·9970 overflows
        uint256 den = rInD + aFee;
        // out = floor(aFee·rOut / den) == 0  ⇔  aFee·rOut < den  (512-bit, cannot overflow)
        if (_mulLt(aFee, rOut, den, 1)) return Outcome.ZeroOutput;
        return Outcome.Success;
    }

    /// @dev Properties of a successful quote. Every product is formed in 512 bits:
    ///      den and rIn·D fit in uint256 because Success excludes overflow, and
    ///      out < rOut guarantees out + 1 ≤ rOut and rOut − out − 1 ≥ 0.
    function _assertSuccessProperties(uint256 a, uint256 rIn, uint256 rOut, uint256 out) internal pure {
        uint256 aFee = a * FEE_MUL;
        uint256 rInD = rIn * D;
        uint256 den = rInD + aFee;

        assertGt(out, 0, "out > 0");
        assertLt(out, rOut, "out < rOut");
        // Rounded down exactly: out·den ≤ aFee·rOut < (out + 1)·den.
        assertTrue(_mulLte(out, den, aFee, rOut), "floor lower: out*den <= aFee*rOut");
        assertTrue(_mulLt(aFee, rOut, out + 1, den), "floor upper: aFee*rOut < (out+1)*den");
        // §6.5 fee-adjusted invariant: (rIn·D + a·9970)·(rOut − out) ≥ rIn·rOut·D.
        assertTrue(_mulLte(rInD, rOut, den, rOut - out), "6.5 invariant holds for out");
        // Tightness: out + 1 violates §6.5, i.e. den·(rOut − out − 1) < rIn·D·rOut.
        assertTrue(_mulLt(den, rOut - out - 1, rInD, rOut), "6.5 invariant fails for out + 1");
    }

    /// @dev Calls the implementation and checks it behaves exactly as classified.
    function _checkAgainstClassifier(uint256 a, uint256 rIn, uint256 rOut) internal {
        Outcome expected = _classify(a, rIn, rOut);
        if (expected == Outcome.Success) {
            _assertSuccessProperties(a, rIn, rOut, harness.getAmountOut(a, rIn, rOut));
            return;
        }
        if (expected == Outcome.ZeroInput) vm.expectRevert(AMMMath.InsufficientInputAmount.selector);
        else if (expected == Outcome.ZeroLiquidity) vm.expectRevert(AMMMath.InsufficientLiquidity.selector);
        else if (expected == Outcome.ZeroOutput) vm.expectRevert(AMMMath.InsufficientOutputAmount.selector);
        else vm.expectRevert(stdError.arithmeticError);
        harness.getAmountOut(a, rIn, rOut);
    }

    // ------------------------------------------------------------------
    // Constants (U1)
    // ------------------------------------------------------------------

    function test_feeConstants() public view {
        assertEq(harness.feeBps(), 30);
        assertEq(harness.bpsDenominator(), 10_000);
    }

    // ------------------------------------------------------------------
    // Reference cases, ARCHITECTURE §6.7 (S02, S14, S03 maths part)
    // ------------------------------------------------------------------

    function test_S02_referenceCase1() public view {
        uint256 out = harness.getAmountOut(10_000, 1_000_000, 1_000_000);
        assertEq(out, 9_871);
        _assertSuccessProperties(10_000, 1_000_000, 1_000_000, out);
    }

    function test_S14_referenceCase2_largeTrade() public view {
        uint256 out = harness.getAmountOut(1_000_000, 1_000_000, 1_000_000);
        assertEq(out, 499_248);
        _assertSuccessProperties(1_000_000, 1_000_000, 1_000_000, out);
    }

    function test_S03_referenceCase3_zeroOutputReverts() public {
        assertEq(uint256(_classify(1, 1_000, 1_000)), uint256(Outcome.ZeroOutput));
        vm.expectRevert(AMMMath.InsufficientOutputAmount.selector);
        harness.getAmountOut(1, 1_000, 1_000);
    }

    function test_S14_referenceCase4_18to6Decimals() public view {
        uint256 out = harness.getAmountOut(1e18, 1_000e18, 2_000e6);
        assertEq(out, 1_992_013);
        _assertSuccessProperties(1e18, 1_000e18, 2_000e6, out);
    }

    function test_S14_referenceCase5_6to18Decimals() public view {
        uint256 out = harness.getAmountOut(1e6, 2_000e6, 1_000e18);
        assertEq(out, 498_251_621_566_649_025);
        _assertSuccessProperties(1e6, 2_000e6, 1_000e18, out);
    }

    // ------------------------------------------------------------------
    // Zero inputs and check order (S03 maths part)
    // ------------------------------------------------------------------

    function test_S03_zeroInputReverts() public {
        vm.expectRevert(AMMMath.InsufficientInputAmount.selector);
        harness.getAmountOut(0, 1_000, 1_000);
    }

    function test_S03_zeroReserveInReverts() public {
        vm.expectRevert(AMMMath.InsufficientLiquidity.selector);
        harness.getAmountOut(1_000, 0, 1_000);
    }

    function test_S03_zeroReserveOutReverts() public {
        vm.expectRevert(AMMMath.InsufficientLiquidity.selector);
        harness.getAmountOut(1_000, 1_000, 0);
    }

    function test_checkOrder_zeroInputBeforeZeroReserves() public {
        vm.expectRevert(AMMMath.InsufficientInputAmount.selector);
        harness.getAmountOut(0, 0, 0);
    }

    function test_checkOrder_zeroReserveBeforeOverflow() public {
        // a = MAX would overflow, but the zero-reserve check comes first.
        vm.expectRevert(AMMMath.InsufficientLiquidity.selector);
        harness.getAmountOut(MAX, 0, 1);
    }

    // ------------------------------------------------------------------
    // Overflow boundaries, ARCHITECTURE §6.6 (Z06, pure part)
    // ------------------------------------------------------------------

    /// a·9970 overflows just above ⌊MAX/9970⌋.
    function test_Z06_amountInTimesFee_overflowBoundary() public {
        vm.expectRevert(stdError.arithmeticError);
        harness.getAmountOut(MAX / FEE_MUL + 1, 1, 1);
    }

    /// Denominator rIn·10000 + a·9970: largest a that fits succeeds, a + 1 panics.
    function test_Z06_denominator_amountInBoundary() public {
        uint256 rIn = 1e18;
        uint256 rOut = 1e18;
        uint256 aMax = (MAX - rIn * D) / FEE_MUL;
        assertEq(uint256(_classify(aMax, rIn, rOut)), uint256(Outcome.Success));
        _assertSuccessProperties(aMax, rIn, rOut, harness.getAmountOut(aMax, rIn, rOut));

        assertEq(uint256(_classify(aMax + 1, rIn, rOut)), uint256(Outcome.Overflow));
        vm.expectRevert(stdError.arithmeticError);
        harness.getAmountOut(aMax + 1, rIn, rOut);
    }

    /// Denominator: largest rIn that fits succeeds, rIn + 1 panics.
    function test_Z06_denominator_reserveInBoundary() public {
        uint256 a = 1;
        uint256 rOut = MAX; // keeps out > 0 at this extreme
        uint256 rInMax = (MAX - FEE_MUL) / D;
        assertEq(uint256(_classify(a, rInMax, rOut)), uint256(Outcome.Success));
        _assertSuccessProperties(a, rInMax, rOut, harness.getAmountOut(a, rInMax, rOut));

        assertEq(uint256(_classify(a, rInMax + 1, rOut)), uint256(Outcome.Overflow));
        vm.expectRevert(stdError.arithmeticError);
        harness.getAmountOut(a, rInMax + 1, rOut);
    }

    /// The a·9970·rOut product exceeds 2^256 here; mulDiv must still return the exact floor.
    function test_Z06_wideNumeratorStillExact() public view {
        uint256 a = 2 ** 200;
        uint256 rIn = 2 ** 200;
        uint256 rOut = 2 ** 200;
        _assertSuccessProperties(a, rIn, rOut, harness.getAmountOut(a, rIn, rOut));
    }

    // ------------------------------------------------------------------
    // Fuzz, TEST_MATRIX §11.1
    // ------------------------------------------------------------------

    /// Class A — success. Inputs constructed so that out ≥ 1:
    /// out ≥ 1 ⇔ a·9970·rOut ≥ rIn·10000 + a·9970 ⇔ a·9970·(rOut − 1) ≥ rIn·10000.
    function testFuzz_getAmountOut_A_success(uint256 rIn, uint256 rOut, uint256 a) public view {
        rIn = bound(rIn, 1, FUZZ_MAX);
        rOut = bound(rOut, 2, FUZZ_MAX);
        uint256 aMin = _ceilDiv(rIn * D, FEE_MUL * (rOut - 1));
        a = bound(a, aMin, aMin > FUZZ_MAX ? aMin : FUZZ_MAX);

        assertEq(uint256(_classify(a, rIn, rOut)), uint256(Outcome.Success));
        _assertSuccessProperties(a, rIn, rOut, harness.getAmountOut(a, rIn, rOut));
    }

    /// Class B — zero output. Either rOut = 1 (out < rOut forces 0), or
    /// rIn·10000 > 9970·(rOut − 1) so that aMin ≥ 2, and a ∈ [1, aMin − 1].
    function testFuzz_getAmountOut_B_zeroOutputReverts(uint256 rIn, uint256 rOut, uint256 a) public {
        rOut = bound(rOut, 1, FUZZ_MAX);
        if (rOut == 1) {
            rIn = bound(rIn, 1, FUZZ_MAX);
            a = bound(a, 1, FUZZ_MAX);
        } else {
            uint256 rInMin = (FEE_MUL * (rOut - 1)) / D + 1;
            rIn = bound(rIn, rInMin, FUZZ_MAX);
            uint256 aMin = _ceilDiv(rIn * D, FEE_MUL * (rOut - 1));
            a = bound(a, 1, aMin - 1);
        }

        assertEq(uint256(_classify(a, rIn, rOut)), uint256(Outcome.ZeroOutput));
        vm.expectRevert(AMMMath.InsufficientOutputAmount.selector);
        harness.getAmountOut(a, rIn, rOut);
    }

    /// Class C — overflow. Three constructions, one per overflowing operation.
    function testFuzz_getAmountOut_C_overflowReverts(uint8 mode, uint256 a, uint256 rIn, uint256 rOut) public {
        rOut = bound(rOut, 1, MAX);
        mode = mode % 3;
        if (mode == 0) {
            // a·9970 overflows
            a = bound(a, MAX / FEE_MUL + 1, MAX);
            rIn = bound(rIn, 1, MAX);
        } else if (mode == 1) {
            // rIn·10000 overflows (a·9970 fits)
            a = bound(a, 1, MAX / FEE_MUL);
            rIn = bound(rIn, MAX / D + 1, MAX);
        } else {
            // both products fit, their sum overflows
            rIn = bound(rIn, 2 ** 200, MAX / D);
            a = bound(a, (MAX - rIn * D) / FEE_MUL + 1, MAX / FEE_MUL);
        }

        assertEq(uint256(_classify(a, rIn, rOut)), uint256(Outcome.Overflow));
        vm.expectRevert(stdError.arithmeticError);
        harness.getAmountOut(a, rIn, rOut);
    }

    /// Raw uint256 inputs (any class): implementation matches the independent classifier.
    function testFuzz_getAmountOut_matchesClassifier(uint256 a, uint256 rIn, uint256 rOut) public {
        _checkAgainstClassifier(a, rIn, rOut);
    }

    /// Same, within [0, 2^112] where success and zero output dominate.
    function testFuzz_getAmountOut_matchesClassifier_fuzzRange(uint256 a, uint256 rIn, uint256 rOut) public {
        _checkAgainstClassifier(bound(a, 0, FUZZ_MAX), bound(rIn, 0, FUZZ_MAX), bound(rOut, 0, FUZZ_MAX));
    }

    // ------------------------------------------------------------------
    // initialShares (ARCHITECTURE §6.1, Z06 pure part)
    // ------------------------------------------------------------------

    function test_initialShares_knownValues() public view {
        assertEq(harness.initialShares(0, 5), 0);
        assertEq(harness.initialShares(5, 0), 0);
        assertEq(harness.initialShares(1, 1), 1);
        assertEq(harness.initialShares(2, 2), 2);
        assertEq(harness.initialShares(3, 5), 3); // floor(sqrt(15))
        assertEq(harness.initialShares(4, 4), 4);
        assertEq(harness.initialShares(1e18, 4e18), 2e18);
        assertEq(harness.initialShares(2 ** 128 - 1, 2 ** 128 - 1), 2 ** 128 - 1);
        assertEq(harness.initialShares(MAX, 1), 2 ** 128 - 1);
    }

    function test_Z06_initialShares_overflowBoundary() public {
        vm.expectRevert(stdError.arithmeticError);
        harness.initialShares(2 ** 128, 2 ** 128); // product = 2^256
        vm.expectRevert(stdError.arithmeticError);
        harness.initialShares(MAX, 2);
    }

    function _checkInitialShares(uint256 net0, uint256 net1) internal {
        if (net0 != 0 && net1 > MAX / net0) {
            vm.expectRevert(stdError.arithmeticError);
            harness.initialShares(net0, net1);
            return;
        }
        uint256 p = net0 * net1;
        uint256 s = harness.initialShares(net0, net1);
        // s = floor(sqrt(p)) ⇔ s² ≤ p < (s + 1)². (s + 1)² can equal 2^256, so compare in 512 bits.
        assertTrue(_mulLte(s, s, p, 1), "s^2 <= p");
        assertTrue(_mulLt(p, 1, s + 1, s + 1), "p < (s+1)^2");
    }

    function testFuzz_initialShares_raw(uint256 net0, uint256 net1) public {
        _checkInitialShares(net0, net1);
    }

    function testFuzz_initialShares_noOverflowRange(uint256 net0, uint256 net1) public {
        _checkInitialShares(bound(net0, 0, 2 ** 128 - 1), bound(net1, 0, 2 ** 128 - 1));
    }

    // ------------------------------------------------------------------
    // Test helper self-checks (Wide512)
    // ------------------------------------------------------------------

    function test_Wide512_knownValues() public pure {
        (uint256 hi, uint256 lo) = Wide512.mul(MAX, MAX); // (2^256 − 1)² = (2^256 − 2)·2^256 + 1
        assertEq(hi, MAX - 1);
        assertEq(lo, 1);
        (hi, lo) = Wide512.mul(2 ** 128, 2 ** 128); // exactly 2^256
        assertEq(hi, 1);
        assertEq(lo, 0);
        (hi, lo) = Wide512.mul(0, MAX);
        assertEq(hi, 0);
        assertEq(lo, 0);
    }

    function testFuzz_Wide512_matchesOpenZeppelin(uint256 x, uint256 y) public pure {
        (uint256 hi, uint256 lo) = Wide512.mul(x, y);
        (uint256 ozHi, uint256 ozLo) = Math.mul512(x, y);
        assertEq(hi, ozHi);
        assertEq(lo, ozLo);
    }
}
