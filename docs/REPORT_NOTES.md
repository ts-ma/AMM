# REPORT NOTES — Draft Material for the Coursework Report

**Last updated:** 2026-11-23

**Status:** Draft material collected per milestone (MILESTONES §3: "write the matching report section during each milestone"). Not authoritative: decisions and their status are recorded only in [DECISIONS.md](DECISIONS.md); where this file disagrees, DECISIONS.md wins. Claims are labelled **[proven]** (mathematical argument given), **[assumption]** (about token behaviour) or **[needs tests]** (not yet shown by executed tests). No gas figure in this file has been measured unless it cites TEST_MATRIX §14.

---

## 1. M8 — Depositing liquidity with transfer-taxed tokens: alternatives considered

### 1.1 Why the original adaptive algorithm (L-α) was retired

L-α (ADR-015) asked the caller for each token's tax rate `t` (a "tax hint"). It computed on-chain the gross amount `g` to pull so that the Pool would receive a target net `T`, and reverted if the measured net fell outside `[T, T+1]`. Two problems led to its replacement (DECISIONS §15):

1. **[proven] The approved ceiling rule conflicts with the user cap.** With `g = ceil(T·D/(D−t))`, `D = 10000`, and the binding cap `T = amountMax − floor(amountMax·t/D)`, write `amountMax·t = q·D + ρ` with `0 ≤ ρ < D`. Then `T·D/(D−t) = amountMax + ρ/(D−t)`. So `g > amountMax`, and the deposit reverts, exactly when `ρ ≠ 0`. An exhaustive check over `amountMax ≤ 1000` and `t ∈ [1, 9999]` (model script, not the Solidity code) found this in 99.9% of binding cases.
2. **Real users often do not know the tax.** Rates may be unknown, random, changed by the token owner at any time, or not queryable. Any rule that predicts the gross on-chain from a hint reverts whenever the hint is wrong.

The chosen replacement (**P1+**, DECISIONS M8-1/M8-2) uses no tax hint on-chain. The Pool pulls only amounts the user authorised, measures what actually arrived, mints shares from the measured net, and bounds the user's exposure explicitly: `maxDebit` for the payer's actual balance loss, `maxExcess` for the unmatched contribution, `minShares`. Unmatched contributions enter the reserves (option X1). The alternatives below were evaluated and not adopted for M8.

### 1.2 Alternative P2 — measured net with rebalancing and refunds

**Mechanism.** As in P1+, pull and measure the nets `n_i`, then compute `σ = min(floor(n_i·S/r_i))`. Accept only the matched amounts `a_i = ceil(σ·r_i/S)` into the reserves (`reserve_i += a_i`). After the effects, refund the excess `x_i = n_i − a_i` to the payer with an outbound transfer checked by A8. Bound the payer's final net debit (pull minus refund) by `maxDebit_i`.

**Benefits.**
- Capital efficiency. **[proven, model example]** The user's loss is only the token's tax on the refunded excess, which is second order in the tax rates. In §1.5 (t0 = 5%, t1 = 3%, token0 pulled first): P2 refunds 285 units and the user receives 271, a loss of 14. P1+ instead leaves 285 units unmatched.
- Nothing unmatched enters the reserves. So deposits do not move the price beyond rounding, the "no donation into reserves" layer of the first-depositor defence (THREAT_MODEL T4) stays intact, and just-in-time LPs cannot capture a depositor's excess (T29).

**Risks and costs.**
- A deposit now contains outbound transfers. This adds a callback point after the effects, so the M5-6 reentrancy suite (bubbling / caught-correct / caught-faulty) must cover the refund as well.
- A8 on the refund makes deposits revert for tokens that over-debit the Pool on outbound transfers. This is a one-time probe at deposit time, **not** a guarantee for later withdrawals: a mutable token can change afterwards (THREAT_MODEL §7.4).
- Refunds can be taxed at an unpredictable rate, blocked (pause or blacklist), or over-debit the Pool. The deposit then either reverts or the user receives less. Protecting the user requires measuring the final debit across the whole call, including the refund.
- Floor dust makes almost every deposit refund at least one unit unless a threshold is introduced. That costs an extra transfer per deposit (not measured).
- `LiquidityAdded.net` would no longer equal the reserve increase (received ≠ accepted), so auditability needs an extra event or fields: an ABI change.
- Higher implementation and testing burden: refund failure classes × reentrancy variants × tax models.

**Trade-off.** P2 buys capital efficiency and a stronger T4 at the cost of a new outbound surface inside deposits, more failure modes, more interface and more tests. It was not adopted because of complexity and the deadline. It remains a candidate for a later refund mode (DECISIONS D14).

