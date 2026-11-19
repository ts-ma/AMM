// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {MockOverDebitERC20} from "./mocks/MockOverDebitERC20.sol";
import {MockFailingERC20} from "./mocks/MockFailingERC20.sol";

/// @notice Self-tests for the M4 outbound-failure mocks (DECISIONS M4-4), so that Pool tests
///         relying on them test the Pool, not a broken mock.
contract OutboundMocksTest is Test {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function test_overDebit_transferDebitsSenderValuePlusExtra() public {
        MockOverDebitERC20 t = new MockOverDebitERC20("Over", "OVR", 18);
        t.mint(alice, 1000);
        t.setExtra(7);
        vm.prank(alice);
        t.transfer(bob, 100);
        assertEq(t.balanceOf(bob), 100, "recipient credited exactly value");
        assertEq(t.balanceOf(alice), 1000 - 100 - 7, "sender over-debited by extra");
        assertEq(t.totalSupply(), 1000 - 7);
    }

    function test_overDebit_zeroExtraIsStandard() public {
        MockOverDebitERC20 t = new MockOverDebitERC20("Over", "OVR", 18);
        t.mint(alice, 1000);
        vm.prank(alice);
        t.transfer(bob, 100);
        assertEq(t.balanceOf(alice), 900);
        assertEq(t.balanceOf(bob), 100);
    }

    function test_overDebit_transferFromIsStandard() public {
        MockOverDebitERC20 t = new MockOverDebitERC20("Over", "OVR", 18);
        t.mint(alice, 1000);
        t.setExtra(7);
        vm.prank(alice);
        t.approve(address(this), 100);
        t.transferFrom(alice, bob, 100);
        assertEq(t.balanceOf(alice), 900);
        assertEq(t.balanceOf(bob), 100);
    }

    function test_failing_revertTransfer() public {
        MockFailingERC20 t = new MockFailingERC20("Fail", "FAIL", 18);
        t.mint(alice, 1000);
        t.setMode(MockFailingERC20.Mode.RevertTransfer);
        vm.prank(alice);
        vm.expectRevert(MockFailingERC20.MockFailure.selector);
        t.transfer(bob, 1);
    }

    function test_failing_returnFalseTransfer() public {
        MockFailingERC20 t = new MockFailingERC20("Fail", "FAIL", 18);
        t.mint(alice, 1000);
        t.setMode(MockFailingERC20.Mode.ReturnFalseTransfer);
        vm.prank(alice);
        assertFalse(t.transfer(bob, 1));
        assertEq(t.balanceOf(alice), 1000, "no movement on false");
    }

    function test_failing_outboundModesDoNotAffectTransferFrom() public {
        MockFailingERC20 t = new MockFailingERC20("Fail", "FAIL", 18);
        t.mint(alice, 1000);
        vm.prank(alice);
        t.approve(address(this), 10);
        t.setMode(MockFailingERC20.Mode.RevertTransfer);
        assertTrue(t.transferFrom(alice, bob, 10));
        assertEq(t.balanceOf(bob), 10);
    }
}
