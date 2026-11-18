# DECISIONS — Architecture Decision Register

**Last updated:** 2026-11-17

**Sources:** Architecture Specification v0.3 (2026-11-15, full text supplied by the student in the design conversation) and every decision the student subsequently approved explicitly. This file is the authoritative record of decision status; where another document disagrees, this file wins and the other document must be corrected.

All protocol design decisions are made by the student. AI assistants provide analysis and recommendations only.

## 0. Status definitions

These labels are used consistently across all five documents in `docs/`.

| Status | Definition |
|---|---|
| `APPROVED` | Explicitly approved by the student. Implementation must comply. |
| `PROPOSED` | A concrete draft awaiting student confirmation. **Must not be implemented as if approved.** |
| `PENDING` | Not yet decided. Approval is required before implementing anything that depends on it. |
| `FUTURE-ONLY` | Optional future extension; excluded from the current implementation. |
| `OUT-OF-SCOPE` | Explicitly excluded. |

Implementers (including later Claude sessions) must stop and ask the student when they reach a `PROPOSED` or `PENDING` item. They must not choose on the student's behalf.

---

## 1. Decisions D1–D14

| ID | Topic | Choice | Decision | Status |
|---|---|---|---|---|
| D1 | Pool architecture | B | Build one two-token constant-product Pool first, then a Factory creating multiple independent two-token Pools. A single three-token Pool (D1-C) is a different mathematical design, not the next stage. | `APPROVED`; D1-C `OUT-OF-SCOPE` |
| D2 | Supported tokens | B | Standard ERC-20 first, then the inclusive fee-on-transfer model defined in U8. Rebasing, exclusive FOT and arbitrary malicious tokens are not supported. | `APPROVED`; scope fixed by U8 |
| D3 | Reserve accounting | B, narrowed by Gate R=(b) | Recorded reserves; public `sync()`; public `skim()` sending surplus only to a fixed immutable `surplusRecipient`. | `APPROVED`; see §3 |
| D4 | LP ownership | B | Transferable ERC-20 LP tokens. | `APPROVED` |
| D5 | Initial mint | B | `floor(sqrt(net0 × net1))` minus a permanently locked minimum liquidity. | `APPROVED`; lock per U2 |
| D6 | Later liquidity | B | Optimal-ratio deposit bounded by GROSS maxima; Adaptive Net Deposit for supported taxed tokens. | `APPROVED`; algorithm per U9 |
| D7 | Withdrawal | A | Proportional redemption of both tokens with net minimum-received constraints. | `APPROVED` |
| D8 | Swap fee | B (current) | Fixed swap fee, 100% retained by LPs. No protocol fee. | `APPROVED`; value per U1 |
| D9 | User protection | A | Slippage minima and deadlines. | `APPROVED` |
| D10 | Administration | A (current) | Pool and Factory are ownerless: no fee setter, no emergency sweep, no configurable admin. | `APPROVED` |
| D11 | Reentrancy | A | OpenZeppelin reentrancy guard plus call-order analysis. Implementation: `ReentrancyGuardTransient` (M3-5, revised from `ReentrancyGuard`). | `APPROVED` |
| D12 | Arithmetic | A | Solidity checked arithmetic; full-precision `mulDiv` where justified and tested. | `APPROVED`; scope per U6 |
| D13 | Tooling | A | Foundry / Forge. | `APPROVED` |
| D14 | Extension priority | — | No additional extension is currently selected. | `PENDING` |

## 2. The four conflict resolutions

| Conflict | Choice | Resolution | Status |
|---|---|---|---|
| 1 | B | Adaptive Net Deposit (not strict-revert-only, not partial support). | `APPROVED` |
| 2 | B | Public `sync()` and publicly callable fixed-destination `skim()`. | `APPROVED`, narrowed by Gate R=(b), §3 |
| 3 | A | **If** a protocol fee is approved in future, use deferred LP-share minting. | `FUTURE-ONLY` |
| 4 | A | Ownerless now. **If** a protocol fee is added later, `feeTo` is immutable, fixed at deployment, and a different role from `surplusRecipient`. | Ownerless `APPROVED`; `feeTo` `FUTURE-ONLY` |

## 3. Gate R = (b) — approved 2026-11-17

### Rules