### 1.3 Alternative P3 — imbalanced addition with an implicit swap

**Mechanism.** Add the full measured nets to the reserves and mint the shares the depositor would get from a proportional deposit plus a swap of the imbalance, charged at the swap fee (as in Balancer- or Curve-style single-sided or imbalanced joins). For a 50/50 constant-product pool the share formula involves a square root.

**Benefits.**
- No refunds and no tax hints.
- Every unit contributed earns shares: the highest capital efficiency of all options.
- A tax mismatch never makes the deposit revert by itself; only `minShares` does.

**Risks and costs.**
- A deposit becomes a trade. It moves the spot price, exposes deposits to sandwiching and MEV, and widens the manipulation surface (THREAT_MODEL T18, T26).
- The implicit swap must pay the full swap fee. Otherwise "imbalanced add + proportional remove" is a fee-free swap route.
- Several rounding steps (square root, divisions) must each provably round in the LPs' favour. Rounding and precision errors in imbalanced joins are a known high-severity class of AMM vulnerability.
- It needs new invariant proofs, a new differential oracle and new fuzz domains. It also interacts with the first-depositor analysis (T4).

**Trade-off.** Best user outcome, but the largest new mathematical and economic attack surface. It could not be specified, proven and tested to the project's standard before the deadline. Not adopted.

### 1.4 Introducing a Router (periphery contract)

