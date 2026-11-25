# A Constant-Product AMM with Measured Token Accounting

Solidity 0.8.38 · Foundry (forge 1.9.0) · OpenZeppelin Contracts v5.7.0 · optimizer 200 runs, `evm_version = osaka`, `via_ir = false`. Source comments point here with `@custom:report docs/REPORT.md §n`; section numbers are stable. Evidence is cited by Foundry test function or file in `test/`; the short IDs inside test names (e.g. W01 in `test_W01_proportionalRedemption`) and the decision IDs of the repository records are listed in §13.4.

## 1. Overview

### 1.1 Components

| Contract | File | Role |
|---|---|---|
| `AMMFactory` | `src/AMMFactory.sol` | Deploys one Pool per unordered token pair; registry. No owner, no funds. |
| `AMMPool` | `src/AMMPool.sol` | Holds two tokens, records reserves, prices swaps, and **is** the LP token (OpenZeppelin `ERC20`). No owner, immutable. |
| `AMMMath` | `src/libraries/AMMMath.sol` | Pure maths: swap quote with fee, initial-share square root. |
| `IAMMPool` | `src/interfaces/IAMMPool.sol` | Deposit parameter struct `AddLiquidityParams`. |

Beyond a basic AMM, the design (i) measures what every transfer actually delivers, so the accounting stays correct for tokens with transfer taxes, (ii) gives each user protection a precise, tested meaning, and (iii) separates recorded reserves from balances, so that a direct transfer never changes the recorded reserves: it becomes surplus, or it refills a deficit (§8.3).

### 1.2 Evidence labels

**[proof]** written mathematical argument · **[source]** inference from reading the code · **[model]** sampled integer Python model of the formulas, not the contract · **[test]** executed against the real contracts in Foundry's local EVM (evidence over sampled states, not a proof) · **[gas]** measured gas, harness and configuration stated.

Notation: `r0, r1` recorded reserves; `S` LP supply; `n_i` amount the Pool actually received; `σ` shares minted; `u_i` unmatched "excess". Amounts are in smallest units.

## 2. How a trade is priced

### 2.1 Constant product

In a continuous model, without fees and ignoring integer rounding, a trade keeps `k = r0·r1` constant: `(r0 + a)·(r1 − out) = r0·r1`. The marginal price of token0 is `r1/r0`; larger trades get a worse average price. The contract works in integers and rounds every output down, so in practice `k` never falls and the fee makes it rise (§2.3).

### 2.2 Fee and exact formula

`AMMMath.getAmountOut`, with a 30 bps fee kept in the reserves (no protocol fee):

```
aFee = a · 9970;   out = ⌊ aFee · rOut / (rIn · 10000 + aFee) ⌋
```

This equals Uniswap V2's 997/1000 rule [source]. `swapExactInput` applies it to the **measured** input (§7).

### 2.3 What the fee guarantees

[proof] From the formula, `(rIn·10000 + aFee)·(rOut − out) ≥ rIn·10000·rOut`. Since `rIn·10000 + aFee ≤ (rIn + a)·10000`, it follows that `(rIn + a)·(rOut − out) ≥ rIn·rOut`: **the product `k` never decreases in a swap**, and the fee makes it grow. This does **not** mean that every per-share claim grows: per share, the input-token reserve rises and the output-token reserve falls. What grows is the constant-product measure `√k/S` (§3.3). [test] Checked in 512-bit arithmetic after every successful swap (`testFuzz_Z01_S11_S15_swapMatchesFormula`; swap invariant I3 of the stateful suites, §10).

### 2.4 Quotes

`AMMPool.getAmountOut` returns the formula at the recorded reserves. It is not tax-aware (a taxed input delivers less; a taxed output pays the recipient less) and not deficit-aware. Quote = swap for exact tokens [test] `test_Q01_quoteEqualsSwapBothDirections`.

## 3. What an LP share represents

### 3.1 A pro-rata claim on recorded reserves

`h` of `S` shares redeem `⌊h·r_i/S⌋` of each token (§6.1). A direct transfer does not change the recorded reserves: it is surplus, which backs no shares, or it refills a deficit up to the recorded reserve (§8.3).

### 3.2 First deposit and the permanent lock

The first depositor sets the price and receives `⌊√(n0·n1)⌋ − 1000` shares (`AMMMath.initialShares`); 1,000 shares are minted to the Pool itself and can never move or be burned (`AMMPool._update`). The lock makes the classic first-depositor inflation attack expensive (§9.2). Through add, remove and swap it keeps both reserves positive [proof] ([test] `test_W06_lastLPExitsLockRemains`); only `sync()` after a deficit, which needs an unsupported token, can lower a reserve to 0 (terminal pool, §6.4). The lock also keeps its pro-rata part of all fees and excess: negligible in a large pool, half of them if the initial `⌊√(n0·n1)⌋` is 2,000 [source].

### 3.3 A pool-level measure that never decreases

[proof] Add and remove round against the actor, so per token `r_i'·S ≥ r_i·S'`; a swap keeps `S` and does not decrease `k` (§2.3). Therefore `k/S²` never decreases through add, remove or swap. Because the square root is increasing, this is the same monotonicity statement as for `√(r0·r1)/S`, the geometric-mean reserve per share: one is non-decreasing exactly when the other is [test: invariant I10 of the stateful suites, §10; 2 suites × 256 runs × 500 random calls]. Exceptions: the initial deposit (`S` starts at 0) and `sync()` after a deficit, which lowers `k` (§8.2).

This measure is **not** the market value of a share. A swap lowers the per-share claim on the output token, and when the external price moves an LP can be worth less than simply holding the two tokens (impermanent loss).

