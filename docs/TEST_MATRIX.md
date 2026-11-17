# TEST MATRIX — Foundry Test Plan

**Last updated:** 2026-11-17

**Status: NO TEST IS IMPLEMENTED YET.** This is a plan, not a record of passing tests. Record a result and the test function name only after the test has actually been run.

Tests that depend on a `PROPOSED` or `PENDING` decision must not be written before that decision is approved. Formulas, invariants (BI-x) and function rules are in [ARCHITECTURE.md](ARCHITECTURE.md).

**Status values:** `NOT IMPLEMENTED` · `PASSED` · `FAILED` · `BLOCKED (reason)`

## 1. Mocks and basics (M1)

| ID | Description | Status |
|---|---|---|
| T01 | `MockERC20.decimals()` returns 18 and 6 for the respective mocks | `NOT IMPLEMENTED` |
| T02 | `mint` updates `balanceOf` and `totalSupply` | `NOT IMPLEMENTED` |
| T03 | `transfer` succeeds; reverts on insufficient balance | `NOT IMPLEMENTED` |
| T04 | `approve` + `transferFrom` succeed and reduce allowance | `NOT IMPLEMENTED` |
| T05 | `transferFrom` reverts on insufficient allowance | `NOT IMPLEMENTED` |

## 2. Constructor (M2)

| ID | Description | Status |
|---|---|---|
| K01 | Zero, identical and unsorted token addresses revert | `NOT IMPLEMENTED` |
| K02 | `surplusRecipient == address(0)` reverts | `NOT IMPLEMENTED` |
| K03 | Immutables set correctly; reserves and `totalSupply` are 0 | `NOT IMPLEMENTED` |
| K04 | `surplusRecipient` equal to `token0`, `token1`, or the Pool's own (predicted) address each revert | `NOT IMPLEMENTED` |

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
| S02 | Reference case 1: `1,000,000 / 1,000,000`, `a = 10,000` → `out = 9,871` | M5 | `NOT IMPLEMENTED` |
| S03 | `amountIn = 0`, `out = 0` (reference case 3) and zero reserves revert | M5 | `NOT IMPLEMENTED` |
| S04 | MIN-NET: `minNetAmountOut = out` succeeds, `out + 1` reverts; expired deadline reverts | M5 | `NOT IMPLEMENTED` |
| S05 | Taxed input: pricing and accounting use measured net | M8 | `NOT IMPLEMENTED` |
| S06 | Taxed output: minimum judged on recipient's actual receipt (e.g. min 100, receives 99 → revert) | M8 | `NOT IMPLEMENTED` |
| S07 | Pre-existing surplus is not counted as input and is unchanged after the swap | M6 | `NOT IMPLEMENTED` |
| S08 | Reentrancy during swap is blocked | M5 | `NOT IMPLEMENTED` |
| S09 | A failed swap leaves no state change | M5 | `NOT IMPLEMENTED` |
| S10 | 0-bps reference (9,900) vs. 30-bps result (9,871); the difference remains in reserves | M5 | `NOT IMPLEMENTED` |
| S11 | Fee-adjusted inequality holds after every successful swap (unit + fuzz in `[1, 2^112]`) | M5 | `NOT IMPLEMENTED` |
| S12 | `recipient ∈ {address(0), Pool}` reverts; `tokenIn` outside the pair reverts | M5 | `NOT IMPLEMENTED` |
| S13 | After several swaps, redeeming all LP returns a larger `amount0 × amount1` than deposited (fees accrue to LPs) | M5 | `NOT IMPLEMENTED` |
| S14 | Reference cases 2, 4 and 5 (499,248; 1,992,013; 498,251,621,566,649,025) | M5 | `NOT IMPLEMENTED` |
| S15 | Implementation output equals the reference formula exactly (fuzz); `out + 1` violates the inequality for reference cases | M5 | `NOT IMPLEMENTED` |

## 6. Reserves, `sync()`, `skim()` (M2, M6, M8)

v0.3's R05, R06 and R10 tested the `sync`/`skim` race. That race no longer exists under Gate R=(b), so they are redefined.

| ID | Description | Milestone | Status |
|---|---|---|---|
| R01 | `getReserves()` returns recorded reserves; unchanged by a direct transfer | M2 | `NOT IMPLEMENTED` |
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
| Z01 | Fuzz swap in `[1, 2^112]`: `out < rOut`; inequality holds; no unexpected revert | M5 | `NOT IMPLEMENTED` |
| Z02 | Fuzz add then full remove: returns no more than contributed | M10 | `NOT IMPLEMENTED` |
| Z03 | Mixed 6/18-decimal scales near the top of the fuzz range | M10 | `NOT IMPLEMENTED` |
| Z04 | Fuzz gross vs. net for the U8 taxed mock | M8 | `NOT IMPLEMENTED` |
| Z05 | Fuzz L-α: for random `T` and `t < 10000`, implementation gross gives `net ∈ [T, T+1]` | M8 | `NOT IMPLEMENTED` |
| Z06 | Boundary tests for each formula in ARCHITECTURE §6.6: just inside the sufficient condition succeeds; beyond the overflow threshold reverts; no wrong value returned | M5, M10 | `NOT IMPLEMENTED` |

Do not use `assume()` to exclude conditions the implementation is expected to handle.

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

| ID | Measurement | Purpose | Milestone | Status |
|---|---|---|---|---|
| G01 | `swapExactInput` gas with and without the on-chain §6.5 assertion | Input to the A9 decision | M5 | `NOT IMPLEMENTED` |
| G02 | Gas snapshot of all public functions | Report and later optimisation baseline | M10 | `NOT IMPLEMENTED` |

**Current status: no gas measurement has been made.**
