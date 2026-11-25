# THREAT MODEL — AMM Security Threat Model

**Last updated:** 2026-11-25

**Status (M11, 2026-11-23):** implemented and tested through M8 (accepted); M9 (protocol fee) out of scope; F1-T4, the full P5 fee path, stays **deferred** (model evidence only, T4). Implemented and tested (M2–M7): constructor checks (T11); `nonReentrant` on `addLiquidity`, `removeLiquidity` and `swapExactInput` with the M5 attack suite — same-function and cross-function, bubbling and caught re-entry (T1); measured input on deposits and swaps (T2, T5 — taxed inputs fully tested only in M8); exact swap formula with the fee-adjusted inequality, enforced by tests only (T8, A9 = DECISIONS M5-9); the lock and LP-SELF supply controls (T10, T24); MIN-NET on withdrawal and swap (T7); read-only reentrancy demonstrated, no view guard (T13); recipient checks on add, remove and swap (T14); `minNetAmountOut` and deadline on swap (T18); full rollback on failing/false-returning tokens, no-return tokens accepted (T20); ownerless ABI verified statically and at run time (T21); A8 on withdrawal, swap and skim (T23). M6: downward-only `sync()` (T3), deficit entry check on add, remove and swap (T9), per-token `skim()` to the immutable recipient with A8 (T12, T15, T16 Pool side), terminal-pool rules after a zero reserve (T25), `nonReentrant` on `sync` / `skim` with the bubbling / caught suite (T1). M7: Factory registry — sorting, zero / identical / duplicate rejection in both orders, code-existence check in the Factory only (T17); shared immutable recipient (T11); Factory ownerless, no payable entry point, no token-withdrawal function (T21); terminal pairs blocked (T25). M8 (implemented on branch `m8-measured-deposit`, **accepted 2026-11-23**; TEST_MATRIX §3.2, §3.4): measured-net `addLiquidity` with the whole-call payer-debit bound `maxDebit` (T28), the unmatched-contribution bound `maxExcess` (T29), measured taxed inputs on deposits (T2, T5, T6), and the in-call balance check BI-2′ (DECISIONS M8-11, `APPROVED`, implemented in commit 4); limitation tests for trapped liquidity, later tax changes and swap/remove scope (T27, T30, §7); T4 revised after L13b and recorded as a known economic limitation. **Any mitigation not listed above is unimplemented or untested.** A mitigation reduces risk; it does not mean the attack is eliminated. Passing tests is not a proof of security.

Status labels: [DECISIONS.md](DECISIONS.md) §0. Invariants BI-x and sections: [ARCHITECTURE.md](ARCHITECTURE.md). Test IDs: [TEST_MATRIX.md](TEST_MATRIX.md).

## 1. Assets

- `token0` / `token1` balances held by each Pool.
- LP `totalSupply` and each holder's redemption right.
- The permanently locked minimum liquidity.
- Integrity of the Factory registry.
- Unskimmed surplus in a Pool, which may be someone's mistaken transfer.

## 2. Actors

| Actor | Assumptions |
|---|---|
| Traders and LPs | May be honest or malicious. |
| Any external account | Can call every public function and transfer tokens (including LP tokens) directly to a Pool. |
| Token contracts | Trusted only within their tier's assumptions (ARCHITECTURE §3). `balanceOf`, `transfer`, `transferFrom` are trust boundaries. |
| Front-runners / MEV searchers | Can observe and reorder transactions. |
| `surplusRecipient` | No privileged functions; economic beneficiary of surplus; whether it refunds mistaken senders is off-chain trust. |
| Owner / admin | None (D10-A). |
| Protocol fee recipient | None now (`FUTURE-ONLY`). |

## 3. Trust assumptions

- **Tier 0:** standard ERC-20; amount debited equals amount credited.
- **Tier 1:** exactly the U8 model (inclusive, `floor(g × taxBps / 10000)`, fixed and address-independent rate, truthful `balanceOf`). For swap, remove and skim no other taxed token is claimed compatible. **Deposits (M8, DECISIONS M8-1, M8-12):** `addLiquidity` does not rely on U8; it also accepts inclusive taxes of unknown, random or changing rate and inbound extra sender-side debits bounded by `maxDebit`, as conditionally supported (category 2, §7.2), with no claim that such liquidity can be redeemed later (§7.4). (Errata 2026-11-23: this paragraph previously contradicted §7.2.)
- `SafeERC20` handles missing/`false` return values; it does not guarantee a token's economics.
- No token can tell the Pool who made an unsolicited transfer.

## 4. Threats

