# MILESTONES — Plan and Progress

**Last updated:** 2026-11-23
**Deadline:** 2026-11-27, 12:00 UK time

Workflow rules: root `CLAUDE.md`. Status labels: [DECISIONS.md](DECISIONS.md) §0.

## 1. Current status

| Item | Status |
|---|---|
| Architecture documents (`docs/`, five files) | Maintained per milestone; M6 decisions and results recorded (DECISIONS §13); M7 decisions approved 2026-11-20 (DECISIONS §14); M7 accepted 2026-11-20; M8 decisions approved (DECISIONS §15: measured-net deposit; M8-11 in-call balance invariant `APPROVED` and implemented; M8-9 / R7 decided 2026-11-23: `LiquidityAdded` unchanged, option A); F1 inflation finding recorded as a known economic limitation (THREAT_MODEL T4, 2026-11-22); F1 follow-up tests T1–T3, T5–T9 executed, T4 deferred (TEST_MATRIX §3.4); M8-2 confirmed as an absolute bound, percentage alternative recorded (2026-11-23); report draft material in `docs/REPORT_NOTES.md` |
| Git | M1, M2, M3 accepted (tags `m1-setup-accepted`, `m2-pool-skeleton-accepted`, `m3-lp-initial-deposit-accepted`, merged to `main`); M4 accepted (tag `m4-deposit-withdraw-accepted`, merged to `main`); M4 hardening accepted (tag `m4-hardening-accepted` on `d355fec`, merged to `main`); M5 accepted (tag `m5-swap-accepted` on `deb66ba`, merged to `main`); M6 accepted (tag `m6-sync-skim-accepted` on the M6 acceptance docs commit, merged to `main`); M7 accepted (tag `m7-factory-accepted` on `26ac725`, merged to `main`); M8 accepted 2026-11-23 (tag `m8-measured-deposit-accepted` on the acceptance commit, merged to local `main` by fast-forward; not pushed): docs `5c87a38`, `c83692c`, `eb61423`; mocks `5d807b6`; features `0582394`, `8df2e55`, `9caf253`; tests `d3103ab`, `d974d53`, `4dee364`, `b5b3dac`, `ef817fd`, `14332b7`; F1 docs `0de1e4e`; step-1 docs sync `8f294b9`; G05 `feaf76b`; R7 `0097292`; M8-2 absolute `maxExcess` `cbc7aea`; F1 follow-up tests T1 `b561f7b`, T2 `0d20d45`, T5 `78285f0`, T6 `c20a5ee`, T7 `c256a39`, T8 `58a2cbb`, T9 `bcac4dd`, T3 `d0f9146`; pre-acceptance docs check `e9e606b`; final test results `eb4ef9d`; acceptance items `1ee1d88`; acceptance (this commit); M10 accepted 2026-11-23 (tag `m10-verification-accepted` on the M10 acceptance commit of branch `m10-verification`; not merged to `main`, not pushed by Claude) |
| AMM contracts | `AMMPool`: constructor checks, LP ERC-20 with `_update` supply controls, `addLiquidity(IAMMPool.AddLiquidityParams)` (M8: measured-net initial and later deposit with 1,000 lock, caller-selected pull order, re-plan, `maxDebit`, `maxExcess`, BI-2′ `InCallBalanceLoss`; ARCHITECTURE §7.2), `removeLiquidity` with MIN-NET and A8 (terminal-pool rule M4-3r), `swapExactInput` (measured input, A8, MIN-NET), deficit entry check `ReserveDeficit` on add/remove/swap, downward-only `sync`, per-token `skim` with A8, terminal-pool rules, `getAmountOut`, `getReserves`; `AMMMath`: quote (returns 0 for zero output), initial shares; `AMMFactory` (M7): `createPair` with zero / identical / sort / code-existence / uniqueness checks, both-order `getPair`, `allPairs`, shared immutable `surplusRecipient`, `PairCreated` |
| Tests | **M10 acceptance, 2026-11-23 on `a585188` (after the Counter removal): 488 tests in 54 suites; `forge test` with default fuzz runs and `FOUNDRY_FUZZ_RUNS=10000 forge test` both 488 passed, 0 failed.** Before the removal, on `bdfff12`: 490 in 55 suites, both settings passed (+24 since `a12a7f6`: L45 regression 1, AMMFactoryInvariant 1, AMMPoolMixedDecimalsTop 1, AMMPoolSmallPosition 1, GasG02 20). Earlier M10 count: 466 in 51 suites on `a12a7f6` (configuration checked with `forge config`: solc 0.8.38, optimizer 200 runs, `osaka`, `via_ir = false`, `isolate = true`, forge 1.9.0; the two invariant campaigns run 256 × 500 calls each in both settings, set inline). New in M10: AMMPoolTaxedSwapRemove 5, AMMPoolRoundTrip 3, AMMPoolInvariantTier0 1, AMMPoolInvariantTaxed 1, AMMPoolMaxExcessTier0 2, AMMPoolMixedDeficitSurplus 3, AMMPoolFirstDepositBranch 4, AMMPoolTaxedSkim 2, AMMPoolSwapOnlyMintBound 1 (+22). M8 acceptance: **444 in 42 suites: result of the final pre-acceptance full-suite run** (2026-11-23, on `e9e606b`, after `forge clean`; `forge test` with default fuzz runs and `FOUNDRY_FUZZ_RUNS=10000 forge test`, 444 passed and 0 failed in each; configuration checked with `forge config`: solc 0.8.38, optimizer 200 runs, `osaka`, `via_ir = false`, `isolate = true`, forge 1.9.0). The commit that records this row changes docs only. The acceptance commits `1ee1d88` and the acceptance commit itself change only docs and comments; the acceptance commit was re-verified with `forge build` and both full-suite runs before tagging, with the results in the acceptance report. Per suite: AMMFactory 28, AMMFactoryIntegration 8, AMMFactoryIsolation 6, AMMFactoryOwnerless 6, AMMMath 27, AMMPool 15, AMMPoolDeficit 12, AMMPoolDeposit 24, AMMPoolDepositDifferential 2, AMMPoolF1DistributedVictims 1, AMMPoolF1ExtremeRequest 16, AMMPoolF1HonestLP 2, AMMPoolF1LargeRelativeLoss 5, AMMPoolF1QuoteProtection 1, AMMPoolF1Redemption 4, AMMPoolF1SurplusAccounting 5, AMMPoolF1SwapFeeChannel 4, AMMPoolInCallBalance 12, AMMPoolInflation 8, AMMPoolLiquidity 35, AMMPoolM8Limitations 5, AMMPoolM8Scenarios 7, AMMPoolMaxExcess 3, AMMPoolMeasuredDeposit 8, AMMPoolMeasuredDifferential 5, AMMPoolOwnerless 7, AMMPoolPayerDebit 11, AMMPoolReentrancy 18, AMMPoolReplan 4, AMMPoolSkim 14, AMMPoolSwap 37, AMMPoolSync 8, AMMPoolSyncSkimReentrancy 10, AMMPoolSyncSkimScenarios 5, AMMPoolTerminal 14, AMMPoolWithdraw 20, Counter 2, DeficitMock 4, FeeMocks 20, MockERC20 7, OutboundMocks 6, SwapMocks 8 (changes in older suites follow the M8 migration map, TEST_MATRIX §3.3). History: 323 at M7 acceptance; 406 on `14332b7` (2026-11-22, both run settings); +38 F1 follow-up tests (TEST_MATRIX §3.4) |
| Dependencies | forge 1.9.0, forge-std 1.17.0, OpenZeppelin Contracts v5.7.0 (all plain directories, not submodules); compiler pinned per U12 |
| Gas measurements | M4 hardening (TEST_MATRIX §14.1); M5 G01 swap assertion (§14.2); M6 G03 deficit check and snapshot reuse (§14.3); M7 G04 `createPair` (§14.4); M8 G05 `addLiquidity` measured 2026-11-22 (§14.5: +10,264 gas, +10.4%, on the G03-comparable path; reuse variants measured, none adopted, current implementation kept (student, 2026-11-23); R7 decided 2026-11-23, option A); G02 measured in M10 (§14.6; isolated variants VP / VU not adopted) |
| M10 (accepted 2026-11-23) | Branch `m10-verification`, base `550bc80` (pushed to `origin` by the student up to `dd45777`; `a585188` and `8c4bee5` local). Tag `m10-verification-accepted` on the acceptance commit; not merged to `main`, not pushed. First batch: read-only review (findings ① docs, ② limitations, ③ conditional risks; reported to the student). Commits: `9b9ee25` docs errata (DECISIONS §0.1 supersession table, ARCHITECTURE §6.6 M8 ranges and §7 guard wording, THREAT_MODEL stale items); `6868ab7` S05, S06, Z04 (swap / remove); `acbb9f8` Z02; `1393489` stateful invariants I1–I3, I7 (BI-5), I9, I10 (I4 evidence reused); `64abd27` L44 Tier 0 `maxExcess` setting; `5ab02b7` R23 mixed deficit / surplus with explicit `sync()`; `260e113` L45 first-deposit branch change; `fd19b46` R09 taxed `skim`; `a12a7f6` Z10 swap-only LP mint upper bound + REPORT_NOTES §2 (retracted `minShares` claims, scoped statements); `1af3c1d` status; `eb957f2` L45 slight-skew regression (initial-path `minShares` does not detect every front-run); the next docs commit: scope revisions of the review ① items (D8/U1 lock share, Gate R scope, unmatched contribution, necessary reserve interval for `minShares`, first deposit, deficit loss), ② disclosures (REPORT_NOTES §3), per-token mapping (ARCHITECTURE §7.10), ABI re-review item (DECISIONS §8) = `cd7e3a3`; `ff2265d` I6 (`maxDebit` boundary in the handler); `2d1a843` I8 (no other address credited by `skim`); `60a3556` I5 Factory registry invariant; `ba76562` Z03 mixed 6/18 decimals near `2^112`; `e59265a` W12 small-position threshold; `8f1bd7b` `forge lint` triage (TEST_MATRIX §16); `a135693` G02 harness and baseline (§14.6); `bdfff12` G02 isolated variants VP (uint112 packing) and VU (`unchecked`), none adopted; `dd45777` status; `a585188` Counter template removed; this commit (acceptance, DECISIONS §16). No change to `src/`, `foundry.toml` or `lib/` since `550bc80`. Decisions at the acceptance (DECISIONS §16): VP / VU not adopted; Counter removed; no imported Uniswap V2 comparison. tools not run: slither, aderyn, mythril, halmos (not installed), Echidna / Medusa, formal verification |
| M11 (in progress) | Branch `m11-report` from `8c4bee5` (local). Batch 1: `8bc2682` L46 worked deposit example; `3ca2c36` report draft; `87a557f` `@custom:report` tags in `src/` (comment-only, bytecode without CBOR metadata identical); `cec9cc1` status. Batch 2 (after reading the latest `Coursework.docx`: report max 10 pages, components explained piece by piece, code and report cross-referenced, 10-minute talk + 5 minutes of questions): `13eabe1` ignore the brief and the generated PDF; `44e3496` R24 deficit top-up; `4ee281a` report condensed and corrected (§2.3, §3.2, §3.3, §4.4, §5.2, §9.2); `b80c5a8` talk plan `docs/TALK.md`; this commit (regression record). Regression on `b80c5a8`: `forge test` and `FOUNDRY_FUZZ_RUNS=10000 forge test`: 491 tests in 55 suites passed. PDF built from `docs/REPORT.md` (Edge print, A4, 10 pt): 7 pages, `REPORT.pdf` (git-ignored). Open: student review; `main --ff-only` merge and push need separate approval |

