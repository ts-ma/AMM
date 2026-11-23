# A Constant-Product AMM with Measured Token Accounting

Solidity 0.8.38 · Foundry (forge 1.9.0) · OpenZeppelin Contracts v5.7.0 · optimizer 200 runs, `evm_version = osaka`, `via_ir = false`. Source comments point here with `@custom:report docs/REPORT.md §n`; section numbers are stable. Decision and test IDs (D…, M8-n, L46, …) refer to `docs/DECISIONS.md` and `docs/TEST_MATRIX.md`.

## 1. Overview

### 1.1 Components

| Contract | File | Role |
|---|---|---|
| `AMMFactory` | `src/AMMFactory.sol` | Deploys one Pool per unordered token pair; registry. No owner, no funds. |
| `AMMPool` | `src/AMMPool.sol` | Holds two tokens, records reserves, prices swaps, and **is** the LP token (OpenZeppelin `ERC20`). No owner, immutable. |
| `AMMMath` | `src/libraries/AMMMath.sol` | Pure maths: swap quote with fee, initial-share square root. |
| `IAMMPool` | `src/interfaces/IAMMPool.sol` | Deposit parameter struct `AddLiquidityParams`. |

Beyond a basic AMM, the design (i) measures what every transfer actually delivers, so the accounting stays correct for tokens with transfer taxes, (ii) gives each user protection a precise, tested meaning, and (iii) separates recorded reserves from balances so that tokens sent to the Pool cannot be used to manipulate it.

### 1.2 Evidence labels

**[proof]** written mathematical argument · **[source]** inference from reading the code · **[model]** sampled integer Python model of the formulas, not the contract · **[test]** executed against the real contracts in Foundry's local EVM (evidence over sampled states, not a proof) · **[gas]** measured gas, harness and configuration stated.

Notation: `r0, r1` recorded reserves; `S` LP supply; `n_i` amount the Pool actually received; `σ` shares minted; `u_i` unmatched "excess". Amounts are in smallest units.

## 2. How a trade is priced

### 2.1 Constant product

Without fees a trade keeps `k = r0·r1` constant: `(r0 + a)·(r1 − out) = r0·r1`. The marginal price of token0 is `r1/r0`; larger trades get a worse average price.

### 2.2 Fee and exact formula

`AMMMath.getAmountOut`, with a 30 bps fee kept in the reserves (no protocol fee):

```
aFee = a · 9970;   out = ⌊ aFee · rOut / (rIn · 10000 + aFee) ⌋
```

This equals Uniswap V2's 997/1000 rule [source]. `swapExactInput` applies it to the **measured** input (§7).

### 2.3 What the fee guarantees

[proof] From the formula, `(rIn·10000 + aFee)·(rOut − out) ≥ rIn·10000·rOut`. Since `rIn·10000 + aFee ≤ (rIn + a)·10000`, it follows that `(rIn + a)·(rOut − out) ≥ rIn·rOut`: **the product `k` never decreases in a swap**, and the fee makes it grow. This does **not** mean that every per-share claim grows: per share, the input-token reserve rises and the output-token reserve falls. What grows is the constant-product measure `√k/S` (§3.3). [test] Checked in 512-bit arithmetic after every successful swap (`testFuzz_Z01_S11_S15_swapMatchesFormula`; invariant I3).

### 2.4 Quotes

`AMMPool.getAmountOut` returns the formula at the recorded reserves. It is not tax-aware (a taxed input delivers less; a taxed output pays the recipient less) and not deficit-aware. Quote = swap for exact tokens [test] `test_Q01_quoteEqualsSwapBothDirections`.

## 3. What an LP share represents

### 3.1 A pro-rata claim on recorded reserves

`h` of `S` shares redeem `⌊h·r_i/S⌋` of each token (§6.1). Tokens sent directly to the Pool are not reserves and back no shares (§8).

### 3.2 First deposit and the permanent lock