| ID | Threat | Surface | Mitigation (design) | Tests | Residual risk |
|---|---|---|---|---|---|
| T1 | Reentrancy via token or recipient code | add, remove, swap, sync, skim | `nonReentrant` on every function that can change reserves or LP supply (add, remove, swap, sync, skim); the inherited LP ERC-20 functions are unguarded by design because they change neither reserves nor `totalSupply` (ARCHITECTURE §7, wording corrected 2026-11-23); outbound transfers after effects; attacker mocks for cross-function reentry (bubbling, caught + correct transfer, caught + faulty transfer; DECISIONS M5-6, M6-5) | W07, S08, X01 (incl. M6 extension), L24 | Inbound `safeTransferFrom` precedes reserve update by necessity (ARCHITECTURE §7); view functions unguarded (T13) |
| T2 | Earlier surplus counted as the current caller's input | add, swap | In-call balance snapshots (§5.2), each taken immediately before its own transfer (DECISIONS M6-8), with one exception (DECISIONS M11-4): in a later `addLiquidity` the first-pulled token's before-reading is its entry reading, taken after the checks with only view calls before its transfer. The second token is reread just before its own transfer, because the first transfer (and any token callback in it) may have moved it; BI-2 | R07, S07, B01, B03, B08, L13 | Relies on truthful `balanceOf` |
| T3 | Price manipulation or share-value inflation via direct transfer + `sync()` | sync | Gate R=(b): `sync()` never absorbs surplus (BI-4) | R05, R10, B05 | In a deficit, `sync()` still changes reserves (T9) |
| T4 | First-depositor inflation (tiny first position plus large direct transfer to dilute later LPs) | first/later mint | 1,000 LP locked; direct transfers never enter reserves (T3); `shares > 0` and `minShares` | L01, L02, L13 | Layered mitigations, not a formal proof; very small deposits are rejected. **M8 (DECISIONS M8-2, X1):** unmatched deposit contributions, bounded by the depositor's own `maxExcess`, enter the reserves. This reopens a bounded way to donate into reserves through `addLiquidity`. Analysis (not a proof): to raise the value of one share by Δ, an attacker loses at least about 1000·Δ, because the locked 1,000 LP keep their pro-rata part of the donation; a later depositor's extra floor-rounding shortfall per deposit is at most about Δ; the depositor's own `maxExcess` bounds it, and `minShares` protects only against changes between quoting and execution. This is Uniswap-V2-level protection, weaker than before M8. **Profitability (revised 2026-11-22 after M8 L13b; analysis plus measurements, not a formal proof).** The earlier conclusion "donating never increases profit" is **withdrawn**: it compared the donation's cost with the gain from a single later deposit only.
- An attacker's own `maxExcess` bounds only its own donation.
- Cost: whoever donates loses at least the lock's pro-rata part of the donation. So raising token i's per-share value by `Δ_i` costs at least about `1000·Δ_i`, and more when other LPs hold shares.
- Gain: each later deposit has a per-token pre-deposit shortfall `n_i − σ·r_i/S = u_i + δ_i` with `0 ≤ δ_i < 1` smallest unit. For exact-delivery tokens this is below one share's worth plus one smallest unit of the floored token ([proven] `u_i < r_i/S + r_i/r_j`); otherwise the depositor's own `maxExcess` bounds `u_i`. The donation raises it by at most about `Δ_i` per deposit. A holder of `h` shares gains `h/(S+σ)·(u_i + δ_i)` in token i from that deposit (book value). The **cumulative gain therefore depends on each later deposit's shortfall and on the holder's fraction at the time of that deposit**, and grows with the number of later deposits, while the donation's cost is paid once.
- **Executed (Foundry, real `AMMPool` contract with a `MockFeeERC20` bonus, `test/AMMPoolInflation.t.sol`, L13b).**
  - The bonus mints to the Pool during the attacker's own transfer. This token behaviour is outside Tier 0/1, and the channel has no overhead beyond the donated amount, which is counted as paid.
  - Setup:
    - the attacker deposits (1e6, 1e6), then donates 1e25 per token;
    - the later deposits all come **from one address**, each `w ∈ [1e21, 1e21 + 2^64 − 1]` of token0 plus the matched token1;
    - that address **redeems all its shares together at the end**, after the attacker has exited;
    - both tokens are valued 1:1, with no price movement.
  - Attacker P&L, from executed `removeLiquidity`, both tokens summed at 1:1:

    | Scenario | Attacker P&L (wei) |
    |---|---|
    | No donation | −2,000 (the lock) |
    | 1 deposit | −19,998,152,847,762,923,531,356 |
    | 1,000 deposits | −11,105,279,878,487,883,917,245 |
    | **5,000 deposits from one address, unbounded `maxExcess`** | **+18,166,023,885,590,118,188,675** |
    | 5,000 deposits with a 10 bps `maxExcess` (558 accepted, 4,442 reverted) | −19,453,511,173,263,290,587,278 |

  - Per token, the profitable case is asserted on-chain in F1-T9's control group (`test/AMMPoolF1HonestLP.t.sol`): A3 P&L (wallet change minus the donated D per token) +9,083,016,484,294,218,244,145 token0 and +9,083,007,401,295,899,944,530 token1.
