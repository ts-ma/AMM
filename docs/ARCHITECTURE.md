# ARCHITECTURE — AMM Specification (Pre-Implementation)

**Last updated:** 2026-11-21

**Status:** Target architecture, partly implemented (M2–M7 accepted). Implementation status per test is recorded only in [TEST_MATRIX.md](TEST_MATRIX.md). This document is not evidence of verification and is not an audit.

Status labels are defined in [DECISIONS.md](DECISIONS.md) §0; DECISIONS.md is authoritative for status. Anything `PROPOSED` or `PENDING` needs student approval before implementation.

## 1. Coursework scope

- University of Edinburgh, *Blockchains and Distributed Ledgers*, individual coursework. Deadline: **2026-11-27, 12:00 UK time**, via Gradescope.
- Checked against the official brief (`Coursework.docx`, read in full on 2026-11-15): no prescribed AMM design. To pass, the contract must compile, run correctly and be free of general and AMM-specific security pitfalls. Marks increase with extra features, gas optimisation and security beyond the pass level; choosing and justifying extensions is part of the task.
- Deliverables: thoroughly commented source code and a report that reference each other (code comments point to report sections; the report points to specific code). In-person 10-minute talk plus 5 minutes of questions on any part of the code or report.

## 2. Contract responsibilities

```text
User / test
  ├── AMMFactory.createPair(tokenA, tokenB) → AMMPool
  ├── AMMPool.addLiquidity / removeLiquidity / swapExactInput / sync / skim
  └── AMMPool is also the LP ERC-20: transfer / approve / transferFrom
```

| Component | Responsibility | Status |
|---|---|---|
| `AMMPool` | Holds two tokens; records reserves; liquidity and swap maths; mints/burns LP; security checks. Inherits OpenZeppelin `ERC20` (it is the LP token) and `ReentrancyGuardTransient` (DECISIONS M3-5). | `APPROVED` (D1, D4, D11) |
| `AMMFactory` | Sorts token addresses, rejects duplicates, deploys and registers Pools. Holds no user funds; no owner. | `APPROVED` (D1, D10) |
| Maths helpers | Quote, integer square root (`Math.sqrt`), `Math.mulDiv`. | `APPROVED` (D12) |
| Test-only mocks | Standard ERC-20 (18 and 6 decimals); U8 taxed ERC-20; exclusive-FOT mock (negative tests); reentrancy probe; failing / false-returning / no-return token; a token whose Pool balance can be reduced (deficit tests). | `APPROVED` |

Names `AMMPool` (`src/AMMPool.sol`) and `AMMMath` (`src/libraries/AMMMath.sol`) are `APPROVED` (DECISIONS M2-1); other names remain `PROPOSED`.

Not introduced without separate approval: Router, Oracle, flash swaps, owner/governance, upgradeable proxy, deployment workflow.

## 3. Token support tiers

| Tier | Behaviour | Status |
|---|---|---|
| Tier 0 | Standard ERC-20: amount debited = amount credited. Tested with 18- and 6-decimal mocks. | `APPROVED` |
| Tier 1 | The U8 model, all four conditions: (1) inclusive — `transfer(g)` debits the sender exactly `g`; (2) recipient receives `g − floor(g × taxBps / 10000)`; (3) `taxBps` fixed, the same for every address, `< 10000`; (4) truthful `balanceOf`. | `APPROVED` (U8) |
| Unsupported | Exclusive FOT (debits sender more than `g`), rebasing, untruthful `balanceOf`, ERC-777 hooks, blacklisting/freezing, address-dependent exemptions, changing tax rates. | `OUT-OF-SCOPE` |

Unsupported tokens either cause a revert (some are deliberately detected, e.g. by A8) or behave outside the guarantees of this document. Compatibility claims must state direction, operation and assumptions. `SafeERC20` handles missing or `false` return values; it does not make any token's economics correct.

## 4. State variables

Names are `PROPOSED`.

| Location | State | Meaning | Status |
|---|---|---|---|
| Pool | `token0`, `token1` (`immutable`) | Nonzero, distinct, `token0 < token1`; set in the constructor. | `APPROVED` |
| Pool | `reserve0`, `reserve1` (`uint256`) | Last accepted accounting state; **not** necessarily equal to `balanceOf`. | `APPROVED` (U6) |
| Pool | `surplusRecipient` (`immutable`) | Constructor argument; four checks (§7.1); no setter. | `APPROVED` (U3) |
| Pool | LP `totalSupply`, `balanceOf`, `allowance` | Inherited from OZ `ERC20`; includes the locked 1,000. | `APPROVED` |
| Pool | `MINIMUM_LIQUIDITY = 1000` (`constant`) | Smallest LP units, held by `address(this)`. | `APPROVED` (U2) |
| Pool | `FEE_BPS = 30`, `BPS_DENOMINATOR = 10_000` (`constant`) | No setter. | `APPROVED` (U1) |
| Pool | Reentrancy lock | OZ `ReentrancyGuardTransient` (transient storage). | `APPROVED` (D11, M3-5) |
| Factory | `getPair[token0][token1]` plus reverse lookup | At most one Pool per unordered pair. | `APPROVED` |
| Factory | `allPairs` | Enumeration. | `APPROVED` (U11) |
| Factory | `surplusRecipient` (`immutable`) shared by all Pools | Constructor argument; rejects `address(0)` and the Factory itself; no setter. | `APPROVED` (M7-1) |
| — | `kLast`, `feeTo`, owner | Absent. | `FUTURE-ONLY` |

An `immutable` is assigned once in the constructor and embedded in the runtime bytecode (no storage slot); nobody can change it afterwards. The deployer (`msg.sender`) is not recorded and gains no rights.

## 5. Reserve accounting

### 5.1 Three quantities

For each token `i`:

