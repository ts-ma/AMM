# TEST MATRIX — Foundry Test Plan

**Last updated:** 2026-11-19

**Status:** Rows marked `PASSED` (M1–M4) are implemented and were run. Everything else is a plan, not a record of passing tests. "Maths level" means the library function was tested; the Pool function that uses it does not exist yet. Record a result and the test function name only after the test has actually been run.

Tests that depend on a `PROPOSED` or `PENDING` decision must not be written before that decision is approved.

**Revert assertions (DECISIONS M4-8):** every revert test asserts the exact error — selector plus arguments where the error has arguments, Panic code for panics. Bare `vm.expectRevert()` is not used. Formulas, invariants (BI-x) and function rules are in [ARCHITECTURE.md](ARCHITECTURE.md).

**Status values:** `NOT IMPLEMENTED` · `PASSED` · `FAILED` · `BLOCKED (reason)`

## 1. Mocks and basics (M1)

| ID | Description | Status |
|---|---|---|
| T01 | `MockERC20.decimals()` returns 18 and 6 for the respective mocks | `PASSED` — `test_T01_decimals` |
| T02 | `mint` updates `balanceOf` and `totalSupply` | `PASSED` — `test_T02_mintUpdatesBalanceAndSupply`, `testFuzz_T02_mint` (256 runs) |
| T03 | `transfer` succeeds; reverts on insufficient balance | `PASSED` — `test_T03_transfer`, `test_T03_transferRevertsOnInsufficientBalance` |
| T04 | `approve` + `transferFrom` succeed and reduce allowance | `PASSED` — `test_T04_approveAndTransferFrom` |
| T05 | `transferFrom` reverts on insufficient allowance | `PASSED` — `test_T05_transferFromRevertsOnInsufficientAllowance` |

File: `test/MockERC20.t.sol`; mock: `test/mocks/MockERC20.sol`. Run 2026-11-17 with the U12 configuration (§14).

## 2. Constructor (M2)

| ID | Description | Status |
|---|---|---|
| K01 | Either token zero (token0, token1 or both, any order) → `ZeroAddress`; identical → `IdenticalTokens`; unsorted → `TokensNotSorted`; fuzz: outcome matches an independent classifier | `PASSED` — `test_K01_*` (5 unit), `testFuzz_K01_K04_constructorMatchesClassifier`, `testFuzz_K01_zeroInEitherPosition` |
| K02 | `surplusRecipient == address(0)` reverts | `PASSED` — `test_K02_zeroRecipientReverts` |
| K03 | Immutables set correctly; reserves are 0; fee constants 30 / 10,000. (`totalSupply == 0` is checked in M3, when the LP ERC-20 exists.) | `PASSED` — `test_K03_initialState` (incl. `totalSupply == 0`, M3) |
| K04 | `surplusRecipient` equal to `token0`, `token1`, or the Pool's own (predicted) address each revert | `PASSED` — `test_K04_*` (3 reverts + address-prediction control), `testFuzz_K01_K04_constructorMatchesClassifier` |

## 3. Liquidity provision (M3, M4, M8)

