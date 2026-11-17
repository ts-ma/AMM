// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {AMMMath} from "./libraries/AMMMath.sol";

/// @title AMMPool — two-token constant-product Pool (skeleton, milestone M2).
/// @notice Ownerless (D10): no admin, no setter, no privileged role. The deployer is not recorded.
/// @dev M2 scope (DECISIONS M2-8): constructor checks, immutables, recorded reserves and
///      `getReserves`. Liquidity, swap, LP token, `sync` and `skim` are added in later
///      milestones; until then no function writes the reserves.
///      Specification: docs/ARCHITECTURE.md §4, §5, §7.1, §7.6.
contract AMMPool {
    /// @notice Swap fee in basis points, retained 100% by LPs (U1). Re-exposed from AMMMath.
    uint256 public constant FEE_BPS = AMMMath.FEE_BPS;
    /// @notice Basis-point denominator (U1). Re-exposed from AMMMath.
    uint256 public constant BPS_DENOMINATOR = AMMMath.BPS_DENOMINATOR;

    /// @notice Lower-addressed token of the pair (token0 < token1).
    address public immutable token0;
    /// @notice Higher-addressed token of the pair.
    address public immutable token1;
    /// @notice Sole destination of surplus (balance above reserve) sent by `skim()` (Gate R=(b), U3).
    /// @dev Has no privileged function; it is only an economic beneficiary (THREAT_MODEL T11, T12).
    address public immutable surplusRecipient;

    /// @dev Recorded reserves: the last accepted accounting state, NOT necessarily equal to
    ///      `balanceOf(this)` (ARCHITECTURE §5.1). Writers are exactly the functions listed in
    ///      ARCHITECTURE §5.2; in M2 there are none, so both stay 0.
    uint256 private reserve0;
    uint256 private reserve1;

    /// @notice A token address is zero.
    error ZeroAddress();
    /// @notice Both token addresses are equal.
    error IdenticalTokens();
    /// @notice token0 is not strictly below token1.
    error TokensNotSorted();
    /// @notice surplusRecipient is address(0), token0, token1, or this Pool.
    error InvalidSurplusRecipient();

    /// @param token0_ Lower token address; the caller (later: the Factory) must sort (DECISIONS M2-2).
    /// @param token1_ Higher token address.
    /// @param surplusRecipient_ Immutable surplus destination.
    /// @dev Check order (DECISIONS M2-3): zero first, so a zero token is always reported as
    ///      ZeroAddress whichever position it is in. The four recipient checks (A3) catch only
    ///      these obvious mistakes; a wrong-but-valid address cannot be detected and is permanent.
    constructor(address token0_, address token1_, address surplusRecipient_) {
        if (token0_ == address(0) || token1_ == address(0)) revert ZeroAddress();
        if (token0_ == token1_) revert IdenticalTokens();
        if (token0_ > token1_) revert TokensNotSorted();
        if (
            surplusRecipient_ == address(0) || surplusRecipient_ == token0_ || surplusRecipient_ == token1_
                || surplusRecipient_ == address(this)
        ) revert InvalidSurplusRecipient();

        token0 = token0_;
        token1 = token1_;
        surplusRecipient = surplusRecipient_;
    }

    /// @notice Recorded reserves (ARCHITECTURE §7.6). These are accounting values, not live
    ///         balances: tokens sent directly to the Pool do not change them.
    /// @return Recorded reserve of token0.
    /// @return Recorded reserve of token1.
    function getReserves() external view returns (uint256, uint256) {
        return (reserve0, reserve1);
    }
}