- `balance_i` = `token_i.balanceOf(address(this))`, the actual on-chain balance.
- `reserve_i` = the stored recorded reserve. Only the functions in §5.2 change it.
- `surplus_i = balance_i − reserve_i` when positive; a *deficit* when `balance_i < reserve_i`.

**Principle:** each function recognises only balance changes that happen **inside that call**, measured with before/after snapshots. Surplus that existed before the call is not attributed to the caller and stays until `skim()`. Each before-snapshot is taken immediately before its own transfer, never reused from an earlier reading (DECISIONS M6-8: about 860 gas per call kept for simpler, locally verifiable measurement).

Uniswap V2's unconditional `reserve := balance` is not used: it would silently absorb surplus and could not separate a caller's contribution from earlier balances.

### 5.2 Per-function rules (`APPROVED`, A1 / ADR-019)

| Function | Entry condition | Measurement | Reserve change | Surplus | FOT effect |
|---|---|---|---|---|---|
| `addLiquidity` | No deficit in either token | Per token: Pool balance before → `safeTransferFrom` → after; `net_i` = difference | `reserve_i += net_i` | Unchanged | Inbound tax already excluded from `net_i`; shares use `net_i` only |
| `removeLiquidity` | No deficit | `amount_i = mulDiv(shares, reserve_i, S)`; recipient balance before/after | `reserve_i −= amount_i` | Unchanged | Recipient may receive less than `amount_i`; MIN-NET applies |
| `swapExactInput` | No deficit | Inbound as in add, giving `a`; quote uses reserves only; recipient balance before/after | `reserveIn += a` (fee included); `reserveOut −= out` | Unchanged | `a` is net; MIN-NET applies to output |
| `sync` | None | Read both balances | Per token: if `balance_i < reserve_i` then `reserve_i := balance_i`, else unchanged | Never absorbed (Gate R=(b)) | No transfer |
| `skim` | None (A2: per-token independent) | Read both balances | Unchanged | Per token with `balance_i > reserve_i`: send the difference to `surplusRecipient` | Recipient may receive less; Pool accounting unaffected |

### 5.3 Deficit (`APPROVED`, U4 revised by A2)

- Under Tier 0 / Tier 1 assumptions a deficit should not arise; one indicates a token outside the supported model.
- `addLiquidity`, `removeLiquidity` and `swapExactInput` revert at entry if **either** token is in deficit.
- `sync()` lowers the affected reserve to the balance and emits an event. The loss is borne by all LPs pro rata. With no deficit, `sync()` returns without change (U5).
- `skim()` is not blocked by a deficit: it handles each token independently (A2). Example: token1 in deficit and token0 with surplus → `skim()` sends token0's surplus and skips token1.
- Entry check placement and error `ReserveDeficit()`: DECISIONS M6-2.

**Terminal pool (`APPROVED`, DECISIONS M6-1 / ADR-023).** If `sync()` lowers a reserve to 0 while `totalSupply() > 0`, the Pool is terminal: `addLiquidity` and `swapExactInput` revert `InsufficientLiquidity()`; `removeLiquidity` pays 0 of the zero-reserve token and the proportional amount of the other (§6.3, M4-3r), so LPs recover the remaining assets. Known limitations: the Pool can never trade again through the current interface, and the reserves backing the 1,000 locked LP can never be redeemed. Recovery is an extension candidate (DECISIONS §8).

### 5.4 Surplus (`APPROVED`, Gate R=(b))

- On-chain, a mistaken transfer and an intentional one look identical; the documents do not call surplus a "donation".
- Only destination: `skim()` → `surplusRecipient`. Anyone may call it; the caller cannot choose the recipient. With no surplus it returns without change (U5).
- LP redemption uses recorded reserves; surplus never takes part.
- Refunds to mistaken senders are voluntary off-chain actions by the controller of `surplusRecipient`; the contract cannot enforce them.

### 5.5 Balance invariants (`APPROVED`, A1)

"Supported tokens" means Tier 0 or Tier 1 (§3). Each invariant names how it is enforced and which tests cover it ([TEST_MATRIX.md](TEST_MATRIX.md)).

| ID | Invariant | Enforced by | Tests |
|---|---|---|---|
| BI-1 | After every successful call, `balance_i ≥ reserve_i` for both tokens (supported tokens). | Construction of §5.2 + BI-2/BI-5 | I2 |
| BI-2 | (Restated 2026-11-21; original wording and reason in DECISIONS ADR-025.) `addLiquidity`, `removeLiquidity` and `swapExactInput` change each reserve only by the measured Pool-side change of their **own** transfers, each measured from a fresh snapshot (M6-8); surplus present before the call is never credited to the caller, and a transfer made by someone else during the call stays surplus (B08). **Not claimed:** that surplus is unchanged by foreign in-call transfers. | Construction of §5.2 (M5/M6) | B01–B03, B08 |
| BI-2′ | **`addLiquidity` only (M8, design approved, not implemented):** under truthful asset measurement, a successful deposit credits to reserves only its own measured arrival `n_i`; `surplus_end ≥ surplus_start` for both tokens; any other arrival stays surplus. Option X1 only (`reserve_i += n_i`). Not a property of `swapExactInput` / `removeLiquidity` (THREAT_MODEL T30) and not a guarantee about ERC-20 tokens in general. | On-chain: `B^end − B^start ≥ n_i`, else `InCallBalanceLoss()` (DECISIONS M8-11) | M8 tests (TEST_MATRIX §3.2) |
| BI-3 | `skim()` leaves reserves unchanged and, for every token that had surplus, leaves `balance_i == reserve_i`. | §7.8 | B04, R03 |
| BI-4 | `sync()` never increases a reserve; afterwards `reserve_i = min(old reserve_i, balance_i)`; balances unchanged. | §7.7 | B05, R05 |
| BI-5 | Every Pool outbound transfer of `x` lowers the Pool's own balance by exactly `x`; otherwise the call reverts. | On-chain check (A8) | B06, X04 |
| BI-6 | Every user minimum is met by the recipient's actual balance increase (MIN-NET). | On-chain check | B07, S04, W04 |
| BI-7 | After the first deposit, `balanceOf(address(this)) == 1000` LP forever (0 before it). | No code path moves Pool-held LP; transfers to the Pool are rejected (LP-SELF, §7.9) | P05, P06, I1 |
| BI-8 | LP `totalSupply` changes only in `addLiquidity` (mint) and `removeLiquidity` (burn). | Only those call `_mint` / `_burn` | P03, P04, I1 |
| BI-9 | Every successful swap satisfies the fee-adjusted inequality (§6.5). | Formula (§6.4) and tests; no on-chain assertion (A9, DECISIONS M5-9) | S11, S15, I3, Z01 |