- Surplus (`balance > reserve`) has exactly one destination: anyone may call `skim()`, which sends it to `surplusRecipient`.
- `sync()` stays public but **may only lower** recorded reserves (deficit reconciliation). It never absorbs surplus into reserves.
- Student intent: surplus goes to an official address, which may return it to mistaken senders off-chain or keep it as protocol income. Separate on-chain surplus accounting may be considered later (`FUTURE-ONLY`).

### Revision of v0.3

In v0.3, `sync()` could set reserves to actual balances, absorbing surplus. Under (b) it cannot, so the v0.3 first-mover race between `sync()` and `skim()` no longer exists.

### Trade-offs to disclose in the report

- The contract cannot identify who sent an unsolicited transfer and cannot force a refund. Refunds depend entirely on off-chain trust in whoever controls `surplusRecipient`.
- `surplusRecipient` has no privileged functions but is an economic beneficiary. Ownerless does not mean "no beneficiary".
- Surplus stays in the Pool until someone pays gas to call `skim()`.
- LPs never benefit from unsolicited transfers.

### Rejected alternatives

- (a) Both public with surplus-absorbing `sync()`, accepting the race.
- (c) `sync()` performs a skim internally before reconciling. Equivalent to calling `skim()` then `sync()`, but a failing transfer of one token would block deficit reconciliation of the other.

## 4. Implementation decisions U1–U13

| ID | Topic | Decision | Status |
|---|---|---|---|
| U1 | Swap fee | 30 bps, denominator 10,000, output rounded down, 100% to LPs. | `APPROVED` |
| U2 | Minimum liquidity lock | Amount: 1,000 smallest LP units. Destination: **the Pool's own address** (`_mint(address(this), 1000)`), with the code-path restrictions in ARCHITECTURE §7.9. | `APPROVED` (amount 2026-11-17; destination A5, 2026-11-17) |
| U3 | `surplusRecipient` | Immutable constructor argument. Constructor rejects four values: `address(0)`, `token0`, `token1`, `address(this)`. These checks catch only these four obvious mistakes; they cannot detect a wrong-but-valid address, a lost key, or an address the token refuses to pay. Tests use mock addresses; the real address is chosen at deployment. | `APPROVED` (A3) |
| U4 | Deficit handling | If either token has `balance < reserve`, `addLiquidity`, `removeLiquidity` and `swapExactInput` revert. `sync()` lowers the affected reserve to the balance. `skim()` treats each token independently (A2): it sends any token's surplus and skips tokens without surplus, whether or not the other token is in deficit. | `APPROVED` (revised by A2) |
| U5 | No-op behaviour | `skim()` with no surplus and `sync()` with no deficit return normally without changing state. | `APPROVED` |
| U6 | Arithmetic and ranges | Keep `uint256` reserves; do not introduce `uint112` now (kept as a possible later gas optimisation). Use `Math.mulDiv` for multiply-then-divide calculations that need full precision. Every formula states its input range in ARCHITECTURE §6.6 and in tests. No document may claim overflow is "impossible" without a proof. | `APPROVED` (A4) |
| U7 | Recipient restrictions | User-supplied `recipient` must not be `address(0)` or the Pool. This applies only to user-supplied parameters; the internal lock mint to `address(this)` is exempt. | `APPROVED` |
| U8 | Supported FOT model (Gate T) | Tier 1 tokens must satisfy all of: (1) inclusive — the sender is debited exactly the transfer amount `g`; (2) fee `= floor(g × taxBps / 10000)`; (3) `taxBps` fixed, identical for all addresses, `< 10000`; (4) `balanceOf` reports balances truthfully. Everything else is unsupported. | `APPROVED` (A6) |
| U9 | Adaptive algorithm (Gate L) | L-α with the seven conditions, the step sequence and the `[T, T+1]` tolerance in ARCHITECTURE §6.2. Initial deposit ignores tax hints (option i). The gross-selection rule in step 3 (ceiling vs. minimal necessary gross) is re-opened for a dedicated comparison at the start of M8. | `APPROVED` (A7); step-3 gross rule `PENDING` (M8) |
| U10 | Tax-hint parameters | Two extra parameters in the single `addLiquidity`; standard tokens pass 0. | `APPROVED` |
| U11 | Factory design | Keep `allPairs`; deploy with ordinary `new` (CREATE). | `APPROVED` |
| U12 | Compiler configuration | `solc` 0.8.38 (`auto_detect_solc = false`); optimizer on, 200 runs; `evm_version = osaka`; `via_ir = false`; OpenZeppelin Contracts v5.7.0 (commit `cab19933`) vendored as plain files; explicit remappings with auto-detection off. Effective values verified with `forge config`. | `APPROVED` (2026-11-17) |
| U13 | Additional extensions | None now; D14 stays `PENDING`. | `PENDING` (D14) |