Accepted so far: M1, M2, M3, M4, M4 hardening, M5, M6, M7, M8, M10 (2026-11-23). Only the student accepts milestones.

## 2. Workflow per milestone

1. **Before:** explain the milestone's decisions in simple Chinese (why needed, options, trade-offs, recommendation); get approval for every relevant `PROPOSED` / `PENDING` item; propose a branch and wait for approval before creating or switching.
2. **During:** one feature at a time; explain unfamiliar Solidity syntax before using it; implement tests with the feature; verify; one focused Conventional Commit per verified feature; 1–2 sentence update after each commit.
3. **End:** stop; Chinese report with the eight sections of `CLAUDE.md` §5; 2–3 conceptual questions; update `docs/`.
4. **Gate:** wait for approval before tagging, merging, or starting the next milestone.

Never: merge, push, rewrite history or delete branches without approval; claim unexecuted tests passed.

## 3. Plan

Dates are targets, not commitments.

| M | Scope | Needs approval first | Acceptance | Tests | Target |
|---|---|---|---|---|---|
| M0 | Repository and brief review; decisions; five documents | — | Student approves documents | — | 11/17 |
| M1 | `chore`: pin `solc` / optimizer / `evm_version`, install OpenZeppelin v5.x + remapping. `test`: `MockERC20` (18/6 decimals) and its tests. Counter kept. No AMM logic | U12 values (approved 2026-11-17) | Actual `forge build` / `forge test` / `forge config` output; no protocol code | T01–T05 | 11/17–18 |
| M2 | Pool skeleton: constructor and four recipient checks, immutables, reserves, `getReserves`; pure maths (swap quote, sqrt) | Signatures, error names | Maths equals reference cases; constructor checks | K01–K04, R01, S02/S14 (pure), Z06 (pure) | 11/18 |
| M3 | LP ERC-20; initial deposit; lock in `address(this)` | LP `name`/`symbol`; LP-SELF override mechanism | Supply accounting; BI-7; lock review rules hold | L01, L02, L07, P01–P06 | 11/18 |
| M4 | Later optimal deposit (Tier 0, full U10 signature) and proportional withdrawal with MIN-NET and A8 | Signatures, events (approved, DECISIONS §11) | Ratios, fairness, minima, atomicity, dust, BI-2/5/6, lock untouched | L03, L04, L06, L08, L11, L12, L14, L26, L27, W01–W06, W08–W11, B01 (later), B02, B06, B07, Z06 (M4 formulas), Z07 | 11/19 |
| M5 | `swapExactInput`, `getAmountOut`, 30 bps, `ReentrancyGuard` | Signatures, events; **A9 final choice after G01** | Both directions, MIN-NET, reentrancy, exact formula, inequality, references | S01–S04, S08–S15, Q01–Q03, W07, X01–X03, B03, Z01, Z06, G01 | 11/20 |
| M6 | Downward-only `sync()`, per-token `skim()`, deficit entry checks, terminal-pool rules | Approved (DECISIONS §13; zero-reserve rule = M6-1 option A); B snapshot reuse decided after the benchmark (M6-3) | Surplus isolation, deficit rules, A2, order independence, zero-reserve recovery, mutation check (M6-6) | R02–R08, R10–R22, S07, L13, B01, B04–B06, B08, X01 (M6 extension), X03 | 11/21 |
| M7 | `AMMFactory` | Approved (DECISIONS §14): shared immutable recipient (M7-1), code check in the Factory only (M7-2), Pool does not store `factory` (M7-3), terminal pairs blocked and disclosed (M7-5) | Uniqueness, reverse lookup, isolation, Factory integration + codehash equivalence (M7-6), size, ownerless ABI, mutation check (TEST_MATRIX §15), G04 | F01–F07, F04b, X03-F, G04 | 11/21 |
| M8 | Measured-net deposit (P1+, X1): `AddLiquidityParams` ABI, measured nets with caller-selected pull order and re-plan, `maxDebit`, `maxExcess`, BI-2′; fee mocks; limitation tests. *Original plan (L-α, taxed mocks, `[T, T+1]`) superseded by DECISIONS M8-1.* | DECISIONS §15 M8-1 to M8-13 (approved); M8-9 / R7 decided (option A) | Request ≤ `RequestMax`; payer debit ≤ `maxDebit`; `u ≤ maxExcess`; BI-2′; error order M8-13 (d); limitations X06 / X07 / B10 documented; F1 recorded (THREAT_MODEL T4) | TEST_MATRIX §3.2 (L13b, L30–L43, Z08, Z09, X03, X06, X07, B10) and the §3.3 migration | 11/22–23 |
| M9 | Protocol fee | — | **Not in scope** (`FUTURE-ONLY`); needs fresh approval | C01–C07 | — |
| M10 | Fuzz, stateful invariants, static review, whole-contract gas profiling after M8 on the final code (DECISIONS §6); taxed-token swap / remove / skim tests moved from M8 at its acceptance (2026-11-23) | — | Actual results; open limitations; reproducible gas data | I1–I9, Z02, Z03, Z06, G02; from M8: S05, S06, R09, Z04 (swap and remove part) | 11/24 |
| M11 | Report, code/report cross-references, talk preparation; optional: tidy the F1 Python models into the repository so the fixed test constants can be regenerated (not required for M8) | — | Every main function, trade-off, limit and real result explained | — | 11/25–26 |
| — | Buffer and submission | — | — | — | 11/27 morning |