The first depositor sets the price and receives `⌊√(n0·n1)⌋ − 1000` shares (`AMMMath.initialShares`); 1,000 shares are minted to the Pool itself and can never move or be burned (`AMMPool._update`). The lock makes the classic first-depositor inflation attack expensive (§9.2). Through add, remove and swap it keeps both reserves positive [proof] (W06 [test]); only `sync()` after a deficit, which needs an unsupported token, can lower a reserve to 0 (terminal pool, §6.4). The lock also keeps its pro-rata part of all fees and excess: negligible in a large pool, half of them if the initial `⌊√(n0·n1)⌋` is 2,000 [source].

### 3.3 A pool-level measure that never decreases

[proof] Add and remove round against the actor, so per token `r_i'·S ≥ r_i·S'`; a swap keeps `S` and does not decrease `k` (§2.3). Therefore `k/S²` (equivalently `√(r0·r1)/S`, the geometric-mean reserve per share) never decreases through add, remove or swap [test: invariant I10, 2 suites × 256 runs × 500 random calls]. Exceptions: the initial deposit (`S` starts at 0) and `sync()` after a deficit, which lowers `k` (§8.2).

This measure is **not** the market value of a share. A swap lowers the per-share claim on the output token, and when the external price moves an LP can be worth less than simply holding the two tokens (impermanent loss). The measure only says that no add, remove or swap moves value away from existing shares under the pool's own pricing rule.

## 4. Contracts and data structures

### 4.1 `AMMFactory`

State: `surplusRecipient` (immutable, shared by all its Pools), `getPair[tokenA][tokenB]` (both orderings), `allPairs[]`. `createPair(tokenA, tokenB)` rejects zero addresses, identical tokens and addresses without code, sorts, rejects duplicates, deploys `new AMMPool(token0, token1, surplusRecipient)` and registers it. [test] F01–F05; registry invariant I5 (`test/AMMFactoryInvariant.t.sol`).

### 4.2 `AMMPool`

| State | Type | Meaning |
|---|---|---|
| `token0`, `token1` | `address immutable` | sorted pair (`token0 < token1`, checked in the constructor) |
| `surplusRecipient` | `address immutable` | only destination of surplus (§8.1) |
| `reserve0`, `reserve1` | `uint256 private` | recorded reserves (§4.4) |
| ERC-20 balances / supply | inherited | LP shares; `_update` enforces the lock rules |
| reentrancy lock | transient storage | `ReentrancyGuardTransient` |

`addLiquidity`, `removeLiquidity`, `swapExactInput`, `sync` and `skim` are `nonReentrant` and follow checks → measured interactions → accounting checks → effects. Two helpers carry the token accounting:
- `_pullMeasured(token, amount)`: Pool balance before → `transferFrom(msg.sender, Pool, amount)` → after; the difference is the Pool's receipt.
- `_pushMeasured(token, to, amount, minNet)`: the Pool's balance must fall by exactly `amount` (**A8**) and the recipient's measured increase must be at least `minNet` (**MIN-NET**).

### 4.3 `AMMMath`

Internal pure functions compiled into the Pool; tested on their own (`test/AMMMath.t.sol`) and through the Pool.

### 4.4 Recorded reserves versus balances

The Pool never prices from `balanceOf`. `balance − reserve` is **surplus** if positive (unsolicited transfers) and **deficit** if negative (a token removed Pool balance). Reserves are written only by the initial deposit, later deposit, `removeLiquidity`, `swapExactInput` and `sync` (downward only) [source]. A direct transfer therefore cannot change reserves: the "donate then `sync`" price route and the classic donation-inflation attack are closed. Value can still enter reserves through the paths that are meant to add it: swap fees and the excess of a deposit (§5.7, §9.2).

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

An immediate full redemption returns `(907, 1,798)` [test] against a payment of `(1,000, 2,000)`. The token1 gap is mostly the tax (200), which never reached the Pool. The token0 gap is the excess: the 100 unmatched token0 joined the reserves, and bob owns only `1,272/15,414 ≈ 8.3 %` of them. Finally, each token's redemption is rounded down: the exact claims are 907.75 and 1,798.99, so in that last step bob loses less than one smallest unit **per token**.