| ID | Description | Milestone | Status |
|---|---|---|---|
| L01 | Initial: provider gets `floor(sqrt(net0 × net1)) − 1000`; Pool holds exactly 1000 LP | M3 | `PASSED` (M3) — `test_L01_initialDepositSharesAndLock` |
| L02 | Initial reverts for zero amounts and for `sqrt(net0 × net1) ≤ 1000` | M3 | `PASSED` (M3) — `test_L02_zeroAmountsRevert`, `test_L17_*` |
| L03 | Later deposit into a 1:2 Pool pulls only the optimal amounts | M4 | `PASSED` (M4) — `test_L03_workedExampleSmallUnits`, `test_L03_token0CapBinds`, `test_L03_token1CapBinds`, `test_L03_roundingDustStaysWithLPs` |
| L04 | Several LPs get shares proportional to contributions | M4 | `PASSED` (M4) — `test_L04_sharesProportionalToContributions`, `testFuzz_L04_L11_L12_laterDepositFairness` |
| L05 | U8 taxed token: measured `net_i ∈ [T_i, T_i+1]`; shares from net; worked example of ARCHITECTURE §6.2 (gross 203, net 201) | M8 | `NOT IMPLEMENTED` |
| L06 | Failed transfer / insufficient balance / insufficient allowance reverts with no state left | M4 | `PASSED` — initial path (M3, `test_L23_*`); later deposit (M4, `test_L06_*`, 4 tests) |
| L07 | First depositor sets the initial price | M3 | `PASSED` (M3) — `test_L07_firstDepositorSetsPrice` (18/6 decimals) |
| L08 | `minShares` unmet reverts; expired deadline reverts; `block.timestamp == deadline` succeeds | M4 | `PASSED` — initial path (M3, `test_L18_*`, `test_L21_deadlineBoundary`); later deposit (M4, `test_L08_*`) |
| L09 | Required gross above cap reverts | M8 | `NOT IMPLEMENTED` |
| L10a | Tax hint higher than actual reverts | M8 | `NOT IMPLEMENTED` |
| L10b | Tax hint lower than actual reverts | M8 | `NOT IMPLEMENTED` |
| L10c | Tax rate changed between quote and execution reverts | M8 | `NOT IMPLEMENTED` |
| L11 | Caller's measured debit per token ≤ its cap (unit + fuzz) | M4, M8 | Tier 0 `PASSED` (M4) — `test_L03_workedExampleSmallUnits`, `testFuzz_L04_L11_L12_laterDepositFairness`; Tier 1 `NOT IMPLEMENTED` (M8) |
| L12 | Caller's token balances never increase during `addLiquidity` (no refund path) | M4, M8 | Tier 0 `PASSED` (M4) — `testFuzz_L04_L11_L12_laterDepositFairness`; Tier 1 `NOT IMPLEMENTED` (M8) |
| L13 | Inflation scenario: after a large direct transfer by an attacker, a later LP's shares are not rounded to zero and the transfer does not enter reserves | M6 | `NOT IMPLEMENTED` |
| L14 | `recipient ∈ {address(0), Pool}` reverts | M4 | `PASSED` — initial path (M3, `test_L21_invalidRecipientReverts`); later deposit (M4, `test_L14_invalidRecipientRevertsOnLaterDeposit`, `test_L14_recipientReceivesSharesAndEvent`) |
| L15 | Initial deposit with a taxed token ignores the hints and uses measured net | M8 | `NOT IMPLEMENTED` |
| L16 | `tax_iBps ≥ 10000` reverts | M8 (initial path in M3) | Initial path `PASSED` (M3, `test_L21_L16_taxBpsBoundary`); later-deposit path `NOT IMPLEMENTED` (M8) |
| L26 | Later deposit with a U8 taxed token and hint 0: measured `net < T` → `NetAmountOutOfRange`, full rollback (DECISIONS M4-1) | M4 | `PASSED` (M4) — `test_L26_taxedToken0WithZeroHintReverts`, `test_L26_taxedToken1WithZeroHintReverts` |
| L27 | TEMPORARY: `S > 0` with any non-zero hint → `TaxedLaterDepositNotImplemented` before any transfer; initial path with non-zero hints unchanged. **M8 removes this test and the revert and adds the replacing tests** (DECISIONS M4-1) | M4 | `PASSED` (M4, temporary) — `test_L27_nonZeroHintOnLaterDepositRevertsBeforeAnyTransfer`, `test_L27_initialPathStillIgnoresHints` |

### 3.00 M4 hardening results (2026-11-19, branch `m4-hardening`)

Full suite 141/141 with default fuzz runs and with `FOUNDRY_FUZZ_RUNS=10000`; the differential fuzz alone also with 20,000 runs. Configuration per §14 (`forge config` checked). The differential oracle (independent 512-bit arithmetic, exact revert bytes, full `uint256` caps and balances, 144 hand-picked corner combinations) first exposed the L-α target Panic for caps such as `(type(uint256).max, 100)` with `r1 > r0`; it now passes against the fix. Mutation check (temporary): the fix's 7 mutants (overflow test `>` instead of `>=`, overflow branch dropped, fast path dividing by the wrong reserve on either side, middle path dropped, wrong `mulDiv` argument order, moved hint check removed) were all killed by `test/AMMPoolDeposit.t.sol`; re-inserting the pre-fix code and 3 earlier mutants were all killed by the differential test.

### 3.0 M4 results (2026-11-19)

Files: `test/AMMPoolDeposit.t.sol` (23), `test/AMMPoolWithdraw.t.sol` (20), `test/OutboundMocks.t.sol` (6, mock self-tests). Full suite 136/136 with default fuzz runs and with `FOUNDRY_FUZZ_RUNS=10000`; configuration per §14 (verified with `forge config`).

Mutation check (temporary, reverted; script outside the repository). Later deposit, 11 mutants: 10 killed; 1 equivalent under Tier 0 (`reserve += T` instead of `+= net`: the `[T, T+1]` check with a Tier 0 token forces `net == T`; distinguishable only with Tier 1 in M8). The first run also showed the token0-side lower tolerance bound surviving, because L26 happened to tax token1 only; L26 was split into token0/token1 variants, which kill it. Withdrawal, 13 mutants, all killed: A8 removed; MIN-NET on `amount` instead of net; MIN-NET off by one; return `amount` instead of measured net; amounts rounded up; zero-amount check removed; supply read after the burn; `mulDiv` before the burn; reserve not decreased; `shares == 0` check removed; deadline `>=`; Pool-recipient check removed (caught by A8 as `OutboundTransferMismatch` too, but the exact-error test detects the wrong error); `min1Net` swapped. Not killable in M4: the **upper** `[T, T+1]` bound (needs a token that credits more than sent; covered by L10a in M8).

### 3.1 M3 initial-deposit additions (DECISIONS M3-7)

