// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {IAMMPool} from "../src/interfaces/IAMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {addParams} from "./utils/AddParams.sol";

/// @notice M10 item 3 (TEST_MATRIX L45): the first-deposit branch changes under a front-run.
///         `addLiquidity` chooses its path from `totalSupply()` at execution; the caller cannot
///         ask for "initial only". bob prepares an initial deposit with caps (A, B) =
///         (1e21, 4e21), i.e. a price of 4 token1 per token0, and expects
///         `isqrt(A·B) − 1000 = 1,999,999,999,999,999,999,000` shares. eve deposits first, so bob's
///         call takes the later path at eve's ratio:
///         - same ratio: bob's caps are pulled in full and σ = 2e21 ≥ the expectation;
///         - a clearly different ratio (tested: 1:1 and a relative skew of 3e-6): σ falls below
///           the expectation, so `minShares` = expectation reverts `InsufficientShares` with no
///           state change; with `minShares = 0` the call succeeds at eve's price (bob deposits
///           a different ratio than intended);
///         - a slightly different ratio (relative skew 2.5e-19): σ still meets the expectation,
///           because on the later path bob pays no lock (the 1000 shares absorb a shortfall), so
///           the initial-path `minShares` does not detect every front-run;
///         - the excess fields, which have no effect on an initial deposit (M8-13 (c)), become
///           active on the later path: `maxExcess = 0` can then revert
///           `ExcessContributionTooHigh`.
///         Expected values: integer Python model of step 2, σ and u (not the Solidity code),
///         reported with the M10 batch-3 report. Tier 0 tokens.
contract AMMPoolFirstDepositBranchTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant A = 1e21;
    uint256 internal constant B = 4e21;
    uint256 internal constant EXPECTED = 1_999_999_999_999_999_999_000; // isqrt(A·B) − 1000

    address internal bob = makeAddr("bob"); // intended first depositor
    address internal eve = makeAddr("eve"); // front-runner
    address internal surplus = makeAddr("surplusRecipient");

    MockERC20 internal t0;
    MockERC20 internal t1;
    AMMPool internal pool;

    function setUp() public {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        pool = new AMMPool(address(t0), address(t1), surplus);
        address[2] memory users = [bob, eve];
        for (uint256 i; i < 2; ++i) {
            t0.mint(users[i], 1e24);
            t1.mint(users[i], 1e24);
            vm.startPrank(users[i]);
            t0.approve(address(pool), MAX);
            t1.approve(address(pool), MAX);
            vm.stopPrank();
        }
    }

    function _bobParams(uint256 minShares, uint256 maxExcess)
        internal
        view
        returns (IAMMPool.AddLiquidityParams memory)
    {
        return IAMMPool.AddLiquidityParams({
            amount0RequestMax: A,
            amount1RequestMax: B,
            maxDebit0: MAX,
            maxDebit1: MAX,
            maxExcess0: maxExcess,
            maxExcess1: maxExcess,
            minShares: minShares,
            recipient: bob,
            deadline: block.timestamp,
            token1First: false
        });
    }

    function _frontRun(uint256 x0, uint256 x1) internal {
        vm.prank(eve);
        pool.addLiquidity(addParams(x0, x1, 0, eve, block.timestamp));
    }

    function _expectBobReverts(IAMMPool.AddLiquidityParams memory p, bytes4 err) internal {
        (uint256 r0, uint256 r1) = pool.getReserves();
        uint256 supply = pool.totalSupply();
        uint256 b0 = t0.balanceOf(bob);
        uint256 b1 = t1.balanceOf(bob);
        vm.expectRevert(err);
        vm.prank(bob);
        pool.addLiquidity(p);
        (uint256 e0, uint256 e1) = pool.getReserves();
        assertEq(e0, r0, "reserve0 unchanged");
        assertEq(e1, r1, "reserve1 unchanged");
        assertEq(pool.totalSupply(), supply, "supply unchanged");
        assertEq(t0.balanceOf(bob), b0, "bob token0 unchanged");
        assertEq(t1.balanceOf(bob), b1, "bob token1 unchanged");
    }

    /// @dev Without a front-run bob's call is the initial deposit and meets its expectation.
    function test_L45_noFrontRunInitialPath() public {
        vm.prank(bob);
        (,, uint256 shares) = pool.addLiquidity(_bobParams(EXPECTED, 0));
        assertEq(shares, EXPECTED);
        assertEq(pool.balanceOf(address(pool)), 1000, "lock minted on the initial path");
    }

    /// @dev eve front-runs at bob's ratio (1e6, 4e6): later path, caps pulled in full, σ = 2e21.
    function test_L45_sameRatioFrontRunMeetsExpectation() public {
        _frontRun(1e6, 4e6);
        vm.prank(bob);
        (uint256 n0, uint256 n1, uint256 shares) = pool.addLiquidity(_bobParams(EXPECTED, 0));
        assertEq(n0, A);
        assertEq(n1, B);
        assertEq(shares, 2e21, "later path: no lock deduction for bob");
    }

    /// @dev eve front-runs at 1:1 (1e6, 1e6): σ would be 1e21. `minShares = EXPECTED` reverts;
    ///      `minShares = 0` succeeds at eve's ratio and pulls only (1e21, 1e21).
    function test_L45_skewedFrontRunRejectedByMinShares() public {
        _frontRun(1e6, 1e6);
        _expectBobReverts(_bobParams(EXPECTED, MAX), AMMPool.InsufficientShares.selector);

        vm.prank(bob);
        (uint256 n0, uint256 n1, uint256 shares) = pool.addLiquidity(_bobParams(0, MAX));
        assertEq(n0, 1e21);
        assertEq(n1, 1e21, "bob deposited at eve's 1:1 ratio, not the intended 1:4");
        assertEq(shares, 1e21);
    }

    /// @dev eve front-runs with a relative skew of 3e-6 (1,000,003, 4,000,000; S = 2,000,002):
    ///      σ = 1,999,996,000,011,999,963,999 < EXPECTED → `InsufficientShares`; with
    ///      `minShares = 0` but `maxExcess = 0` → u1 = 1 → `ExcessContributionTooHigh` (the
    ///      excess fields are active on the later path); with both loose it succeeds.
    function test_L45_slightSkewMinSharesAndExcessFieldsBecomeActive() public {
        _frontRun(1_000_003, 4_000_000);
        assertEq(pool.totalSupply(), 2_000_002);
        _expectBobReverts(_bobParams(EXPECTED, MAX), AMMPool.InsufficientShares.selector);
        _expectBobReverts(_bobParams(0, 0), AMMPool.ExcessContributionTooHigh.selector);

        vm.prank(bob);
        (uint256 n0, uint256 n1, uint256 shares) = pool.addLiquidity(_bobParams(0, MAX));
        assertEq(n0, 1e21);
        assertEq(n1, 3_999_988_000_035_999_892_000);
        assertEq(shares, 1_999_996_000_011_999_963_999);
    }

    /// @dev Regression (M10): a front-run at a slightly different ratio still passes bob's
    ///      original initial-deposit `minShares`. eve deposits (1e18, 4e18 + 1), relative skew
    ///      2.5e-19, S = 2e18. On the later path bob pays no lock, so σ = 1,999,999,999,999,999,999,500
    ///      ≥ EXPECTED (by 500) and the call succeeds even with `maxExcess = 0` (u = (0, 0)).
    ///      bob deposits at eve's ratio (n0 = 999,999,999,999,999,999,750 < A), not his own: the
    ///      initial-path `minShares` does not detect this front-run. Values: integer Python model.
    function test_L45_slightSkewStillPassesInitialMinShares() public {
        _frontRun(1e18, 4e18 + 1);
        assertEq(pool.totalSupply(), 2e18);
        vm.prank(bob);
        (uint256 n0, uint256 n1, uint256 shares) = pool.addLiquidity(_bobParams(EXPECTED, 0));
        assertEq(n0, 999_999_999_999_999_999_750, "bob deposits at eve's ratio");
        assertEq(n1, B);
        assertEq(shares, 1_999_999_999_999_999_999_500);
        assertGe(shares, EXPECTED, "initial-path minShares passes");
        assertEq(pool.balanceOf(address(pool)), 1000, "the lock was minted for eve's deposit, not bob's");
    }
}
