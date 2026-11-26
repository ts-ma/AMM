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

Beyond a basic AMM, the design adds three things. (i) **Measured inputs** (§4.2, §5.3, §7): a deposit or a swap input is booked at the Pool's measured balance increase, not at the requested amount, so a transfer tax cannot inflate the reserves. On the way out, the Pool's balance must fall by exactly the amount sent (A8); withdrawals and swaps also check the recipient's measured net receipt against the caller's minimum (MIN-NET), `skim()` does not (§8.1). (ii) **User limits as revert conditions** (§5.4, §6.2, §7): each limit is compared with one measured or computed quantity, and a failed limit reverts the whole call; boundary tests show that the exact limit passes and one unit tighter reverts. (iii) **Recorded reserves separate from balances** (§4.4, §8): a direct transfer never changes a recorded reserve; it becomes surplus, which only `skim()` removes, or it refills an existing deficit.

### 1.2 Evidence labels

**[proof]** written mathematical argument · **[source]** inference from reading the code · **[model]** sampled integer Python model of the formulas, not the contract · **[test]** executed against the real contracts in Foundry's local EVM (evidence over sampled states, not a proof) · **[gas]** measured gas, harness and configuration stated · **[estimate]** arithmetic on measured [gas] values (e.g. break-even counts), not itself measured.

Notation: `r0, r1` recorded reserves; `S` LP supply; `n_i` amount the Pool actually received; `σ` shares minted; `u_i` unmatched "excess". Amounts are in smallest units.

## 2. How a trade is priced

### 2.1 Constant product

In a continuous model, without fees and ignoring integer rounding, a trade keeps `k = r0·r1` constant: `(r0 + a)·(r1 − out) = r0·r1`. The marginal price of token0 is `r1/r0`; larger trades get a worse average price. The contract works in integers and rounds every output down, so in practice `k` never falls and the fee makes it rise (§2.3).

### 2.2 Fee and exact formula

`AMMMath.getAmountOut`, with a 30 bps fee kept in the reserves (no protocol fee):

```
aFee = a · 9970;   out = ⌊ aFee · rOut / (rIn · 10000 + aFee) ⌋
```

This equals Uniswap V2's 997/1000 rule [source] (`AMMMath.getAmountOut`; V2 `Router02.getAmountOut`). `swapExactInput` applies it to the **measured** input (§7).

### 2.3 What the fee guarantees

[proof] From the formula, `(rIn·10000 + aFee)·(rOut − out) ≥ rIn·10000·rOut`. Since `rIn·10000 + aFee ≤ (rIn + a)·10000`, it follows that `(rIn + a)·(rOut − out) ≥ rIn·rOut`: **the product `k` never decreases in a swap**, and the fee makes it grow. This does **not** mean that every per-share claim grows: per share, the input-token reserve rises and the output-token reserve falls. What grows is the constant-product measure `√k/S` (§3.3). [test] Checked in 512-bit arithmetic after every successful swap (`testFuzz_Z01_S11_S15_swapMatchesFormula`; swap invariant I3 of the stateful suites, §10).

### 2.4 Quotes

`AMMPool.getAmountOut` returns the formula at the recorded reserves. It is not tax-aware (a taxed input delivers less; a taxed output pays the recipient less) and not deficit-aware. Quote = swap for exact tokens [test] `test_Q01_quoteEqualsSwapBothDirections`.

## 3. What an LP share represents

### 3.1 A pro-rata claim on recorded reserves

`h` of `S` shares redeem `⌊h·r_i/S⌋` of each token (§6.1). A direct transfer does not change the recorded reserves, so it never raises this per-share claim: it is surplus, which backs no shares, or it refills an existing deficit up to the recorded reserve (§8.3). A deposit's unmatched excess does enter the reserves, without extra shares (§5.7).

### 3.2 Opening a pool: first deposit and the permanent lock

(1) Anyone calls `AMMFactory.createPair(tokenA, tokenB)`; the caller gets no role and is not recorded. (2) The depositor (the *payer*, `msg.sender` of `addLiquidity`) approves the **Pool**, not the Factory, for at least `amount_iRequestMax` of each token, because the first deposit requests both caps in full. (3) The first `addLiquidity` (branch `totalSupply() == 0`) pulls both tokens and measures the receipts `n0, n1`; tokens already at the Pool's address are excluded and stay surplus. (4) The receipts become the reserves, so `n1/n0` sets the opening price; `maxDebit_i` and `minShares` apply, `maxExcess` has no effect. (5) `⌊√(n0·n1)⌋ − 1000` shares (`AMMMath.initialShares`) are minted to `p.recipient`, which may differ from the payer, and 1,000 to the Pool itself, where `AMMPool._update` forbids moving or burning them. [test] `test_L01_initialDepositSharesAndLock`, `test_L19_taxedInitialDepositUsesMeasuredNet`, `test_B09a_preExistingSurplusUnchanged_initial_allCases`; through the Factory `test_F06_initialDepositAndLock`. Whether a call takes this branch is decided at execution (§5.5).