M3 results (2026-11-18): `test/AMMPoolLiquidity.t.sol` 37 tests passed (default runs and `FOUNDRY_FUZZ_RUNS=10000`); full suite 88/88. Mutation check (temporary, reverted): removing lock immobility, LP-SELF, the once-only lock condition, or the guard check; `<` instead of `<=` for the threshold; requested instead of measured amount; off-by-one `minShares` and deadline — each made at least one test fail.

| ID | Description | Status |
|---|---|---|
| L17 | `gross = 999`, `1000` revert `InsufficientInitialLiquidity`; `gross = 1001` succeeds with 1 provider share | `PASSED` — `test_L17_gross999Reverts`, `test_L17_gross1000Reverts`, `test_L17_gross1001SucceedsWithOneShare`, `test_L17_asymmetricGross1001` |
| L18 | `minShares == shares` succeeds; `minShares == shares + 1` reverts `InsufficientShares` | `PASSED` — `test_L18_minSharesEqualSucceeds`, `test_L18_minSharesPlusOneReverts` |
| L19 | U8 taxed token, initial deposit: shares and reserves use the measured balance difference, not the requested amount; different tax hints give identical results | `PASSED` — `test_L19_*`, `testFuzz_L19_anyValidHintGivesSameShares` |
| L20 | Pre-existing surplus in both tokens: each measured net equals the amount transferred in this call; final reserves equal the nets; both surpluses unchanged (BI-2, initial path of B01) | `PASSED` — `test_L20_preExistingSurplusIsNotAttributed` |
| L21 | Initial path argument checks: deadline (`==` succeeds, `+1` reverts), recipient `0`/Pool, zero amounts, `tax ≥ 10000` | `PASSED` — `test_L21_deadlineBoundary`, `test_L21_invalidRecipientReverts`, `test_L21_L16_taxBpsBoundary` |
| L22 | `S > 0` reverts `LaterDepositNotImplemented` (temporary; replaced in M4) | `PASSED` in M3 — `test_L22_laterDepositRevertsUntilM4` (temporary; removed in M4 together with the error, replaced by L03) |
| L23 | Failing token1 (reverting `transferFrom`, `false` return, reverting `balanceOf`) rolls back the whole call, including token0's completed transfer | `PASSED` — `test_L23_*` (4 tests) |
| L24 | Reentrancy smoke test: a token callback re-entering `addLiquidity` reverts `ReentrancyGuardReentrantCall` (full attacks in M5) | `PASSED` (smoke) — `test_L24_tokenCallbackCannotReenterAddLiquidity` |
| L25 | `LiquidityAdded` and the two `Transfer` mint events carry the expected fields | `PASSED` — `test_L25_events` |

## 4. Withdrawal (M4, M5, M8)

| ID | Description | Milestone | Status |
|---|---|---|---|
| W01 | Proportional redemption matches ARCHITECTURE §6.3 | M4 | `PASSED` (M4) — `test_W01_proportionalRedemption`, `testFuzz_W01_redemptionMatchesFormula` |
| W02 | Only the caller's own shares are burned; a transferee can redeem transferred LP | M4 | `PASSED` (M4) — `test_W02_onlyCallersSharesBurned` |
| W03 | Zero shares, shares above balance, or a zero output reverts | M4 | `PASSED` (M4) — `test_W03_zeroSharesReverts`, `test_W10_classA_*`, `test_Z07_zeroOutputBoundary` |
| W04 | MIN-NET: recipient receiving exactly `min_iNet` succeeds; one unit less reverts | M4 | `PASSED` (M4) — `test_W04_minNetBoundaryToken0`, `test_W04_minNetBoundaryToken1` |
| W05 | Taxed output: minima judged on recipient's actual receipt; LP burned, reserve decrease, event `amount_i`, return `net_i` and recipient balance change all checked (DECISIONS M4-5, moved from M8) | M4 | `PASSED` (M4) — `test_W05_taxedToken0Output`, `test_W05_taxedToken1Output` |
| W06 | After the last redeemable LP exits, the Pool still holds exactly 1000 LP and reserves > 0 | M4 | `PASSED` (M4) — `test_W06_lastLPExitsLockRemains` (also: a new deposit afterwards succeeds) |
| W07 | Reentrancy during withdrawal is blocked | M5 | `NOT IMPLEMENTED` |
| W08 | `recipient ∈ {address(0), Pool}` reverts | M4 | `PASSED` (M4) — `test_W08_invalidRecipientReverts`, `test_W08_deadlineBoundary`, `test_W08_checkOrder` |
| W09 | Atomicity: token1's outbound transfer fails (revert, `false`, over-debit) after token0 was sent → whole call reverts; caller LP, `totalSupply`, reserves and all token balances (incl. token0 at Pool and recipient) unchanged (DECISIONS M4-4) | M4 | `PASSED` (M4) — `test_W09_token1TransferRevertRollsBackToken0`, `test_W09_token1ReturnsFalseRollsBackToken0`, `test_W10_classB_W09_overDebitToken1RevertsAndRollsBackToken0` |
| W10 | Failure classes distinguished by exact error: insufficient LP before withdrawal (`ERC20InsufficientBalance`, incl. `shares = type(uint256).max` and `shares = S`); Pool-side anomaly after transfer (`OutboundTransferMismatch`); recipient shortfall (`InsufficientNetReceived`) (DECISIONS M4-3) | M4 | `PASSED` (M4) — `test_W10_classA_insufficientLPBeforeWithdrawal`, `test_W10_classB_*` (2), class C in `test_W04_*`, `test_W05_*` |
| W11 | Lock untouched: after every successful withdrawal the Pool holds exactly 1000 LP; no withdrawal path burns Pool-held LP | M4 | `PASSED` (M4) — asserted in every successful-withdrawal test; `test_W11_poolHeldLPCannotBeRedeemed` (Pool as `msg.sender` → `LockedLiquidity`) |

