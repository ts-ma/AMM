// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MockDeficitERC20} from "./mocks/MockDeficitERC20.sol";

/// @notice Self-tests for `MockDeficitERC20` (DECISIONS M6-5), so that Pool deficit tests
///         test the Pool, not a broken mock.
contract DeficitMockTest is Test {
    MockDeficitERC20 internal t;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        t = new MockDeficitERC20("Deficit", "DEF", 18);
        t.mint(alice, 1000);
    }

    function test_slashLowersBalanceAndSupply() public {
        t.slash(alice, 300);
        assertEq(t.balanceOf(alice), 700);
        assertEq(t.totalSupply(), 700);
    }

    function test_slashToZero() public {
        t.slash(alice, 1000);
        assertEq(t.balanceOf(alice), 0);
    }

    function test_slashAboveBalanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1000, 1001));
        t.slash(alice, 1001);
    }

    function test_transfersAreStandard() public {
        vm.prank(alice);
        t.transfer(bob, 100);
        assertEq(t.balanceOf(alice), 900);
        assertEq(t.balanceOf(bob), 100);
        vm.prank(alice);
        t.approve(address(this), 50);
        t.transferFrom(alice, bob, 50);
        assertEq(t.balanceOf(bob), 150);
        assertEq(t.allowance(alice, address(this)), 0);
    }
}
