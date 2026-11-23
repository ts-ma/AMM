# A Constant-Product AMM with Measured Token Accounting — Design Report

**Status:** M11 draft, 2026-11-23. Code base: branch `m11-report`; `src/` logic unchanged since the M8 acceptance (`550bc80`), comments only in M11.
**Toolchain:** Solidity 0.8.38, Foundry (forge 1.9.0), OpenZeppelin Contracts v5.7.0; optimizer on, 200 runs, `evm_version = osaka`, `via_ir = false`.

Section numbers in this report are stable. Source comments refer to them as "Report §n", and the report refers back to files, contracts, functions and tests. Project milestones (M1–M10) and decision IDs (D…, U…, A…, M…-n in `docs/DECISIONS.md`) are given only for traceability; §13 maps them.

---

## 1. Introduction

### 1.1 What was built

Two contracts and one library implement a two-token constant-product automated market maker (AMM):

| Component | File | Role |
|---|---|---|
| `AMMFactory` | `src/AMMFactory.sol` | Deploys one `AMMPool` per unordered token pair and keeps a registry (`getPair`, `allPairs`). Ownerless. |
| `AMMPool` | `src/AMMPool.sol` | Holds the two tokens, records reserves, prices swaps, mints and burns LP shares. It **is** the LP token (OpenZeppelin `ERC20`). Ownerless and immutable. |
| `AMMMath` | `src/libraries/AMMMath.sol` | Pure maths: the swap quote with the 0.3 % fee and the initial-share square root. |
| `IAMMPool` | `src/interfaces/IAMMPool.sol` | The deposit parameter struct `AddLiquidityParams`. |

The public interface is: `addLiquidity`, `removeLiquidity`, `swapExactInput`, `getAmountOut`, `getReserves`, `sync`, `skim`, the LP ERC-20 functions, and `AMMFactory.createPair`.

The design goal beyond a basic AMM was to keep the Pool's accounting correct for tokens that do not deliver exactly what was requested (transfer taxes), and to make every user protection a precise, testable statement.

### 1.2 How to read the evidence

Every important claim carries one of these labels:

| Label | Meaning |
|---|---|
| **[proof]** | A written mathematical argument (in this report, a test header or `docs/`). |
| **[source]** | An inference from reading the code, not separately executed. |
| **[model]** | An integer Python model of the approved formulas, sampled; not the Solidity code. |
| **[test]** | Executed against the real contracts in Foundry's local EVM (unit, fuzz or invariant). |
| **[gas]** | Measured gas with the stated configuration and harness. |

A [test] is evidence over the sampled states, not a proof. A [model] result is weaker than a [test] result because it does not run the contract.

### 1.3 Notation

`r0, r1` recorded reserves; `S` LP total supply; `n_i` the amount the Pool actually received of token i (measured net); `σ` shares minted; `u_i` the unmatched part of a deposit ("excess"); `⌊x⌋`, `⌈x⌉` floor and ceiling. Amounts are in each token's smallest unit.

---

## 2. How the AMM prices a trade

### 2.1 Constant product

The Pool quotes prices from its two recorded reserves. Without fees, a trade keeps the product `k = r0·r1` constant: putting `a` of token0 in and taking `out` of token1 out must satisfy `(r0 + a)·(r1 − out) = r0·r1`. The marginal price of token0 in token1 is `r1/r0`; larger trades move along the curve and get a worse average price (price impact).

### 2.2 The fee and the exact formula

The fee is 30 basis points of the input, kept entirely in the reserves (no protocol fee). Code: `AMMMath.getAmountOut`, constants `FEE_BPS = 30`, `BPS_DENOMINATOR = 10_000`:

```
aFee = a · 9970
out  = ⌊ aFee · rOut / (rIn · 10000 + aFee) ⌋
```

This is the same formula as Uniswap V2's 997/1000 [source]. Output is rounded down, so rounding always favours the Pool.

### 2.3 Why the product never decreases

[proof] (ARCHITECTURE §6.5): with `out` as above, `(rIn·10000 + aFee)·(rOut − out) ≥ (rIn·10000)·rOut`, hence `(rIn + a)·(rOut − out) ≥ rIn·rOut`. Each swap therefore leaves `k` at least as large, and because no shares are minted, each LP share's claim grows by the fee.
[test] The inequality is asserted in 512-bit arithmetic after every successful swap: `test/AMMPoolSwap.t.sol` `testFuzz_Z01_S11_S15_swapMatchesFormula`, and in the stateful invariant suites (§10.2, I3).