### Why U10 affects the function signature

A Pool cannot query a token's transfer-tax rate on-chain, so the caller must supply it as a parameter. Parameters are part of the function signature, which determines the function selector. Adding the parameters in M8 after writing `addLiquidity` in M4 would change the public interface and every test calling it. Hence the interface is fixed before M4.

## 5. Decisions A1–A9 (2026-11-17)

| ID | Topic | Decision | Status |
|---|---|---|---|
| A1 | Per-function accounting (ADR-019) | ARCHITECTURE §5.2 table approved. Supplemented with per-function security rules (§7), balance invariants BI-1 to BI-9 (§5.5) and matching tests (TEST_MATRIX §§3–7, B-series). | `APPROVED` |
| A2 | `skim()` during deficit | Per-token independence; see U4. | `APPROVED` |
| A3 | `surplusRecipient` checks | Four checks; documented limits; see U3. | `APPROVED` |
| A4 | Ranges and `mulDiv` | See U6. | `APPROVED` |
| A5 | Lock destination | Pool itself; see U2. | `APPROVED` |
| A6 | FOT scope | See U8. | `APPROVED` |
| A7 | L-α details | See U9. | `APPROVED` |
| A8 | Outbound exactness check | After every Pool outbound transfer of `x` (in `removeLiquidity`, `swapExactInput`, `skim`), require the Pool's own balance to have decreased by exactly `x`; otherwise revert. | `APPROVED` |
| MIN-NET | Meaning of user minima | `minNetAmountOut`, `min0Net` and `min1Net` are compared with the **recipient's actual balance increase**. Example: if the user sets `minNetAmountOut = 100`, the recipient must actually receive at least 100; receiving 99 reverts the whole transaction; receiving exactly 100 succeeds. | `APPROVED` |
| LP-SELF | LP tokens sent to the Pool address | Option (ii): the LP token rejects any transfer whose destination is the Pool itself; the only LP ever credited to `address(this)` is the initial 1,000 lock mint. Exact override mechanism is fixed in M3. | `APPROVED` (2026-11-17) |
| A9 | On-chain swap invariant assertion | Process approved: (1) fix the exact swap formula (ARCHITECTURE §6.4); (2) write the invariant (§6.5); (3) verify with unit and fuzz tests; (4) analyse whether an on-chain assertion adds protection; (5) measure its gas cost; (6) student makes the final choice. | Process `APPROVED`; final choice `PENDING` (during M5) |

## 6. Workflow decisions (2026-11-17)

| Topic | Decision | Status |
|---|---|---|
| Commits | Follow `CLAUDE.md`: one focused Conventional Commit per verified feature. | `APPROVED` |
| Baseline commit contents | `CLAUDE.md`, `README.md`, `foundry.toml`, `lib/forge-std/`, the three Counter template files, the five `docs/` files, and `.gitignore` (moved forward from M1 to exclude `cache/` and `out/`). | `APPROVED` |
| Baseline commit timing | Only after the student says "开始" (start). | `APPROVED` |
| Feature branch for M1 | `m1-setup`, created after the baseline commit. Every later create/switch/merge still needs approval. | `APPROVED` |
| Conceptual questions | 2–3 per milestone end. | `APPROVED` |
| Decision explanations | Before each milestone, explain the relevant decisions in simple Chinese. | `APPROVED` |
| M1 configuration changes | Install OpenZeppelin Contracts v5.x with remapping; pin `solc`/optimizer/`evm_version`; `.gitignore`. | `APPROVED`; values per U12 |
| Counter template | Keep for now. | `APPROVED` |
| Commit authorship | Commits list only the student as author; no `Co-Authored-By` lines. Applies from M1 onward (baseline `97f64d8` predates the rule and is not rewritten). | `APPROVED` |
| Configuration verification | Besides `forge build` and `forge test`, run `forge config` to verify the effective configuration after any config change and at each milestone. | `APPROVED` |
| Gas reporting | Every gas measurement in the report and docs is recorded together with the compiler configuration it used (TEST_MATRIX §14). | `APPROVED` |

## 7. ADR log

Before a substantive change to any ADR, present: problem, evidence, proposed change, alternatives, benefits, risks, affected state/functions, tests.

