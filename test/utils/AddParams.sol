// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IAMMPool} from "../../src/interfaces/IAMMPool.sol";

/// @notice Test helpers that build `IAMMPool.AddLiquidityParams` (DECISIONS M8-8).
/// @dev Migration rule (TEST_MATRIX §3.3): an old call
///      `addLiquidity(a0, a1, 0, 0, minShares, to, deadline)` becomes
///      `addLiquidity(addParams(a0, a1, minShares, to, deadline))`. `maxDebit` and `maxExcess`
///      are unbounded and token0 is pulled first, which reproduces the pre-M8 behaviour for
///      Tier 0 tokens exactly: the same pull order, the same targets (step 2 unchanged), net =
///      target so no re-plan, and the same shares. The old tolerance check `[T, T + 1]` never
///      fired for a Tier 0 token, and the old Pool already put the measured net into the reserves.
function addParams(uint256 a0, uint256 a1, uint256 minShares, address to, uint256 deadline)
    pure
    returns (IAMMPool.AddLiquidityParams memory)
{
    return addParamsOrdered(a0, a1, minShares, to, deadline, false);
}

/// @notice Same as `addParams` with an explicit pull order.
function addParamsOrdered(uint256 a0, uint256 a1, uint256 minShares, address to, uint256 deadline, bool token1First)
    pure
    returns (IAMMPool.AddLiquidityParams memory)
{
    return IAMMPool.AddLiquidityParams({
        amount0RequestMax: a0,
        amount1RequestMax: a1,
        maxDebit0: type(uint256).max,
        maxDebit1: type(uint256).max,
        maxExcess0: type(uint256).max,
        maxExcess1: type(uint256).max,
        minShares: minShares,
        recipient: to,
        deadline: deadline,
        token1First: token1First
    });
}