### 2.4 Quoting

`AMMPool.getAmountOut(tokenIn, amountIn)` returns the formula's output for an exact input at the recorded reserves. It is not tax-aware: for a taxed input token the Pool receives less than `amountIn`, and for a taxed output token the recipient receives less than `out` (§7.3). `test_Q01_quoteEqualsSwapBothDirections` [test] shows quote = swap for exact tokens.

---

## 3. What an LP share represents

### 3.1 A pro-rata claim on the recorded reserves

Holding `h` of `S` shares is a claim on `h/S` of each recorded reserve. Redemption pays `⌊h·r_i/S⌋` of each token (§6.1). Tokens sent to the Pool outside its functions are **not** part of the reserves and do not back shares (§8).

### 3.2 First deposit and the permanent lock

The first depositor sets the price. Shares are `⌊√(n0·n1)⌋ − 1000`; the 1,000 shares are minted to the Pool itself and can never move or be burned (`AMMPool._update`, rules 1–3). The lock makes the "tiny first deposit plus donation" inflation attack expensive (§9.2) and keeps both reserves positive forever.

Consequence: the lock holds a pro-rata part of everything the Pool ever earns. In a large pool this is negligible; if the initial `⌊√(n0·n1)⌋` is 2,000, half of all fees and excess accrue to the lock [source] (DECISIONS D8 note).

Tests: `test_L01_initialDepositSharesAndLock`, `test_L17_gross1001SucceedsWithOneShare`, `test_P05_poolLPZeroBeforeAndExactlyLockAfter`, `test_P06_transferToPoolReverts`, `test_P07_poolHeldLPCannotMove` (`test/AMMPoolLiquidity.t.sol`) [test].

### 3.3 Existing holders never lose per-share value through add, remove or swap

[proof] For add and remove, `r_i'·S ≥ r_i·S'` per token (rounding is always against the actor); for swaps `S' = S` and `r0'·r1' ≥ r0·r1` (§2.3). So `k/S²` never decreases. Exceptions by design: `sync()` after a deficit (§8.2) and the initial deposit.
[test] Invariant I10 in `test/AMMPoolInvariant.t.sol` checks this after every call of 256 × 500-call random sequences, for exact and taxed tokens.

### 3.4 Rounding direction

All divisions round against the caller: swap output down, shares down, redemption down, the matched part of a deposit up (§5.3). Small positions can therefore be unredeemable (§6.3).

---

## 4. Architecture: how Factory, Pool and library work together

### 4.1 Factory

`AMMFactory.createPair(tokenA, tokenB)` rejects the zero address, identical tokens and addresses without code, sorts the pair, rejects duplicates, deploys `new AMMPool(token0, token1, surplusRecipient)` and registers it under both orderings. It holds no funds and has no owner; every Pool it creates shares one immutable `surplusRecipient` (§8.1).
Tests: `test/AMMFactory.t.sol` (F01–F05) [test]; registry invariant I5, `test/AMMFactoryInvariant.t.sol` [test] (§10.2).

### 4.2 Pool

The Pool is the only contract holding user funds. `addLiquidity`, `removeLiquidity`, `swapExactInput`, `sync` and `skim` are `nonReentrant` (OpenZeppelin `ReentrancyGuardTransient`, transient storage) and follows checks → measured interactions → accounting checks → effects. Token transfers go through `SafeERC20`.

Two internal measurement helpers carry the token accounting:
- `_pullMeasured(token, amount)`: Pool balance before, `transferFrom(msg.sender, Pool, amount)`, balance after; the difference is what the Pool received.
- `_pushMeasured(token, to, amount, minNet)`: the Pool's balance must fall by exactly `amount` (rule A8), and the recipient's measured increase must be at least `minNet` (rule MIN-NET).

### 4.3 Library

`AMMMath` has only internal pure functions: it has no state and its code is compiled into the Pool. It is tested on its own (`test/AMMMath.t.sol`) and through the Pool.

### 4.4 Recorded reserves versus balances

The Pool stores `reserve0`, `reserve1` and never reads `balanceOf` to price anything. The difference `balance − reserve` is either **surplus** (positive: unsolicited transfers) or **deficit** (negative: a token that took balance away). Only five code paths write reserves: initial deposit, later deposit, `removeLiquidity`, `swapExactInput`, and `sync` (downward only) [source]. This separation is what makes donation and balance-manipulation attacks ineffective (§8, §9.2).

### 4.5 Which tokens are supported