| ADR | Selected | Alternatives | Trade-off | Status |
|---|---|---|---|---|
| 001 Pool | Single CPMM first, then multi-pool Factory | Factory first; three-token Pool | Clear incremental path; Factory needs constructor/fixture changes and full regression | `APPROVED` |
| 002 Token tiers | Tier 0 + U8 Tier 1 | Standard only; rebasing; exclusive FOT | Compatibility vs. accounting complexity | `APPROVED` |
| 003 Reserve model | Recorded reserves; `skim()` to fixed recipient; downward-only `sync()` | v0.3 absorbing `sync()`; arbitrary recipient; admin recovery | Removes the race and the transfer-plus-sync price route; refunds rely on off-chain trust | `APPROVED` |
| 004 LP token | Transferable ERC-20 (Pool inherits OZ `ERC20`) | Internal mapping | Composability vs. transfer/allowance surface | `APPROVED` |
| 005 Initial LP | Floor sqrt, 1,000 locked in the Pool's own balance | No lock; `0x…dEaD` | Raises the cost of first-depositor manipulation; lock argument relies on code review plus invariant tests | `APPROVED` |
| 006 Later LP | Optimal ratio + adaptive net path | Strict rejection; partial FOT | Better UX vs. complexity | `APPROVED` |
| 007 Withdrawal | Proportional two-token | Single-sided | Simple semantics | `APPROVED` |
| 008 Fee | Fixed 30 bps, all to LPs | Zero; protocol split; dynamic | Small surface, clear LP economics | `APPROVED` |
| 009 Bounds | Net minima + deadline | No deadline | User intent vs. more parameters | `APPROVED` |
| 010 Admin | Ownerless | Pause-only; configurable | Minimal privilege; fixes need redeployment | `APPROVED` |
| 011 Reentrancy | OZ `ReentrancyGuardTransient` + order review (revised 2026-11-18, M3-5) | OZ `ReentrancyGuard` (storage; deprecated in OZ v5.7.0); custom mutex | Proven component, cheaper than storage guard; needs EIP-1153 | `APPROVED` |
| 012 Arithmetic | Checked + `mulDiv`, `uint256` reserves, documented ranges | `uint112` packing | Simplicity now; packing kept as a measured optimisation candidate | `APPROVED` |
| 013 Toolchain | Foundry | Hardhat / Remix | Native fuzz/invariant/gas | `APPROVED` |
| 014 Extensions | None selected | Router, Oracle, three-token | Avoid scope creep | `PENDING` (D14) |
| 015 Adaptive FOT | L-α: declared tax, single transfer per token, no refund | L-β top-up; L-γ refund; strict rejection | No double tax; relies on caller hint | `APPROVED` |
| 016 Surplus | Only via `skim()` to immutable recipient | See 003 | See 003 | `APPROVED` |
| 017 Future protocol fee | Deferred LP mint | Separate accounting; immediate transfer | No per-swap transfer; dilution/accounting risk | `FUTURE-ONLY` |
| 018 Fee-recipient privileges | Ownerless; future immutable `feeTo` | Limited owner; governance | No setter; immutability cost | Current `APPROVED`; `feeTo` `FUTURE-ONLY` |
| 019 Per-function accounting | In-call balance snapshots; ARCHITECTURE §5.2 | Uniswap V2 `reserve := balance` | Isolates historical surplus; extra balance reads cost gas | `APPROVED` (A1) |
| 020 Outbound exactness | Pool balance must fall by exactly the amount sent | No check | Rejects tokens that over-debit the Pool; one extra `balanceOf` per outbound transfer | `APPROVED` (A8) |
| 021 Zero-output quote | `AMMMath.getAmountOut` returns 0; `swapExactInput` reverts on `out == 0` | Library reverts (original M2-5) | Quotes are informative (callers see 0 instead of an error); swap safety unchanged but now depends on the Pool-level check, which M5 must test | `APPROVED` (M2-5r) |
| 022 LP supply control | `_update` enforces: Pool-held LP immovable; only the first 1,000 lock mint credits the Pool; mint/burn only inside `nonReentrant` | Review rules only; override `transfer`/`transferFrom` only | Lock and LP-SELF become code-enforced, not review-only; small gas cost on every LP movement | `APPROVED` (M3-2) |

## 8. Outstanding items

In dependency order.