**What the lock guarantees** [proof]. (a) `totalSupply()` never returns to 0, so the first-deposit branch, in which one depositor sets the price, cannot be reopened. (b) 1,000 shares exist forever and are never redeemed; through add, remove and swap this keeps both reserves positive ([test] `test_W06_lastLPExitsLockRemains`). Only `sync()` after a deficit, which needs an unsupported token, can lower a reserve to 0 (terminal pool, §6.4). (c) If the recorded reserve per share, `r_i/S`, rises by `Δ`, the 1,000 permanently locked shares' aggregate book claim on token i rises by `1,000·Δ`. This is a book claim, not a market value and not the net cost of a particular attack (§9.2). The lock thus keeps its pro-rata part of all fees and excess: negligible in a large pool, half of them if the initial `⌊√(n0·n1)⌋` is 2,000.

### 3.3 A pool-level measure that never decreases

[proof] Add and remove round against the actor, so per token `r_i'·S ≥ r_i·S'`; a swap keeps `S` and does not decrease `k` (§2.3). Therefore `k/S²` never decreases through add, remove or swap. Equivalently, `√(r0·r1)/S`, the geometric-mean reserve per share, never decreases [test: invariant I10, §10]. Exceptions: the initial deposit (`S` starts at 0) and `sync()` after a deficit, which lowers `k` (§8.2).

This measure is **not** the market value of a share. A swap lowers the per-share claim on the output token, and when the external price moves an LP can be worth less than simply holding the two tokens (impermanent loss).

## 4. Contracts and data structures

### 4.1 `AMMFactory`

State: `surplusRecipient` (immutable, shared by all its Pools), a private registry holding each pair once under its sorted order, `allPairs[]`. `getPair(tokenA, tokenB)` sorts its arguments and reads that entry, so both orders return the same Pool (0 if none). `createPair(tokenA, tokenB)` rejects zero addresses, identical tokens and addresses without code, sorts, rejects duplicates, deploys `new AMMPool(token0, token1, surplusRecipient)` and registers it. [test] `test/AMMFactory.t.sol`, `test/AMMFactoryPairLookup.t.sol`; invariant `invariant_I5_registryConsistent`.

### 4.2 `AMMPool`

| State | Type | Meaning |
|---|---|---|
| `token0`, `token1` | `address immutable` | sorted pair (`token0 < token1`, checked in the constructor) |
| `surplusRecipient` | `address immutable` | only destination of surplus (§8.1); the constructor rejects 0, `token0`, `token1` and the Pool, the Factory also rejects itself |
| `reserve0`, `reserve1` | `uint256 private` | recorded reserves (§4.4) |
| ERC-20 balances / supply | inherited | LP shares; `_update` enforces the lock rules |
| reentrancy lock | transient storage | `ReentrancyGuardTransient` |

Every Pool uses the same LP name and symbol, so wallets cannot tell pools apart by name. Two helpers carry the token accounting:

- `_pullMeasured(token, amount)`: Pool balance before → `transferFrom(msg.sender, Pool, amount)` → after; the increase is the receipt that is booked. A later deposit uses variants that reuse an earlier reading (`_pullFromKnown`, `_pullMeasuredEnd`; §5.3).
- `_pushMeasured(token, to, amount, minNet)` makes two checks of different kinds. **A8** (DECISIONS §5) is an equality on the Pool side: the Pool's balance must fall by exactly `amount`, the number subtracted from the reserve (else `OutboundTransferMismatch`). **MIN-NET** (DECISIONS §5) is a lower bound on the recipient side: `to`'s measured increase may be below `amount` for a taxed token, but must be at least `minNet` (else `InsufficientNetReceived`). Used by `removeLiquidity` and `swapExactInput`. `skim()` (`_skimToken`) applies A8 only, so a taxed token's `surplusRecipient` receives less [test] `test_R09_taxedSkimExactPoolSideRecipientReceivesLess`.

**Order of the entry points** [source]. The Pool must measure an incoming amount before it can book it, so the deposit and the swap transfer tokens in before they write reserves:

- `addLiquidity`: checks (including the deficit reads) → payer snapshots → pull(s) and measurement → BI-2′ and payer-debit checks → reserves and mint → event; no token call follows the reserve write.
- `swapExactInput`: checks → pull and measure the input → reserves → outbound transfer with A8 and MIN-NET → event.
- `removeLiquidity`: checks → burn and reserves → two outbound transfers → event (the Checks–Effects–Interactions order).
- `skim` sends surplus without writing reserves; `sync` writes reserves without a transfer.

While a token call runs, the Pool's five state-changing entry points (`addLiquidity`, `removeLiquidity`, `swapExactInput`, `sync`, `skim`) revert on re-entry: they share one `nonReentrant` lock, and `_update` mints or burns LP only while it is held. Still callable: the views (`getReserves`, `getAmountOut`, `balanceOf`, `totalSupply`) and LP `transfer`/`transferFrom`/`approve`, which change neither reserves nor supply. A callback reads pre-call reserves and supply during an inbound pull and post-swap reserves during the outbound transfer [test] `test_X05_midSwapInboundReadsPreCallState`, `test_X05_midSwapOutboundReadsPostEffectReserves`. The lock is per Pool and relies on a truthful `balanceOf` (§4.5).

### 4.3 `AMMMath`

Internal pure functions compiled into the Pool; tested on their own (`test/AMMMath.t.sol`) and through the Pool. OpenZeppelin `Math.mulDiv(x, y, d)` returns `⌊x·y/d⌋` with the product `x·y` held in 512 bits, so only the quotient must fit in 256 bits. `getAmountOut` calls `mulDiv(a·9970, rOut, rIn·10000 + a·9970)`; its first and third arguments are ordinary checked 256-bit arithmetic. `initialShares` forms `net0·net1` in checked 256 bits before `Math.sqrt`, so a first deposit with `n0·n1 ≥ 2²⁵⁶` reverts (Panic 0x11) [test] `test_Z06_initialShares_overflowBoundary`. The Pool's own calls (`mulDiv` in `removeLiquidity` and `_mintLater`; `mul512` with saturation in `_pullLater` and `_mulDivSat`) are separate (§9.5).

### 4.4 Recorded reserves versus balances