| Tier | Behaviour | Status |
|---|---|---|
| 0 | Standard ERC-20: debit = credit | supported |
| 1 | Inclusive transfer tax with a fixed rate (the recipient receives `g − ⌊g·t/10000⌋`, the sender is debited `g`) | supported |
| — | Deposits only: unknown, random or changing inclusive taxes; extra sender-side debits bounded by `maxDebit` | accepted on deposit, may revert on the user's bounds |
| — | Rebasing, exclusive fee-on-transfer, untruthful `balanceOf`, hooks, blacklisting | unsupported; some are detected (A8), others behave outside the guarantees |

A successful deposit does not prove that a token can be withdrawn later (§9.3).

### 4.6 Ownerless and immutable

No owner, no admin function, no pause, no upgrade, no fallback or `receive`. `test/AMMPoolOwnerless.t.sol` (X03) compares the compiled ABI with the approved function list and calls admin-style selectors, which fail [test].

---

## 5. Depositing liquidity

### 5.1 The interface

`addLiquidity(IAMMPool.AddLiquidityParams p) → (net0, net1, shares)`. Fields per token: `amount{0,1}RequestMax` (cap on what the Pool may request), `maxDebit{0,1}` (cap on the payer's actual balance decrease), `maxExcess{0,1}` (cap on the unmatched amount left in the reserves). Shared: `minShares`, `recipient`, `deadline`, `token1First` (pull order). Fields marked 0/1 refer to the sorted token order (token0 = lower address); ARCHITECTURE §7.10 has the full mapping.

### 5.2 One deposit, followed through every stage

Executed on the real Pool in `test/AMMPoolReportExample.t.sol` `test_L46_reportWorkedDeposit` [test]; values computed beforehand by an independent integer model [model].

State: reserves `(10,000, 20,000)`, `S = ⌊√(2·10⁸)⌋ = 14,142`. token1 charges a 10 % inclusive tax on transfers into the Pool; token0 is exact. bob calls with caps `(1,000, 2,500)`, `maxDebit (1,000, 2,000)`, `maxExcess (100, 1)`, `minShares 1,272`, token0 first.

| Stage | token0 | token1 | Where |
|---|---:|---:|---|
| ① Most the Pool may request (`RequestMax`) | 1,000 | 2,500 | caller |
| ② Planned request at the current ratio (step 2) | 1,000 | 2,000 | `_pullLater` |
| ③ Payer's actual debit | 1,000 | 2,000 | measured; ≤ `maxDebit` |
| ④ Pool's measured receipt `n_i` | 1,000 | 1,800 | `_pullMeasured`; 200 burned as tax |
| ⑤ Shares `σ = min ⌊n_i·S/r_i⌋` | 1,414 | **1,272** | `_mintLater` |
| ⑥ Matched part `⌈σ·r_i/S⌉` | 900 | 1,799 | `_mintLater` |
| ⑦ Excess `u_i = n_i − matched` | **100** | **1** | ≤ `maxExcess` |
| ⑧ New reserves / supply | 11,000 | 21,800 | `S = 15,414` |

Each bound is binding: with `maxDebit1 = 1,999`, `maxExcess0 = 99` or `minShares = 1,273` the call reverts with `PayerDebitTooHigh`, `ExcessContributionTooHigh` or `InsufficientShares`, and nothing changes [test].

If bob redeems immediately he receives `(907, 1,798)` [test]. He paid `(1,000, 2,000)`. The token1 shortfall is mostly the tax (200), which never reached the Pool. The token0 shortfall comes from the excess: the 100 unmatched token0 entered the reserves, and bob keeps only his share of it (`1,272/15,414 ≈ 8.3 %`); the rest benefits the other LPs. Rounding costs at most one unit per token.

### 5.3 The steps in the code

1. **Checks before any transfer** (`addLiquidity`): deadline, recipient, non-zero caps; on a non-empty pool no deficit (`ReserveDeficit`) and no zero reserve (terminal pool).
2. **Snapshots:** the Pool's balances and the payer's balances of both tokens.
3. **Step 2** (`_pullLater`): the largest pair `(T0, T1)` at the current ratio within both caps, rounded down. A zero side reverts before any transfer.
4. **Pull the first token** and measure `n_f`. **Only if** `n_f ≠ T_f`, re-plan the second: `T_s = min(cap_s, n_f·r_s/r_f)`. This keeps the deposit near the pool ratio when the first token was taxed. Then pull and measure the second token.
5. **After the last token call:** BI-2′ (`_checkInCallBalance`): for each token, the Pool's balance must have risen by at least the own measured net, so no foreign in-call removal can hide inside the measurement. Then the payer-debit bound (`_checkPayerDebit`).
6. **Shares and effects** (`_mintLater`): `σ`, `minShares`, checked `S + σ`, the excess bound, then `reserve_i += n_i` (the excess included) and mint.

### 5.4 What each protection actually promises

| Field / rule | Promise | Not promised |
|---|---|---|
| `RequestMax_i` | The Pool never asks to transfer more than this of token i. | That this amount is transferred (step 2 and the re-plan may request less), or what the payer is debited. |
| `maxDebit_i` | The payer's net balance decrease of token i over the whole call is at most this. [test] L37, I6 | Anything about what the Pool receives. With a router, it protects the router, which is the payer. |
| `maxExcess_i` | At most this much of the Pool's receipt of token i is left unmatched in the reserves. [test] L36, F1-T5, L44 | That the excess is returned (it is not; §5.7). |
| `minShares` | At least this many shares are minted. [test] L18, L46 | Any value, price or token amount. See §5.6. |
| BI-2′ | No foreign removal of Pool balance during the call goes unnoticed. [test] B09 | Protection against a token whose `balanceOf` lies. |
| `deadline` | The call fails after this timestamp. | Exact timing (producers can shift timestamps by seconds). |

For exact (Tier 0) tokens the excess is only rounding: [proof] `u_i < r_i/S + r_i/r_j` (F1-T1), so the setting `M_i = ⌊(r_i(r_j+S)−1)/(S·r_j)⌋` at the execution state never rejects an honest deposit; `maxExcess = 0` often does (L44) [test].

### 5.5 The first deposit cannot be requested as such

The Pool chooses the initial or later path from `totalSupply()` at execution; the interface cannot say "initial only". A front-runner who deposits first turns the intended initial deposit into a later one at the front-runner's ratio. Setting `minShares` to the initial-path expectation `⌊√(A·B)⌋ − 1000` rejects a clearly different ratio (1:1 and a 3·10⁻⁶ skew, [test] L45), but **not every front-run**: on the later path no lock is charged, so a shortfall of up to 1,000 shares is absorbed, and a 2.5·10⁻¹⁹ skew passes (`test_L45_slightSkewStillPassesInitialMinShares`) [test].

### 5.6 What `minShares` does and does not bound

`minShares` promises only a minimum share count. Under the narrower premise "Tier 0 tokens, and only swaps between the quote and the deposit":
- [proof] + [test] `σ'²·k_q ≤ S²·A·B`, with `k_q` the reserve product at the quote and `A, B` the caps (Z10, `test/AMMPoolSwapOnlyMintBound.t.sol`).
- [proof] A successful deposit with `σ' ≥ m` **requires** `r0' ∈ [k_q·m/(S·B), S·A/m]` at execution (a necessary condition, not a sufficient one, and not a price guarantee). [model] 59,521 sampled deposits, none outside.
- [proof] With strictly proportional caps (`A·r1 = B·r0`), `σ' ≤ σ_quote`; [model] only.

An earlier, more general claim ("after any front-running swap σ′ ≤ σ_quote", "`minShares` suffices against a sandwich") was retracted with a counterexample (REPORT_NOTES §2). Loose caps let a sandwich move the price within the band while `minShares` still passes; the binding protections are then the caps and `maxDebit`.

### 5.7 Why the excess stays in the Pool (and what it costs)

The excess is not refunded. Alternatives considered (REPORT_NOTES §1): refunds (P2: an outbound transfer inside a deposit, more failure modes and another taxed hop) and an implicit swap of the excess (P3: a second pricing path). The chosen rule adds it to the reserves (X1), so it benefits all shares pro rata, the depositor's included, and moves the price slightly. Its cost to the depositor is bounded only by `maxExcess`. For taxed tokens it is first-order in the tax and depends on the pull order: with a 5 % tax on token1 pulled second, 500 of 10,000 token0 (5 %) are left unmatched [model] (REPORT_NOTES §1.5).

---

## 6. Withdrawing liquidity

### 6.1 Redemption

`removeLiquidity(shares, min0Net, min1Net, recipient, deadline)` burns the caller's shares first, then pays `amount_i = ⌊shares·r_i/S⌋` and lowers each reserve by `amount_i`. Tests: `test_W01_proportionalRedemption`, `testFuzz_W01_redemptionMatchesFormula` (`test/AMMPoolWithdraw.t.sol`) [test]. The lock guarantees `r_i > 0` after any withdrawal [proof], [test] W06.

### 6.2 Two output rules

- **A8 (Pool side):** the Pool's balance must fall by exactly `amount_i`; otherwise `OutboundTransferMismatch`. This rejects tokens that charge the Pool extra or move the Pool's balance during the transfer [test] B06, W10.
- **MIN-NET (recipient side):** the recipient's measured increase must be at least `min_iNet`; otherwise `InsufficientNetReceived`. For a taxed token this is the amount that matters to the user [test] W04, W05.

A8 is an equality, which has a cost: a token whose transfers differ from the requested amount by rounding (share-based balances) can be deposited but not withdrawn whenever the difference occurs. A one-sided check would admit such tokens but would also let a token that delivers less than it reports leave the shortfall in the Pool as surplus. A8 was kept and the boundary disclosed (THREAT_MODEL §7.3).

### 6.3 Small positions

If `r_i/S < 1` (for example a 2-decimal token paired with an 18-decimal one), a holder of fewer than `⌈S/r_i⌉` shares receives 0 of token i, which reverts `InsufficientLiquidityBurned` (as in Uniswap V2). In `test/AMMPoolSmallPosition.t.sol` (W12) [test]: `S = 10¹²`, `r2 = 10⁴`; a remainder of 5·10⁷ shares cannot exit until it is topped up to the threshold 99,995,001.

### 6.4 Terminal pool

If `sync()` lowers a reserve to 0 while shares exist, the pool is terminal: deposits and swaps revert, and withdrawals still pay the remaining token (`test/AMMPoolTerminal.t.sol`) [test].

---

## 7. Swapping

### 7.1 Flow

`swapExactInput(tokenIn, amountIn, minNetAmountOut, recipient, deadline)`:
1. checks (deadline, recipient, valid `tokenIn`, non-zero input, non-zero reserves, no deficit);
2. pull `amountIn` and measure `a` (the Pool's actual increase);
3. `out` from §2.2 on the measured `a`; `out = 0` reverts;
4. update reserves; send `out` with A8 and MIN-NET.

Unlike Uniswap V2's optimistic `swap(amount0Out, amount1Out, to, data)`, the Pool pulls the input first and computes the output itself; there are no flash swaps. The direction is given by the `tokenIn` address, so a caller unaware of the sort order cannot reverse it.
Tests: S01–S15, Z01, Q01–Q04 (`test/AMMPoolSwap.t.sol`) [test].

### 7.2 Taxed tokens

The input is priced on what the Pool actually received, and `minNetAmountOut` is judged on what the recipient actually received [test] S05, S06, Z04 (`test/AMMPoolTaxedSwapRemove.t.sol`).

### 7.3 MEV

There is no MEV protection beyond the user's `minNetAmountOut` and `deadline`. A sandwich can take up to the slippage the user allows, as in any constant-product AMM. The spot price can be moved within a transaction; no view of the Pool may be used as a price oracle (THREAT_MODEL T26).

---

## 8. Reserves, `sync()` and `skim()`

### 8.1 Surplus

Tokens sent directly to the Pool become surplus. `skim()` sends each token's surplus to the immutable `surplusRecipient`; anyone may call it and nobody can choose the recipient. Surplus never enters the reserves, so it cannot be used to move the price or inflate shares [test] R01, R03, R05, I9. Refunds of mistaken transfers depend on whoever controls `surplusRecipient` (off-chain trust). For an unsupported positive-rebase or yield token the growth becomes surplus and goes to `surplusRecipient`, not to LPs.

### 8.2 Deficit

A balance below the reserve (an unsupported token took tokens away) blocks add, remove and swap (`ReserveDeficit`) [test] R08. `sync()` lowers the affected reserve to the balance. The LPs bear the booked loss pro rata, and the price jump that follows exposes them to arbitrage: [proof] with fees ignored and the pool at the external price before the loss `d`, the extra loss is `P·(2x − d − 2√(x(x − d))) ≈ P·d²/(4x)`; not tested. A deficit of any size blocks the pool until someone calls `sync()`; a small deficit gives nobody an incentive to pay for that call, so an integrator should do it.

### 8.3 Three different ways tokens reach the reserves' backing

| Case | Effect | Evidence |
|---|---|---|
| Direct transfer while `balance > reserve` | surplus; only `skim()` removes it; LPs do not benefit | [test] R01, I9 |
| Direct transfer while in deficit | first refills the backing up to the reserve (no surplus); the block lifts once no token is in deficit | [source] |
| Excess inside `addLiquidity` | enters the reserves, benefits all shares, moves the price slightly | [test] L46, F1-T5 |

### 8.4 Why not Uniswap V2's `sync`

Uniswap V2's `sync()` sets reserves to the balances in both directions, so a direct transfer plus `sync()` adds value to the reserves (and moves the price) [source, V2]. Here `sync()` only lowers, and surplus has exactly one destination. This removes the race between `sync()` and `skim()` for donated tokens and the "transfer then sync" price route, at the cost of a fixed `surplusRecipient` (DECISIONS §3, Gate R).

---

## 9. Security analysis

### 9.1 Reentrancy

`addLiquidity`, `removeLiquidity`, `swapExactInput`, `sync` and `skim` are `nonReentrant` (the LP ERC-20 functions make no external calls); reserves are written after the measured transfers but the lock prevents interleaving. Malicious token callbacks are tested for add, remove and swap, both when the reentrant call bubbles up and when the token swallows it (`test/AMMPoolReentrancy.t.sol`, `test/AMMPoolSyncSkimReentrancy.t.sol`) [test]. View functions are not guarded: integrators must not read `getReserves` mid-transaction as a price (read-only reentrancy, THREAT_MODEL T13).

### 9.2 Inflation and donation attacks

The classic attack (tiny first deposit, then a large donation to make later deposits round to zero shares) is blocked in two ways: direct transfers never enter the reserves (§8.1), and the 1,000-share lock makes raising one share's value by `Δ` cost about `1000·Δ` [proof, approximate].

The measured-deposit design reopened a bounded donation channel: the excess (§5.7). The analysis (THREAT_MODEL T4, the "F1" finding) is:
- [test] With a token that mints a bonus to the Pool on transfer (unsupported behaviour), 5,000 later deposits from one address with unbounded `maxExcess` made the attacker profitable (`test_L13b_5000Victims_unboundedExcess_profitable`); a 10 bps `maxExcess` made it unprofitable; an honest LP of about 1 % present before the donation turned the attacker's P&L negative (F1-T9).
- [model] The full path with supported tokens (P5: raising the share value through swap fees instead of a bonus) needs an estimated 32,000–58,000 round-trip swaps; capital need, execution and net profitability are **not verified** (F1-T4 deferred). Only a reduced-scale swap-fee channel was executed (F1-T3).
- Status: a known economic limitation of the Uniswap-V2 class of pools, bounded by the user's own `maxExcess`; not a demonstrated exploit with supported tokens.

### 9.3 Token behaviour and exit safety

Deposits accept more token behaviours than withdrawals. A token that later charges the Pool on outbound transfers, blacklists it or reverts `balanceOf` can trap both tokens of the pool, because a withdrawal transfers both atomically. There is no recovery path in an ownerless design (THREAT_MODEL §7.4–§7.6; `test/AMMPoolM8Limitations.t.sol`) [test].

### 9.4 Access control

Nothing is privileged. `surplusRecipient` is an economic beneficiary without functions. The Pool's LP token cannot be sent to the Pool (`LPTransferToPool`), the lock cannot move, and minting or burning outside a guarded entry point reverts (`AMMPool._update`) [test] P04–P08.

### 9.5 Arithmetic ranges

Solidity 0.8 checked arithmetic turns overflow into a revert, never a wrong value. Hand-derived sufficient conditions for each formula are in ARCHITECTURE §6.6; for example the initial deposit needs `n0·n1 < 2²⁵⁶`. Later-deposit share computation saturates instead of reverting, and an oversized result is rejected by the checked `S + σ`. Boundary tests: Z06, Z08; mixed 6/18-decimal values near `2¹¹²`: Z03 [test].

---

## 10. Verification

### 10.1 Strategy

Unit tests per rule with exact expected values from independent models; fuzz tests over the documented ranges; stateful invariant campaigns; differential tests against reference implementations; mutation checks (deliberate bugs in `src/` that a test must catch); and manual review with `forge lint`. Final result: see §10.6.

### 10.2 Stateful invariants

`test/AMMPoolInvariant.t.sol` with `test/invariant/AMMPoolHandler.sol`: two suites (exact tokens; 1 % / 3 % taxed tokens), 256 runs × 500 random calls (deposit, withdraw, swap, sync, skim, donation, LP transfers). Checked after every call:

| ID | Property |
|---|---|
| I1 | LP supply = minted − burned; the Pool holds exactly the 1,000 lock |
| I2 | balance ≥ reserve for each token |
| I3 | each swap keeps `k` non-decreasing and matches §2.2 |
| I6 | payer debit ≤ `RequestMax` and ≤ `maxDebit` |
| I7 | every outbound transfer lowers the Pool's balance by exactly the amount (A8) |
| I8 | `skim` pays only the surplus, only to `surplusRecipient` |
| I9 | surplus changes only by donations and `skim` |
| I10 | per-share reserves never decrease (§3.3) |

`test/AMMFactoryInvariant.t.sol` (I5): no duplicate or unregistered pair. Accepted reverts are classified by error and followed by an unchanged-state check (I4).

### 10.3 Mutation checks

For each feature, deliberate bugs were inserted into a single source file, the suite was run and the file was restored and verified by hash. Every reported mutant was killed, or the survivor was analysed as an equivalent mutant or a test gap and the gap closed (for example W12's token-order gap). Details per test: TEST_MATRIX.

### 10.4 Static analysis

`forge lint` on `src/`: one medium finding (a false positive on a short-circuited read), three `block-timestamp` and four `reentrancy-events` (accepted, explained in §9.1 and §12), and informational naming notes (TEST_MATRIX §16).

### 10.5 Not done

No formal verification, no symbolic execution (halmos, mythril), no slither / aderyn, no Echidna / Medusa, no mainnet-fork tests, no external audit.

### 10.6 Final regression

To be filled at the end of M11 with the commit, configuration and test count.

---

## 11. Gas and optimisation

### 11.1 Baseline

[gas] Harness `test/gas/GasG02.t.sol`: one call per test, `gasleft()` before and after, arguments prepared outside the measured interval, cold state (`isolate = true`). Single scenarios; values are for comparisons inside this project only.

| Call | Gas |
|---|---:|
| `addLiquidity` initial | 232,004 |
| `addLiquidity` later | 108,814 |
| `removeLiquidity` | 94,105 |
| `swapExactInput` | 82,539 |
| `sync` / `skim` (no-op) | 40,067 / 39,905 |
| `skim` (both tokens) | 101,777 |
| `createPair` | 2,316,864 |

The measured-deposit design costs gas: in the earlier G05 comparison the later deposit cost +10,264 gas (+10.4 %) more than the pre-M8 deposit on the same path, under one harness [gas].

### 11.2 Evaluated and not adopted

| Variant | Saving [gas] | Why not adopted |
|---|---|---|
| VP: `uint112` reserves in one slot | ≈ 4,300 per add / remove / swap; 21,567 on the initial deposit | +159,273 per deployment; narrows reserves to `2¹¹²`, which breaks 13 range tests and needs a new approved range and error case |
| VU: `unchecked` on proven-safe arithmetic (14 blocks) | 263–534 per state-changing call; 29,565 per deployment | Small saving; the overflow proofs would become load-bearing (a mistake would wrap silently instead of reverting) |
| VA / VB / VC: reuse of balance readings (G05) | 684–1,924 per deposit | Changes the fresh-snapshot rule; VC changes an error order for unsupported tokens |
| On-chain §2.3 assertion after each swap (G01) | (costs +836) | Mathematically redundant; enforced by tests instead |

### 11.3 Comparison with Uniswap V2 (qualitative)

No gas comparison with Uniswap V2 was made under the same harness; V2 is compiled with Solidity 0.5.16 and was not imported. The following architectural differences are taken from the V2 source code (References):

| Aspect | Uniswap V2 Pair (+ Router02) | This project |
|---|---|---|
| Reserve storage | `uint112` ×2 + `uint32` timestamp in one slot | `uint256` ×2 (VP measured, not adopted) |
| Deposit amounts | `balance − reserve` after the router transferred tokens in | measured around the Pool's own `transferFrom` |
| User protection | in the Router (`amountAMin`, `amountBMin`, deadline) | in the Pool (caps, `maxDebit`, `maxExcess`, `minShares`, MIN-NET) |
| Swap | optimistic transfer out, then `K` check; flash swaps | input pulled first; no flash swaps |
| `sync` | sets reserves to balances, both directions | lowers only |
| Lock | 1,000 to `address(0)` | 1,000 held by the Pool, immovable |
| Protocol fee / oracle | `feeTo` (1/6 of fee growth); cumulative prices | none |
| Fee-on-transfer | separate Router functions using balance differences | measured in every Pool function |

The V2 split keeps the core minimal and cheap and leaves user protection to a periphery contract; this project puts the protections in the Pool, which costs gas (§11.1) but makes them hold for every caller.

---

## 12. Limitations

### 12.1 The limitations that matter most

1. **Exit is not guaranteed for every token.** Deposits accept tokens whose outbound behaviour may make withdrawals revert (A8), and one failing token traps the other. There is no recovery path (§6.2, §9.3).
2. **The excess is not refunded.** With taxed tokens it is of the order of the tax and depends on the pull order; only `maxExcess` bounds it (§5.7).
3. **`minShares` bounds a share count, not value.** Deposits have no per-token minimum, and the intended first deposit cannot be protected completely against front-running (§5.5, §5.6).
4. **Deficits freeze the pool** until someone calls `sync()`, and the LPs then bear the loss plus an arbitrage cost (§8.2).
5. **Inflation through the excess channel** is a bounded, known limitation; the full supported-token path is model-only (§9.2).

### 12.2 Other disclosed limitations

| Limitation | Section / source |
|---|---|
| Tests are evidence over sampled states, not proofs | §10 |
| Refunds of mistaken transfers depend on `surplusRecipient` | §8.1 |
| Immutable parameters; one shared `surplusRecipient` per Factory | §4.1 |
| No MEV protection, no oracle, no pause; deadlines use `block.timestamp` | §7.3 |
| Arithmetic ranges are sufficient conditions; extreme inputs may revert | §9.5 |
| One failing token blocks `skim()` for both | THREAT_MODEL §6 (8) |
| Events emitted after token calls (measurement first); guarded by `nonReentrant` | §9.1 |
| Views can be read mid-transaction (read-only reentrancy) | §9.1 |
| Terminal pool: cannot trade again; the lock's backing is unredeemable; pair cannot be re-created | §6.4 |
| Factory code check is not an ERC-20 check; no pre-created pairs for undeployed tokens | §4.1 |
| Small positions may be unredeemable | §6.3 |
| Positive rebases / yield go to `surplusRecipient` | §8.1 |
| Add / remove fields are positional (token0 / token1); swap uses an address | §5.1 |
| The lock takes its pro-rata part of fees and excess | §3.2 |
| Quotes are not tax- or deficit-aware | §2.4 |

---

## 13. Traceability

### 13.1 Milestones

| Milestone | Content | Report |
|---|---|---|
| M1 | Toolchain, mocks | §10 |
| M2 | Pool skeleton, maths library, constructor checks | §2, §4 |
| M3 | Initial deposit, lock, LP token rules | §3.2, §9.4 |
| M4 | Later deposit, withdrawal | §5, §6 |
| M5 | Swap, quote, reentrancy tests | §2, §7, §9.1 |
| M6 | `sync`, `skim`, deficit rules, terminal pool | §6.4, §8 |
| M7 | Factory | §4.1 |
| M8 | Measured-net deposit (`maxDebit`, `maxExcess`, BI-2′); F1 analysis | §5, §9.2 |
| M10 | Review, invariants, fuzz near the range limits, G02 gas, lint | §5.6, §10, §11 |
| M11 | This report, worked example (L46), source cross-references | all |

(M9, a protocol fee, is out of scope and was not implemented; DECISIONS `FUTURE-ONLY`.)

### 13.2 Code → report index

| Code | Report |
|---|---|
| `AMMMath.getAmountOut`, `AMMPool.getAmountOut` | §2.2, §2.4 |
| `AMMMath.initialShares`, `AMMPool._update` | §3.2, §9.4 |
| `AMMFactory.createPair` | §4.1 |
| `AMMPool.addLiquidity`, `_pullLater`, `_mintLater`, `_checkInCallBalance`, `_checkPayerDebit` | §5 |
| `AMMPool.removeLiquidity`, `_pushMeasured` | §6 |
| `AMMPool.swapExactInput` | §7 |
| `AMMPool.sync`, `skim`, `_checkNoDeficit` | §8 |

### 13.3 Supporting documents

`docs/ARCHITECTURE.md` (specification), `docs/DECISIONS.md` (every decision with its status), `docs/THREAT_MODEL.md` (threats T1–T29 and disclosed limitations), `docs/TEST_MATRIX.md` (every test ID with its result and mutation check), `docs/REPORT_NOTES.md` (alternatives and retracted claims).

### 13.4 References

- Uniswap, `v2-core/contracts/UniswapV2Pair.sol`. https://github.com/Uniswap/v2-core/blob/master/contracts/UniswapV2Pair.sol
- Uniswap, `v2-periphery/contracts/UniswapV2Router02.sol`. https://github.com/Uniswap/v2-periphery/blob/master/contracts/UniswapV2Router02.sol
- OpenZeppelin Contracts v5.7.0 (`ERC20`, `SafeERC20`, `ReentrancyGuardTransient`, `Math`).