| Item | Needed by | Status |
|---|---|---|
| Function signatures, event names/fields, custom-error names | Start of each milestone (M2 items approved, §9) | `PROPOSED` for M3 onward |
| LP token `name` / `symbol` | M3 | Resolved (M3-1) |
| `nonReentrantView` on view functions (T13) | M5 | `PENDING` |
| L-α gross selection: compare the current ceiling-gross formula with the minimal-necessary-gross alternative; decide whether a one-unit over-delivery is allowed and how the user cap applies (ARCHITECTURE §6.2) | Start of M8 | `PENDING` |
| A9 final choice: on-chain swap assertion or tests only | During M5 | `PENDING` |
| Factory: one shared `surplusRecipient` for all Pools; token code-existence check; whether Pool stores `factory` | M7 | `PENDING` |
| D14 | — | `PENDING` |
| Protocol fee, `feeTo`, owner/pause, separate surplus accounting, `uint112` packing | — | `FUTURE-ONLY` |

## 9. M2 decisions (approved 2026-11-17)

| ID | Topic | Decision | Status |
|---|---|---|---|
| M2-1 | Names | Pool: `AMMPool` in `src/AMMPool.sol`. Maths: separate library `AMMMath` in `src/libraries/AMMMath.sol` with `internal pure` functions (inlined; no linking). | `APPROVED` |
| M2-2 | Token ordering | Caller supplies pre-sorted tokens; the Pool checks and never sorts. Future Factory sorts before deploying (not implemented now). Pool does not read or store `msg.sender`/`factory`; no code-existence check (both stay `PENDING` for M7). | `APPROVED` |
| M2-3 | Token checks and errors | In order: `token0_ == 0 \|\| token1_ == 0` → `ZeroAddress()` (whichever is zero, including both, and regardless of order); `token0_ == token1_` → `IdenticalTokens()`; `token0_ > token1_` → `TokensNotSorted()`. | `APPROVED` |
| M2-4 | Reserves in M2 | `reserve0`, `reserve1` are `private uint256`, start at 0, and **no M2 function writes them**. Only `getReserves()` reads them. Later writers are exactly those in ARCHITECTURE §5.2. | `APPROVED` |
| M2-5 | Fee and maths conventions | `FEE_BPS = 30`, `BPS_DENOMINATOR = 10_000` are `constant`s in `AMMMath`; `AMMPool` re-exposes them as public constants. Swap output and sqrt round down. `AMMMath.getAmountOut` reverts: `amountIn == 0` → `InsufficientInputAmount()`; either reserve 0 → `InsufficientLiquidity()`; floored output 0 → `InsufficientOutputAmount()`. Overflow in checked arithmetic reverts with Panic `0x11`, never a wrong value. `AMMMath.initialShares(net0, net1) = floor(sqrt(net0 × net1))` (before the M3 lock); zero inputs return 0 (validation belongs to M3). | `APPROVED`; zero-output rule revised by M2-5r (§10.1) |
| M2-6 | Interface (option 4A) | `constructor(address token0_, address token1_, address surplusRecipient_)`; `token0`, `token1`, `surplusRecipient` are `public immutable`; `getReserves() external view returns (uint256, uint256)`. One error `InvalidSurplusRecipient()` for all four A3 checks. | `APPROVED`; output names revised by M2-6r (§10.1) |
| M2-7 | Commits | `feat`: AMMMath + tests; `feat`: AMMPool skeleton + tests; `docs`: sync. | `APPROVED` |
| M2-8 | Scope guard | M2 contains only the Pool skeleton and pure maths. Not in M2: Factory, swap, quote on the Pool, LP ERC-20, mint/burn, lock address, `MINIMUM_LIQUIDITY`, LP `name`/`symbol`, `ReentrancyGuard`, any reserve write. | `APPROVED` |
| M2-9 | Maths test design | See TEST_MATRIX §11.1: inputs are classified by an independent, overflow-free classifier (not by "all three inputs > 0"); fuzz tests are split into success, zero-output revert and overflow revert; every product in test assertions is computed exactly in 512 bits so test helpers cannot overflow. | `APPROVED`; class B revised by M2-9r (§10.1) |

## 10. M3 decisions and M2 revisions (approved 2026-11-18)

### 10.1 Revisions of M2 decisions