## 4. Contracts and data structures

### 4.1 `AMMFactory`

State: `surplusRecipient` (immutable, shared by all its Pools), a private registry holding each pair once under its sorted order, `allPairs[]`. `getPair(tokenA, tokenB)` sorts its arguments and reads that entry, so both orders return the same Pool (0 if none). `createPair(tokenA, tokenB)` rejects zero addresses, identical tokens and addresses without code, sorts, rejects duplicates, deploys `new AMMPool(token0, token1, surplusRecipient)` and registers it. [test] `test/AMMFactory.t.sol` (creation, both orderings, duplicates, constructor checks); `test/AMMFactoryPairLookup.t.sol` (lookups); registry invariant `invariant_I5_registryConsistent` (`test/AMMFactoryInvariant.t.sol`).

### 4.2 `AMMPool`

| State | Type | Meaning |
|---|---|---|
| `token0`, `token1` | `address immutable` | sorted pair (`token0 < token1`, checked in the constructor) |
| `surplusRecipient` | `address immutable` | only destination of surplus (§8.1); the constructor rejects 0, `token0`, `token1` and the Pool, the Factory also rejects itself |
| `reserve0`, `reserve1` | `uint256 private` | recorded reserves (§4.4) |
| ERC-20 balances / supply | inherited | LP shares; `_update` enforces the lock rules |
| reentrancy lock | transient storage | `ReentrancyGuardTransient` |

`addLiquidity`, `removeLiquidity`, `swapExactInput`, `sync` and `skim` are `nonReentrant`. Their order differs because a Pool must measure an incoming amount before it can book it: `addLiquidity` runs checks → pulls → balance checks → effects; `swapExactInput` checks → pull → effects → push; `removeLiquidity` checks → effects (burn, reserves) → pushes; `skim` only pushes surplus and `sync` makes no transfer. Every Pool uses the same LP name and symbol, so wallets cannot tell pools apart by name. Two helpers carry the token accounting:

- `_pullMeasured(token, amount)`: Pool balance before → `transferFrom(msg.sender, Pool, amount)` → after; the difference is the Pool's receipt.
- `_pushMeasured(token, to, amount, minNet)`: the Pool's balance must fall by exactly `amount` (**A8**) and the recipient's measured increase must be at least `minNet` (**MIN-NET**).

### 4.3 `AMMMath`

Internal pure functions compiled into the Pool; tested on their own (`test/AMMMath.t.sol`) and through the Pool.

### 4.4 Recorded reserves versus balances

The Pool never prices from `balanceOf`. `balance − reserve` is **surplus** if positive (unsolicited transfers) and **deficit** if negative (a token removed Pool balance). Reserves are written only by the initial deposit, later deposit, `removeLiquidity`, `swapExactInput` and `sync` (downward only) [source]. A direct transfer therefore cannot change reserves: the "donate then `sync`" price route and the classic donation-inflation attack are closed. During a deficit a direct transfer first refills the missing backing; only the part above the reserve is surplus (§8.3). Value can still enter reserves through the paths that are meant to add it: swap fees and the excess of a deposit (§5.7, §9.2).

### 4.5 Supported tokens

Tier 0: standard ERC-20. Tier 1: a fixed inclusive transfer tax. Deposits additionally accept unknown or changing inclusive taxes and extra payer debits bounded by `maxDebit`. Rebasing, exclusive fee-on-transfer, untruthful `balanceOf`, hooks and blacklisting are unsupported; some are detected (A8), others fall outside the guarantees. Accepting a deposit does not prove that the tokens can be withdrawn later (§12).

## 5. Depositing liquidity

### 5.1 Interface

`addLiquidity(IAMMPool.AddLiquidityParams p) → (net0, net1, shares)`. Per token (sorted order, token0 = lower address): `amount{0,1}RequestMax`, `maxDebit{0,1}`, `maxExcess{0,1}`. Shared: `minShares`, `recipient`, `deadline`, `token1First` (pull order only).

### 5.2 One deposit through every stage

Executed on the real Pool: `test/AMMPoolReportExample.t.sol` `test_L46_reportWorkedDeposit` [test]; expected values from an independent model [model].
State: reserves `(10,000, 20,000)`, `S = ⌊√(2·10⁸)⌋ = 14,142`; token1 charges a 10 % inclusive tax on transfers into the Pool. bob: caps `(1,000, 2,500)`, `maxDebit (1,000, 2,000)`, `maxExcess (100, 1)`, `minShares 1,272`, token0 first.

| Stage | token0 | token1 | Code |
|---|---:|---:|---|
| ① most the Pool may request | 1,000 | 2,500 | caller |
| ② planned request at the pool ratio | 1,000 | 2,000 | `_pullLater` step 2 |
| ③ payer's actual debit (≤ `maxDebit`) | 1,000 | 2,000 | `_checkPayerDebit` |
| ④ Pool's measured receipt `n_i` | 1,000 | 1,800 | `_pullMeasured` (200 burned as tax) |
| ⑤ candidate share count per token `⌊n_i·S/r_i⌋` | 1,414 | 1,272 | `_mintLater` |
| ⑥ **LP minted** `σ` = the smaller candidate | **1,272** (one amount for the deposit) | | `_mintLater` |
| ⑦ matched part `⌈σ·r_i/S⌉` | 900 | 1,799 | `_mintLater` |
| ⑧ excess `u_i = n_i − matched` (≤ `maxExcess`) | 100 | 1 | `_mintLater` |
| ⑨ new reserves (`S` = 15,414) | 11,000 | 21,800 | |