The Pool never prices from `balanceOf`. Per token, `balance − reserve` is **surplus** if positive and a **deficit** if negative (a token removed Pool balance; unsupported tokens only). Every write to `reserve0`/`reserve1` is in `addLiquidity` (first deposit), `_mintLater` (later deposit), `removeLiquidity`, `swapExactInput` or `_syncToken` (downward only) [source]. Hence: a direct transfer with no deficit is surplus; the per-share claim on recorded reserves is unchanged, and the tokens leave only through `skim()`. A direct transfer during a deficit refills the missing backing up to the reserve; reserves stay unchanged and only the part above them is surplus (§8.3). A deposit's unmatched excess and the swap fee do enter the reserves, without new shares (§5.7). So a donation can neither move the price through `sync` nor raise share value; the lock (§3.2) bounds the excess and fee channels (§9.2).

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
| ④ Pool's measured receipt `n_i` | 1,000 | 1,800 | `_pullFromKnown` for token0, `_pullMeasuredEnd` for token1 (200 burned as tax) |
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
4. **Pull and measure** the first token (`_pullFromKnown`: its before-balance is its reading from step 1); only if it delivered a different amount than planned, re-plan the second token from what arrived; then pull and measure the second token (`_pullMeasuredEnd`).
5. **After the last transfer**: BI-2′ (`addLiquidity` only; initial deposit `_checkInCallBalance`, later deposits `_checkInCallBalanceLater`, reusing the second transfer's closing balance and rereading the first token): from the start snapshot to the end, each Pool balance rose by at least this call's own measured receipt, so no foreign removal hides inside the call; then the payer-debit bound (`_checkPayerDebit`).
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

**Why two bounds per token.** `RequestMax_i` limits what the Pool asks the token contract for; `maxDebit_i` limits how much `msg.sender`'s balance actually falls over the whole call. `RequestMax = 100, maxDebit = 105` requests at most 100 while tolerating up to 5 of extra sender-side fees; for an ordinary token the two can be equal, but the debit is still measured.

**`minShares` versus `maxExcess`** (§5.2 example): bob's 1,272 shares pass `minShares = 1,272`, yet the token0 excess of 100 makes `maxExcess0 = 99` revert the same deposit. With a taxed token `token1First` matters, because the second request is re-planned from what the first delivered (§5.7). The Pool has no defaults: every field is supplied by the caller.

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

Both are defined in §4.2. A8 rejects tokens that charge the Pool extra or move its balance mid-transfer [test] `test_B06_overDebitRejectedByA8`, `test_W10_classB_overDebitToken0Reverts`; MIN-NET judges `min_iNet` on what a taxed token actually delivers [test] `test_W04_minNetBoundaryToken0`, `test_W05_taxedToken0Output`. Because A8 is an equality, a token whose transfers differ by rounding (share-based balances) can be deposited but not reliably withdrawn. A one-sided check would admit it, but would also let an under-delivering token leave the shortfall in the Pool as surplus; A8 was kept.

### 6.3 Small positions

If `r_i/S < 1` (e.g. a 2-decimal token against an 18-decimal one), fewer than `⌈S/r_i⌉` shares pay 0 of token i and revert `InsufficientLiquidityBurned`, as in Uniswap V2. [test] `test_W12_positionBelowThresholdCannotExit`: `S = 10¹²`, `r = 10⁴`; a remainder of 5·10⁷ shares cannot exit until it reaches 99,995,001.

### 6.4 Terminal pool

If `sync()` lowers a reserve to 0 while shares exist, deposits and swaps revert and withdrawals still pay the other token [test] `test/AMMPoolTerminal.t.sol`.

## 7. Swapping

`swapExactInput(tokenIn, amountIn, minNetAmountOut, recipient, deadline)`: checks (deadline, recipient, valid `tokenIn`, non-zero input and reserves, no deficit) → pull and measure `a` → `out` from §2.2 (0 reverts) → reserves → send (§4.2). Unlike Uniswap V2's optimistic `swap`, the Pool pulls the input first and computes the output itself; there are no flash swaps. The direction is an address, so callers cannot invert it by misordering tokens. Taxed tokens: the input is priced on what arrived and `minNetAmountOut` is judged on what the recipient received [test] `test_S05_taxedInputPricedOnMeasuredNet`, `test_S06_taxedOutputMinNetBoundary`, `testFuzz_Z04_swapGrossVsNet`. There is no MEV protection beyond `minNetAmountOut` and `deadline`, and no view may serve as a price oracle (one transaction can move the spot price).

## 8. Reserves, `sync()` and `skim()`

### 8.1 Surplus and `skim()`

`skim()` sends each token's surplus to the immutable `surplusRecipient`; anyone may call it, nobody chooses the recipient. Surplus never enters reserves [test] `test_R01_directTransferDoesNotChangeReserves`, `test_R05_surplusNotAbsorbed`; invariants I8, I9 (§10). Refunds of mistaken transfers rely on whoever controls `surplusRecipient`; the growth of an unsupported rebasing or yield token also goes there, not to LPs.

### 8.2 Deficit and `sync()`

A deficit in either token blocks add, remove and swap (`ReserveDeficit`, `_checkNoDeficit`); the block lifts only when **both** balances cover their reserves [test] `test_R08_deficitBothBlocksAll`, `test_R24_bothDeficitsOneRefilledStillBlocks`. `sync()` only lowers a reserve to the balance; LPs bear the booked loss pro rata and, as the price jumps, an extra arbitrage loss of about `P·d²/(4x)` (fees ignored) [proof, not tested]. A tiny deficit gives nobody a reason to pay for `sync()`, so integrators should call it.

### 8.3 Where tokens sent to the Pool end up

| Case | Effect | Evidence |
|---|---|---|
| Direct transfer, no deficit | surplus; only `skim()` removes it; LPs do not benefit | [test] `test_R01_directTransferDoesNotChangeReserves`; invariant I9 |
| Direct transfer during a deficit | refills the backing up to the reserve, only the part above it is surplus; a partial top-up keeps the block, an exact one lifts it; reserves unchanged, so LPs bear no write-down | [test] `test_R24_partialTopUpStillBlocksExactTopUpRestores`, `test_R08_deficitToken0BlocksAll` |
| Excess inside a later `addLiquidity` | joins the reserves without extra shares, benefits all shares, moves the price slightly | [test] §5.2 example; `test_F1T5_tier1_maxExcessBoundary_token0First` |

Uniswap V2's `sync()` sets reserves to balances in both directions, so a transfer plus `sync()` adds to reserves [source] (V2 `UniswapV2Pair.sync`). Here `sync()` only lowers, which removes the `sync`/`skim` race and that price route, at the cost of a fixed `surplusRecipient`.

## 9. Security

Three kinds of outcome, one example each:

- **Blocked** (the call reverts): an outbound transfer that charges the Pool more than the amount sent (A8) [test] `test_B06_overDebitRejectedByA8`.
- **Bounded by the caller's limit**: a swap whose net output would fall below `minNetAmountOut` [test] `test_S04_minNetBoundary`. A limit bounds only its own quantity: `minNetAmountOut` the recipient's net output, `minShares` a share count (not value, §5.6), `maxExcess_i` the unmatched amount of token i.
- **Open, disclosed**: a token that later refuses the Pool's outbound transfers blocks withdrawal of both tokens, while new deposits still succeed (§9.3) [test] `test_X06_limitation_modeA_outboundRefused_drainAndNewDeposits`.

### 9.1 Reentrancy

Call order and lock coverage are in §4.2. Malicious token callbacks are tested for add, remove, swap, `sync` and `skim`, both bubbling and swallowed [test] `AMMPoolReentrancy`, `AMMPoolSyncSkimReentrancy`. Views are unguarded (DECISIONS M5-5), so a mid-transaction read is not a safe price (read-only reentrancy, THREAT_MODEL T13).

### 9.2 Inflation and donation

Direct donations do not change recorded reserves (§4.4). Deposit excess and swap fees raise the recorded reserve per share; by §3.2 (c), each rise of `r_i/S` by `Δ` adds `1,000·Δ` to the locked shares' book claim [proof]. Each depositor bounds the excess with `maxExcess`. The evidence has four separate parts:

- **Bonus-token experiment, local EVM** [test] (`test/AMMPoolInflation.t.sol`, `test_L13b_*`). An unsupported token mints a bonus `D = 10²⁵` per token to the Pool during the attacker's own deposit (counted as paid). bob then makes 5,000 deposits (token0 request `w` from a fixed generator in `[10²¹, 10²¹ + 2⁶⁴ − 1]`, unlimited token1 request) with `maxExcess0 = maxExcess1` either unbounded or `⌊w·10/10,000⌋` ("10 bps", an absolute amount derived from token0). Unbounded: attacker profit ≈ 9.08·10²¹ per token (wallet change minus `D`, gas excluded); 10 bps: 4,442 of 5,000 deposits revert and the attacker loses.
- **Honest-LP experiment, local EVM** [test] (`test/AMMPoolF1HonestLP.t.sol`): the same sequence with one honest LP holding 0.99999901 % of the supply before the donation; the attacker's result per token (wallet change minus `D`) turns negative.
- **Reduced-scale fee channel, local EVM** [test] (`test/AMMPoolF1SwapFeeChannel.t.sol`): with supported tokens, the legitimate way to raise per-share value is trading fees; up to 2,000 round trips were executed, and the attacker as the only LP loses exactly what stays in the Pool.
- **Full fee path** [model]: an estimated 32,000–58,000 round-trip swaps would be needed to reach the bonus scale; capital, execution and net profitability are **not verified**.

Status: a known economic limitation of this Pool, bounded by each depositor's own `maxExcess`; not a demonstrated exploit with supported tokens. These experiments test this Pool only; no claim is made about other designs. Full figures: THREAT_MODEL T4, TEST_MATRIX §3.4.

### 9.3 Exit safety

Deposits accept more token behaviours than withdrawals. A token that later charges the Pool on outbound transfers, blacklists it or reverts `balanceOf` traps both tokens, because a withdrawal transfers both atomically; there is no recovery path in an ownerless design [test] `AMMPoolM8Limitations`.

### 9.4 Access control and LP rules

No owner, admin function, pause, upgrade, fallback or `receive`; [test] `test_X03_static_abiFunctionsEqualApprovedList` compares the compiled ABI with the approved list. `_update` makes the lock immovable, rejects LP sent to the Pool and rejects minting or burning outside a guarded entry point [test] `test_P04_noExternalMintOrBurn` to `test_P08_supplyChangesOutsideGuardRevert` (`test/AMMPoolLiquidity.t.sol`).

### 9.5 Arithmetic

Checked arithmetic turns overflow into a revert, never a wrong value; the hand-derived ranges are in ARCHITECTURE §6.6 (e.g. initial deposit `n0·n1 < 2²⁵⁶`). Later-deposit share maths saturates and is caught by the checked `S + σ`. [test] Overflow-boundary tests `test_Z06_*`, `test_Z08_saturatedSharesPanicBeforeExcessCheck`; 6/18-decimal values near `2¹¹²`, `testFuzz_Z03_mixedDecimalsNearTop`.

### 9.6 Balance changes inside a call

BI-2′ guards `addLiquidity` only. `swapExactInput` and `removeLiquidity` rely on the entry deficit check, measuring each own transfer from a fresh snapshot, A8, MIN-NET and `nonReentrant`. With an unsupported token whose callback moves the Pool's balance outside the transfer being measured (THREAT_MODEL T30), a swap or remove does not detect a foreign decrease of **surplus** ([test] `test_B10_limitation_swapAndRemove_maskedForeignLossSucceeds`), nor, within that call, a decrease that creates a **deficit**. From the next call on, add, remove and swap revert `ReserveDeficit` until both balances cover their reserves (§8.2): either `sync()` writes the reserve down to the balance (down to 0 makes the Pool terminal, §6.4), or a transfer restores the balance to at least the reserve [test] `test_R08_operationsResumeAfterSync`, `test_R24_partialTopUpStillBlocksExactTopUpRestores`. Supported tokens make no such callback.

## 10. Verification

Unit tests use exact values from independent models; fuzz tests cover the documented ranges; two stateful invariant suites (exact and 1 %/3 % taxed tokens, 256 runs × 500 random calls) check after every call: LP supply and lock (I1), balance ≥ reserve (I2), the swap formula and `k` (I3), debit ≤ cap and ≤ `maxDebit` (I6), exact outbound amounts (I7), `skim` only to `surplusRecipient` (I8), surplus changes only by donation and `skim` (I9), and §3.3 (I10). Every feature had a mutation check (deliberate bugs in one source file that a test had to catch); survivors were analysed and test gaps closed. `forge lint` findings were triaged (TEST_MATRIX §16). **Not done:** formal verification, symbolic execution, slither, Echidna/Medusa, fork tests, an external audit.

**Final regression** on the final code: `forge build` succeeded; **527 tests in 59 suites passed, 0 failed**, both with the default fuzz runs and with `FOUNDRY_FUZZ_RUNS=10000`; the invariant suites use their own 256 × 500 setting in both runs. Record: `docs/TEST_MATRIX.md` §14.11.

## 11. Gas

### 11.1 Measured baseline

[gas] `test/gas/GasG02.t.sol` on the final code (§10): one call per test, arguments prepared outside the measured interval, cold state (`isolate = true`). Table 11.2 uses another harness with its own scenarios (later deposit 105,377 here, 104,721 there); compare values only within one table.

| Call | Gas | Call | Gas |
|---|---:|---|---:|
| `addLiquidity` initial | 232,000 | `swapExactInput` | 82,540 |
| `addLiquidity` later | 105,377 | `skim` (both tokens) | 101,777 |
| `removeLiquidity` | 94,105 | `sync` / `skim` no-op | 40,067 / 39,905 |
| deploy `AMMPool` | 2,592,900 | `createPair` | 2,451,531 |

### 11.2 Optimisations adopted and rejected

| | Change | Measured effect [gas] | Decision |
|---|---|---|---|
| Adopted | `removeLiquidity` burns the caller's shares **before** computing the amounts (`mulDiv`) | failing for insufficient LP 27,926 instead of 30,469; success −6 (TEST_MATRIX §14.1) | kept: cheaper failure, clearer error (`ERC20InsufficientBalance`, not an overflow panic) |
| Adopted | LP `name()` / `symbol()` return constants instead of two stored strings | getters −2,707 / −2,696 (Table 11.2) | kept; `pure` alone changed no gas |
| Adopted | A later deposit reuses the Pool's balance readings (6 + 4 reads instead of 10 + 4; §5.3); the Factory stores each pair once and `getPair` sorts | Table 11.2 | kept; relies on only read-only calls between a reading and its reuse |
| Rejected | VP: `uint112` reserves in one storage slot (as Uniswap V2) | ≈ −4,300 per add/remove/swap, +159,273 per deployment | caps reserves at `2¹¹²` (13 range tests fail) |

Table 11.2 compares the combined implementation with commit `04eb336` [gas], with the same harness, `test/gas/GasM11Combined.t.sol`, and the same scenarios on both commits (finite `maxDebit`; Δ = final − `04eb336`; "repeated" = second lookup in one transaction). Controls: swap +1, remove 0; full matrix TEST_MATRIX §14.11.

| Operation (Table 11.2) | `04eb336` | final | Δ | % |
|---|---:|---:|---:|---:|
| deploy `AMMFactory` / `AMMPool` directly | 2,840,966 / 2,424,914 | 3,058,070 / 2,595,417 | +217,104 / +170,503 | +7.6 / +7.0 |
| `createPair`: first pair / a second, different pair (Pool deployment included) | 2,316,852 / 2,299,740 | 2,451,519 / 2,434,407 | +134,667 each | +5.8 / +5.9 |
| `addLiquidity` initial | 231,973 | 231,969 | −4 | <0.01 |
| later deposit, ordinary, token0 / token1 first | 108,158 / 108,180 | 104,721 / 104,722 | −3,437 / −3,458 | −3.2 |
| later deposit, §5.2 taxed, taxed second / first | 193,456 / 193,847 | 189,883 / 190,253 | −3,573 / −3,594 | −1.8 / −1.9 |
| `getPair` sorted / reversed: cold; repeated in one tx; reversed after sorted | 5,975; 1,255; 3,255 | 6,076 / 6,086; 1,356 / 1,366; 1,366 | +101 / +111; −1,889 | +1.7 … +8.8; −58.0 |
| `name()` / `symbol()` | 6,322 / 6,321 | 3,615 / 3,625 | −2,707 / −2,696 | −42.8 / −42.7 |

Singly from `04eb336` (TEST_MATRIX §14.9) [gas]: snapshot reuse −3,437 per ordinary later deposit, +243,957 per Pool deployment; one Factory entry, `createPair` −22,238; constant metadata, `createPair` −70,154. Not additive (Pool deployment: singles +170,599, combined +170,503), so the estimate below uses combined values only.

Break-even per Pool [estimate]: `createPair` through a deployed Factory, one initial deposit and `N` ordinary later deposits give Δ(N) = 134,667 − 4 − 3,437·N: +100,293 at N = 10, −209,037 at N = 100, no dearer from **N = 40**; with a new Factory (+217,104), from N = 103. Paid on-chain `getPair` calls add their Δ per lookup.

VU (`unchecked` on arithmetic proven safe) saved 263–534 gas per state-changing call [gas]; not adopted, because checked arithmetic turns a mistake in those proofs, or in a later edit, into a revert instead of a silent wrap. Other variants: TEST_MATRIX §14.

### 11.3 Uniswap V2, qualitative

No gas comparison with Uniswap V2 was made (V2 needs Solidity 0.5.16 and was not imported), so none is claimed. Design differences from the V2 source (§13.3): V2's `mint` credits `balance − reserve` after a router has transferred the tokens, whereas this Pool books its own measured receipts (§5.3; the two-reads variant of §11.4 implements V2's rule). V2 keeps user minima and deadlines in Router02; this Pool checks them in the Pool for every caller (§5.4; Router experiment C, §11.4). V2's `sync` moves reserves both ways; here it only lowers them (§8.3).

