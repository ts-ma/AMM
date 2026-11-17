# THREAT MODEL — AMM Security Threat Model

**Last updated:** 2026-11-17

**Status:** Pre-implementation. **Every mitigation below is unimplemented and untested.** A mitigation reduces risk; it does not mean the attack is eliminated. Passing tests is not a proof of security.

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
| T1 | Reentrancy via token or recipient code | add, remove, swap, sync, skim | `nonReentrant` on every state-changing function; outbound transfers after effects; attacker mocks for cross-function reentry | W07, S08, X01 | Inbound `safeTransferFrom` precedes reserve update by necessity (ARCHITECTURE §7); view functions unguarded (T13) |
| T2 | Earlier surplus counted as the current caller's input | add, swap | In-call balance snapshots (§5.2); BI-2 | R07, S07, B01, B03 | Relies on truthful `balanceOf` |
| T3 | Price manipulation or share-value inflation via direct transfer + `sync()` | sync | Gate R=(b): `sync()` never absorbs surplus (BI-4) | R05, R10, B05 | In a deficit, `sync()` still changes reserves (T9) |
| T4 | First-depositor inflation (tiny first position plus large direct transfer to dilute later LPs) | first/later mint | 1,000 LP locked; direct transfers never enter reserves (T3); `shares > 0` and `minShares` | L01, L02, L13 | Layered mitigations, not a formal proof; very small deposits are rejected |
| T5 | Inbound tax over-credited | add, swap | Account only measured net | S05, L05 | Only the U8 model |
| T6 | Adaptive deposit over-debits or mints unfair shares | add (Tier 1) | L-α seven conditions; `[T, T+1]` check; wrong hint reverts | L05, L09–L12, Z05 | Rounding dust, not zero; Pool cannot observe the sender's debit directly (relies on U8 inclusive condition) |
| T7 | Outbound tax leaves the recipient short | swap, remove | MIN-NET: compare the recipient's actual increase with the user minimum (BI-6) | S04, S06, W04, W05, B07 | Recipient balance measurements are unreliable for special recipients (e.g. the token's own tax collector); unsupported |
| T8 | Fee missing or miscomputed | swap | Exact formula (§6.4); fee-adjusted inequality with proof (§6.5); five reference cases incl. tightness (`out + 1` fails) | S02, S10, S11, S14, S15 | Tests sample behaviour; on-chain assertion `PENDING` (A9) |
| T9 | Deficit (`balance < reserve`) | add, remove, swap | Entry check reverts those three; `sync()` lowers reserves and emits an event (U4) | R08 | Should not occur with supported tokens; if it does, LPs bear the loss |
| T10 | Locked LP moved or burned | LP ERC-20 | Lock held by `address(this)`; code-review rules forbid any Pool-side approve/transfer/burn of its own LP (§7.9); BI-7 | P05, P06, I1 | Code review plus tests, not a formal proof |
| T11 | Wrong `surplusRecipient` at deployment | deployment | Constructor rejects `address(0)`, `token0`, `token1`, `address(this)` | K02, K04 | Catches only those four values; any other wrong address is undetectable and immutable — redeploy and migrate |
| T12 | `surplusRecipient` keeps mistaken transfers | skim | None on-chain | — | Entirely off-chain trust; must be disclosed |
| T13 | Read-only reentrancy: a callback reads `getReserves()` mid-call | view functions | Effects before outbound transfers narrow the window | — | During the inbound `safeTransferFrom`, reserves are still pre-update; no dedicated guard; no in-scope consumer relies on these reads |
| T14 | Recipient set to the Pool, manufacturing surplus | swap, remove, add | Reject `recipient ∈ {address(0), address(this)}` (U7) | S12, W08, L14 | — |
| T15 | `skim()` transfer fails (e.g. recipient blacklisted by a token) | skim | `skim()` is independent of other functions | R12 | The whole `skim()` call reverts, so **neither** token's surplus is sent while one transfer keeps failing; blacklisting tokens are unsupported |
| T16 | Taxed token in `skim()` | skim | Pool accounting ignores the recipient's receipt; A8 checks the Pool side | R09 | Recipient receives less than the surplus |
| T17 | Duplicate pairs, fake or undeployed token addresses | Factory | Sorting, duplicate rejection; code-existence check `PENDING` | F01–F03 | A deployed token can still be malicious; code existence proves nothing about safety |
| T18 | Sandwich / price manipulation | swap | `minNetAmountOut`, deadline | S04 | Limits the user's loss; does not prevent MEV; no oracle |
| T19 | Overflow or rounding error | all maths | Checked arithmetic; `mulDiv` where needed; per-formula ranges (§6.6); boundary and fuzz tests | Z01–Z06 | Ranges are hand-derived sufficient conditions, confirmed only by tests; outside them a call may revert |
| T20 | Token transfer fails, returns `false`, or returns nothing | external calls | `SafeERC20`; atomic rollback | L06, S09, X02 | — |
| T21 | Unauthorised admin action | all | No privileged function exists | X03 | Deployed contracts cannot be paused or repaired |
| T22 | LP allowance misuse | LP ERC-20 | Standard OZ behaviour | P02 | The standard ERC-20 approve race remains |
| T23 | Token over-debits the Pool on outbound transfer (exclusive FOT or similar) | remove, swap, skim | A8: Pool balance must fall by exactly the amount sent, else revert (BI-5) | B06, X04 | Detects this one behaviour; does not make such tokens usable |
| T24 | User sends LP tokens to the Pool address by mistake | LP ERC-20 | LP-SELF (ii): LP transfers to the Pool revert | P06 | LP sent to other wrong addresses is still unrecoverable (standard ERC-20 behaviour) |

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
6. No MEV protection, no oracle, no pause.
7. Arithmetic ranges are hand-derived sufficient conditions; inputs beyond them may make legitimate calls revert.
8. A failing transfer of one token blocks `skim()` for both tokens.