BI-7 can be stated as `== 1000` only because of LP-SELF: without it, anyone could `transfer` LP to the Pool address and those tokens would also be locked forever (§7.9).

Not an invariant: `reserve0 × reserve1` may fall in `removeLiquidity` and `sync()`. Monotonicity is required only per swap (BI-9).

## 6. Mathematics

Notation: `r0`, `r1` recorded reserves before the call; `S` LP `totalSupply` before the call; `D = 10_000`; `t_i` tax hint in bps.

### 6.1 Initial deposit (D5-B, U2)

```text
pull amount0Max and amount1Max (tax hints ignored, U9 option i)
net0, net1     = measured Pool balance increases
grossShares    = Math.sqrt(net0 × net1)            // floor
require grossShares > MINIMUM_LIQUIDITY
_mint(address(this), 1000)                          // permanent lock
providerShares = grossShares − 1000  →  _mint(recipient, providerShares)
r0 = net0; r1 = net1
```

- No ratio exists yet, so the first depositor sets the initial price. No oracle.
- Tax hints are ignored because there is no ratio to hit; measured `net_i` is sufficient.
- OZ v5 `_mint(address(0), …)` reverts, which is why the lock is held by the Pool instead (A5).

### 6.2 Later deposits — L-α (`APPROVED`, U9 / A7)

**Inputs:** `amount0Max`, `amount1Max` (gross caps), `tax0Bps`, `tax1Bps` (untrusted hints; 0 for Tier 0), `minShares`.

**Seven conditions:** (1) U8 tax model; (2) rounding tolerance `[T, T+1]`; (3) gross debit `≤` cap; (4) shares and reserves from measured net only; (5) any failure reverts the whole transaction; (6) a wrong hint reverts, never mints unfair shares; (7) no refund path.

**Steps:**

```text
require t_i < D
1. cap_i = amountMax_i − mulDiv(amountMax_i, t_i, D)          // predicted max net
2. n1 = mulDiv(cap0, r1, r0)
   if n1 ≤ cap1:  (T0, T1) = (cap0, n1)
   else:          (T0, T1) = (mulDiv(cap1, r0, r1), cap1)
   require T0 > 0 and T1 > 0
3. g_i = mulDiv(T_i, D, D − t_i, Rounding.Ceil);  require g_i ≤ amountMax_i
4. per token, once: Pool balance before → safeTransferFrom(msg.sender, this, g_i) → after
   net_i = difference;  require T_i ≤ net_i ≤ T_i + 1
5. shares = min(mulDiv(net0, S, r0), mulDiv(net1, S, r1))
   require shares > 0 and shares ≥ minShares
6. reserve_i += net_i;  _mint(recipient, shares)
```

**Worked example.** `r0 = 1000`, `r1 = 2000`; token1 tax 1% (`t1 = 100`); caps `100`, `300`.
cap = (100, 297); n1 = 200 ≤ 297 → T = (100, 200); g1 = ceil(200 × 10000 / 9900) = 203; token1 net = 203 − floor(2.03) = 201 ∈ [200, 201] ✓. The extra 1 unit of token1 stays in reserves for all LPs.

**Tolerance proof (under U8).** Let `g = ceil(T·D/(D−t))` and `net(g) = g − floor(g·t/D)`.
- Lower: `g ≥ T·D/(D−t)` ⇒ `g·(D−t)/D ≥ T`; and `net(g) ≥ g − g·t/D = g·(D−t)/D ≥ T`.
- Upper: `g < T·D/(D−t) + 1` ⇒ `g·(D−t)/D < T + (D−t)/D ≤ T + 1`; and `net(g) < g − g·t/D + 1 < T + 2`. Since `net(g)` is an integer, `net(g) ≤ T + 1`.

A bounded exhaustive check of this formula (all `T ≤ 300`, all `0 ≤ t < 10000`, Python, run outside the repository on 2026-11-17) found no counterexample. This checks the formula only, not the future Solidity code; Z05 must test the implementation.

**Open comparison — step 3 gross rule (`PENDING`, start of M8).** The student asked for a dedicated comparison before implementing this step:

| | Current: ceiling gross | Alternative: minimal necessary gross |
|---|---|---|
| Rule | `g = ceil(T·D/(D−t))` | smallest `g` with `g − floor(g·t/D) ≥ T` |
| Net received | `T` or `T + 1` | Smallest net `≥ T` reachable (often exactly `T`) |
| Worked example (`T = 200`, `t = 100`) | `g = 203`, net `201` | `g = 202`, net `200` (`floor(2.02) = 2`) |
| Points to analyse | Simple closed form; proven bound; may deliver one extra unit to LPs | Less over-delivery; needs a correction step or proof; tolerance and gas differ |

To decide at that time: whether a one-unit over-delivery is acceptable, the exact tolerance check in step 4, and how the user cap `amountMax_i` constrains the chosen `g_i`. Until then, the step sequence above is the approved baseline and only step 3's gross rule is open.