- **Executed F1 follow-up tests (2026-11-23, local Foundry EVM, real `AMMPool`; TEST_MATRIX §3.4).**
  - F1-T9 honest LP. Both groups executed the full 5,000-deposit L13b sequence against the real contract, with the same exit order (alice, bob, then the honest LP) and the same A3 cost basis. carol enters after alice's initial deposit and before the donations, depositing (10,101, 10,101) for 10,101 shares: 10,101 / 1,010,101 = 0.99999901 % of the total LP supply including the 1,000 locked LP. A3 = wallet change − D per token; the bonus is minted to the Pool for free, so the wallet change is listed separately. Under these conditions alice's A3 P&L turns from positive to negative in each token: token0 +9,083,016,484,294,218,244,145 → −91,153,837,011,029,980,641,690; token1 +9,083,007,401,295,899,944,530 → −91,153,746,768,909,116,702,138. The baseline details of the earlier "1 % honest LP" model are not recorded.
  - F1-T3 swap-fee channel, reduced scale, supported Tier 0 tokens: up to 2,000 round trips (4,000 swaps) executed. With alice as the only trader and the only non-locked LP, her per-token wallet loss after exiting equals what stays in the Pool. The number of round trips needed to reach 1e25 is a model estimate; capital need, execution and net profitability of the full P5 path remain unverified (F1-T4 deferred).
  - F1-T6 book claim vs redemption: the 909 fresh shares redeem to gross (0, 826,746) and revert `InsufficientLiquidityBurned`; the (0, 909,082) example is model-only. F1-T7: `minShares` enforces the user's share floor when the state changes after the quote (quote computed by the test per the documented rule; state change from the bonus mock). F1-T8: with the fixed 50 deposits and redemption order, a merged redemption receives 3 token0 and 6 token1 units more than individual redemptions.
  - The test records the attacker's gas for its four transactions in this mock scenario (815,882), but **the P&L does not deduct gas**.
  - `minShares` equal to a quote taken after the inflation did not prevent the shortfall, and a direct transfer followed by `sync()` did not inflate the reserves.
- Ordinary ERC-20 tokens, source reasoning:
  - recorded reserves are written only by the initial deposit, the later deposit, `removeLiquidity`, `swapExactInput` and `sync()`;
  - `sync()` only lowers a reserve and `skim()` writes none;
  - inbound amounts are measured around the Pool's own transfer, so earlier surplus is not counted;
  - for exact-delivery tokens the unmatched part of one deposit obeys the bound above, whatever `maxExcess` the caller sets;
  - swap fees raise the reserves without minting shares. This has been so since M5 and is the same as in Uniswap-V2-style pools.
- Model only, not executed on-chain:
  - about 32,040 (input 10× the reserve) or 58,288 (1×) round-trip swaps reach an L13b-scale state, with a peak temporary token0 inventory of 2e25–1.1e26;
  - when the attacker is the only non-locked LP, its unrecoverable cost in each token equals what stays in the Pool after it exits (executed only at reduced scale, F1-T3);
  - with fixed-tax tokens the M8 unmatched contribution burns about as much of the other token as it donates.