## 5. Swap (M5, M6, M8)

| ID | Description | Milestone | Status |
|---|---|---|---|
| S01 | Swaps work in both directions | M5 | `NOT IMPLEMENTED` |
| S02 | Reference case 1: `1,000,000 / 1,000,000`, `a = 10,000` → `out = 9,871` | M5 | `PASSED` at maths level (`AMMMath`, M2) — `test_S02_referenceCase1`; Pool swap: `NOT IMPLEMENTED` (M5) |
| S03 | `amountIn = 0` and zero reserves revert; floored `out = 0` (reference case 3): `AMMMath` returns 0 but `swapExactInput` must revert `InsufficientOutputAmount` (DECISIONS M2-5r) | M5 | Maths level `PASSED` after M2-5r (zero input/reserves revert; case 3 returns 0, `test_S03_*`); Pool swap revert: `NOT IMPLEMENTED` (M5) |
| S04 | MIN-NET: `minNetAmountOut = out` succeeds, `out + 1` reverts; expired deadline reverts | M5 | `NOT IMPLEMENTED` |
| S05 | Taxed input: pricing and accounting use measured net | M8 | `NOT IMPLEMENTED` |
| S06 | Taxed output: minimum judged on recipient's actual receipt (e.g. min 100, receives 99 → revert) | M8 | `NOT IMPLEMENTED` |
| S07 | Pre-existing surplus is not counted as input and is unchanged after the swap | M6 | `NOT IMPLEMENTED` |
| S08 | Reentrancy during swap is blocked | M5 | `NOT IMPLEMENTED` |
| S09 | A failed swap leaves no state change | M5 | `NOT IMPLEMENTED` |
| S10 | 0-bps reference (9,900) vs. 30-bps result (9,871); the difference remains in reserves | M5 | `NOT IMPLEMENTED` |
| S11 | Fee-adjusted inequality holds after every successful swap (unit + fuzz in `[1, 2^112]`) | M5 | `PASSED` at maths level (`AMMMath`, M2) — fuzz class A and classifier fuzz (512-bit check); per-swap: `NOT IMPLEMENTED` (M5) |
| S12 | `recipient ∈ {address(0), Pool}` reverts; `tokenIn` outside the pair reverts | M5 | `NOT IMPLEMENTED` |
| S13 | After several swaps, redeeming all LP returns a larger `amount0 × amount1` than deposited (fees accrue to LPs) | M5 | `NOT IMPLEMENTED` |
| S14 | Reference cases 2, 4 and 5 (499,248; 1,992,013; 498,251,621,566,649,025) | M5 | `PASSED` at maths level (`AMMMath`, M2) — `test_S14_referenceCase2/4/5`; Pool swap: `NOT IMPLEMENTED` (M5) |
| S15 | Implementation output equals the reference formula exactly (fuzz); `out + 1` violates the inequality for reference cases | M5 | `PASSED` at maths level (`AMMMath`, M2) — exact floor and `out + 1` tightness for reference cases and fuzz; Pool swap: `NOT IMPLEMENTED` (M5) |

## 6. Reserves, `sync()`, `skim()` (M2, M6, M8)

v0.3's R05, R06 and R10 tested the `sync`/`skim` race. That race no longer exists under Gate R=(b), so they are redefined.

| ID | Description | Milestone | Status |
|---|---|---|---|
| R01 | `getReserves()` returns recorded reserves; unchanged by a direct transfer | M2 | `PASSED` — `test_R01_directTransferDoesNotChangeReserves` (M2), `test_R01_directTransferAfterDepositDoesNotChangeReserves` (M3) |
| R02 | Any address can call `sync()` | M6 | `NOT IMPLEMENTED` |
| R03 | `skim()` sends all surplus to `surplusRecipient`; reserves and price unchanged | M6 | `NOT IMPLEMENTED` |
| R04 | `skim()` takes no recipient parameter; caller's balance does not increase | M6 | `NOT IMPLEMENTED` |
| R05 | `sync()` with surplus leaves reserves and surplus unchanged | M6 | `NOT IMPLEMENTED` |
| R06 | Direct transfer → `skim()` → `sync()`: surplus reaches the recipient; `sync()` is a no-op | M6 | `NOT IMPLEMENTED` |
| R07 | Historical surplus is not counted as input to later add or swap | M6 | `NOT IMPLEMENTED` |
| R08 | Deficit: add, remove and swap revert; `sync()` lowers reserves and emits an event; operations resume afterwards | M6 | `NOT IMPLEMENTED` |
| R09 | Taxed token: `skim()` lowers the Pool balance by exactly the surplus; reserves unchanged | M8 | `NOT IMPLEMENTED` |
| R10 | Order independence: transfer → `sync()` → `skim()` and transfer → `skim()` → `sync()` reach the same final state | M6 | `NOT IMPLEMENTED` |
| R11 | `skim()` without surplus and `sync()` without deficit return normally and change nothing | M6 | `NOT IMPLEMENTED` |
| R12 | A failing `skim()` transfer reverts `skim()` only; swap, add and remove still work | M6 | `NOT IMPLEMENTED` |
| R13 | A2: token1 in deficit and token0 with surplus → `skim()` sends token0's surplus and leaves token1 untouched | M6 | `NOT IMPLEMENTED` |