**Notes.**
- With `t_i = 0`: `g_i = T_i = net_i`, i.e. ordinary optimal deposit.
- A wrong hint makes `net_i` fall outside `[T_i, T_i+1]` and reverts (tests L10a–c).
- Remaining imbalance is integer-rounding dust (floor in step 2, +1 in step 4). It goes to all LPs and is **not zero**; the report must say so.
- The Pool cannot directly observe how much the token debited the sender. Condition (3) relies on U8 condition (1); tests check it by measuring the caller's balance (L11).

### 6.3 Withdrawal (D7-A)

```text
amount_i = mulDiv(shares, r_i, S)        // floor; ≤ r_i because shares ≤ S
require not (amount0 == 0 and amount1 == 0)
require amount_i > 0 for every token with r_i > 0     // M4-3r; r_i == 0 only in a terminal pool:
                                                      // no transfer, net_i = 0, MIN-NET still applies
_burn(msg.sender, shares); reserve_i −= amount_i
send amount_i to recipient; MIN-NET: recipient increase ≥ min_iNet
```

Rounding down favours the LPs who remain.

### 6.4 Swap — exact formula (D8-B, U1)

`a` = measured net input; `rIn`, `rOut` = recorded reserves before the swap.

```text
aFee = a × 9970                                  // a × (D − FEE_BPS)
out  = mulDiv(aFee, rOut, rIn × D + aFee)        // floor
require a > 0                                    // AMMMath reverts InsufficientInputAmount
require out > 0                                  // swapExactInput only; AMMMath returns 0 (M2-5r)
reserveIn += a;  reserveOut −= out
```

- `out < rOut` always holds when `rIn > 0`, because `aFee / (rIn·D + aFee) < 1`.
- All of `a` enters `reserveIn`; 0.3% of it is excluded from pricing, so the fee stays in the Pool for LPs. `skim()` cannot reach it because it is inside recorded reserves.
- Exact-input only; no exact-output.
- The implementation must return **exactly** this value — not less (would underpay users) and not more (would break §6.5; see tightness below).

### 6.5 Fee-adjusted invariant and proof

For every successful swap, with pre-swap `rIn`, `rOut`:

```text
(rIn × D + a × 9970) × (rOut − out)  ≥  rIn × rOut × D
```

**Proof.** Let `den = rIn·D + aFee`. Since `out ≤ aFee·rOut/den`,
`rOut − out ≥ rOut − aFee·rOut/den = rOut·rIn·D/den`, hence `den·(rOut − out) ≥ rIn·rOut·D`. ∎

**Why this inequality and not the weaker one.** `(rIn + a)(rOut − out) ≥ rIn·rOut` also holds for a 0-bps implementation, so it cannot show the fee was charged. The fee-adjusted form fails if the code forgets the fee.

**Tightness.** In every reference case below, `out + 1` violates the inequality (checked by script). So the tests detect over-payment by even one unit.

**Scope.** This holds per swap only. `removeLiquidity` and `sync()` may lower `r0 × r1`.

**On-chain assertion:** not used (A9 decided 2026-11-19, DECISIONS M5-9). Because `out` comes from the formula, the assertion is mathematically redundant; its only value would be catching an implementation bug at run time. Measured cost (G01, TEST_MATRIX §14.2): +836 gas per swap, +154 B runtime; the inequality is enforced by tests instead (S11, S15, Z01).

### 6.6 Arithmetic and input ranges (`APPROVED`, U6 / A4)

Solidity 0.8 checked arithmetic reverts on overflow instead of wrapping, so an overflow produces a failed transaction, not a wrong number. The question per formula is: for which inputs might a legitimate call revert? Bounds below are **sufficient conditions derived by hand**, to be confirmed by boundary tests (Z06); they are not claims that overflow is impossible.

| Formula | Operation | Behaviour | Sufficient no-revert condition (hand-derived) |
|---|---|---|---|
| Swap `aFee` | `a × 9970` checked | Reverts on overflow | `a < 2^256 / 9970` (about `2^242.7`) |
| Swap denominator | `rIn × D + aFee` checked | Reverts on overflow | `rIn × D + a × 9970 < 2^256` |
| Swap `out` | `mulDiv(aFee, rOut, den)` | Result `≤ rOut`, so cannot exceed `uint256`; reverts if `den = 0` (excluded by `a > 0`) | As above |
| Initial shares | `net0 × net1` checked, then `Math.sqrt` | Reverts if product `≥ 2^256` | `net0 × net1 < 2^256`, e.g. both `< 2^128` (about `3.4 × 10^20` whole 18-decimal tokens) |
| Later shares | `mulDiv(net_i, S, r_i)` | Reverts if the result exceeds `uint256` | `net_i × S / r_i < 2^256` |
| Redemption | `mulDiv(shares, r_i, S)` | Result `≤ r_i` | Always within range when `shares ≤ S` |
| L-α cap | `mulDiv(amountMax_i, t_i, D)` | Result `< amountMax_i` | Always within range |
| L-α target | `Math.mul512(cap0, r1)`, then plain division, `mulDiv`, or the token1 branch; token1 branch likewise (DECISIONS M4H-2) | Never reverts: if `cap0 × r1 / r0 ≥ 2^256` the token1 cap necessarily binds, and the token1 branch result is `< cap0` | All inputs (verified by the Z06 differential fuzz) |
| L-α gross | `mulDiv(T_i, D, D − t_i, Ceil)` | Reverts if result exceeds `uint256` | `T_i × D / (D − t_i) < 2^256` |
| Reserve updates | `reserve += net`, `reserve −= amount` checked | Reverts on overflow/underflow | Under BI-1 with truthful `balanceOf`, `reserve_i ≤ balance_i`; not asserted beyond checked arithmetic |
| §6.5 in tests | Products of two `uint256` values (`den × (rOut − out)`, `(rIn × D) × rOut`, `aFee × rOut`, `out × den`) | Computed exactly as 512-bit values by a test helper; compared as 512-bit numbers | No overflow possible in the test helper for any `uint256` inputs (DECISIONS M2-9) |

