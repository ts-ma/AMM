# THREAT MODEL — AMM Security Threat Model

**Last updated:** 2026-11-19

**Status:** Partially implemented. Implemented and tested so far (M2–M6): constructor checks (T11); `nonReentrant` on `addLiquidity`, `removeLiquidity` and `swapExactInput` with the M5 attack suite — same-function and cross-function, bubbling and caught re-entry (T1); measured input on deposits and swaps (T2, T5 — taxed inputs fully tested only in M8); exact swap formula with the fee-adjusted inequality, enforced by tests only (T8, A9 = DECISIONS M5-9); the lock and LP-SELF supply controls (T10, T24); MIN-NET on withdrawal and swap (T7); read-only reentrancy demonstrated, no view guard (T13); recipient checks on add, remove and swap (T14); `minNetAmountOut` and deadline on swap (T18); full rollback on failing/false-returning tokens, no-return tokens accepted (T20); ownerless ABI verified statically and at run time (T21); A8 on withdrawal, swap and skim (T23). M6: downward-only `sync()` (T3), deficit entry check on add, remove and swap (T9), per-token `skim()` to the immutable recipient with A8 (T12, T15, T16 Pool side), terminal-pool rules after a zero reserve (T25), `nonReentrant` on `sync` / `skim` with the bubbling / caught suite (T1). Still open: Factory (M7), Tier 1 taxed tokens (M8). **All other mitigations below are unimplemented and untested.** A mitigation reduces risk; it does not mean the attack is eliminated. Passing tests is not a proof of security.

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
- **Tier 1:** exactly the U8 model (inclusive, `floor(g × taxBps / 10000)`, fixed and address-independent rate, truthful `balanceOf`). No other taxed token is claimed compatible.
- `SafeERC20` handles missing/`false` return values; it does not guarantee a token's economics.
- No token can tell the Pool who made an unsolicited transfer.

## 4. Threats