| R14 | `sync()` lowers one reserve to 0 while `totalSupply > 0` (DECISIONS M4-6) | M6 | `NOT IMPLEMENTED` |
| R15 | After R14, later deposits never fail with an unexpected division-by-zero Panic; behaviour follows the zero-reserve recovery decision (`PENDING`, M6) | M6 | `NOT IMPLEMENTED` |
| R16 | After R14, withdrawal / recovery of the LPs' remaining assets follows a defined rule (`PENDING`, M6) | M6 | `NOT IMPLEMENTED` |
| R17 | Transitions between deficit, surplus and normal balance states (each token independently) reach the specified state | M6 | `NOT IMPLEMENTED` |

R08, R13 and R14–R17 need a test-only mock token whose Pool balance can be reduced.

## 7. Balance invariants per call (M4–M8)

Each test records `balance_i` and `reserve_i` for both tokens before and after one call.

| ID | Invariant | Description | Milestone | Status |
|---|---|---|---|---|
| B01 | BI-2 | `addLiquidity` with pre-existing surplus leaves both surpluses unchanged | M4 (surplus setup in M6) | `PASSED` — initial path (M3, `test_L20_*`); later deposit (M4, `test_B01_laterDepositLeavesSurplusUnchanged`, surplus created by direct transfer) |
| B02 | BI-2 | `removeLiquidity` leaves both surpluses unchanged | M4 | `PASSED` (M4) — `test_B02_withdrawalLeavesSurplusUnchanged` |
| B03 | BI-2 | `swapExactInput` leaves both surpluses unchanged | M5 | `NOT IMPLEMENTED` |
| B04 | BI-3 | After `skim()`, every token that had surplus has `balance == reserve`; reserves unchanged | M6 | `NOT IMPLEMENTED` |
| B05 | BI-4 | After `sync()`, `reserve_i = min(old reserve_i, balance_i)`; no reserve increased; balances unchanged | M6 | `NOT IMPLEMENTED` |
| B06 | BI-5 | Pool balance falls by exactly the amount sent in remove, swap and skim; negative case with `MockOverDebitERC20` (moved forward from X04, DECISIONS M4-4) | M4–M6 | Remove `PASSED` (M4) — `test_W01_proportionalRedemption`, `test_W05_*`, `test_W10_classB_*`; swap (M5), skim (M6) `NOT IMPLEMENTED` |
| B07 | BI-6 | Recipient's actual increase ≥ user minimum in remove and swap; boundary at exactly the minimum | M4, M5 | Remove `PASSED` (M4) — `test_W04_*`, `test_W05_*`; swap `NOT IMPLEMENTED` (M5) |

## 8. LP ERC-20 and lock (M3)

| ID | Description | Dependency | Status |
|---|---|---|---|
| P01 | LP `transfer` moves ownership; `totalSupply` unchanged | — | `PASSED` — `test_P01_transferMovesOwnership`, `test_P01_metadata` |
| P02 | `approve` / `transferFrom` / allowance follow the standard | — | `PASSED` — `test_P02_approveTransferFromAllowance` |
| P03 | `totalSupply` = minted − burned, including the locked 1000 | — | `PASSED` — mint (M3, `test_L01_initialDepositSharesAndLock`, `testFuzz_P10_*`); burn (M4, `test_W01_*`, `test_W06_lastLPExitsLockRemains`) |
| P04 | No external account can mint or burn LP directly | — | `PASSED` — `test_P04_noExternalMintOrBurn` |
| P05 | Pool's own LP balance is exactly 1000 after the first deposit and no sequence of calls changes it | — | `PASSED` (M3 operations; full sequences in M10 I1) — `test_P05_*`, `testFuzz_P10_*` |
| P06 | LP-SELF: `transfer(pool, x)` and `transferFrom(…, pool, x)` revert `LPTransferToPool`, including `x = 0`; the initial lock mint still succeeds | — | `PASSED` — `test_P06_transferToPoolReverts`, `test_P06_transferFromToPoolReverts` |
| P07 | Pool-held LP cannot move: `transfer`/`transferFrom` from the Pool revert `LockedLiquidity` (DECISIONS M3-2) | — | `PASSED` — `test_P07_poolHeldLPCannotMove` |
| P08 | Mint or burn outside a `nonReentrant` function reverts `SupplyChangeOutsideGuard` (test-only harness) | — | `PASSED` — `test_P08_supplyChangesOutsideGuardRevert`, `test_P08_secondMintToPoolRejectedEvenWhenGuarded` |
| P09 | Failed `transferFrom` (to the Pool, above allowance, above balance) leaves allowance and balances unchanged | — | `PASSED` — `test_P09_*` |
| P10 | After sequences of deposit, transfer, approve, transferFrom and failed calls: `totalSupply == 1000 + Σ holder balances`, Pool holds exactly 1000 | — | `PASSED` — `testFuzz_P10_accountingHoldsAcrossSequences` |

