// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {addParams} from "./utils/AddParams.sol";

/// @notice TEST_MATRIX Z03 (M10 P1): mixed 6 / 18-decimal tokens near the top of the fuzz range
///         `[1, 2^112]` (ARCHITECTURE §6.6). Tier 0 `MockERC20` tokens; which of the two is
///         token0 depends on the deployment addresses, so the test works by "6-dec" / "18-dec"
///         side and maps to positions.
///         Ranges: the 18-decimal initial amount `x18 ∈ [2^104, 2^112]`; the 6-decimal amount
///         `x6 ∈ [x18 / 1e15, x18 / 1e9]` (a value ratio of 1e-3 to 1e3 per whole token at the
///         1e12 scale difference), so `x6 ∈ [about 2^54, 2^82]`. Swaps: input in
///         `[1, reserveIn]` of either token; a later deposit with caps up to 2^112 on the 18-dec
///         side and up to the 6-dec reserve on the other; then a full exit of that deposit.
///         Expected values are computed independently in the test from the approved formulas
///         (§6.4 swap with `mulDiv`, M8 σ = min floor, §6.3 redemption) and compared exactly;
///         products are compared as 512-bit numbers. Any revert other than the classified
///         rounding-to-zero cases fails the run.
contract AMMPoolMixedDecimalsTopTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant TOP = 2 ** 112;

    address internal alice = makeAddr("alice");
    address internal eve = makeAddr("eve");
    address internal bob = makeAddr("bob");
    address internal surplus = makeAddr("surplusRecipient");

    MockERC20 internal t0;
    MockERC20 internal t1;
    AMMPool internal pool;
    bool internal sixIsToken0;

    function setUp() public {
        MockERC20 six = new MockERC20("SIX", "SIX", 6);
        MockERC20 eighteen = new MockERC20("EIGHTEEN", "E18", 18);
        sixIsToken0 = address(six) < address(eighteen);
        (t0, t1) = sixIsToken0 ? (six, eighteen) : (eighteen, six);
        pool = new AMMPool(address(t0), address(t1), surplus);
        address[3] memory users = [alice, eve, bob];
        for (uint256 i; i < 3; ++i) {
            t0.mint(users[i], 2 ** 120);
            t1.mint(users[i], 2 ** 120);
            vm.startPrank(users[i]);
            t0.approve(address(pool), MAX);
            t1.approve(address(pool), MAX);
            vm.stopPrank();
        }
    }

    function _pos(uint256 a6, uint256 a18) internal view returns (uint256 a0, uint256 a1) {
        (a0, a1) = sixIsToken0 ? (a6, a18) : (a18, a6);
    }

    function _geq512(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (bool) {
        (uint256 h1, uint256 l1) = Math.mul512(a, b);
        (uint256 h2, uint256 l2) = Math.mul512(c, d);
        return h1 > h2 || (h1 == h2 && l1 >= l2);
    }

    function _swapChecked(bool sixIn, uint256 seed) internal {
        bool zeroForOne = sixIn == sixIsToken0;
        (uint256 r0, uint256 r1) = pool.getReserves();
        (uint256 rIn, uint256 rOut) = zeroForOne ? (r0, r1) : (r1, r0);
        uint256 a = bound(seed, 1, rIn);
        uint256 aFee = a * 9970;
        uint256 den = rIn * 10_000 + aFee;
        uint256 want = Math.mulDiv(aFee, rOut, den);
        vm.prank(eve);
        if (want == 0) {
            vm.expectRevert(AMMPool.InsufficientOutputAmount.selector);
            pool.swapExactInput(zeroForOne ? address(t0) : address(t1), a, 0, eve, block.timestamp);
            return;
        }
        uint256 out = pool.swapExactInput(zeroForOne ? address(t0) : address(t1), a, 0, eve, block.timestamp);
        assertEq(out, want, "swap output = formula");
        assertLt(out, rOut, "out < rOut");
        // §6.5: (rIn·D + aFee)·(rOut − out) ≥ (rIn·D)·rOut.
        assertTrue(_geq512(den, rOut - out, rIn * 10_000, rOut), "fee-adjusted invariant");
        (uint256 e0, uint256 e1) = pool.getReserves();
        (uint256 eIn, uint256 eOut) = zeroForOne ? (e0, e1) : (e1, e0);
        assertEq(eIn, rIn + a, "reserveIn += a");
        assertEq(eOut, rOut - out, "reserveOut -= out");
    }

    struct Dep {
        uint256 r0;
        uint256 r1;
        uint256 s;
        uint256 n0;
        uint256 n1;
        uint256 shares;
    }

    function _depositChecked(uint256 c6, uint256 c18) internal returns (Dep memory d) {
        (d.r0, d.r1) = pool.getReserves();
        d.s = pool.totalSupply();
        (uint256 a0, uint256 a1) = _pos(c6, c18);
        vm.prank(bob);
        try pool.addLiquidity(addParams(a0, a1, 0, bob, block.timestamp)) returns (
            uint256 n0, uint256 n1, uint256 shares
        ) {
            (d.n0, d.n1, d.shares) = (n0, n1, shares);
        } catch (bytes memory reason) {
            bytes4 sel = bytes4(reason);
            assertTrue(
                sel == AMMPool.InsufficientDepositAmount.selector || sel == AMMPool.InsufficientShares.selector,
                "unexpected deposit revert"
            );
            return d; // shares = 0: rounding-to-zero case
        }
        assertLe(d.n0, a0, "n0 <= cap0");
        assertLe(d.n1, a1, "n1 <= cap1");
        uint256 want = Math.min(Math.mulDiv(d.n0, d.s, d.r0), Math.mulDiv(d.n1, d.s, d.r1));
        assertEq(d.shares, want, "sigma = min floor(n_i S / r_i)");
        (uint256 e0, uint256 e1) = pool.getReserves();
        // I10 per token: e_i · S ≥ r_i · (S + σ).
        assertTrue(_geq512(e0, d.s, d.r0, d.s + d.shares), "per-share token0 not down");
        assertTrue(_geq512(e1, d.s, d.r1, d.s + d.shares), "per-share token1 not down");
    }

    function _exitChecked(Dep memory d) internal {
        (uint256 r0, uint256 r1) = pool.getReserves();
        uint256 s = pool.totalSupply();
        uint256 w0 = Math.mulDiv(d.shares, r0, s);
        uint256 w1 = Math.mulDiv(d.shares, r1, s);
        vm.prank(bob);
        if (w0 == 0 || w1 == 0) {
            vm.expectRevert(AMMPool.InsufficientLiquidityBurned.selector);
            pool.removeLiquidity(d.shares, 0, 0, bob, block.timestamp);
            return;
        }
        (uint256 g0, uint256 g1) = pool.removeLiquidity(d.shares, 0, 0, bob, block.timestamp);
        assertEq(g0, w0, "redeem token0 = floor(shares r0 / S)");
        assertEq(g1, w1, "redeem token1 = floor(shares r1 / S)");
        assertLe(g0, d.n0, "round trip token0 <= contributed");
        assertLe(g1, d.n1, "round trip token1 <= contributed");
        (uint256 e0, uint256 e1) = pool.getReserves();
        assertGt(e0, 0, "reserve0 > 0");
        assertGt(e1, 0, "reserve1 > 0");
    }

    struct In {
        uint256 x18;
        uint256 x6;
        bool sixIn1;
        uint256 a1;
        bool sixIn2;
        uint256 a2;
        uint256 c6;
        uint256 c18;
    }

    function testFuzz_Z03_mixedDecimalsNearTop(In memory f) public {
        f.x18 = bound(f.x18, 2 ** 104, TOP);
        f.x6 = bound(f.x6, f.x18 / 1e15, f.x18 / 1e9);
        (uint256 i0, uint256 i1) = _pos(f.x6, f.x18);
        vm.prank(alice);
        (,, uint256 seedShares) = pool.addLiquidity(addParams(i0, i1, 0, alice, block.timestamp));
        assertEq(seedShares, Math.sqrt(f.x6 * f.x18) - 1000, "initial shares");

        _swapChecked(f.sixIn1, f.a1);
        _swapChecked(f.sixIn2, f.a2);

        (uint256 r0, uint256 r1) = pool.getReserves();
        uint256 r6 = sixIsToken0 ? r0 : r1;
        Dep memory d = _depositChecked(bound(f.c6, 1, r6), bound(f.c18, 1, TOP));
        if (d.shares != 0) _exitChecked(d);
    }
}
