// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title AMMMath — pure constant-product maths for AMMPool.
/// @notice Swap quote with a fixed 30 bps LP fee (U1) and initial-share square root (D5).
/// @dev All functions are `internal pure`: the compiler inlines them into the calling
///      contract, so the library is never deployed or linked separately.
///      Formulas: docs/ARCHITECTURE.md §6.1, §6.4; input ranges: §6.6; conventions: DECISIONS M2-5.
///      Arithmetic is Solidity 0.8 checked arithmetic: an overflow reverts with Panic(0x11)
///      and never returns a wrong value.
library AMMMath {
    /// @notice Swap fee in basis points, 100% retained by LPs (U1, D8).
    uint256 internal constant FEE_BPS = 30;
    /// @notice Basis-point denominator (U1).
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    /// @dev Share of the input that is priced: 10_000 − 30 = 9_970.
    uint256 internal constant FEE_MULTIPLIER = BPS_DENOMINATOR - FEE_BPS;

    /// @notice The input amount is zero.
    error InsufficientInputAmount();
    /// @notice At least one reserve is zero, so no price exists.
    error InsufficientLiquidity();

    /// @notice Output of an exact-input swap (ARCHITECTURE §6.4).
    /// @dev out = floor(a·9970·rOut / (rIn·10000 + a·9970)).
    ///      Rounds down, in favour of the Pool. Because a·9970 / (rIn·10000 + a·9970) < 1
    ///      whenever rIn > 0, the result is always strictly below `reserveOut`.
    ///      Reverts (in this order): a == 0; either reserve == 0; Panic(0x11) if
    ///      a·9970 or rIn·10000 + a·9970 exceeds 2^256 − 1 (ARCHITECTURE §6.6).
    ///      A floored result of 0 is RETURNED, not reverted (DECISIONS M2-5r, ADR-021), e.g.
    ///      reference case 3 (1 unit into a 1,000/1,000 Pool). Any caller that transfers
    ///      tokens — `swapExactInput` (M5) — must itself revert when the result is 0.
    ///      `mulDiv` computes the a·9970·rOut product in 512 bits, so that product never overflows.
    /// @param amountIn Net amount received by the Pool (`a`).
    /// @param reserveIn Recorded reserve of the input token before the swap (`rIn`).
    /// @param reserveOut Recorded reserve of the output token before the swap (`rOut`).
    /// @return amountOut Amount the Pool would send out (`out`), 0 ≤ out < reserveOut.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert InsufficientInputAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

        uint256 amountInWithFee = amountIn * FEE_MULTIPLIER;
        uint256 denominator = reserveIn * BPS_DENOMINATOR + amountInWithFee;
        amountOut = Math.mulDiv(amountInWithFee, reserveOut, denominator);
    }

    /// @notice Gross LP shares for the first deposit: floor(sqrt(net0 · net1)) (ARCHITECTURE §6.1).
    /// @dev Value before the 1,000-unit lock is subtracted (that step belongs to M3).
    ///      Returns 0 if either input is 0; callers validate. Panic(0x11) if net0 · net1 ≥ 2^256.
    function initialShares(uint256 net0, uint256 net1) internal pure returns (uint256) {
        return Math.sqrt(net0 * net1);
    }
}