### 5.3 Steps in the code

1. **Checks** (`addLiquidity`): deadline, recipient, non-zero caps; for a non-empty pool, no deficit and no zero reserve.
2. **Snapshots** of the Pool's and the payer's balances of both tokens.
3. **Step 2** (`_pullLater`): the largest pair at the pool ratio within both caps, rounded down. The exact 512-bit product is formed once, so huge caps never overflow.
4. **Pull and measure** the first token; only if it delivered a different amount than planned, re-plan the second token from what arrived; then pull and measure the second token.
5. **After the last transfer**: BI-2′ (`_checkInCallBalance`): each Pool balance rose by at least the own measured receipt, so no foreign removal hides inside the call; then the payer-debit bound (`_checkPayerDebit`).
6. **Shares and effects** (`_mintLater`): `σ`, `minShares`, checked `S + σ`, the excess bound, then `reserve_i += n_i` (excess included) and mint.

### 5.4 What each protection promises

| Field / rule | Promise | Not promised |
|---|---|---|
| `RequestMax_i` | The Pool never requests more of token i. | That this amount is transferred, or what is debited. |
| `maxDebit_i` | Bounds the payer's net decrease of token i over the call. [test] L37, I6 | What the Pool receives. With a router, it protects the router. |
| `maxExcess_i` | Bounds the unmatched amount of token i left in reserves. [test] L36, L44, L46 | A refund. |
| `minShares` | A minimum number of shares. [test] L18, L46 | Any value, price or token amount (§5.6). |
| BI-2′ | No foreign in-call loss of Pool balance goes unnoticed. [test] B09 | Protection against a lying `balanceOf`. |

For exact tokens the excess is pure rounding: [proof] `u_i < r_i/S + r_i/r_j` (F1-T1).

### 5.5 The first deposit cannot be requested as such

The path (initial or later) is chosen from `totalSupply()` at execution; the interface has no "initial only" option. A front-runner who deposits first turns the intended first deposit into a later one at the front-runner's ratio. Setting `minShares` to the initial expectation `⌊√(A·B)⌋ − 1000` rejects a clearly different ratio, but on the later path no lock is charged, so a skew of 2.5·10⁻¹⁹ still passes (`test_L45_slightSkewStillPassesInitialMinShares`) [test].

### 5.6 The scope of `minShares`

It bounds a share count only. With Tier 0 tokens and only swaps between quote and deposit: [proof]+[test] `σ'²·k_q ≤ S²·A·B` (Z10); [proof] success with `σ' ≥ m` **requires** `r0' ∈ [k_q·m/(S·B), S·A/m]`, a necessary condition and not a price guarantee ([model] 59,521 samples, none outside). A general claim that `minShares` stops sandwiches was retracted with a counterexample (REPORT_NOTES §2).

### 5.7 Why the excess stays in the Pool

Refunding it (an outbound transfer inside a deposit: more failure modes, another taxed hop) and swapping it implicitly (a second pricing path) were rejected. The chosen rule adds it to the reserves, where it benefits all shares, including the depositor's. Its cost to the depositor is bounded only by `maxExcess`. With taxed tokens it is of the order of the tax and depends on the pull order (5 % tax on the second token: 5 % of the first token unmatched [model]).

## 6. Withdrawing liquidity

### 6.1 Redemption

`removeLiquidity(shares, min0Net, min1Net, recipient, deadline)` burns the caller's shares, pays `⌊shares·r_i/S⌋` of each token and lowers each reserve by that amount [test] W01.

### 6.2 Output rules A8 and MIN-NET

