// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AMMMath} from "./libraries/AMMMath.sol";

/// @title AMMPool — two-token constant-product Pool; the contract is also its own LP token.
/// @notice Ownerless (D10): no admin, no setter, no privileged role. The deployer is not recorded.
/// @dev Implemented so far: constructor checks and immutables (M2), LP ERC-20 with supply
///      controls and the initial deposit with the permanent 1,000-unit lock (M3), Tier 0 later
///      deposits (M4). Withdrawal (M4), swap (M5), sync/skim (M6) follow.
///      Specification: docs/ARCHITECTURE.md §4, §5, §6.1, §6.2, §7.1, §7.2, §7.6, §7.9.
contract AMMPool is ERC20, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Swap fee in basis points, retained 100% by LPs (U1). Re-exposed from AMMMath.
    uint256 public constant FEE_BPS = AMMMath.FEE_BPS;
    /// @notice Basis-point denominator (U1). Re-exposed from AMMMath.
    uint256 public constant BPS_DENOMINATOR = AMMMath.BPS_DENOMINATOR;
    /// @notice LP units minted to the Pool itself on the first deposit and locked forever (U2, A5).
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    /// @notice Lower-addressed token of the pair (token0 < token1).
    address public immutable token0;
    /// @notice Higher-addressed token of the pair.
    address public immutable token1;
    /// @notice Sole destination of surplus (balance above reserve) sent by `skim()` (Gate R=(b), U3).
    /// @dev Has no privileged function; it is only an economic beneficiary (THREAT_MODEL T11, T12).
    address public immutable surplusRecipient;

    /// @dev Recorded reserves: the last accepted accounting state, NOT necessarily equal to
    ///      `balanceOf(this)` (ARCHITECTURE §5.1). Writers are exactly the functions listed in
    ///      ARCHITECTURE §5.2; so far only `addLiquidity` (initial and later deposits).
    uint256 private reserve0;
    uint256 private reserve1;

    /// @notice Emitted on every successful deposit (DECISIONS M3-4).
    /// @param sender Account whose tokens were pulled (`msg.sender`).
    /// @param recipient Account that received the LP shares.
    /// @param net0 Measured token0 increase of the Pool in this call.
    /// @param net1 Measured token1 increase of the Pool in this call.
    /// @param shares LP shares minted to `recipient` (excluding the 1,000 lock).
    event LiquidityAdded(address indexed sender, address indexed recipient, uint256 net0, uint256 net1, uint256 shares);

    /// @notice A token address is zero.
    error ZeroAddress();
    /// @notice Both token addresses are equal.
    error IdenticalTokens();
    /// @notice token0 is not strictly below token1.
    error TokensNotSorted();
    /// @notice surplusRecipient is address(0), token0, token1, or this Pool.
    error InvalidSurplusRecipient();
    /// @notice `block.timestamp` is after the caller's deadline.
    error DeadlineExpired();
    /// @notice A user-supplied recipient is address(0) or this Pool (U7).
    error InvalidRecipient();
    /// @notice A required amount is zero.
    error ZeroAmount();
    /// @notice A tax hint is ≥ 10,000 bps.
    error InvalidTaxBps();
    /// @notice floor(sqrt(net0 · net1)) does not exceed MINIMUM_LIQUIDITY.
    error InsufficientInitialLiquidity();
    /// @notice Minted shares are below max(`minShares`, 1) (DECISIONS M3-4, M4-2).
    error InsufficientShares();
    /// @notice TEMPORARY (DECISIONS M4-1): a later deposit with a non-zero tax hint needs the L-α
    ///         gross rule, which is decided in M8. Removed in M8.
    error TaxedLaterDepositNotImplemented();
    /// @notice A later deposit's optimal amount for one token rounds down to 0 (ARCHITECTURE §6.2 step 2).
    error InsufficientDepositAmount();
    /// @notice The measured net received is outside the tolerance [T, T + 1] (ARCHITECTURE §6.2 step 4).
    error NetAmountOutOfRange();
    /// @notice LP would be credited to this Pool other than by the single initial lock mint (LP-SELF).
    error LPTransferToPool();
    /// @notice LP held by this Pool (the lock) can never be moved or burned.
    error LockedLiquidity();
    /// @notice LP minted or burned outside a `nonReentrant` entry point.
    error SupplyChangeOutsideGuard();

    /// @param token0_ Lower token address; the caller (later: the Factory) must sort (DECISIONS M2-2).
    /// @param token1_ Higher token address.
    /// @param surplusRecipient_ Immutable surplus destination.
    /// @dev Check order (DECISIONS M2-3): zero first, so a zero token is always reported as
    ///      ZeroAddress whichever position it is in. The four recipient checks (A3) catch only
    ///      these obvious mistakes; a wrong-but-valid address cannot be detected and is permanent.
    ///      LP name/symbol are constants (DECISIONS M3-1), so the signature is unchanged from M2.
    constructor(address token0_, address token1_, address surplusRecipient_) ERC20("AMM Liquidity Provider", "AMM-LP") {
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

    // ------------------------------------------------------------------
    // Liquidity
    // ------------------------------------------------------------------

    /// @notice Deposit both tokens and receive LP shares (ARCHITECTURE §7.2).
    /// @dev Initial deposit (`totalSupply() == 0`, ARCHITECTURE §6.1, M3) or later deposit at the
    ///      current reserve ratio (ARCHITECTURE §6.2 with t = 0, M4). Later deposits with a non-zero
    ///      tax hint revert until M8 (DECISIONS M4-1).
    ///      Call order: the inbound transfers necessarily happen before the reserves are written,
    ///      because the Pool must measure what it actually received; `nonReentrant` blocks any
    ///      token callback from re-entering a state-changing function (ARCHITECTURE §7).
    /// @param amount0Max Gross token0 cap (initial: pulled in full; later: at most this is pulled).
    /// @param amount1Max Gross token1 cap (initial: pulled in full; later: at most this is pulled).
    /// @param tax0Bps Caller's token0 transfer-tax hint; validated; ignored on the initial deposit
    ///        (U9 option i); must be 0 on a later deposit until M8 (DECISIONS M4-1).
    /// @param tax1Bps Caller's token1 transfer-tax hint; same rules as `tax0Bps`.
    /// @param minShares Smallest acceptable number of LP shares for `recipient`.
    /// @param recipient Receiver of the LP shares; not address(0) or this Pool (U7).
    /// @param deadline Last valid `block.timestamp` (inclusive).
    /// @return net0 Measured token0 received by the Pool.
    /// @return net1 Measured token1 received by the Pool.
    /// @return shares LP shares minted to `recipient`.
    function addLiquidity(
        uint256 amount0Max,
        uint256 amount1Max,
        uint256 tax0Bps,
        uint256 tax1Bps,
        uint256 minShares,
        address recipient,
        uint256 deadline
    ) external nonReentrant returns (uint256 net0, uint256 net1, uint256 shares) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        if (amount0Max == 0 || amount1Max == 0) revert ZeroAmount();
        if (tax0Bps >= BPS_DENOMINATOR || tax1Bps >= BPS_DENOMINATOR) revert InvalidTaxBps();
        uint256 supply = totalSupply();
        if (supply == 0) {
            // Initial deposit (ARCHITECTURE §6.1): no ratio exists yet, so pull both maxima and
            // account only what actually arrived. Earlier surplus is excluded by the snapshots.
            net0 = _pullMeasured(token0, amount0Max);
            net1 = _pullMeasured(token1, amount1Max);

            uint256 grossShares = AMMMath.initialShares(net0, net1);
            if (grossShares <= MINIMUM_LIQUIDITY) revert InsufficientInitialLiquidity();
            shares = grossShares - MINIMUM_LIQUIDITY;
            if (shares < minShares) revert InsufficientShares();

            // Effects. Reserves are 0 here (no earlier writer can run while totalSupply() == 0,
            // because the 1,000 lock can never be burned), so `=` equals `reserve += net`.
            reserve0 = net0;
            reserve1 = net1;
            _mint(address(this), MINIMUM_LIQUIDITY); // permanent lock (U2, A5)
            _mint(recipient, shares);
        } else {
            (net0, net1, shares) = _addLater(amount0Max, amount1Max, tax0Bps, tax1Bps, minShares, recipient, supply);
        }

        emit LiquidityAdded(msg.sender, recipient, net0, net1, shares);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice Recorded reserves (ARCHITECTURE §7.6). These are accounting values, not live
    ///         balances: tokens sent directly to the Pool do not change them.
    ///         Output names carry a trailing underscore so they do not shadow the state
    ///         variables (DECISIONS M2-6r).
    /// @return reserve0_ Recorded reserve of token0.
    /// @return reserve1_ Recorded reserve of token1.
    function getReserves() external view returns (uint256 reserve0_, uint256 reserve1_) {
        return (reserve0, reserve1);
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    /// @dev Later deposit, L-α (ARCHITECTURE §6.2) restricted to t = 0 until M8 (DECISIONS M4-1, M4-2).
    ///      With t = 0: step 1 gives cap_i = amount_iMax and step 3 gives gross g_i = T_i, so the
    ///      still-`PENDING` step-3 gross rule is not exercised. The measured net is always used
    ///      and checked against [T_i, T_i + 1] (step 4), so a taxed token passed with hint 0 reverts.
    ///      Rounding: T and shares round down, so the depositor never receives more than its
    ///      proportional value; the dust stays with all LPs (THREAT_MODEL §6 item 5).
    ///      Reserves are > 0 here: the first deposit sets both > 0 and the never-burned lock keeps
    ///      every withdrawal strictly below the reserve (ARCHITECTURE §6.3). A reserve of 0 can only
    ///      arise from the future `sync()` — see THREAT_MODEL T25 (decided in M6).
    /// @param supply LP totalSupply before this deposit (> 0).
    function _addLater(
        uint256 amount0Max,
        uint256 amount1Max,
        uint256 tax0Bps,
        uint256 tax1Bps,
        uint256 minShares,
        address recipient,
        uint256 supply
    ) private returns (uint256 net0, uint256 net1, uint256 shares) {
        if (tax0Bps != 0 || tax1Bps != 0) revert TaxedLaterDepositNotImplemented();

        uint256 r0 = reserve0;
        uint256 r1 = reserve1;

        // Step 2: the largest pair (T0, T1) at the current ratio within both caps (floor).
        uint256 target0 = amount0Max;
        uint256 target1 = Math.mulDiv(amount0Max, r1, r0);
        if (target1 > amount1Max) {
            target0 = Math.mulDiv(amount1Max, r0, r1);
            target1 = amount1Max;
        }
        if (target0 == 0 || target1 == 0) revert InsufficientDepositAmount();

        // Step 4: one measured pull per token; reject anything outside [T, T + 1].
        // Written as `net - target > 1` so that `target + 1` can never overflow.
        net0 = _pullMeasured(token0, target0);
        if (net0 < target0 || net0 - target0 > 1) revert NetAmountOutOfRange();
        net1 = _pullMeasured(token1, target1);
        if (net1 < target1 || net1 - target1 > 1) revert NetAmountOutOfRange();

        // Step 5: shares from measured net only; the smaller side decides (no free value).
        shares = Math.min(Math.mulDiv(net0, supply, r0), Math.mulDiv(net1, supply, r1));
        if (shares == 0 || shares < minShares) revert InsufficientShares();

        // Step 6: effects.
        reserve0 = r0 + net0;
        reserve1 = r1 + net1;
        _mint(recipient, shares);
    }

    /// @dev Pulls `amount` of `token` from msg.sender and returns the Pool's measured balance
    ///      increase (ARCHITECTURE §5.2). For a U8 taxed token this is below `amount`.
    ///      A token whose balance falls during its own transferFrom makes the subtraction revert.
    function _pullMeasured(address token, uint256 amount) private returns (uint256 received) {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - balanceBefore;
    }

    /// @dev Single choke point for every LP balance change (DECISIONS M3-2, ADR-022).
    ///      OZ routes transfer, transferFrom, _mint and _burn through `_update`, so these rules
    ///      cover every present and future code path:
    ///      1. Pool-held LP (the lock) is immovable: no transfer or burn from this address.
    ///      2. LP may be credited to this Pool only by the first lock mint
    ///         (mint, totalSupply() == 0, value == MINIMUM_LIQUIDITY); every other movement to
    ///         the Pool — including zero-value transfers — reverts (LP-SELF).
    ///      3. Minting or burning is possible only while a `nonReentrant` entry point executes,
    ///         so a future `_mint`/`_burn` placed in an unguarded function fails loudly.
    ///      Consequence: BI-7 (Pool LP == 1000 after the first deposit) is enforced on-chain.
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(this)) revert LockedLiquidity();
        if (to == address(this) && (from != address(0) || totalSupply() != 0 || value != MINIMUM_LIQUIDITY)) {
            revert LPTransferToPool();
        }
        if ((from == address(0) || to == address(0)) && !_reentrancyGuardEntered()) {
            revert SupplyChangeOutsideGuard();
        }
        super._update(from, to, value);
    }
}