## 9. Quote (M5)

| ID | Description | Status |
|---|---|---|
| Q01 | `getAmountOut` equals the actual swap output on the same state (Tier 0) | `NOT IMPLEMENTED` |
| Q02 | Invalid `tokenIn`, zero input, zero reserves behave as in swap | `NOT IMPLEMENTED` |
| Q03 | Quote uses recorded reserves and ignores surplus | `NOT IMPLEMENTED` |
| Q04 | Where the floored output is 0, `getAmountOut` returns 0 and `swapExactInput` with the same inputs reverts `InsufficientOutputAmount` with no state change (unit: reference case 3; fuzz over class-B inputs of §11.1) | `NOT IMPLEMENTED` |

## 10. Factory (M7)

| ID | Description | Status |
|---|---|---|
| F01 | Unique pair created; event emitted; `allPairs` grows | `NOT IMPLEMENTED` |
| F02 | `getPair(A,B) == getPair(B,A)` | `NOT IMPLEMENTED` |
| F03 | Identical, zero and duplicate pairs revert | `NOT IMPLEMENTED` |
| F04 | Two Pools have independent reserves and LP | `NOT IMPLEMENTED` |
| F05 | Pool's `surplusRecipient` matches the value the Factory passed (per the M7 decision) | `NOT IMPLEMENTED` |
| F06 | M2–M6 tests pass with Pools deployed by the Factory | `NOT IMPLEMENTED` |
| F07 | `forge build --sizes`: runtime size below 24,576 bytes for both contracts | `NOT IMPLEMENTED` |

## 11. Cross-cutting, fuzz and boundary (M5, M8, M10)

| ID | Description | Milestone | Status |
|---|---|---|---|
| X01 | Cross-function reentrancy (e.g. `removeLiquidity` from a swap callback) blocked | M5 | `NOT IMPLEMENTED` |
| X02 | Tokens that return `false`, return nothing, or revert cause full rollback | M5 | `NOT IMPLEMENTED` |
| X03 | ABI has no owner, setter, sweep or pause function | M5 | `NOT IMPLEMENTED` |
| X04 | Exclusive-FOT mock (over-debits the Pool) makes remove, swap and skim revert (A8) | M8 | `NOT IMPLEMENTED` |
| Z01 | Fuzz swap in `[1, 2^112]`: `out < rOut`; inequality holds; no unexpected revert | M5 | `PASSED` at maths level (`AMMMath`, M2) — `testFuzz_getAmountOut_A_success`; Pool swap: `NOT IMPLEMENTED` (M5) |
| Z02 | Fuzz add then full remove: returns no more than contributed | M10 | `NOT IMPLEMENTED` |
| Z03 | Mixed 6/18-decimal scales near the top of the fuzz range | M10 | `NOT IMPLEMENTED` |
| Z04 | Fuzz gross vs. net for the U8 taxed mock | M8 | `NOT IMPLEMENTED` |
| Z05 | Fuzz L-α: for random `T` and `t < 10000`, implementation gross gives `net ∈ [T, T+1]` | M8 | `NOT IMPLEMENTED` |
| Z06 | **Arithmetic boundaries** for each formula in ARCHITECTURE §6.6: just inside the sufficient condition succeeds; beyond the overflow threshold reverts with the exact Panic; no wrong value returned | M5, M10 | `PASSED` for `getAmountOut` and `initialShares` (`test_Z06_*`); M4 formulas `PASSED`: L-α target — after M4H-2 it never overflows; `test_Z06_laterTargetOverflowTakesToken1Branch` (`2^255 − 1` → token0 branch, `2^255` → token1 branch instead of the former Panic), `test_M4H2_*` (3 tests, all three `mul512` paths), and the differential oracle `testFuzz_Z06_laterDepositMatchesOracle` / `test_Z06_extremeCapCorners` (file `test/AMMPoolDepositDifferential.t.sol`, DECISIONS M4H-3); redemption `test_W10_classA_*` (`type(uint256).max` → `ERC20InsufficientBalance`, no Panic). Analysed as unreachable before another check fails, so not separately testable: the other L-α branch (`T0 < amount0Max`), later-share `mulDiv` (bounded by the targets), reserve additions (bounded by token supply). Others M8/M10 |
| Z07 | **Business-invariant boundaries** (DECISIONS M4-7): `T_i == 0`, `shares == 0`, `amount_i == 0`, `[T, T + 1]`, `minShares`, `min_iNet`, the 1,000 lock — value at the boundary succeeds or fails exactly as specified, with the exact custom error | M4 | `PASSED` (M4) — `test_Z07_targetZeroBoundary`, `test_Z07_targetZeroBoundaryToken0Side`, `test_Z07_zeroSharesReverts`, `test_Z07_zeroOutputBoundary`; `[T, T+1]` lower side `test_L26_*`; `minShares` `test_L08_*`; `min_iNet` `test_W04_*`/`test_W05_*`; lock `test_W06_*`/`test_W11_*` |