A8: the Pool's balance must fall by exactly the amount sent (`OutboundTransferMismatch`), which rejects tokens that charge the Pool extra or move its balance mid-transfer [test] B06, W10. MIN-NET: the recipient's measured increase must be at least `min_iNet` (`InsufficientNetReceived`), the amount that matters for a taxed token [test] W04, W05. A8 is an equality, so a token whose transfers differ by rounding (share-based balances) can be deposited but not reliably withdrawn. A one-sided check would admit it but would also let an under-delivering token leave the shortfall in the Pool as surplus; A8 was kept.

### 6.3 Small positions

If `r_i/S < 1` (e.g. a 2-decimal token against an 18-decimal one), fewer than `⌈S/r_i⌉` shares pay 0 of token i and revert `InsufficientLiquidityBurned`, as in Uniswap V2. [test] W12: `S = 10¹²`, `r = 10⁴`; a remainder of 5·10⁷ shares cannot exit until it reaches 99,995,001.

### 6.4 Terminal pool

If `sync()` lowers a reserve to 0 while shares exist, deposits and swaps revert and withdrawals still pay the other token [test] R15–R22.

## 7. Swapping

`swapExactInput(tokenIn, amountIn, minNetAmountOut, recipient, deadline)`: checks (deadline, recipient, valid `tokenIn`, non-zero input and reserves, no deficit) → pull and measure the input `a` → `out` from §2.2 on `a` (0 reverts) → update reserves → send with A8 and MIN-NET. Unlike Uniswap V2's optimistic `swap`, the Pool pulls the input first and computes the output itself; there are no flash swaps. The direction is an address, so callers cannot invert it by misordering tokens. Taxed tokens: the input is priced on what arrived and `minNetAmountOut` is judged on what the recipient received [test] S05, S06, Z04. There is no MEV protection beyond `minNetAmountOut` and `deadline`, and no view may serve as a price oracle (one transaction can move the spot price). [test] S01–S15, Z01, Q01–Q04.

## 8. Reserves, `sync()` and `skim()`

### 8.1 Surplus and `skim()`

`skim()` sends each token's surplus to the immutable `surplusRecipient`; anyone may call it, nobody chooses the recipient. Surplus never enters reserves [test] R01, R05, I8, I9. Refunds of mistaken transfers rely on whoever controls `surplusRecipient`; the growth of an unsupported rebasing or yield token also goes there, not to LPs.

### 8.2 Deficit and `sync()`

A deficit in either token blocks add, remove and swap (`ReserveDeficit`, `_checkNoDeficit`) [test] R08. `sync()` only lowers a reserve to the balance; LPs bear the booked loss pro rata and, as the price jumps, an extra arbitrage loss of about `P·d²/(4x)` (fees ignored) [proof, not tested]. A tiny deficit gives nobody a reason to pay for `sync()`, so integrators should call it.

### 8.3 How tokens reach the reserves' backing

| Case | Effect | Evidence |
|---|---|---|
| Direct transfer, no deficit | surplus; only `skim()` removes it; LPs do not benefit | [test] R01, I9 |
| Direct transfer during a deficit | refills the backing up to the reserve; a partial top-up keeps the block, an exact one lifts it; reserves unchanged | [test] R24, R08 |
| Excess inside `addLiquidity` | joins the reserves, benefits all shares, moves the price slightly | [test] L46, F1-T5 |

Uniswap V2's `sync()` sets reserves to balances in both directions, so a transfer plus `sync()` adds to reserves [source, V2]. Here `sync()` only lowers, which removes the `sync`/`skim` race and that price route, at the cost of a fixed `surplusRecipient`.

## 9. Security

### 9.1 Reentrancy

The five state-changing Pool functions are `nonReentrant` (the LP functions make no external calls). Malicious token callbacks are tested for add, remove, swap, `sync` and `skim`, both bubbling and swallowed [test] `AMMPoolReentrancy`, `AMMPoolSyncSkimReentrancy`. Views are unguarded, so mid-transaction reads are not a safe price (read-only reentrancy).

### 9.2 Inflation and donation