**Test input ranges:** unit tests use the reference values in §6.7; fuzz tests use `[1, 2^112]` for reserves and amounts, plus mixed 6/18-decimal scales; boundary tests (Z06) go just below and just above each threshold and expect success and a revert respectively, never a wrong value.

`uint112` reserves (Uniswap V2 style, enabling storage packing) are not used now. They remain a candidate gas optimisation, to be proposed only with before/after measurements (DECISIONS ADR-012).

`Math.Rounding.Ceil` confirmed in the installed OpenZeppelin v5.7.0 (`enum Rounding { Floor, Ceil, Trunc, Expand }`, M1).

### 6.7 Numerical reference cases (script-checked 2026-11-17)

| # | `rIn` | `rOut` | `a` | `out` at 0 bps | `out` at 30 bps | Notes |
|---|---:|---:|---:|---:|---:|---|
| 1 | 1,000,000 | 1,000,000 | 10,000 | 9,900 | **9,871** | Primary reference |
| 2 | 1,000,000 | 1,000,000 | 1,000,000 | 500,000 | **499,248** | Large trade |
| 3 | 1,000 | 1,000 | 1 | 0 | **0** | Must revert (`out = 0`) |
| 4 | 1,000 × 10^18 | 2,000 × 10^6 | 10^18 | 1,998,001 | **1,992,013** | 18-decimal in, 6-decimal out |
| 5 | 2,000 × 10^6 | 1,000 × 10^18 | 10^6 | 499,750,124,937,531,234 | **498,251,621,566,649,025** | 6-decimal in, 18-decimal out |

Case 1 by hand: `9.97 × 10^13 / 10,099,700,000 = 9871.58…` → 9,871. For all five cases the inequality holds with `out` and fails with `out + 1`.

## 7. Function specifications and security rules

Signatures, event names and custom-error names are `PROPOSED` until the relevant milestone. Common rules:

- Every state-changing function is `nonReentrant`.
- Deadline valid iff `block.timestamp <= deadline`.
- User-supplied `recipient ∉ {address(0), address(this)}` (U7); the internal lock mint is exempt.
- Token transfers use `SafeERC20`.
- A revert undoes every effect of the transaction, including earlier token transfers in it.

**Call-order note.** In `addLiquidity` and `swapExactInput` the inbound `safeTransferFrom` necessarily happens **before** reserves are updated, because the Pool must measure what it actually received. This departs from a pure checks-effects-interactions order. Protection: `nonReentrant` on every state-changing function, so a token callback cannot re-enter any of them. Residual: during that callback, view functions such as `getReserves()` return pre-update values (read-only reentrancy, THREAT_MODEL T13).

### 7.1 `constructor(address token0_, address token1_, address surplusRecipient_)`

- **Checks (in order, DECISIONS M2-3):** either token zero → `ZeroAddress()`; equal → `IdenticalTokens()`; `token0_ > token1_` → `TokensNotSorted()`; `surplusRecipient_ ∈ {address(0), token0_, token1_, address(this)}` → `InvalidSurplusRecipient()` (A3). The zero check comes first so a zero `token1_` is reported as `ZeroAddress`, not as unsorted.
- **Effects:** set three immutables; reserves 0; `totalSupply` 0.
- **Not done:** no record of `msg.sender`; no privileged role.
- **Limit:** the four recipient checks catch only those four values. A valid but wrong address, a lost key, or an address the token refuses to pay cannot be detected; an immutable mistake requires redeployment.
- **Tests:** K01–K04.

### 7.2 `addLiquidity(amount0Max, amount1Max, tax0Bps, tax1Bps, minShares, recipient, deadline) → (net0, net1, shares)`

1. `nonReentrant`.
2. Checks: deadline; recipient (U7); `amount0Max > 0`, `amount1Max > 0`; `tax_iBps < D`; no deficit in either token.
3. If `S == 0`: gross `g_i = amountMax_i` (§6.1). Else: compute `T_i`, `g_i` (§6.2 steps 1–3).
4. Inbound interaction, per token: snapshot Pool balance → `safeTransferFrom(msg.sender, this, g_i)` → snapshot → `net_i`. If `S > 0`: require `T_i ≤ net_i ≤ T_i + 1`.
5. Compute shares (§6.1 or §6.2 step 5); require `> 0` and `≥ minShares`.
6. Effects: `reserve_i += net_i`; if initial, `_mint(address(this), 1000)`; `_mint(recipient, shares)`; emit event.

