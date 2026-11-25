# Talk plan: 10 minutes + 5 minutes of questions

Structure required by the brief: (1) what an AMM is and why a smart contract; (2) the solution, with strengths, weaknesses, decisions, the broader picture and ways to improve. No slides required; the report sections to show on screen are given in brackets.

## Part 1 — What an AMM is (≈ 2.5 min)

1. **Problem (30 s).** An exchange needs someone willing to trade at any time. An order book needs market makers and many cheap updates; on Ethereum every update costs gas.
2. **Idea (60 s).** A pool holds two tokens; a formula sets the price. Constant product `x·y = k`: buying token1 makes it scarcer and dearer. Fee 0.3 % stays in the pool and pays liquidity providers. One worked number: reserves (10,000, 20,000) → price 2. [Report §2.1–2.2]
3. **Why a smart contract (60 s).** The rules run without an operator: no admin can freeze funds or change the fee (the code itself can still block a pool, e.g. on a deficit); anyone can verify the code; other contracts can trade with it (composability). The cost: bugs are permanent and public, so security matters more than features.

## Part 2 — My solution (≈ 7 min)

4. **Architecture (60 s).** Factory → one Pool per pair; the Pool is also the LP token; a small maths library. No owner, no upgrade, no pause. Recorded reserves, not balances. [§1.1, §4]
5. **LP shares (45 s).** First deposit `√(x·y) − 1000`, the 1,000 locked forever against inflation attacks. Pro-rata claim; `√k/S` never falls through add/remove/swap — but this is not market value (impermanent loss). [§3]
6. **Main extension: measured deposits (2 min).** Walk through the L46 table: cap → debit → receipt → shares → excess. Explain why measuring matters (taxed tokens) and what each bound promises: caps bound what the Pool may request, `maxDebit` bounds the payer's balance decrease, `maxExcess` bounds the unmatched amount, `minShares` bounds only the share count; none of them guarantees value. One example for the two caps: `RequestMax = 100, maxDebit = 105` allows a 5-unit sender fee. L46: `minShares = 1,272` passes but `maxExcess0 = 99` reverts the same deposit. [§5.2, §5.4]
7. **Security decisions (90 s).** Reentrancy guard + checks/effects; direct transfers cannot move reserves (`skim` to a fixed recipient, `sync` only lowers) vs Uniswap V2's two-way `sync`; A8 + MIN-NET on every output; deficit blocks the pool. The inflation question: what was executed, what is only a model. [§8, §9.2]
8. **Verification and gas (60 s).** 492 tests incl. invariants; per-feature mutation checks (no single aggregate count). G02 measures selected operations in fixed, stated scenarios (one call, cold state), not averages over states. Two optimisations adopted (burn before the maths: a failed withdrawal costs 2,543 less; constant LP `name()`/`symbol()`: −70,154 per `createPair`, ABI unchanged). Rejected: VP (≈ −4,300 per call, but reserves capped at 2¹¹² and +159k per deployment) and VU (a few hundred gas, but proofs become load-bearing). Evaluated, not adopted: skipping the payer snapshot when `maxDebit` is unbounded (−3,846, only for users who give up that bound) and clone pools (≈ 2M saved per pair, ≈ +6k on every call). [§10, §11]
9. **Weaknesses and improvements (60 s).** Exit not guaranteed for odd tokens; excess not refunded; no per-token deposit minimum; deficit freezes; no oracle/MEV protection. Improvements: a router with per-token minima, optional VU after review, TWAP oracle, an ABI that names tokens by address. [§12]

Close (10 s): "A small, conservative core whose protections each say exactly what they guarantee."

## Question practice (answer in ≤ 30 s each)

| Question | Short answer | § |
|---|---|---|
| Why 1,000 locked shares? | Makes the first-depositor donation attack cost ≈ 1000× the per-share gain; keeps reserves > 0 through add/remove/swap. | 3.2, 9.2 |
| Why can't someone inflate shares by sending tokens to the pool? | Direct transfers become surplus; reserves are written only by Pool functions; `sync` only lowers. | 4.4, 8 |
| What does `minShares` protect? | Only the share count. Caps bound what the Pool may request and `maxDebit` the payer's debit; neither guarantees value. A general sandwich claim was retracted. | 5.4, 5.6 |
| Why keep the excess instead of refunding? | A refund is another outbound (taxed, failure-prone) transfer inside a deposit; the excess benefits all shares and is bounded by `maxExcess`. | 5.7 |
| Walk me through `_pullLater`. | Plan at the ratio within caps (512-bit product), pull first token, re-plan second only if the first delivered differently, pull second. | 5.3 |
| What is BI-2′? | After the transfers, each Pool balance must have risen by at least what we measured; catches a foreign removal during the call. | 5.3 |
| Why does A8 demand equality? | An output that moves the Pool's balance by a different amount means a token outside the model; equality rejects both directions. Cost: rounding-share tokens are not withdrawable. | 6.2 |
| What happens with a deficit? | Add/remove/swap revert; `sync` books the loss, or an exact top-up restores the pool (R24). | 8.2, 8.3 |
| Is the pool safe from reentrancy? | All five state-changing functions use a transient-storage guard; callbacks tested bubbling and swallowed; views are unguarded (read-only reentrancy). | 9.1 |
| Why both `RequestMax` and `maxDebit`? | One bounds what the Pool requests, the other what the payer actually loses; `100 / 105` tolerates a 5-unit sender fee. Equal values are fine for ordinary tokens, but the debit is still measured. | 5.4 |
| Why not clone pools to save deployment gas? | Measured: a clone saves ≈ 2M once per pair but costs ≈ +6k on every call; break-even ≈ 337 calls (estimate, +6,072 per call, implementation deployment not amortised). Busy pools pay more. | 11.4 |
| Why not `uint112` like Uniswap? | Measured: saves ≈ 4,300 gas per call, costs 159k per deployment, and caps reserves at 2¹¹²; rejected to keep the full approved range. | 11.2 |
| Biggest open problem? | Exit safety for tokens that change behaviour; inflation via excess is bounded but the supported-token path is only modelled. | 12 |
| How do you know the maths is right? | Independent integer models give expected values; fuzz and invariants check them on the real contract; for each feature, deliberate bugs were inserted and every reported mutant was killed or analysed (counted per feature, not as one total). | 10 |
| What did AI help with, and how did you check it? | Be honest about the workflow; point to the tests, models and the retracted claim as examples of checking. | — |
