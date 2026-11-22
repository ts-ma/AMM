// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {IAMMPool} from "../src/interfaces/IAMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeERC20} from "./mocks/MockFeeERC20.sol";
import {MockDeficitERC20} from "./mocks/MockDeficitERC20.sol";
import {Wide512} from "./utils/Wide512.sol";
import {addParams, addParamsOrdered} from "./utils/AddParams.sol";

/// @notice M8 commit 5c (tests only; M8 remains WIP). TEST_MATRIX Z08 (i), (ii)/(iii), (iii-b) and
///         the 512-bit differential oracle; Z09 invariant fuzz.
///         The oracle is independent of the Pool and of OpenZeppelin: exact 512-bit products and
///         bitwise long division; it replays the documented M8 later-deposit algorithm (step 2 →
///         first pull → re-plan → second pull → σ → M8-13 (d) error order → effects) for fee
///         mocks whose per-transfer behaviour is known exactly (inclusive tax, absolute bonus).
contract AMMPoolMeasuredDifferentialTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    MockFeeERC20.Path internal constant PULL = MockFeeERC20.Path.TransferFrom;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal surplusRecipient = makeAddr("surplusRecipient");

    AMMPool internal p;
    MockFeeERC20 internal f0;
    MockFeeERC20 internal f1;
    uint160 internal nextLow = 0x60000;
    uint160 internal nextHigh = type(uint160).max - 0x4000;

    // ------------------------------------------------------------------
    // Independent 512-bit oracle
    // ------------------------------------------------------------------

    /// @dev floor(x·y/d); `over` when the quotient does not fit (hi ≥ d). Bitwise long division.
    function _floorMulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (bool over, uint256 q) {
        (uint256 hi, uint256 lo) = Wide512.mul(x, y);
        if (hi >= d) return (true, 0);
        if (hi == 0) return (false, lo / d);
        uint256 rem = hi;
        for (uint256 i; i < 256; ++i) {
            bool carry = rem >> 255 == 1;
            rem = (rem << 1) | ((lo >> (255 - i)) & 1);
            q <<= 1;
            if (carry || rem >= d) {
                unchecked {
                    rem -= d;
                }
                q |= 1;
            }
        }
    }

    function _sat(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        (bool over, uint256 q) = _floorMulDiv(x, y, d);
        return over ? MAX : q;
    }

    struct Fee {
        uint256 tax0;
        uint256 tax1;
        uint256 bonus0;
        uint256 bonus1;
    }

    /// @dev What the Pool receives for a pull of `value` of token i under the mock's rules.
    function _arrive(uint256 value, uint256 tax, uint256 bonus) internal pure returns (uint256) {
        (, uint256 fee) = _floorMulDiv(value, tax, 10_000);
        return value - fee + bonus;
    }

    struct Pred {
        bytes err;
        uint256 n0;
        uint256 n1;
        uint256 shares;
        uint256 req0; // requested (= payer debit, inclusive tax)
        uint256 req1;
    }

    function _step2(uint256 c0, uint256 c1, uint256 r0, uint256 r1) internal pure returns (uint256, uint256) {
        (bool over, uint256 q) = _floorMulDiv(c0, r1, r0);
        if (!over && q <= c1) return (c0, q);
        (, uint256 q0) = _floorMulDiv(c1, r0, r1);
        return (q0, c1);
    }

    function _predict(uint256 r0, uint256 r1, uint256 S, IAMMPool.AddLiquidityParams memory prm, Fee memory fee)
        internal
        pure
        returns (Pred memory e)
    {
        (e.req0, e.req1) = _step2(prm.amount0RequestMax, prm.amount1RequestMax, r0, r1);
        if (e.req0 == 0 || e.req1 == 0) {
            e.err = abi.encodeWithSelector(AMMPool.InsufficientDepositAmount.selector);
            return e;
        }
        // Pulls and re-plan
        if (prm.token1First) {
            e.n1 = _arrive(e.req1, fee.tax1, fee.bonus1);
            if (e.n1 != e.req1) {
                e.req0 = _min(prm.amount0RequestMax, _sat(e.n1, r0, r1));
                if (e.req0 == 0) {
                    e.err = abi.encodeWithSelector(AMMPool.InsufficientDepositAmount.selector);
                    return e;
                }
            }
            e.n0 = _arrive(e.req0, fee.tax0, fee.bonus0);
        } else {
            e.n0 = _arrive(e.req0, fee.tax0, fee.bonus0);
            if (e.n0 != e.req0) {
                e.req1 = _min(prm.amount1RequestMax, _sat(e.n0, r1, r0));
                if (e.req1 == 0) {
                    e.err = abi.encodeWithSelector(AMMPool.InsufficientDepositAmount.selector);
                    return e;
                }
            }
            e.n1 = _arrive(e.req1, fee.tax1, fee.bonus1);
        }
        // BI-2′ and maxDebit cannot fail here (no foreign change; unbounded limits).
        e.shares = _min(_sat(e.n0, S, r0), _sat(e.n1, S, r1));
        if (e.shares == 0 || e.shares < prm.minShares) {
            e.err = abi.encodeWithSelector(AMMPool.InsufficientShares.selector);
        } else if (e.shares > MAX - S) {
            e.err = abi.encodeWithSignature("Panic(uint256)", 0x11);
        }
        // maxExcess unbounded: no excess error.
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // ------------------------------------------------------------------
    // Fixture
    // ------------------------------------------------------------------

    function _deploy(string memory artifact, bool low, uint8 decimals) internal returns (address at) {
        at = low ? address(nextLow++) : address(nextHigh--);
        require(at.code.length == 0, "address reused");
        deployCodeTo(artifact, abi.encode("T", "T", decimals), at);
    }

    /// @dev Two fee mocks; alice's untaxed initial deposit (a0, a1); bob gets `fund` of each and
    ///      unlimited approval.
    function _setUpFee(uint256 a0, uint256 a1, uint256 fund, uint8 d0, uint8 d1) internal {
        f0 = MockFeeERC20(_deploy("MockFeeERC20.sol:MockFeeERC20", true, d0));
        f1 = MockFeeERC20(_deploy("MockFeeERC20.sol:MockFeeERC20", false, d1));
        p = new AMMPool(address(f0), address(f1), surplusRecipient);
        f0.mint(alice, a0);
        f1.mint(alice, a1);
        f0.mint(bob, fund);
        f1.mint(bob, fund);
        address[2] memory users = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(users[i]);
            f0.approve(address(p), MAX);
            f1.approve(address(p), MAX);
            vm.stopPrank();
        }
        vm.prank(alice);
        p.addLiquidity(addParams(a0, a1, 0, alice, block.timestamp));
    }

    function _isqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    // ------------------------------------------------------------------
    // Differential fuzz (Z08 oracle): exact outcome, error and end state
    // ------------------------------------------------------------------

    struct In {
        uint256 a0;
        uint256 a1;
        uint256 c0;
        uint256 c1;
        uint256 minShares;
        bool t1First;
    }

    function testFuzz_Z08_differentialOracle(In memory x, Fee memory fee) public {
        x.a0 = bound(x.a0, 1, 2 ** 120);
        x.a1 = bound(x.a1, 1, 2 ** 120);
        vm.assume(_isqrt(x.a0 * x.a1) > 1000);
        fee.tax0 = bound(fee.tax0, 0, 10_000);
        fee.tax1 = bound(fee.tax1, 0, 10_000);
        fee.bonus0 = bound(fee.bonus0, 0, 2 ** 200);
        fee.bonus1 = bound(fee.bonus1, 0, 2 ** 200);
        // Bob's funds cover every possible request (requests never exceed the caps), and the
        // bonus mints cannot overflow either token's total supply.
        uint256 fund = MAX - 2 ** 121 - 2 ** 201;
        x.c0 = bound(x.c0, 1, fund);
        x.c1 = bound(x.c1, 1, fund);
        x.minShares = bound(x.minShares, 0, 2 ** 64);
        _setUpFee(x.a0, x.a1, fund, 18, 18);
        f0.setTax(PULL, fee.tax0);
        f1.setTax(PULL, fee.tax1);
        f0.setBonus(PULL, fee.bonus0);
        f1.setBonus(PULL, fee.bonus1);

        IAMMPool.AddLiquidityParams memory prm =
            addParamsOrdered(x.c0, x.c1, x.minShares, bob, block.timestamp, x.t1First);
        Pre memory b = _pre();
        Pred memory e = _predict(b.r0, b.r1, b.S, prm, fee);
        vm.prank(bob);
        (bool ok, bytes memory ret) = address(p).call(abi.encodeCall(AMMPool.addLiquidity, (prm)));
        if (e.err.length != 0) {
            assertFalse(ok, "oracle predicts a revert");
            assertEq(ret, e.err, "exact revert data");
            _assertUnchanged(b);
            return;
        }
        assertTrue(ok, "oracle predicts success");
        _checkSuccess(e, b, ret, prm);
    }

    struct Pre {
        uint256 r0;
        uint256 r1;
        uint256 S;
        uint256 bob0;
        uint256 bob1;
        uint256 sur0;
        uint256 sur1;
    }

    function _pre() internal view returns (Pre memory b) {
        (b.r0, b.r1) = p.getReserves();
        b.S = p.totalSupply();
        b.bob0 = f0.balanceOf(bob);
        b.bob1 = f1.balanceOf(bob);
        b.sur0 = f0.balanceOf(address(p)) - b.r0;
        b.sur1 = f1.balanceOf(address(p)) - b.r1;
    }

    function _assertUnchanged(Pre memory b) internal view {
        assertEq(keccak256(abi.encode(_pre())), keccak256(abi.encode(b)), "state unchanged after revert");
    }

    function _checkSuccess(Pred memory e, Pre memory b, bytes memory ret, IAMMPool.AddLiquidityParams memory prm)
        internal
        view
    {
        (uint256 n0, uint256 n1, uint256 s) = abi.decode(ret, (uint256, uint256, uint256));
        assertEq(n0, e.n0, "net0");
        assertEq(n1, e.n1, "net1");
        assertEq(s, e.shares, "shares");
        assertEq(b.bob0 - f0.balanceOf(bob), e.req0, "token0 request = debit (inclusive)");
        assertEq(b.bob1 - f1.balanceOf(bob), e.req1, "token1 request = debit (inclusive)");
        assertLe(e.req0, prm.amount0RequestMax, "request <= RequestMax");
        assertLe(e.req1, prm.amount1RequestMax);
        (uint256 rr0, uint256 rr1) = p.getReserves();
        assertEq(rr0, b.r0 + n0, "reserve0 += net0");
        assertEq(rr1, b.r1 + n1, "reserve1 += net1");
        assertEq(p.totalSupply(), b.S + s);
    }

    // ------------------------------------------------------------------
    // Z08 fixed cases
    // ------------------------------------------------------------------

    /// @dev (i) One side saturates, the other fits: r = (1, 1e60), S = 1e30. Token0 credits a
    ///      2^200 bonus: n0·S/r0 ≥ 2^256 (saturated), n1·S/r1 = 1e60·1e30/1e60 = 1e30 → σ = 1e30,
    ///      the deposit succeeds. Both pull orders (token0 first re-plans token1 to its cap).
    function test_Z08i_oneSideSaturates_otherFits_succeeds() public {
        for (uint256 k; k < 2; ++k) {
            _setUpFee(1, 1e60, 1e61, 18, 18);
            assertEq(p.totalSupply(), 1e30);
            f0.setBonus(PULL, 2 ** 200);
            vm.prank(bob);
            (uint256 n0, uint256 n1, uint256 s) =
                p.addLiquidity(addParamsOrdered(1, 1e60, 0, bob, block.timestamp, k == 1));
            assertEq(n0, 1 + 2 ** 200);
            assertEq(n1, 1e60);
            assertEq(s, 1e30, "sigma = the fitting side");
        }
    }

    /// @dev Pool with r = (r0, r1) and S = 65535 (a divisor of 2^256 − 1), reached by an initial
    ///      deposit and slash + sync. Token0 is a fee mock (bonus), token1 a deficit mock.
    function _setUpS65535(uint256 i0, uint256 i1, uint256 slashTo) internal returns (MockDeficitERC20 d1) {
        f0 = MockFeeERC20(_deploy("MockFeeERC20.sol:MockFeeERC20", true, 18));
        d1 = MockDeficitERC20(_deploy("MockDeficitERC20.sol:MockDeficitERC20", false, 18));
        p = new AMMPool(address(f0), address(d1), surplusRecipient);
        f0.mint(alice, i0);
        d1.mint(alice, i1);
        vm.startPrank(alice);
        f0.approve(address(p), MAX);
        d1.approve(address(p), MAX);
        p.addLiquidity(addParams(i0, i1, 0, alice, block.timestamp));
        vm.stopPrank();
        assertEq(p.totalSupply(), 65_535, "S = 65535");
        d1.slash(address(p), i1 - slashTo);
        p.sync();
        uint256 big = MAX / 65_535 + 2;
        f0.mint(bob, 2 * big);
        d1.mint(bob, 2 * big);
        vm.startPrank(bob);
        f0.approve(address(p), MAX);
        d1.approve(address(p), MAX);
        vm.stopPrank();
    }

    /// @dev (iii) r = (1, 1), S = 65535, k = (2^256 − 1)/65535. Request (k, k), token0 first with
    ///      a 1-unit bonus: n0 = k + 1 → (k + 1)·65535 ≥ 2^256 (saturated); the re-plan asks
    ///      min(k, sat(k + 1)) = k of token1 → n1·65535 = 2^256 − 1 exactly. σ = 2^256 − 1, which
    ///      passes InsufficientShares (minShares ≤ max) → Panic 0x11 from the checked supply + σ,
    ///      never ExcessContributionTooHigh (maxExcess = 0) or a mint.
    function test_Z08iii_saturatedAndExactMax_panics() public {
        _setUpS65535(1, 65_535 * 65_535, 1);
        (uint256 r0, uint256 r1) = p.getReserves();
        assertEq(r0, 1);
        assertEq(r1, 1);
        uint256 k = MAX / 65_535;
        assertEq(k * 65_535, MAX, "65535 divides 2^256 - 1");
        f0.setBonus(PULL, 1);
        IAMMPool.AddLiquidityParams memory prm = addParams(k, k, MAX, bob, block.timestamp);
        (prm.maxExcess0, prm.maxExcess1) = (0, 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        p.addLiquidity(prm);
        assertEq(p.totalSupply(), 65_535);
    }

    /// @dev (iii-b) r = (2, 2), S = 65535, k as above, request (2k − 1, 2k − 1), no fees:
    ///      σ = floor((2k − 1)·65535/2) = 2^256 − 1 − 32768, inside (max − S, max). With
    ///      minShares = max > σ → InsufficientShares; with minShares = σ → Panic 0x11.
    function test_Z08iiib_sigmaBelowMaxAboveMaxMinusS() public {
        _setUpS65535(2, 2_147_418_113, 2); // floor(sqrt(2 · 2,147,418,113)) = 65535
        (uint256 r0, uint256 r1) = p.getReserves();
        assertEq(r0, 2);
        assertEq(r1, 2);
        uint256 k = MAX / 65_535;
        uint256 n = 2 * k - 1;
        uint256 sigma = MAX - 32_768;
        assertGt(sigma, MAX - 65_535);
        uint256 id = vm.snapshotState();
        vm.prank(bob);
        vm.expectRevert(AMMPool.InsufficientShares.selector);
        p.addLiquidity(addParams(n, n, MAX, bob, block.timestamp));
        vm.revertToState(id);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        p.addLiquidity(addParams(n, n, sigma, bob, block.timestamp));
        // and the oracle agrees on σ
        assertEq(_sat(n, 65_535, 2), sigma);
    }

    // ------------------------------------------------------------------
    // Z09 — invariant fuzz with seeded random tax per transfer
    // ------------------------------------------------------------------

    struct Z9 {
        uint256 a0;
        uint256 a1;
        uint256 c0;
        uint256 c1;
        uint256 seed;
        uint256 maxDebit0;
        uint256 maxDebit1;
        uint256 maxExcess0;
        uint256 maxExcess1;
        bool t1First;
        bool dec6;
    }

    /// @dev Reserves [1e3, 2^112], requests [1, 2^112], random tax in [0, 9999] bps per transfer
    ///      from a seed (reproducible), 6- or 18-decimal token1, random limits. On success:
    ///      per-share reserves never decrease; surplus never decreases (BI-2′); payer debit ≤
    ///      maxDebit; u ≤ maxExcess; request ≤ RequestMax. On revert: one of the specified errors
    ///      and the state unchanged. Uncovered: tokens outside the mocks' rules; foreign in-call
    ///      changes (B09); reserves outside the range.
    function testFuzz_Z09_invariants(Z9 memory z) public {
        z.a0 = bound(z.a0, 1e3, 2 ** 112);
        z.a1 = bound(z.a1, 1e3, 2 ** 112);
        vm.assume(_isqrt(z.a0 * z.a1) > 1000);
        z.c0 = bound(z.c0, 1, 2 ** 112);
        z.c1 = bound(z.c1, 1, 2 ** 112);
        _setUpFee(z.a0, z.a1, 2 ** 113, 18, z.dec6 ? 6 : 18);
        f0.setRandomTax(PULL, z.seed, 0, 9999);
        f1.setRandomTax(PULL, z.seed ^ 0x5eed, 0, 9999);
        f0.mint(address(p), 777); // pre-existing surplus
        IAMMPool.AddLiquidityParams memory prm = addParamsOrdered(z.c0, z.c1, 0, bob, block.timestamp, z.t1First);
        prm.maxDebit0 = z.maxDebit0;
        prm.maxDebit1 = z.maxDebit1;
        prm.maxExcess0 = z.maxExcess0;
        prm.maxExcess1 = z.maxExcess1;

        Pre memory b = _pre();
        vm.prank(bob);
        (bool ok, bytes memory ret) = address(p).call(abi.encodeCall(AMMPool.addLiquidity, (prm)));
        if (!ok) {
            bytes4 sel = bytes4(ret);
            assertTrue(
                sel == AMMPool.InsufficientDepositAmount.selector || sel == AMMPool.InsufficientShares.selector
                    || sel == AMMPool.PayerDebitTooHigh.selector || sel == AMMPool.ExcessContributionTooHigh.selector,
                "only specified errors"
            );
            _assertUnchanged(b);
            return;
        }
        _z9Invariants(b, ret, prm);
    }

    function _z9Invariants(Pre memory b, bytes memory ret, IAMMPool.AddLiquidityParams memory prm) internal view {
        (uint256 n0, uint256 n1, uint256 s) = abi.decode(ret, (uint256, uint256, uint256));
        assertEq(p.totalSupply(), b.S + s);
        _z9PerShareAndSurplus(b);
        // payer limits; inclusive tax: debit = request <= RequestMax
        uint256 d0 = b.bob0 - f0.balanceOf(bob);
        uint256 d1 = b.bob1 - f1.balanceOf(bob);
        assertLe(d0, prm.maxDebit0, "debit0 <= maxDebit0");
        assertLe(d1, prm.maxDebit1, "debit1 <= maxDebit1");
        assertLe(d0, prm.amount0RequestMax);
        assertLe(d1, prm.amount1RequestMax);
        // u_i = n_i - ceil(sigma r_i / S) <= maxExcess_i (oracle division)
        assertLe(n0 - _ceilMulDiv(s, b.r0, b.S), prm.maxExcess0, "u0 <= maxExcess0");
        assertLe(n1 - _ceilMulDiv(s, b.r1, b.S), prm.maxExcess1, "u1 <= maxExcess1");
    }

    /// @dev Per-share reserves never decrease (rr_i * S >= r_i * S2, 512-bit) and surplus never
    ///      decreases (BI-2').
    function _z9PerShareAndSurplus(Pre memory b) internal view {
        (uint256 rr0, uint256 rr1) = p.getReserves();
        uint256 S2 = p.totalSupply();
        assertTrue(_lte512(b.r0, S2, rr0, b.S), "per-share reserve0");
        assertTrue(_lte512(b.r1, S2, rr1, b.S), "per-share reserve1");
        assertGe(f0.balanceOf(address(p)) - rr0, b.sur0, "surplus0");
        assertGe(f1.balanceOf(address(p)) - rr1, b.sur1, "surplus1");
    }

    /// @dev a*b <= c*d in 512 bits.
    function _lte512(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (bool) {
        (uint256 h1, uint256 l1) = Wide512.mul(a, b);
        (uint256 h2, uint256 l2) = Wide512.mul(c, d);
        return Wide512.lte(h1, l1, h2, l2);
    }

    function _ceilMulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        (, uint256 q) = _floorMulDiv(x, y, d);
        (uint256 hi, uint256 lo) = Wide512.mul(q, d);
        (uint256 ph, uint256 pl) = Wide512.mul(x, y);
        return (hi == ph && lo == pl) ? q : q + 1;
    }
}