- **Postconditions:** BI-2 (surplus unchanged); caller debited `g_i ≤ amountMax_i` per token (under U8); BI-7 after the first deposit.
- **Threats:** wrong hint, over-debit, attributing earlier surplus, reentrancy via token callback, dilution, first-depositor manipulation.
- **Tests:** L01–L14, B01, P05.
- **Staging:** M4 implements and tests Tier 0 (`tax = 0`) with the full signature (U10); Tier 1 is tested in M8.
- **M3:** only the initial (`S == 0`) branch; `S > 0` reverted `LaterDepositNotImplemented()` (DECISIONS M3-3). Exact checks, errors and event: DECISIONS M3-4. The deficit entry check is added in M6 (with reserves 0, no deficit can exist in M3).
- **M4:** `S > 0` with both hints 0 follows §6.2 with `t = 0` (`g_i = T_i`); errors per DECISIONS M4-2. `S > 0` with any non-zero hint reverts `TaxedLaterDepositNotImplemented()` before any transfer until M8 (DECISIONS M4-1).
- **M6:** in the `S > 0` branch only, in this order before any transfer: deficit → `ReserveDeficit()` (M6-2); either reserve 0 → `InsufficientLiquidity()` (terminal pool, M6-1); then the temporary hint check. With `S == 0` both reserves are 0, so no deficit can exist and the check is skipped.
- **M8 (design approved in principle, ABI not yet approved; DECISIONS M8-1 to M8-13):** the signature becomes a single struct parameter; this section is rewritten in the M8 decisions commit. Rules already fixed for that rewrite:
  - The per-token request field is a cap on what the Pool may request, **not a promise that this amount is transferred**. Step 2 and the re-plan may request less, and the payer's actual debit can differ from the request; the debit is bounded only by `maxDebit`.
  - The payer is always `msg.sender`. With a router, the router is the payer and `maxDebit` protects the router, not the end user. The LP `recipient` may differ from the payer.
  - On the initial deposit the excess fields have no effect (`u_i = 0` by definition).
  - Postcondition: BI-2′ (§5.5).

### 7.3 `removeLiquidity(shares, min0Net, min1Net, recipient, deadline) → (net0, net1)`

