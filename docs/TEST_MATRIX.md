# TEST MATRIX — Foundry Test Plan

**Last updated:** 2026-11-23

**Status:** Rows marked `PASSED` (M1–M6) are implemented and were run. Everything else is a plan, not a record of passing tests. "Maths level" means the library function was tested; the Pool function that uses it does not exist yet. Record a result and the test function name only after the test has actually been run.

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
| L05 | U8 taxed token: measured `net_i ∈ [T_i, T_i+1]`; shares from net; worked example of ARCHITECTURE §6.2 (gross 203, net 201) | M8 | **Retired in M8** (L-α and `[T, T+1]` retired, M8-1). Kept property "shares from measured net" for taxed tokens: L26, L31–L35, Z08 |
| L06 | Failed transfer / insufficient balance / insufficient allowance reverts with no state left | M4 | `PASSED` — initial path (M3, `test_L23_*`); later deposit (M4, `test_L06_*`, 4 tests) |
| L07 | First depositor sets the initial price | M3 | `PASSED` (M3) — `test_L07_firstDepositorSetsPrice` (18/6 decimals) |
| L08 | `minShares` unmet reverts; expired deadline reverts; `block.timestamp == deadline` succeeds | M4 | `PASSED` — initial path (M3, `test_L18_*`, `test_L21_deadlineBoundary`); later deposit (M4, `test_L08_*`) |
| L09 | Required gross above cap reverts | M8 | **Retired in M8** (L-α retired, DECISIONS M8-1): no gross is computed; the request is bounded by `RequestMax` and the payer's debit by `maxDebit` (L37, L39, Z09) |
| L10a | Tax hint higher than actual reverts | M8 | **Retired in M8** (tax hints removed, M8-1, M8-10) |
| L10b | Tax hint lower than actual reverts | M8 | **Retired in M8** (tax hints removed, M8-1, M8-10) |
| L10c | Tax rate changed between quote and execution reverts | M8 | **Retired in M8** (no hint to contradict, M8-1): a changed rate is measured, not rejected; covered by L42 (seeded random tax per transfer) and Z09; a change after the deposit is the limitation test X07 |
| L11 | Caller's measured debit per token ≤ its cap (unit + fuzz) | M4, M8 | Tier 0 `PASSED` (M4) — `test_L03_workedExampleSmallUnits`, `testFuzz_L04_L11_L12_laterDepositFairness`; taxed tokens covered in M8 by Z09 (debit ≤ `RequestMax` and ≤ `maxDebit`, random tax 0–9,999 bps) and Z08 (exact debits) |
| L12 | Caller's token balances never increase during `addLiquidity` (no refund path) | M4, M8 | Tier 0 `PASSED` (M4) — `testFuzz_L04_L11_L12_laterDepositFairness`; taxed tokens covered in M8 by Z08 (exact payer debits asserted for inclusive tax 0–100 % and bonus) |
| L13 | Inflation scenario: after a large direct transfer by an attacker, a later LP's shares are not rounded to zero and the transfer does not enter reserves | M6 | `PASSED` (M6) — `test_L13_inflationAttemptFails` |
| L14 | `recipient ∈ {address(0), Pool}` reverts | M4 | `PASSED` — initial path (M3, `test_L21_invalidRecipientReverts`); later deposit (M4, `test_L14_invalidRecipientRevertsOnLaterDeposit`, `test_L14_recipientReceivesSharesAndEvent`) |
| L15 | Initial deposit with a taxed token ignores the hints and uses measured net | M8 | `PASSED` — `test_L19_taxedInitialDepositUsesMeasuredNet` (hints no longer exist, §3.3 row 2) |
| L16 | `tax_iBps ≥ 10000` reverts | M8 (initial path in M3) | **Retired in M8** (commit 2): the tax-hint parameters no longer exist (DECISIONS M8-1, M8-10); `InvalidTaxBps` absent from the compiled ABI (L30). See §3.3 |
| L26 | Pre-M8: later deposit with a U8 taxed token and hint 0 → `NetAmountOutOfRange`. **M8 (approved incompatible change, M8-1):** the deposit is accepted and accounted by measured net; taxed token as token0 and as token1, each with both pull orders; nets = Pool balance increases; reserves += nets; shares = min(floor(n_i·S/r_i)); per-share reserves never decrease | M4, M8 | `PASSED` (M8 commit 2) — `test_L26_taxedToken0LaterDepositUsesMeasuredNet`, `test_L26_taxedToken1LaterDepositUsesMeasuredNet` (replace the two M4 tests, §3.3) |
| L27 | TEMPORARY (M4-1): `S > 0` with a non-zero hint → `TaxedLaterDepositNotImplemented` | M4 | **Retired in M8** (commit 2): the revert and the hint parameters are removed (M8-5); absence proven by L30; the initial-path property moved to L19. See §3.3 |

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
| L19 | U8 taxed token, initial deposit: shares and reserves use the measured balance difference, not the requested amount; caller inputs other than the amounts (M8: pull order and excess fields; pre-M8: tax hints) give identical results | `PASSED` — `test_L19_taxedInitialDepositUsesMeasuredNet`, `test_L19_pullOrderAndExcessFieldsDoNotChangeInitialResult`, `testFuzz_L19_anyOrderAndExcessFieldsGiveSameShares` (M8 replacements, §3.3) |
| L20 | Pre-existing surplus in both tokens: each measured net equals the amount transferred in this call; final reserves equal the nets; both surpluses unchanged (BI-2, initial path of B01) | `PASSED` — `test_L20_preExistingSurplusIsNotAttributed` |
| L21 | Initial path argument checks: deadline (`==` succeeds, `+1` reverts), recipient `0`/Pool, zero amounts (pre-M8 also `tax ≥ 10000`, retired in M8) | `PASSED` — `test_L21_deadlineBoundary`, `test_L21_invalidRecipientReverts` (`test_L21_L16_taxBpsBoundary` retired in M8, §3.3) |
| L22 | `S > 0` reverts `LaterDepositNotImplemented` (temporary; replaced in M4) | `PASSED` in M3 — `test_L22_laterDepositRevertsUntilM4` (temporary; removed in M4 together with the error, replaced by L03) |
| L23 | Failing token1 (reverting `transferFrom`, `false` return, reverting `balanceOf`) rolls back the whole call, including token0's completed transfer | `PASSED` — `test_L23_*` (4 tests) |
| L24 | Reentrancy smoke test: a token callback re-entering `addLiquidity` reverts `ReentrancyGuardReentrantCall` (full attacks in M5) | `PASSED` (smoke) — `test_L24_tokenCallbackCannotReenterAddLiquidity` |
| L25 | `LiquidityAdded` and the two `Transfer` mint events carry the expected fields | `PASSED` — `test_L25_events` |

### 3.2 M8 measured-net deposit — tests (DECISIONS M8-1 to M8-13; planned before implementation, results in the status column)

Planned before implementation; the status column records the results. Every revert asserts the exact error (M4-8) and full-state rollback: reserves, Pool / payer / recipient token balances, LP supply and balances, allowances. Every fuzz row states its success range, safe-revert inputs and uncovered boundaries (M5-7).

