# MILESTONES — Plan and Progress

**Last updated:** 2026-11-19
**Deadline:** 2026-11-27, 12:00 UK time

Workflow rules: root `CLAUDE.md`. Status labels: [DECISIONS.md](DECISIONS.md) §0.

## 1. Current status

| Item | Status |
|---|---|
| Architecture documents (`docs/`, five files) | Maintained per milestone; M5 decisions recorded (DECISIONS §12) |
| Git | M1, M2, M3 accepted (tags `m1-setup-accepted`, `m2-pool-skeleton-accepted`, `m3-lp-initial-deposit-accepted`, merged to `main`); M4 accepted (tag `m4-deposit-withdraw-accepted`, merged to `main`); M4 hardening accepted (tag `m4-hardening-accepted` on `d355fec`, merged to `main`); M5 in progress on `m5-swap` |
| AMM contracts | `AMMPool`: constructor checks, LP ERC-20 with `_update` supply controls, `addLiquidity` (initial with 1,000 lock; Tier 0 later deposit; non-zero hints on later deposits temporarily rejected until M8), `removeLiquidity` with MIN-NET and A8, `getReserves`; `AMMMath`: quote (returns 0 for zero output), initial shares |
| Tests | 141 passing: Counter 2, MockERC20 7, OutboundMocks 6, AMMMath 27, AMMPool 15, AMMPoolLiquidity 36, AMMPoolDeposit 26, AMMPoolDepositDifferential 2, AMMPoolWithdraw 20 |
| Dependencies | forge 1.9.0, forge-std 1.17.0, OpenZeppelin Contracts v5.7.0 (all plain directories, not submodules); compiler pinned per U12 |
| Gas measurements | M4 hardening only (TEST_MATRIX §14.1: `removeLiquidity` order, L-α overflow-fix variants); full snapshot G02 in M10 |

Accepted so far: M1, M2, M3, M4, M4 hardening. Only the student accepts milestones.

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
| M6 | Downward-only `sync()`, per-token `skim()`, deficit entry checks | Event fields; **zero-reserve recovery rule** (DECISIONS M4-6) | Surplus isolation, deficit rules, A2, order independence, zero-reserve recovery | R02–R08, R10–R17, S07, L13, B01, B04, B05 | 11/21 |
| M7 | `AMMFactory` | Shared recipient; code-existence check; Pool stores `factory` | Uniqueness, reverse lookup, isolation, full regression, size | F01–F07 | 11/21 |
| M8 | Tier 1: U8 taxed mock, exclusive-FOT mock, L-α, taxed outputs | L-α step-3 gross rule comparison (ceiling vs. minimal necessary gross; one-unit over-delivery; cap handling) | Caps, `[T, T+1]`, wrong hints revert, net minima, A8 detection | L05, L09–L10c, L15, L16, S05, S06, W05, R09, X04, Z04, Z05 | 11/22–23 |
| M9 | Protocol fee | — | **Not in scope** (`FUTURE-ONLY`); needs fresh approval | C01–C07 | — |
| M10 | Fuzz, stateful invariants, static review, gas snapshot | — | Actual results; open limitations; reproducible gas data | I1–I9, Z02, Z03, Z06, G02 | 11/24 |
| M11 | Report, code/report cross-references, talk preparation | — | Every main function, trade-off, limit and real result explained | — | 11/25–26 |
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
| M6 | `feat`: `sync` + tests; `feat`: `skim` + tests |
| M7 | `feat`: Factory + tests; `test`: regression fixtures |
| M8 | `test`: taxed and exclusive-FOT mocks; `feat`: L-α + tests; `feat`: taxed-output handling + tests |
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
