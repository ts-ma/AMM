// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/// @title Wide512 — exact 512-bit products for test assertions (TEST_MATRIX §11.1).
/// @notice TEST-ONLY. The product of two uint256 values is < 2^512, so representing it as
///         (hi, lo) with value = hi·2^256 + lo can never overflow. Used so that test-side
///         checks such as (out + 1)·den > aFee·rOut cannot themselves overflow.
/// @dev Schoolbook multiplication on 128-bit limbs, deliberately independent of
///      OpenZeppelin's Math.mul512/mulDiv (the code under test); cross-checked by fuzzing.
library Wide512 {
    uint256 private constant MASK128 = type(uint128).max;

    /// @return hi Upper 256 bits of x·y.
    /// @return lo Lower 256 bits of x·y.
    function mul(uint256 x, uint256 y) internal pure returns (uint256 hi, uint256 lo) {
        uint256 x0 = x & MASK128;
        uint256 x1 = x >> 128;
        uint256 y0 = y & MASK128;
        uint256 y1 = y >> 128;

        // Each partial product is < 2^256 (two values < 2^128).
        uint256 p00 = x0 * y0;
        uint256 p01 = x0 * y1;
        uint256 p10 = x1 * y0;
        uint256 p11 = x1 * y1;

        // x·y = p00 + (p01 + p10)·2^128 + p11·2^256.
        // Bits 128..255 plus carry; each term < 2^128, so mid < 3·2^128.
        uint256 mid = (p00 >> 128) + (p01 & MASK128) + (p10 & MASK128);
        // Left shift discards bits above 255 (shifts are not overflow-checked); those bits
        // are exactly the carry `mid >> 128` added to `hi` below.
        lo = (p00 & MASK128) | (mid << 128);
        // Mathematically < 2^256 because x·y < 2^512, so this checked sum cannot overflow.
        hi = p11 + (p01 >> 128) + (p10 >> 128) + (mid >> 128);
    }

    /// @return True iff (aHi, aLo) < (bHi, bLo) as 512-bit unsigned integers.
    function lt(uint256 aHi, uint256 aLo, uint256 bHi, uint256 bLo) internal pure returns (bool) {
        return aHi < bHi || (aHi == bHi && aLo < bLo);
    }

    /// @return True iff (aHi, aLo) ≤ (bHi, bLo) as 512-bit unsigned integers.
    function lte(uint256 aHi, uint256 aLo, uint256 bHi, uint256 bLo) internal pure returns (bool) {
        return !lt(bHi, bLo, aHi, aLo);
    }
}