Direct donations never enter reserves (§4.4), and the lock makes raising one share's value by `Δ` cost about `1000·Δ` [proof, approximate]. The deposit excess is a bounded donation channel; the evidence has four separate parts:

- **Bonus-token experiment, local EVM** [test] (`test/AMMPoolInflation.t.sol`, L13b). An unsupported token mints a bonus to the Pool during the attacker's own deposit (`D = 10²⁵` per token, a free donation counted as paid). bob then makes 5,000 deposits with token0 request `w` from a fixed generator in `[10²¹, 10²¹ + 2⁶⁴ − 1]` and an unlimited token1 request. Both absolute `maxExcess` fields are derived from token0's `w`: unbounded (`type(uint256).max`), or `maxExcess0 = maxExcess1 = ⌊w·10/10,000⌋` ("10 bps"); for token1 this is an absolute amount, not 10 bps of token1. Result: unbounded → attacker profit ≈ 1.8·10²² wei (both tokens valued 1:1, gas excluded); 10 bps → 4,442 of 5,000 deposits revert and the attacker loses.
- **Honest-LP experiment, local EVM** [test] (F1-T9, `test/AMMPoolF1HonestLP.t.sol`): the same 5,000-deposit sequence, run again with one honest LP holding 0.99999901 % of the supply before the donation; the attacker's per-token result turns negative.
- **Reduced-scale fee channel, local EVM** [test] (F1-T3): with supported tokens, the legitimate way to raise per-share value is trading fees; up to 2,000 round trips were executed, and the attacker as the only LP loses exactly what stays in the Pool.
- **Full fee path P5** [model only]: an estimated 32,000–58,000 round-trip swaps would be needed to reach the bonus scale; capital, execution and net profitability are **not verified**.

Status: a known limitation of the Uniswap-V2 class of pools, bounded by each depositor's own `maxExcess`; not a demonstrated exploit with supported tokens. Full figures: THREAT_MODEL T4, TEST_MATRIX §3.4.

### 9.3 Exit safety

Deposits accept more token behaviours than withdrawals. A token that later charges the Pool on outbound transfers, blacklists it or reverts `balanceOf` traps both tokens, because a withdrawal transfers both atomically; there is no recovery path in an ownerless design [test] `AMMPoolM8Limitations`.

### 9.4 Access control and LP rules

No owner, admin function, pause, upgrade, fallback or `receive`; [test] X03 compares the compiled ABI with the approved list. `_update` makes the lock immovable, rejects LP sent to the Pool and rejects minting or burning outside a guarded entry point [test] P04–P08.

### 9.5 Arithmetic

Checked arithmetic turns overflow into a revert, never a wrong value; the hand-derived ranges are in ARCHITECTURE §6.6 (e.g. initial deposit `n0·n1 < 2²⁵⁶`). Later-deposit share maths saturates and is caught by the checked `S + σ`. [test] Boundary tests Z06, Z08; 6/18-decimal values near `2¹¹²`, Z03.

## 10. Verification

Unit tests use exact values from independent models; fuzz tests cover the documented ranges; two stateful invariant suites (exact and 1 %/3 % taxed tokens, 256 runs × 500 random calls) check after every call: LP supply and lock (I1), balance ≥ reserve (I2), the swap formula and `k` (I3), debit ≤ cap and ≤ `maxDebit` (I6), exact outbound amounts (I7), `skim` only to `surplusRecipient` (I8), surplus changes only by donation and `skim` (I9), and §3.3 (I10). Every feature had a mutation check (deliberate bugs in one source file that a test had to catch); survivors were analysed and test gaps closed. `forge lint` findings were triaged (one false positive; accepted timestamp and event-order warnings). **Not done:** formal verification, symbolic execution, slither, Echidna/Medusa, fork tests, an external audit.

### 10.6 Final regression