Write the matching report section during each milestone, not only in M11.

## 4. Commit boundaries (recommended)

| Milestone | Expected commits |
|---|---|
| Baseline | `chore`: initial Foundry project, workflow and architecture docs (§5) |
| M1 | `chore`: compiler config and OpenZeppelin; `test`: MockERC20 and tests |
| M2 | `feat`: maths helpers + tests; `feat`: Pool skeleton + tests |
| M3 | `feat`: LP token, initial deposit and lock + tests |
| M4 | `docs`: M4 decisions; `test`: outbound-failure mocks; `feat`: Tier 0 later deposit + tests; `feat`: `removeLiquidity` + tests; `docs`: M4 results (DECISIONS M4-9) |
| M5 | `docs`: M5 decisions; `test`: reentrancy / no-return mocks; `feat`: `swapExactInput` + tests; `feat`: `getAmountOut` + tests; `test`: reentrancy suite and ownerless ABI checks; `docs`: G01 result (then A9 decision); `docs`: M5 results (DECISIONS M5-8) |
| M6 | `docs`: M6 decisions; `test`: `MockDeficitERC20`; `feat`: `sync` + tests; `feat`: deficit entry check + tests; `feat`: terminal-pool rules + tests; `feat`: `skim` + tests; `test`: cross-state / reentrancy scenarios; `docs`: gas and B benchmark (then B decision); `docs`: M6 results (DECISIONS M6-7) |
| M7 | `docs`: M7 decisions; `feat`: `AMMFactory` + F01–F03, F05; `feat`: token code-existence check + tests; `test`: Factory ownerless ABI (X03-F); `test`: Factory integration and codehash equivalence (F06); `test`: isolation and terminal-pair scenarios (F04, F04b); `docs`: F07, G04, mutation results, M7 results (DECISIONS M7-8) |
| M8 | *Planned (superseded by DECISIONS M8-1):* `test`: taxed and exclusive-FOT mocks; `feat`: L-α + tests; `feat`: taxed-output handling + tests. *Actual:* `docs`: decisions and ABI; `test`: fee mocks; `feat`: struct ABI + measured net + `maxExcess`; `feat`: `maxDebit`; `feat`: BI-2′; `test`: commits 5a–5f; `docs`: F1, docs sync, G05, R7, M8-2; `test`: F1-T1 to T9 except T4 (one commit per group); `docs`: pre-acceptance check and results |
| M10 | `test`: fuzz / invariants; `docs`: gas data |
| Every milestone | `docs`: keep `docs/` current |