1. `nonReentrant`.
2. Checks: deadline; recipient (U7); `shares > 0`; no deficit (`ReserveDeficit()`, before the burn; M6-2).
3. Effects: `S := totalSupply()`; `_burn(msg.sender, shares)` (reverts `ERC20InsufficientBalance` if the caller's LP is insufficient — done before the `mulDiv` so an oversized `shares` never surfaces as an overflow Panic, DECISIONS M4-3).
4. `amount_i = mulDiv(shares, r_i, S)`; `InsufficientLiquidityBurned` if both are 0 or if `amount_i == 0` with `r_i > 0` (M4-3r); `reserve_i −= amount_i`. A token with `r_i == 0` (terminal pool) is not transferred in step 5; its `net_i = 0` is still checked against `min_iNet`.
5. Outbound interaction, per token: snapshot Pool and recipient balances → `safeTransfer(recipient, amount_i)` → require Pool decrease `== amount_i` (A8) → `net_i` = recipient increase → require `net_i ≥ min_iNet` (MIN-NET).
6. Emit event.

- Burns `msg.sender`'s shares; never the V2 pattern "transfer LP to the Pool, then burn the Pool's balance" (that would conflict with the lock in §7.9).
- **Postconditions:** BI-2, BI-5, BI-6, BI-7, BI-8.
- **Threats:** malicious recipient, taxed output, rounding, locked-share redemption.
- **Tests:** W01–W08, B02, B06, B07.

### 7.4 `swapExactInput(tokenIn, amountIn, minNetAmountOut, recipient, deadline) → netOut`

1. `nonReentrant`.
2. Checks, in order (DECISIONS M5-1): deadline (`DeadlineExpired`); recipient (U7, `InvalidRecipient`); `tokenIn ∈ {token0, token1}` (`InvalidTokenIn`); `amountIn > 0` (`InsufficientInputAmount`, M5-2); both recorded reserves nonzero (`InsufficientLiquidity`), read once and cached before any transfer; no deficit (`ReserveDeficit()`, added in M6 for add, remove and swap together; DECISIONS M4-6, M5-1, M6-2).
3. Inbound interaction: snapshot → `safeTransferFrom(msg.sender, this, amountIn)` → snapshot → `a`; `a == 0` reverts `InsufficientInputAmount` inside `AMMMath` (no separate Pool check).
4. Compute `out` (§6.4); require `out > 0`, else `InsufficientOutputAmount()` (the library quote itself may be 0, DECISIONS M2-5r).
5. Effects: `reserveIn += a`; `reserveOut −= out`.
6. Outbound interaction: snapshot Pool and recipient balances of `tokenOut` → `safeTransfer(recipient, out)` → require Pool decrease `== out` (A8) → `netOut` = recipient increase → require `netOut ≥ minNetAmountOut` (MIN-NET).
7. Emit `Swap` (§9); return `netOut`.

- Uses the `tokenIn` address, not an index, so sorting cannot reverse the user's direction.
- **Postconditions:** BI-2, BI-5, BI-6, BI-9.
- **Threats:** quote error, taxed output, sandwich, reentrancy, balance manipulation, recipient = Pool.
- **Tests:** S01–S04, S08–S15 (S05–S07 in M6/M8), B03, B06, B07, Q01–Q04, X01, X02, X05, Z01, Z06.

### 7.5 `getAmountOut(tokenIn, amountIn) → out` (`view`)

- `getAmountOut(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut)` (DECISIONS M5-2). Shares the reserve-selection helper with `swapExactInput`, so invalid `tokenIn` (`InvalidTokenIn`), zero input (`InsufficientInputAmount`) and zero reserves (`InsufficientLiquidity`) revert with the same errors as the swap. No `nonReentrantView` (M5-5, THREAT_MODEL T13).
- Returns §6.4 using recorded reserves, treating `amountIn` as the net input. For taxed tokens the caller must reduce the input and output by the tax; the result may be stale by execution time.
- Returns **0** when the floored output is 0 (DECISIONS M2-5r); `swapExactInput` with the same inputs reverts (Q04).
- **Tests:** Q01–Q04.

### 7.6 `getReserves() → (reserve0_, reserve1_)` (`view`)

- Returns recorded reserves, not balances. **Test:** R01.

### 7.7 `sync()`

`sync() external nonReentrant` (DECISIONS M6-4).

1. `nonReentrant`.
2. Per token (token0 then token1): `b = balance`; if `b < reserve`, emit `ReserveSynced(token, reserve, b)` and set `reserve = b`; else do nothing (no write, no event).

- No outbound transfer; callable by anyone.
- **Postconditions:** BI-4.
- **Tests:** R02, R05, R08, R11, B05.

### 7.8 `skim()`

`skim() external nonReentrant` (DECISIONS M6-4).

1. `nonReentrant`. No parameters.
2. Per token, independently (token0 then token1): `b = balance`; if `b > reserve`, `x = b − reserve`; snapshot → `safeTransfer(surplusRecipient, x)` → require Pool decrease `== x` (A8, `OutboundTransferMismatch`); emit `SurplusSkimmed(token, x)`. Otherwise (equal or deficit) skip. The recipient's receipt is not measured (no MIN-NET).

- Never changes reserves; not blocked by a deficit in the other token (A2).
- If either transfer fails, the whole `skim()` reverts, so neither token's surplus is sent in that call; other functions are unaffected.
- **Postconditions:** BI-3, BI-5.
- **Tests:** R03, R04, R06, R09–R13, B04.

### 7.9 LP ERC-20 and the permanent lock

- Inherit OZ `ERC20` `transfer`, `approve`, `transferFrom`, with the single LP-SELF restriction below. No `ERC20Permit`.
- `_mint` is called only in `addLiquidity`; `_burn` only in `removeLiquidity`, always on `msg.sender`.

**Lock argument (A5).** OZ `ERC20` lets Pool-held LP decrease only through: `transfer` with `msg.sender == Pool`; `transferFrom` after an allowance granted by the Pool; or internal `_transfer` / `_update` / `_burn` with `from == address(this)`. The Pool has no private key, so only its own code could do any of these. Code-review rules, checked at every milestone:

- No `this.transfer`, `this.approve`, or external self-calls on the LP token.
- No `_approve(address(this), …)`, `_transfer(address(this), …)`, `_burn(address(this), …)`, or `_update(address(this), …)`.
- No `selfdestruct` / `delegatecall`; no `ERC20Permit` (which would allow signature-based approvals — irrelevant without a key, but excluded anyway).

Evidence: these review rules plus P05/P06 and invariant I1. This is code-review-plus-test evidence, not a formal proof.

**LP sent to the Pool (`APPROVED`, LP-SELF option ii).** Plain OZ `ERC20` would accept `transfer(pool, x)` / `transferFrom(…, pool, x)`, permanently locking those LP (no sweep exists, D10). The LP token therefore rejects any balance movement whose destination is `address(this)`, except the initial 1,000 lock mint. Mechanism (`APPROVED`, DECISIONS M3-2 / ADR-022): one override of `_update(from, to, value)`:

1. `from == address(this)` → `LockedLiquidity()`. Pool-held LP can never be transferred or burned, so the lock argument above no longer relies on code review alone.
2. `to == address(this)` → allowed only when `from == 0`, `totalSupply() == 0` and `value == MINIMUM_LIQUIDITY` (the first lock mint); otherwise `LPTransferToPool()`. Zero-value transfers to the Pool are also rejected.
3. Any mint (`from == 0`) or burn (`to == 0`) while no `nonReentrant` function is executing → `SupplyChangeOutsideGuard()`. A future `_mint`/`_burn` call site placed in an unguarded function therefore fails in testing instead of silently changing supply.

Review rule per milestone: every `_mint`/`_burn` call site in `src/` is listed and grep-checked. Consequence: BI-7 holds with equality and is enforced on-chain.

**Tests:** P01–P06.

## 8. Factory

| Topic | Specification | Status |
|---|---|---|
Contract `AMMFactory` in `src/AMMFactory.sol` (DECISIONS M7-4).

| Topic | Specification | Status |
|---|---|---|
| `constructor(address surplusRecipient_)` | Stores the shared recipient as `public immutable`; rejects `address(0)` and `address(this)` with `InvalidSurplusRecipient()`. | `APPROVED` (M7-1) |
| `createPair(address tokenA, address tokenB) external returns (address pool)` | Order: either address 0 → `ZeroAddress()`; equal → `IdenticalTokens()`; sort; either without code → `TokenHasNoCode()`; registered → `PairExists()`; `new AMMPool(token0, token1, surplusRecipient)` (the Pool's own four recipient checks still apply); register both orderings; push to `allPairs`; emit `PairCreated`. No external call, so no reentrancy point and no `nonReentrant`. | `APPROVED` (D1, U11, M7-2, M7-4) |
| `getPair(address, address)` (public mapping) | Both orders return the same address; 0 if no pair. The authoritative way to verify that a Pool is genuine. | `APPROVED` (M7-3) |
| `allPairs(uint256)`, `allPairsLength()` | Enumerable list in creation order. | `APPROVED` (U11, M7-4) |
| Deployment | Ordinary `new` (CREATE); no CREATE2. | `APPROVED` (U11) |
| Shared `surplusRecipient` | One immutable value for every Pool of this Factory. | `APPROVED` (M7-1) |
| Token code-existence check | Only in the Factory; the Pool constructor (M2) is unchanged, so a directly deployed Pool still accepts code-less addresses. Code existence does not prove ERC-20 compliance or safety. A pair cannot be created in advance for a not-yet-deployed token (including predictable future Pool / LP addresses). | `APPROVED` (M7-2) |
| Pool stores `factory` | No; Pool constructor, ABI and M2-2 unchanged. | `APPROVED` (M7-3) |
| Privileges and funds | No owner, no setter, no payable entry point, no `fallback` / `receive`, no token-withdrawal function. Report wording: "Factory does not expose payable entry points or token withdrawal functions." | `APPROVED` (D10, M7-7) |
| Terminal pairs | A pair whose Pool is terminal (M6-1) can never be re-created by this Factory (`PairExists()`). | `APPROVED` (M7-5) |

**Deployment requirements for the shared recipient (DECISIONS M7-1):**

- Before deploying the Factory, the recipient address must be fixed explicitly and checked, so that it can receive **and withdraw** the expected ERC-20 tokens (e.g. an account or contract under the operator's control that is not blacklisted by those tokens).
- A wrong recipient cannot be repaired in an existing Factory. The only remedy is deploying a new Factory; Pools of the old Factory keep the old recipient and are not migrated automatically.
- If the recipient is itself a token contract X, no pair containing X can be created (the Pool constructor rejects it with `InvalidSurplusRecipient()`).

**Effects of introducing the Factory:**

- The Pool constructor's `msg.sender` becomes the Factory; the Pool neither reads nor trusts it (M7-3). The Pool constructor signature is unchanged.
- Token validation is split: zero / identical / code existence / uniqueness in the Factory, zero / identical / sort / four recipient checks in the Pool; both are tested.
- The Factory's runtime embeds the Pool's creation code; `forge build --sizes` is checked against the 24,576-byte runtime limit and the 49,152-byte initcode limit for both contracts (F07). The Factory grows with the Pool (M8).
- Regression (M7-6): the M2–M6 Pool unit suites keep deploying directly; a Factory integration suite runs representative flows on Factory Pools, and equal runtime `codehash` for identical constructor arguments shows that both deployment paths execute the same code.

No public one-time `initialize()`; use the parameterised constructor.

## 9. Events (`PROPOSED`)

Typed events for: pair creation, liquidity added, liquidity removed, swap, deficit reconciled (`sync`), surplus sent (`skim`). Fields are fixed per milestone.

- `LiquidityAdded(address indexed sender, address indexed recipient, uint256 net0, uint256 net1, uint256 shares)` — `APPROVED` (M3-4); used for initial and later deposits.
- `LiquidityRemoved(address indexed sender, address indexed recipient, uint256 shares, uint256 amount0, uint256 amount1)` — `APPROVED` (M4-3); amounts are the Pool-side reserve decreases. The recipient's actual receipt is the function's return value; MIN-NET is enforced on-chain from balance snapshots, not from events.
- `ReserveSynced(address indexed token, uint256 previousReserve, uint256 newReserve)` — `APPROVED` (M6-4); one per lowered token, only when a reserve actually changes; the LP loss is `previousReserve − newReserve`.
- `SurplusSkimmed(address indexed token, uint256 amount)` — `APPROVED` (M6-4); one per token with surplus; `amount` is the Pool-side decrease (A8); the recipient is always `surplusRecipient`.
- `PairCreated(address indexed token0, address indexed token1, address pool, uint256 pairCount)` — `APPROVED` (M7-4); emitted by the Factory with sorted tokens; `pairCount` is `allPairs.length` after the push.
- `Swap(address indexed sender, address indexed recipient, address tokenIn, uint256 amountIn, uint256 amountOut, uint256 netOut)` — `APPROVED` (M5-3). Three distinct, non-interchangeable quantities: `amountIn` = `a`, the Pool's measured input increase in this call; `amountOut` = `out`, the Pool's measured output decrease (= `reserveOut` decrease, checked by A8); `netOut` = the recipient's measured output increase (MIN-NET basis; below `amountOut` for a taxed output).

## 10. Not in the current version

| Item | Status |
|---|---|
| Protocol fee, `feeTo`, `kLast`, deferred LP minting | `FUTURE-ONLY` |
| On-chain surplus ownership / claim accounting | `FUTURE-ONLY` |
| Owner, pause, governance | `FUTURE-ONLY` |
| `uint112` reserve packing | `FUTURE-ONLY` (measured optimisation candidate) |
| Three-asset Pool, StableSwap, cross-chain, flash swap, proxy, oracle, Router, mainnet deployment | `OUT-OF-SCOPE` |
| Exact-output swap | `OUT-OF-SCOPE` |

## 11. Cross-references

[DECISIONS.md](DECISIONS.md) (status) · [THREAT_MODEL.md](THREAT_MODEL.md) (threats, limits) · [TEST_MATRIX.md](TEST_MATRIX.md) (test IDs) · [MILESTONES.md](MILESTONES.md) (progress).

Source comments must cite report sections; the report must cite contracts and functions.

## 12. Review log

Findings from the 2026-11-17 consistency review and how they were resolved.

| # | Finding | Resolution |
|---|---|---|
| 1 | `skim()` behaviour during a deficit was contradictory | A2: per-token independence (§5.3, §7.8) |
| 2 | U8 `PENDING` while L-α condition 1 relied on it | U8 approved (A6) |
| 3 | D8 / D10 status questioned | Both `APPROVED` in DECISIONS.md; no conflict |
| 4 | Range bound enforced or assumed | A4: `uint256`, documented per-formula ranges, no on-chain cap (§6.6) |
| 5 | Lock destination | A5: Pool itself (§7.9) |
| 6 | Shared Factory `surplusRecipient` | Resolved in M7 (DECISIONS M7-1) |
| 7 | L-α tolerance unproven; first-deposit hints | Proof in §6.2; hints ignored on first deposit (A7) |
| 8 | Inflation protection overstated | Wording is "mitigation", THREAT_MODEL T4 |
| 9 | Brief not verified | Verified against `Coursework.docx` (§1) |
| 10 | Test-ID ranges in §7 out of date | Updated |
| 11 | §7.4 "enforces §6.5" vs. assertion `PENDING` | §7.4 now cites BI-9; assertion per A9 |
| 12 | Lock balance `== 1000` was unjustified while LP could be sent to the Pool | LP-SELF (ii) approved: transfers to the Pool are rejected, so BI-7 holds with equality |
| 14 | L-α step 3 gross rule may over-deliver one unit | Dedicated comparison (ceiling vs. minimal necessary gross) deferred to the start of M8 (§6.2) |
| 13 | `skim()` failure scope understated | §7.8 and T15 state that the whole call reverts |