- **Not verified:** executability and net profitability with supported tokens. That would need all of:
  - an executed supported-token inflation path;
  - measured gas;
  - capital and holding-period costs;
  - price movement and impermanent loss;
  - arbitrage;
  - other LPs (in the executed bonus-channel scenario F1-T9, an honest LP of 0.99999901 % entering before the donations turned alice's per-token A3 P&L negative; other sizes, timings and channels untested);
  - enough later deposits with loose or unbounded `maxExcess`;
  - an explicit valuation of the two tokens;
  - redemptions that actually execute rather than book claims (T6).
- Status: known economic limitation of the Uniswap-V2 class; not a demonstrated exploit with supported tokens.
- Donating token i does not change token j's per-share value, so it cannot inflate the rounding loss in token j.
- Griefing (making deposits of value `V` revert with `σ = 0`) costs at least about `1000·V`.
- Assumptions: donated tokens have real cost to the attacker (an attacker who can mint a pool token freely breaks any pool containing it anyway), and balances are truthful.
- Separate MEV risks, not inflation: JIT capture of a victim's excess (T29), and sandwiching a deposit around a price move. The latter is bounded by the victim's own request caps, `maxDebit` and `minShares`, and is the same class as a Uniswap V2 `addLiquidity` sandwich (T18).

Executed: L13 (M6), L13b and the F1 follow-up tests T1–T3, T5–T9 (TEST_MATRIX §3.2, §3.4); F1-T4 (full P5 path) deferred. (Errata 2026-11-23: replaces the stale "To be tested by an L13 extension".) |
| T5 | Inbound tax over-credited | add, swap | Account only measured net | S05, L05 | Only the U8 model. M8: measured net regardless of rate (§7.2) |
| T6 | Adaptive deposit over-debits or mints unfair shares | add (Tier 1) | L-α seven conditions; `[T, T+1]` check; wrong hint reverts. **M8: L-α retired** (DECISIONS M8-1); replaced by the measured-net bounded deposit: no tax hint on-chain; shares from measured net; payer debit bounded over the whole call (`maxDebit`, M8-3); unmatched contribution bounded (`maxExcess`, M8-2) | M8: L37, L39, Z08, Z09, F1-T6; L11, L12 (Tier 0 in M4, taxed tokens in M8). The L-α tests L05, L09, L10a–L10c and Z05 are retired with L-α (TEST_MATRIX §3, §3.3; errata 2026-11-23) | Rounding dust, not zero. **Book shortfall vs executable redemption:** with both reserves positive, `removeLiquidity` passes its rounding check only if both integer gross outputs `⌊shares·r_i/S⌋` are at least 1 smallest unit; otherwise it reverts `InsufficientLiquidityBurned` and the user still holds its shares. Example (Tier 0, caps (MAX, 1e6), so the Pool pulls (1, 1e6) and mints σ = 909): at reserves (1100, 909,338,911) with S = 1e6, an immediate redemption of the 909 shares computes (0, 826,746); at the mathematical state (1100, 1e9) with S = 1e6 (reachability not checked) it computes (0, 909,082). Both revert `InsufficientLiquidityBurned`. The 17.3% token1 shortfall in the first case (pre-deposit reference difference `n_1 − σ·r_1/S`) is therefore a **book shortfall**. Only if the redemption succeeds and the transfers arrive in full may the book shortfall `S/(S+σ)·(u_i + δ_i)` plus a rounding difference below one smallest unit be stated as the user's actual loss. Before M8 the Pool could not observe the sender's debit; M8 measures it (T28) |
| T7 | Outbound tax leaves the recipient short | swap, remove | MIN-NET: compare the recipient's actual increase with the user minimum (BI-6) | S04, S06, W04, W05, B07 | Recipient balance measurements are unreliable for special recipients (e.g. the token's own tax collector); unsupported |
| T8 | Fee missing or miscomputed | swap | Exact formula (§6.4); fee-adjusted inequality with proof (§6.5); five reference cases incl. tightness (`out + 1` fails); exact-formula fuzz at Pool level | S02, S10, S11, S14, S15, Z01 | Tests sample behaviour; no on-chain assertion (A9 = tests only, DECISIONS M5-9): without A9 the swap lacks one additional on-chain invariant check, so certain implementation errors that no other check detects might not be stopped at run time by this invariant |
| T9 | Deficit (`balance < reserve`) | add, remove, swap | Entry check `ReserveDeficit()` reverts those three before any effect or transfer (DECISIONS M6-2); `sync()` lowers reserves and emits `ReserveSynced` (U4) | R08, R17, B05 | Should not occur with supported tokens; if it does, LPs bear the loss once `sync()` is called. Tested: deficits present at entry, in either or both tokens, for every operation. Not covered by the entry check: a deficit created during the call by an unsupported token (e.g. a hook that reduces the Pool's balance of the other token); A8, `[T, T+1]` and MIN-NET check only the transfer they surround, so such a deficit is not proven to be detected in that call and is first rejected by the next call's entry check (until `sync()`). `getAmountOut` has no deficit check and may quote from stale reserves while swaps revert (`test_R08_quoteDoesNotCheckDeficit`) |
| T10 | Locked LP moved or burned | LP ERC-20 | Lock held by `address(this)`; `_update` rejects any movement or burn from the Pool and any mint/burn outside `nonReentrant` (DECISIONS M3-2); code-review rules (§7.9); BI-7 | P05–P08, P10, I1 | On-chain checks plus tests, not a formal proof |
| T11 | Wrong `surplusRecipient` at deployment | deployment | Constructor rejects `address(0)`, `token0`, `token1`, `address(this)` | K02, K04, F05 | Catches only those four values; any other wrong address is undetectable and immutable — redeploy and migrate. Factory (DECISIONS M7-1): one immutable recipient is shared by every Pool of a Factory; the Factory constructor additionally rejects `address(0)` and the Factory itself. Before deployment the recipient must be fixed explicitly and checked so that it can receive **and withdraw** the expected ERC-20 tokens. A wrong recipient cannot be repaired in an existing Factory: the only remedy is a new Factory, and existing Pools are not migrated automatically. If the recipient is itself a token contract, no pair containing that token can be created |
| T12 | `surplusRecipient` keeps mistaken transfers | skim | None on-chain | — | Entirely off-chain trust; must be disclosed |
| T13 | Read-only reentrancy: a callback reads `getReserves()` / `getAmountOut()` mid-call | view functions | No `nonReentrantView` (DECISIONS M5-5). Effects before outbound transfers; at every callback point reserves and LP supply form a consistent snapshot (pre-call during inbound pulls, post-effects during outbound pushes) | X05 | Mid-call reads during an inbound pull return pre-call values although the Pool's balance may already have changed; no in-scope consumer relies on them. **Re-evaluate T13** if any of these changes: hook/callback tokens become supported; an external protocol is expected to use `getReserves` / `getAmountOut` as a price source or collateral oracle; the effects-before-interactions order of any function changes; new view functions derive values from balances rather than recorded reserves |
| T14 | Recipient set to the Pool, manufacturing surplus | swap, remove, add | Reject `recipient ∈ {address(0), address(this)}` (U7) | S12, W08, L14 | — |
| T15 | `skim()` transfer fails (e.g. recipient blacklisted by a token) | skim | `skim()` is independent of other functions | R12 (tested: add, remove and both swaps still work) | The whole `skim()` call reverts, so **neither** token's surplus is sent while one transfer keeps failing; blacklisting tokens are unsupported |
| T16 | Taxed token in `skim()` | skim | Pool accounting ignores the recipient's receipt; A8 checks the Pool side | R09 (M8); short delivery shown not rejected in `test_X01_M6_skimCallback_caughtShortDeliveryNotChecked` | Recipient receives less than the surplus |
| T17 | Duplicate pairs, fake or undeployed token addresses | Factory | Sorting; zero / identical / duplicate rejection (both orderings); code-existence check `TokenHasNoCode()` in the Factory only (DECISIONS M7-2) | F01–F03 | A deployed token can still be malicious; code existence does not prove ERC-20 compliance or safety. The Pool constructor is unchanged, so a directly deployed Pool still accepts code-less addresses (it cannot receive funds: `SafeERC20` / `balanceOf` revert). A pair cannot be created in advance for a not-yet-deployed token. Anyone may create any pair; the creator gains no privilege (shared, immutable parameters), and the initial price is set by the first depositor, not the creator |
| T18 | Sandwich / price manipulation | swap | `minNetAmountOut`, deadline | S04 | Limits the user's loss; does not prevent MEV; no oracle |
| T19 | Overflow or rounding error | all maths | Checked arithmetic; `mulDiv` where needed; per-formula ranges (§6.6); boundary and fuzz tests | Z01–Z06 | Ranges are hand-derived sufficient conditions, confirmed only by tests; outside them a call may revert |
| T20 | Token transfer fails, returns `false`, or returns nothing | external calls | `SafeERC20`; atomic rollback | L06, S09, X02 | — |
| T21 | Unauthorised admin action | all | No privileged function exists; compiled ABI equals the approved list, no fallback/receive; admin-style and unknown selectors fail at run time (DECISIONS M5-7) | X03, X03-F | Deployed contracts cannot be paused or repaired. Factory (DECISIONS M7-7): no owner and no setter; the Factory does not expose payable entry points or token withdrawal functions |
| T22 | LP allowance misuse | LP ERC-20 | Standard OZ behaviour | P02 | The standard ERC-20 approve race remains |
| T23 | Token over-debits the Pool on outbound transfer (exclusive FOT or similar) | remove, swap, skim | A8: Pool balance must fall by exactly the amount sent, else revert (BI-5) | B06, X04 | Detects this one behaviour; does not make such tokens usable |
| T24 | User sends LP tokens to the Pool address by mistake | LP ERC-20 | LP-SELF (ii): LP transfers to the Pool revert, including zero-value transfers | P06, P09 | LP sent to other wrong addresses is still unrecoverable (standard ERC-20 behaviour) |
| T25 | Zero-reserve state: after `sync()` lowers a reserve to 0 while `totalSupply > 0`, later deposits could hit division by zero and proportional withdrawals could revert (`amount_i == 0`), trapping the LPs' remaining other-token assets | add, remove, sync | Terminal-pool rule (DECISIONS M6-1, M4-3r, ADR-023): deposits and swaps revert `InsufficientLiquidity`; withdrawal pays the remaining non-zero reserve proportionally, with MIN-NET on both sides. Implemented and tested in M6 (zero reserve in either token, both zero, with surplus, last LP exit) | R14–R22 | Arises only with tokens outside the supported model. A terminal pool cannot trade again through the current interface; the reserves backing the 1,000 locked LP can never be redeemed (recovery = extension candidate, DECISIONS §8). Because each pair is unique in the Factory, a terminal Pool also blocks its pair in that Factory permanently: `createPair` reverts `PairExists()` (DECISIONS M7-5, F04b) |
| T26 | Price manipulation and oracle misuse: the Pool's spot price (`getReserves`, `getAmountOut`) can be moved arbitrarily within one transaction by a large (e.g. flash-loan-funded) swap and moved back afterwards; a protocol that reads it as a price feed or collateral oracle can be exploited | swap, views | Within the Pool: swaps are priced only from recorded reserves, so direct transfers never move the price (Gate R=(b), R01, Q03, S07); `sync()` can only lower a reserve when the balance has really fallen (BI-4, unsupported tokens only); `minNetAmountOut` and deadline bound a user's own loss (T18); every swap keeps the fee-adjusted invariant (BI-9). No oracle: no TWAP, no cumulative price, no manipulation-resistant view (ARCHITECTURE §10, `OUT-OF-SCOPE`) | R01, Q03, S07, S04, S11 | The spot price is manipulable by anyone with enough capital for the duration of a transaction; sandwiching and MEV remain (T18); views are unguarded mid-call (T13); during a deficit `getAmountOut` can quote from stale reserves (DECISIONS M6-9). Integrators must not use any view of this Pool as an oracle; an oracle would be a new extension needing a separate decision (D14) |
| T27 | Liquidity trapped after deposit: a token later refuses Pool outbound transfers (pause, blacklisting the Pool, a fee that over-debits the Pool) or its `balanceOf` reverts | remove, swap, skim, sync | None that can guarantee exit: A8 is kept unchanged (DECISIONS M8-7). No inbound check can establish future outbound behaviour of a mutable or upgradeable token (§7.4) | Limitation tests (M8): deposit succeeds → outbound fee enabled → `removeLiquidity` reverts `OutboundTransferMismatch` with state unchanged; `balanceOf` revert blocks every function | High. The healthy token's assets can become unredeemable too, and the Pool can keep buying the broken token through swaps (§7.6). No approved recovery path (§7.5) |
| T28 | Payer-debit bound evaded or mismeasured | add | `msg.sender`'s balance of each token snapshotted after all checks and before the first transfer, and again after the last external call; net decrease `≤ maxDebit_i` (DECISIONS M8-3). [proven] This captures every in-call change, including cross-token callbacks, because all state-changing external calls lie between the snapshots and `balanceOf` is called with STATICCALL | L37 (`maxDebit` boundary, inclusive / exclusive / random fee), L38 (cross-token callback debiting the payer), L40 (error order), Z09 (debit ≤ `maxDebit` fuzz) | [assumption] truthful `balanceOf`. The bound is the payer's **net** in-call change (in-call credits offset debits). Debits the token applies after the call are not covered. With a router, the bound protects the router (the payer), not the end user (REPORT_NOTES §1.4) |
| T29 | Unmatched deposit contribution captured by others | add | Bounded by the depositor's `maxExcess_i` (absolute, Pool-received units; DECISIONS M8-2); `minShares` | L36, F1-T1, F1-T5 (`maxExcess = u` succeeds, `u − 1` reverts), Z09 (`u ≤ maxExcess` fuzz), L41 (JIT capture) | Under X1 the excess belongs to everyone who is an LP at execution time, including a just-in-time LP who adds before and removes after the deposit. The depositor recovers only its own pro-rata part; price-restoring arbitrage takes a small part from all LPs. For a taxed token the depositor's gross cost of `u` is higher than `u`. The unmatched amount also moves the spot price (T26) |
| T30 | Foreign balance change during `swapExactInput` / `removeLiquidity` (a callback of one token moves the Pool's balance of either token outside the transfer being measured) | swap, remove | Guarantees from M5/M6, unchanged by M8: the entry deficit check (M6-2); each own transfer measured from a fresh snapshot (M6-8); A8 on every outbound transfer; MIN-NET on the recipient; `nonReentrant`. M8's in-call balance check (BI-2′, `InCallBalanceLoss`) applies to **`addLiquidity` only** (DECISIONS M8-11, R2 = (a)) | B08 (donation stays surplus), X01 | Not detected within the call: a foreign **decrease of surplus** (for example unskimmed surplus taken by a cross-token callback) is never detected; a foreign change that creates a **deficit** is first rejected by the next call's entry check (until `sync()`). Arises only with tokens outside the supported model. Extending the check to swap / remove is a separate, later decision (with the optimisation items) |

## 5. Excluded from the current attack surface

### 5.1 Protocol-fee accounting

Double minting of protocol LP shares, `kLast` mis-attribution, fee accounting after reserve changes: not applicable because no protocol fee exists (`FUTURE-ONLY`). If one is added, redo this model, especially for reserve changes caused by deficit reconciliation.

### 5.2 Owner key compromise

No owner exists. This does not remove risk around the economically privileged `surplusRecipient` (T11, T12).

## 6. Limitations the report must disclose

1. Unit, fuzz and invariant tests are evidence over sampled states, not a formal proof.
2. Refunds of mistaken transfers depend on off-chain trust in `surplusRecipient`.
3. Immutable parameters cannot be corrected; the four `surplusRecipient` checks catch only four obvious mistakes.
4. Tier 1 covers only the U8 model; other taxed tokens may revert or behave outside the guarantees.
5. Later deposits leave an unmatched contribution `u_i` in the reserves (M8-2, X1); it benefits all LP shares pro rata (the depositor's new shares and the lock included) and is not zero. Its size depends on the token (M10 scope revision):
   - Tier 0: rounding only, `u_i < r_i/S + r_i/r_j` at execution ([proven], F1-T1);
   - taxed tokens: of the order of the tax on the deposit, depending on the pull order (REPORT_NOTES §1.5: a 5 % tax on token1 pulled second leaves 500 of 10,000 token0 unmatched, 5 %); bounded only by the depositor's `maxExcess_i`.
6. No MEV protection, no oracle, no pause. Deadlines use `block.timestamp`, which a block producer can shift by a few seconds (`forge lint` `block-timestamp`); a deadline bounds staleness, not exact timing.
7. Arithmetic ranges are hand-derived sufficient conditions; inputs beyond them may make legitimate calls revert.
8. A failing transfer of one token blocks `skim()` for both tokens.
9. `LiquidityAdded` / `LiquidityRemoved` / `Swap` are emitted after the token calls, because the Pool must first measure balances (`forge lint` `reentrancy-events`). All three functions are `nonReentrant`, so a token callback cannot interleave another Pool event; off-chain consumers should still treat the return values and balances as authoritative.
10. Deficits (T9): the M6 entry check stops add, remove and swap when a deficit exists at entry (tested for each token and both); the LPs bear the loss once `sync()` is called, and `getAmountOut` can quote from stale reserves during a deficit. Each transfer is measured from its own fresh snapshot, which costs about 860 gas per call more than reusing the entry reading (DECISIONS M6-8); since DECISIONS M11-4 a later `addLiquidity` reuses the entry reading for its first-pulled token only (the second token is reread before its transfer, and BI-2′ still checks both tokens over the whole call).
11. Read-only reentrancy (T13): view functions are unguarded by design (DECISIONS M5-5); integrators must not use mid-transaction reads of `getReserves` / `getAmountOut` as a price source.
12. Terminal pool (T25, DECISIONS M6-1): once `sync()` lowers a reserve to 0 while LPs remain, the Pool can never trade again through the current interface, and the reserves backing the 1,000 locked LP stay unredeemable.
13. Price manipulation and oracles (T26): the spot price can be moved within a single transaction (e.g. with a flash loan); the Pool provides no oracle (no TWAP) and none of its views may be used as a price feed or collateral oracle.
14. Factory recipient (T11, DECISIONS M7-1): every Pool of a Factory shares one immutable `surplusRecipient`. It must be checked before deployment to be able to receive and withdraw the expected tokens; if it is wrong, only a new Factory helps, and Pools of the old Factory are not migrated.
15. Factory token check (T17, DECISIONS M7-2): the code-existence check runs only in the Factory, does not prove ERC-20 compliance, and prevents creating a pair in advance for a token that is not deployed yet.
16. Terminal pairs (T25, DECISIONS M7-5): a pair whose Pool has become terminal can never be re-created in the same Factory.
17. Deficit recovery needs an external `sync()` call (T9): until someone pays gas to call it, add / remove / swap revert `ReserveDeficit`. Whether a better mechanism exists is an open question for the optimisation stage (DECISIONS §8).
18. Exit is not guaranteed for every token (T27, §7.4): a successful deposit is not evidence that withdrawal will succeed. `min_iNet = 0` only guarantees that MIN-NET is never the reason a withdrawal fails.
19. One failing token can make the other, healthy token's assets unredeemable, because withdrawal transfers both tokens atomically and the deficit check reads both balances (§7.6).
20. No approved recovery path exists for a token that stops paying out or whose `balanceOf` reverts; the Pool is ownerless, and the Factory cannot re-create the pair (§7.5, DECISIONS M7-5).
21. Unmatched deposit contributions enter the reserves (X1): they are shared by all LPs at execution time, including just-in-time LPs, and weaken one layer of the first-depositor defence (T4, T29).

## 7. M8 token-behaviour and exit-safety policy

**Status:** design approved 2026-11-21 (DECISIONS §15); implemented in M8 commits 2–4 and tested in M8 commits 5a–5f and the F1 follow-up tests (TEST_MATRIX §3.2, §3.4); **M8 accepted 2026-11-23**. The in-call balance invariant (DECISIONS M8-11) is `APPROVED` and implemented (commit 4). Tags: [proven] mathematical argument; [assumption] about token behaviour; [needs tests] not yet shown by executed tests.

### 7.1 Risk levels (student classification, 2026-11-21)

| Level | Behaviour | Handling |
|---|---|---|
| Low | Fixed transfer tax; the Pool can measure every transfer, and the Pool is debited exactly what it sends | Supported: deposits and swaps account only measured net; outputs are judged by MIN-NET |
| Medium | Tax changes dynamically or randomly | Explicit revert and disclosed exit risk. Precision: an **inclusive** tax of any rate does **not** trigger A8, because A8 compares the Pool's own debit, not the recipient's credit. It can make MIN-NET revert, or take value through the tax. A change becomes **high** risk as soon as it alters the Pool-side debit (an extra sender-side charge, or a debit below the amount): then A8 rejects every outbound transfer of that token |
| High | The token refuses outbound transfers (pause, blacklisting the Pool, outbound over-debit) or `balanceOf()` reverts | Treated as able to make the Pool unusable for a long time or permanently (T27); no approved recovery (§7.5) |

### 7.2 Support scope (A8 unchanged)

Categories: **1** supported; **2** conditionally supported, may revert; **3** unsupported; **4** may trap liquidity.

| Token behaviour | Inbound (deposit, swap in) | Outbound (withdraw, swap out, skim) | Category |
|---|---|---|---|
| Standard ERC-20 | ✓ | ✓ | 1 |
| Inclusive FOT, fixed rate (known or unknown to the Pool) | ✓ measured net; the unmatched part is bounded by `maxExcess` | ✓ A8 passes; the recipient receives less, judged by MIN-NET | 1 |
| Inclusive FOT, random or dynamic rate | ✓, may revert on the user's bounds | A8 passes; MIN-NET may revert; value can be taken by the tax (up to 100%) | 2 |
| Extra sender-side charge on inbound only (Pool-outbound exact) | conditional: payer's net debit `≤ maxDebit` | ✓ | 2 |
| Extra charge on Pool-outbound (exclusive FOT) | ✓ — **deposits succeed** | every outbound transfer reverts (A8) | 3 + 4 |
| Direction- or address-dependent, owner-settable, upgradeable, pausable or blacklisting tokens | measured | may switch to the row above at any time | 4 |
| Rebasing or reflection | rebase down → deficit (T9); rebase up or reflection → surplus, which goes to `skim()` and so to `surplusRecipient`, **not to the LPs** (M10 disclosure; Gate R kept). This also applies to yield that accrues to the holder's balance | as inbound | 3 |
| Untruthful `balanceOf`, or `balanceOf` reverting | measurements meaningless | every function can revert | 3 + 4 |

### 7.3 What triggers A8

A8 reverts a Pool outbound transfer of `x` (in `removeLiquidity`, swap output, `skim`) when the Pool's own balance does not fall by exactly `x`:
- (a) the token charges the Pool extra (exclusive FOT);
- (b) the Pool is debited less than `x` while the call reports success;
- (c) the Pool's balance of that token changes for another reason during the transfer (a rebase, reflection, or a callback moving the Pool's balance).

**Applicable boundary of (b) (M10 disclosure; A8 kept, student 2026-11-23).** A8 is an equality: a token whose transfer changes the sender's balance by an amount that differs from `x` by rounding (share-based balance accounting; Lido documents a 1–2 wei corner case for stETH, not tested here) traps the Pool. Its deposits and swap inputs succeed, but each outbound transfer reverts whenever the difference occurs, so withdrawals of such a pool can fail. A one-sided check (rejecting only an over-debit) would admit these tokens, but it would also accept a token that reports success while moving less than `x` out of the Pool: the reserve would still fall by `x`, the undelivered part would stay in the Pool as surplus (to `surplusRecipient` through `skim()`), and with `min = 0` a withdrawing LP would burn shares for less than their claim. Such tokens are unsupported (rebasing, category 3); A8 stays.

A8 is **not** triggered by an inclusive tax (the recipient side is MIN-NET's job), or by a token transfer that reverts (that revert simply propagates). Deposits contain no outbound transfer in the M8 design, so they never trigger A8.

### 7.4 Can a depositor know that exit may fail later?

**[proven by counterexample] No inbound-only check can guarantee future outbound compatibility.**
- A token can debit the payer exactly 100 and credit the Pool exactly 100 on deposit, then enable an outbound over-debit later.
- Every withdrawal then fails A8, although every check at deposit time passed.
- The payer-debit bound (T28) protects what the user pays. It is not an exit guarantee.

Policy:
- Exit is guaranteed only if, **at exit time**, all of the following hold:
  - both tokens' `balanceOf` returns truthfully and does not revert;
  - a Pool `transfer` succeeds and debits the Pool exactly the amount sent;
  - the Pool is not paused or blacklisted;
  - there is no deficit, or `sync()` has been called;
  - the position is large enough that no withdrawn amount rounds to 0 (`InsufficientLiquidityBurned`);
  - the 1,000 locked LP is never redeemable.
- Depositors (and any UI) must treat tokens whose transfer logic can change as carrying exit risk: upgradeable proxies, owner-settable fees, pause, blacklist. The Pool gives no on-chain warning.

### 7.5 Approved recovery paths if a token's behaviour changes

| Situation | Recovery |
|---|---|
| Deficit (balance below reserve) | `sync()` (anyone; LPs bear the loss), then the terminal-pool rules if a reserve reaches 0 (M6-1, M4-3r) |
| Token stops paying out, over-debits the Pool, or `balanceOf` reverts | **None approved.** The Pool is ownerless (D10) and has no sweep; the Factory cannot re-create the pair (M7-5). Recovery depends entirely on the token reverting its behaviour |
| Extension candidate E1, "forfeit one side on exit" (burn shares, receive only the healthy token, leave the other side to the remaining LPs) | Not approved; would change D7 and the ABI. It would not help when `balanceOf` reverts, because the entry checks read both balances |

### 7.6 Can a failing token make the healthy token unredeemable?

**Yes.**
- `removeLiquidity` transfers both tokens in one atomic call, and the deficit entry check reads both balances. So one token whose outbound transfer fails (A8 or revert) blocks the withdrawal of the healthy token as well.
- If the broken token X fails only outbound, swaps X → Y still work: inbound X is accepted, outbound Y is healthy. Traders can then sell X into the Pool for Y while LPs cannot withdraw. The LPs' Y reserve is progressively converted into X that nobody can withdraw.
- If `balanceOf(X)` reverts, add, remove, swap, `sync` and `skim` all revert.
- **New deposits are still accepted while exit is impossible.** In the mode "X can still be transferred in, but the Pool cannot transfer it out", `addLiquidity` pulls X with `transferFrom` and succeeds. New LPs therefore deposit into a Pool they cannot leave. The inbound-only policy of DECISIONS M8-12 cannot detect this.
- Model illustration (Python model, not the Solidity code): Pool (1,000,000 X, 1,000,000 Y), ten swaps of 100,000 X → Y at 30 bps. The Y reserve falls to 501,008: 498,992 Y are paid out, and the LPs hold 2,000,000 X that nobody can withdraw.

**Limitation test required (M8, TEST_MATRIX X06; not only documentation):**
1. Build a normal Pool.
2. Switch X to one of three modes:
   - (A) the Pool's outbound `transfer` reverts, inbound `transferFrom` still works;
   - (B) every transfer reverts;
   - (C) `balanceOf` reverts.
3. Show that `removeLiquidity` fails with the exact error and full state rollback.
4. In mode (A): X → Y swaps succeed, Y → X swaps fail, and new deposits succeed. In mode (B): swaps in both directions and deposits fail. In mode (C): every function fails.
5. Repeat X → Y swaps and record the Y reserve and the LPs' redeemable value per share. This shows the economic risk to LPs.
6. Switch X back to normal and show that exit works again. Recovery depends only on the token.
