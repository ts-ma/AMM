// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AMMPool} from "../../src/AMMPool.sol";
import {AMMFactory} from "../../src/AMMFactory.sol";
import {IAMMPool} from "../../src/interfaces/IAMMPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockDeficitERC20} from "../mocks/MockDeficitERC20.sol";
import {addParams, addParamsOrdered} from "../utils/AddParams.sol";

/// @notice TEST_MATRIX G02 (M10): gas of every public function of the final code, one scenario
///         each. Measurement only: the tests log values and assert nothing about gas.
///         Run: `forge test --match-contract GasG02 -vv` (configuration: TEST_MATRIX §14).
///         Method (as G03 / G05, TEST_MATRIX §14.5): one external call per test, `gasleft()`
///         immediately before and after it. All arguments and contract references (the params
///         struct, token, Pool and account addresses held in test storage) are copied to locals
///         before the first `gasleft()`, so no test-contract SLOAD is inside the interval;
///         the ABI encoding of the call is inside the interval, the 21,000 intrinsic
///         transaction cost and calldata cost are not. (G05's harness read the Pool address
///         from a parameter but token addresses from storage, so its values are not
///         identical; see TEST_MATRIX §14.6.) Each
///         measured call is a top-level call of the test under `isolate = true`, so the storage
///         and accounts it touches are cold. Tier 0 `MockERC20` (18 decimals) unless stated.
///         State: Pool seeded in `setUp` by alice with (1000e18, 2000e18); alice is payer and
///         recipient, with non-zero token and LP balances and approvals of `type(uint256).max`.
///         Values are single-scenario measurements, not averages; other states (new recipient,
///         zero balances, taxed tokens) cost differently (§14.5 P4, P6–P8).
contract GasG02 is Test {
    MockERC20 internal t0;
    MockERC20 internal t1;
    AMMPool internal pool; // seeded
    AMMPool internal fresh; // empty
    MockDeficitERC20 internal d0;
    MockDeficitERC20 internal d1;
    AMMPool internal deficitPool; // seeded, token0 slashed by 1e18 before the measured `sync`
    AMMFactory internal factory;
    MockERC20 internal t2;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal surplus = makeAddr("surplus");

    function _fund(address a, address b, address p) internal {
        address[2] memory u = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            MockERC20(a).mint(u[i], 1e30);
            MockERC20(b).mint(u[i], 1e30);
            vm.startPrank(u[i]);
            MockERC20(a).approve(p, type(uint256).max);
            MockERC20(b).approve(p, type(uint256).max);
            vm.stopPrank();
        }
    }

    function setUp() public {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        pool = new AMMPool(address(t0), address(t1), surplus);
        fresh = new AMMPool(address(t0), address(t1), surplus);
        _fund(address(t0), address(t1), address(pool));
        vm.startPrank(alice);
        t0.approve(address(fresh), type(uint256).max);
        t1.approve(address(fresh), type(uint256).max);
        pool.addLiquidity(addParams(1000e18, 2000e18, 0, alice, block.timestamp));
        pool.approve(bob, type(uint256).max);
        vm.stopPrank();

        MockDeficitERC20 c = new MockDeficitERC20("C", "C", 18);
        MockDeficitERC20 d = new MockDeficitERC20("D", "D", 18);
        (d0, d1) = address(c) < address(d) ? (c, d) : (d, c);
        deficitPool = new AMMPool(address(d0), address(d1), surplus);
        _fund(address(d0), address(d1), address(deficitPool));
        vm.prank(alice);
        deficitPool.addLiquidity(addParams(1000e18, 2000e18, 0, alice, block.timestamp));
        d0.slash(address(deficitPool), 1e18);

        factory = new AMMFactory(surplus);
        t2 = new MockERC20("E", "E", 18);
    }

    // ---------------- addLiquidity ----------------

    function test_gas_add_initial() public {
        AMMPool pl = fresh;
        IAMMPool.AddLiquidityParams memory p = addParams(1000e18, 2000e18, 0, alice, block.timestamp);
        vm.prank(alice);
        uint256 g = gasleft();
        pl.addLiquidity(p);
        emit log_named_uint("GAS addLiquidity initial", g - gasleft());
    }

    function test_gas_add_later_token0Binds() public {
        AMMPool pl = pool;
        IAMMPool.AddLiquidityParams memory p = addParams(1e18, 1e19, 0, alice, block.timestamp);
        vm.prank(alice);
        uint256 g = gasleft();
        pl.addLiquidity(p);
        emit log_named_uint("GAS addLiquidity later token0 cap binds (G05 P1 conditions)", g - gasleft());
    }

    function test_gas_add_later_token1Binds_token1First() public {
        AMMPool pl = pool;
        IAMMPool.AddLiquidityParams memory p = addParamsOrdered(1e19, 2e18, 0, alice, block.timestamp, true);
        vm.prank(alice);
        uint256 g = gasleft();
        pl.addLiquidity(p);
        emit log_named_uint("GAS addLiquidity later token1 cap binds, token1First", g - gasleft());
    }

    // ---------------- removeLiquidity ----------------

    function test_gas_remove_partial() public {
        AMMPool pl = pool;
        address a_ = alice;
        vm.prank(alice);
        uint256 g = gasleft();
        pl.removeLiquidity(1e18, 0, 0, a_, block.timestamp);
        emit log_named_uint("GAS removeLiquidity partial", g - gasleft());
    }

    function test_gas_remove_all() public {
        AMMPool pl = pool;
        address a_ = alice;
        uint256 shares = pool.balanceOf(alice);
        vm.prank(alice);
        uint256 g = gasleft();
        pl.removeLiquidity(shares, 0, 0, a_, block.timestamp);
        emit log_named_uint("GAS removeLiquidity full exit (LP balance -> 0)", g - gasleft());
    }

    // ---------------- swapExactInput / getAmountOut ----------------

    function test_gas_swap_token0In() public {
        AMMPool pl = pool;
        address a_ = alice;
        address tin = address(t0);
        vm.prank(alice);
        uint256 g = gasleft();
        pl.swapExactInput(tin, 1e18, 0, a_, block.timestamp);
        emit log_named_uint("GAS swapExactInput token0 in", g - gasleft());
    }

    function test_gas_swap_token1In() public {
        AMMPool pl = pool;
        address a_ = alice;
        address tin = address(t1);
        vm.prank(alice);
        uint256 g = gasleft();
        pl.swapExactInput(tin, 1e18, 0, a_, block.timestamp);
        emit log_named_uint("GAS swapExactInput token1 in", g - gasleft());
    }

    function test_gas_getAmountOut() public {
        AMMPool pl = pool;
        address tin = address(t0);
        uint256 g = gasleft();
        pl.getAmountOut(tin, 1e18);
        emit log_named_uint("GAS getAmountOut", g - gasleft());
    }

    function test_gas_getReserves() public {
        AMMPool pl = pool;
        uint256 g = gasleft();
        pl.getReserves();
        emit log_named_uint("GAS getReserves", g - gasleft());
    }

    // ---------------- sync / skim ----------------

    function test_gas_sync_noDeficit() public {
        AMMPool pl = pool;
        uint256 g = gasleft();
        pl.sync();
        emit log_named_uint("GAS sync no deficit (no-op)", g - gasleft());
    }

    function test_gas_sync_deficitToken0() public {
        AMMPool pl = deficitPool;
        uint256 g = gasleft();
        pl.sync();
        emit log_named_uint("GAS sync token0 deficit (MockDeficitERC20)", g - gasleft());
    }

    function test_gas_skim_bothTokens() public {
        AMMPool pl = pool;
        t0.mint(address(pool), 1e18); // separate top-level call: state stays cold for `skim`
        t1.mint(address(pool), 1e18);
        uint256 g = gasleft();
        pl.skim();
        emit log_named_uint("GAS skim surplus in both tokens", g - gasleft());
    }

    function test_gas_skim_noSurplus() public {
        AMMPool pl = fresh;
        uint256 g = gasleft();
        pl.skim();
        emit log_named_uint("GAS skim no surplus (no-op)", g - gasleft());
    }

    // ---------------- LP ERC-20 ----------------

    function test_gas_lp_transfer() public {
        AMMPool pl = pool;
        address b_ = bob;
        vm.prank(alice);
        uint256 g = gasleft();
        pl.transfer(b_, 1e18);
        emit log_named_uint("GAS LP transfer (recipient balance 0 -> non-zero)", g - gasleft());
    }

    function test_gas_lp_approve() public {
        AMMPool pl = pool;
        address a_ = alice;
        vm.prank(bob);
        uint256 g = gasleft();
        pl.approve(a_, 1e18);
        emit log_named_uint("GAS LP approve (0 -> non-zero)", g - gasleft());
    }

    function test_gas_lp_transferFrom_infiniteAllowance() public {
        AMMPool pl = pool;
        address a_ = alice;
        address b_ = bob;
        vm.prank(bob);
        uint256 g = gasleft();
        pl.transferFrom(a_, b_, 1e18);
        emit log_named_uint("GAS LP transferFrom (allowance MAX, not decreased)", g - gasleft());
    }

    // ---------------- Factory and deployments ----------------

    function test_gas_createPair() public {
        AMMFactory fc = factory;
        address a = address(t0);
        address b = address(t2);
        uint256 g = gasleft();
        fc.createPair(a, b);
        emit log_named_uint("GAS createPair", g - gasleft());
    }

    function test_gas_deploy_pool() public {
        address a = address(t0);
        address b = address(t1);
        address s = makeAddr("surplus2");
        uint256 g = gasleft();
        new AMMPool(a, b, s);
        emit log_named_uint("GAS deploy AMMPool", g - gasleft());
    }

    function test_gas_deploy_factory() public {
        address s = makeAddr("surplus2");
        uint256 g = gasleft();
        new AMMFactory(s);
        emit log_named_uint("GAS deploy AMMFactory", g - gasleft());
    }

    function test_gas_calibration_balanceOf() public {
        MockERC20 tk = t0;
        address a_ = alice;
        uint256 g = gasleft();
        tk.balanceOf(a_);
        emit log_named_uint("GAS calibration balanceOf", g - gasleft());
    }
}