| ID | Threat | Surface | Mitigation (design) | Tests | Residual risk |
|---|---|---|---|---|---|
| T1 | Reentrancy via token or recipient code | add, remove, swap, sync, skim | `nonReentrant` on every state-changing function; outbound transfers after effects; attacker mocks for cross-function reentry (bubbling, caught + correct transfer, caught + faulty transfer; DECISIONS M5-6, M6-5) | W07, S08, X01 (incl. M6 extension), L24 | Inbound `safeTransferFrom` precedes reserve update by necessity (ARCHITECTURE §7); view functions unguarded (T13) |
| T2 | Earlier surplus counted as the current caller's input | add, swap | In-call balance snapshots (§5.2), each taken immediately before its own transfer (DECISIONS M6-8); BI-2 | R07, S07, B01, B03, B08, L13 | Relies on truthful `balanceOf` |
| T3 | Price manipulation or share-value inflation via direct transfer + `sync()` | sync | Gate R=(b): `sync()` never absorbs surplus (BI-4) | R05, R10, B05 | In a deficit, `sync()` still changes reserves (T9) |
| T4 | First-depositor inflation (tiny first position plus large direct transfer to dilute later LPs) | first/later mint | 1,000 LP locked; direct transfers never enter reserves (T3); `shares > 0` and `minShares` | L01, L02, L13 | Layered mitigations, not a formal proof; very small deposits are rejected |
| T5 | Inbound tax over-credited | add, swap | Account only measured net | S05, L05 | Only the U8 model |
| T6 | Adaptive deposit over-debits or mints unfair shares | add (Tier 1) | L-α seven conditions; `[T, T+1]` check; wrong hint reverts | L05, L09–L12, Z05 | Rounding dust, not zero; Pool cannot observe the sender's debit directly (relies on U8 inclusive condition) |
| T7 | Outbound tax leaves the recipient short | swap, remove | MIN-NET: compare the recipient's actual increase with the user minimum (BI-6) | S04, S06, W04, W05, B07 | Recipient balance measurements are unreliable for special recipients (e.g. the token's own tax collector); unsupported |
| T8 | Fee missing or miscomputed | swap | Exact formula (§6.4); fee-adjusted inequality with proof (§6.5); five reference cases incl. tightness (`out + 1` fails); exact-formula fuzz at Pool level | S02, S10, S11, S14, S15, Z01 | Tests sample behaviour; no on-chain assertion (A9 = tests only, DECISIONS M5-9): without A9 the swap lacks one additional on-chain invariant check, so certain implementation errors that no other check detects might not be stopped at run time by this invariant |
| T9 | Deficit (`balance < reserve`) | add, remove, swap | Entry check `ReserveDeficit()` reverts those three before any effect or transfer (DECISIONS M6-2); `sync()` lowers reserves and emits `ReserveSynced` (U4) | R08, R17, B05 | Should not occur with supported tokens; if it does, LPs bear the loss once `sync()` is called. Tested: deficits present at entry, in either or both tokens, for every operation. Not covered by the entry check: a deficit created during the call by an unsupported token (e.g. a hook that reduces the Pool's balance of the other token); A8, `[T, T+1]` and MIN-NET check only the transfer they surround, so such a deficit is not proven to be detected in that call and is first rejected by the next call's entry check (until `sync()`). `getAmountOut` has no deficit check and may quote from stale reserves while swaps revert (`test_R08_quoteDoesNotCheckDeficit`) |
| T10 | Locked LP moved or burned | LP ERC-20 | Lock held by `address(this)`; `_update` rejects any movement or burn from the Pool and any mint/burn outside `nonReentrant` (DECISIONS M3-2); code-review rules (§7.9); BI-7 | P05–P08, P10, I1 | On-chain checks plus tests, not a formal proof |
| T11 | Wrong `surplusRecipient` at deployment | deployment | Constructor rejects `address(0)`, `token0`, `token1`, `address(this)` | K02, K04 | Catches only those four values; any other wrong address is undetectable and immutable — redeploy and migrate |
| T12 | `surplusRecipient` keeps mistaken transfers | skim | None on-chain | — | Entirely off-chain trust; must be disclosed |
| T13 | Read-only reentrancy: a callback reads `getReserves()` / `getAmountOut()` mid-call | view functions | No `nonReentrantView` (DECISIONS M5-5). Effects before outbound transfers; at every callback point reserves and LP supply form a consistent snapshot (pre-call during inbound pulls, post-effects during outbound pushes) | X05 | Mid-call reads during an inbound pull return pre-call values although the Pool's balance may already have changed; no in-scope consumer relies on them. **Re-evaluate T13** if any of these changes: hook/callback tokens become supported; an external protocol is expected to use `getReserves` / `getAmountOut` as a price source or collateral oracle; the effects-before-interactions order of any function changes; new view functions derive values from balances rather than recorded reserves |
| T14 | Recipient set to the Pool, manufacturing surplus | swap, remove, add | Reject `recipient ∈ {address(0), address(this)}` (U7) | S12, W08, L14 | — |
| T15 | `skim()` transfer fails (e.g. recipient blacklisted by a token) | skim | `skim()` is independent of other functions | R12 (tested: add, remove and both swaps still work) | The whole `skim()` call reverts, so **neither** token's surplus is sent while one transfer keeps failing; blacklisting tokens are unsupported |
| T16 | Taxed token in `skim()` | skim | Pool accounting ignores the recipient's receipt; A8 checks the Pool side | R09 (M8); short delivery shown not rejected in `test_X01_M6_skimCallback_caughtShortDeliveryNotChecked` | Recipient receives less than the surplus |
| T17 | Duplicate pairs, fake or undeployed token addresses | Factory | Sorting, duplicate rejection; code-existence check `PENDING` | F01–F03 | A deployed token can still be malicious; code existence proves nothing about safety |
| T18 | Sandwich / price manipulation | swap | `minNetAmountOut`, deadline | S04 | Limits the user's loss; does not prevent MEV; no oracle |
| T19 | Overflow or rounding error | all maths | Checked arithmetic; `mulDiv` where needed; per-formula ranges (§6.6); boundary and fuzz tests | Z01–Z06 | Ranges are hand-derived sufficient conditions, confirmed only by tests; outside them a call may revert |
| T20 | Token transfer fails, returns `false`, or returns nothing | external calls | `SafeERC20`; atomic rollback | L06, S09, X02 | — |
| T21 | Unauthorised admin action | all | No privileged function exists; compiled ABI equals the approved list, no fallback/receive; admin-style and unknown selectors fail at run time (DECISIONS M5-7) | X03 | Deployed contracts cannot be paused or repaired |
| T22 | LP allowance misuse | LP ERC-20 | Standard OZ behaviour | P02 | The standard ERC-20 approve race remains |
| T23 | Token over-debits the Pool on outbound transfer (exclusive FOT or similar) | remove, swap, skim | A8: Pool balance must fall by exactly the amount sent, else revert (BI-5) | B06, X04 | Detects this one behaviour; does not make such tokens usable |
| T24 | User sends LP tokens to the Pool address by mistake | LP ERC-20 | LP-SELF (ii): LP transfers to the Pool revert, including zero-value transfers | P06, P09 | LP sent to other wrong addresses is still unrecoverable (standard ERC-20 behaviour) |
| T25 | Zero-reserve state: after `sync()` lowers a reserve to 0 while `totalSupply > 0`, later deposits could hit division by zero and proportional withdrawals could revert (`amount_i == 0`), trapping the LPs' remaining other-token assets | add, remove, sync | Terminal-pool rule (DECISIONS M6-1, M4-3r, ADR-023): deposits and swaps revert `InsufficientLiquidity`; withdrawal pays the remaining non-zero reserve proportionally, with MIN-NET on both sides. Implemented and tested in M6 (zero reserve in either token, both zero, with surplus, last LP exit) | R14–R22 | Arises only with tokens outside the supported model. A terminal pool cannot trade again through the current interface; the reserves backing the 1,000 locked LP can never be redeemed (recovery = extension candidate, DECISIONS §8) |

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
5. Adaptive deposits leave small rounding dust that benefits all LPs; it is not zero.
6. No MEV protection, no oracle, no pause. Deadlines use `block.timestamp`, which a block producer can shift by a few seconds (`forge lint` `block-timestamp`); a deadline bounds staleness, not exact timing.
7. Arithmetic ranges are hand-derived sufficient conditions; inputs beyond them may make legitimate calls revert.
8. A failing transfer of one token blocks `skim()` for both tokens.
9. `LiquidityAdded` / `LiquidityRemoved` / `Swap` are emitted after the token calls, because the Pool must first measure balances (`forge lint` `reentrancy-events`). All three functions are `nonReentrant`, so a token callback cannot interleave another Pool event; off-chain consumers should still treat the return values and balances as authoritative.
10. Deficits (T9): the M6 entry check stops add, remove and swap when a deficit exists at entry (tested for each token and both); the LPs bear the loss once `sync()` is called, and `getAmountOut` can quote from stale reserves during a deficit. Each transfer is measured from its own fresh snapshot, which costs about 860 gas per call more than reusing the entry reading (DECISIONS M6-8).
11. Read-only reentrancy (T13): view functions are unguarded by design (DECISIONS M5-5); integrators must not use mid-transaction reads of `getReserves` / `getAmountOut` as a price source.
12. Terminal pool (T25, DECISIONS M6-1): once `sync()` lowers a reserve to 0 while LPs remain, the Pool can never trade again through the current interface, and the reserves backing the 1,000 locked LP stay unredeemable.
