# TEST MATRIX — Foundry Test Plan

**Last updated:** 2026-11-17

**Status:** T01–T05 (M1) and the M2 rows marked `PASSED` are implemented. Everything else is a plan, not a record of passing tests. "Maths level" means the library function was tested; the Pool function that uses it does not exist yet. Record a result and the test function name only after the test has actually been run.

Tests that depend on a `PROPOSED` or `PENDING` decision must not be written before that decision is approved. Formulas, invariants (BI-x) and function rules are in [ARCHITECTURE.md](ARCHITECTURE.md).

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
| K03 | Immutables set correctly; reserves are 0; fee constants 30 / 10,000. (`totalSupply == 0` is checked in M3, when the LP ERC-20 exists.) | `PASSED` — `test_K03_initialState` (`totalSupply` part in M3) |
| K04 | `surplusRecipient` equal to `token0`, `token1`, or the Pool's own (predicted) address each revert | `PASSED` — `test_K04_*` (3 reverts + address-prediction control), `testFuzz_K01_K04_constructorMatchesClassifier` |

## 3. Liquidity provision (M3, M4, M8)

| ID | Description | Milestone | Status |
|---|---|---|---|
| L01 | Initial: provider gets `floor(sqrt(net0 × net1)) − 1000`; Pool holds exactly 1000 LP | M3 | `NOT IMPLEMENTED` |
| L02 | Initial reverts for zero amounts and for `sqrt(net0 × net1) ≤ 1000` | M3 | `NOT IMPLEMENTED` |
| L03 | Later deposit into a 1:2 Pool pulls only the optimal amounts | M4 | `NOT IMPLEMENTED` |
| L04 | Several LPs get shares proportional to contributions | M4 | `NOT IMPLEMENTED` |
| L05 | U8 taxed token: measured `net_i ∈ [T_i, T_i+1]`; shares from net; worked example of ARCHITECTURE §6.2 (gross 203, net 201) | M8 | `NOT IMPLEMENTED` |
| L06 | Failed transfer / insufficient balance / insufficient allowance reverts with no state left | M4 | `NOT IMPLEMENTED` |
| L07 | First depositor sets the initial price | M3 | `NOT IMPLEMENTED` |
| L08 | `minShares` unmet reverts; expired deadline reverts; `block.timestamp == deadline` succeeds | M4 | `NOT IMPLEMENTED` |
| L09 | Required gross above cap reverts | M8 | `NOT IMPLEMENTED` |
| L10a | Tax hint higher than actual reverts | M8 | `NOT IMPLEMENTED` |
| L10b | Tax hint lower than actual reverts | M8 | `NOT IMPLEMENTED` |
| L10c | Tax rate changed between quote and execution reverts | M8 | `NOT IMPLEMENTED` |
| L11 | Caller's measured debit per token ≤ its cap (unit + fuzz) | M4, M8 | `NOT IMPLEMENTED` |
| L12 | Caller's token balances never increase during `addLiquidity` (no refund path) | M4, M8 | `NOT IMPLEMENTED` |
| L13 | Inflation scenario: after a large direct transfer by an attacker, a later LP's shares are not rounded to zero and the transfer does not enter reserves | M6 | `NOT IMPLEMENTED` |
| L14 | `recipient ∈ {address(0), Pool}` reverts | M4 | `NOT IMPLEMENTED` |
| L15 | Initial deposit with a taxed token ignores the hints and uses measured net | M8 | `NOT IMPLEMENTED` |
| L16 | `tax_iBps ≥ 10000` reverts | M8 | `NOT IMPLEMENTED` |

## 4. Withdrawal (M4, M5, M8)

| ID | Description | Milestone | Status |
|---|---|---|---|
| W01 | Proportional redemption matches ARCHITECTURE §6.3 | M4 | `NOT IMPLEMENTED` |
| W02 | Only the caller's own shares are burned; a transferee can redeem transferred LP | M4 | `NOT IMPLEMENTED` |
| W03 | Zero shares, shares above balance, or a zero output reverts | M4 | `NOT IMPLEMENTED` |
| W04 | MIN-NET: recipient receiving exactly `min_iNet` succeeds; one unit less reverts | M4 | `NOT IMPLEMENTED` |
| W05 | Taxed output: minima judged on recipient's actual receipt | M8 | `NOT IMPLEMENTED` |
| W06 | After the last redeemable LP exits, the Pool still holds exactly 1000 LP and reserves > 0 | M4 | `NOT IMPLEMENTED` |
| W07 | Reentrancy during withdrawal is blocked | M5 | `NOT IMPLEMENTED` |
| W08 | `recipient ∈ {address(0), Pool}` reverts | M4 | `NOT IMPLEMENTED` |

## 5. Swap (M5, M6, M8)

| ID | Description | Milestone | Status |
|---|---|---|---|
| S01 | Swaps work in both directions | M5 | `NOT IMPLEMENTED` |
| S02 | Reference case 1: `1,000,000 / 1,000,000`, `a = 10,000` → `out = 9,871` | M5 | `PASSED` at maths level (`AMMMath`, M2) — `test_S02_referenceCase1`; Pool swap: `NOT IMPLEMENTED` (M5) |
| S03 | `amountIn = 0`, `out = 0` (reference case 3) and zero reserves revert | M5 | `PASSED` at maths level (`AMMMath`, M2) — zero input, zero reserves, reference case 3 (`test_S03_*`); Pool swap: `NOT IMPLEMENTED` (M5) |
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
| R01 | `getReserves()` returns recorded reserves; unchanged by a direct transfer | M2 | `PASSED` (M2, no reserve writer exists yet) — `test_R01_directTransferDoesNotChangeReserves`; re-run when writers exist |
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