**Mechanism.** A separate contract (in the style of Uniswap V2's router) that users call instead of the Pool. It pulls tokens from the user, computes amounts from the Pool's current reserves, calls `addLiquidity` / `swapExactInput` as `msg.sender`, and returns leftovers. It could host P2-style refunds, multi-hop swaps and quoting without enlarging the Pool. It is not part of the design: ARCHITECTURE §2 lists a Router as "not introduced without separate approval" (D14).

**Benefits.**
- Better UX: one call, multi-hop, leftover handling.
- The Pool stays small. This matters because the Factory embeds the Pool's initcode (F07).
- Refund logic lives outside the Pool's accounting core.

**Risks and costs.**
- **Payer identity.** The Pool measures and bounds its `msg.sender`, which is the Router. The Pool's `maxDebit` then protects the Router, not the user. The Router must re-implement whole-call measurement of the *user's* debit, or users lose that protection.
- **Extra taxed hops.** On the path where the Router first receives the user's tokens and the Pool then pulls them from the Router (the only path this interface allows, because the Pool always pulls from `msg.sender`), an inclusive tax is charged twice: user → Router, then Router → Pool, so the Pool receives about `(1−t)²·g`. Refunds add a third hop. Exclusive FOT charges extra on every hop. Letting the Pool pull directly from the user would need a `payer` parameter with its own authorisation scheme (Permit2-like). That is an ABI and security change: without authorisation, anyone could spend other users' allowances to the Pool.
- **Allowance blast radius.** Users approve one Router for every pool. A Router bug can drain all of those allowances, whereas today each approval only exposes one Pool.
- **Stranded funds.** Leftovers and dust held by the Router between or after calls need sweep or refund logic; such functions are a common periphery footgun.
- **More surface to keep ownerless.** The Router must also be ownerless and immutable (D10), with its own ABI whitelist (an X03-style check), its own reentrancy lock (the Pool's transient lock does not cover the Router), and care with reading Pool views mid-call (T13).
- **Duplicated user parameters.** Deadline, recipient and minimum checks are duplicated between Router and Pool, and they must be consistent.

**Trade-off.** A Router improves UX and keeps the Pool minimal. But it moves user protection into a second contract that must be equally rigorous, and for taxed tokens it adds tax hops. The Pool's interface is designed to be router-compatible: payer = `msg.sender`, measured nets, explicit bounds. The Router itself stays out of scope.

### 1.5 Comparison and worked numbers

**Worked numbers** (Python model, not the Solidity implementation):
- State: `r = (1,000,000, 2,000,000)`, `S = 1,414,213`, requested `(10,000, 30,000)`.
- On-chain planning at the current reserves.
- Conditional re-planning of the second token from the first token's measured net.
- Taxes unknown to the Pool.

| Scenario | Pull order | Measured net `n` | Shares `σ` | P1+ unmatched `u` (enters reserves) | P2 refund received |
|---|---|---|---|---|---|
| Standard | either | (10000, 20000) | 14142 | (0, 0) | — |
| token1 tax 5% | token0 first | (10000, 19000) | 13435 | (500, 0) | (500, 0) |
| token1 tax 5% | token1 first | (9500, 19000) | 13435 | (0, 0) | — |
| t0 = 5%, t1 = 3% | token0 first | (9500, 18430) | 13031 | (285, 1) | (271, 1) |

The unmatched amount is not the user's loss one-to-one. Under X1 the depositor owns `σ/(S+σ)` of the enlarged pool and so recovers part of it, while price-restoring arbitrage takes a small part from all LPs (THREAT_MODEL T29).

| Criterion | P1+ (chosen, X1) | P2 refunds | P3 implicit swap | Router |
|---|---|---|---|---|
| Tax hint on-chain | none | none | none | none (Router may quote) |
| Accounting change vs. A1 | none (`reserve += n`) | `reserve += a` | new share formula | none in Pool |
| Outbound transfers in deposit | none | refunds | none | Router hops |
| User loss with unknown tax | first order in the second token's tax; avoidable by pull order when only one token is taxed | second order (refund tax) | swap fee + price impact | extra tax hops |
| Price moves on deposit | by the unmatched part | rounding only | yes | as the Pool |
| T4 layer "no donation into reserves" | weakened, bounded by `maxExcess` | intact | changed | as the Pool |
| New attack surface | JIT capture of excess | refund callbacks, A8 on refund | MEV on deposits, rounding | allowances, stranded funds |
| Implementation and test burden | medium | medium-high | very high | high (second contract) |
| Gas | measured in G05 (TEST_MATRIX §14.5): +10,264 gas (+10.4 %) on the G03-comparable later-deposit path. Evaluated, not adopted: VA, VB, VC; VC (deficit check on the start snapshot) measured −1,856 on P1–P4 and −1,924 on P6–P8, but with token0 in deficit and a reverting `token1.balanceOf` the reported error changes from `ReserveDeficit()` to the token's revert; the VA + VB + VC combination (about 3,300 on P1) is an unverified estimate | not measured | not measured | not measured |

### 1.6 Bounding the unmatched contribution: absolute amount vs. percentage of the receipt

**Decision** (DECISIONS M8-2, confirmed 2026-11-23): `maxExcess_i` is an **absolute** bound on token i's unmatched amount `u_i = net_i − ceil(σ·r_i/S)`, in the smallest unit of token i as received by the Pool. A deposit reverts with `ExcessContributionTooHigh()` if `u_i > maxExcess_i` for either token. A percentage bound on the measured receipt, `u_i ≤ floor(net_i·bps_i/10,000)`, was evaluated and not adopted.

| Criterion | Absolute amount (chosen) | Percentage of the measured receipt (evaluated) |
|---|---|---|
| Very small tolerances | expressed exactly, down to 1 unit | limited by integer bps: 1 bps = 0.01 % is the smallest non-zero step |
| What the user knows in advance | the exact number of units that may stay unmatched | only a ratio; the allowed amount depends on the receipt, which is known only after the transfer |
| Effort for the user | must understand the token's decimals | the same ratio reads the same for every token |
| Change in deposit size | the user must adjust the bound | adapts automatically to the actual receipt |
| Interface impact in M8 | none (current ABI, selector `0x7713f77f`) | new field type and selector, range check, test migration |

**Worked example** [proven, integer arithmetic]: the Pool receives `net_i = 1,000,000` units of a token, and the user wants to allow at most 1 unmatched unit.

| Bound | Setting | Allowed `u_i` | Allows exactly 1 unit? |
|---|---|---|---|
| Absolute | `maxExcess_i = 1` | 1 | yes |
| Percentage | 0 bps | 0 | no, too strict: a deposit with `u_i = 1` reverts |
| Percentage | 1 bps | `floor(1,000,000·1/10,000) = 100` | no, 100 times the intended tolerance |

The wanted ratio is 1/1,000,000 = 0.01 bps, which is not an integer bps value. The opposite effect also exists: if the same user deposits twice as much (`net_i = 2,000,000`), the absolute bound stays at 1 unit, while 1 bps would rise to 200 units. Whether this is an advantage (the user keeps exact control) or a burden (the user must re-set the bound) depends on the user; the decision favours exact control.

**Decimals.** One unit is the token's smallest unit. With 6 decimals, 1,000,000 units are 1 whole token and 1 unit is 0.000001 tokens. With 18 decimals, 1,000,000 units are only 10^−12 tokens. A UI must therefore convert a human-readable tolerance into units using the token's decimals; the Pool itself does not read decimals.

**Use in the reports.** The M8 milestone report cites this decision briefly. The M11 final report uses the example above in its design trade-offs section.

---

## 2. M10 — What `minShares` does and does not bound under swap-only state changes

**Retracted (2026-11-23, M10 review):** the review's first-batch statements "after any front-running swap σ′ ≤ σ_quote" and "`minShares` is sufficient against a sandwich" are withdrawn. Three reasons:
- The equality step `S·√(A·B/k) = σ_quote` holds only for caps exactly at the ratio (`A·r1 = B·r0`). With loose caps a swap can raise σ′ above σ_quote. Example (integer model): r = (1e6, 1e6), S = 1e6, caps (1e4, 1e5): σ_quote = 10,000; after a swap of 1e5 token1 in, σ′ = 10,996 while the depositor pays 12,096 instead of 10,000 token1. `minShares = σ_quote` does not revert; there the binding protections are the other token's cap and `maxDebit`.
- Rounding: σ_quote is floored after the step-2 floor, so it can lie below `⌊S·√(A·B/k_q)⌋`.
- Sampling: the first model drew nearly-proportional caps, large reserves and large swaps, so it did not sample the rounding edge, and it modelled only swaps between quote and execution. Share count was also conflated with value.

**Kept statements, each with its scope:**
1. **[proven] + executed (Z10):** with only swaps between the quote and the deposit, for any caps `A`, `B` and Tier 0 tokens (`n_i ≤ cap_i`): `σ′²·k_q ≤ S²·A·B`. Proof and local evidence: TEST_MATRIX Z10.
2. **[proven], model only:** if the caps are *strictly* proportional at the quote, `A·r1 = B·r0` (cross products equal), then σ′ ≤ σ_quote. Proof: step 2 at the quote gives `T = (A, B)` exactly, so `σ_quote = ⌊S·A/r0⌋ = ⌊S·√(A·B/k_q)⌋`, and statement 1 gives `σ′ ≤ ⌊S·√(A·B/k_q)⌋`. Model check: 200,000 targeted strictly-proportional samples, 0 cases with σ′ > σ_quote. Not executed on the Pool.
3. **Model observation:** with caps that are only approximately proportional after flooring, `B = ⌊A·r1/r0⌋`, σ′ = σ_quote + 1 occurred in 1,069 of 288,702 model samples with small swaps; **none of these 1,069 had equal cross products**. The example previously labelled "proportional" is not: r = (19,952, 5,314), A = 882, B = 234 gives `A·r1 = 4,686,948 ≠ B·r0 = 4,668,768`.
4. **Not claimed:** any protection of value; any statement when deposits, withdrawals or `sync()` happen between the quote and the deposit; protection against a quote taken after a per-share inflation (F1-T7).

**Use in the reports.** The M10 milestone report states 1–4 in this form; the M11 report may use statement 1 as the share-count bound and must keep the scope sentence.

---

## 3. M10 — Consequences of correct rules (review ②, 2026-11-23)

Each item is a cost or consequence of rules that work as approved. None changes a rule; the student's decision is recorded for each.

| # | Consequence | Applicable boundary | Decision |
|---|---|---|---|
| ②-1 | Positional per-token fields in add / remove vs. the `tokenIn` address in swaps | A caller with the token order reversed applies caps, debit bounds and minima to the wrong token (it may revert or execute under the wrong bounds) | Registered as a later ABI re-review item (DECISIONS §8); mapping table in ARCHITECTURE §7.10 now |
| ②-2 | A8 is two-sided | Traps tokens whose transfers differ from `x` by rounding (THREAT_MODEL §7.3) | A8 kept; disclosed |
| ②-3 | Gate R sends balance growth to `surplusRecipient` | Positive rebase, reflection or holder-balance yield (unsupported tokens): not paid to LPs | Gate R kept; disclosed |
| ②-4 | Any deficit, even 1 unit, blocks add / remove / swap until `sync()` | Small deficits give no incentive to call `sync()` | Explicit `sync()` kept (M10 decision 3); UI guidance in ARCHITECTURE §5.3 |
| ②-5 | Deposit protection is a single `minShares` with request caps | It implies only a necessary reserve interval, not a price guarantee (ARCHITECTURE §7.2) | Documented; a per-token minimum would change the ABI and is not proposed now |
| ②-6 | User protection lives in the Pool | Measured in G05 (TEST_MATRIX §14.5): +10,264 gas (+10.4 %) for the later deposit **P1 (token0 first, token0 cap binds) compared with the G03 baseline 98,525 of the same path at the pre-M8 code** under identical harness conditions; other paths are not comparable with G03. A Router would add a second taxed hop on the path described in §1.4 | Not re-opened; G02 reports the isolated variants |
| ②-7 | The 1,000-share lock | Takes the lock's pro-rata part of fees and unmatched contributions permanently; large share of a small pool (DECISIONS D8 note) | Kept (as Uniswap V2); figures in the report |
| ②-8 | Same LP `name` / `symbol` in every pool | Wallets cannot tell pools apart by name | Kept (M3-1) |