Do not use `assume()` to exclude conditions the implementation is expected to handle.

### 11.1 Maths test design for `AMMMath` (M2, DECISIONS M2-9)

**M2-5r re-run (2026-11-18):** `test/AMMMath.t.sol` 27 tests passed (class B now expects 0; new exact A/B boundary fuzz), also with `FOUNDRY_FUZZ_RUNS=10000`.

**M2 results (2026-11-17):** `test/AMMMath.t.sol` 26 tests and `test/AMMPool.t.sol` 15 tests passed with the default 256 fuzz runs and again with `FOUNDRY_FUZZ_RUNS=10000`. Mutation check (temporary, reverted): removing the fee, rounding up, and returning `out + 1` each made the reference-case, floor and zero-output tests fail.

**Independent classifier.** A test helper classifies `(a, rIn, rOut)` without calling `mulDiv` and without overflowing, in the same order as the implementation's checks:

1. `a == 0` → `InsufficientInputAmount`.
2. `rIn == 0` or `rOut == 0` → `InsufficientLiquidity`.
3. Overflow → Panic `0x11` if `a > ⌊MAX/9970⌋`, or `rIn > ⌊MAX/10000⌋`, or `rIn·10000 > MAX − a·9970` (each step evaluated only after the previous one is known not to overflow).
4. Zero output → returns 0 (DECISIONS M2-5r) iff `aFee × rOut < den`, compared as exact 512-bit values.
5. Otherwise success.

So validity is never judged only by "all three inputs > 0".

**512-bit helper.** `Wide512.mul(x, y)` returns the exact product as `(hi, lo)` using 128-bit limbs (schoolbook multiplication, independent of OpenZeppelin); it is cross-checked against `Math.mul512` by fuzzing. `Wide512.lt/lte` compare such values. Any product of two `uint256` values is `< 2^512`, so the helper cannot overflow.

**Three fuzz classes, each with constructed (not `assume`-filtered) inputs:**

| Class | Input construction | Assertions |
|---|---|---|
| A — success | `rIn ∈ [1, 2^112]`, `rOut ∈ [2, 2^112]`, `a ≥ aMin = ⌈rIn·10000 / (9970·(rOut−1))⌉` (the exact condition for `out ≥ 1`) | classifier says success; `out < rOut`; floor: `out·den ≤ aFee·rOut < (out+1)·den`; §6.5: `den·(rOut−out) ≥ (rIn·D)·rOut`; tightness: `den·(rOut−out−1) < (rIn·D)·rOut` (i.e. `out + 1` violates §6.5) |
| B — zero output | `rOut = 1` with any `a`, or `rIn > 0.997·(rOut−1)` and `a ∈ [1, aMin − 1]` | classifier says zero output; call returns exactly 0 (M2-5r); floor lower bound `0 ≤ aFee·rOut < den` re-checked. The swap-level revert is tested in M5 (S03, Q04) |
| C — overflow | one of: `a > ⌊MAX/9970⌋`; `rIn > ⌊MAX/10000⌋`; or both in range but `rIn·10000 + a·9970 > MAX` | classifier says overflow; call reverts with Panic `0x11` |

A fourth fuzz test feeds raw `uint256` triples to the classifier and checks the implementation behaves exactly as classified (any class, including zero input and zero reserves).

**How `out + 1` avoids helper overflow.** All four products above are products of two values `< 2^256`: `den` and `rIn·D` fit in `uint256` because class A already excludes overflow; `out + 1 ≤ rOut` and `rOut − out − 1 ≥ 0` because `out < rOut`. Each product is formed with `Wide512.mul` and compared in 512 bits, so nothing in the test can overflow or wrap.

**`initialShares`.** Overflow iff `net0 ≠ 0` and `net1 > ⌊MAX/net0⌋`. Otherwise `s = ⌊√p⌋` satisfies `s² ≤ p < (s+1)²`, checked in 512 bits because `(s+1)²` can equal `2^256`.

## 12. Stateful invariants (M10)

The handler randomly calls every public function and also transfers tokens (and LP) directly to the Pool.

