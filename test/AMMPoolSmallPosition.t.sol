// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {addParams} from "./utils/AddParams.sol";

/// @notice TEST_MATRIX W12 (M10 P2, review finding "small positions may never exit"): when
///         `r_i / S < 1`, a holder of fewer than `⌈S / r_i⌉` shares cannot redeem: the token-i
///         amount floors to 0 while `r_i > 0`, so `removeLiquidity` reverts
///         `InsufficientLiquidityBurned` (DECISIONS M4-3r; Uniswap V2 behaves alike with
///         `INSUFFICIENT_LIQUIDITY_BURNED`). The shares keep their book claim and can still be
///         transferred, so such a position can only be exited by first acquiring more shares.
///         Example with a 2-decimal and an 18-decimal token (Tier 0): alice deposits 100.00 and
///         100 tokens, i.e. (10,000, 1e20) units, so S = 1e12 and S / r2 = 1e8 shares per smallest
///         unit of the 2-decimal token. Expected values: integer Python model of the approved
///         formulas (not the Solidity code), reported with the M10 batch-4 report. The
///         scenario runs under both deployment orders, so the 2-decimal token is token0 once and
///         token1 once.
contract AMMPoolSmallPositionTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal surplus = makeAddr("surplusRecipient");

    MockERC20 internal two; // 2 decimals
    MockERC20 internal e18; // 18 decimals
    AMMPool internal pool;
    bool internal twoIsToken0;

    /// @dev Deployment order decides which token gets the lower address; the scenario is run
    ///      under both orders so that the 2-decimal token is token0 in one and token1 in the other.
    function _build(bool twoDeployedFirst) internal {
        if (twoDeployedFirst) {
            two = new MockERC20("TWO", "TWO", 2);
            e18 = new MockERC20("E18", "E18", 18);
        } else {
            e18 = new MockERC20("E18", "E18", 18);
            two = new MockERC20("TWO", "TWO", 2);
        }
        twoIsToken0 = address(two) < address(e18);
        pool = twoIsToken0
            ? new AMMPool(address(two), address(e18), surplus)
            : new AMMPool(address(e18), address(two), surplus);
        address[2] memory users = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            two.mint(users[i], 1e9);
            e18.mint(users[i], 1e24);
            vm.startPrank(users[i]);
            two.approve(address(pool), MAX);
            e18.approve(address(pool), MAX);
            vm.stopPrank();
        }
        _add(alice, 10_000, 1e20);
        assertEq(pool.totalSupply(), 1e12, "S = isqrt(1e4 * 1e20)");
    }

    function _add(address who, uint256 a2, uint256 a18) internal returns (uint256 shares) {
        (uint256 a0, uint256 a1) = twoIsToken0 ? (a2, a18) : (a18, a2);
        vm.prank(who);
        (,, shares) = pool.addLiquidity(addParams(a0, a1, 0, who, block.timestamp));
    }

    function _remove(address who, uint256 shares) internal returns (uint256 got2, uint256 got18) {
        vm.prank(who);
        (uint256 n0, uint256 n1) = pool.removeLiquidity(shares, 0, 0, who, block.timestamp);
        (got2, got18) = twoIsToken0 ? (n0, n1) : (n1, n0);
    }

    function test_W12_positionBelowThresholdCannotExit() public {
        _build(true);
        bool first = twoIsToken0;
        _scenario();
        _build(false);
        assertTrue(twoIsToken0 != first, "both token positions covered");
        _scenario();
    }

    function _scenario() internal {
        // bob deposits 2 units and 0.02 tokens: σ = 2e8.
        uint256 shares = _add(bob, 2, 2e16);
        assertEq(shares, 200_000_000);

        // A partial exit of 1.5e8 shares returns (1, 1.5e16) and leaves 5e7 shares.
        (uint256 g2, uint256 g18) = _remove(bob, 150_000_000);
        assertEq(g2, 1);
        assertEq(g18, 15_000_000_000_000_000);
        assertEq(pool.balanceOf(bob), 50_000_000);

        // Now S = 1,000,050,000,000 and r2 = 10,001: ⌈S / r2⌉ = 99,995,001 > 5e7, so the 2-decimal
        // amount floors to 0 while r2 > 0 → the whole exit reverts. The book claim of the 5e7
        // shares is 0.5 units of the 2-decimal token and 5e15 (0.005 token) of the 18-decimal one.
        vm.expectRevert(AMMPool.InsufficientLiquidityBurned.selector);
        vm.prank(bob);
        pool.removeLiquidity(50_000_000, 0, 0, bob, block.timestamp);
        assertEq(pool.balanceOf(bob), 50_000_000, "shares kept, state unchanged");

        // The position can exit once it reaches the threshold: alice transfers 49,995,001 shares.
        vm.prank(alice);
        pool.transfer(bob, 49_995_001);
        (g2, g18) = _remove(bob, 99_995_001);
        assertEq(g2, 1);
        assertEq(g18, 9_999_500_100_000_000);
    }
}
