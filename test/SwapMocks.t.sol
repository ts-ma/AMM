// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";
import {MockNoReturnERC20} from "./mocks/MockNoReturnERC20.sol";

/// @dev Callback target for the mock self-tests.
contract CallbackProbe {
    error Boom();

    uint256 public pings;

    function ping() external returns (uint256) {
        return ++pings;
    }

    function boom() external pure {
        revert Boom();
    }
}

/// @notice Self-tests for the M5 mocks (DECISIONS M5-6, M5-7), so that Pool tests relying on
///         them test the Pool, not a broken mock.
contract SwapMocksTest is Test {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    ReentrantERC20 internal r;
    CallbackProbe internal probe;

    function setUp() public {
        r = new ReentrantERC20("Re", "RE", 18);
        probe = new CallbackProbe();
        r.mint(alice, 1000);
        vm.prank(alice);
        r.approve(address(this), type(uint256).max);
    }

    // --- ReentrantERC20 -------------------------------------------------------------

    function test_reentrant_armKeepsM3Behaviour_transferFromBubbles() public {
        r.arm(address(probe), abi.encodeCall(CallbackProbe.boom, ()));
        vm.expectRevert(CallbackProbe.Boom.selector);
        r.transferFrom(alice, bob, 100);
    }

    function test_reentrant_transferHookRunsOnlyOnTransfer() public {
        r.armWith(address(probe), abi.encodeCall(CallbackProbe.ping, ()), ReentrantERC20.Hook.Transfer, false);
        r.transferFrom(alice, bob, 100); // wrong hook point: no callback
        assertFalse(r.callbackRan());
        assertTrue(r.armed());

        vm.prank(alice);
        r.transfer(bob, 100);
        assertTrue(r.callbackRan());
        assertFalse(r.armed(), "one-shot");
        assertEq(probe.pings(), 1);
        assertTrue(r.lastCallOk());
        assertEq(abi.decode(r.lastReturnData(), (uint256)), 1, "return data recorded");
        assertEq(r.balanceOf(bob), 200);
    }

    function test_reentrant_transferHookBubbles() public {
        r.armWith(address(probe), abi.encodeCall(CallbackProbe.boom, ()), ReentrantERC20.Hook.Transfer, false);
        vm.prank(alice);
        vm.expectRevert(CallbackProbe.Boom.selector);
        r.transfer(bob, 100);
    }

    function test_reentrant_caughtRevertContinuesTransfer() public {
        r.armWith(address(probe), abi.encodeCall(CallbackProbe.boom, ()), ReentrantERC20.Hook.TransferFrom, true);
        assertTrue(r.transferFrom(alice, bob, 100));
        assertTrue(r.callbackRan());
        assertFalse(r.lastCallOk());
        assertEq(r.lastReturnData(), abi.encodeWithSelector(CallbackProbe.Boom.selector), "caught error recorded");
        assertEq(r.balanceOf(alice), 900);
        assertEq(r.balanceOf(bob), 100);
    }

    function test_reentrant_extraDebitOverDebitsSender() public {
        r.setFaults(7, 0);
        vm.prank(alice);
        r.transfer(bob, 100);
        assertEq(r.balanceOf(alice), 1000 - 100 - 7);
        assertEq(r.balanceOf(bob), 100);
    }

    function test_reentrant_withholdShortsReceiver() public {
        r.setFaults(0, 3);
        r.transferFrom(alice, bob, 100);
        assertEq(r.balanceOf(alice), 900, "sender debited exactly value");
        assertEq(r.balanceOf(bob), 97, "receiver short by withhold");
    }

    // --- MockNoReturnERC20 ----------------------------------------------------------

    function test_noReturn_transferAndTransferFromReturnNoData() public {
        MockNoReturnERC20 t = new MockNoReturnERC20("NoRet", "NR", 6);
        t.mint(alice, 1000);

        vm.prank(alice);
        (bool ok, bytes memory ret) = address(t).call(abi.encodeWithSignature("transfer(address,uint256)", bob, 100));
        assertTrue(ok);
        assertEq(ret.length, 0, "transfer returns no data");

        vm.prank(alice);
        t.approve(address(this), 50);
        (ok, ret) = address(t).call(abi.encodeWithSignature("transferFrom(address,address,uint256)", alice, bob, 50));
        assertTrue(ok);
        assertEq(ret.length, 0, "transferFrom returns no data");

        assertEq(t.balanceOf(alice), 850);
        assertEq(t.balanceOf(bob), 150);
        assertEq(t.allowance(alice, address(this)), 0);
        assertEq(t.totalSupply(), 1000);
        assertEq(t.decimals(), 6);
    }

    function test_noReturn_failuresRevertExactly() public {
        MockNoReturnERC20 t = new MockNoReturnERC20("NoRet", "NR", 18);
        t.mint(alice, 10);
        vm.prank(alice);
        vm.expectRevert(MockNoReturnERC20.InsufficientBalance.selector);
        t.transfer(bob, 11);

        vm.expectRevert(MockNoReturnERC20.InsufficientAllowance.selector);
        t.transferFrom(alice, bob, 1);
    }
}
