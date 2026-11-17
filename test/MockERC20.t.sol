// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice TEST_MATRIX §1 (T01–T05): the Tier 0 mock behaves as a standard ERC-20,
///         so later AMM tests can trust it as a baseline.
contract MockERC20Test is Test {
    MockERC20 internal token18;
    MockERC20 internal token6;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal spender = makeAddr("spender");

    function setUp() public {
        token18 = new MockERC20("Mock 18", "M18", 18);
        token6 = new MockERC20("Mock 6", "M6", 6);
    }

    // T01: decimals() returns the configured value for each mock.
    function test_T01_decimals() public view {
        assertEq(token18.decimals(), 18);
        assertEq(token6.decimals(), 6);
    }

    // T02: mint increases both the recipient balance and totalSupply.
    function test_T02_mintUpdatesBalanceAndSupply() public {
        token18.mint(alice, 100e18);
        token18.mint(bob, 5e18);
        assertEq(token18.balanceOf(alice), 100e18);
        assertEq(token18.balanceOf(bob), 5e18);
        assertEq(token18.totalSupply(), 105e18);
    }

    function testFuzz_T02_mint(address to, uint256 amount) public {
        vm.assume(to != address(0)); // OZ rejects mint to address(0) by design.
        token6.mint(to, amount);
        assertEq(token6.balanceOf(to), amount);
        assertEq(token6.totalSupply(), amount);
    }

    // T03: transfer moves exactly `amount` (Tier 0: debit == credit).
    function test_T03_transfer() public {
        token6.mint(alice, 1_000e6);
        vm.prank(alice);
        assertTrue(token6.transfer(bob, 400e6));
        assertEq(token6.balanceOf(alice), 600e6);
        assertEq(token6.balanceOf(bob), 400e6);
        assertEq(token6.totalSupply(), 1_000e6);
    }

    // T03: transfer above balance reverts with OZ's custom error and changes nothing.
    function test_T03_transferRevertsOnInsufficientBalance() public {
        token6.mint(alice, 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 100, 101));
        vm.prank(alice);
        token6.transfer(bob, 101);
        assertEq(token6.balanceOf(alice), 100);
        assertEq(token6.balanceOf(bob), 0);
    }

    // T04: approve + transferFrom succeed and reduce the allowance exactly.
    function test_T04_approveAndTransferFrom() public {
        token18.mint(alice, 10e18);
        vm.prank(alice);
        assertTrue(token18.approve(spender, 4e18));
        assertEq(token18.allowance(alice, spender), 4e18);

        vm.prank(spender);
        assertTrue(token18.transferFrom(alice, bob, 3e18));
        assertEq(token18.balanceOf(alice), 7e18);
        assertEq(token18.balanceOf(bob), 3e18);
        assertEq(token18.allowance(alice, spender), 1e18);
    }

    // T05: transferFrom above allowance reverts (even with sufficient balance).
    function test_T05_transferFromRevertsOnInsufficientAllowance() public {
        token18.mint(alice, 10e18);
        vm.prank(alice);
        token18.approve(spender, 1e18);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 1e18, 1e18 + 1)
        );
        vm.prank(spender);
        token18.transferFrom(alice, bob, 1e18 + 1);
        assertEq(token18.balanceOf(alice), 10e18);
        assertEq(token18.allowance(alice, spender), 1e18);
    }
}
