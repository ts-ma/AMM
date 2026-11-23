// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {AMMPool} from "./AMMPool.sol";

/// @title AMMFactory — deploys and registers at most one AMMPool per unordered token pair.
/// @notice Ownerless (D10): no owner, no setter, no payable entry point, no token-withdrawal
///         function. Holds no user funds. Every Pool it creates shares one immutable
///         `surplusRecipient` (DECISIONS M7-1).
/// @dev Specification: docs/ARCHITECTURE.md §8; decisions: docs/DECISIONS.md §14 (M7-1 … M7-8).
///      The Pool neither reads nor trusts the Factory (M7-3): authenticity of a Pool is verified
///      through this registry (`getPair(token0, token1) == pool`), not through the Pool itself.
/// @custom:report docs/REPORT.md §4.1
contract AMMFactory {
    /// @notice Surplus destination passed to every Pool this Factory creates (M7-1).
    /// @dev Immutable: a wrong value cannot be repaired; the only remedy is a new Factory, and
    ///      Pools of the old Factory are not migrated (THREAT_MODEL T11, limitation 14).
    address public immutable surplusRecipient;

    /// @notice Pool for a token pair; registered under both orderings, 0 if none exists.
    mapping(address tokenA => mapping(address tokenB => address pool)) public getPair;

    /// @notice Every Pool created, in creation order (U11).
    address[] public allPairs;

    /// @notice Emitted once per created Pool.
    /// @param token0 Lower token address (sorted).
    /// @param token1 Higher token address (sorted).
    /// @param pool The new Pool.
    /// @param pairCount `allPairs.length` after registering this Pool.
    event PairCreated(address indexed token0, address indexed token1, address pool, uint256 pairCount);

    /// @notice A token address is zero.
    error ZeroAddress();
    /// @notice Both token addresses are equal.
    error IdenticalTokens();
    /// @notice A token address has no deployed code (DECISIONS M7-2).
    error TokenHasNoCode();
    /// @notice The pair already has a Pool in this Factory (either ordering).
    error PairExists();
    /// @notice Constructor recipient is zero or the Factory itself.
    error InvalidSurplusRecipient();

    /// @param surplusRecipient_ Shared surplus destination. Must be fixed explicitly and checked
    ///        before deployment so that it can receive **and withdraw** the expected ERC-20 tokens
    ///        (ARCHITECTURE §8). The Factory only rejects `address(0)` and itself (it has no
    ///        withdrawal function, so surplus sent here would be locked forever); each Pool's
    ///        constructor additionally rejects `token0`, `token1` and the Pool (A3).
    constructor(address surplusRecipient_) {
        if (surplusRecipient_ == address(0) || surplusRecipient_ == address(this)) {
            revert InvalidSurplusRecipient();
        }
        surplusRecipient = surplusRecipient_;
    }

    /// @notice Deploy and register the Pool for `tokenA` / `tokenB` (any order).
    /// @dev Check order (DECISIONS M7-4): zero first (so `(0, 0)` reports ZeroAddress, as M2-3),
    ///      then identical, then sort, then code existence, then uniqueness.
    ///      Code-existence check (M7-2) is a fail-fast against mistyped addresses, done only here
    ///      (the M2 Pool constructor is unchanged). Limits: code does not prove ERC-20 compliance
    ///      or safety, and a pair cannot be created in advance for a token not yet deployed. No external call is made: the only code
    ///      executed by `new` is the AMMPool constructor, which calls no contract, so nothing can
    ///      re-enter between the creation and the registry writes / event, and no guard is needed
    ///      (`forge lint` `reentrancy-events` counts the creation as a call; accepted, M7-4).
    ///      The Pool's own constructor checks still run and may revert (e.g. a token equal to
    ///      `surplusRecipient` → `AMMPool.InvalidSurplusRecipient`).
    /// @return pool The new Pool's address.
    /// @custom:report docs/REPORT.md §4.1
    function createPair(address tokenA, address tokenB) external returns (address pool) {
        if (tokenA == address(0) || tokenB == address(0)) revert ZeroAddress();
        if (tokenA == tokenB) revert IdenticalTokens();
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0.code.length == 0 || token1.code.length == 0) revert TokenHasNoCode();
        if (getPair[token0][token1] != address(0)) revert PairExists();

        pool = address(new AMMPool(token0, token1, surplusRecipient));

        getPair[token0][token1] = pool;
        getPair[token1][token0] = pool;
        allPairs.push(pool);
        emit PairCreated(token0, token1, pool, allPairs.length);
    }

    /// @notice Number of Pools created so far.
    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }
}