| ID | Invariant | Status |
|---|---|---|
| I1 | BI-7 and BI-8: LP `totalSupply` = minted − burned; Pool's LP == 1000 after the first deposit; no protocol shares | `NOT IMPLEMENTED` |
| I2 | BI-1: `balance_i ≥ reserve_i` with supported tokens | `NOT IMPLEMENTED` |
| I3 | BI-9 for every successful swap | `NOT IMPLEMENTED` |
| I4 | Reverted calls leave no state change | `NOT IMPLEMENTED` |
| I5 | Factory has no duplicate or unregistered pair | `NOT IMPLEMENTED` |
| I6 | Adaptive deposits never debit more than the cap | `NOT IMPLEMENTED` |
| I7 | BI-5 and BI-6 hold on every outbound transfer | `NOT IMPLEMENTED` |
| I8 | `skim()` sends only `balance − reserve`, only to `surplusRecipient` | `NOT IMPLEMENTED` |
| I9 | Only `sync()` lowers a reserve without an outbound transfer; no function moves surplus into reserves | `NOT IMPLEMENTED` |

`reserve0 × reserve1` monotonicity is required per swap only (BI-9), not across withdrawals or `sync()`.

## 13. Future-only

C01–C07 (deferred protocol fee): `FUTURE-ONLY`; not written; excluded from pass counts.

## 14. Gas

Record only measured values, with identical compiler, optimizer, EVM version, initial state and workload for any comparison.

**Every gas result must state the compiler configuration it was measured with** (`APPROVED` workflow rule). Verify it with `forge config` immediately before measuring. Current configuration (U12):

| Setting | Value |
|---|---|
| `solc` | 0.8.38 (`auto_detect_solc = false`) |
| Optimizer | enabled, `optimizer_runs = 200` |
| `evm_version` | `osaka` |
| `via_ir` | `false` |
| OpenZeppelin Contracts | v5.7.0 (`cab19933`) |
| forge / forge-std | 1.9.0 / 1.17.0 |

If any setting changes, earlier measurements are not comparable with later ones; re-measure both sides under one configuration.

| ID | Measurement | Purpose | Milestone | Status |
|---|---|---|---|---|
| G01 | `swapExactInput` gas with and without the on-chain §6.5 assertion | Input to the A9 decision | M5 | `NOT IMPLEMENTED` |
| G02 | Gas snapshot of all public functions | Report and later optimisation baseline | M10 | `NOT IMPLEMENTED` |

### 14.1 M4 hardening measurements (2026-11-19)

Configuration verified with `forge config` immediately before measuring: `solc` 0.8.38, optimizer on, 200 runs, `evm_version = osaka`, `via_ir = false`, OpenZeppelin v5.7.0, forge 1.9.0. Temporary variants were applied by a script outside the repository and reverted afterwards.

**H1 — `removeLiquidity` order** (`forge test --gas-report`, calls from `test_W01_proportionalRedemption`, `test_W06_lastLPExitsLockRemains`, `test_W10_classA_*`; 2 successful + 4 reverting calls):

| Order | Min (revert) | Median (revert) | Max (success) | Runtime size |
|---|---:|---:|---:|---:|
| Burn, then `mulDiv` (kept) | 27,926 | 28,160 | 123,262 | 6,071 B |
| `mulDiv`, then burn | 30,469 | 32,732 | 123,268 | 6,073 B |

**H2 — L-α step 2 overflow fix** (one later deposit measured with `gasleft()` around the external call; Pool `(1000e18, 2000e18)`, caller's storage pre-warmed; caps `(100e18, 300e18)` → token0 cap binds; `(100e18, 150e18)` → token1 cap binds; `(type(uint256).max, 100e18)`):

| Variant | token0-cap branch | token1-cap branch | `(MAX, 100e18)` | Runtime size |
|---|---:|---:|---|---:|
| V0 before (inline `mulDiv`) | 96,170 | 96,425 | Panic `0x11` | 6,071 B |
| V0 in a private helper | 96,240 | 96,495 | Panic | 6,099 B |
| V1 helper: `mul512` guard + `mulDiv` | 96,427 | 96,684 | 96,805 | 6,143 B |
| V2 helper: `mul512` once, fast division | 96,258 | 96,515 | 96,834 | 6,202 B |
| V3 helper: `tryMul` fast path | 96,267 | 96,524 | 96,974 | 6,255 B |
| V4 helper: fast division on both branches | 96,258 | 96,476 | 96,795 | 6,238 B |
| V1' inline guard + `mulDiv` (hint check moved) | 96,341 | 96,596 | 96,717 | 6,101 B |
| V2' inline `mul512` once (hint check moved) | 96,186 | 96,441 | 96,751 | 6,161 B |
| **V4' inline, fast division on both branches (hint check moved) — chosen** | **96,173** | **96,389** | **96,708** | 6,195 B |

V4' costs +3 gas on the token0-cap branch and saves 36 gas on the token1-cap branch per call; measured deployment cost (`forge test --gas-report`, `test/AMMPool.t.sol`): V0 1,425,234 gas / 7,162 B, V4' 1,452,077 gas / 7,286 B, i.e. +26,843 gas once per Pool. Break-even on runtime alone: about 746 token1-cap deposits; never for token0-cap deposits. Chosen anyway (student, 2026-11-19, option A): deployment is paid once per Pool, per-call gas is roughly neutral, and the fix makes legitimate unbounded-cap deposits succeed instead of reverting. These are single-scenario measurements, not a full gas snapshot (that is G02, M10).
