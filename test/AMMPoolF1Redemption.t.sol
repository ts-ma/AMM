// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {IAMMPool} from "../src/interfaces/IAMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockTaxedERC20} from "./mocks/MockTaxedERC20.sol";
import {MulDiv512} from "./utils/MulDiv512.sol";
import {addParamsOrdered} from "./utils/AddParams.sol";

/// @notice F1-T6: book entitlement vs executable immediate redemption (THREAT_MODEL T6).
///
///         Definitions, per token i, for a later deposit that mints σ shares from net n_i
///         at the pre-deposit reserve r_i and supply S (all integers, measured by the Pool):
///         - exact book claim of the new shares right after the deposit:
///             C_i = σ·(r_i + n_i) / (S + σ)   (a rational number);
///         - book shortfall          n_i − C_i = (n_i·S − σ·r_i) / (S + σ) ≥ 0
///           (equal to S/(S+σ)·(u_i + δ_i) with δ_i = ceil(σ·r_i/S) − σ·r_i/S);
///         - redemption rounding     C_i − floor(C_i) ∈ [0, 1);
///         - actual shortfall vs the Pool's net   n_i − floor(C_i).
///         floor(C_i) is the Pool-side redemption gross; the wallet receipt is the recipient's
///         actual balance change. Conditions for "receipt = floor(C_i)": the redemption is the very next Pool call
///         (no state change in between), both reserves are positive, both gross outputs
///         floor(C_i) are at least 1 (otherwise `removeLiquidity` reverts
///         `InsufficientLiquidityBurned`, M4-3r), and the outbound transfer arrives in full
///         (Tier 0). The comparison base is the Pool's measured net n_i, not the payer's debit;
///         an inbound tax (debit − net) and an outbound tax (gross out − receipt) are listed
///         separately and are not part of the shortfalls above.
///
///         Expected values: an independent integer/rational Python model (literal constants
///         below) and, in the fuzz test, MulDiv512 (no OpenZeppelin `mulDiv`).
///         State for the deterministic cases: as F1-T5 (initial deposit (1000, 1e9), swap 100
///         token0 in), then bob deposits with caps (max, c1) and immediately redeems σ to carol.
contract AMMPoolF1RedemptionTest is Test {
    uint256 internal constant MAX = type(uint256).max;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal surplusRecipient = makeAddr("surplusRecipient");

    MockERC20 internal t0;
    MockERC20 internal t1;
    AMMPool internal pool;

    // ------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------

    function _tokens(bool taxed1) internal {
        t0 = new MockERC20("Plain", "PLN", 18);
        for (uint256 salt;; ++salt) {
            MockERC20 c = taxed1
                ? MockERC20(address(new MockTaxedERC20{salt: bytes32(salt)}("Taxed", "TAX", 18, 1000)))
                : new MockERC20{salt: bytes32(salt)}("Plain1", "PL1", 18);
            if (address(c) > address(t0)) {
                t1 = c;
                break;
            }
        }
        pool = new AMMPool(address(t0), address(t1), surplusRecipient);
        _fund(alice, 2 ** 122);
        _fund(bob, 2 ** 122);
    }

    function _fund(address who, uint256 amount) internal {
        t0.mint(who, amount);
        t1.mint(who, amount);
        vm.startPrank(who);
        t0.approve(address(pool), MAX);
        t1.approve(address(pool), MAX);
        vm.stopPrank();
    }

    function _p3(bool taxed1) internal {
        _tokens(taxed1);
        vm.prank(alice);
        pool.addLiquidity(addParamsOrdered(1000, 1e9, 0, alice, block.timestamp, false));
        vm.prank(alice);
        pool.swapExactInput(address(t0), 100, 0, alice, block.timestamp);
    }

    function _deposit(uint256 c0, uint256 c1) internal returns (uint256 n0, uint256 n1, uint256 sh) {
        vm.prank(bob);
        (n0, n1, sh) = pool.addLiquidity(addParamsOrdered(c0, c1, 0, bob, block.timestamp, false));
    }

    struct State {
        uint256 r0;
        uint256 r1;
        uint256 lpSupply;
        uint256 bobLP;
        uint256 aliceLP;
        uint256 poolLP;
        uint256 pool0;
        uint256 pool1;
        uint256 bob0;
        uint256 bob1;
        uint256 carol0;
        uint256 carol1;
        uint256 supply0;
        uint256 supply1;
    }

    function _state() internal view returns (State memory s) {
        (s.r0, s.r1) = pool.getReserves();
        s.lpSupply = pool.totalSupply();
        s.bobLP = pool.balanceOf(bob);
        s.aliceLP = pool.balanceOf(alice);
        s.poolLP = pool.balanceOf(address(pool));
        s.pool0 = t0.balanceOf(address(pool));
        s.pool1 = t1.balanceOf(address(pool));
        s.bob0 = t0.balanceOf(bob);
        s.bob1 = t1.balanceOf(bob);
        s.carol0 = t0.balanceOf(carol);
        s.carol1 = t1.balanceOf(carol);
        s.supply0 = t0.totalSupply();
        s.supply1 = t1.totalSupply();
    }

    function _assertSame(State memory x, State memory y) internal pure {
        assertEq(x.r0, y.r0, "reserve0");
        assertEq(x.r1, y.r1, "reserve1");
        assertEq(x.lpSupply, y.lpSupply, "LP totalSupply");
        assertEq(x.bobLP, y.bobLP, "bob LP");
        assertEq(x.aliceLP, y.aliceLP, "alice LP");
        assertEq(x.poolLP, y.poolLP, "Pool LP (lock)");
        assertEq(x.pool0, y.pool0, "Pool token0");
        assertEq(x.pool1, y.pool1, "Pool token1");
        assertEq(x.bob0, y.bob0, "bob token0");
        assertEq(x.bob1, y.bob1, "bob token1");
        assertEq(x.carol0, y.carol0, "carol token0");
        assertEq(x.carol1, y.carol1, "carol token1");
        assertEq(x.supply0, y.supply0, "token0 totalSupply");
        assertEq(x.supply1, y.supply1, "token1 totalSupply");
    }

    function _redeemCall(uint256 shares) internal view returns (bytes memory) {
        return abi.encodeCall(AMMPool.removeLiquidity, (shares, 0, 0, carol, block.timestamp));
    }

    // ------------------------------------------------------------------
    // 1. Redemption fails: integer gross outputs (0, 826,746)
    // ------------------------------------------------------------------

    /// @dev Tier 0, caps (max, 1e6): net (1, 1,000,000), σ = 909 (F1-T5). After the deposit
    ///      r = (1101, 910,338,911), S + σ = 1,000,909. Book claim C = (1,000,809 / 1,000,909,
    ///      827,498,070,099 / 1,000,909) ≈ (0.9999, 826,746.557); gross outputs floor(C) =
    ///      (0, 826,746). token0's gross 0 against a positive reserve → `InsufficientLiquidityBurned`;
    ///      bob keeps the 909 shares, no token is transferred, every balance, reserve and the
    ///      LP supply equal the pre-redemption values.
    ///      The other example of THREAT_MODEL T6, output (0, 909,082) at reserves (1100, 1e9) with
    ///      S = 1e6, is checked only in the Python model; that state is not constructed here.
    function test_F1T6_tier0_redemptionOfFreshSharesReverts() public {
        _p3(false);
        (uint256 n0, uint256 n1, uint256 sh) = _deposit(MAX, 1e6);
        assertEq(n0, 1);
        assertEq(n1, 1e6);
        assertEq(sh, 909);
        (uint256 r0, uint256 r1) = pool.getReserves();
        assertEq(r0, 1101);
        assertEq(r1, 910_338_911);
        assertEq(pool.totalSupply(), 1_000_909);
        // independent gross outputs
        (, uint256 g0) = MulDiv512.floorMulDiv(909, 1101, 1_000_909);
        (, uint256 g1) = MulDiv512.floorMulDiv(909, 910_338_911, 1_000_909);
        assertEq(g0, 0, "gross0 floors to 0");
        assertEq(g1, 826_746, "gross1");
        assertEq(uint256(909) * 1101, 1_000_809, "C0 numerator");
        assertEq(uint256(909) * 910_338_911, 827_498_070_099, "C1 numerator");

        State memory pre = _state();
        vm.expectCall(address(t0), abi.encodeWithSelector(IERC20.transfer.selector), 0);
        vm.expectCall(address(t1), abi.encodeWithSelector(IERC20.transfer.selector), 0);
        vm.prank(bob);
        (bool ok, bytes memory ret) = address(pool).call(_redeemCall(909));
        assertFalse(ok, "redemption must revert");
        assertEq(ret, abi.encodePacked(AMMPool.InsufficientLiquidityBurned.selector), "exact revert data");
        _assertSame(pre, _state());
        assertEq(pool.balanceOf(bob), 909, "user still holds its 909 shares");
        assertEq(t0.balanceOf(carol), 0, "no token0 paid");
        assertEq(t1.balanceOf(carol), 0, "no token1 paid");
    }

    // ------------------------------------------------------------------
    // 2. Redemption succeeds (Tier 0): receipt = floor(C)
    // ------------------------------------------------------------------

    /// @dev Tier 0, caps (max, 1e7): net (12, 10,000,000), σ = 10,909, S + σ = 1,010,909.
    ///      | | token0 | token1 |
    ///      |---|---|---|
    ///      | n_i·S − σ·r_i (book numerator) | 100 | 80,021,819,901 |
    ///      | book shortfall n − C | 0.000099 | 79,158.2822 |
    ///      | C | 11.999901 | 9,920,841.7178 |
    ///      | rounding C − floor(C) | 0.999901 | 0.7178 |
    ///      | receipt floor(C) | 11 | 9,920,841 |
    ///      | actual shortfall n − floor(C) | 1 | 79,159 |
    ///      No tax: the payer's wallet loss equals the actual shortfall.
    function test_F1T6_tier0_immediateRedemptionReceivesFloorOfBookClaim() public {
        _p3(false);
        (uint256 n0, uint256 n1, uint256 sh) = _deposit(MAX, 1e7);
        assertEq(n0, 12);
        assertEq(n1, 1e7);
        assertEq(sh, 10_909);
        uint256 S = 1_000_000;
        uint256 r0 = 1100;
        uint256 r1 = 909_338_911;
        assertEq(pool.totalSupply(), S + sh);
        assertEq(n0 * S - sh * r0, 100, "book numerator token0");
        assertEq(n1 * S - sh * r1, 80_021_819_901, "book numerator token1");

        uint256 b0 = t0.balanceOf(bob);
        uint256 b1 = t1.balanceOf(bob);
        vm.prank(bob);
        (uint256 got0, uint256 got1) = pool.removeLiquidity(sh, 0, 0, bob, block.timestamp);
        uint256 recv0 = t0.balanceOf(bob) - b0;
        uint256 recv1 = t1.balanceOf(bob) - b1;
        assertEq(recv0, 11, "receipt token0 (balance change)");
        assertEq(recv1, 9_920_841, "receipt token1 (balance change)");
        assertEq(got0, recv0);
        assertEq(got1, recv1);
        _assertFloorAndShortfall(n0, r0, S, sh, recv0, 1);
        _assertFloorAndShortfall(n1, r1, S, sh, recv1, 79_159);
        assertEq(pool.balanceOf(bob), 0);
        assertEq(pool.totalSupply(), S, "supply back to S");
    }

    /// @dev receipt == floor(σ(r+n)/(S+σ)) via MulDiv512, the actual shortfall equals the
    ///      literal, and actual = book + rounding with rounding ∈ [0, 1):
    ///      0 ≤ (n − receipt)·(S+σ) − (n·S − σ·r) < S + σ.
    function _assertFloorAndShortfall(uint256 n, uint256 r, uint256 S, uint256 sh, uint256 receipt, uint256 actual)
        internal
        pure
    {
        (, uint256 fc) = MulDiv512.floorMulDiv(sh, r + n, S + sh);
        assertEq(receipt, fc, "receipt = floor(C)");
        assertEq(n - receipt, actual, "actual shortfall n - floor(C)");
        uint256 book = n * S - sh * r; // ≥ 0, else this underflows
        uint256 lhs = (n - receipt) * (S + sh);
        assertGe(lhs, book, "actual >= book shortfall");
        assertLt(lhs - book, S + sh, "rounding difference < 1");
    }

    // ------------------------------------------------------------------
    // 2b. Redemption succeeds with a taxed token1 (taxes listed separately)
    // ------------------------------------------------------------------

    /// @dev Tier 1 (token1 inclusive tax 10 %, burned), caps (max, 1e7), token0 first.
    ///      Pre-deposit r = (1100, 818,405,020), S = 948,683. Payer debit (13, 10,000,000);
    ///      inbound tax token1 1,000,000; net (13, 9,000,000); σ = 10,432; S + σ = 959,115.
    ///      Book numerators n·S − σ·r = (857,679, 545,831,360); book shortfall ≈ (0.8942,
    ///      569.099); Pool-side gross out floor(C) = (12, 8,999,430); actual shortfall vs net
    ///      (1, 570). Outbound tax on token1 floor(8,999,430·0.1) = 899,943, so the wallet
    ///      receives (12, 8,099,487). Payer wallet: −13 + 12 token0, −10,000,000 + 8,099,487 token1
    ///      = inbound tax 1,000,000 + actual shortfall 570 + outbound tax 899,943.
    struct D {
        uint256 r0;
        uint256 r1;
        uint256 S;
        uint256 n0;
        uint256 n1;
        uint256 sh;
    }

    function test_F1T6_tier1_redemptionPoolSideFloorAndTaxesSeparate() public {
        _tier1Redeem(_tier1Deposit());
    }

    function _tier1Deposit() internal returns (D memory d) {
        _p3(true);
        (d.r0, d.r1) = pool.getReserves();
        assertEq(d.r0, 1100);
        assertEq(d.r1, 818_405_020);
        d.S = pool.totalSupply();
        assertEq(d.S, 948_683);
        uint256 d0 = t0.balanceOf(bob);
        uint256 d1 = t1.balanceOf(bob);
        uint256 supply1 = t1.totalSupply();
        (d.n0, d.n1, d.sh) = _deposit(MAX, 1e7);
        assertEq(d0 - t0.balanceOf(bob), 13, "debit token0");
        assertEq(d1 - t1.balanceOf(bob), 1e7, "debit token1");
        assertEq(supply1 - t1.totalSupply(), 1_000_000, "inbound tax burned");
        assertEq(d.n0, 13);
        assertEq(d.n1, 9_000_000);
        assertEq(d.sh, 10_432);
        assertEq(d.n0 * d.S - d.sh * d.r0, 857_679);
        assertEq(d.n1 * d.S - d.sh * d.r1, 545_831_360);
    }

    function _tier1Redeem(D memory d) internal {
        State memory pre = _state();
        vm.prank(bob);
        (uint256 got0, uint256 got1) = pool.removeLiquidity(d.sh, 0, 0, carol, block.timestamp);
        State memory post = _state();
        uint256 out0 = pre.pool0 - post.pool0;
        uint256 out1 = pre.pool1 - post.pool1;
        assertEq(out0, 12, "Pool-side gross out token0");
        assertEq(out1, 8_999_430, "Pool-side gross out token1");
        _assertFloorAndShortfall(d.n0, d.r0, d.S, d.sh, out0, 1);
        _assertFloorAndShortfall(d.n1, d.r1, d.S, d.sh, out1, 570);
        assertEq(post.carol0 - pre.carol0, 12, "wallet receipt token0");
        assertEq(post.carol1 - pre.carol1, 8_099_487, "wallet receipt token1");
        assertEq(got0, 12);
        assertEq(got1, 8_099_487, "returned = measured receipt");
        assertEq(pre.supply1 - post.supply1, 899_943, "outbound tax burned");
    }

    // ------------------------------------------------------------------
    // Fuzz (Tier 0): immediate redemption of fresh shares
    // ------------------------------------------------------------------

    struct F {
        uint256 a0;
        uint256 a1;
        uint8 swapDir;
        uint256 swapAmt;
        uint256 c0;
        uint256 c1;
        uint8 mode;
    }

    /// @dev Random reachable state (initial deposit [1e3, 2^100] per token, optional swap
    ///      [1, 2^100]), a later deposit (caps [1, 1e30], two modes force one tiny and one huge
    ///      cap; two more modes set one cap to exactly 1, which favours a gross output of 0) and the
    ///      immediate redemption of σ. Prediction with MulDiv512 only: step 2, σ,
    ///      floor(C_i). If either floor(C_i) is 0: `InsufficientLiquidityBurned`, full rollback,
    ///      the shares stay with bob, no transfer. Otherwise the receipts measured from carol's
    ///      balances equal floor(C_i), and actual = book + rounding with rounding ∈ [0, 1).
    ///      Deposits the model rejects are skipped (`vm.assume`); they are F1-T1's subject.
    function testFuzz_F1T6_immediateRedemption(F memory f) public {
        f.a0 = bound(f.a0, 1e3, 2 ** 100);
        f.a1 = bound(f.a1, 1e3, 2 ** 100);
        vm.assume(_isqrt(f.a0 * f.a1) > 1000);
        f.mode = uint8(bound(f.mode, 0, 4));
        if (f.mode == 3) {
            // one unit of token0: σ ≤ S/r0, the redemption branch that floors to 0
            f.c0 = 1;
            f.c1 = bound(f.c1, 1e27, 1e30);
        } else if (f.mode == 4) {
            f.c0 = bound(f.c0, 1e27, 1e30);
            f.c1 = 1;
        } else if (f.mode == 0) {
            f.c0 = bound(f.c0, 1e27, 1e30);
            f.c1 = bound(f.c1, 1, 1e3);
        } else if (f.mode == 1) {
            f.c0 = bound(f.c0, 1, 1e3);
            f.c1 = bound(f.c1, 1e27, 1e30);
        } else {
            f.c0 = bound(f.c0, 1, 1e30);
            f.c1 = bound(f.c1, 1, 1e30);
        }
        _fuzzRedeem(_fuzzDeposit(f));
    }

    function _fuzzDeposit(F memory f) internal returns (D memory d) {
        _tokens(false);
        vm.prank(alice);
        pool.addLiquidity(addParamsOrdered(f.a0, f.a1, 0, alice, block.timestamp, false));
        f.swapDir = uint8(bound(f.swapDir, 0, 2));
        if (f.swapDir != 0) {
            address tin = f.swapDir == 1 ? address(t0) : address(t1);
            uint256 amt = bound(f.swapAmt, 1, 2 ** 100);
            if (pool.getAmountOut(tin, amt) > 0) {
                vm.prank(alice);
                pool.swapExactInput(tin, amt, 0, alice, block.timestamp);
            }
        }
        (d.r0, d.r1) = pool.getReserves();
        d.S = pool.totalSupply();
        (uint256 tg0, uint256 tg1, uint256 sigma) = _predictDeposit(d.r0, d.r1, d.S, f.c0, f.c1);
        vm.assume(sigma > 0);
        (d.n0, d.n1, d.sh) = _deposit(f.c0, f.c1);
        assertEq(d.n0, tg0, "net0");
        assertEq(d.n1, tg1, "net1");
        assertEq(d.sh, sigma, "sigma");
    }

    function _fuzzRedeem(D memory d) internal {
        (, uint256 fc0) = MulDiv512.floorMulDiv(d.sh, d.r0 + d.n0, d.S + d.sh);
        (, uint256 fc1) = MulDiv512.floorMulDiv(d.sh, d.r1 + d.n1, d.S + d.sh);
        if (fc0 == 0 || fc1 == 0) {
            State memory pre = _state();
            vm.expectCall(address(t0), abi.encodeWithSelector(IERC20.transfer.selector), 0);
            vm.expectCall(address(t1), abi.encodeWithSelector(IERC20.transfer.selector), 0);
            vm.prank(bob);
            (bool ok, bytes memory ret) = address(pool).call(_redeemCall(d.sh));
            assertFalse(ok);
            assertEq(ret, abi.encodePacked(AMMPool.InsufficientLiquidityBurned.selector));
            _assertSame(pre, _state());
            assertEq(pool.balanceOf(bob), d.sh, "shares kept");
            return;
        }
        vm.prank(bob);
        pool.removeLiquidity(d.sh, 0, 0, carol, block.timestamp);
        _assertFloorAndShortfallNoLiteral(d.n0, d.r0, d.S, d.sh, t0.balanceOf(carol), fc0);
        _assertFloorAndShortfallNoLiteral(d.n1, d.r1, d.S, d.sh, t1.balanceOf(carol), fc1);
    }

    function _assertFloorAndShortfallNoLiteral(uint256 n, uint256 r, uint256 S, uint256 sh, uint256 receipt, uint256 fc)
        internal
        pure
    {
        assertEq(receipt, fc, "receipt = floor(C)");
        uint256 book = n * S - sh * r;
        uint256 lhs = (n - receipt) * (S + sh);
        assertGe(lhs, book, "actual >= book shortfall");
        assertLt(lhs - book, S + sh, "rounding difference < 1");
    }

    function _predictDeposit(uint256 r0, uint256 r1, uint256 S, uint256 c0, uint256 c1)
        internal
        pure
        returns (uint256 tg0, uint256 tg1, uint256 sigma)
    {
        (bool over, uint256 q) = MulDiv512.floorMulDiv(c0, r1, r0);
        if (!over && q <= c1) {
            (tg0, tg1) = (c0, q);
        } else {
            (, q) = MulDiv512.floorMulDiv(c1, r0, r1);
            (tg0, tg1) = (q, c1);
        }
        if (tg0 == 0 || tg1 == 0) return (tg0, tg1, 0);
        (, uint256 s0) = MulDiv512.floorMulDiv(tg0, S, r0);
        (, uint256 s1) = MulDiv512.floorMulDiv(tg1, S, r1);
        sigma = s0 < s1 ? s0 : s1;
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
}
