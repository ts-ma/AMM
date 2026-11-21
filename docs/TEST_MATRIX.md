# TEST MATRIX — Foundry Test Plan

**Last updated:** 2026-11-21

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
| L13 | Inflation scenario: after a large direct transfer by an attacker, a later LP's shares are not rounded to zero and the transfer does not enter reserves | M6 | `PASSED` (M6) — `test_L13_inflationAttemptFails` |
| L14 | `recipient ∈ {address(0), Pool}` reverts | M4 | `PASSED` — initial path (M3, `test_L21_invalidRecipientReverts`); later deposit (M4, `test_L14_invalidRecipientRevertsOnLaterDeposit`, `test_L14_recipientReceivesSharesAndEvent`) |
| L15 | Initial deposit with a taxed token ignores the hints and uses measured net | M8 | `NOT IMPLEMENTED` |
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

### 3.2 M8 measured-net deposit — planned tests (DECISIONS M8-1 to M8-13; all `NOT IMPLEMENTED`)

Plan only. IDs are final once the M8 decisions commit is made. Every revert asserts the exact error (M4-8) and full-state rollback: reserves, Pool / payer / recipient token balances, LP supply and balances, allowances. Every fuzz row states its success range, safe-revert inputs and uncovered boundaries (M5-7).

| ID | Description | Status |
|---|---|---|
| L30 | Interface (M8-5): new `addLiquidity` selector equals the approved struct signature, old selector absent; `LiquidityAdded` topic unchanged; X03 still 22 entries with exactly one approved replacement; `TaxedLaterDepositNotImplemented` / `NetAmountOutOfRange` absent from `src/` and the compiled ABI; map of each removed L26/L27 test to its replacing functional test | `PASSED` (M8 commit 2) — `test_L30_removedErrorsAbsentFromCompiledAbi`, `test_L30_liquidityAddedEventUnchanged`; selector and X03 parts: `test_X03_static_addLiquidityReplaced`, `test_X03_runtime_oldAddLiquiditySelectorFails`; mapping: §3.3 |
| L31 | First token delivers **less** than requested (taxed first token): the second request is re-planned from the measured net; the worked numbers of REPORT_NOTES §1.5 | `NOT IMPLEMENTED` |
| L32 | First token delivers **more** than requested (bonus token): re-plan capped by the second token's request cap; this covers the `min(...)` branch, so a mutant removing it is a test gap, not an equivalent mutant | `NOT IMPLEMENTED` |
| L33 | Both tokens taxed (fixed, unknown to the Pool), with each pull order | `NOT IMPLEMENTED` |
| L34 | Token0-first vs. token1-first on the same state: different unmatched amounts as predicted by the model; shares from measured net in both | `NOT IMPLEMENTED` |
| L35 | Second token delivers **zero** (100% tax mock): `σ == 0` → `InsufficientShares`, full rollback | `NOT IMPLEMENTED` |
| L36 | `maxExcess` boundary per token: `u == maxExcess` succeeds; `maxExcess = u − 1` → `ExcessContributionTooHigh` | `NOT IMPLEMENTED` |
| L37 | `maxDebit` boundary per token (inbound exclusive mock): debit `== maxDebit` succeeds, `maxDebit = debit − 1` → `PayerDebitTooHigh`; the success case does **not** assert future redeemability (M8-12 (4)) | `PASSED` (M8 commit 3) — `test/AMMPoolPayerDebit.t.sol`: `test_L37_plainTokens_bothPullOrders`, `test_L37_inclusiveFee_bothPositions_bothPullOrders`, `test_L37_exclusiveFee_bothPositions_bothPullOrders`, `test_L37_initialDeposit_exclusiveFee_bothPullOrders`, `test_L37_payerBalanceRises_countsAsZero_bothPositions_bothPullOrders`, `test_L37_randomTaxBothTokens_seeded_bothPullOrders` (seeds 1–8, fresh fixture per seed). Shared driver per case: limit above, equal (succeed, identical result), one unit over on token0, on token1, on both (`PayerDebitTooHigh`, full-state rollback) |
| L38 | Payer debited **extra during the whole call** by a cross-token callback (token0's hook slashes the payer's token1 outside token1's own window) → `PayerDebitTooHigh`; the same amount without the callback succeeds (shows that local windows would miss it) | `PASSED` (M8 commit 3) — `test_L38_crossTokenHook_bothDirections_bothPullOrders`: hook token as token0 and as token1 (both directions), each pull order; the limit covering only the deposit reverts, the limit including the slash succeeds with the clean-run result |
| L39 | Request cap is not a promise: the actual request is below the request cap after step 2 / re-plan; the payer's debit is measured, not assumed equal to the cap | `NOT IMPLEMENTED` |
| L40 | Check order (M8-13 (d)) when several conditions fail at once: the first error in the approved order is reported | `PayerDebitTooHigh` part `PASSED` (M8 commit 3) — before `InsufficientShares`, `ExcessContributionTooHigh` and the checked-supply Panic (each with a control run showing the later error alone); initial path: before `InsufficientInitialLiquidity`. `InCallBalanceLoss` part follows in commit 4 |
| B09 | In-call balance rule (M8-11, X1, `addLiquidity` only): (a) pre-existing surplus in both tokens, no foreign change → succeeds, surplus unchanged; (b) cross-token debit of the Pool **masked by surplus** (r1 = 1000, B1 = 1300, 200 removed during token0's pull, n1 = 500) → `InCallBalanceLoss`, full rollback; (c) extra GIFT during the first pull (B08 case) → succeeds, surplus increases by GIFT; (d) zero surplus with a cross-token debit → `InCallBalanceLoss`; (e) the comparison is written in subtraction form, and a fuzzed balance near `type(uint256).max` neither overflows nor passes wrongly | `NOT IMPLEMENTED` |
| B10 | BI-2′ is **not** extended: swap / remove with a masked foreign surplus decrease still succeed — a documented limitation test (THREAT_MODEL T30) | `NOT IMPLEMENTED` |
| L13b | Inflation via a self-chosen large `maxExcess` (THREAT_MODEL T4): attacker's loss ≥ about 1000 × per-share increase; victim's extra floor loss ≤ the per-share increase; victim protected by `minShares` / `σ > 0`; the attacker's net result is not better than without donating | `NOT IMPLEMENTED` |
| L42 | Re-planned second target is 0 → `InsufficientDepositAmount()` before the second `transferFrom` (DECISIONS M8-8): (i) the first token's measured net is 0 (100% tax mock); (ii) the first net is > 0 but the re-plan floors to 0; (iii) both cases with each pull order; (iv) full rollback: the first transfer's balance changes, reserves, supply and payer balances are restored; the second token's `transferFrom` is never called; (v) the exact error selector is asserted | `PASSED` (M8 commit 2) — `test_L42_firstNetZero_bothPullOrders`, `test_L42_firstNetPositiveReplanFloorsToZero_bothPullOrders`, `test_L42_randomTaxSeeded_bothPullOrders` (seeds 1–8), reverse test `test_L42_reverse_detectorsSeeTheSecondCall`. Zero calls are asserted by `vm.expectCall(token, transferFrom selector, 0)`, which matches any `transferFrom` call, and by a `MockFailure()` tripwire. Mutation: removing either re-plan zero check fails all three L42 tests (source restored, hash identical) |
| L43 | Canonical token order: with `token1First = true` and `false`, the return values `net0`/`net1` and the `LiquidityAdded` arguments are token0's and token1's measured nets, not first/second pulled | `PASSED` (M8 commit 2) — `test_L43_netsReportedInTokenOrder_bothPullOrders` (initial and later deposit; token0 1%, token1 3% tax, so the nets differ) |
| L41 | JIT capture of a victim's excess (T29): add before, remove after; the capture is bounded by the victim's `maxExcess` | `NOT IMPLEMENTED` |
| Z08 | Saturating arithmetic (M8-4): (i) one side's `n·S/r` ≥ 2^256, the other side fits → `σ` = the smaller side, proceeds; (ii) both sides saturate (`σ = max`) → Panic `0x11` from the checked `supply + σ`, unless `InCallBalanceLoss` or `PayerDebitTooHigh` fails first (asserted separately); `InsufficientShares` cannot fire here; (iii) one side saturates, the other is exactly `2^256 − 1` → same as (ii); (iii-b) `σ` in `(max − S, max)` with `minShares > σ` → `InsufficientShares`, with `minShares ≤ σ` → Panic `0x11`; in no case is `ExcessContributionTooHigh` reported or a share minted; (iv) re-plan saturates → request equals the request cap; 512-bit differential oracle over `[1, 2^256 − 1]` | (ii) `PASSED` (M8 commit 2) — `test_Z08_saturatedSharesPanicBeforeExcessCheck`; mutation: removing the checked addition gives `ExcessContributionTooHigh` instead, so the check is not optimised away. Other parts `NOT IMPLEMENTED` |
| Z09 | Fuzz: per-share reserves never decrease; BI-2′; debit `≤ maxDebit`; `u ≤ maxExcess`; random tax per transfer in `[0, 9999]`, reserves `[10^3, 2^112]`, requests `[1, 2^112]`, mixed 6/18 decimals | `NOT IMPLEMENTED` |
| X06 | Trapped-liquidity limitation (THREAT_MODEL §7.6), modes (A) outbound-only refusal, (B) all transfers revert, (C) `balanceOf` reverts: remove fails; in (A) X → Y swaps and new deposits still succeed, Y → X fails; repeated X → Y swaps drain Y and the LPs' redeemable value is recorded; restoring X makes exit work again | `NOT IMPLEMENTED` |
| X07 | Tax changes between deposit and withdrawal: an inclusive increase never triggers A8, MIN-NET decides; an outbound over-debit enabled after deposit → `OutboundTransferMismatch` (A8) | `NOT IMPLEMENTED` |

Test-method rules (student review, 2026-11-21):

- "Random" tax is reproducible: an explicit seed drives a deterministic pseudo-random sequence (`keccak256(seed, nonce)`), and an explicit FIFO schedule gives predictable boundary values. No environment randomness. A failing fuzz case can be replayed from its seed.
- Every mock has its own self-tests before it is used against the Pool: payer debit, recipient credit, who bears an inclusive fee, where an exclusive extra charge is taken, and full balance restore after a failed transfer.
- "Not called" assertions (L42) use both `vm.expectCall(..., 0)` and a tripwire: the guarded token reverts with a mock-only error (`MockFailure()`) if it is called, so a wrong path cannot be mistaken for the Pool's own `InsufficientDepositAmount()`.
- Each `token1First` path is tested separately for: one token taxed, both taxed, random tax, and failure rollback (L31–L35, L42, Z09 run with both values); L43 checks that `net0`/`net1` are token0's/token1's.
- L36 keeps the `maxExcess` boundary; L42 checks full rollback; L43 checks the canonical token order.
- X06/X07 are **limitation tests**: they document behaviour outside the supported model (trapped liquidity, A8 refusal) and never describe the inability to exit as supported.
- Migration of the existing tests (commit 2 of M8): every existing test calling the old `addLiquidity` or using a removed error is listed in §3.3 as kept, modified, replaced or retired, with the reason. A security test is never deleted only because its old parameters no longer exist; its property is re-tested under the new ABI or the retirement is justified.
- M8 mocks (commit 1, 2026-11-21): `test/mocks/MockFeeERC20.sol` (per-path inclusive tax 0–100%, exclusive extra, bonus, FIFO schedule, seeded random tax; call trace `callCount`, `lastTaxBps`) and `MockFailingERC20.Mode.RevertAllTransfers` (appended; numbering of existing modes asserted). Self-tests `test/FeeMocks.t.sol`: 20 tests, `PASSED` with default fuzz runs and with `FOUNDRY_FUZZ_RUNS=10000`; full suite 343/343.
- Commits 2–4 of M8 (struct ABI, `maxDebit`, BI-2′) are work in progress. The first functional acceptance happens only after commit 4, with the full suite passing.

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
7. **Not yet enforced (WIP):** `maxDebit0/1` (commit 3) and BI-2′ / `InCallBalanceLoss` (commit 4). Gas is not measured yet (G05).

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
| S05 | Taxed input: pricing and accounting use measured net | M8 | `NOT IMPLEMENTED` |
| S06 | Taxed output: minimum judged on recipient's actual receipt (e.g. min 100, receives 99 → revert) | M8 | `NOT IMPLEMENTED` (M8). Partial evidence from M5: `test_M5_3_eventFieldsAreDistinct` (taxed output, `min = netOut` succeeds) and `test_S08_swapOutbound_caughtFaulty_shortDeliveryRejectedByMinNet` (short delivery → `InsufficientNetReceived`) |
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
| R09 | Taxed token: `skim()` lowers the Pool balance by exactly the surplus; reserves unchanged | M8 | `NOT IMPLEMENTED` |
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
| X04 | Exclusive-FOT mock (over-debits the Pool) makes remove, swap and skim revert (A8) | M8 | `NOT IMPLEMENTED` |
| Z01 | Fuzz swap in `[1, 2^112]`: `out < rOut`; inequality holds; no unexpected revert | M5 | Maths level `PASSED` (M2); Pool swap `PASSED` (M5) — `testFuzz_Z01_S11_S15_swapMatchesFormula` (range in §5.0) |
| Z02 | Fuzz add then full remove: returns no more than contributed | M10 | `NOT IMPLEMENTED` |
| Z03 | Mixed 6/18-decimal scales near the top of the fuzz range | M10 | `NOT IMPLEMENTED` |
| Z04 | Fuzz gross vs. net for the U8 taxed mock | M8 | `NOT IMPLEMENTED` |
| Z05 | Fuzz L-α: for random `T` and `t < 10000`, implementation gross gives `net ∈ [T, T+1]` | M8 | `NOT IMPLEMENTED` |
| Z06 | **Arithmetic boundaries** for each formula in ARCHITECTURE §6.6: just inside the sufficient condition succeeds; beyond the overflow threshold reverts with the exact Panic; no wrong value returned | M5, M10 | `PASSED` for `getAmountOut` and `initialShares` (`test_Z06_*`); swap at Pool level `PASSED` (M5) — `test_Z06_denominatorBoundary` (largest `a` with `rIn·D + a·9970 ≤ 2^256 − 1` succeeds, `+1` reverts Panic `0x11` with full rollback), `test_Z06_aFeeOverflowReverts`; M4 formulas `PASSED`: L-α target — after M4H-2 it never overflows; `test_Z06_laterTargetOverflowTakesToken1Branch` (`2^255 − 1` → token0 branch, `2^255` → token1 branch instead of the former Panic), `test_M4H2_*` (3 tests, all three `mul512` paths), and the differential oracle `testFuzz_Z06_laterDepositMatchesOracle` / `test_Z06_extremeCapCorners` (file `test/AMMPoolDepositDifferential.t.sol`, DECISIONS M4H-3); redemption `test_W10_classA_*` (`type(uint256).max` → `ERC20InsufficientBalance`, no Panic). Analysed as unreachable before another check fails, so not separately testable: the other L-α branch (`T0 < amount0Max`), later-share `mulDiv` (bounded by the targets), reserve additions (bounded by token supply). Others M8/M10 |
| Z07 | **Business-invariant boundaries** (DECISIONS M4-7): `T_i == 0`, `shares == 0`, `amount_i == 0`, `[T, T + 1]`, `minShares`, `min_iNet`, the 1,000 lock — value at the boundary succeeds or fails exactly as specified, with the exact custom error | M4 | `PASSED` (M4) — `test_Z07_targetZeroBoundary`, `test_Z07_targetZeroBoundaryToken0Side`, `test_Z07_zeroSharesReverts`, `test_Z07_zeroOutputBoundary`; `[T, T+1]` lower side `test_L26_*`; `minShares` `test_L08_*`; `min_iNet` `test_W04_*`/`test_W05_*`; lock `test_W06_*`/`test_W11_*` |

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
| G01 | `swapExactInput` gas with and without the on-chain §6.5 assertion | Input to the A9 decision | M5 | Measured 2026-11-19 (§14.2); A9 decided: tests only (DECISIONS M5-9) |
| G03 | Cost of the M6 deficit entry check; M6-3 snapshot-reuse variant B vs. A | Input to the B decision (DECISIONS M6-3) | M6 | Measured 2026-11-19 (§14.3); B not adopted (DECISIONS M6-8) |
| G04 | `createPair` gas (one measurement, configuration recorded) | Report only; no optimisation (DECISIONS M7-7) | M7 | Measured 2026-11-20 (§14.4) |
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

## 15. Mutation-check result classes (from M7, DECISIONS M7-7)

Mutants are applied temporarily by a scratchpad script that always restores `src/`. Each result is reported in one of three classes:

| Result | Meaning |
|---|---|
| Compiles, at least one test fails | Killed: the tests detected the behavioural error |
| Compiles, all tests pass | Survived: a possible test gap or an equivalent mutant; must be analysed and reported |
| Does not compile | Not compilable: does **not** count as a behavioural test success |