| ID | Revises | Decision | Status |
|---|---|---|---|
| M2-5r | M2-5 | `AMMMath.getAmountOut` **returns 0** when the floored output is 0 instead of reverting. Zero input (`InsufficientInputAmount`) and zero reserves (`InsufficientLiquidity`) still revert; overflow still panics. `InsufficientOutputAmount()` moves from `AMMMath` to `AMMPool.swapExactInput`, which must revert when `out == 0` (M5; TEST_MATRIX S03, Q04). ADR-021. | `APPROVED` |
| M2-6r | M2-6 | `getReserves() external view returns (uint256 reserve0_, uint256 reserve1_)`: named outputs appear in the ABI; trailing underscore avoids shadowing the state variables. | `APPROVED` |
| M2-9r | M2-9 | Fuzz class B ("zero output") now expects a return value of 0, not a revert. Classes A and C unchanged. | `APPROVED` |

### 10.2 M3 decisions

| ID | Topic | Decision | Status |
|---|---|---|---|
| M3-1 | LP metadata | Constants: `ERC20("AMM Liquidity Provider", "AMM-LP")`, OZ default `decimals() = 18`. Constructor signature unchanged. Resolves the `PENDING` LP `name`/`symbol` item. | `APPROVED` |
| M3-2 | LP supply control (LP-SELF mechanism, ADR-022) | Single override of OZ `_update(from, to, value)`, checked in this order: (1) `from == address(this)` → `LockedLiquidity()`: Pool-held LP can never be transferred or burned; (2) `to == address(this)` is allowed **only** for the first lock mint (`from == 0`, `totalSupply() == 0`, `value == MINIMUM_LIQUIDITY`), otherwise `LPTransferToPool()` — this includes zero-value transfers and any later mint to the Pool; (3) a mint or burn (`from == 0` or `to == 0`) outside a `nonReentrant` entry point → `SupplyChangeOutsideGuard()`. Review rule per milestone: list and grep every `_mint`/`_burn` call site in `src/`. | `APPROVED` |
| M3-3 | `addLiquidity` when `S > 0` | Temporary `LaterDepositNotImplemented()` revert; removed and replaced by the L-α path in M4. | `APPROVED` (temporary) |
| M3-4 | `addLiquidity` interface | `addLiquidity(uint256 amount0Max, uint256 amount1Max, uint256 tax0Bps, uint256 tax1Bps, uint256 minShares, address recipient, uint256 deadline) external nonReentrant returns (uint256 net0, uint256 net1, uint256 shares)`. Checks in order: `block.timestamp > deadline` → `DeadlineExpired()`; recipient `0`/Pool → `InvalidRecipient()`; either max 0 → `ZeroAmount()`; either tax `≥ 10000` → `InvalidTaxBps()`; `S > 0` → M3-3. Initial path: per token (token0 then token1) Pool balance before → `safeTransferFrom(msg.sender, this, amount_iMax)` → after; `gross = initialShares(net0, net1)`; `gross ≤ 1000` → `InsufficientInitialLiquidity()`; `shares = gross − 1000 < minShares` → `InsufficientShares()`; reserves := nets; mint 1000 to the Pool, then `shares` to `recipient`; emit `LiquidityAdded(address indexed sender, address indexed recipient, uint256 net0, uint256 net1, uint256 shares)`. `MINIMUM_LIQUIDITY = 1000` is a public constant. | `APPROVED` |
| M3-5 | Reentrancy guard (ADR-011 revised) | `ReentrancyGuardTransient` (EIP-1153) instead of `ReentrancyGuard`, which OZ v5.7.0 marks deprecated. Requires an EVM with transient storage (`osaka` per U12). Gas difference to be measured in M10 with the configuration recorded. `nonReentrantView` on view functions (THREAT_MODEL T13): `PENDING`, decided in M5. | `APPROVED`; view guard `PENDING` (M5) |
| M3-6 | Test-only mocks moved forward | U8-compliant inclusive taxed mock (fee burned, truthful `balanceOf`); configurable failing token (revert / return `false` / `balanceOf` revert); reentrant token (M3 smoke test only; full attacks in M5). | `APPROVED` |
| M3-7 | Extra M3 tests | Student checklist: `gross` 999/1000/1001; `minShares` equal and +1; taxed initial deposit; pre-existing surplus in both tokens; zero-value LP transfer to the Pool (forbidden); LP supply/lock accounting after operation sequences; failed `approve`/`transferFrom` leave no residue; reentrancy smoke; balance-read or transfer failure rolls back the whole call. TEST_MATRIX §3.1, §8. | `APPROVED` |
