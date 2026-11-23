// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Wide512} from "./Wide512.sol";

/// @title MulDiv512 — independent floor/ceil(x·y/d) for test oracles (TEST_MATRIX §11.1).
/// @notice TEST-ONLY. Exact 512-bit product (`Wide512`) and bitwise long division, so the
///         expected values do not reuse OpenZeppelin's `Math.mulDiv` (the code under test).
///         Same algorithm as the private oracles in the M4H/M8 differential tests.
library MulDiv512 {
    /// @return over True when the quotient does not fit in uint256 (hi ≥ d).
    /// @return q floor(x·y/d) when it fits, else 0.
    function floorMulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (bool over, uint256 q) {
        (uint256 hi, uint256 lo) = Wide512.mul(x, y);
        if (hi >= d) return (true, 0);
        if (hi == 0) return (false, lo / d);
        uint256 rem = hi; // invariant: rem < d
        for (uint256 i; i < 256; ++i) {
            bool carry = rem >> 255 == 1;
            rem = (rem << 1) | ((lo >> (255 - i)) & 1);
            q <<= 1;
            if (carry || rem >= d) {
                unchecked {
                    rem -= d; // exact modulo 2^256 because the true remainder is < 2d
                }
                q |= 1;
            }
        }
    }

    /// @dev ceil(x·y/d); the caller guarantees that the quotient fits.
    function ceilMulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 q) {
        bool over;
        (over, q) = floorMulDiv(x, y, d);
        require(!over, "MulDiv512: quotient overflow");
        (uint256 qh, uint256 ql) = Wide512.mul(q, d);
        (uint256 ph, uint256 pl) = Wide512.mul(x, y);
        if (qh != ph || ql != pl) q += 1;
    }
}