### 11.4 Alternatives evaluated

[gas] Same method as §11.1, on isolated, unmerged branches with the code of `04eb336`: A and B on `a85cd8d` (TEST_MATRIX §14.7); C and the minimal deposits on `da59581` (§14.8).

| Alternative | Measured effect | Trade-off | Decision |
|---|---|---|---|
| A: skip the payer snapshot of token i when `maxDebit_i = type(uint256).max` | Later deposit, ordinary tokens [gas]: both MAX −3,846; one MAX −1,860; both finite +127. The finite side still binds [test]. | Saves gas only for callers who give up the debit bound; the others pay +127. | Not adopted: one uniform rule, always measure the payer. |
| B: one shared Pool implementation, ERC-1167 clones with immutable arguments | Micro-benchmark, not a full Pool [gas]: a clone call costs +2,588 (delegatecall) to +6,072 (reading the three addresses); creating a clone 115,269 vs 2,159,325 for `new AMMPool`. | ≈ 2.04M saved once per pair; at +6,072 per call, offset after about 337 calls [estimate]. Constructor checks move to the Factory. | Not adopted: a busy Pool would pay the per-call overhead on every call. |
| C: payer-debit check in an optional custodial Router (prototype), not the Pool | Ordinary tokens [gas]: Pool 108,185; direct without the check 104,135 (−4,050); through the Router 230,294 gross (refund counter 45,386 not subtracted). §5.2 taxed token [test]: 1,145 shares through the Router vs 1,272 direct for the same 2,000 token1 paid. | Direct callers lose the debit bound; the custodial Router makes 4 `transferFrom` instead of 2, so a token taxed on every transfer is taxed twice. | Not adopted; Pool retained. |

