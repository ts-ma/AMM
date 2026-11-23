// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {IAMMPool} from "../src/interfaces/IAMMPool.sol";
import {MockFeeERC20} from "./mocks/MockFeeERC20.sol";
import {addParams} from "./utils/AddParams.sol";

/// @notice TEST_MATRIX L46 (M11): the worked deposit example of REPORT.md §5, executed on the real
///         Pool. It follows one deposit through every stage:
///         request cap → payer debit → Pool receipt (measured net) → LP shares → excess.
///         State: reserves (10,000, 20,000), S = isqrt(2e8) = 14,142 (smallest units).
///         token1 charges a 10 % inclusive tax on pulls (`MockFeeERC20`, burned from the payer's
///         debit), token0 is exact. bob requests at most (1,000, 2,500), token0 first, with
///         maxDebit (1,000, 2,000), maxExcess (100, 1), minShares 1,272.
///         Expected values: integer Python model of the approved formulas (ARCHITECTURE §7.2),
///         not the Solidity code:
///         - step 2 at the current ratio: targets (1,000, 2,000) (token0 cap binds);
///         - payer debit (1,000, 2,000); Pool receipt (1,000, 1,800); tax 200 burned;
///         - σ = min(⌊1,000·14,142/10,000⌋, ⌊1,800·14,142/20,000⌋) = min(1,414, 1,272) = 1,272;
///         - u = (1,000 − ⌈1,272·10,000/14,142⌉, 1,800 − ⌈1,272·20,000/14,142⌉) = (100, 1);
///         - reserves (11,000, 21,800), S = 15,414;
///         - an immediate full redemption returns (907, 1,798).
///         Each bound is shown to be binding: one unit tighter reverts with no state change.
contract AMMPoolReportExampleTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal surplus = makeAddr("surplusRecipient");

    MockFeeERC20 internal t0;
    MockFeeERC20 internal t1;
    AMMPool internal pool;

    function setUp() public {
        MockFeeERC20 a = new MockFeeERC20("A", "A", 18);
        MockFeeERC20 b = new MockFeeERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        pool = new AMMPool(address(t0), address(t1), surplus);
        address[2] memory users = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            t0.mint(users[i], 1e9);
            t1.mint(users[i], 1e9);
            vm.startPrank(users[i]);
            t0.approve(address(pool), MAX);
            t1.approve(address(pool), MAX);
            vm.stopPrank();
        }
        vm.prank(alice);
        pool.addLiquidity(addParams(10_000, 20_000, 0, alice, block.timestamp));
        t1.setTax(MockFeeERC20.Path.TransferFrom, 1000); // 10 % on pulls, from now on
    }

    function _params(uint256 maxDebit1, uint256 maxExcess0, uint256 minShares)
        internal
        view
        returns (IAMMPool.AddLiquidityParams memory)
    {
        return IAMMPool.AddLiquidityParams({
            amount0RequestMax: 1_000,
            amount1RequestMax: 2_500,
            maxDebit0: 1_000,
            maxDebit1: maxDebit1,
            maxExcess0: maxExcess0,
            maxExcess1: 1,
            minShares: minShares,
            recipient: bob,
            deadline: block.timestamp,
            token1First: false
        });
    }

    function _expectUnchangedRevert(IAMMPool.AddLiquidityParams memory p, bytes4 err) internal {
        (uint256 r0, uint256 r1) = pool.getReserves();
        uint256 s = pool.totalSupply();
        uint256 b0 = t0.balanceOf(bob);
        uint256 b1 = t1.balanceOf(bob);
        vm.expectRevert(err);
        vm.prank(bob);
        pool.addLiquidity(p);
        (uint256 e0, uint256 e1) = pool.getReserves();
        assertEq(e0, r0);
        assertEq(e1, r1);
        assertEq(pool.totalSupply(), s);
        assertEq(t0.balanceOf(bob), b0);
        assertEq(t1.balanceOf(bob), b1);
    }

    function test_L46_reportWorkedDeposit() public {
        (uint256 r0, uint256 r1) = pool.getReserves();
        assertEq(r0, 10_000);
        assertEq(r1, 20_000);
        assertEq(pool.totalSupply(), 14_142, "S = isqrt(10,000 * 20,000)");

        // Each bound one unit tighter: the deposit reverts and nothing changes.
        _expectUnchangedRevert(_params(1_999, 100, 1_272), AMMPool.PayerDebitTooHigh.selector);
        _expectUnchangedRevert(_params(2_000, 99, 1_272), AMMPool.ExcessContributionTooHigh.selector);
        _expectUnchangedRevert(_params(2_000, 100, 1_273), AMMPool.InsufficientShares.selector);

        uint256 w0 = t0.balanceOf(bob);
        uint256 w1 = t1.balanceOf(bob);
        uint256 supply1Before = t1.totalSupply();
        vm.prank(bob);
        (uint256 n0, uint256 n1, uint256 shares) = pool.addLiquidity(_params(2_000, 100, 1_272));

        assertEq(w0 - t0.balanceOf(bob), 1_000, "payer debit token0");
        assertEq(w1 - t1.balanceOf(bob), 2_000, "payer debit token1 (step-2 target, within cap 2,500)");
        assertEq(supply1Before - t1.totalSupply(), 200, "10 % tax burned, never reaches the Pool");
        assertEq(n0, 1_000, "Pool receipt token0");
        assertEq(n1, 1_800, "Pool receipt token1");
        assertEq(shares, 1_272, "sigma");
        (r0, r1) = pool.getReserves();
        assertEq(r0, 11_000, "reserve0 += net0 (excess 100 included)");
        assertEq(r1, 21_800, "reserve1 += net1 (excess 1 included)");
        assertEq(pool.totalSupply(), 15_414);

        // Immediate full redemption: floor(1,272 * r_i / 15,414).
        vm.prank(bob);
        (uint256 g0, uint256 g1) = pool.removeLiquidity(shares, 0, 0, bob, block.timestamp);
        assertEq(g0, 907);
        assertEq(g1, 1_798);
    }
}