Boundaries may change when needed to keep each commit atomic and reviewable.

## 5. Baseline commit (`APPROVED` contents; runs on "开始")

**Contents:** `CLAUDE.md`, `README.md`, `foundry.toml` (unchanged), `lib/forge-std/`, `src/Counter.sol`, `test/Counter.t.sol`, `script/Counter.s.sol`, the five `docs/` files, `.gitignore`.

**`.gitignore`:** `cache/` and `out/` (build artefacts). Moved forward from M1 so the baseline can be staged safely.

**Order after "开始":** (1) create `.gitignore`; (2) show `git status` and stage the listed files explicitly; (3) commit on `main`; (4) create and switch to `m1-setup`; (5) begin M1.

`lib/forge-std` is a plain directory, so it is committed as ordinary files; OpenZeppelin will be installed the same way in M1 for consistency (reported before doing so).

## 6. Deadline risk and scope rules

- Biggest risks: M8 (Tier 1, L-α) and the report. M8 is time-boxed to two days.
- If time runs short: stop at the last verified milestone, document the gap from the approved target, present the remaining work, and let the student decide what to defer.
- Never present an intermediate stage as the delivered target; never drop an approved objective without the student's consent.

## 7. M1 start conditions

| Condition | Status |
|---|---|
| Three configuration changes approved | Satisfied |
| Baseline commit contents | Approved |
| `m1-setup` branch | Approved (created after the baseline commit) |
| Student review of the revised documents | Awaiting |
| Student says "开始" | Awaiting |
| U12 exact values | Reported and approved during M1 (not a start blocker) |