Commit `b80c5a8` (`src/` logic identical to the M8 acceptance `550bc80`: bytecode built without CBOR metadata is unchanged). Commands: `forge build`; `forge test`; `FOUNDRY_FUZZ_RUNS=10000 forge test`. Result: **491 tests in 55 suites passed, 0 failed**, in both runs (invariant suites use their inline 256 × 500 setting). Configuration from `forge config`: solc 0.8.38, optimizer 200 runs, `osaka`, `via_ir = false`, `isolate = true`; forge 1.9.0.

## 11. Gas

### 11.1 Measured baseline

[gas] `test/gas/GasG02.t.sol`: one call per test, arguments prepared outside the measured interval, cold state (`isolate = true`); single scenarios, for comparisons inside this project only.

| Call | Gas | Call | Gas |
|---|---:|---|---:|
| `addLiquidity` initial | 232,004 | `swapExactInput` | 82,539 |
| `addLiquidity` later | 108,814 | `skim` (both tokens) | 101,777 |
| `removeLiquidity` | 94,105 | `sync` / `skim` no-op | 40,067 / 39,905 |
| deploy `AMMPool` | 2,422,397 | `createPair` | 2,316,864 |

Protection has a price: the measured deposit costs +10,264 gas (+10.4 %) more than the pre-M8 deposit on the same path, same harness [gas].

### 11.2 Optimisations adopted and rejected

In the code: custom errors, immutable addresses, a transient-storage reentrancy lock, reserves cached in memory within each function, and a single 512-bit product in step 2 (chosen by measurement). Measured and **not adopted** [gas]:

| Variant | Saving | Reason not adopted |
|---|---|---|
| VP: `uint112` reserves in one slot | ≈ 4,300 per add/remove/swap; 21,567 on the first deposit | +159,273 per deployment; caps reserves at `2¹¹²` (13 range tests fail; new error case and range rules needed) |
| VU: `unchecked` on 14 proven-safe operations | 263–534 per call; 29,565 per deployment | small; the overflow proofs would become load-bearing, so a mistake would wrap silently |
| Reuse of balance readings (VA/VB/VC) | 684–1,924 per deposit | weakens the fresh-snapshot rule; changes an error order for unsupported tokens |
| On-chain swap assertion | (cost +836) | redundant with §2.3; enforced by tests |

### 11.3 Uniswap V2, qualitative

No same-harness gas comparison with Uniswap V2 was made (V2 needs Solidity 0.5.16 and was not imported). From the V2 source (§13.3): V2 packs `uint112` reserves with a timestamp in one slot; computes deposits as `balance − reserve` after the router transferred tokens; keeps user minima in Router02; swaps optimistically with flash swaps; lets `sync` move reserves both ways; locks 1,000 LP at `address(0)`; and has a protocol fee and price accumulators. V2 keeps the core minimal and cheap and leaves protection to the periphery; this design puts the protections in the Pool, which costs gas but holds for every caller.

## 12. Limitations

Most important for users and LPs:
1. **Exit is not guaranteed for every token** accepted on deposit (§6.2, §9.3); no recovery path.
2. **Excess is not refunded**; with taxed tokens it is first-order in the tax, bounded only by `maxExcess` (§5.7).
3. **`minShares` bounds a share count, not value**; no per-token deposit minimum; the first deposit cannot be fully protected from front-running (§5.5, §5.6).
4. **A deficit of any size freezes the pool** until someone calls `sync()` or tops it up; LPs then bear the loss plus arbitrage (§8.2).
5. **The excess inflation channel** is bounded but open; the supported-token path is model-only (§9.2).

| Other disclosed limitations | § |
|---|---|
| Tests sample states; no formal proof | 10 |
| One immutable `surplusRecipient` per Factory; refunds need trust | 4.1, 8.1 |
| No MEV protection, oracle or pause; deadlines use `block.timestamp` | 7 |
| Small positions may be unredeemable; terminal pools cannot trade again | 6.3, 6.4 |
| Quotes ignore taxes and deficits; views unsafe mid-transaction | 2.4, 9.1 |
| Deposit/withdraw fields are positional (token0/token1); swaps use an address | 5.1 |

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
