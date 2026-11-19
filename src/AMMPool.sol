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
///      deposits and proportional withdrawal (M4), exact-input swap (M5), downward-only sync,
///      per-token skim, deficit entry checks and terminal-pool rules (M6).
///      add, remove and swap revert on a deficit (balance < reserve; U4, DECISIONS M6-2).
///      Specification: docs/ARCHITECTURE.md §4, §5, §6.1–§6.4, §7.1–§7.9.
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
    ///      ARCHITECTURE §5.2: `addLiquidity` (initial and later), `removeLiquidity`,
    ///      `swapExactInput` and `sync` (lower only).
    uint256 private reserve0;
    uint256 private reserve1;

    /// @notice Emitted on every successful deposit (DECISIONS M3-4).
    /// @param sender Account whose tokens were pulled (`msg.sender`).
    /// @param recipient Account that received the LP shares.
    /// @param net0 Measured token0 increase of the Pool in this call.
    /// @param net1 Measured token1 increase of the Pool in this call.
    /// @param shares LP shares minted to `recipient` (excluding the 1,000 lock).
    event LiquidityAdded(address indexed sender, address indexed recipient, uint256 net0, uint256 net1, uint256 shares);

    /// @notice Emitted on every successful withdrawal (DECISIONS M4-3).
    /// @param sender Account whose LP shares were burned (`msg.sender`).
    /// @param recipient Account that received the tokens.
    /// @param shares LP shares burned.
    /// @param amount0 token0 sent by the Pool (= reserve0 decrease). For a taxed token the
    ///        recipient receives less; its actual receipt is the function's return value.
    /// @param amount1 token1 sent by the Pool (= reserve1 decrease).
    event LiquidityRemoved(
        address indexed sender, address indexed recipient, uint256 shares, uint256 amount0, uint256 amount1
    );

    /// @notice Emitted on every successful swap (DECISIONS M5-3). The three amounts are distinct:
    /// @param sender Account whose input tokens were pulled (`msg.sender`).
    /// @param recipient Account that received the output tokens.
    /// @param tokenIn Input token (token0 or token1); the output token is the other one.
    /// @param amountIn `a`: the Pool's measured input-token increase in this call (= reserveIn increase).
    /// @param amountOut `out`: the Pool's measured output-token decrease (= reserveOut decrease, A8).
    /// @param netOut The recipient's measured output-token increase (MIN-NET basis; below
    ///        `amountOut` for a taxed output token).
    event Swap(
        address indexed sender,
        address indexed recipient,
        address tokenIn,
        uint256 amountIn,
        uint256 amountOut,
        uint256 netOut
    );

    /// @notice Emitted by `sync()` for each token whose recorded reserve was lowered to the actual
    ///         balance (deficit reconciliation, DECISIONS M6-4). Not emitted when nothing changes.
    /// @param token The token whose reserve was lowered.
    /// @param previousReserve Recorded reserve before the call.
    /// @param newReserve Recorded reserve after the call (= the Pool's balance); the LPs' loss is
    ///        `previousReserve − newReserve`.
    event ReserveSynced(address indexed token, uint256 previousReserve, uint256 newReserve);

    /// @notice Emitted by `skim()` for each token whose surplus was sent to `surplusRecipient`
    ///         (DECISIONS M6-4). Not emitted for a token without surplus.
    /// @param token The token whose surplus was sent.
    /// @param amount The Pool-side decrease (= balance − reserve before the call; A8). A taxed
    ///        token's recipient receives less; its receipt is not measured.
    event SurplusSkimmed(address indexed token, uint256 amount);

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
    /// @notice A withdrawal's proportional amount of one token rounds down to 0 (ARCHITECTURE §6.3).
    error InsufficientLiquidityBurned();
    /// @notice The Pool's balance did not fall by exactly the amount sent (A8, BI-5).
    error OutboundTransferMismatch();
    /// @notice The recipient's actual balance increase is below the caller's minimum (MIN-NET, BI-6).
    error InsufficientNetReceived();
    /// @notice `tokenIn` is neither token0 nor token1 (DECISIONS M5-1).
    error InvalidTokenIn();
    /// @notice The swap output rounds down to 0 (DECISIONS M2-5r; the quote returns 0 instead).
    error InsufficientOutputAmount();
    /// @notice A token's Pool balance is below its recorded reserve (U4, DECISIONS M6-2); call
    ///         `sync()` to reconcile before adding, removing or swapping.
    error ReserveDeficit();
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
            // Deficit entry check (M6-2) only here: with supply == 0 both reserves are 0, so a
            // deficit cannot exist on the initial path.
            _checkNoDeficit();
            // Terminal pool (DECISIONS M6-1): a zero reserve can only come from sync(); refuse
            // before any transfer instead of dividing by zero in _addLater.
            if (reserve0 == 0 || reserve1 == 0) revert AMMMath.InsufficientLiquidity();
            // TEMPORARY (DECISIONS M4-1): still after every M3-4 check and before any transfer.
            if (tax0Bps != 0 || tax1Bps != 0) revert TaxedLaterDepositNotImplemented();
            (net0, net1, shares) = _addLater(amount0Max, amount1Max, minShares, recipient, supply);
        }

        emit LiquidityAdded(msg.sender, recipient, net0, net1, shares);
    }

    /// @notice Burn the caller's LP shares and receive the proportional part of both reserves
    ///         (ARCHITECTURE §6.3, §7.3; DECISIONS M4-3).
    /// @dev Order: checks → effects (burn, reserve decrease) → interactions (one transfer per token),
    ///      so a recipient or token callback sees post-withdrawal state; `nonReentrant` blocks
    ///      re-entry into every state-changing function.
    ///      The burn comes before the `mulDiv`, so any `shares` above the caller's balance — even
    ///      `type(uint256).max` — is reported as `ERC20InsufficientBalance`, never as an overflow
    ///      Panic. Afterwards `shares <= supply`, so `amount_i <= r_i` cannot overflow.
    ///      The 1,000 lock is never redeemed: only `msg.sender`'s balance is burned, and `_update`
    ///      rejects any burn from this Pool (`LockedLiquidity`). Because the lock stays in the
    ///      supply, `amount_i <= r_i · (S − 1000) / S < r_i`, so both reserves stay > 0.
    ///      Rounding down favours the LPs who remain.
    ///      Terminal pool (DECISIONS M6-1, M4-3r): if `sync()` lowered one reserve to 0, that side
    ///      pays 0 without a transfer and the other side pays its proportional amount, so LPs can
    ///      still recover the remaining asset; MIN-NET still applies to both sides.
    /// @param shares LP shares to burn from `msg.sender`.
    /// @param min0Net Smallest acceptable token0 increase of `recipient` (MIN-NET).
    /// @param min1Net Smallest acceptable token1 increase of `recipient` (MIN-NET).
    /// @param recipient Receiver of both tokens; not address(0) or this Pool (U7).
    /// @param deadline Last valid `block.timestamp` (inclusive).
    /// @return net0 Measured token0 increase of `recipient`.
    /// @return net1 Measured token1 increase of `recipient`.
    function removeLiquidity(uint256 shares, uint256 min0Net, uint256 min1Net, address recipient, uint256 deadline)
        external
        nonReentrant
        returns (uint256 net0, uint256 net1)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        if (shares == 0) revert ZeroAmount();
        _checkNoDeficit(); // M6-2: before the burn, so a deficit is reported before any effect

        uint256 supply = totalSupply();
        _burn(msg.sender, shares); // reverts ERC20InsufficientBalance if the caller holds fewer

        uint256 r0 = reserve0;
        uint256 r1 = reserve1;
        uint256 amount0 = Math.mulDiv(shares, r0, supply);
        uint256 amount1 = Math.mulDiv(shares, r1, supply);
        // M4-3r: rounding to 0 against a non-zero reserve still reverts, and so does a withdrawal
        // that pays nothing at all. Only a zero reserve (terminal pool, M6-1) may pay 0.
        if ((amount0 == 0 && amount1 == 0) || (amount0 == 0 && r0 != 0) || (amount1 == 0 && r1 != 0)) {
            revert InsufficientLiquidityBurned();
        }
        reserve0 = r0 - amount0;
        reserve1 = r1 - amount1;

        net0 = amount0 == 0 ? _skipZeroSide(min0Net) : _pushMeasured(token0, recipient, amount0, min0Net);
        net1 = amount1 == 0 ? _skipZeroSide(min1Net) : _pushMeasured(token1, recipient, amount1, min1Net);

        emit LiquidityRemoved(msg.sender, recipient, shares, amount0, amount1);
    }

    // ------------------------------------------------------------------
    // Swap
    // ------------------------------------------------------------------

    /// @notice Sell exactly `amountIn` of `tokenIn` for the other token (ARCHITECTURE §6.4, §7.4;
    ///         DECISIONS M5-1).
    /// @dev Check order (M5-1): deadline → recipient → tokenIn → amountIn → reserves, all before
    ///      any transfer. Reserves are read once and cached; `nonReentrant` guarantees no other
    ///      state-changing call can modify them while this call runs.
    ///      Pricing uses the MEASURED input `a` and the recorded reserves only, so surplus that was
    ///      in the Pool before the call is neither counted as input nor used for the price (BI-2).
    ///      out = floor(a·9970·rOut / (rIn·10000 + a·9970)) < rOut (§6.4); `a == 0` reverts
    ///      `InsufficientInputAmount` inside `AMMMath`; `out == 0` reverts here (M2-5r).
    ///      Call order: inbound pull (must precede the reserve update, because the Pool must
    ///      measure what arrived) → effects → outbound push, so an outbound callback sees the
    ///      post-swap reserves (THREAT_MODEL T13).
    ///      A pre-existing deficit (balance < reserve) reverts `ReserveDeficit` before the pull,
    ///      so the swap never prices from reserves the Pool no longer holds (M6-2, closes M5-1).
    /// @param tokenIn Token sold; must be token0 or token1. An address (not a direction flag)
    ///        cannot be reversed by a caller unaware of the sort order (M5-1).
    /// @param amountIn Gross amount pulled from `msg.sender`.
    /// @param minNetAmountOut Smallest acceptable output increase of `recipient` (MIN-NET).
    /// @param recipient Receiver of the output token; not address(0) or this Pool (U7).
    /// @param deadline Last valid `block.timestamp` (inclusive).
    /// @return netOut Measured output-token increase of `recipient`.
    function swapExactInput(
        address tokenIn,
        uint256 amountIn,
        uint256 minNetAmountOut,
        address recipient,
        uint256 deadline
    ) external nonReentrant returns (uint256 netOut) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        (bool zeroForOne, uint256 rIn, uint256 rOut) = _swapReserves(tokenIn);
        if (amountIn == 0) revert AMMMath.InsufficientInputAmount();
        if (rIn == 0 || rOut == 0) revert AMMMath.InsufficientLiquidity();
        _checkNoDeficit(); // M6-2: never price from reserves the Pool no longer holds

        uint256 amountInNet = _pullMeasured(tokenIn, amountIn);
        uint256 amountOut = AMMMath.getAmountOut(amountInNet, rIn, rOut);
        if (amountOut == 0) revert InsufficientOutputAmount();

        // Effects: the whole measured input (fee included) enters reserveIn, so the 0.3% fee
        // stays with the LPs (§6.4). amountOut < rOut, so the subtraction cannot underflow.
        address tokenOut;
        if (zeroForOne) {
            reserve0 = rIn + amountInNet;
            reserve1 = rOut - amountOut;
            tokenOut = token1;
        } else {
            reserve1 = rIn + amountInNet;
            reserve0 = rOut - amountOut;
            tokenOut = token0;
        }

        netOut = _pushMeasured(tokenOut, recipient, amountOut, minNetAmountOut);

        emit Swap(msg.sender, recipient, tokenIn, amountInNet, amountOut, netOut);
    }

    // ------------------------------------------------------------------
    // Reserve reconciliation
    // ------------------------------------------------------------------

    /// @notice Lower each recorded reserve that exceeds the Pool's actual balance to that balance
    ///         (deficit reconciliation; ARCHITECTURE §5.3, §7.7; DECISIONS M6-4). Callable by anyone.
    /// @dev Gate R=(b): `sync()` may only LOWER a reserve; surplus (balance > reserve) is never
    ///      absorbed — it belongs to `skim()` alone (BI-4). So a direct transfer followed by
    ///      `sync()` can neither move the price nor inflate share value (THREAT_MODEL T3).
    ///      A deficit only arises with tokens outside the supported model (ARCHITECTURE §3); the
    ///      loss is borne by all LPs pro rata. If a reserve reaches 0 while LP supply remains, the
    ///      Pool becomes terminal (DECISIONS M6-1, THREAT_MODEL T25).
    ///      No transfer, so no callback point; `nonReentrant` stops it running inside another
    ///      Pool call (e.g. from a token hook) where the reserves are mid-update.
    ///      No change → no write and no event (U5).
    function sync() external nonReentrant {
        _syncToken(token0, true);
        _syncToken(token1, false);
    }

    /// @notice Send each token's surplus (balance above recorded reserve) to the immutable
    ///         `surplusRecipient` (ARCHITECTURE §5.4, §7.8; DECISIONS M6-4). Callable by anyone;
    ///         the caller cannot choose the destination and gains nothing.
    /// @dev Gate R=(b): the only exit for surplus; reserves are never changed (BI-3), so the price
    ///      and the LPs' claims are unaffected. Per token independently (A2): a token without
    ///      surplus — equal or in deficit — is skipped, so a deficit in one token never blocks the
    ///      other token's surplus. A8 (BI-5): the Pool's balance must fall by exactly the amount
    ///      sent, else `OutboundTransferMismatch`. A reverting transfer reverts the whole call, so
    ///      neither token is skimmed while one transfer keeps failing (THREAT_MODEL T15).
    ///      No MIN-NET: a taxed token's recipient receives less (THREAT_MODEL T16).
    ///      Effects-free before the transfer (reserves are only read), and `nonReentrant`
    ///      blocks a token callback from re-entering any state-changing function.
    ///      No surplus → no transfer, no write, no event (U5).
    function skim() external nonReentrant {
        _skimToken(token0, reserve0);
        _skimToken(token1, reserve1);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice Quote for an exact-input swap of `amountIn` of `tokenIn` (ARCHITECTURE §6.4, §7.5;
    ///         DECISIONS M5-2).
    /// @dev Uses recorded reserves only (surplus ignored) and treats `amountIn` as the NET input:
    ///      for a taxed token the caller must deduct the tax itself, and the result can be stale by
    ///      execution time. Shares `_swapReserves` with `swapExactInput`, so invalid `tokenIn`,
    ///      zero input and zero reserves revert with the same errors as the swap
    ///      (`InvalidTokenIn`, `InsufficientInputAmount`, `InsufficientLiquidity`).
    ///      A floored output of 0 is RETURNED (the swap reverts instead; M2-5r, ADR-021).
    ///      No `nonReentrantView` (DECISIONS M5-5, THREAT_MODEL T13).
    /// @param tokenIn Token to sell; must be token0 or token1.
    /// @param amountIn Net input amount the Pool would receive.
    /// @return amountOut Output the Pool would send: floor(a·9970·rOut / (rIn·10000 + a·9970)).
    function getAmountOut(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut) {
        (, uint256 rIn, uint256 rOut) = _swapReserves(tokenIn);
        amountOut = AMMMath.getAmountOut(amountIn, rIn, rOut);
    }

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
    ///      The caller (`addLiquidity`) has already rejected non-zero tax hints (M4-1).
    ///      With t = 0: step 1 gives cap_i = amount_iMax and step 3 gives gross g_i = T_i, so the
    ///      still-`PENDING` step-3 gross rule is not exercised. The measured net is always used
    ///      and checked against [T_i, T_i + 1] (step 4), so a taxed token passed with hint 0 reverts.
    ///      Rounding: T and shares round down, so the depositor never receives more than its
    ///      proportional value; the dust stays with all LPs (THREAT_MODEL §6 item 5).
    ///      Reserves are > 0 here: the first deposit sets both > 0 and the never-burned lock keeps
    ///      every withdrawal strictly below the reserve (ARCHITECTURE §6.3). A reserve of 0 can only
    ///      arise from `sync()`; `addLiquidity` rejects that terminal state before calling here
    ///      (DECISIONS M6-1, THREAT_MODEL T25), so the divisions below never see r_i == 0.
    /// @param supply LP totalSupply before this deposit (> 0).
    function _addLater(uint256 amount0Max, uint256 amount1Max, uint256 minShares, address recipient, uint256 supply)
        private
        returns (uint256 net0, uint256 net1, uint256 shares)
    {
        uint256 r0 = reserve0;
        uint256 r1 = reserve1;

        // Step 2: the largest pair (T0, T1) at the current ratio within both caps (floor).
        // DECISIONS M4H-2 (chosen by gas, TEST_MATRIX §14.1 H2): form the exact 512-bit product
        // once instead of letting `mulDiv` revert on overflow.
        //   hi == 0      → the product fits: plain division (cheaper than `mulDiv`);
        //   0 < hi < r0  → the quotient still fits: `mulDiv`;
        //   hi >= r0     → amount0Max · r1 / r0 ≥ 2^256 > amount1Max, so the token1 cap binds.
        // In the token1 branch amount1Max · r0 / r1 < amount0Max, so it can never overflow.
        // Results equal floor(amount0Max · r1 / r0) wherever that fits in uint256.
        uint256 target0 = amount0Max;
        uint256 target1;
        {
            (uint256 hi, uint256 lo) = Math.mul512(amount0Max, r1);
            if (hi == 0) target1 = lo / r0;
            else if (hi < r0) target1 = Math.mulDiv(amount0Max, r1, r0);
            if (hi >= r0 || target1 > amount1Max) {
                (hi, lo) = Math.mul512(amount1Max, r0);
                target0 = hi == 0 ? lo / r1 : Math.mulDiv(amount1Max, r0, r1);
                target1 = amount1Max;
            }
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

    /// @dev Zero-reserve side of a terminal-pool withdrawal (M4-3r): nothing is sent, so the
    ///      recipient's increase is 0 and MIN-NET is still enforced against it.
    function _skipZeroSide(uint256 minNet) private pure returns (uint256) {
        if (minNet != 0) revert InsufficientNetReceived();
        return 0;
    }

    /// @dev Deficit entry check (U4, DECISIONS M6-2): reverts if either token's Pool balance is
    ///      below its recorded reserve. Equality passes. Only view calls, so no callback point.
    function _checkNoDeficit() private view {
        if (IERC20(token0).balanceOf(address(this)) < reserve0 || IERC20(token1).balanceOf(address(this)) < reserve1) {
            revert ReserveDeficit();
        }
    }

    /// @dev One token of `sync()`: if balance < reserve, lower the reserve to the balance.
    /// @param isToken0 Selects `reserve0` (true) or `reserve1` (false).
    function _syncToken(address token, bool isToken0) private {
        uint256 reserve = isToken0 ? reserve0 : reserve1;
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < reserve) {
            if (isToken0) reserve0 = balance;
            else reserve1 = balance;
            emit ReserveSynced(token, reserve, balance);
        }
    }

    /// @dev One token of `skim()`. The balance read here is the before-snapshot of the transfer:
    ///      nothing runs between the two, and the reserve cannot change (`nonReentrant`).
    function _skimToken(address token, uint256 reserve) private {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > reserve) {
            uint256 amount = balance - reserve;
            IERC20(token).safeTransfer(surplusRecipient, amount);
            uint256 balanceAfter = IERC20(token).balanceOf(address(this));
            if (balanceAfter > balance || balance - balanceAfter != amount) revert OutboundTransferMismatch();
            emit SurplusSkimmed(token, amount);
        }
    }

    /// @dev Orders the recorded reserves as (input, output) for `tokenIn`; shared by the swap and
    ///      the quote so both reject an invalid token with the same error (DECISIONS M5-2).
    function _swapReserves(address tokenIn) private view returns (bool zeroForOne, uint256 rIn, uint256 rOut) {
        if (tokenIn == token0) return (true, reserve0, reserve1);
        if (tokenIn == token1) return (false, reserve1, reserve0);
        revert InvalidTokenIn();
    }

    /// @dev Pulls `amount` of `token` from msg.sender and returns the Pool's measured balance
    ///      increase (ARCHITECTURE §5.2). For a U8 taxed token this is below `amount`.
    ///      A token whose balance falls during its own transferFrom makes the subtraction revert.
    function _pullMeasured(address token, uint256 amount) private returns (uint256 received) {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - balanceBefore;
    }

    /// @dev Sends `amount` of `token` to `to` and returns `to`'s measured balance increase.
    ///      A8 / BI-5: the Pool's own balance must fall by exactly `amount` (a rise or any other
    ///      change reverts `OutboundTransferMismatch`, never an underflow Panic).
    ///      MIN-NET / BI-6: the recipient's actual increase (0 if its balance fell) must be at
    ///      least `minNet`; for a U8 taxed token it is below `amount`.
    function _pushMeasured(address token, address to, uint256 amount, uint256 minNet)
        private
        returns (uint256 received)
    {
        uint256 poolBefore = IERC20(token).balanceOf(address(this));
        uint256 toBefore = IERC20(token).balanceOf(to);
        IERC20(token).safeTransfer(to, amount);
        uint256 poolAfter = IERC20(token).balanceOf(address(this));
        if (poolAfter > poolBefore || poolBefore - poolAfter != amount) revert OutboundTransferMismatch();
        uint256 toAfter = IERC20(token).balanceOf(to);
        received = toAfter > toBefore ? toAfter - toBefore : 0;
        if (received < minNet) revert InsufficientNetReceived();
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