**Minimal deposits (same experiment).** Two variants keep the caps, step-2 planning, `nonReentrant`, the lock and zero-share rejection, but drop every caller bound. *Four reads*: Pool balances before and after the two transfers, `n_i` = after − before. *Two reads* (V2's rule): balances after payment only, `n_i = balance_i − reserve_i`, so earlier surplus is credited to the depositor and an earlier shortfall is charged to them. Ordinary-token deposit of row C [gas]; outcomes [test]:

| Design | Pool `balanceOf` | Gas | Most important guarantee given up |
|---|---:|---:|---|
| Pool at `04eb336` | 14 | 108,185 | — |
| No payer check, direct | 10 | 104,135 | the payer-debit bound |
| Four reads | 4 | 94,079 | `minShares`, `maxExcess`, the debit bound, the re-plan, BI-2′ |
| Two reads | 2 | 92,445 | the surplus and deficit rules: a 200-token1 donation made earlier raised the depositor's shares from 1,272 to 1,414; a 100-token0 deficit was paid by the depositor |

Against the unchanged 492-test suite the three variants fail 16, 66 and 90 tests [test]; apart from three ABI-list tests (the adapter's extra entry point), every failure is in these guarantees. Four reads was the lowest tested count that kept this project's surplus and deficit rules. None was adopted.
## 12. Limitations

Most important for users and LPs:

1. **Exit is not guaranteed for every token** accepted on deposit (§6.2, §9.3); no recovery path.
2. **Excess is not refunded**; with taxed tokens it is first-order in the tax, bounded only by `maxExcess` (§5.7).
3. **`minShares` bounds a share count, not value**; no per-token deposit minimum; the first deposit cannot be fully protected from front-running (§5.5, §5.6).
4. **A deficit of any size freezes the pool** (§8.2, §8.3) until `sync()` writes the reserve down (LPs bear the write-down pro rata, plus the arbitrage after the price jump) or a third party tops the balance back up (reserves unchanged, no write-down).
5. **The excess inflation channel** is bounded but open; the supported-token path is model-only (§9.2).

| Other disclosed limitations | § |
|---|---|
| One immutable `surplusRecipient` per Factory; refunds need trust | 4.1, 8.1 |
| No MEV protection, oracle or pause; deadlines use `block.timestamp` | 7 |
| Small positions may be unredeemable; terminal pools cannot trade again | 6.3, 6.4 |
| Quotes ignore taxes and deficits; views unsafe mid-transaction | 2.4, 9.1 |
| Deposit/withdraw fields are positional (token0/token1); swaps use an address | 5.1 |
| No event for the payer's debit or the unmatched amounts (the latter reconstructable from the pre-mint state) | 5.2 |

## 13. Traceability

### 13.1 Development history

Milestones M1–M8 built the Pool, Factory and measured deposit, M10 verification and gas, M11 this report (M9, a protocol fee, out of scope). Records in `docs/`: `MILESTONES`, `DECISIONS`, `TEST_MATRIX`, `THREAT_MODEL`, `REPORT_NOTES`.

### 13.2 Code → report index

Each declaration below carries a NatSpec tag `@custom:report docs/REPORT.md §…` that points back to these sections.

| Code | § |
|---|---|
| `AMMMath.getAmountOut`, `AMMPool.getAmountOut`; `AMMMath.initialShares`, `AMMPool._update` | 2.2–2.4; 3.2, 9.4 |
| `AMMFactory.createPair`; `AMMPool._pullMeasured`, `_pushMeasured`, `getReserves` | 4.1; 4.2, 4.4, 6.2 |
| `AMMPool.addLiquidity`, `_pullLater`, `_pullFromKnown`, `_pullMeasuredEnd`, `_mintLater`, `_checkInCallBalance`, `_checkInCallBalanceLater`, `_checkPayerDebit` | 5 |
| `AMMPool.removeLiquidity`; `AMMPool.swapExactInput` | 6; 7 |
| `AMMPool.sync`, `skim`, `_checkNoDeficit` | 8 |

### 13.3 References

Uniswap, `v2-core/contracts/UniswapV2Pair.sol` and `v2-periphery/contracts/UniswapV2Router02.sol`, https://github.com/Uniswap/v2-core and https://github.com/Uniswap/v2-periphery (read 2026-11-23). OpenZeppelin Contracts v5.7.0.

### 13.4 Test and decision IDs (lookup only; the main text cites test functions and files)

| ID | Meaning | Where |
|---|---|---|
| L W S Q R B P X Z F; F1-T; I1–I10 | tests: deposit, withdrawal, swap, quote, reserves/`sync`/`skim`, in-call balance (B09 tests BI-2′), LP rules, ABI/reentrancy, ranges, Factory; L46 = §5.2; F1-T = §9.2; invariants (§10) | `test/` |
| D, U, A, MIN-NET, M*n*-*k*; BI; T; G, V, H1 | decisions (e.g. A8, M8-3); balance invariants; threats; gas variants | `DECISIONS` §1, §4, §5, §15; `ARCHITECTURE` §5.5; `THREAT_MODEL` §4; `TEST_MATRIX` §14 |