| ID | Description | Status |
|---|---|---|
| L30 | Interface (M8-5): new `addLiquidity` selector equals the approved struct signature, old selector absent; `LiquidityAdded` topic unchanged; X03 still 22 entries with exactly one approved replacement; `TaxedLaterDepositNotImplemented` / `NetAmountOutOfRange` absent from `src/` and the compiled ABI; map of each removed L26/L27 test to its replacing functional test | `PASSED` (M8 commit 2) — `test_L30_removedErrorsAbsentFromCompiledAbi`, `test_L30_liquidityAddedEventUnchanged`; selector and X03 parts: `test_X03_static_addLiquidityReplaced`, `test_X03_runtime_oldAddLiquiditySelectorFails`; mapping: §3.3 |
| L31 | First token delivers **less** than requested (taxed first token): the second request is re-planned from the measured net; the worked numbers of REPORT_NOTES §1.5 | `PASSED` (M8 commit 5e) — `test/AMMPoolM8Scenarios.t.sol`: `test_L31_standard_eitherOrder`, `test_L31_L34_token1Taxed_pullOrderDecidesTheExcess`; every REPORT_NOTES §1.5 worked number reproduced exactly on-chain |
| L32 | First token delivers **more** than requested (bonus token): re-plan capped by the second token's request cap; this covers the `min(...)` branch, so a mutant removing it is a test gap, not an equivalent mutant | `PASSED` (M8 commit 5a) — `test/AMMPoolReplan.t.sol`: `test_L32_bonusFirst_upwardReplanCappedByRequestMax` (caps unbounded / binding / equal to the step-2 target, both positions), `test_L32_bonusFirst_cappedReplanExcessBoundedByMaxExcess`, `test_L32_bonusSecond_noReplan_bonusIsExcess`. Mutation: removing the `min(cap, …)` (R1/R2) survives every pre-5a test and is killed by L32 |
| L33 | Both tokens taxed (fixed, unknown to the Pool), with each pull order | `PASSED` (M8 commit 5e) — `test_L33_bothTaxed_eachPullOrder`: token0 first n = (9,500, 18,430), σ = 13,031, u = (285, 1) (§1.5); token1 first n = (9,215, 19,400), σ = 13,031, u = (0, 971) |
| L34 | Token0-first vs. token1-first on the same state: different unmatched amounts as predicted by the model; shares from measured net in both | `PASSED` (M8 commit 5e) — `test_L31_L34_token1Taxed_pullOrderDecidesTheExcess`: token1 taxed 5%: token1 first u = (0, 0); token0 first u = (500, 0); same σ = 13,435 |
| L35 | Second token delivers **zero** (100% tax mock): `σ == 0` → `InsufficientShares`, full rollback | `PASSED` (M8 commit 5e) — `test_L35_secondNetZero_insufficientShares_fullRollback` (each pull order, the second-pulled token 100% taxed) |
| L36 | `maxExcess` boundary per token: `u == maxExcess` succeeds; `maxExcess = u − 1` → `ExcessContributionTooHigh` | `PASSED` (M8 commit 5b) — `test/AMMPoolMaxExcess.t.sol`: `test_L36_excessOnEachToken_boundary` (~10% excess on token0 and on token1), `test_L36_tier0Dust_boundaryIncludingZero` (u = 0 with maxExcess = 0 succeeds; ceil ≠ floor covered), `testFuzz_L36_tier0Boundary`. Expected u from the pre-state and the nets (independent reference); u = maxExcess succeeds, u − 1 reverts with full rollback, per token |
| L37 | `maxDebit` boundary per token (inbound exclusive mock): debit `== maxDebit` succeeds, `maxDebit = debit − 1` → `PayerDebitTooHigh`; the success case does **not** assert future redeemability (M8-12 (4)) | `PASSED` (M8 commit 3) — `test/AMMPoolPayerDebit.t.sol`: `test_L37_plainTokens_bothPullOrders`, `test_L37_inclusiveFee_bothPositions_bothPullOrders`, `test_L37_exclusiveFee_bothPositions_bothPullOrders`, `test_L37_initialDeposit_exclusiveFee_bothPullOrders`, `test_L37_payerBalanceRises_countsAsZero_bothPositions_bothPullOrders`, `test_L37_randomTaxBothTokens_seeded_bothPullOrders` (seeds 1–8, fresh fixture per seed). Shared driver per case: limit above, equal (succeed, identical result), one unit over on token0, on token1, on both (`PayerDebitTooHigh`, full-state rollback) |
| L38 | Payer debited **extra during the whole call** by a cross-token callback (token0's hook slashes the payer's token1 outside token1's own window) → `PayerDebitTooHigh`; the same amount without the callback succeeds (shows that local windows would miss it) | `PASSED` (M8 commit 3) — `test_L38_crossTokenHook_bothDirections_bothPullOrders`: hook token as token0 and as token1 (both directions), each pull order; the limit covering only the deposit reverts, the limit including the slash succeeds with the clean-run result |
| L39 | Request cap is not a promise: the actual request is below the request cap after step 2 / re-plan; the payer's debit is measured, not assumed equal to the cap | `PASSED` (M8 commit 5e) — `test_L39_requestCapIsNotAPromise` (step-2 target and downward re-plan both below the cap; debits measured) |
| L40 | Check order (M8-13 (d)) when several conditions fail at once: the first error in the approved order is reported | `PASSED` — commit 3 (`PayerDebitTooHigh` part), commit 4 (`InCallBalanceLoss` part), commit 5e `test_L40_fullChain_threeSimultaneousFailures` (BI-2′, maxDebit and σ = 0 at once; removing each reported condition reveals the next: `InCallBalanceLoss` → `PayerDebitTooHigh` → `InsufficientShares` → success) |
| B09 | In-call balance rule (M8-11, X1, `addLiquidity` only): (a) pre-existing surplus in both tokens, no foreign change → succeeds, surplus unchanged; (b) cross-token debit of the Pool **masked by surplus** (r1 = 1000, B1 = 1300, 200 removed during token0's pull, n1 = 500) → `InCallBalanceLoss`, full rollback; (c) extra GIFT during the first pull (B08 case) → succeeds, surplus increases by GIFT; (d) zero surplus with a cross-token debit → `InCallBalanceLoss`; (e) the comparison is written in subtraction form, and a fuzzed balance near `type(uint256).max` neither overflows nor passes wrongly | `PASSED` (M8 commit 4) — `test/AMMPoolInCallBalance.t.sol`, each over hook-token position × pull order (4 cases): (a) `test_B09a_preExistingSurplusUnchanged_later_allCases`, `..._initial_allCases`, `test_B09a_ownShortfallIsNotAForeignLoss_allCases`; (b) `test_B09b_foreignGiftIncreasesSurplus_later_allCases`, `..._initial_allCases`; (c) `test_B09c_maskedSurplusLoss_later_allCases` (the M8-11 numbers), `..._initial_allCases`; (d) `test_B09d_zeroSurplusLossOfOneUnit_allCases`, `test_B09d_lossLargerThanOwnNet_endBelowStart_allCases`; (e) `testFuzz_B09e_largeBalances` (surplus up to the token maximum) |
| B10 | BI-2′ is **not** extended: swap / remove with a masked foreign surplus decrease still succeed — a documented limitation test (THREAT_MODEL T30) | `PASSED` as a **limitation test** (M8 commit 5f) — `test/AMMPoolM8Limitations.t.sol` `test_B10_limitation_swapAndRemove_maskedForeignLossSucceeds`: a hook removes 300 units of the other token's surplus during a swap's inbound and a withdrawal's outbound transfer; both succeed and the surplus falls 1000 → 700 → 400 (T30 residual, executed) |
| L13b | Inflation P&L measured on the real `AMMPool` (THREAT_MODEL T4), under the explicit assumptions A1–A5 (bonus-mock donation channel; later deposits from one address, redeemed together at the end; 1:1 valuation; gas not in the P&L). Covered: <br>• the attacker's P&L from executed redemptions for 0, 1, 1,000 and 5,000 later deposits, with unbounded or 10 bps `maxExcess`; <br>• `minShares` set to a post-inflation quote; <br>• a direct transfer followed by `sync`; <br>• the attacker's own `maxExcess` through a 10% FOT channel with one later deposit | **Redefined at the student's request (2026-11-22): real P&L under explicit assumptions, no assumed outcome.** `test/AMMPoolInflation.t.sol` (M8 commit 5d), all `PASSED`; every exact P&L equals an independent integer model of the same steps. Measured: baseline −2000 wei (the lock); one victim −1.9998e22; 1000 victims −1.1105e22; **5000 victims with unbounded victim excess +1.8166e22 (PROFITABLE; victims lose 3.8204e22)**; 5000 victims with a 10 bps tolerance −1.9454e22 (4442 deposits rejected: griefing); minShares equal to the quote does not prevent the loss; direct donation + sync does not inflate; own maxExcess with a real 10% FOT channel and one victim loses money. See the 5d note below | |
| L42 | Re-planned second target is 0 → `InsufficientDepositAmount()` before the second `transferFrom` (DECISIONS M8-8): (i) the first token's measured net is 0 (100% tax mock); (ii) the first net is > 0 but the re-plan floors to 0; (iii) both cases with each pull order; (iv) full rollback: the first transfer's balance changes, reserves, supply and payer balances are restored; the second token's `transferFrom` is never called; (v) the exact error selector is asserted | `PASSED` (M8 commit 2) — `test_L42_firstNetZero_bothPullOrders`, `test_L42_firstNetPositiveReplanFloorsToZero_bothPullOrders`, `test_L42_randomTaxSeeded_bothPullOrders` (seeds 1–8), reverse test `test_L42_reverse_detectorsSeeTheSecondCall`. Zero calls are asserted by `vm.expectCall(token, transferFrom selector, 0)`, which matches any `transferFrom` call, and by a `MockFailure()` tripwire. Mutation: removing either re-plan zero check fails all three L42 tests (source restored, hash identical) |
| L43 | Canonical token order: with `token1First = true` and `false`, the return values `net0`/`net1` and the `LiquidityAdded` arguments are token0's and token1's measured nets, not first/second pulled | `PASSED` (M8 commit 2) — `test_L43_netsReportedInTokenOrder_bothPullOrders` (initial and later deposit; token0 1%, token1 3% tax, so the nets differ) |
| L44 | (M10 item 1) Tier 0 `maxExcess` setting: `maxExcess_i = 0` can reject an honest deposit; `M_i = ⌊(r_i·(r_j+S) − 1)/(S·r_j)⌋` computed at the execution state never rejects a Tier 0 deposit for its excess | M10 | `PASSED` (M10) — `test/AMMPoolMaxExcessTier0.t.sol`: `test_L44_tier0ZeroMaxExcessRevertsSafeSettingPasses` (r = (623,347,348,957, 884,107,996,871), caps (820,096,754, 67,760,437): `maxExcess = (0, 0)` reverts `ExcessContributionTooHigh` with reserves, balances and supply unchanged; `M = (1, 2)` passes with σ = 56,896,898, u = (0, 1)); `testFuzz_L44_safeMaxExcessNeverRejectsTier0` (initial amounts [1e3, 2^100], optional swap [1, 2^100], caps [1, 2^100], either order; accepted reverts only `InsufficientDepositAmount` / `InsufficientShares`; measured `u_i ≤ M_i`). Default and 10,000 runs passed. Mutation check: excess computed with floor instead of ceil (token1); `>=` instead of `>` (token0): 2/2 killed by the fuzz. Scope: Tier 0, unsaturated σ, `M_i` at the execution state |
| L45 | (M10 item 3) First-deposit branch change under a front-run: the path is chosen by `totalSupply()` at execution; the caller cannot require "initial only" | M10 | `PASSED` (M10) — `test/AMMPoolFirstDepositBranch.t.sol` (Tier 0; bob's caps (1e21, 4e21), initial-path expectation `isqrt(A·B) − 1000`; expected values from an integer model): `test_L45_noFrontRunInitialPath`; `test_L45_sameRatioFrontRunMeetsExpectation` (eve (1e6, 4e6): caps pulled in full, σ = 2e21); `test_L45_skewedFrontRunRejectedByMinShares` (eve 1:1: `minShares` = expectation reverts `InsufficientShares` with no state change; `minShares = 0` succeeds at eve's ratio, pulling (1e21, 1e21)); `test_L45_slightSkewMinSharesAndExcessFieldsBecomeActive` (relative skew 3e-6: `InsufficientShares`; with `minShares = 0` and `maxExcess = 0` the excess fields, inactive on the initial path, revert `ExcessContributionTooHigh` (u1 = 1); loose bounds succeed with σ = 1,999,996,000,011,999,963,999); `test_L45_slightSkewStillPassesInitialMinShares` (regression, relative skew 2.5e-19, eve (1e18, 4e18 + 1): the call succeeds with `minShares` = expectation and `maxExcess = 0`, σ = 1,999,999,999,999,999,999,500 ≥ expectation, n0 = 999,999,999,999,999,999,750: bob deposits at eve's ratio). Mutation check (later path ignoring `minShares`; token1 excess check removed; later path also deducting 1000 shares, killed by the regression): 3/3 killed. **Scope:** setting `minShares` to the initial-path expectation rejects a front-run at a clearly different ratio (tested: 1:1, skew 3e-6), but not every front-run: on the later path the caller pays no lock, so a shortfall of up to the 1000 lock shares is absorbed and a slightly different ratio passes (the depositor then deposits at the front-runner's ratio). The current interface cannot request "initial only". Not covered: a front-run followed by a per-share inflation (F1, T4) |
| L46 | (M11) Worked deposit example of REPORT §5 executed on the real Pool: request cap → payer debit → Pool receipt → shares → excess | M11 | `PASSED` (M11) — `test/AMMPoolReportExample.t.sol` `test_L46_reportWorkedDeposit`. Reserves (10,000, 20,000), S = 14,142; token1 10 % inclusive tax on pulls (`MockFeeERC20`); caps (1,000, 2,500), token0 first, maxDebit (1,000, 2,000), maxExcess (100, 1), minShares 1,272. Asserted: payer debit (1,000, 2,000), 200 burned as tax, Pool receipt (1,000, 1,800), σ = 1,272, reserves (11,000, 21,800), S = 15,414, immediate redemption (907, 1,798); maxDebit1 = 1,999, maxExcess0 = 99 and minShares = 1,273 each revert (`PayerDebitTooHigh`, `ExcessContributionTooHigh`, `InsufficientShares`) with no state change. Expected values from an integer Python model |
| L41 | JIT capture of a victim's excess (T29): add before, remove after; the capture is bounded by the victim's `maxExcess` | `PASSED` (M8 commit 5e) — `test_L41_jitCapture_boundedByVictimsExcess`: measured JIT gain 898 token1-units out of the victim's 1,000 unmatched value (maxExcess = 500 token0); a round trip without the victim gains nothing |
| Z08 | Saturating arithmetic (M8-4): (i) one side's `n·S/r` ≥ 2^256, the other side fits → `σ` = the smaller side, proceeds; (ii) both sides saturate (`σ = max`) → Panic `0x11` from the checked `supply + σ`, unless `InCallBalanceLoss` or `PayerDebitTooHigh` fails first (asserted separately); `InsufficientShares` cannot fire here; (iii) one side saturates, the other is exactly `2^256 − 1` → same as (ii); (iii-b) `σ` in `(max − S, max)` with `minShares > σ` → `InsufficientShares`, with `minShares ≤ σ` → Panic `0x11`; in no case is `ExcessContributionTooHigh` reported or a share minted; (iv) re-plan saturates → request equals the request cap; 512-bit differential oracle over `[1, 2^256 − 1]` | `PASSED` (M8 commits 2 and 5a/5c) — (i) `test_Z08i_oneSideSaturates_otherFits_succeeds`; (ii) `test_Z08_saturatedSharesPanicBeforeExcessCheck`; (iii) `test_Z08iii_saturatedAndExactMax_panics` (S = 65535 divides 2^256 − 1); (iii-b) `test_Z08iiib_sigmaBelowMaxAboveMaxMinusS`; (iv) `test_Z08iv_replanSaturates_requestIsCap`; oracle `testFuzz_Z08_differentialOracle` (`test/AMMPoolMeasuredDifferential.t.sol`): independent 512-bit long division replaying step 2 → pulls (inclusive tax 0–100%, bonus 0–2^200 per token) → re-plan → σ → error order; exact revert data or exact nets, shares, debits and reserves. Success range: reserves [1, 2^120] with S > 1000, caps [1, MAX − 2^121 − 2^201]; uncovered: exact equality T1 = cap1 in step 2 (the C7 `>=` mutant survives this file and is killed by the M4 Z06/Z07 tests) |
| Z09 | Fuzz: per-share reserves never decrease; BI-2′; debit `≤ maxDebit`; `u ≤ maxExcess`; random tax per transfer in `[0, 9999]`, reserves `[10^3, 2^112]`, requests `[1, 2^112]`, mixed 6/18 decimals | `PASSED` (M8 commit 5c) — `testFuzz_Z09_invariants`: reserves [1e3, 2^112], requests [1, 2^112], seeded random tax [0, 9999] bps per transfer on both tokens, 6/18 decimals, random maxDebit/maxExcess, pre-existing surplus. Success: per-share reserves non-decreasing (512-bit), surplus non-decreasing, debit ≤ maxDebit, request ≤ RequestMax, u ≤ maxExcess. Revert: only the specified errors, state unchanged. Uncovered: tokens outside the mock rules, foreign in-call changes (B09) |
| X06 | Trapped-liquidity limitation (THREAT_MODEL §7.6), modes (A) outbound-only refusal, (B) all transfers revert, (C) `balanceOf` reverts: remove fails; in (A) X → Y swaps and new deposits still succeed, Y → X fails; repeated X → Y swaps drain Y and the LPs' redeemable value is recorded; restoring X makes exit work again | `PASSED` as **limitation tests** (M8 commit 5f) — mode A `test_X06_limitation_modeA_outboundRefused_drainAndNewDeposits` (remove and Y→X fail; X→Y swaps and new deposits succeed; the new LP cannot exit; ten 100,000-X swaps drain Y to 501,008 as in the model; alice's redeemable Y 500,506 vs nominal X 1,998,000 she cannot withdraw; restoring X restores exit), mode B `test_X06_limitation_modeB_allTransfersRevert`, mode C `test_X06_limitation_modeC_balanceOfReverts` (also sync/skim). None of this is supported behaviour |
| X07 | Tax changes between deposit and withdrawal: an inclusive increase never triggers A8, MIN-NET decides; an outbound over-debit enabled after deposit → `OutboundTransferMismatch` (A8) | `PASSED` as a **limitation test** (M8 commit 5f) — `test_X07_limitation_taxChangesAfterDeposit`: an inclusive outbound tax added later never triggers A8, MIN-NET decides (recipient gets 90%); an exclusive outbound extra added later → `OutboundTransferMismatch` for a small withdrawal, and a token-level `ERC20InsufficientBalance` for a full one (the extra exceeds the Pool's balance): trapped either way |

Test-method rules (student review, 2026-11-21):

- "Random" tax is reproducible: an explicit seed drives a deterministic pseudo-random sequence (`keccak256(seed, nonce)`), and an explicit FIFO schedule gives predictable boundary values. No environment randomness. A failing fuzz case can be replayed from its seed.
- Every mock has its own self-tests before it is used against the Pool: payer debit, recipient credit, who bears an inclusive fee, where an exclusive extra charge is taken, and full balance restore after a failed transfer.
- "Not called" assertions (L42) use both `vm.expectCall(..., 0)` and a tripwire: the guarded token reverts with a mock-only error (`MockFailure()`) if it is called, so a wrong path cannot be mistaken for the Pool's own `InsufficientDepositAmount()`.
- Each `token1First` path is tested separately for: one token taxed, both taxed, random tax, and failure rollback (L31–L35, L42, Z09 run with both values); L43 checks that `net0`/`net1` are token0's/token1's.
- L36 keeps the `maxExcess` boundary; L42 checks full rollback; L43 checks the canonical token order.
- X06/X07 are **limitation tests**: they document behaviour outside the supported model (trapped liquidity, A8 refusal) and never describe the inability to exit as supported.
- Migration of the existing tests (commit 2 of M8): every existing test calling the old `addLiquidity` or using a removed error is listed in §3.3 as kept, modified, replaced or retired, with the reason. A security test is never deleted only because its old parameters no longer exist; its property is re-tested under the new ABI or the retirement is justified.
- M8 mocks (commit 1, 2026-11-21): `test/mocks/MockFeeERC20.sol` (per-path inclusive tax 0–100%, exclusive extra, bonus, FIFO schedule, seeded random tax; call trace `callCount`, `lastTaxBps`) and `MockFailingERC20.Mode.RevertAllTransfers` (appended; numbering of existing modes asserted). Self-tests `test/FeeMocks.t.sol`: 20 tests, `PASSED` with default fuzz runs and with `FOUNDRY_FUZZ_RUNS=10000`; full suite 343/343.
- Commits 2–4 of M8 (struct ABI, `maxDebit`, BI-2′) were work in progress when this was written; all three are implemented (`0582394`, `8df2e55`, `9caf253`) and M8 was accepted on 2026-11-23.

Mocks: variable / random tax with separate inbound and outbound settings, including 100%; exclusive extra charge (inbound and outbound separately, switchable after deposit); bonus (credits more than sent); cross-token hook (`ReentrantERC20` + `MockDeficitERC20.slash` on the Pool or on the payer); `MockFailingERC20` gains an additive "all transfers revert" mode for X06 (B), while the existing `RevertTransfer` and `RevertBalanceOf` modes cover (A) and (C).

### 3.3 M8 migration map of existing tests

M8 commit 2 (WORK IN PROGRESS: `maxDebit` and BI-2′ are not enforced until commits 3 and 4). Rule: no security assertion is dropped only because its old parameters no longer exist.

| # | Old test(s) | Outcome | New test(s) | Reason |
|---|---|---|---|---|
| 1 | 74 calls in 16 files with both hints `0` (helpers and tests in Factory, Integration, Isolation, Deficit, Deposit, DepositDifferential, Liquidity, Ownerless, Reentrancy, Skim, Swap, SyncSkimReentrancy, SyncSkimScenarios, Terminal, Withdraw, `PoolStateFixture`) | Modified, mechanically (script) | same names | `addParams(a0, a1, minShares, to, deadline)`: unbounded `maxDebit`/`maxExcess`, token0 first. This reproduces the pre-M8 Tier 0 behaviour exactly (same pull order, same step-2 targets, net = target so no re-plan, same shares; `[T, T+1]` never fired for Tier 0; the old Pool also added the measured net to the reserves). Every assertion unchanged |
| 2 | `test_L19_taxedInitialDepositUsesMeasuredNet` | Modified | same | Helper takes pull order and excess fields instead of hints; assertions unchanged |
| 3 | `test_L19_taxHintsDoNotChangeInitialResult`, `testFuzz_L19_anyValidHintGivesSameShares` | Replaced | `test_L19_pullOrderAndExcessFieldsDoNotChangeInitialResult`, `testFuzz_L19_anyOrderAndExcessFieldsGiveSameShares` | Same property ("non-amount caller inputs do not change the initial result") with the inputs that exist now (M8-13 (c)) |
| 4 | `test_L21_L16_taxBpsBoundary` | Retired | L30 (`InvalidTaxBps` absent) | The parameter no longer exists. A 100% tax is now handled by measurement (L42 (i); L35 later) |
| 5 | `test_L26_taxedToken0WithZeroHintReverts`, `test_L26_taxedToken1WithZeroHintReverts` | Replaced | `test_L26_taxedToken0LaterDepositUsesMeasuredNet`, `test_L26_taxedToken1LaterDepositUsesMeasuredNet` | Approved incompatible change (M8-1): taxed later deposits are accepted. Kept property: no shares for tokens that did not arrive; per-share reserves never decrease; both positions and both pull orders |
| 6 | `test_L27_nonZeroHintOnLaterDepositRevertsBeforeAnyTransfer` | Retired | L30 | Temporary revert removed (M8-5) |
| 7 | `test_L27_initialPathStillIgnoresHints` | Retired | L19 replacements (row 3) | Property moved to L19 |
| 8 | `test_R08_checkOrderAdd` (hint-range step; "deficit before the hint check") | Modified | same | Hint step removed; the deficit is still reported before any transfer, asserted for both pull orders |
| 9 | Deficit `_assertAllRevert` (add data) | Modified | same | Add data now built for both pull orders |
| 10 | R15 `_assertNoDepositOrSwap` (hint-100 case) | Modified | same | Replaced by the `token1First = true` case: the terminal check still precedes any transfer |
| 11 | `test_X01_add_caughtFaulty_shortInputRejectedByNetRange` | Replaced | `test_X01_add_caughtFaulty_shortInputAccountedByMeasuredNet`, `test_X01_add_caughtFaulty_shortInputRejectedByExcessBound` | `[T, T+1]` removed. Kept property: a short delivery during a caught re-entry earns no shares for missing tokens; (a) measured-net accounting, (b) with `maxExcess = 0` and the hook token pulled second, `ExcessContributionTooHigh` with full rollback |
| 12 | X03 whitelist entry | Modified | + `test_X03_static_addLiquidityReplaced`, `test_X03_runtime_oldAddLiquiditySelectorFails` | Old selector `0x12c62f32` absent and fails at runtime with empty data; new `0x7713f77f` present; still 22 functions |
| 13 | Z06 differential oracle | Modified (row 1) | same | Oracle unchanged: Tier 0 tokens, token0 first |

New in commit 2: L30 (2), L42 (4), L43 (1), Z08 (ii) (1), X03 (2), X01 (1 net). Suite: 343 → 351, all `PASSED` with default fuzz runs and with `FOUNDRY_FUZZ_RUNS=10000` (U12 configuration, verified with `forge config`).

Behaviour changes compared with M1–M7 (all approved in M8 unless noted):

1. `addLiquidity` ABI: one struct parameter; selector `0x12c62f32` → `0x7713f77f` (M8-8).
2. Errors `InvalidTaxBps`, `TaxedLaterDepositNotImplemented`, `NetAmountOutOfRange` removed; `ExcessContributionTooHigh` added (M8-10).
3. Later deposits with taxed or bonus tokens are accepted and measured instead of rejected (M8-1).
4. When the first token's net differs from its target, the second token's request is re-planned and can be below or above its step-2 target, never above its request cap (M8-12).
5. Unmatched contributions enter the reserves, bounded by `maxExcess` (M8-2). For Tier 0 tokens this is only the rounding dust that pre-M8 deposits already left in the reserves.
6. The initial deposit honours `token1First` (only the transfer order changes).
7. *Historical (commit 2):* `maxDebit0/1` and BI-2′ / `InCallBalanceLoss` were not yet enforced; they are enforced since commits 3 and 4. Gas: G05 (§14.5).

M8 commit 3 (WORK IN PROGRESS: BI-2′ follows in commit 4): `maxDebit` enforced by a whole-call snapshot of `msg.sender`'s two balances, taken after every pre-transfer check and before the first transfer. The end reading comes after the second pull. `addLiquidity` is split into the pull part (`_pullLater`) and the accounting part (`_mintLater`) so that the payer check sits between them. No migration was needed: the existing tests use unbounded `maxDebit` (row 1). New tests: 11 in `test/AMMPoolPayerDebit.t.sol` (L37 ×6, L38 ×1, L40 ×4). Suite 351 → 362, all `PASSED` with default fuzz runs and with `FOUNDRY_FUZZ_RUNS=10000`.

Mutation (commit 3; per-file backup and restore, hash identical afterwards; run against `test/AMMPoolPayerDebit.t.sol`):

| Mutant | Result |
|---|---|
| M1 token0 check removed | killed (8 tests) |
| M2 token1 check removed | killed (8 tests) |
| M3a token0 `start − end` without the "rose = 0" guard | killed (`test_L37_payerBalanceRises_*`, underflow) |
| M3b same for token1 | killed (same test) |
| M4 start snapshot taken after the transfers | killed (10 tests) |
| M5a token0 `>=` instead of `>` | killed (7 tests) |
| M5b token1 `>=` instead of `>` | killed (7 tests) |

Gas: **not measured** (G05 pending). A test-level gas figure is not used as evidence because it is dominated by Pool deployment cost. `forge build --sizes`: AMMPool runtime 9,881 B (margin 14,695 B), initcode 11,009 B (margin 38,143 B).

M8 commit 4 (WORK IN PROGRESS until M8 acceptance): BI-2′ (`InCallBalanceLoss`) for the initial and the later deposit. The Pool's start balances are read together with the payer snapshot, and fresh end balances are read after the second pull. The check is per token, written `end < start || end − start < net`. Order: `InCallBalanceLoss` → `PayerDebitTooHigh` → … (M8-13 (d)).

Pre-implementation audit (read-only):

- Every function that writes `reserve0` / `reserve1` (`addLiquidity` initial and later via `_mintLater`; `removeLiquidity`; `swapExactInput`; `sync` via `_syncToken`) is an external entry with `nonReentrant`, or a private function reachable only from one.
- All of them share OZ `ReentrancyGuardTransient`'s single transient slot. The reserves are `private`.
- The Pool has no `delegatecall`, no assembly and no other writer.
- The unguarded entries are LP `transfer` / `transferFrom` / `approve` and views. They cannot write reserves, and they cannot mint or burn: OZ rejects `to == 0`, and `_update` only allows a mint or burn inside the guard from the Pool's own code.
- So no token callback during the two pulls can change the recorded reserves or `totalSupply`. Executed evidence: X01 add callbacks (swap/add/remove payloads) and the M6 X01 add callbacks (sync/skim/add/remove/swap payloads, hooks on both tokens) all revert with `ReentrancyGuardReentrantCall` or leave a state identical to a clean run.

New tests: 12 in `test/AMMPoolInCallBalance.t.sol` (B09 ×10, L40 ×2). Suite 362 → 374, all `PASSED` with default fuzz runs and with `FOUNDRY_FUZZ_RUNS=10000`.

Mutation (commit 4; per-file backup and restore, hash identical afterwards; run against `test/AMMPoolInCallBalance.t.sol`):

| Mutant | Result |
|---|---|
| M1 / M2 token0 / token1 check removed | killed (6 / 7 tests) |
| M3a / M3b `end − start < net` without the `end < start` guard | killed (3 tests each, Panic 0x11 instead of `InCallBalanceLoss`) |
| M4a / M4b `<=` instead of `<` | killed (11 tests each) |
| M5a / M5b only `end < start` (own net ignored) | killed (4 / 5 tests) |
| M6a / M6b deficit-only rule `end < reserve + net` (surplus loss masked by surplus) | killed (3 / 4 tests, incl. both B09c) |
| M7 payer check before the balance check | killed (`test_L40_inCallBalanceLossBeforePayerDebitTooHigh_allCases`) |

Gas: **not measured** (G05 pending); commit 4 adds four `balanceOf` STATICCALLs per deposit. A candidate optimisation for G05 is to reuse the second pull's after-reading for the second token. `forge build --sizes`: AMMPool runtime 10,553 B (margin 14,023 B), initcode 11,709 B (margin 37,443 B).

M8 commit 5 (tests only; M8 remains WIP). 5a: L32 and Z08 (iv) (`test_Z08iv_replanSaturates_requestIsCap`). Re-plan mutation (per-file backup and restore, hash identical; run against `AMMPoolReplan` + `AMMPoolMeasuredDeposit`): R1/R2 cap removed, killed (3 tests; they survive the older tests); R3/R4 `mulDiv` instead of saturating, killed (Z08 (iv)); R5/R6 re-plan only downward, killed (3); R7/R8 no re-plan, killed (6).
5b: L36. Excess mutation (run against `AMMPoolMaxExcess`): E1/E2 `>=` instead of `>`, killed (3 each); E3/E4 check removed, killed (2 / 3); E5/E6 floor instead of ceil for the matched amount, killed (2 each); E7 limits swapped between tokens, killed (3).
5c: Z08 (i), (iii), (iii-b), differential oracle, Z09. Oracle validation mutants (run against `AMMPoolMeasuredDifferential` alone): shares max instead of min, killed; shares without saturation, killed; saturation returning 0, killed; reserve += net − 1, killed; checked supply removed, killed; minShares ignored, killed; re-plan cap removed, killed; re-plan only downward, killed; step-2 `>=` instead of `>` (C7), survives this file (fuzz never hits T1 = cap1 exactly), killed by `test_Z06_extremeCapCorners` and `test_Z07_zeroSharesReverts`. Not an equivalent mutant: r = (3, 2) with request (2, 1) pulls (2, 1) originally and (1, 1) under the mutant.
5d: L13b, redefined. Assumptions A1–A5 are in the test file's header. The donation channel in the multi-victim cases is free (a fee-mock bonus), which is the attacker-favourable bound. Model results (same steps, A = 1e6, D = 1e25 per token, later deposits w ∈ [1e21, 1e21 + 2^64 − 1]). The LCG output is below 2^64, so the `% (1e22 − 1e21 + 1)` in the test never reduces it; the earlier label "[1e21, 1e22]" was wrong. For the 5,000-deposit runs, Σw ≈ 5.046e24 is the total token0 request. The model uses the same LCG, seed and formula as the test:

- break-even at about 2,380 victims with unbounded victim excess;
- with 5,000 victims the attack stays profitable up to a victim tolerance of 100 bps and becomes unprofitable at 50 bps or below, at the cost of rejected deposits;
- profit grows with D (5,000 victims: D = 1e24 → −2.2e20; 3e24 → +2.8e21; 3e25 → +1.0e23).

Attacker gas for its four transactions: 815,882 (with donation), 492,873 (without). **Finding:** the earlier THREAT_MODEL T4 sentence "donating never increases profit" holds for one victim only; for many victims the attacker's gain from rounding grows with N while the donation's cost (the lock's share, about 1000·Δ) is fixed. Decision (2026-11-22): recorded as a known economic limitation in the revised THREAT_MODEL T4 (book shortfall vs executable redemption: T6). The attacker's gas is recorded but not deducted from the P&L.
5e: L31, L33, L34, L35, L39, L40 (full chain), L41.
5f: limitation tests B10, X06 (A/B/C), X07. One expectation error found and corrected in the test (not the contract): a full withdrawal under an exclusive outbound extra fails inside the token before A8 can run.

### 3.4 M8 F1 follow-up tests (F1-T1 to T9; scope approved 2026-11-23)

Required by the student after F1 was closed as a known economic limitation (THREAT_MODEL T4, T6). Limitation: the literal constants in these tests come from Python models kept outside the repository (session scratchpad), so they cannot be regenerated from the repository; the tests also recompute key values with MulDiv512 where stated. Tidying the models into the repository is an optional M11 item. `maxExcess` keeps its absolute meaning (DECISIONS M8-2). Every expected value comes from an independent model or a separate mathematical claim, never only from a replay of the Pool's code. Order of implementation: T1, T2, T5, T6, T7, T8, T9, T3; one commit per group.

| ID | Description | Status |
|---|---|---|
| F1-T1 | Tier 0 later deposit with an extremely unbalanced request: (a) exactly two `transferFrom` calls, in the caller's pull order, with the step-2 targets (`vm.expectCall` with exact calldata and count 1, plus the order of the `Transfer` events); (b) `u_i < r_i/S + r_i/r_j`, checked as `u_i·S·r_j < r_i·(r_j + S)` in 512 bits (proof in the test header); (c) `maxExcess_i = u_i` passes and `u_i − 1` reverts `ExcessContributionTooHigh` with no state change; the opposite extreme request floors a target to 0 and reverts `InsufficientDepositAmount` with no `transferFrom` from the payer | `PASSED` — `test/AMMPoolF1ExtremeRequest.t.sol` (16 tests). Fixed cases: six reserve shapes (including the P3 state (1100, 909,338,911), S = 1e6 and ratios 2^100 : 1e4) × caps (1, 1e30) / (1e30, 1) × both pull orders, plus a step-2 tie at a 1e30 cap; constants from an independent integer Python model. Fuzz `testFuzz_F1T1_extremeRequest` against `test/utils/MulDiv512.sol` (no OpenZeppelin `mulDiv`): initial amounts [1e3, 2^120], one optional swap [1, 2^120], caps [1, 1e30] with two modes forcing one cap in [1, 1e3] and the other in [1e27, 1e30]; about 42% of inputs reach the success path with u > 0 (measured with a temporary copy). Uncovered: taxed tokens (re-plan) and saturated σ (Z08). Mutation (per-file backup and restore, hash identical; run against this file alone): later path ignores `token1First`, first pull uses the cap, step-2 division by the wrong reserve, shares max instead of min, excess `>=`, floor instead of ceil, token1 compared with `maxExcess0`, re-plan forced in either order: all killed. Step-2 `>=` instead of `>` (C7) survived the first version and is killed by the added tie case |
| F1-T2 | Surplus and deficit accounting under mixed sequences, per the M6 rule of each function (ARCHITECTURE §5.2–§5.5, BI-2 to BI-4). Scope: ordinary transfers arrive exactly; donations and slashes are separate test steps, never inside a Pool call. Signed `s_i = b_i − r_i` (negative = deficit). Transitions asserted: donate `s += x`; slash `s −= x` with a deficit only if afterwards `b < r`; successful later add, remove and swap keep `s` exactly; `sync` lowers only a deficit reserve to the balance (one `ReserveSynced` per deficit token) and never absorbs surplus; `skim` sends only a positive `s` (one `SurplusSkimmed` per surplus token) and keeps reserves and deficits; add, remove and both swaps with otherwise valid parameters revert `ReserveDeficit` with full rollback while either token is in deficit. In-call side effects are not re-derived here: for add, `s_after − s_before = (b_after − b_before) − net` with net measured inside the token's own transfer window (bonus channel counted in net: L13b; arrival outside it stays surplus: B08, B09b; in-call removal leaving `end − start < net` reverts `InCallBalanceLoss`: B09c, B09d); for swap and remove a foreign in-call gift stays surplus (B08), a masked foreign loss is not detected (B10, THREAT_MODEL T30) | `PASSED` — `test/AMMPoolF1SurplusAccounting.t.sol` (5 tests). Deterministic, from one initial surplus of 500 token0: slash 499 (s = 1), 500 (`b = r`, not a deficit) and 501 (deficit 1). For the deficit, the same add/remove/swap calldata reverts `ReserveDeficit` and then succeeds after either recovery: `sync` (reserve0 999,999) or an external top-up of 1 (reserve0 unchanged). Two-token case: token0 deficit 300 and token1 surplus 700, `sync` vs `skim` from the same state; each handles only its own token; the deposit (1e4, 3e4) succeeds after `sync` with (1e4, 20,006, 14,146) and is still blocked after `skim`; both paths execute `sync`, `skim` and one successful deposit, in the orders sync → deposit → skim and skim → (deposit and swap revert `ReserveDeficit`) → sync → deposit; the test asserts equal reserves, Pool balances, LP supply and surplusRecipient balances of both tokens at the end (LP holdings and carol's balances are not compared); in both paths the 700 token1 end at surplusRecipient and the Pool's token1 balance equals reserve1. Literal anchors from an independent Python model. Fuzz `testFuzz_F1T2_mixedSequence`: initial surplus in both tokens, 16 random steps (donate, slash biased to s − 1 / s / s + 1, deficit top-up, sync, skim, add in both orders, remove, both swaps) checked after every step against a shadow model (MulDiv512 and the §6.2–§6.4 formulas). Measured coverage over 300 seeds (temporary derived contract): slash below / equal / above surplus 110 / 76 / 107, deficit top-ups 50, sync with deficit 87, ReserveDeficit on add / remove / swap 83 / 90 / 154, successful add / remove / swap 460 / 441 / 890. Mutation (run against this file alone): sync absorbs surplus, sync emits without writing, skim `>=`, deficit check with `<=`, deficit check ignoring token0, deficit entry check removed from add / remove / swap, add and swap writing `reserve := balance`: all 10 killed. Uncovered: taxed tokens; terminal pools (slashes keep `b ≥ 1`; R14–R22) |
| F1-T3 | Reduced on-chain swap-fee channel with supported exact-delivery tokens (Tier 0 `MockERC20`). alice: initial deposit (1e6, 1e6), only LP besides the lock and only trader. Round trip k: input token0 for even k, token1 for odd k; swap c × the current input reserve, then swap the whole output back (1 round trip = 2 swaps); finally alice removes all her LP. After every swap: output, both reserves, Pool balances (= reserves) and LP supply (unchanged, 1e6) against an in-test §6.4 formula model; at the end: values from an independent Python model, and alice's wallet change = − what stays in the Pool, per token | `PASSED` — `test/AMMPoolF1SwapFeeChannel.t.sol` (4 tests). c = 1: 200 round trips (400 swaps): reserves before exit (1,350,041, 1,350,040), left in the Pool and alice's loss (1,351, 1,351); 2,000 round trips (4,000 swaps): (20,095,042, 20,095,155), loss (20,096, 20,096). c = 10: 200 (400 swaps): (1,727,288, 1,727,357), loss (1,728, 1,728); 2,000 (4,000 swaps): (235,642,086, 235,646,772), loss (235,643, 235,647). Gas (`gasleft()` around each top-level `swapExactInput` call, `vm.prank` before the first reading, `isolate = true` forge default so cold storage per call, as G03/G05; solc 0.8.38, optimizer 200, osaka, via_ir false, forge 1.9.0; two runs identical): per swap mean 84,768 (200 round trips) and 85,274 / 85,282 (2,000, c = 1 / 10), min 84,683, max 85,873; gas sum over the 4,000 measured calls 341,099,256 (c = 1) and 341,130,552 (c = 10). No 21,000 transaction base cost or calldata cost included. Boundaries of this evidence: (1) supported Tier 0 tokens, executed on the local Foundry EVM, at most 2,000 round trips = 4,000 swaps; (2) with alice as the only trader and only non-locked LP, her per-token wallet loss after exiting equals what stays in the Pool; (3) the round trips needed to reach 1e25 are a model estimate, and the capital need, execution and net profitability of the full P5 path remain unverified. Extrapolation (Python model only): average growth multiple per round trip 1.00150 (c = 1) and 1.00273 (c = 10), i.e. a growth rate of about 0.150 % and 0.273 %, computed as the geometric mean (token0 reserve before exit / 1e6)^(1/2000) over the same 2,000 round trips; reaching 1e25 would take about 29,161 / 16,019 round trips of this definition (58,322 / 32,038 swaps). THREAT_MODEL T4's model figures 58,288 / 32,040 "round-trip swaps" are close to these swap counts; the counting definition of the earlier model is unknown. Growth per round trip is not constant (it depends on the integer reserves), so this is not a measured result. Mutation (this file; AMMPool and AMMMath restored by hash): fee 31 bps, output rounded up, fee not retained in reserveIn, post-burn supply on withdrawal, output reserve lowered by out + 1: all killed. Full P5 scale remains model-only (F1-T4 deferred) |
| F1-T4 | Full P5 replay | **Deferred in this M8 round** (student, 2026-11-23); kept as a follow-up verification item. The full-scale P5 result (capital need, execution, net profitability) stays model-only |
| F1-T5 | Large unmatched amount in a reachable state, bounded by the absolute `maxExcess` in a real deposit. State by normal calls: initial deposit (1000, 1e9), swap 100 token0 in; deposit caps (max, 1e6), both pull orders. Tier 0: reserves (1100, 909,338,911), S = 1e6; net (1, 1,000,000); σ = 909; u = (0, 173,410); unmatched ratio u1/net1 = 17.3410 %. Tier 1 (token1 inclusive tax 10 %, fee burned; `MockTaxedERC20`): reserves (1100, 818,405,020), S = 948,683; payer debit (1, 1,000,000); tax burned 100,000; net (1, 900,000); σ = 862; u = (0, 156,374); unmatched ratio 17.3749 %. The tax is debit − net and never reaches the Pool; the unmatched amount is part of the net and comes from token0's single unit limiting σ. With token1 first, Tier 1 re-plans token0 to floor(900,000·1100/818,405,020) = 1. From the same pre-deposit state (`vm.snapshotState`), with `maxExcess0 = max`: `maxExcess1 = u1 − 1` reverts `ExcessContributionTooHigh` and `u1` succeeds; also (0, u1) succeeds. Book shortfall and redemption loss are F1-T6 | `PASSED` — `test/AMMPoolF1LargeRelativeLoss.t.sol` (5 tests). Expected values from an independent integer Python model. The failed call restores both reserves, LP supply and all LP holdings (lock, alice, bob), the payer's and the Pool's balances of both tokens, alice's balances, and both token total supplies (the burned tax is rolled back). On success: nets, σ, matched amounts (MulDiv512 ceil), payer debits, burned tax, reserve increase = net (X1) asserted. Mutation (run against this file): token1 excess `>=`, check removed, floor instead of ceil, compared with `maxExcess0`, X2 (only the matched part enters reserve1), σ from token1 only: killed; excess computed from the gross request cap instead of net: killed by the Tier 1 cases only. Skipping the token1-first re-plan survives this file (equivalent in this state: the re-plan gives the same pull) and is killed by L32 and Z08 (iv) (`test/AMMPoolReplan.t.sol`). Absolute amount vs ratio: Tier 1 has the smaller u1 (156,374 < 173,410) but the slightly higher unmatched ratio (17.3749 % > 17.3410 %), because its net1 is smaller. Not tested: a taxed token0. `MockTaxedERC20` charges floor(g·t/10,000), so a 1-unit transfer pays no tax for any t < 10,000; in this state the 1-unit token0 pull would arrive in full, with no re-plan (Python model only, not executed) |
| F1-T6 | Book entitlement vs executable immediate redemption. Per token, for σ minted from net n at pre-deposit r, S: exact book claim C = σ·(r + n)/(S + σ); book shortfall n − C = (n·S − σ·r)/(S + σ) (= S/(S+σ)·(u + δ)); redemption rounding C − floor(C) ∈ [0, 1); actual shortfall vs the Pool's net n − floor(C). floor(C_i) is the Pool-side redemption gross (the Pool's balance decrease, = reserve decrease); it is paid only if the redemption is the next Pool call, both reserves are positive and both floor(C_i) ≥ 1 (else `InsufficientLiquidityBurned`). The wallet receipt is recorded from the recipient's actual balance change; it equals floor(C_i) only when the outbound transfer arrives in full (Tier 0). Inbound and outbound taxes are listed separately | `PASSED` — `test/AMMPoolF1Redemption.t.sol` (4 tests). Failure (Tier 0, F1-T5 state, caps (max, 1e6), σ = 909): gross floor(C) = (0, 826,746) from C = (1,000,809, 827,498,070,099)/1,000,909 → `InsufficientLiquidityBurned`; bob keeps 909 LP; no `transfer` call on either token; reserves, LP supply and holdings, Pool, payer and recipient balances and token supplies unchanged. The second example, (0, 909,082) at (1100, 1e9) with S = 1e6, is checked in the Python model only (state not constructed). Success (Tier 0, caps (max, 1e7)): net (12, 10,000,000), σ = 10,909; book numerators (100, 80,021,819,901) over 1,010,909, i.e. book shortfall (0.000099, 79,158.28); rounding (0.999901, 0.7178); Pool-side gross floor(C) = (11, 9,920,841), and the wallet receipt from the balance change is the same (Tier 0); actual shortfall (1, 79,159). Success (Tier 1, token1 tax 10 %, caps (max, 1e7)): debit (13, 10,000,000), inbound tax 1,000,000, net (13, 9,000,000), σ = 10,432; Pool-side gross out floor(C) = (12, 8,999,430); Pool net minus redemption gross (1, 570); outbound tax 899,943; wallet receipt from the balance change (12, 8,099,487). Fuzz `testFuzz_F1T6_immediateRedemption` (Tier 0; initial [1e3, 2^100], optional swap, caps [1, 1e30] in five modes, two with a cap of exactly 1): prediction with MulDiv512; failure branch asserts revert, rollback, kept shares, no transfer; success branch asserts that the recipient's balance change (Tier 0, = Pool-side gross) equals floor(C) and 0 ≤ (n − receipt)·(S+σ) − (n·S − σ·r) < S + σ. About 16 % of inputs reach the failure branch (temporary copy). Mutation (this file): token0 zero-output check removed, zero-output rule reduced to both-zero, token1 rounded up, post-burn supply, X2 reserve, mint σ + 1: all killed. Uncovered: redemption after later state changes; taxed token0 |
| F1-T7 | `minShares` protects a depositor whose share quote was taken before the Pool state changed (complements L13b, where the quote was taken after the inflation). Scenario: initial deposit (1e6, 1e6); bob's quote for caps (1e21, max), token0 first; then two L13b bonus donations of D = 1e25 per token (unsupported bonus behaviour, assumption A3); bob's deposit with unchanged parameters; `maxDebit` and `maxExcess` unbounded | `PASSED` — `test/AMMPoolF1QuoteProtection.t.sol` (1 test). Independent Python model and MulDiv512 quote: q_before = 1e21 (minShares = q_before succeeds at the quote state and mints 1e21); changed state r = (10,000,009,999,990,000,010,999,993, 10,000,000,000,000,000,001,000,002), S = 1,000,002; q_after = 100, so 0 < q_after < q_before. From the same changed state: minShares = q_before reverts `InsufficientShares` with full rollback (reserves, LP supply and holdings, Pool and payer balances of both tokens, token supplies); minShares = q_after + 1 also reverts; minShares = q_after succeeds and mints exactly 100 with net (1e21, 999,999,000,001,999,996,000). Not claimed: that the re-quoted deposit is fair (its loss is L13b / F1-T6). Mutation (this file): `<=` instead of `<`, minShares ignored, shares max instead of min, requested instead of measured pull, `shares − 1 < minShares`: all killed |
| F1-T8 | The same 50 deposits held and redeemed by one address (merged) vs by 50 addresses (each its own). L13b scenario (A1–A3: initial (1e6, 1e6), two free bonus donations D = 1e25 per token), deposits caps (w_k, max) with w_k from the L13b LCG (seed 2026), token0 first, unbounded `maxDebit` / `maxExcess`; identical amounts, order and parameters in both groups; alice removes all her LP after the deposits in both groups; then one merged redemption vs 50 redemptions in deposit order, each at the reserves and supply left by the previous one | `PASSED` — `test/AMMPoolF1DistributedVictims.t.sol` (1 test). Independent Python model plus an in-test MulDiv512 step model (never reads the Pool's reserves after the start). Deposit phase identical: users paid (50,411,394,302,409,418,842,469, 50,411,343,891,115,939,019,985), 5,018 shares (100 or 101 each), reserves (10,050,421,394,292,409,429,842,462, 10,050,411,343,891,115,940,019,987), S = 1,005,020. alice receives (9,990,240,068,596,550,919,615,011, 9,990,230,078,376,462,763,240,380) in both groups; her wallet P&L with the free bonus is positive, with D counted as paid (A3) it is (−9,769,931,393,449,091,384,982, −9,769,921,623,537,237,759,622). Users receive: merged (50,181,105,407,414,091,778,223, 50,181,055,226,409,046,374,221); individual (…778,220, …374,215); merged − individual = (3, 6) smallest units, left in the Pool behind the 1,000 locked LP. Users' total loss: merged (230,288,894,995,327,064,246, 230,288,664,706,892,645,764), individual 3 and 6 units more. Per-user loss in the individual group: token0 min 43,974,487,781,985,612 (v_30), max 9,331,871,098,641,087,073 (v_49); token1 min 43,974,443,807,585,779 (v_30), max 9,331,861,766,788,652,136 (v_49). No redemption reverts. Mutation (this file): withdrawal rounding up, post-burn supply, mint σ + 1, reserve not lowered on withdrawal: all killed. Scope: one deposit sequence, one redemption order, the bonus channel |
| F1-T9 | Honest LP present before the inflation vs none, full L13b scale on-chain (A1–A5, D = 1e25, 5,000 deposits with unbounded `maxExcess`; exit order alice, bob, then the honest LP). The earlier "1 % honest LP" model is recorded only as one sentence in THREAT_MODEL T4, so its baseline is defined here: carol deposits (10,101, 10,101) after alice's initial deposit and before the donations and receives 10,101 shares (proportional deposit at r = (1e6, 1e6), S = 1e6); fraction 10,101 / 1,010,101 = 0.99999901 % of total supply including the 1,000 locked LP (1.00099 % excluding it), 10,101 / 1,010,103 after the donations, 0.66590 % after the deposits | `PASSED` — `test/AMMPoolF1HonestLP.t.sol` (2 tests). Independent Python model; per token, wallet = balance change, A3 = wallet − D (the bonus is minted to the Pool for free). Control group (aligned with L13b): alice A3 (+9,083,016,484,294,218,244,145, +9,083,007,401,295,899,944,530), positive in each token, sum = the L13b aggregate +18,166,023,885,590,118,188,675; wallet (10,009,083,016,484,294,218,244,145, 10,009,083,007,401,295,899,944,530). With the honest LP: alice A3 (−91,153,837,011,029,980,641,690, −91,153,746,768,909,116,702,138), negative in each token; change (−100,236,853,495,324,198,885,835, −100,236,754,170,205,016,646,668); honest LP P&L (+100,189,344,057,522,994,307,908, +100,189,244,870,267,776,252,902); bob's loss (18,954,262,026,942,770,553,458, 18,954,243,262,260,330,302,473) vs (19,102,108,554,654,732,266,384, 19,102,089,452,584,381,750,317) without. Mutation (this file): X2 reserve, withdrawal rounding up, mint σ + 1, σ from token0 only: all killed. Scope: one honest-LP size and timing, one deposit sequence, the bonus channel; THREAT_MODEL T4's sentence still says "modelled" and is updated at the pre-acceptance doc check |

## 4. Withdrawal (M4, M5, M8)

| ID | Description | Milestone | Status |
|---|---|---|---|
| W01 | Proportional redemption matches ARCHITECTURE §6.3 | M4 | `PASSED` (M4) — `test_W01_proportionalRedemption`, `testFuzz_W01_redemptionMatchesFormula` |
| W02 | Only the caller's own shares are burned; a transferee can redeem transferred LP | M4 | `PASSED` (M4) — `test_W02_onlyCallersSharesBurned` |
| W03 | Zero shares, shares above balance, or a zero output reverts | M4 | `PASSED` (M4) — `test_W03_zeroSharesReverts`, `test_W10_classA_*`, `test_Z07_zeroOutputBoundary` |
| W04 | MIN-NET: recipient receiving exactly `min_iNet` succeeds; one unit less reverts | M4 | `PASSED` (M4) — `test_W04_minNetBoundaryToken0`, `test_W04_minNetBoundaryToken1` |
| W05 | Taxed output: minima judged on recipient's actual receipt; LP burned, reserve decrease, event `amount_i`, return `net_i` and recipient balance change all checked (DECISIONS M4-5, moved from M8) | M4 | `PASSED` (M4) — `test_W05_taxedToken0Output`, `test_W05_taxedToken1Output` |
| W06 | After the last redeemable LP exits, the Pool still holds exactly 1000 LP and reserves > 0 | M4 | `PASSED` (M4) — `test_W06_lastLPExitsLockRemains` (also: a new deposit afterwards succeeds) |
| W07 | Reentrancy during withdrawal is blocked: token callback in the outbound `transfer` re-enters `removeLiquidity`; bubbling, caught + correct transfer, caught + faulty transfer (DECISIONS M5-6) | M5 | `PASSED` (M5) — `test_W07_X01_removeCallback_bubbling`, `test_W07_X01_removeCallback_caughtCorrect`, `test_W07_remove_caughtFaulty_*` (A8, MIN-NET) |
| W08 | `recipient ∈ {address(0), Pool}` reverts | M4 | `PASSED` (M4) — `test_W08_invalidRecipientReverts`, `test_W08_deadlineBoundary`, `test_W08_checkOrder` |
| W09 | Atomicity: token1's outbound transfer fails (revert, `false`, over-debit) after token0 was sent → whole call reverts; caller LP, `totalSupply`, reserves and all token balances (incl. token0 at Pool and recipient) unchanged (DECISIONS M4-4) | M4 | `PASSED` (M4) — `test_W09_token1TransferRevertRollsBackToken0`, `test_W09_token1ReturnsFalseRollsBackToken0`, `test_W10_classB_W09_overDebitToken1RevertsAndRollsBackToken0` |
| W10 | Failure classes distinguished by exact error: insufficient LP before withdrawal (`ERC20InsufficientBalance`, incl. `shares = type(uint256).max` and `shares = S`); Pool-side anomaly after transfer (`OutboundTransferMismatch`); recipient shortfall (`InsufficientNetReceived`) (DECISIONS M4-3) | M4 | `PASSED` (M4) — `test_W10_classA_insufficientLPBeforeWithdrawal`, `test_W10_classB_*` (2), class C in `test_W04_*`, `test_W05_*` |
| W11 | Lock untouched: after every successful withdrawal the Pool holds exactly 1000 LP; no withdrawal path burns Pool-held LP | M4 | `PASSED` (M4) — asserted in every successful-withdrawal test; `test_W11_poolHeldLPCannotBeRedeemed` (Pool as `msg.sender` → `LockedLiquidity`) |
| W12 | (M10 P2) Small position below the redemption threshold: with `r_i/S < 1`, fewer than `⌈S/r_i⌉` shares cannot be redeemed (token-i amount floors to 0 while `r_i > 0` → `InsufficientLiquidityBurned`, M4-3r; as Uniswap V2) | M10 | `PASSED` (M10) — `test/AMMPoolSmallPosition.t.sol` `test_W12_positionBelowThresholdCannotExit` (Tier 0, 2- and 18-decimal tokens, both deployment orders so the 2-decimal token is token0 once and token1 once; expected values from an integer model). alice deposits (10,000, 1e20) units (100.00 and 100 tokens), S = 1e12, `S/r2` = 1e8; bob deposits (2, 2e16) → σ = 2e8; a partial exit of 1.5e8 returns (1, 1.5e16) and leaves 5e7 shares; with S = 1,000,050,000,000 and r2 = 10,001 the threshold is 99,995,001, so the full exit of 5e7 reverts with state unchanged (book claim 0.5 unit and 0.005 token); after receiving 49,995,001 shares bob exits 99,995,001 for (1, 9,999,500,100,000,000). Mutation check (per-file restore, hash verified): zero-amount check removed for token0, for token1: 2/2 killed (the token0 mutant survived until both deployment orders were added: a test gap, now closed) |

## 5. Swap (M5, M6, M8)

### 5.0 M5 results (2026-11-19, branch `m5-swap`)

208 tests passing (`forge test`); new in M5: `AMMPoolSwap` 37, `AMMPoolReentrancy` 17, `AMMPoolOwnerless` 5, `SwapMocks` 8. Mutation checks (scratchpad script, source always restored): 11 deliberate bugs — each `nonReentrant` removed, `fallback` or `owner()` added, `out + 1` paid, MIN-NET ignored, `amountIn` used instead of measured `a` (event and reserve), `out == 0` check removed, `tokenIn` / `amountIn` check order swapped — each one makes at least one test fail. The measured-`a` reserve mutation initially survived and was killed by adding `test_M5_measuredInputUsedInBothDirections`.

**Safety vs. supported range (DECISIONS M5-7):**

| Test | Success asserted over | Safe revert asserted for | Not covered |
|---|---|---|---|
| Z01 / S11 / S15 fuzz | reserves in `[1, 2^112]` with `r0·r1 ≥ 1001²`; `a` in `[1, 2^112]`; both directions | inputs with floored `out = 0` → `InsufficientOutputAmount` | reserves or `a` above `2^112` (only the Z06 points); reserve pairs below `1001²` other than reference case 3 |
| Q01 fuzz | same as Z01 | — (zero-output inputs belong to Q04) | same as Z01 |
| Q04 fuzz | — | class-B inputs (`rIn` in `[1001, 2^112]`, `rOut ≤ rIn`): quote returns 0, swap reverts with full rollback | class-B inputs with `rOut > rIn` |
| Z06 swap | one point: `rIn = rOut = 10^6`, largest `a` with `rIn·D + a·9970 ≤ 2^256 − 1` | `a + 1`, and `a = ⌊(2^256 − 1)/9970⌋ + 1` → Panic `0x11`, full rollback | other reserve sizes near the threshold; shows only safe failure, not that every `uint256` input can trade |
| X03 unknown selector | — | 256 random selectors (approved selectors excluded) | selectors not sampled |

| ID | Description | Milestone | Status |
|---|---|---|---|
| S01 | Swaps work in both directions | M5 | `PASSED` (M5) — `test_S01_S02_referenceCase1Token0In/Token1In`, `test_S01_bothDirectionsSequentially`, `test_M5_measuredInputUsedInBothDirections` |
| S02 | Reference case 1: `1,000,000 / 1,000,000`, `a = 10,000` → `out = 9,871` | M5 | Maths level `PASSED` (M2); Pool swap `PASSED` (M5) — `test_S01_S02_referenceCase1Token0In/Token1In` |
| S03 | `amountIn = 0` and zero reserves revert; floored `out = 0` (reference case 3): `AMMMath` returns 0 but `swapExactInput` must revert `InsufficientOutputAmount` (DECISIONS M2-5r) | M5 | Maths level `PASSED` (M2); Pool swap `PASSED` (M5) — `test_S03_zeroAmountInReverts`, `test_S03_zeroReservesRevertBeforeTransfer`, `test_S03_referenceCase3ZeroOutputReverts`, `test_S03_measuredZeroInputReverts` |
| S04 | MIN-NET: `minNetAmountOut = out` succeeds, `out + 1` reverts; expired deadline reverts | M5 | `PASSED` (M5) — `test_S04_minNetBoundary`, `test_S04_deadlineBoundary` |
| S05 | Taxed input: pricing and accounting use measured net | M10 | `PASSED` (M10) — `test/AMMPoolTaxedSwapRemove.t.sol` `test_S05_taxedInputPricedOnMeasuredNet` (U8 mock, 2.5 %: payer debited exactly `g`, `a = g − floor(g·250/10000)`, output priced on `a` and shown to differ from pricing on `g`, `reserveIn += a`, `Swap.amountIn = a`, surplus unchanged); both-taxed fuzz in Z04. Moved from M8 to M10 at the M8 acceptance (student, 2026-11-23) |
| S06 | Taxed output: minimum judged on recipient's actual receipt (e.g. min 100, receives 99 → revert) | M10 | `PASSED` (M10) — `test/AMMPoolTaxedSwapRemove.t.sol` `test_S06_taxedOutputMinNetBoundary`: `min = net + 1` reverts `InsufficientNetReceived` with full rollback although `out > net + 1`; `min = net` succeeds, `reserveOut −= out`, A8 on `out`. Earlier partial evidence from M5: `test_M5_3_eventFieldsAreDistinct` (taxed output, `min = netOut` succeeds) and `test_S08_swapOutbound_caughtFaulty_shortDeliveryRejectedByMinNet` (short delivery → `InsufficientNetReceived`). Moved from M8 to M10 at the M8 acceptance (student, 2026-11-23) |
| S07 | Pre-existing surplus is not counted as input and is unchanged after the swap | M6 | `PASSED` (M6) — `test_S07_surplusNotCountedAsSwapInput` (both directions) |
| S08 | Reentrancy during swap is blocked: callback in the inbound `transferFrom` and in the outbound `transfer` re-enters `swapExactInput`; bubbling, caught + correct transfer, caught + faulty transfer (DECISIONS M5-6) | M5 | `PASSED` (M5) — `test_S08_X01_swapInboundCallback_*`, `test_S08_X01_swapOutboundCallback_*`, `test_S08_swap*_caughtFaulty_*` (A8; MIN-NET on short output and on short input) |
| S09 | A failed swap leaves no state change: recorded reserves, Pool token balances, user token balances, LP `totalSupply` / LP balances and allowances all equal their pre-call values (DECISIONS M5-6) | M5 | `PASSED` (M5) — every revert test in `test/AMMPoolSwap.t.sol` (helper `_expectSwapRevert` compares 14 quantities) |
| S10 | 0-bps reference (9,900) vs. 30-bps result (9,871); the difference remains in reserves | M5 | `PASSED` (M5) — `test_S10_feeDifferenceStaysInReserves` |
| S11 | Fee-adjusted inequality holds after every successful swap (unit + fuzz in `[1, 2^112]`) | M5 | Maths level `PASSED` (M2); per swap `PASSED` (M5) — asserted in every successful swap via `_checkedSwap`, and `testFuzz_Z01_S11_S15_swapMatchesFormula` |
| S12 | `recipient ∈ {address(0), Pool}` reverts `InvalidRecipient`; `tokenIn` outside the pair reverts `InvalidTokenIn`; check order of DECISIONS M5-1 | M5 | `PASSED` (M5) — `test_S12_invalidRecipientReverts`, `test_S12_invalidTokenInReverts`, `test_S12_checkOrder` |
| S13 | After several swaps, redeeming all LP returns a larger `amount0 × amount1` than deposited (fees accrue to LPs) | M5 | `PASSED` (M5) — `test_S13_feesAccrueToLPs` |
| S14 | Reference cases 2, 4 and 5 (499,248; 1,992,013; 498,251,621,566,649,025) | M5 | Maths level `PASSED` (M2); Pool swap `PASSED` (M5) — `test_S14_referenceCase2`, `test_S14_referenceCase4_18In6Out`, `test_S14_referenceCase5_6In18Out` |
| S15 | Implementation output equals the reference formula exactly (fuzz); `out + 1` violates the inequality for reference cases | M5 | Maths level `PASSED` (M2); Pool swap `PASSED` (M5) — `testFuzz_Z01_S11_S15_swapMatchesFormula` (exact equality and `out + 1` tightness on every fuzz input) |

## 6. Reserves, `sync()`, `skim()` (M2, M6, M8)

### 6.0 M6 results (2026-11-19, branch `m6-sync-skim`)

275 tests passing (`forge test`, and again with `FOUNDRY_FUZZ_RUNS=10000`); configuration per §14 (checked with `forge config`). New in M6: `DeficitMock` 4, `AMMPoolSync` 8, `AMMPoolDeficit` 12, `AMMPoolTerminal` 14, `AMMPoolSkim` 14, `AMMPoolSyncSkimScenarios` 5, `AMMPoolSyncSkimReentrancy` 10. Revert tests compare the exact revert bytes and a 20-quantity snapshot (reserves, LP supply, Pool / alice / bob LP, Pool / alice / bob / carol / `surplusRecipient` token balances, alice / bob allowances) before and after (`test/utils/PoolStateFixture.sol`).

**Mutation check (DECISIONS M6-6;** scratchpad script, `src/` restored byte-for-byte**):** 16 mutants, all killed — `_checkNoDeficit` removed from add / remove / swap (each separately); `<` → `<=` for token0 and for token1; `sync` absorbs surplus; `sync` writes and emits on a no-op; `skim` reverts as a whole when one token is in deficit; `skim` absorbs surplus into the reserve; `skim` without A8; zero-reserve side skips MIN-NET; M4-3r loosened to "only all-zero reverts"; M4-3r allowing the all-zero withdrawal; terminal-pool deposit check removed; `nonReentrant` removed from `sync`; from `skim`. In the G03 benchmark (§14.3), three B variants that reuse the **second** token's stale snapshot were each caught by B08.

**Safety vs. supported range (DECISIONS M5-7):**

| Test | Success / property asserted over | Safe revert asserted for | Not covered |
|---|---|---|---|
| B05 fuzz | seeded reserves `(1e6, 2e6)`; per token a deficit `0..reserve` or a surplus `0..2^128` | — | other reserve sizes |
| R08 fuzz | — | deficits `1..reserve` in token0, token1 or both → `ReserveDeficit`, full rollback, for add, remove, both swaps | other reserve sizes; deficits created inside the same transaction by a token hook |
| R10 / B04 fuzz | per token normal, deficit `1..reserve`, surplus `1..2^128` | — | surplus above `2^128` |
| R15 fuzz | — | caps `1..2^256 − 1` with either reserve 0 → `InsufficientLiquidity`, never a Panic | — |
| R16 fuzz | shares `1..` alice's LP in a terminal pool with the seeded non-zero reserve | shares whose non-zero amount rounds to 0 → `InsufficientLiquidityBurned` | other non-zero reserve sizes |
| R17 fuzz | 12-step random sequences: donations `1..1e24`, slashes up to half the balance, sync, skim, swaps `1,000..1e6` | swaps with any deficit → `ReserveDeficit` | sequences that reach a zero reserve (terminal states are covered by R14–R22 unit tests); add / remove inside the sequence |
| R03 fuzz | any caller except 0, the Pool and `surplusRecipient`; surplus `1..2^128` per token | — | taxed recipient (R09, M8) |

v0.3's R05, R06 and R10 tested the `sync`/`skim` race. That race no longer exists under Gate R=(b), so they are redefined.

| ID | Description | Milestone | Status |
|---|---|---|---|
| R01 | `getReserves()` returns recorded reserves; unchanged by a direct transfer | M2 | `PASSED` — `test_R01_directTransferDoesNotChangeReserves` (M2), `test_R01_directTransferAfterDepositDoesNotChangeReserves` (M3) |
| R02 | Any address can call `sync()` | M6 | `PASSED` (M6) — `testFuzz_R02_anyoneCanSync` |
| R03 | `skim()` sends all surplus to `surplusRecipient`; reserves and price unchanged | M6 | `PASSED` (M6) — `testFuzz_R03_R04_skimSendsAllSurplus` (any caller; surplus 1..2^128 per token; reserves and quote unchanged) |
| R04 | `skim()` takes no recipient parameter; caller's balance does not increase | M6 | `PASSED` (M6) — `testFuzz_R03_R04_skimSendsAllSurplus` (caller gains nothing), `test_R04_noRecipientParameter` |
| R05 | `sync()` with surplus leaves reserves and surplus unchanged | M6 | `PASSED` (M6) — `test_R05_surplusNotAbsorbed` (no storage write, no event), `test_syncDeficitAndSurplus` |
| R06 | Direct transfer → `skim()` → `sync()`: surplus reaches the recipient; `sync()` is a no-op | M6 | `PASSED` (M6) — `test_R06_skimThenSyncIsNoOp` |
| R07 | Historical surplus is not counted as input to later add or swap | M6 | `PASSED` (M6) — `test_R07_B01_surplusNotCountedAsDepositInput`, `test_S07_surplusNotCountedAsSwapInput` |
| R08 | Deficit: add, remove and swap revert; `sync()` lowers reserves and emits an event; operations resume afterwards | M6 | `PASSED` (M6) — `test_R08_*` (11) and `testFuzz_R08_anyDeficitBlocksAll` in `test/AMMPoolDeficit.t.sol`: token0 / token1 / both, deficit plus other-token surplus, `balance == reserve` passes and `reserve − 1` reverts, check order per function, resume after `sync()`, initial path and quote unaffected; `test_syncDeficitToken1EmitsOneEvent`, `test_syncBothDeficitsTwoEventsInOrder` |
| R09 | Taxed token: `skim()` lowers the Pool balance by exactly the surplus; reserves unchanged | M10 | `PASSED` (M10) — `test/AMMPoolTaxedSkim.t.sol`: `test_R09_taxedSkimExactPoolSideRecipientReceivesLess` and `testFuzz_R09_taxedSkim` (surplus per token [0, 1e27]; both tokens U8 taxed, 1 % / 3 %). Key assertions: the Pool's balance falls by exactly `x_i = balance_i − reserve_i` per token (A8, Pool side); `SurplusSkimmed(token, x_i)` with the Pool-side amount, only for tokens with surplus; reserves unchanged; afterwards `balance_i == reserve_i`; `surplusRecipient` receives `x_i − floor(x_i·t_i/10000)` (< `x_i`, not measured by the Pool, T16); a second `skim()` emits nothing. Default and 10,000 runs passed. Mutation check: surplus + 1 sent, event with the balance: killed; skim's A8 check removed: survives R09 (U8 mocks debit the Pool exactly, so the check never fires in this token model) and is killed by `test_B06_overDebitRejectedByA8` (`AMMPoolSkimTest`). Also asserted inside the taxed invariant campaign (`AMMPoolHandler.skim`). Moved from M8 to M10 at the M8 acceptance (student, 2026-11-23) |
| R10 | Order independence: transfer → `sync()` → `skim()` and transfer → `skim()` → `sync()` reach the same final state | M6 | `PASSED` (M6) — `testFuzz_R10_orderIndependence` (each token normal / deficit / surplus) |
| R11 | `skim()` without surplus and `sync()` without deficit return normally and change nothing | M6 | `PASSED` (M6) — `test_R11_syncNoOpAndRepeated`, `test_R11_skimNoOpAndRepeated` (`vm.record`: no storage write; no event; full snapshot unchanged) |
| R12 | A failing `skim()` transfer reverts `skim()` only; swap, add and remove still work | M6 | `PASSED` (M6) — `test_R12_failingSkimRevertsOnlySkim` (token refuses the transfer to `surplusRecipient`: neither token skimmed; swap both ways, add, remove still work), `test_R12_falseReturnRevertsSkim` |
| R13 | A2: token1 in deficit and token0 with surplus → `skim()` sends token0's surplus and leaves token1 untouched | M6 | `PASSED` (M6) — `test_R13_deficitDoesNotBlockOtherSurplus`, `test_R13_mirror`, `test_R13_bothDeficitIsNoOp` |

| R14 | `sync()` lowers one reserve to 0 while `totalSupply > 0` (DECISIONS M4-6) | M6 | `PASSED` (M6) — `test_R14_syncLowersReserveToZero` |
| R15 | After R14 (terminal pool, DECISIONS M6-1): later deposits revert `InsufficientLiquidity` before any transfer, never a division-by-zero Panic; swaps and quotes revert `InsufficientLiquidity` | M6 | `PASSED` (M6) — `test_R15_token0ZeroBlocksDepositAndSwap`, `test_R15_token1ZeroBlocksDepositAndSwap`, `testFuzz_R15_depositNeverPanics` |
| R16 | After R14, zero reserve + normal other side: `removeLiquidity` pays 0 of the zero-reserve token and the proportional amount of the other (M4-3r); LPs recover the remaining asset | M6 | `PASSED` (M6) — `test_R16_token0ZeroRecoversToken1`, `test_R16_token1ZeroRecoversToken0` (two LPs), `testFuzz_R16_partialRecovery` |
| R17 | Transitions between deficit, surplus and normal balance states (each token independently) reach the specified state | M6 | `PASSED` (M6) — `test_R17_transitionSequence`, `testFuzz_R17_randomTransitions` |
| R18 | Terminal pool, `min_iNet > 0` on the zero-reserve side → `InsufficientNetReceived`, full rollback (slippage protection not bypassed) | M6 | `PASSED` (M6) — `test_R18_minNetOnZeroSideReverts`, `test_R18_minNetOnZeroSideRevertsToken1`, `test_R18_minNetBoundaryOnNonZeroSide` |
| R19 | Non-zero reserve whose `amount_i` rounds to 0 still reverts `InsufficientLiquidityBurned`, in a normal and in a terminal pool (M4-3 not loosened) | M6 | `PASSED` (M6) — `test_R19_roundingToZeroRevertsInNormalPool`, `test_R19_roundingToZeroRevertsInTerminalPool` |
| R20 | Both reserves 0 (`S > 0`) → `removeLiquidity` reverts `InsufficientLiquidityBurned` | M6 | `PASSED` (M6) — `test_R20_bothReservesZeroReverts` |
| R21 | Terminal pool with surplus in the zero-reserve token (and in the other token): withdrawal pays only reserve-based amounts; both surpluses unchanged; `skim()` still sends them | M6 | `PASSED` (M6) — `test_R21_terminalWithdrawalLeavesSurplus`, `test_R21_skimInTerminalPool` |
| R22 | Last redeemable LP exits a terminal pool: Pool still holds exactly 1,000 LP; the reserves backing the lock remain (documented limitation) | M6 | `PASSED` (M6) — `test_R22_lastLPExitsTerminalPool` |
| R23 | (M10 item 2) Mixed state: one token in deficit, the other with surplus, explicit `sync()` kept (student, 2026-11-23) | M10 | `PASSED` (M10) — `test/AMMPoolMixedDeficitSurplus.t.sol`: `test_R23_mixedDeficit0Surplus1`, `test_R23_mixedDeficit1Surplus0`, `test_R23_lossOnlyInDeficitTokenProRata`. Seed (1e6, 2e6), deficit 200,000, surplus 500,000. Asserted: add / remove / both swaps revert `ReserveDeficit` with full rollback, also after a `skim()` that sent the surplus (nothing of the deficit token); `sync()` lowers only the deficit reserve and emits exactly one `ReserveSynced(token, previous, new)`; the surplus token's reserve and surplus are unchanged; afterwards both swaps, a deposit and a full withdrawal change reserves only by their own amounts and leave the surplus exactly as donated; the withdrawal is reserve-based, so the loss falls only on the deficit token, pro rata; `skim()` then sends exactly the surplus. Mutation check (sync absorbing surplus, swap / remove without the entry check, skim of token1 against reserve0): 4/4 killed. Not covered: a deficit created inside a call (T9, T30) |
| R24 | (M11) Direct top-up during a deficit, without `sync()`: a partial top-up still blocks add, remove and both swaps; an exact top-up (balance == reserve) restores them with no `sync()` call; reserves unchanged | M11 | `PASSED` (M11) — `test/AMMPoolDeficit.t.sol`: `test_R24_partialTopUpStillBlocksExactTopUpRestores` (deficit 1,000 in token0; +999 still blocked with no state change; +1 and then directly swap (priced from the unchanged reserves), add and remove succeed, no `sync()` in between); `test_R24_syncAfterExactTopUpIsNoOp` (after an exact top-up `sync()` emits no event and changes no reserve); `test_R24_bothDeficitsOneRefilledStillBlocks` (both tokens in deficit; refilling one keeps the block). Existing exact-top-up coverage: `test_R08_boundaryEqualPassesMinusOneReverts`, `test_F1T2_slashAboveSurplus_deficitAndBothRecoveries` (path B). Mutation check (per-file restore, hash verified): `<` → `<=` in the token0 deficit check (re-run on the final test version); token1 deficit check removed: 2/2 killed |

R11 also covers repeated calls: `sync()` / `skim()` with nothing to do emit no `ReserveSynced` / `SurplusSkimmed` and write no reserve (checked with `vm.record` / `vm.accesses`). R13 also covers deficit and surplus at the same time in either token.

R08, R13 and R14–R22 need a test-only mock token whose Pool balance can be reduced (`MockDeficitERC20`, DECISIONS M6-5).

## 7. Balance invariants per call (M4–M8)

Each test records `balance_i` and `reserve_i` for both tokens before and after one call.

| ID | Invariant | Description | Milestone | Status |
|---|---|---|---|---|
| B01 | BI-2 | `addLiquidity` with pre-existing surplus leaves both surpluses unchanged | M4 (surplus setup in M6) | `PASSED` — initial path (M3, `test_L20_*`); later deposit (M4, `test_B01_laterDepositLeavesSurplusUnchanged`, surplus created by direct transfer); re-checked with the M6 entry check (`test_R07_B01_surplusNotCountedAsDepositInput`) |
| B02 | BI-2 | `removeLiquidity` leaves both surpluses unchanged | M4 | `PASSED` (M4) — `test_B02_withdrawalLeavesSurplusUnchanged` |
| B03 | BI-2 | `swapExactInput` leaves both surpluses unchanged | M5 | `PASSED` (M5) — `test_B03_swapLeavesSurplusUnchanged` (surplus by direct transfer) |
| B04 | BI-3 | After `skim()`, every token that had surplus has `balance == reserve`; reserves unchanged | M6 | `PASSED` (M6) — `testFuzz_B04_skimLeavesBalanceEqualReserve`, `testFuzz_R03_R04_skimSendsAllSurplus` |
| B05 | BI-4 | After `sync()`, `reserve_i = min(old reserve_i, balance_i)`; no reserve increased; balances unchanged | M6 | `PASSED` (M6) — `testFuzz_B05_syncIsMin` |
| B06 | BI-5 | Pool balance falls by exactly the amount sent in remove, swap and skim; negative case with `MockOverDebitERC20` (moved forward from X04, DECISIONS M4-4) | M4–M6 | Remove `PASSED` (M4); swap `PASSED` (M5) — asserted in `_checkedSwap`, negative `test_B06_overDebitOutputReverts`, `test_S08_swapOutbound_caughtFaulty_overDebitRejectedByA8`; skim `PASSED` (M6) — `test_B06_overDebitRejectedByA8`, `test_X01_M6_skimCallback_caughtFaulty_overDebitRejectedByA8`; positive side in `testFuzz_B04_*` |
| B08 | BI-2 | The first token's transfer callback directly transfers the **other** token to the Pool (add, remove, swap both directions): the donation is not counted as the caller's input and stays surplus (guards the M6-3 B snapshot reuse) | M6 | `PASSED` (M6) — `test_B08_addDonationDuringFirstPull`, `test_B08_removeDonationDuringFirstPush`, `test_B08_swapIn0DonationDuringPull`, `test_B08_swapIn1DonationDuringPull` |
| B07 | BI-6 | Recipient's actual increase ≥ user minimum in remove and swap; boundary at exactly the minimum | M4, M5 | Remove `PASSED` (M4); swap `PASSED` (M5) — `test_S04_minNetBoundary`, `test_M5_3_eventFieldsAreDistinct` (taxed output, min = netOut) |

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
| Q01 | `getAmountOut` equals the actual swap output on the same state (Tier 0) | `PASSED` (M5) — `test_Q01_quoteEqualsSwapBothDirections`, `testFuzz_Q01_quoteEqualsSwap` |
| Q02 | Invalid `tokenIn`, zero input, zero reserves revert with the same errors as the swap (`InvalidTokenIn`, `InsufficientInputAmount`, `InsufficientLiquidity`; DECISIONS M5-2) | `PASSED` (M5) — `test_Q02_errorsMatchSwap` |
| Q03 | Quote uses recorded reserves and ignores surplus | `PASSED` (M5) — `test_Q03_quoteIgnoresSurplus` |
| Q04 | Where the floored output is 0, `getAmountOut` returns 0 and `swapExactInput` with the same inputs reverts `InsufficientOutputAmount` with no state change (unit: reference case 3; fuzz over class-B inputs of §11.1) | `PASSED` (M5) — `test_Q04_zeroQuoteSwapReverts`, `testFuzz_Q04_zeroQuoteSwapReverts` |

## 10. Factory (M7)

| ID | Description | Status |
|---|---|---|
Decisions: DECISIONS §14 (M7-1 to M7-8). Every revert asserts the exact error (M4-8) and that the registry (`getPair` both orders, `allPairsLength`) is unchanged.

**M7 results (2026-11-20, branch `m7-factory`):** 323 tests passing (275 before M7 + 48 new: `AMMFactory` 28, `AMMFactoryOwnerless` 6, `AMMFactoryIntegration` 8, `AMMFactoryIsolation` 6), also with `FOUNDRY_FUZZ_RUNS=10000`; `AMMPool.sol` unchanged in M7. Fuzz range: `testFuzz_F02_getPairSymmetric` uses any two distinct addresses above `0xffff` with no prior code, given placeholder code by `vm.etch` — it shows ordering-independence of the registry, not that such addresses are usable tokens. **Mutation check** (scratchpad script, `src/AMMFactory.sol` restored byte-for-byte; classes per §15): 14 mutants, **14 killed, 0 survived, 0 not compilable** — reverse ordering not registered; forward ordering not registered; duplicate check removed; code check removed; code check only on token0; only on token1; sorting removed; `allPairs` not pushed; non-shared recipient (`msg.sender`) passed to the Pool; `createPair` payable; zero check removed; identical checked before zero; constructor self-check removed; `pairCount` off by one. The first run showed the token0-only mutant killed only incidentally (by the address order of one test); `test_F03_noCodeAsSortedToken0Reverts` / `_AsSortedToken1Reverts` were added so each sorted position is checked explicitly. `forge lint`: `reentrancy-events` on the `PairCreated` emit counts `new AMMPool` as an external call; accepted, because the only code run by the creation is the Pool constructor, which calls no contract (DECISIONS M7-4).

| ID | Description | Status |
|---|---|---|
| F01 | Unique pair created: returned address equals `getPair`; `allPairs[n] == pool`; `allPairsLength` grows by 1; `PairCreated(token0, token1, pool, pairCount)` with sorted tokens, for both argument orders | `PASSED` (M7) — `test_F01_createPairRegistersAndEmits`, `test_F01_reverseArgumentOrderSortsTheSame`, `test_F01_secondPairAppendsAndCounts`, `test_F01_allPairsOutOfRangeReverts` |
| F02 | `getPair(A,B) == getPair(B,A)`; unknown pair returns 0 | `PASSED` (M7) — `test_F02_getPairBothOrders`, `test_F02_unknownPairIsZero`, `testFuzz_F02_getPairSymmetric` |
| F03 | `ZeroAddress` (zero in either position, and `(0, 0)`), `IdenticalTokens`, `TokenHasNoCode` (EOA in either position; M7-2), `PairExists` (same and reverse order); check order as M7-4 | `PASSED` (M7) — `test_F03_zero*`, `test_F03_bothZeroReportsZeroAddress`, `test_F03_identicalReverts`, `test_F03_duplicate*`, `test_F03_noCode*` (incl. each sorted position), `test_F03_bothNoCodeReverts`, `test_F03_precompileRejected`, `test_F03_identicalNoCodeReportsIdentical`, `test_F03_noCodeCheckedBeforePairExists`; M7-2 limits: `test_F03_cannotPrecreatePairForFutureToken`, `test_F03_codeIsNotErc20Compliance` |
| F04 | Two Pools sharing a token, `(A,B)` and `(A,C)`: reserves, LP balances and supply independent; donation / `sync` / `skim` in one leave the other unchanged; both skim to the shared recipient | `PASSED` (M7) — `test/AMMFactoryIsolation.t.sol` `test_F04_*` (5 tests; P2's reserves, LP supply, lock, LP balances and token balances compared) |
| F04b | A pair whose Pool is terminal (M6-1) cannot be re-created: `createPair` reverts `PairExists` in both orders (M7-5) | `PASSED` (M7) — `test_F04b_terminalPairCannotBeRecreated` |
| F05 | Every Pool's `surplusRecipient` equals the Factory's; Factory constructor rejects `address(0)` and the Factory itself (`InvalidSurplusRecipient`); a recipient equal to a token makes `createPair` for that token revert `InvalidSurplusRecipient` (M7-1) | `PASSED` (M7) — `test_F05_constructorStoresRecipient`, `test_F05_constructorRejectsZeroRecipient`, `test_F05_constructorRejectsFactoryItself`, `test_F05_poolsShareFactoryRecipient`, `test_F05_recipientEqualToTokenBlocksItsPairs` |
| F06 | Factory integration (M7-6): representative M2–M6 flows on Factory Pools (initial and later deposit, withdrawal, both swaps, quote, deficit + `sync`, `skim`, terminal path, reentrancy smoke); runtime `codehash` of a Factory Pool equals that of a directly deployed Pool with identical constructor arguments. The M2–M6 unit suites keep direct deployment; F06 does not claim they were re-run through the Factory | `PASSED` (M7) — `test/AMMFactoryIntegration.t.sol`: `test_F06_codehashEqualsDirectDeployment`, `test_F06_codehashDiffersForOtherArguments` (equality is not vacuous), `test_F06_differentialMatchesDirectPool` (12 observable results equal), `test_F06_initialDepositAndLock`, `test_F06_deficitBlocksThenSyncReconciles`, `test_F06_skimPaysSharedRecipient`, `test_F06_terminalPoolPath`, `test_F06_reentrancyBubblesOnFactoryPool` |
| F07 | `forge build --sizes`: runtime below 24,576 B and initcode below 49,152 B for `AMMPool` and `AMMFactory`; margins recorded with the configuration (§14) | `PASSED` (M7) — `forge build --sizes` (configuration of §14, `forge config` checked 2026-11-20): `AMMPool` runtime 8,563 B (margin 16,013), initcode 9,635 B (margin 39,517); `AMMFactory` runtime 10,696 B (margin 13,880), initcode 10,894 B (margin 38,258). The Factory's runtime embeds the Pool's initcode, so it grows with the Pool in M8 |
| X03-F | Factory ownerless: compiled ABI (`out/AMMFactory.sol/AMMFactory.json`) lists exactly `allPairs(uint256)`, `allPairsLength()`, `createPair(address,address)`, `getPair(address,address)`, `surplusRecipient()`; no `fallback` / `receive`; admin-style selectors, a fuzzed unknown selector and a plain ETH transfer fail with no state change. The Factory does not expose payable entry points or token withdrawal functions (M7-7) | `PASSED` (M7) — `test_X03F_static_abiFunctionsEqualApprovedList`, `test_X03F_static_noFallbackReceiveOrPayable` (no ABI entry, constructor included, is payable), `test_X03F_runtime_adminAndWithdrawalSelectorsFail`, `test_X03F_runtime_plainEthTransferFails`, `test_X03F_runtime_ethWithApprovedFunctionsFails`, `testFuzz_X03F_runtime_unknownSelectorFails` |

## 11. Cross-cutting, fuzz and boundary (M5, M8, M10)

| ID | Description | Milestone | Status |
|---|---|---|---|
| X01 | Cross-function reentrancy blocked: from a swap callback into `addLiquidity` / `removeLiquidity`, from a withdrawal callback into `swapExactInput`, from a deposit callback into `swapExactInput`; bubbling and caught variants (DECISIONS M5-6) | M5 | `PASSED` (M5) — every `test_*_X01_*` in `test/AMMPoolReentrancy.t.sol` loops over the three re-entrant calls (swap, add, remove) from each callback point; `test_X01_add_caughtFaulty_shortInputRejectedByNetRange` |
| X02 | Swap with a token that returns `false` or reverts → full rollback (all M5-6 state compared); a token that returns **no value** is accepted by `SafeERC20` and the swap succeeds, tested on the input side and on the output side (DECISIONS M5-7) | M5 | `PASSED` (M5) — `test_X02_input*`, `test_X02_output*`, `test_X02_balanceOfRevertRollsBack`, `test_X02_noReturnTokenAsInput`, `test_X02_noReturnTokenAsOutput` |
| X03 | D10 ownerless. Static: the compiled ABI (`out/AMMPool.sol/AMMPool.json`) lists exactly the approved functions, with no `fallback` / `receive`. Runtime: admin-style selectors (owner, setter, sweep, pause), a fuzzed unknown selector and a plain ETH transfer fail with empty return data and no state change (DECISIONS M5-7) | M5 | `PASSED` (M5) — `test_X03_static_abiFunctionsEqualApprovedList`, `test_X03_static_noFallbackOrReceive`, `test_X03_runtime_adminSelectorsFail`, `test_X03_runtime_plainEthTransferFails`, `testFuzz_X03_runtime_unknownSelectorFails`. Extended in M6 to 22 entries (`sync()` in the sync commit, `skim()` in the skim commit) |
| X01 (M6) | `skim()` outbound callback re-entering `sync`, `skim`, add, remove, swap — bubbling, caught + correct transfer, caught + faulty transfer (A8); callbacks during add, remove and swap re-entering `sync` / `skim`; full-state rollback comparison (DECISIONS M6-5) | M6 | `PASSED` (M6) — `test_X01_M6_skimCallback_bubbling`, `_caughtCorrect`, `_caughtFaulty_overDebitRejectedByA8`, `test_X01_M6_operationCallbacksIntoSyncSkim_bubbling`, `_caughtCorrect`; documented limit `test_X01_M6_skimCallback_caughtShortDeliveryNotChecked` (T16) |
| X05 | T13 demonstration: a callback mock records `getReserves()` (and LP `totalSupply`) during the inbound pull and the outbound push of a swap; the recorded values equal the pre-call snapshot and the post-effects state respectively (DECISIONS M5-5) | M5 | `PASSED` (M5) — `test_X05_midSwapInboundReadsPreCallState`, `test_X05_midSwapOutboundReadsPostEffectReserves` (Pool output balance = reserve + out mid-call), `test_X05_midRemoveReadsPostEffectState` |
| X04 | Exclusive-FOT mock (over-debits the Pool) makes remove, swap and skim revert (A8) | M8 | Covered by B06 (moved forward from X04, DECISIONS M4-4): `test_W10_classB_*` (remove), `test_B06_overDebitOutputReverts` (swap), `test_B06_overDebitRejectedByA8` (skim), all `PASSED` |
| Z01 | Fuzz swap in `[1, 2^112]`: `out < rOut`; inequality holds; no unexpected revert | M5 | Maths level `PASSED` (M2); Pool swap `PASSED` (M5) — `testFuzz_Z01_S11_S15_swapMatchesFormula` (range in §5.0) |
| Z02 | Fuzz add then full remove: returns no more than contributed | M10 | `PASSED` (M10) — `test/AMMPoolRoundTrip.t.sol`: `testFuzz_Z02_roundTripTier0`, `testFuzz_Z02_roundTripTaxed` (1 % / 3 %), `testFuzz_Z02_initialRoundTrip`. Later deposit then full redemption of the same `σ`: (P1) [proven] Pool-side redeemable `floor(σ·(r_i+n_i)/(S+σ)) ≤ n_i`; (P2) the depositor's wallet ends no higher per token; (P3) `S` returns to its start and each reserve ends not below its start. Initial deposit: the lock's pro-rata part `n_i·1000/(shares+1000)` stays. Expected reverts are classified by selector (`InsufficientDepositAmount`, `InsufficientShares`, `InsufficientInitialLiquidity`, and `InsufficientLiquidityBurned` only when one side rounds to 0); any other revert fails. Ranges: prior swap `[0, 1e22]` on a ≈ (1e21, 3e21) seed, caps `[1, 1e24]`, either pull order. Default and 10,000 runs passed. Mutation check: shares rounded up, lock not minted, redemption rounded up per token: 4/4 killed. The later-deposit round-trip properties cannot distinguish the two roundings of the redemption (floor vs ceil): `ceil(σ·(r_i+n_i)/(S+σ)) ≤ n_i` still holds, so P1–P3 hold under both; the initial round trip kills both redemption mutants. Per-share protection of the other LPs is checked by I10 |
| Z03 | Mixed 6/18-decimal scales near the top of the fuzz range | M10 | `PASSED` (M10) — `test/AMMPoolMixedDecimalsTop.t.sol` `testFuzz_Z03_mixedDecimalsNearTop`, 256 runs (default) and 10,000 runs (`FOUNDRY_FUZZ_RUNS=10000`), Tier 0. Ranges: 18-decimal initial amount `[2^104, 2^112]`, 6-decimal initial amount `[x18/1e15, x18/1e9]` (value ratio 1e-3 to 1e3 per whole token), so about `[2^54, 2^82]`; two swaps by another account, input `[1, reserveIn]` of either token; a later deposit with caps `[1, reserve6]` and `[1, 2^112]`; full exit of that deposit. Expected values computed in the test from the approved formulas and compared exactly: initial shares `⌊√(x6·x18)⌋ − 1000`; swap output (§6.4), `out < rOut`, §6.5 (512-bit) and reserve updates; σ = `min ⌊n_i·S/r_i⌋`, `n_i ≤ cap_i`, per-share reserves not down (512-bit); redemption `⌊shares·r_i/S⌋`, round trip `≤` contributed, reserves > 0 afterwards. Accepted reverts only for rounding to zero (swap `InsufficientOutputAmount`, deposit `InsufficientDepositAmount` / `InsufficientShares`, exit `InsufficientLiquidityBurned`), each predicted or classified. Probes (temporary, file restored by hash): each rounding-to-zero branch occurs (first within 7, 22 and 27 runs), so the success paths and the zero branches are both sampled; frequencies not counted. Mutation check (per-file restore, hashes verified): fee 30 → 29 bps, σ = max, redemption rounded up: 3/3 killed |
| Z04 | Fuzz gross vs. net for the U8 taxed mock | M8, M10 | Deposit (M8): covered by Z08 (inclusive tax 0–100 %) and Z09. Swap and remove (moved to M10 at the M8 acceptance): `PASSED` (M10) — `test/AMMPoolTaxedSwapRemove.t.sol` `testFuzz_Z04_swapGrossVsNet` (both tokens taxed, 1 % / 3 %; optional prior swap `[0, 1e22]`, then `g ∈ [1e3, 1e23]`, both directions; exact `a`, `out`, `netOut`, payer debit `g`, A8, reserves, surplus), `testFuzz_Z04_removeGrossVsNet` (`shares ∈ [1, LP balance]`; exact `amount_i`, `net_i`, A8, reserves, LP burn, lock, surplus; rounding-to-0 branch reverts `InsufficientLiquidityBurned` with full rollback), `test_Z04_removeMinNetBoundaryBothTaxed`. Default and 10,000 runs passed. Mutation check (4 mutants: reserveIn += gross for each token, pricing on gross, push returns Pool-side amount): 4/4 killed. Not covered: reserves near 2^256, taxes other than 1 %, 2.5 %, 3 % |
| Z05 | Fuzz L-α: for random `T` and `t < 10000`, implementation gross gives `net ∈ [T, T+1]` | M8 | **Retired in M8** (L-α and `[T, T+1]` retired, M8-1); the measured-net deposit is fuzzed by Z08 and Z09 |
| Z06 | **Arithmetic boundaries** for each formula in ARCHITECTURE §6.6: just inside the sufficient condition succeeds; beyond the overflow threshold reverts with the exact Panic; no wrong value returned | M5, M10 | `PASSED` for `getAmountOut` and `initialShares` (`test_Z06_*`); swap at Pool level `PASSED` (M5) — `test_Z06_denominatorBoundary` (largest `a` with `rIn·D + a·9970 ≤ 2^256 − 1` succeeds, `+1` reverts Panic `0x11` with full rollback), `test_Z06_aFeeOverflowReverts`; M4 formulas `PASSED`: L-α target — after M4H-2 it never overflows; `test_Z06_laterTargetOverflowTakesToken1Branch` (`2^255 − 1` → token0 branch, `2^255` → token1 branch instead of the former Panic), `test_M4H2_*` (3 tests, all three `mul512` paths), and the differential oracle `testFuzz_Z06_laterDepositMatchesOracle` / `test_Z06_extremeCapCorners` (file `test/AMMPoolDepositDifferential.t.sol`, DECISIONS M4H-3); redemption `test_W10_classA_*` (`type(uint256).max` → `ERC20InsufficientBalance`, no Panic). Analysed as unreachable before another check fails, so not separately testable: the other L-α branch (`T0 < amount0Max`), later-share `mulDiv` (bounded by the targets), reserve additions (bounded by token supply). Others M8/M10 |
| Z07 | **Business-invariant boundaries** (DECISIONS M4-7): `T_i == 0`, `shares == 0`, `amount_i == 0`, `[T, T + 1]`, `minShares`, `min_iNet`, the 1,000 lock — value at the boundary succeeds or fails exactly as specified, with the exact custom error | M4 | `PASSED` (M4) — `test_Z07_targetZeroBoundary`, `test_Z07_targetZeroBoundaryToken0Side`, `test_Z07_zeroSharesReverts`, `test_Z07_zeroOutputBoundary`; `[T, T+1]` lower side `test_L26_*`; `minShares` `test_L08_*`; `min_iNet` `test_W04_*`/`test_W05_*`; lock `test_W06_*`/`test_W11_*` |
| Z10 | (M10 P1, approved 2026-11-23) Upper bound on the LP shares minted when only swaps happen between a quote and the deposit ("仅有 swap 时的 LP 铸造数量上界"), Tier 0: `σ'²·k_q ≤ S²·A·B` | M10 | `PASSED` (M10) — `test/AMMPoolSwapOnlyMintBound.t.sol` `testFuzz_Z10_swapOnlyMintUpperBound`. **Definitions:** quote state `q` = recorded reserves `(r0, r1)`, LP supply `S`, `k_q = r0·r1`; `A = amount0RequestMax`, `B = amount1RequestMax` (request caps, smallest units); between `q` and the deposit only 1–2 swaps by another account (any direction), so `S` is unchanged and `r0'·r1' ≥ k_q` (§6.5); `σ'` = shares minted by the real Pool (return value, checked equal to the supply increase); premise `n_i ≤ cap_i` (Tier 0: `n_i = T_i`), asserted from the returned nets. **Mathematical proof [proven]:** `σ' ≤ min(n0·S/r0', n1·S/r1') ≤ min(A·S/r0', B·S/r1')`; `min(x, y)² ≤ x·y`; so `σ'² ≤ S²·A·B/(r0'·r1') ≤ S²·A·B/k_q`. It bounds the share count only, not value, and does not cover non-swap changes (deposits, withdrawals, `sync`) between quote and deposit. **Local execution evidence (2026-11-23, local Foundry EVM, real `AMMPool`):** inputs in `[1e3, 2^64]` (initial amounts, geometric mean > 1001) and `[1, 2^64]` (swap amounts, caps); a run counts only if at least one swap executed and the deposit succeeded, otherwise it is discarded with `vm.assume(false)`, so forge's `runs` equals the number of valid samples: 256 (default) and 10,000 (`FOUNDRY_FUZZ_RUNS=10000`), all passed; forge does not report the number of discarded inputs (the default `max_test_rejects` limit was not reached). Unexpected deposit reverts fail the run. **Overflow handling:** with these bounds `σ'²`, `S²`, `A·B` and `k_q` each fit in a checked `uint256` (an overflow would Panic and fail the run, never truncate); the two final products are formed with `Math.mul512` and compared exactly as 512-bit numbers; under the claim `σ' < 2^118`. **Mutation check:** σ = max instead of min, step 2 ignoring the token1 cap, inflated σ: killed by the revert classification; mint (and return) of `2σ` and of `σ + σ/100` after all checks: killed by the bound assertion itself. Not covered: taxed tokens, reserves near 2^256, value-based claims |

Do not use `assume()` to exclude conditions the implementation is expected to handle.

**Safety vs. supported range (DECISIONS M5-7).** A fuzz or boundary test proves only what its input range covers. Example: Z06 for `a × 9970` shows that an overflow fails safely with Panic `0x11` and never returns a wrong value; it does not show that every `uint256` input can be traded. Each fuzz/boundary row must state (a) the range over which success is asserted, (b) the inputs where a safe revert is asserted, and (c) any boundary not covered. These are recorded per test when the results are written.

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

**Implemented 2026-11-23 (M10 P0):** `test/AMMPoolInvariant.t.sol` + `test/invariant/AMMPoolHandler.sol`. Two campaigns with the same handler: `AMMPoolInvariantTier0Test` (two standard tokens) and `AMMPoolInvariantTaxedTest` (two U8 taxed tokens, 1 % / 3 %). Configuration (inline `forge-config`): 256 runs × depth 500 = 128,000 handler calls per campaign, `fail-on-revert = true`, so an assertion inside the handler fails the campaign instead of being discarded. Result 2026-11-23 on `acbb9f8` + this commit: both passed, 0 unclassified reverts.

- **Actions:** later deposit (caps either independent in `[1, 1e24]` or near the ratio, either pull order), withdrawal (1 bp to 100 % of the actor's LP), swap in both directions (`[1, 1e23]`), `sync`, `skim`, direct donation (`[1, 1e22]`, minted to the Pool), LP transfer between actors, LP transfer to the Pool (must revert `LPTransferToPool`).
- **Premises / model:** one Pool, three actors (wallets topped up by minting when below 1e27, which changes no Pool state), supported tokens with truthful `balanceOf`, no deficit-creating token, initial deposit (1e21, 3e21) in the handler's constructor, so every sequence runs with `S > 0`. Expected values come from the pre-call state and the token model, not from the Pool.
- **Reverts:** every Pool call runs in try/catch; a revert is accepted only with the selector the expectation predicts (`InsufficientDepositAmount` / `InsufficientShares` on deposit; `InsufficientLiquidityBurned` only if an amount rounds to 0; `InsufficientOutputAmount` only if the formula gives 0; `LPTransferToPool`). Any other revert fails.
- **Not modelled:** unsupported tokens (deficits, hooks, in-call foreign transfers: T9, T30), the initial-deposit path inside sequences, reserves near 2^256, several Pools, MIN-NET thresholds above 0 (boundaries are unit-tested: S04, S06, W04, Z04).
- **Mutation check** (per-file restore verified by hash and `git status`): sync absorbing surplus, X2-style `reserve += matched`, swap fee missing, redemption rounded up, `skim` sending surplus + 1, LP-SELF removed, later shares rounded up, withdrawal not lowering `reserve1`: **8/8 killed**. Note on which check killed them: fee missing and redemption rounded up were killed first by the exact-expectation checks (A8 amount), shares rounded up by the revert classification (a deposit revert with an unexpected selector); this run does not show that I3 or I10 alone would have caught them.

| ID | Invariant | Status |
|---|---|---|
| I1 | BI-7 and BI-8: LP `totalSupply` = minted − burned; Pool's LP == 1000 after the first deposit; no protocol shares | `PASSED` (M10) — global: supply = ghost minted − burned, lock == 1000, actors + lock hold the whole supply; per call: add `S += shares`, remove `S −= shares`, LP transfers keep `S` |
| I2 | BI-1: `balance_i ≥ reserve_i` with supported tokens | `PASSED` (M10) — global, after every call |
| I3 | BI-9 for every successful swap | `PASSED` (M10) — per swap, exact 512-bit `(rIn·D + a·9970)·(rOut − out) ≥ rIn·rOut·D`, plus `out` equal to the independent formula |
| I4 | Reverted calls leave no state change | Evidence **reused, no separate campaign** (student, 2026-11-23): the EVM reverts a failed call atomically; the existing unit tests assert full rollback per failure class (M5-6 snapshot style, e.g. `PoolStateFixture`); in addition the handler asserts unchanged reserves, supply, Pool balances and actor LP after every accepted revert |
| I5 | Factory has no duplicate or unregistered pair | `PASSED` (M10 P2) — `test/AMMFactoryInvariant.t.sol` `invariant_I5_registryConsistent` (inline config: 256 runs × depth 50, `fail-on-revert = true`). Handler: `createPair` over seven candidates (five MockERC20 tokens, `address(0)`, an address without code), any ordering; each outcome is predicted from a ghost registry and the M7-4 check order, and the exact revert error is asserted. After each success: Pool deployed, `token0 < token1` matching the sorted inputs, shared `surplusRecipient`, `getPair` under both orderings, `allPairs` grows by one with the Pool last. Global after every call: `allPairsLength` = successful creations; every `allPairs[k]` distinct in address and in pair, registered under both orderings; for all 7 × 7 candidate orderings `getPair` equals the ghost entry (non-zero only for created pairs). Last run: 9 created, 42 rejected. Mutation check on `AMMFactory.sol` (per-file restore, hash verified): reverse mapping not written, uniqueness check removed, `allPairs.push` removed, code check removed, no sort: 5/5 killed, all by the handler's per-call assertions. Not covered: a token equal to `surplusRecipient` (M7 unit tests), several Factories |
| I6 | (renamed in M10; was "Adaptive deposits never debit more than the cap") Deposits: request ≤ `RequestMax`, debit ≤ `maxDebit` | `PASSED` (M10, both handler suites): per successful deposit `net_i ≤ debit_i ≤ RequestMax_i` and `debit_i ≤ maxDebit_i` (payer's measured balance decrease; Tier 0 and U8). In a quarter of the deposits `maxDebit_i` is a finite boundary value, `T_i` or `T_i − 1` with `T_i` the step-2 target at the current reserves (a handler-side model used only to place the bound); `PayerDebitTooHigh` is an accepted revert only when some `maxDebit_i < RequestMax_i`, followed by the unchanged-state check. Last run of each campaign: finite-bound successes 1 and 5, `PayerDebitTooHigh` 11 and 5 (per-run statistics, not totals). Mutation check (per-file restore, hash verified): payer-debit check removed; each token's bound relaxed by one unit (`debit − 1 > maxDebit`): 3/3 killed by the I6 assertion. Single-call boundary and exotic payer debits remain in L37 / Z09 |
| I7 | BI-5 and BI-6 hold on every outbound transfer | `PASSED` for BI-5 (M10): remove, swap and skim — the Pool's balance falls by exactly the expected amount. BI-6 part: the return value equals the recipient's measured increase and matches the token model; minima are 0 in the handler, so the MIN-NET threshold itself is covered by unit tests only |
| I8 | `skim()` sends only `balance − reserve`, only to `surplusRecipient` | `PASSED` (M10, both handler suites): `skim` sends exactly the surplus (Pool side), leaves reserves unchanged, and `surplusRecipient` is credited the surplus minus the token's tax. No other address is credited: each token's `totalSupply` falls by exactly the burned tax (0 for Tier 0), which together with the exact Pool decrease and the exact recipient credit implies that the combined balance of all other addresses is unchanged; in addition the balances of the `skim()` caller (the handler) and of each actor are checked individually. Sensitivity check (per-file restore of `src/` and of the handler, hashes verified): mutant "half the surplus to `msg.sender`" is first killed by the recipient-credit assertion; with that assertion temporarily removed it is still killed by I8 alone (Tier 0: caller balance; taxed: supply accounting, the extra transfer burns extra tax). Scope: addresses outside the model can only be covered by the combined supply statement |
| I9 | Only `sync()` lowers a reserve without an outbound transfer; no function moves surplus into reserves | `PASSED` (M10) — per call: each reserve changes exactly by the call's own measured amount (add `+n_i`, remove `−amount_i`, swap `+a` / `−out`), `sync` changes nothing (no deficit with supported tokens), donations and LP transfers change no reserve; global: `balance_i − reserve_i` equals the ghost surplus (donations minus `skim`) |
| I10 | (new, approved conditionally 2026-11-23) Per-share value of existing LPs never decreases: for every successful later `addLiquidity` and `removeLiquidity`, `r_i'·S ≥ r_i·S'` for both tokens; for every successful swap `S' = S` and `r0'·r1' ≥ r0·r1`; `skim`, donations and LP transfers change neither reserves nor `S`. Hence `r0·r1/S²` never decreases along these operations. Premises: supported tokens, truthful `balanceOf`, `S > 0`; `sync()` and the initial deposit excluded. Proof per operation: add `n_i·S ≥ σ·r_i` (σ floored); remove `S·amount_i ≤ shares·r_i` (floored); swap §6.5 | `PASSED` (M10) — exact 512-bit cross-multiplied comparisons after every call |

`reserve0 × reserve1` monotonicity is required per swap only (BI-9), not across withdrawals or `sync()`; across add / remove / swap the per-share form I10 holds.

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
| G01 | `swapExactInput` gas with and without the on-chain §6.5 assertion | Input to the A9 decision | M5 | Measured 2026-11-19 (§14.2); A9 decided: tests only (DECISIONS M5-9) |
| G03 | Cost of the M6 deficit entry check; M6-3 snapshot-reuse variant B vs. A | Input to the B decision (DECISIONS M6-3) | M6 | Measured 2026-11-19 (§14.3); B not adopted (DECISIONS M6-8) |
| G04 | `createPair` gas (one measurement, configuration recorded) | Report only; no optimisation (DECISIONS M7-7) | M7 | Measured 2026-11-20 (§14.4) |
| G05 | M8 `addLiquidity` paths vs. the G03 baseline; balance-reading reuse variants VA / VB / VC | Input to the optimisation decision and to R7 (DECISIONS M8-9) | M8 | Measured 2026-11-22 (§14.5); current implementation kept, VA / VB / VC recorded as evaluated candidates (2026-11-23); R7 event variants measured, option A chosen (M8-9) |
| G02 | Gas snapshot of all public functions | Report and later optimisation baseline | M10 | Measured 2026-11-23 (§14.6), harness `test/gas/GasG02.t.sol` |

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

### 14.2 G01 — on-chain §6.5 assertion (2026-11-19, branch `m5-swap`, base commit `e445d02`)

Configuration verified with `forge config` immediately before measuring: `solc` 0.8.38, optimizer on, 200 runs, `evm_version = osaka`, `via_ir = false`, OpenZeppelin v5.7.0, forge 1.9.0. The assertion variant and a temporary measurement test were applied by a scratchpad script and removed afterwards (DECISIONS M5-4).

**Variant B (measured; not adopted — A9 = tests only, DECISIONS M5-9):** directly after the `out == 0` check, `Math.mul512(rIn·D + a·9970, rOut − out)` and `Math.mul512(rIn·D, rOut)` compared as 512-bit numbers; failure → `SwapInvariantViolated()`.

**Single swap** (`gasleft()` around the external call; Pool `(1000e18, 2000e18)`, `amountIn = 1e18`, recipient balances non-zero, first swap of the transaction = cold storage):

| Variant | token0 in | token1 in | second swap, same tx | Runtime size | Deployment (gas / size) |
|---|---:|---:|---:|---:|---|
| A — no assertion (committed) | 83,895 | 83,943 | 79,440 | 7,183 B | 1,664,720 / 8,302 B |
| B — inline 512-bit assertion | 84,731 | 84,779 | 80,276 | 7,337 B | 1,697,993 / 8,456 B |
| Difference | +836 | +836 | +836 | +154 B | +33,273 gas once per Pool |

**`forge test --gas-report`, `AMMPoolSwapTest`** (`swapExactInput`, all calls incl. reverts): A min 22,820 / median 74,579 / max 122,795; B min 22,820 / median 75,240 / max 123,631. Max +836 matches the single-swap delta; median/mean are only indicative because the fuzz inputs differ between runs (779 vs 781 calls).

**New numerical boundary?** None found. The assertion re-evaluates `rIn·D + a·9970` and `rIn·D`, which `AMMMath.getAmountOut` has already evaluated with checked arithmetic in the same call, so they cannot overflow where the swap itself did not; `rOut − out ≥ 1` (`out < rOut`); `mul512` cannot overflow. The full suite (208 tests incl. Z06 boundaries and the `[1, 2^112]` swap fuzz) passes unchanged with variant B.

**What it catches:** with a deliberately injected `out + 1` bug, variant B reverts `SwapInvariantViolated()`; the existing test suite also detects the same bug (28 failing tests in the M5 mutation check), so the extra protection applies only to bugs that escape the tests and would otherwise ship in an immutable contract.

### 14.3 G03 — M6 deficit check and snapshot reuse (2026-11-19, branch `m6-sync-skim`, base commit `c82608f`)

Configuration verified with `forge config` immediately before measuring: `solc` 0.8.38, optimizer on, 200 runs, `evm_version = osaka`, `via_ir = false`, OpenZeppelin v5.7.0, forge 1.9.0. Variants were applied by a scratchpad script that always restored `src/` (checked byte-for-byte), together with a temporary measurement test that was removed afterwards (DECISIONS M6-3).

**Scenario:** one external call per test, `gasleft()` around it, first call of the transaction (cold storage); Tier 0 tokens; Pool seeded with `(1000e18, 2000e18)`; recipient balances non-zero. Calls: later deposit with caps `(1e18, 1e19)` (token0 cap binds); withdrawal of `1e18` LP; swap of `1e18` token0 in and token1 in. Deployment measured with `gasleft()` around `new AMMPool(...)`.

**Variants:** **A** (committed): `_checkNoDeficit()` reads both balances; every pull/push takes its own fresh snapshot. **N** (reference only, never adoptable): no deficit check. **B**: the first-transferred token reuses its entry reading as its before-snapshot (add: token0 pull; remove: token0 push; swap: input-token pull); the second token always re-reads.

| Variant | `addLiquidity` | `removeLiquidity` | swap token0 in | swap token1 in | Runtime | Initcode | Deployment gas |
|---|---:|---:|---:|---:|---:|---:|---:|
| N — no deficit check | 96,415 | 96,210 | 86,752 | 86,789 | 8,226 B | 9,284 B | 1,926,851 |
| **A — committed** | **98,525** | **98,320** | **88,862** | **88,899** | **8,563 B** | **9,635 B** | **1,999,255** |
| B — snapshot reuse | 97,662 | 97,438 | 88,004 | 88,040 | 9,150 B | 10,222 B | 2,126,234 |
| A − N (cost of the check) | +2,110 | +2,110 | +2,110 | +2,110 | +337 B | +351 B | +72,404 |
| B − A | −863 | −882 | −858 | −859 | +587 B | +587 B | +126,979 |

**B against the four adoption conditions (DECISIONS M6-3):**

1. B passes every test written for A: 275/275.
2. B08 (donation of the other token during the first transfer) passes with B. Three deliberately wrong B variants that also reuse the **second** token's stale entry reading are each detected, and only by B08: add → `test_B08_addDonationDuringFirstPull`; remove → `test_B08_removeDonationDuringFirstPush`; swap → `test_B08_swapIn0DonationDuringPull`, `test_B08_swapIn1DonationDuringPull`.
3. Gas measured separately for add, remove and both swap directions (table): about −860 gas per call (about 0.9%).
4. Maintainability: the straightforward B (both cached balances passed on) does **not compile** (`Stack too deep` in `swapExactInput`, `removeLiquidity` and `_addLater`); the compiling version needs two duplicated helpers (`_pullFrom`, `_pushFrom`), a block scope in the swap, and an extra `_addLater` parameter that uses one of the last free stack slots before M8 adds L-α tax handling there. Runtime +587 B and deployment +126,979 gas once per Pool; break-even on runtime alone after about 148 calls per Pool.

Status: measured; **B not adopted, A kept** (student, DECISIONS M6-8, with the accepted trade-off recorded there). These are single-scenario measurements, not a full gas snapshot (G02, M10).

### 14.4 G04 — `createPair` (2026-11-20, branch `m7-factory`, base commit `a70c42a`)

Configuration: §14 table, checked with `forge config` immediately before measuring (`solc` 0.8.38, optimizer on, 200 runs, `osaka`, `via_ir = false`, OZ v5.7.0, forge 1.9.0). Source: `forge test --match-test "test_F01_secondPairAppendsAndCounts|test_F02_getPairBothOrders" --gas-report` (successful calls only; call gas as reported by forge, without the 21,000 transaction base cost and calldata).

| Measurement | Gas |
|---|---:|
| `createPair`, first pair of the Factory (`allPairs` length slot 0 → 1) | 1,914,651 |
| `createPair`, later pair | 1,897,551 |
| `AMMFactory` deployment | 2,360,843 (10,926 B) |

Almost all of the cost is the deployment of the Pool's code (runtime 8,563 B); the registry writes (two `getPair` entries, `allPairs` push) and the code-existence check are a small part. No optimisation is proposed (report only, M7-7).

### 14.5 G05 — M8 `addLiquidity` paths and balance-reading reuse (2026-11-22, branch `m8-measured-deposit`, base commit `8f294b9`)

**Configuration.** Checked with `forge config` in every measured copy immediately before measuring: `solc` 0.8.38, optimizer on, 200 runs, `evm_version = osaka`, `via_ir = false`, `isolate = true` (forge default; not set in `foundry.toml`, `FOUNDRY_ISOLATE` unset), OZ v5.7.0. Foundry: `forge 1.9.0` (commit `6056c58`).

**Method.**
- Clean code copies were exported with `git archive` into the scratchpad:
  - `m6-sync-skim-accepted` (`d24ca3a`);
  - `m7-factory-accepted` (`26ac725`);
  - `HEAD` (`8f294b9`).
- The repository's `src/` and `test/` were not modified, and no measurement test was committed.
- Commands, run in each copy:
  - baseline: `forge test --match-contract GasM6 -vv`;
  - M8: `forge test --match-contract GasM8 -vv`;
  - sizes: `forge build --sizes`.
- Every value was measured twice with identical results.

**Baseline conditions (G03, §14.3; harness `GasM6`, archived from M6 and reused unchanged).**
- Metering: `gasleft()` immediately before and after one external call. The `vm.prank` is set before the first reading, and the ABI encoding of the arguments lies inside the interval.
- It is a top-level call of the test under `isolate = true`, so storage and accounts are cold, as in G03.
- Tier 0 `MockERC20` tokens, 18 decimals.
- Pool seeded in `setUp` by alice with `(1000e18, 2000e18)`.
- The payer is alice: an existing LP with token balances of about 1e30 (non-zero) and approvals of `type(uint256).max`.
- The recipient is alice, whose LP balance is non-zero.
- The later deposit uses caps `(1e18, 1e19)`, so the token0 cap binds and the Pool pulls `(1e18, 2e18)`.

The G03 value 98,525 reproduces exactly on both `m6-sync-skim-accepted` and `m7-factory-accepted`, which are the same addLiquidity code before M8. Remove, swap and deploy also reproduce, at 98,320 / 88,862 / 88,899 / 1,999,255.

**M8 harness (`GasM8`).** Same conditions and the same `setUp` deposit, using the M8 ABI (`addParams`: `maxDebit` / `maxExcess` unbounded, token0 first unless stated). The params struct is built in memory before the first `gasleft()`; its ABI encoding is inside the interval. A calibration call (`t0.balanceOf(alice)` as a top-level call) measures 9,693 in the G03 harness and 9,664 in the M8 harness. These are harness-context differences of this order, not Pool code. Absolute values are Foundry measurements of a top-level call under isolation, not mainnet transaction receipts.

| Path | Conditions | M8 committed | Comparable with G03? | Δ vs 98,525 |
|---|---|---:|---|---:|
| P1 later, token0 first, token0 cap binds | identical to G03 | 108,789 | yes | **+10,264 (+10.4%)** |
| P2 later, `token1First`, token0 cap binds | as P1, other pull order | 108,810 | no (path not in G03) | — |
| P3 later, token1 cap binds, caps `(1e19, 2e18)` | pulls `(1e18, 2e18)` | 109,005 | no | — |
| P4 later, new recipient `dave` (LP balance 0 → non-zero) | as P1 | 125,889 | no | — |
| P5 initial deposit `(1000e18, 2000e18)` into an empty Pool | payer alice | 231,979 | no | — |
| P6 later, `MockFeeERC20` with tax 0 | as P1, other token contract | 150,521 | no (mock token code costs more) | — |
| P7 later, token0 (first) inclusive 1% tax → re-plan | `MockFeeERC20` | 178,280 | no | — |
| P8 later, token1 (second) inclusive 1% tax → excess on token0 | `MockFeeERC20` | 177,899 | no | — |
| Deployment `new AMMPool(...)` | same constructor arguments | 2,426,562 | yes | +427,307 (+21.4%) vs 1,999,255 |
| Runtime / initcode size | `forge build --sizes` | 10,553 B / 11,709 B | yes | +1,990 B / +2,074 B vs 8,563 B / 9,635 B |

**Balance-reading reuse (temporary variant copies; full suite of 406 tests run with default fuzz runs on each).**

| Variant | Reading reused | External calls between the two readings | Check effect | Tests | Saving per path (measured) | Size / deployment |
|---|---|---|---|---|---|---|
| VA | The second-pulled token's after-reading inside its `_pullMeasured` is reused as its BI-2′ end reading | None that can change state: only the function return and the `balanceOf` STATICCALL of the other token | Same value under truthful and stable `balanceOf` (the M8-11 assumption); the first-pulled token still re-reads after the second transfer | 406/406 | P1 −684, P2 −705, P3 −684, P4 −684, P5 −704, P6–P8 −718 | runtime +328 B, deployment +71,033 |
| VB | The first-pulled token's whole-call start snapshot is reused as the before-reading of its own pull | Only the two payer `balanceOf` STATICCALLs | Same value under the same assumption; the second token still takes a fresh before-reading | 406/406 | P1 −773, P2 −772, P3 −773, P4 −773, P5 −917, P6–P8 −807 | runtime +104 B, deployment +22,569 |
| VC | Later path: the deficit entry check compares the start snapshot instead of reading again in `_checkNoDeficit` | None | Same comparison. One difference: both balances are now read before the comparison, so with token0 in deficit and a reverting `token1.balanceOf` the error changes from `ReserveDeficit()` to the token's revert. That is an unsupported token (THREAT_MODEL §7.2), and no existing test covers it | 406/406 | P1–P4 −1,856, P5 0 (no deficit check on the initial path), P6–P8 −1,924 | runtime +39 B, deployment +8,475 |
| VW (control, deliberately wrong) | The **first**-pulled token's after-reading reused as its end reading, across the second transfer | The second token's `transferFrom`, a CALL that can move the first token's balance | Broken: a foreign in-call loss is missed | 400/406; 6 failures, all in `AMMPoolInCallBalance`: B09c (initial, later), B09d (two cases), `testFuzz_B09e_largeBalances`, L40 | — | — |

**Decision conflicts and combination.**
- VB reverses the per-transfer fresh-snapshot rule (DECISIONS M6-8).
- VA and VC change the M8-11 implementation note (end reading taken separately; deficit-check reading kept separate). Adopting any variant needs the student's decision.
- The combination of VA + VB + VC was **not** measured. Its saving is an estimate only: about the sum, roughly 3,300 on P1.

Status: measured. **Decision (student, 2026-11-23):**
- the current implementation is kept, and VA, VB and VC are recorded as evaluated optimisation candidates;
- the VC saving and its error-order difference are kept for the report;
- the about-3,300 combination is an unverified estimate;
- VW shows only that the existing tests caught this one incorrect reuse.

**R7 event variants (2026-11-23, same harness, configuration and method as above; temporary copies of `8f294b9`, now `feaf76b` with identical `src/`):**

| Variant | P1 | Δ P1 | P5 initial | Δ P5 | P7 / P8 | Deployment | Runtime | Tests |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| A — current `LiquidityAdded` | 108,789 | — | 231,979 | — | 178,280 / 177,899 | 2,426,562 | 10,553 B | 406/406 |
| E2 — plus `DepositAccounting(payer, debit0, debit1, excess0, excess1)` | 111,308 | +2,519 | 234,440 | +2,461 | 180,799 / 180,418 | 2,463,830 | 10,725 B | 407/407 (406 + worked example asserting both events) |
| E3 — `LiquidityAdded` extended to 9 fields | 110,194 | +1,405 | 233,326 | +1,347 | 179,685 / 179,304 | 2,457,351 | 10,695 B | event signature changed: 3 test files (9 references) do not compile |

Worked example used for E2, on the real Pool:
- start: reserves (10,000, 20,000), S = 14,142; token1 has a 10% inclusive tax;
- request (1,000, MAX), token0 first;
- payer debit (1,000, 2,000); net (1,000, 1,800); σ = 1,272; excess (100, 1).

Decision: option A (DECISIONS M8-9). These are single-scenario measurements, not a full gas snapshot (G02, M10).

### 14.6 G02 — gas of every public function on the final code (2026-11-23, branch `m10-verification`)

Configuration verified with `forge config` immediately before measuring: `solc` 0.8.38, optimizer on, 200 runs, `evm_version = osaka`, `via_ir = false`, `isolate = true`, OpenZeppelin v5.7.0, forge 1.9.0. `src/` is identical to `550bc80` (the M8 acceptance). Harness: `test/gas/GasG02.t.sol` (committed for reproducibility; logs values, asserts nothing about gas); command `forge test --match-contract GasG02 -vv`. Two consecutive runs gave identical values.

**Method.** One external call per test, `gasleft()` immediately before and after it. All arguments and contract references (params struct, token, Pool and account addresses held in test storage) are copied to locals before the first reading, so no test-contract `SLOAD` is inside the interval; the ABI encoding of the call is inside, the 21,000 intrinsic cost and calldata cost are not. Each measured call is a top-level call under `isolate = true`, so the state it touches is cold. Tier 0 `MockERC20` (18 decimals); Pool seeded by alice with (1000e18, 2000e18); alice is payer and recipient with non-zero token and LP balances and approvals of `type(uint256).max`. Single scenarios, not averages.

| Function | Scenario | Gas |
|---|---|---:|
| `addLiquidity` | initial deposit (1000e18, 2000e18) into an empty Pool | 232,004 |
| `addLiquidity` | later, caps (1e18, 1e19), token0 cap binds, token0 first (G05 P1 conditions) | 108,814 |
| `addLiquidity` | later, caps (1e19, 2e18), token1 cap binds, `token1First` | 109,052 |
| `removeLiquidity` | 1e18 shares, recipient = caller | 94,105 |
| `removeLiquidity` | all of alice's shares (LP balance → 0) | 94,144 |
| `swapExactInput` | 1e18 token0 in | 82,539 |
| `swapExactInput` | 1e18 token1 in | 82,587 |
| `getAmountOut` | 1e18 token0 in (view) | 8,474 |
| `getReserves` | view | 7,376 |
| `sync` | no deficit (no-op) | 40,067 |
| `sync` | token0 deficit of 1e18 (`MockDeficitERC20`) | 44,774 |
| `skim` | surplus of 1e18 in both tokens | 101,777 |
| `skim` | no surplus (no-op) | 39,905 |
| LP `transfer` | 1e18 to an account with LP balance 0 | 54,879 |
| LP `approve` | 0 → 1e18 | 49,430 |
| LP `transferFrom` | allowance `type(uint256).max` (not decreased), recipient balance non-zero | 57,659 |
| `AMMFactory.createPair` | new pair of two deployed tokens | 2,316,864 |
| deployment | `new AMMPool(token0, token1, recipient)` | 2,422,397 |
| deployment | `new AMMFactory(recipient)` | 2,838,448 |
| calibration | `MockERC20.balanceOf` (top-level call) | 5,479 |

Sizes (`forge build --sizes`): `AMMPool` runtime 10,553 B / initcode 11,709 B; `AMMFactory` 12,770 B / 12,968 B (the Factory embeds the Pool's initcode).

**Comparability.** The archived G05 harness (`GasM8`), run unchanged on a `git archive` copy of the final code, reproduces its own values exactly (P1 108,789, P5 231,979, deployment 2,426,562). The G02 values differ from those by harness effects only: G05 read the token addresses from test storage inside the interval for the deployment (G05 +4,165, consistent with two cold `SLOAD`s of 2,100 each; not separately measured), and its deposit measurement differs by 25 gas (G05 108,789, G02 108,814) for harness reasons not isolated further. G02 values are therefore not to be subtracted from G05 values; comparisons use one harness.
**Isolated variants (M10 decision 4: measured only, production adoption decided separately).** Each variant is a `git archive` copy of `a135693` in the scratchpad with only `src/AMMPool.sol` changed; the repository's `src/` was not modified. Same configuration and harness; full suite (all tests except `GasG02`, 470 tests, default fuzz runs) run on each copy.
- **VP — packed reserves:** `reserve0` / `reserve1` as `uint112` in one storage slot; all 12 writes through OpenZeppelin `SafeCast.toUint112`, which reverts above `2^112 − 1`. This adds a new numerical boundary (Uniswap V2 style) that the approved ranges (§6.6, U6 / A4) do not have.
- **VU — `unchecked` on proven-safe arithmetic:** 14 blocks: `gross − 1000` after its check; reserve decreases in `removeLiquidity` (`amount_i ≤ r_i`) and swap (`out < rOut`); reserve increases in swap and later deposit (`r + n ≤` Pool balance, §6.6 "Reserve updates"); `u_i` (matched amount `≤ n_i`); the guarded comparisons in BI-2′, payer debit, `skim` and `_pushMeasured`. Not changed: the inbound measurement `after − before` (its Panic is the intended reaction to an unsupported token, §6.6) and the checked `S + σ`.

| Function / scenario | G02 base | VP Δ | VU Δ |
|---|---:|---:|---:|
| `addLiquidity` initial | 232,004 | −21,567 | −330 |
| `addLiquidity` later, token0 cap binds | 108,814 | −4,298 | −534 |
| `addLiquidity` later, token1 cap binds, `token1First` | 109,052 | −4,298 | −534 |
| `removeLiquidity` partial / full exit | 94,105 / 94,144 | −4,292 | −394 |
| `swapExactInput` token0 in / token1 in | 82,539 / 82,587 | −4,292 / −4,295 | −263 |
| `getAmountOut` / `getReserves` | 8,474 / 7,376 | −2,056 | 0 |
| `sync` no deficit / token0 deficit | 40,067 / 44,774 | −1,899 / −1,667 | 0 |
| `skim` both tokens / no surplus | 101,777 / 39,905 | −1,935 | −278 / 0 |
| LP `transfer` / `approve` / `transferFrom` | 54,879 / 49,430 / 57,659 | 0 | 0 |
| `createPair` | 2,316,864 | +147,588 | −27,467 |
| deployment `AMMPool` / `AMMFactory` | 2,422,397 / 2,838,448 | +159,273 / +159,279 | −29,565 / −29,578 |
| `AMMPool` runtime / initcode size | 10,553 / 11,709 B | +736 / +736 B | −137 / −137 B |
| Full suite (470 tests) | 470 passed | **457 passed, 13 failed** | 470 passed |

VP failures, all at reserve values above `2^112` (`SafeCastOverflowedUintDowncast`, or a test that classifies reverts and does not accept that error): `test_M4H2_productAbove2pow256QuotientFits`, `test_Z06_denominatorBoundary`, `test_Z06_extremeCapCorners`, `test_Z08i_oneSideSaturates_otherFits_succeeds`, `test_Z08iv_replanSaturates_requestIsCap`, and the fuzz tests `testFuzz_F1T1_extremeRequest`, `testFuzz_Q01_quoteEqualsSwap`, `testFuzz_Q04_zeroQuoteSwapReverts`, `testFuzz_Z01_S11_S15_swapMatchesFormula`, `testFuzz_Z03_mixedDecimalsNearTop`, `testFuzz_Z06_laterDepositMatchesOracle`, `testFuzz_Z08_differentialOracle`, `testFuzz_Z09_invariants`. These are range changes, not wrong values: adopting VP would require a new approved range (U6 / A4), revised tests and a new error case.

**Reading.** VP saves about 4,300 gas per add, remove and swap and about 21,600 on the initial deposit (consistent with one storage slot instead of two for the reserves; the causes were not measured separately), but costs about 159,000 once per deployment and narrows the supported reserve range to `2^112`. VU saves 263–534 per state-changing call and about 29,600 per deployment, with no test difference; its safety rests on the proofs listed above, which become load-bearing (an error in them would wrap instead of revert). The combination VP + VU was not measured. Status: measured; **neither VP nor VU adopted** (student, 2026-11-23, DECISIONS M10-4).
### 14.7 M11 architecture gas review (2026-11-23; review and isolated experiments only, no production change)

**Baseline:** `m11-report` at `a85cd8d` (`src/` logic identical to `550bc80`). **Experiments:** local branch `m11-gas-exp` (worktree in the scratchpad, not merged): `01321dc` candidate A, `7fe4c43` candidate B micro-benchmark, `9a5f1e5` follow-up (mixed `maxDebit` settings, clone no-read control). Same toolchain and configuration as §14.6 (`forge config` checked); harness `GasM11` uses the G05/G02 method (one call, `gasleft()` around it, `isolate = true`, Pools seeded (1000e18, 2000e18), alice payer and recipient). Baseline values were measured on a `git archive` copy of `a85cd8d` with the same harness. Separate from the M11 final regression (§10.6 of the report).

**Where the gas goes (traces of the G02 calls, `forge test -vvvv`).**
- `createPair` 2,313,872 inside the call, of which `new AMMPool` 2,159,325 (93 %); the registry writes and event are the rest.
- Later deposit (ordinary tokens): 14 `balanceOf` calls (4 cold at 2,559 gas, 10 warm at 559: ≈ 15,800) and 2 `transferFrom` (11,320 each).
- Swap: 8 `balanceOf` (3 cold, 5 warm), 1 `transferFrom` (13,320), 1 `transfer` (8,881). Remove: 10 `balanceOf` (4 cold, 6 warm), 2 `transfer`. Initial deposit: 12 `balanceOf` and 2 first-time `transferFrom` (28,420 each, zero-to-non-zero Pool balances).

**The 14 balance readings of a later deposit (object, time, protection).** Identical for ordinary and L46-style taxed tokens: the tax changes the token's own cost and the excess, not the number of readings; a re-plan adds none.

| # | Object | Time | Protection |
|---|---|---|---|
| 1–2 | Pool, both tokens | entry (`_checkNoDeficit`) | deficit block (M6-2) |
| 3–4 | Pool, both tokens | start snapshot | BI-2′ baseline (M8-11) |
| 5–6 | payer, both tokens | start snapshot | `maxDebit` baseline (M8-3) |
| 7–8 | Pool, first token | around its `transferFrom` | measured receipt `n_f` |
| 9–10 | Pool, second token | around its `transferFrom` | measured receipt `n_s` |
| 11–12 | Pool, both tokens | after the last transfer | BI-2′ end |
| 13–14 | payer, both tokens | after the last transfer | `maxDebit` end |

Earlier reuse variants (§14.5) target readings 1–4 (VC), 3 with 7 (VB) and 9/10 with 11/12 (VA); they are not re-evaluated here (no new architectural reason).

**Candidate A — skip the payer readings when `maxDebit_i = type(uint256).max` (measured).** With an unbounded `maxDebit_i` the comparison `debit > maxDebit_i` can never be true, so readings 5/13 (token0) and 6/14 (token1) are skipped per token.

| Later deposit (harness `GasM11`) | Baseline | Candidate A | Δ |
|---|---:|---:|---:|
| ordinary tokens, `maxDebit` MAX (G05 P1 conditions) | 108,789 | 104,943 | **−3,846** |
| ordinary tokens, `maxDebit` finite | 108,165 | 108,292 | +127 |
| token1 10 % tax pulled second, `maxDebit` MAX | 177,899 | 173,917 | **−3,982** |
| token1 10 % tax pulled second, `maxDebit` finite | 177,275 | 177,402 | +127 |
| token1 10 % tax pulled first (re-plan), `maxDebit` MAX | 178,301 | 174,319 | **−3,982** |
| ordinary tokens, `maxDebit` (MAX, finite 2e18) (`9a5f1e5`) | 108,477 | 106,617 | **−1,860** |
| ordinary tokens, `maxDebit` (finite 1e18, MAX) (`9a5f1e5`) | 108,477 | 106,618 | **−1,859** |
| swap / remove (control) | 82,510 / 94,076 | 82,510 / 94,076 | 0 |

- Full suite on the variant (all tests except the gas harnesses): 472 / 472 passed. At `9a5f1e5`, the whole worktree including the harnesses: `forge test` 509 / 509 in 57 suites (492 project tests + 11 `GasM11` + 6 `GasM11Clone`).
- Mixed settings (`9a5f1e5`; same deposit: token0 first, token0 cap binds, actual debits (1e18, 2e18), cold state): each finite side still binds on both the baseline and candidate A. A bound equal to the actual debit succeeds and debits exactly (1e18, 2e18); one unit tighter reverts `PayerDebitTooHigh` with balances and supply unchanged (`test_mixed_finiteToken0StillBinds`, `test_mixed_finiteToken1StillBinds`). The saving of one skipped side (≈ 1,860) is about half of the two-sided saving (3,846). The L46 example uses finite bounds and gains nothing.
- Who pays: callers with a finite `maxDebit` pay +127; callers with an unbounded `maxDebit` save ≈ 3.5 % (ordinary) or ≈ 2.2 % (taxed). Deployment size changes slightly (not separately measured).
- Behaviour: identical for every token whose `balanceOf(payer)` succeeds: payer debit (the bound is vacuous at MAX), Pool receipt, `maxExcess`, BI-2′ and reentrancy protection are unchanged; token support is unchanged. One difference: an unsupported token whose `balanceOf(payer)` reverts no longer makes a MAX-bounded deposit revert at the snapshot. No existing test distinguishes the two.
- Why it is safe for ordinary tokens [source]: for Tier 0 the payer's debit equals the amount requested, which is already bounded by `RequestMax_i`; `maxDebit` adds protection only for tokens with extra sender-side charges, where a caller should keep it finite.
- Needs a student decision: it changes the implementation of the approved M8-3 rule ("snapshot the payer always") to "snapshot the payer only when the bound can bind"; ABI unchanged. Recommendation: **adopt** if a per-call saving of ≈ 3.8–4.0k for the default setting is wanted; otherwise keep.

**Candidate B — shared implementation via ERC-1167 clones with immutable args (partly measured, partly estimated).** The Factory would deploy one implementation and, per pair, a clone carrying `(token0, token1, surplusRecipient)` in its code.
- Measured micro-benchmark (`GasM11Clone`): reading three addresses through a clone (DELEGATECALL + `Clones.fetchCloneArgs`) costs 9,143 vs 3,067 with immutables in a directly deployed contract: **+6,076 per call** (`7fe4c43`). Creating a clone with three address arguments: **115,240**.
- Control (`9a5f1e5`, one build, all four calls return the same value): direct 3,100 (reads immutables) / 3,146 (reads nothing); clone 9,172 (reads the arguments) / 5,734 (reads nothing). So **+2,588** is the clone path alone (ERC-1167 forwarding and a DELEGATECALL to a cold implementation), and **≈ +3,480** is fetching and decoding the arguments (`EXTCODECOPY` of the clone's own code); total **+6,072**. Clone creation in this build: 115,269. The small shifts from `7fe4c43` (≤ 33 gas) come from the extra function changing the selector dispatch. With one argument read per call, break-even stays ≈ 2,044,056 / 6,072 ≈ 336 calls per pair [estimate]; if arguments were never read the per-call cost would be ≈ 2,588 (≈ 790 calls) [estimate]; inside one transaction that reuses the same implementation the cold-access part becomes warm (not measured).
- Estimate (not measured on a full Pool): per pair, creation falls from 2,159,325 (the `new AMMPool` part of `createPair`) to ≈ 115,240, saving ≈ 2.04M once; every later Pool call (add, remove, swap, `sync`, `skim`, and LP `transfer` / `approve` / `transferFrom`) costs ≈ +6,100 or more (more if the arguments are fetched more than once per call). Break-even ≈ 2,044,085 / 6,076 ≈ 336 calls per pair; one implementation deployment (≈ 2.4M) is paid once and needs at least two pairs to be recovered. Assumptions: one argument fetch per call, the same cold/warm conditions as G02.
- Behavioural and architectural differences: constructor checks (sorting, `surplusRecipient` rules) move to the Factory; the LP `name`/`symbol` must be constants (OpenZeppelin `ERC20` stores them in the implementation's storage); Pools could no longer be deployed directly (most unit suites deploy them directly); the implementation must be unusable on its own; ownerless and immutable properties remain (no initializer is needed with immutable args). ABI of the Pool unchanged except possibly a guard; `AMMFactory` changes.
- Recommendation: **keep the current full-Pool deployment.** The saving is paid once per pair, while every user of every pool pays ≈ +6k per call forever (≈ +5.6 % on a later deposit, +7.4 % on a swap); an exchange's busy pools dominate total cost.

**VP / VU / VA–VC:** cited from §14.5 and §14.6; no new architectural reason found to re-open them (VU stays not adopted, student decision).

**Decision (student, 2026-11-23, DECISIONS M11-1):** candidates A and B are **evaluated, not adopted**; VU stays not adopted. The approved M8-3 rule (snapshot the payer's balance of both tokens on every deposit) and the full-Pool deployment are kept. Report §11.4 summarises both.
## 15. Mutation-check result classes (from M7, DECISIONS M7-7)

Mutants are applied temporarily by a scratchpad script that always restores `src/`. Each result is reported in one of three classes:

| Result | Meaning |
|---|---|
| Compiles, at least one test fails | Killed: the tests detected the behavioural error |
| Compiles, all tests pass | Survived: a possible test gap or an equivalent mutant; must be analysed and reported |
| Does not compile | Not compilable: does **not** count as a behavioural test success |

## 16. Static analysis: `forge lint` triage (M10, 2026-11-23)

Run on `src/` with forge 1.9.0 (`forge lint src`, and once per severity with `--severity high|med|low|info|gas|code-size`). No `[lint]` section in `foundry.toml`, so the defaults apply. Each finding was reviewed by hand; none changes code. Tools **not** run: slither, aderyn, mythril, halmos (not installed), Echidna / Medusa, formal verification (student decision 5, 2026-11-23).

| Severity | Lint | Location | Verdict | Reason / evidence |
|---|---|---|---|---|
| high | — | — | none reported | — |
| med | `uninitialized-local` | `AMMPool.sol:482` (`_pullLater`, `target1`) | False positive | `target1` is assigned on the `hi == 0` and `0 < hi < r0` paths; on the `hi ≥ r0` path it is unassigned but the `||` short-circuits on `hi >= r0` and the branch then assigns it before any use (Solidity also zero-initialises locals, so there is no undefined value). Step-2 results are checked against the reference formula by the Z06 differential and the M4H-2 tests |
| low | `block-timestamp` (3) | `addLiquidity`, `removeLiquidity`, `swapExactInput` deadline checks | Accepted | A deadline bounds staleness, not exact timing; a producer can shift the timestamp by seconds (THREAT_MODEL §6 item 6) |
| low | `reentrancy-events` (4) | `LiquidityAdded`, `LiquidityRemoved`, `Swap` after the token calls; `PairCreated` after `new AMMPool` | Accepted | The Pool must measure balances first; all three Pool functions are `nonReentrant` (THREAT_MODEL §6 item 9; reentrancy tests X01, X02, X05, W07). The Factory's only external code is the Pool constructor, which calls nothing (DECISIONS M7-4) |
| info | `screaming-snake-case-immutable` (4) | `token0`, `token1`, `surplusRecipient` (Pool), `surplusRecipient` (Factory) | Kept | Public getter names are part of the approved ABI (V2-style names); renaming would change the interface |
| info | `internal-function-used-once` (1) | `AMMMath.initialShares` | Kept | Library helper named after ARCHITECTURE §6.1 and tested directly in the maths-library tests |
| info | `pragma-inconsistent` (1) | `src/Counter.sol` (`^0.8.13`) vs `0.8.38` elsewhere | Resolved | The Foundry template was removed (`a585188`, DECISIONS M10-8); `forge lint src --severity info` no longer reports `pragma-inconsistent` |
| gas, code-size | — | — | none reported | — |

Test code: `forge lint` over the whole project adds 59 `environment-read-across-mutation` notes in tests (`block.timestamp` reused across `vm.revertToState` / `vm.warp`). They concern test code only (no production contract is affected); they were not reviewed one by one. Not changed.