Each bound is binding: `maxDebit1 = 1,999`, `maxExcess0 = 99` or `minShares = 1,273` reverts (`PayerDebitTooHigh`, `ExcessContributionTooHigh`, `InsufficientShares`) with no state change [test].

An immediate full redemption returns `(907, 1,798)` [test] against a payment of `(1,000, 2,000)`. The token1 gap is mostly the tax (200), which never reached the Pool. The token0 gap is the excess: the 100 unmatched token0 joined the reserves, and bob owns only `1,272/15,414 ≈ 8.3 %` of them. Finally, each token's redemption is rounded down: the exact claims are approximately 907.75 and 1,798.99, so in that last step bob loses less than one smallest unit **per token**.

**What the event shows.** `LiquidityAdded(sender, recipient, net0, net1, shares)` records the Pool's receipt `(1,000, 1,800)` and the 1,272 shares. The Pool does not emit the payer's actual debit (here 2,000 token1); a successful call shows only that `debit_i ≤ maxDebit_i` held (an extra accounting event was measured at about +2,500 gas per deposit and not adopted; TEST_MATRIX §14.5). The excess must be reconstructed with the reserves and LP supply **before** the deposit: `u0 = 1,000 − ⌈1,272·10,000/14,142⌉ = 100`. The LP mint `Transfer` is logged before `LiquidityAdded`, so an indexer that has already applied it sees `S = 15,414`; using that value gives `1,000 − ⌈1,272·10,000/15,414⌉ = 174`, which is wrong (ARCHITECTURE §9).

### 5.3 Steps in the code

