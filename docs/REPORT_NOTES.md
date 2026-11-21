# REPORT NOTES — Draft Material for the Coursework Report

**Last updated:** 2026-11-21

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
- **Extra taxed hops.** With a router, an inclusive tax is charged twice: user → Router, then Router → Pool, so the Pool receives about `(1−t)²·g`. Refunds add a third hop. Exclusive FOT charges extra on every hop. Letting the Pool pull directly from the user would need a `payer` parameter with its own authorisation scheme (Permit2-like). That is an ABI and security change: without authorisation, anyone could spend other users' allowances to the Pool.
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
| Gas | **not measured** (G05) | not measured | not measured | not measured |
