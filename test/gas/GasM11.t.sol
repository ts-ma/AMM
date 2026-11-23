// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AMMPool} from "../../src/AMMPool.sol";
import {IAMMPool} from "../../src/interfaces/IAMMPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFeeERC20} from "../mocks/MockFeeERC20.sol";
import {addParams, addParamsOrdered} from "../utils/AddParams.sol";

/// M11 architecture gas review (experiment only). Same method as GasG02: one call per test,
/// arguments and references copied to locals before the first gasleft(), isolate = true (cold).
/// Pools seeded by alice with (1000e18, 2000e18); alice is payer and recipient.
contract GasM11 is Test {
    MockERC20 internal t0;
    MockERC20 internal t1;
    AMMPool internal pool;
    MockFeeERC20 internal f0;
    MockFeeERC20 internal f1;
    AMMPool internal taxPool; // token1 10 % inclusive tax on pulls (L46-style)
    address internal alice = makeAddr("alice");

    function _fund(address a, address b, address p) internal {
        MockERC20(a).mint(alice, 1e30);
        MockERC20(b).mint(alice, 1e30);
        vm.startPrank(alice);
        MockERC20(a).approve(p, type(uint256).max);
        MockERC20(b).approve(p, type(uint256).max);
        vm.stopPrank();
    }

    function setUp() public {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        pool = new AMMPool(address(t0), address(t1), makeAddr("surplus"));
        _fund(address(t0), address(t1), address(pool));
        vm.prank(alice);
        pool.addLiquidity(addParams(1000e18, 2000e18, 0, alice, block.timestamp));

        MockFeeERC20 c = new MockFeeERC20("F", "F", 18);
        MockFeeERC20 d = new MockFeeERC20("G", "G", 18);
        (f0, f1) = address(c) < address(d) ? (c, d) : (d, c);
        taxPool = new AMMPool(address(f0), address(f1), makeAddr("surplus"));
        _fund(address(f0), address(f1), address(taxPool));
        vm.prank(alice);
        taxPool.addLiquidity(addParams(1000e18, 2000e18, 0, alice, block.timestamp));
        f1.setTax(MockFeeERC20.Path.TransferFrom, 1000);
    }

    function _m(AMMPool pl, IAMMPool.AddLiquidityParams memory p, string memory label) internal {
        vm.prank(alice);
        uint256 g = gasleft();
        pl.addLiquidity(p);
        emit log_named_uint(label, g - gasleft());
    }

    function test_g_t0_unboundedDebit() public {
        _m(pool, addParams(1e18, 1e19, 0, alice, block.timestamp), "GAS T0 later, maxDebit MAX");
    }

    function test_g_t0_finiteDebit() public {
        IAMMPool.AddLiquidityParams memory p = addParams(1e18, 1e19, 0, alice, block.timestamp);
        (p.maxDebit0, p.maxDebit1) = (1e18, 2e18);
        _m(pool, p, "GAS T0 later, maxDebit finite");
    }

    function test_g_tax_second_unboundedDebit() public {
        _m(taxPool, addParams(1e18, 1e19, 0, alice, block.timestamp), "GAS TAX later, taxed token second, maxDebit MAX");
    }

    function test_g_tax_second_finiteDebit() public {
        IAMMPool.AddLiquidityParams memory p = addParams(1e18, 1e19, 0, alice, block.timestamp);
        (p.maxDebit0, p.maxDebit1) = (1e18, 2e18);
        _m(taxPool, p, "GAS TAX later, taxed token second, maxDebit finite");
    }

    function test_g_tax_first_replan_unboundedDebit() public {
        _m(taxPool, addParamsOrdered(1e18, 1e19, 0, alice, block.timestamp, true), "GAS TAX later, taxed token first (re-plan), maxDebit MAX");
    }

    // ---- Mixed maxDebit settings (same ordinary-token deposit: token0 first, token0 cap binds,
    //      targets and actual debits (1e18, 2e18)). One bound is finite, the other unbounded.

    function _mixed(uint256 d0, uint256 d1) internal view returns (IAMMPool.AddLiquidityParams memory p) {
        p = addParams(1e18, 1e19, 0, alice, block.timestamp);
        (p.maxDebit0, p.maxDebit1) = (d0, d1);
    }

    function test_g_t0_mixed_max0_finite1() public {
        _m(pool, _mixed(type(uint256).max, 2e18), "GAS T0 later, maxDebit (MAX, finite)");
    }

    function test_g_t0_mixed_finite0_max1() public {
        _m(pool, _mixed(1e18, type(uint256).max), "GAS T0 later, maxDebit (finite, MAX)");
    }

    /// The finite side still binds: equal to the actual debit succeeds, one unit tighter reverts.
    function _checkFiniteSideBinds(bool finite0) internal {
        uint256 b0 = t0.balanceOf(alice);
        uint256 b1 = t1.balanceOf(alice);
        uint256 s = pool.totalSupply();
        IAMMPool.AddLiquidityParams memory tight =
            finite0 ? _mixed(1e18 - 1, type(uint256).max) : _mixed(type(uint256).max, 2e18 - 1);
        vm.expectRevert(AMMPool.PayerDebitTooHigh.selector);
        vm.prank(alice);
        pool.addLiquidity(tight);
        assertEq(t0.balanceOf(alice), b0);
        assertEq(t1.balanceOf(alice), b1);
        assertEq(pool.totalSupply(), s);

        IAMMPool.AddLiquidityParams memory exact =
            finite0 ? _mixed(1e18, type(uint256).max) : _mixed(type(uint256).max, 2e18);
        vm.prank(alice);
        pool.addLiquidity(exact);
        assertEq(b0 - t0.balanceOf(alice), 1e18, "debit token0");
        assertEq(b1 - t1.balanceOf(alice), 2e18, "debit token1");
    }

    function test_mixed_finiteToken0StillBinds() public {
        _checkFiniteSideBinds(true);
    }

    function test_mixed_finiteToken1StillBinds() public {
        _checkFiniteSideBinds(false);
    }

    function test_g_swap_t0() public {
        AMMPool pl = pool;
        address tin = address(t0);
        address a = alice;
        vm.prank(a);
        uint256 g = gasleft();
        pl.swapExactInput(tin, 1e18, 0, a, block.timestamp);
        emit log_named_uint("GAS T0 swap", g - gasleft());
    }

    function test_g_remove_t0() public {
        AMMPool pl = pool;
        address a = alice;
        vm.prank(a);
        uint256 g = gasleft();
        pl.removeLiquidity(1e18, 0, 0, a, block.timestamp);
        emit log_named_uint("GAS T0 remove", g - gasleft());
    }
}
