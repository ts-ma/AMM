// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/// @title IAMMPool — shared types of the AMM Pool's public interface (DECISIONS M8-8).
/// @notice Holds only the `addLiquidity` parameter struct, so the Pool, the Factory tests and a
///         future Router can name it. `AMMPool` does not inherit this interface; it declares no
///         function, so it adds nothing to the Pool's compiled ABI.
interface IAMMPool {
    /// @notice Parameters of `AMMPool.addLiquidity` (DECISIONS M8-8, M8-13; ARCHITECTURE §7.2).
    /// @param amount0RequestMax Cap on the token0 amount the Pool may request with `transferFrom`.
    ///        A cap, not a promise: on a later deposit step 2 and the re-plan may request less,
    ///        and the payer's actual debit may differ from the request (taxes, extra charges).
    ///        Must be > 0. On the initial deposit it is requested in full.
    /// @param amount1RequestMax Same for token1.
    /// @param maxDebit0 Largest accepted net decrease of `msg.sender`'s token0 balance over the
    ///        whole call (M8-3). The payer is always `msg.sender`; with a router, the router.
    /// @param maxDebit1 Same for token1.
    /// @param maxExcess0 Largest accepted unmatched token0 contribution `u0 = n0 − ceil(σ·r0/S)`,
    ///        in Pool-received units, which enters the reserves (X1, M8-2). No effect on the
    ///        initial deposit (u = 0 by definition).
    /// @param maxExcess1 Same for token1.
    /// @param minShares Smallest acceptable number of LP shares for `recipient`.
    /// @param recipient Receiver of the LP shares; not address(0) or the Pool (U7).
    /// @param deadline Last valid `block.timestamp` (inclusive).
    /// @param token1First Pull order (M8-12): false pulls token0 first, true pulls token1 first.
    ///        Changes only the order of the two transfers; results are always reported in
    ///        token0/token1 order.
    struct AddLiquidityParams {
        uint256 amount0RequestMax;
        uint256 amount1RequestMax;
        uint256 maxDebit0;
        uint256 maxDebit1;
        uint256 maxExcess0;
        uint256 maxExcess1;
        uint256 minShares;
        address recipient;
        uint256 deadline;
        bool token1First;
    }
}