1. **Checks** (`addLiquidity`): deadline, recipient, non-zero caps; for a non-empty pool, no deficit (token0's balance read and checked, then token1's) and no zero reserve.
2. **Snapshots** of the Pool's and the payer's balances of both tokens. A later deposit reuses the Pool readings of step 1 (only read-only calls in between): 6 Pool + 4 payer reads [test] `test/AMMPoolSnapshotReuseCalls.t.sol`.
3. **Step 2** (`_pullLater`): the largest pair at the pool ratio within both caps, rounded down. The exact 512-bit product is formed once, so huge caps never overflow.
4. **Pull and measure** the first token (its before-balance is its reading from step 1); only if it delivered a different amount than planned, re-plan the second token from what arrived; then pull and measure the second token.
5. **After the last transfer**: BI-2′ (`_checkInCallBalance`, `addLiquidity` only; a later deposit uses the second token's after-balance as its end): from the start snapshot to the end, each Pool balance rose by at least this call's own measured receipt, so no foreign removal hides inside the call; then the payer-debit bound (`_checkPayerDebit`).
6. **Shares and effects** (`_mintLater`): `σ`, `minShares`, checked `S + σ`, the excess bound, then `reserve_i += n_i` (excess included) and mint.

### 5.4 What each protection promises

| Field / rule | Promise | Not promised |
|---|---|---|
| `RequestMax_i` | The Pool never requests more of token i. | That this amount is transferred, or what is debited. |
| `maxDebit_i` | Bounds the payer's net decrease of token i over the call. [test] `AMMPoolPayerDebit` (plain, inclusive- and exclusive-fee tokens, both pull orders); invariant I6 | What the Pool receives. With a router, it protects the router. |
| `maxExcess_i` | Bounds the unmatched amount of token i left in reserves. [test] `AMMPoolMaxExcess`, `AMMPoolMaxExcessTier0`, §5.2 example | A refund. |
| `minShares` | A minimum number of shares. [test] `test_L18_minSharesPlusOneReverts`, §5.2 example | Any value, price or token amount (§5.6). |
| BI-2′ (`addLiquidity` only) | No foreign in-call loss of Pool balance goes unnoticed; a foreign in-call gift stays surplus. [test] `AMMPoolInCallBalance` | Protection against a lying `balanceOf`; swap and remove (§9.6). |

For exact tokens the excess is pure rounding: [proof] `u_i < r_i/S + r_i/r_j`; [test] at extreme requests, `testFuzz_F1T1_extremeRequest`.

**Why two bounds per token.** `RequestMax_i` limits what the Pool asks the token contract for; `maxDebit_i` limits how much `msg.sender`'s balance actually falls over the whole call. They answer different questions. Example: `RequestMax = 100, maxDebit = 105` lets the Pool request at most 100 while tolerating up to 5 of extra sender-side fees. One number used as both bounds would remove this separate authorisation. For an ordinary token the caller can set the two numbers equal; while the call still promises to bound the actual debit, the debit must still be measured.

**`minShares` versus `maxExcess`** (§5.2 example). They bound different quantities. bob receives 1,272 shares, so `minShares = 1,272` passes, but the token0 excess is 100, so `maxExcess0 = 99` reverts the same deposit. `maxExcess` has no effect on the first deposit (`u_i = 0` by definition). On a later deposit with a taxed token, `token1First` matters: if the first-pulled token delivers less than planned, the second request is re-planned from what arrived, which changes the excess (§5.7).

**Simpler use is a caller-side matter.** A wallet or router could later pre-fill these fields for ordinary users (recipient = the user, an explicit deadline, `maxDebit_i = RequestMax_i` for ordinary tokens, `token1First` as an advanced option). The Pool itself has no defaults: every field is supplied by the caller.

### 5.5 The first deposit cannot be requested as such

The path (initial or later) is chosen from `totalSupply()` at execution; the interface has no "initial only" option. A front-runner who deposits first turns the intended first deposit into a later one at the front-runner's ratio. Setting `minShares` to the initial expectation `⌊√(A·B)⌋ − 1000` rejects a clearly different ratio, but on the later path no lock is charged, so a skew of 2.5·10⁻¹⁹ still passes (`test_L45_slightSkewStillPassesInitialMinShares`) [test].

### 5.6 The scope of `minShares`

It bounds a share count only. With Tier 0 tokens and only swaps between quote and deposit: [proof]+[test] `σ'²·k_q ≤ S²·A·B` (`testFuzz_Z10_swapOnlyMintUpperBound`); [proof] success with `σ' ≥ m` **requires** `r0' ∈ [k_q·m/(S·B), S·A/m]`, a necessary condition and not a price guarantee ([model] 59,521 samples, none outside). A general claim that `minShares` stops sandwiches was retracted with a counterexample (REPORT_NOTES §2).

### 5.7 Why the excess stays in the Pool

Refunding it (an outbound transfer inside a deposit: more failure modes, another taxed hop) and swapping it implicitly (a second pricing path) were rejected. The chosen rule adds it to the reserves, where it benefits all shares, including the depositor's. Its cost to the depositor is bounded only by `maxExcess`. With taxed tokens it is of the order of the tax and depends on the pull order (5 % tax on the second token: 5 % of the first token unmatched [model]).

## 6. Withdrawing liquidity

### 6.1 Redemption

`removeLiquidity(shares, min0Net, min1Net, recipient, deadline)` burns the caller's shares, pays `⌊shares·r_i/S⌋` of each token and lowers each reserve by that amount [test] `test_W01_proportionalRedemption`.

### 6.2 Output rules A8 and MIN-NET

A8: the Pool's balance must fall by exactly the amount sent (`OutboundTransferMismatch`), which rejects tokens that charge the Pool extra or move its balance mid-transfer [test] `test_B06_overDebitRejectedByA8`, `test_W10_classB_overDebitToken0Reverts`. MIN-NET: the recipient's measured increase must be at least `min_iNet` (`InsufficientNetReceived`), the amount that matters for a taxed token [test] `test_W04_minNetBoundaryToken0`, `test_W05_taxedToken0Output`. A8 is an equality, so a token whose transfers differ by rounding (share-based balances) can be deposited but not reliably withdrawn. A one-sided check would admit it but would also let an under-delivering token leave the shortfall in the Pool as surplus; A8 was kept.

### 6.3 Small positions

If `r_i/S < 1` (e.g. a 2-decimal token against an 18-decimal one), fewer than `⌈S/r_i⌉` shares pay 0 of token i and revert `InsufficientLiquidityBurned`, as in Uniswap V2. [test] `test_W12_positionBelowThresholdCannotExit`: `S = 10¹²`, `r = 10⁴`; a remainder of 5·10⁷ shares cannot exit until it reaches 99,995,001.

### 6.4 Terminal pool

If `sync()` lowers a reserve to 0 while shares exist, deposits and swaps revert and withdrawals still pay the other token [test] `test/AMMPoolTerminal.t.sol`.

## 7. Swapping

`swapExactInput(tokenIn, amountIn, minNetAmountOut, recipient, deadline)`: checks (deadline, recipient, valid `tokenIn`, non-zero input and reserves, no deficit) → pull and measure the input `a` → `out` from §2.2 on `a` (0 reverts) → update reserves → send with A8 and MIN-NET. Unlike Uniswap V2's optimistic `swap`, the Pool pulls the input first and computes the output itself; there are no flash swaps. The direction is an address, so callers cannot invert it by misordering tokens. Taxed tokens: the input is priced on what arrived and `minNetAmountOut` is judged on what the recipient received [test] `test_S05_taxedInputPricedOnMeasuredNet`, `test_S06_taxedOutputMinNetBoundary`, `testFuzz_Z04_swapGrossVsNet`. There is no MEV protection beyond `minNetAmountOut` and `deadline`, and no view may serve as a price oracle (one transaction can move the spot price). [test] `test/AMMPoolSwap.t.sol` (swap and quote tests).

## 8. Reserves, `sync()` and `skim()`

### 8.1 Surplus and `skim()`

`skim()` sends each token's surplus to the immutable `surplusRecipient`; anyone may call it, nobody chooses the recipient. Surplus never enters reserves [test] `test_R01_directTransferDoesNotChangeReserves`, `test_R05_surplusNotAbsorbed`; invariants I8, I9 (§10). Refunds of mistaken transfers rely on whoever controls `surplusRecipient`; the growth of an unsupported rebasing or yield token also goes there, not to LPs.

### 8.2 Deficit and `sync()`

A deficit in either token blocks add, remove and swap (`ReserveDeficit`, `_checkNoDeficit`); the block lifts only when **both** balances cover their reserves [test] `test_R08_deficitBothBlocksAll`, `test_R24_bothDeficitsOneRefilledStillBlocks`. `sync()` only lowers a reserve to the balance; LPs bear the booked loss pro rata and, as the price jumps, an extra arbitrage loss of about `P·d²/(4x)` (fees ignored) [proof, not tested]. A tiny deficit gives nobody a reason to pay for `sync()`, so integrators should call it.

### 8.3 How tokens reach the reserves' backing

| Case | Effect | Evidence |
|---|---|---|
| Direct transfer, no deficit | surplus; only `skim()` removes it; LPs do not benefit | [test] `test_R01_directTransferDoesNotChangeReserves`; invariant I9 |
| Direct transfer during a deficit | refills the backing up to the reserve, only the part above it is surplus; a partial top-up keeps the block, an exact one lifts it; reserves unchanged, so LPs bear no write-down | [test] `test_R24_partialTopUpStillBlocksExactTopUpRestores`, `test_R08_deficitToken0BlocksAll` |
| Excess inside `addLiquidity` | joins the reserves, benefits all shares, moves the price slightly | [test] §5.2 example; `test_F1T5_tier1_maxExcessBoundary_token0First` |

Uniswap V2's `sync()` sets reserves to balances in both directions, so a transfer plus `sync()` adds to reserves [source, V2]. Here `sync()` only lowers, which removes the `sync`/`skim` race and that price route, at the cost of a fixed `surplusRecipient`.

## 9. Security

### 9.1 Reentrancy

The five state-changing Pool functions are `nonReentrant` (the LP functions make no external calls). Malicious token callbacks are tested for add, remove, swap, `sync` and `skim`, both bubbling and swallowed [test] `AMMPoolReentrancy`, `AMMPoolSyncSkimReentrancy`. Views are unguarded, so mid-transaction reads are not a safe price (read-only reentrancy).

### 9.2 Inflation and donation

Direct donations never enter reserves (§4.4), and the lock makes raising one share's value by `Δ` cost about `1000·Δ` [proof, approximate]. The deposit excess is a bounded donation channel; the evidence has four separate parts:

- **Bonus-token experiment, local EVM** [test] (`test/AMMPoolInflation.t.sol`, `test_L13b_*`). An unsupported token mints a bonus to the Pool during the attacker's own deposit (`D = 10²⁵` per token, a free donation counted as paid). bob then makes 5,000 deposits with token0 request `w` from a fixed generator in `[10²¹, 10²¹ + 2⁶⁴ − 1]` and an unlimited token1 request. Both absolute `maxExcess` fields are derived from token0's `w`: unbounded (`type(uint256).max`), or `maxExcess0 = maxExcess1 = ⌊w·10/10,000⌋` ("10 bps"); for token1 this is an absolute amount, not 10 bps of token1. Result: unbounded → attacker profit ≈ 9.08·10²¹ per token, measured as the attacker's wallet change minus `D`, ≈ 1.8·10²² with both tokens valued 1:1, gas excluded; 10 bps → 4,442 of 5,000 deposits revert and the attacker loses.
- **Honest-LP experiment, local EVM** [test] (`test/AMMPoolF1HonestLP.t.sol`): the same 5,000-deposit sequence, run again with one honest LP holding 0.99999901 % of the supply before the donation. The attacker's result per token, measured as the wallet change minus the assumed contribution cost `D`, turns negative.
- **Reduced-scale fee channel, local EVM** [test] (`test/AMMPoolF1SwapFeeChannel.t.sol`): with supported tokens, the legitimate way to raise per-share value is trading fees; up to 2,000 round trips were executed, and the attacker as the only LP loses exactly what stays in the Pool.
- **Full fee path** [model only]: an estimated 32,000–58,000 round-trip swaps would be needed to reach the bonus scale; capital, execution and net profitability are **not verified**.

Status: a known economic limitation of this Pool, bounded by each depositor's own `maxExcess`; not a demonstrated exploit with supported tokens. These experiments test this Pool only; no claim is made about other designs. Full figures: THREAT_MODEL T4, TEST_MATRIX §3.4.

### 9.3 Exit safety

Deposits accept more token behaviours than withdrawals. A token that later charges the Pool on outbound transfers, blacklists it or reverts `balanceOf` traps both tokens, because a withdrawal transfers both atomically; there is no recovery path in an ownerless design [test] `AMMPoolM8Limitations`.

### 9.4 Access control and LP rules

No owner, admin function, pause, upgrade, fallback or `receive`; [test] `test_X03_static_abiFunctionsEqualApprovedList` compares the compiled ABI with the approved list. `_update` makes the lock immovable, rejects LP sent to the Pool and rejects minting or burning outside a guarded entry point [test] `test_P04_noExternalMintOrBurn` to `test_P08_supplyChangesOutsideGuardRevert` (`test/AMMPoolLiquidity.t.sol`).

### 9.5 Arithmetic

Checked arithmetic turns overflow into a revert, never a wrong value; the hand-derived ranges are in ARCHITECTURE §6.6 (e.g. initial deposit `n0·n1 < 2²⁵⁶`). Later-deposit share maths saturates and is caught by the checked `S + σ`. [test] Overflow-boundary tests `test_Z06_*`, `test_Z08_saturatedSharesPanicBeforeExcessCheck`; 6/18-decimal values near `2¹¹²`, `testFuzz_Z03_mixedDecimalsNearTop`.

### 9.6 Balance changes inside a call

BI-2′ guards `addLiquidity` only. `swapExactInput` and `removeLiquidity` rely on the entry deficit check, measuring each own transfer from a fresh snapshot, A8, MIN-NET and `nonReentrant`. With an unsupported token whose callback moves the Pool's balance outside the transfer being measured (THREAT_MODEL T30), a swap or remove does not detect a foreign decrease of **surplus**; a decrease that creates a **deficit** is rejected by the next call's entry check until `sync()`. Supported tokens cannot cause either case.

## 10. Verification

Unit tests use exact values from independent models; fuzz tests cover the documented ranges; two stateful invariant suites (exact and 1 %/3 % taxed tokens, 256 runs × 500 random calls) check after every call: LP supply and lock (I1), balance ≥ reserve (I2), the swap formula and `k` (I3), debit ≤ cap and ≤ `maxDebit` (I6), exact outbound amounts (I7), `skim` only to `surplusRecipient` (I8), surplus changes only by donation and `skim` (I9), and §3.3 (I10). Every feature had a mutation check (deliberate bugs in one source file that a test had to catch); survivors were analysed and test gaps closed. `forge lint` findings were triaged (one false positive; accepted timestamp and event-order warnings). **Not done:** formal verification, symbolic execution, slither, Echidna/Medusa, fork tests, an external audit.

### 10.6 Final regression

Final code and tests: commit `1ab26ec`. Against the earlier regression commit `04eb336` it changes `src/AMMPool.sol` (constant LP metadata with `name()` declared `pure`; snapshot reuse on a later deposit) and `src/AMMFactory.sol` (one registry entry per pair), §11.2, and adds their tests and the comparison harness. Compiled ABI against `04eb336`: the Pool differs only in `name()`, now `pure`; the Factory is identical. `src/`, `test/`, `lib/` and `foundry.toml` are unchanged in every later commit of this branch. Experimental contracts (§11.4) are not part of this run. Commands: `forge build`; `forge test`; `FOUNDRY_FUZZ_RUNS=10000 forge test`. Result: **527 tests in 59 suites passed, 0 failed**, in both runs (invariant suites use their inline 256 × 500 setting). Configuration from `forge config`: solc 0.8.38, optimizer 200 runs, `osaka`, `via_ir = false`, `isolate = true`; forge 1.9.0.

## 11. Gas

### 11.1 Measured baseline

[gas] `test/gas/GasG02.t.sol` on the code of §10.6 (`1ab26ec`): one call per test, arguments prepared outside the measured interval, cold state (`isolate = true`); single scenarios, for comparisons inside this project only.

| Call | Gas | Call | Gas |
|---|---:|---|---:|
| `addLiquidity` initial | 232,000 | `swapExactInput` | 82,540 |
| `addLiquidity` later | 105,377 | `skim` (both tokens) | 101,777 |
| `removeLiquidity` | 94,105 | `sync` / `skim` no-op | 40,067 / 39,905 |
| deploy `AMMPool` | 2,592,900 | `createPair` | 2,451,531 |

Protection has a price [gas]. Before §11.2 (TEST_MATRIX §14.5: 108,789) a later deposit cost +10,264 (+10.4 %) more than the earlier ordinary-token-only deposit of `26ac725`, whose taxed deposits reverted: 8 more `balanceOf` reads (14 instead of 6; the final code makes 10), the re-plan, the excess bound and the struct-encoded call; the parts were not measured separately.

### 11.2 Optimisations adopted and rejected

| | Change | Measured effect [gas] | Decision |
|---|---|---|---|
| Adopted | `removeLiquidity` burns the caller's shares **before** computing the amounts (`mulDiv`) | a withdrawal that fails for insufficient LP costs 27,926 instead of 30,469 (−2,543); a successful one 6 gas less (TEST_MATRIX §14.1) | kept: cheaper failure and the clearer error (`ERC20InsufficientBalance` instead of an overflow panic) |
| Adopted | LP `name()` / `symbol()` return constants instead of two stored strings | getters −2,707 / −2,696 (Table 11.2) | kept; `pure` alone changed no gas |
| Adopted | A later deposit reuses the Pool's balance readings (6 + 4 reads instead of 10 + 4; §5.3); the Factory stores each pair once and `getPair` sorts | Table 11.2 | every later deposit is cheaper; relies on only read-only calls between a reading and its reuse |
| Rejected | VP: `uint112` reserves in one storage slot (as Uniswap V2) | ≈ −4,300 per add/remove/swap, −21,567 on the first deposit, but +159,273 per deployment | caps reserves at `2¹¹²` (13 range tests fail; a new error case and range rules would be needed) |

The LP name is fixed and `name()` is declared `pure`. Its selector and return value are unchanged. The compiled ABI now records `pure` for `name()` and `view` for `symbol()`. We compared the combined implementation with commit `04eb336` using the same benchmark harness. Table 11.2 reports the measured gas change for each operation [gas] (cold calls, finite `maxDebit`; Δ = final − `04eb336`, negative = saving; full matrix TEST_MATRIX §14.11).

| Operation (Table 11.2) | `04eb336` | final | Δ | % |
|---|---:|---:|---:|---:|
| deploy `AMMFactory` | 2,840,966 | 3,058,070 | +217,104 | +7.6 |
| deploy `AMMPool` directly | 2,424,914 | 2,595,417 | +170,503 | +7.0 |
| `createPair`, first / later pair (Pool deployment included) | 2,316,852 / 2,299,740 | 2,451,519 / 2,434,407 | +134,667 | +5.8 / +5.9 |
| `addLiquidity` initial | 231,973 | 231,969 | −4 | −0.0 |
| later deposit, ordinary, token0 / token1 first | 108,158 / 108,180 | 104,721 / 104,722 | −3,437 / −3,458 | −3.2 |
| later deposit, §5.2 taxed, taxed second / first | 193,456 / 193,847 | 189,883 / 190,253 | −3,573 / −3,594 | −1.8 / −1.9 |
| `getPair` sorted / reversed: cold; repeated in one tx; reversed after sorted | 5,975; 1,255; 3,255 | 6,076 / 6,086; 1,356 / 1,366; 1,366 | +101 / +111; −1,889 | +1.7 … +8.8; −58.0 |
| `name()` / `symbol()` | 6,322 / 6,321 | 3,615 / 3,625 | −2,707 / −2,696 | −42.8 / −42.7 |
| controls: `swapExactInput` / `removeLiquidity` | 82,539 / 94,105 | 82,540 / 94,105 | +1 / 0 | 0.0 |
| runtime bytes, Pool / Factory | 10,553 / 12,770 | 11,534 / 13,780 | +981 / +1,010 | +9.3 / +7.9 |

The per-pool break-even estimate uses the measured cost of pair creation, the initial deposit and subsequent deposits [estimate]: a Pool created through a deployed Factory, one initial deposit and `N` ordinary later deposits (token0 first) give Δ(N) = 134,667 − 4 − 3,437·N: +100,293 at N = 10, −209,037 at N = 100, no dearer from **N = 40**. With a new Factory (+217,104): +317,397 and +8,067, break-even N = 103. Paid on-chain `getPair` calls add their Δ per lookup.

VU (`unchecked` on arithmetic proven safe) saved 263–534 gas per state-changing call; it was not adopted, because checked arithmetic turns a mistake in those proofs, or in a later edit, into a revert instead of a silent wrap. Other measured variants are in TEST_MATRIX §14.


### 11.3 Uniswap V2, qualitative

No same-harness gas comparison with Uniswap V2 was made (V2 needs Solidity 0.5.16 and was not imported). From the V2 source (§13.3): V2 packs `uint112` reserves with a timestamp in one slot; computes deposits as `balance − reserve` after the router transferred tokens; keeps user minima in Router02; swaps optimistically with flash swaps; lets `sync` move reserves both ways; locks 1,000 LP at `address(0)`; and has a protocol fee and price accumulators. V2 keeps the core minimal and cheap and leaves protection to the periphery; this design puts the protections in the Pool, which costs gas but holds for every caller.

### 11.4 Alternatives evaluated

[gas] Same method as §11.1, on isolated, unmerged branches with the code of `04eb336`: A and B on `a85cd8d` (TEST_MATRIX §14.7); C and the minimal deposits on `da59581` (§14.8).

| Alternative | Measured effect | Trade-off | Decision |
|---|---|---|---|
| A: skip the payer snapshot of token i when `maxDebit_i = type(uint256).max` | Later deposit, ordinary tokens, token0 first [measured]: both MAX 108,789 → 104,943 (−3,846); one MAX, one finite 108,477 → 106,617 / 106,618 (−1,860 / −1,859); both finite 108,165 → 108,292 (+127). The §5.2 example uses finite bounds, so it gains nothing. The finite side still binds (exact debit passes, one unit less reverts `PayerDebitTooHigh`). | Benefits callers who give up the debit bound; callers who keep it pay +127. A deposit with an unsupported token whose `balanceOf(payer)` reverts would no longer fail at the snapshot. | Evaluated, not adopted: the approved design keeps one uniform rule (always measure the payer); MAX is not a default. |
| B: one shared Pool implementation, ERC-1167 clones with immutable arguments | Cold micro-benchmark [measured], same result returned: a clone call costs **+2,588** without reading the three addresses (delegatecall path) and **+6,072** when reading them (`fetchCloneArgs`); creating a clone 115,269 vs 2,159,325 for `new AMMPool`. The cost on each entry of a full Pool was **not measured** (Pool not ported). | The pair creator saves ≈ 2.04M once. Both measured call paths incurred extra gas. At 6,072 extra gas per call, about 337 calls would offset the estimated per-pair deployment saving, before allocating the shared implementation cost [estimated]. Constructor checks move to the Factory; Pools can no longer be deployed directly. | Evaluated, not adopted. In frequently used pools, recurring overhead could outweigh the initial deployment saving. |
| C: payer-debit check in an optional custodial Router (prototype), not the Pool | **Gas, ordinary tokens** (same outcome on every path) [measured]: Pool at `04eb336` 108,185; direct deposit without the check 104,135 (−4,050); through the Router **230,294 gross execution gas** (+122,109; its refund counter of 45,386, from clearing Router balances and approvals, not subtracted). **Shares, §5.2 taxed token** [measured]: for the same 2,000 token1 paid, 1,145 shares through the Router vs 1,272 direct. In the Router the exact debit bound passes; one unit tighter reverts the whole call. | Direct callers have no debit bound. The prototype takes custody (the Pool pulls from its caller): 4 `transferFrom` instead of 2, 8 more reads; a token taxed on every transfer is taxed twice. Results apply to this custodial prototype only. Unlike A (finite bound kept in the Pool), protection becomes optional. | Not adopted (student); Pool retained. |

**Minimal deposits (same experiment).** Two Pool variants, each with an interface listing what it omits, keep the caps, step-2 planning, `nonReentrant`, the lock and zero-share rejection, but drop every caller bound. *Four reads*: both Pool balances before the two transfers (also used for the deficit check) and after them; `n_i` = after − before, so surplus present before the call is excluded and a deficit present before the call reverts. *Two reads* (Uniswap-V2-style, different accounting rules): only the balances after payment; `n_i = balance_i − reserve_i`. Surplus present before the call is part of that balance, so it enters the depositor's `n_i`, the share calculation and the reserves. An earlier shortfall `d` is subtracted in the same way, so the incoming payment first covers it and the depositor is credited only with the rest (1,000 paid, 900 credited). Ordinary-token deposit of row C [measured]:

| Design | Pool `balanceOf` | Gas | Most important guarantee given up |
|---|---:|---:|---|
| Pool at `04eb336` | 14 | 108,185 | — |
| No payer check, direct | 10 | 104,135 | the payer-debit bound |
| Custodial Router (C) | 10 + 8 in Router | 230,294 gross | equal outcome for taxed tokens |
| Four reads | 4 | 94,079 | `minShares`, `maxExcess`, the debit bound, the re-plan (taxed token first: 1,000 instead of 900 token0 for the same shares), BI-2′ |
| Two reads | 2 | 92,445 | the surplus and deficit rules: a 200-token1 donation made earlier raised the depositor's shares from 1,272 to 1,414; a 100-token0 deficit was paid by the depositor |

Against the unchanged 492-test suite the three variants fail 16, 66 and 90 tests; apart from three ABI-list tests failed by the test adapter's extra entry point, every failure is in these guarantees. Among the tested variants, four reads is the lowest count that preserved this project's rules for surplus and deficit present before the call (the only case supported tokens can create [source, §9.6]); two reads is the lowest under the balance-minus-reserve rules; fewer reads were not tested. None was adopted; the production Pool is retained (student decision).

**Three smaller changes, first measured one at a time** (each on its own branch from `04eb336`; TEST_MATRIX §14.9) [gas]. (1) A later deposit reuses the Pool's own balance readings, 6 Pool + 4 payer `balanceOf` instead of 10 + 4: −3,437 (ordinary tokens), −3,573 / −3,594 (§5.2 taxed token), +243,957 per Pool deployment (≈ 71 deposits to recover on its own [estimate]), same outcomes and errors in the tested cases; a Pool with no payer-debit check (10 + 0 reads) measures 613 less than 6 + 4. (2) One Factory entry per pair: `createPair` −22,238; `getPair` as in Table 11.2. (3) Constant LP metadata: `createPair` −70,154, a standalone deployment −73,358, each getter ≈ −2,700. All three were adopted (student decision); Table 11.2 measures them together (deployment costs do not simply add up).

## 12. Limitations

Most important for users and LPs:

1. **Exit is not guaranteed for every token** accepted on deposit (§6.2, §9.3); no recovery path.
2. **Excess is not refunded**; with taxed tokens it is first-order in the tax, bounded only by `maxExcess` (§5.7).
3. **`minShares` bounds a share count, not value**; no per-token deposit minimum; the first deposit cannot be fully protected from front-running (§5.5, §5.6).
4. **A deficit of any size freezes the pool** until one of two things happens (§8.2, §8.3): `sync()` writes the reserve down to the balance, and the LPs bear that write-down pro rata, plus the arbitrage after the price jump; or a third party tops the balance back up, and the recorded reserves stay unchanged, so the LPs bear no write-down.
5. **The excess inflation channel** is bounded but open; the supported-token path is model-only (§9.2).

| Other disclosed limitations | § |
|---|---|
| Tests sample states; no formal proof | 10 |
| One immutable `surplusRecipient` per Factory; refunds need trust | 4.1, 8.1 |
| No MEV protection, oracle or pause; deadlines use `block.timestamp` | 7 |
| Small positions may be unredeemable; terminal pools cannot trade again | 6.3, 6.4 |
| Quotes ignore taxes and deficits; views unsafe mid-transaction | 2.4, 9.1 |
| Deposit/withdraw fields are positional (token0/token1); swaps use an address | 5.1 |
| The Pool does not emit the payer's debit or the unmatched amounts. The latter can be reconstructed from the Pool's logs using the pre-mint state (§5.2). | 5.2 |

## 13. Traceability

### 13.1 Development history

M1 toolchain · M2 Pool skeleton and maths · M3 initial deposit and lock · M4 later deposit and withdrawal · M5 swap · M6 `sync`/`skim`/deficits · M7 Factory · M8 measured deposit · M10 verification and gas · M11 this report (M9, a protocol fee, was out of scope). Full records: `docs/MILESTONES.md`, `docs/DECISIONS.md`, `docs/TEST_MATRIX.md`, `docs/THREAT_MODEL.md`, `docs/REPORT_NOTES.md`.

### 13.2 Code → report index

Each declaration below carries a NatSpec tag `@custom:report docs/REPORT.md §…` that points back to these sections.

| Code | § |
|---|---|
| `AMMMath.getAmountOut`, `AMMPool.getAmountOut` | 2.2–2.4 |
| `AMMMath.initialShares`, `AMMPool._update` | 3.2, 9.4 |
| `AMMFactory.createPair` | 4.1 |
| `AMMPool._pullMeasured`, `_pushMeasured`, `getReserves` | 4.2, 4.4, 6.2 |
| `AMMPool.addLiquidity`, `_pullLater`, `_mintLater`, `_checkInCallBalance`, `_checkPayerDebit` | 5 |
| `AMMPool.removeLiquidity` | 6 |
| `AMMPool.swapExactInput` | 7 |
| `AMMPool.sync`, `skim`, `_checkNoDeficit` | 8 |

### 13.3 References

Uniswap, `v2-core/contracts/UniswapV2Pair.sol` and `v2-periphery/contracts/UniswapV2Router02.sol`, https://github.com/Uniswap/v2-core and https://github.com/Uniswap/v2-periphery (read 2026-11-23). OpenZeppelin Contracts v5.7.0.

### 13.4 Test and decision IDs (lookup only; the main text cites test functions and files)

| ID | Meaning | Where |
|---|---|---|
| L, W, S, Q, R, B, P, X, Z, F; F1-T; I1–I10 | tests of deposit, withdrawal, swap, quote, reserves and `sync`/`skim`, balance changes inside a call (B09 = BI-2′), LP rules, ownerless ABI and reentrancy, numerical ranges, Factory; L46 = §5.2 example; F1-T = §9.2 excess study; stateful invariants (§10) | `test/` by topic |
| D…, U…, M*n*-*k*; T…; G…, V…, H1 | design decisions (e.g. M8-3: always measure the payer); threats; gas measurements and variants | `docs/`: `DECISIONS`, `THREAT_MODEL`, `TEST_MATRIX` §14 |