R08 and R13 need a test-only mock token whose Pool balance can be reduced.

## 7. Balance invariants per call (M4–M8)

Each test records `balance_i` and `reserve_i` for both tokens before and after one call.

| ID | Invariant | Description | Milestone | Status |
|---|---|---|---|---|
| B01 | BI-2 | `addLiquidity` with pre-existing surplus leaves both surpluses unchanged | M4 (surplus setup in M6) | `NOT IMPLEMENTED` |
| B02 | BI-2 | `removeLiquidity` leaves both surpluses unchanged | M4 | `NOT IMPLEMENTED` |
| B03 | BI-2 | `swapExactInput` leaves both surpluses unchanged | M5 | `NOT IMPLEMENTED` |
| B04 | BI-3 | After `skim()`, every token that had surplus has `balance == reserve`; reserves unchanged | M6 | `NOT IMPLEMENTED` |
| B05 | BI-4 | After `sync()`, `reserve_i = min(old reserve_i, balance_i)`; no reserve increased; balances unchanged | M6 | `NOT IMPLEMENTED` |
| B06 | BI-5 | Pool balance falls by exactly the amount sent in remove, swap and skim | M4–M6 | `NOT IMPLEMENTED` |
| B07 | BI-6 | Recipient's actual increase ≥ user minimum in remove and swap; boundary at exactly the minimum | M4, M5 | `NOT IMPLEMENTED` |

## 8. LP ERC-20 and lock (M3)

| ID | Description | Dependency | Status |
|---|---|---|---|
| P01 | LP `transfer` moves ownership; `totalSupply` unchanged | — | `NOT IMPLEMENTED` |
| P02 | `approve` / `transferFrom` / allowance follow the standard | — | `NOT IMPLEMENTED` |
| P03 | `totalSupply` = minted − burned, including the locked 1000 | — | `NOT IMPLEMENTED` |
| P04 | No external account can mint or burn LP directly | — | `NOT IMPLEMENTED` |
| P05 | Pool's own LP balance is exactly 1000 after the first deposit and no sequence of calls changes it | — | `NOT IMPLEMENTED` |
| P06 | LP-SELF: `transfer(pool, x)` and `transferFrom(…, pool, x)` revert; the initial lock mint still succeeds | — | `NOT IMPLEMENTED` |

## 9. Quote (M5)

| ID | Description | Status |
|---|---|---|
| Q01 | `getAmountOut` equals the actual swap output on the same state (Tier 0) | `NOT IMPLEMENTED` |
| Q02 | Invalid `tokenIn`, zero input, zero reserves behave as in swap | `NOT IMPLEMENTED` |
| Q03 | Quote uses recorded reserves and ignores surplus | `NOT IMPLEMENTED` |

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
| Z06 | Boundary tests for each formula in ARCHITECTURE §6.6: just inside the sufficient condition succeeds; beyond the overflow threshold reverts; no wrong value returned | M5, M10 | `PASSED` for `getAmountOut` and `initialShares` (`test_Z06_*`); other §6.6 formulas: `NOT IMPLEMENTED` (M4/M8/M10) |

Do not use `assume()` to exclude conditions the implementation is expected to handle.

### 11.1 Maths test design for `AMMMath` (M2, DECISIONS M2-9)

**M2 results (2026-11-17):** `test/AMMMath.t.sol` 26 tests and `test/AMMPool.t.sol` 15 tests passed with the default 256 fuzz runs and again with `FOUNDRY_FUZZ_RUNS=10000`. Mutation check (temporary, reverted): removing the fee, rounding up, and returning `out + 1` each made the reference-case, floor and zero-output tests fail.

**Independent classifier.** A test helper classifies `(a, rIn, rOut)` without calling `mulDiv` and without overflowing, in the same order as the implementation's checks:

1. `a == 0` → `InsufficientInputAmount`.
2. `rIn == 0` or `rOut == 0` → `InsufficientLiquidity`.
3. Overflow → Panic `0x11` if `a > ⌊MAX/9970⌋`, or `rIn > ⌊MAX/10000⌋`, or `rIn·10000 > MAX − a·9970` (each step evaluated only after the previous one is known not to overflow).
4. Zero output → `InsufficientOutputAmount` iff `aFee × rOut < den`, compared as exact 512-bit values.
5. Otherwise success.

So validity is never judged only by "all three inputs > 0".

**512-bit helper.** `Wide512.mul(x, y)` returns the exact product as `(hi, lo)` using 128-bit limbs (schoolbook multiplication, independent of OpenZeppelin); it is cross-checked against `Math.mul512` by fuzzing. `Wide512.lt/lte` compare such values. Any product of two `uint256` values is `< 2^512`, so the helper cannot overflow.

**Three fuzz classes, each with constructed (not `assume`-filtered) inputs:**

| Class | Input construction | Assertions |
|---|---|---|
| A — success | `rIn ∈ [1, 2^112]`, `rOut ∈ [2, 2^112]`, `a ≥ aMin = ⌈rIn·10000 / (9970·(rOut−1))⌉` (the exact condition for `out ≥ 1`) | classifier says success; `out < rOut`; floor: `out·den ≤ aFee·rOut < (out+1)·den`; §6.5: `den·(rOut−out) ≥ (rIn·D)·rOut`; tightness: `den·(rOut−out−1) < (rIn·D)·rOut` (i.e. `out + 1` violates §6.5) |
| B — zero output | `rOut = 1` with any `a`, or `rIn > 0.997·(rOut−1)` and `a ∈ [1, aMin − 1]` | classifier says zero output; call reverts with `InsufficientOutputAmount()`; no quote is required |
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

**Current status: no gas measurement has been made.**
