// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AMMPool} from "../../src/AMMPool.sol";
import {AMMFactory} from "../../src/AMMFactory.sol";
import {IAMMPool} from "../../src/interfaces/IAMMPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFeeERC20} from "../mocks/MockFeeERC20.sol";
import {addParams} from "../utils/AddParams.sol";

/// @notice Measures `getPair` twice inside one call (one transaction): the second lookup sees the
///         Factory account and the slot(s) read by the first lookup as warm.
contract M11PairLookupProbe {
    function twice(AMMFactory f, address x1, address y1, address x2, address y2)
        external
        view
        returns (uint256 first, uint256 second)
    {
        uint256 g = gasleft();
        f.getPair(x1, y1);
        first = g - gasleft();
        g = gasleft();
        f.getPair(x2, y2);
        second = g - gasleft();
    }
}

/// @notice M11 combined comparison (TEST_MATRIX §14.11; DECISIONS M11-4). The same file runs
///         unchanged on 04eb336 and on the final code: it uses only the public ABI shared by both.
///         Measurement only: the tests log values and assert nothing about gas.
///         Run: `forge test --match-contract GasM11Combined -vv`.
///         Method as G02 (TEST_MATRIX §14.6): every argument and contract reference is a local
///         before the first `gasleft()`; one top-level call per test under `isolate = true`, so
///         the measured call sees cold accounts and storage; the ABI encoding is inside the
///         interval, the 21,000 intrinsic and calldata costs are not. Warm `getPair` lookups are
///         measured inside `M11PairLookupProbe` (one transaction).
///         Fixtures:
///           ORD  `MockERC20` pair, Pool seeded by alice with (1000e18, 2000e18); later deposit by
///                alice with caps (1e18, 2e18), maxDebit (1e18, 2e18) = the exact debits,
///                maxExcess MAX, minShares 0; token0 first or token1 first.
///           L46  report §5.2: `MockFeeERC20` pair, reserves (10,000, 20,000), token1 taxed 10 %
///                on `transferFrom`; bob, caps (1,000, 2,500), minShares 1,272. Taxed second:
///                maxDebit (1,000, 2,000), maxExcess (100, 1). Taxed first (re-plan to 900):
///                maxDebit (900, 2,000), maxExcess (0, 1).
///           INIT empty ORD-token Pool; initial deposit (1000e18, 2000e18), token0 first.
///           Factory `seeded` holds pair (a, b); `factory` is empty.
contract GasM11Combined is Test {
    uint256 internal constant MAX = type(uint256).max;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal surplus = makeAddr("surplusRecipient");

    MockERC20 internal o0;
    MockERC20 internal o1;
    AMMPool internal ord;
    AMMPool internal fresh;
    MockFeeERC20 internal f0;
    MockFeeERC20 internal f1;
    AMMPool internal l46;

    AMMFactory internal factory;
    AMMFactory internal seeded;
    M11PairLookupProbe internal probe;
    address internal a;
    address internal b;
    address internal c;

    function setUp() public {
        MockERC20 x = new MockERC20("A", "A", 18);
        MockERC20 y = new MockERC20("B", "B", 18);
        (o0, o1) = address(x) < address(y) ? (x, y) : (y, x);
        ord = new AMMPool(address(o0), address(o1), surplus);
        fresh = new AMMPool(address(o0), address(o1), surplus);
        o0.mint(alice, 1e30);
        o1.mint(alice, 1e30);
        vm.startPrank(alice);
        o0.approve(address(ord), MAX);
        o1.approve(address(ord), MAX);
        o0.approve(address(fresh), MAX);
        o1.approve(address(fresh), MAX);
        ord.addLiquidity(addParams(1000e18, 2000e18, 0, alice, block.timestamp));
        vm.stopPrank();

        MockFeeERC20 u = new MockFeeERC20("C", "C", 18);
        MockFeeERC20 v = new MockFeeERC20("D", "D", 18);
        (f0, f1) = address(u) < address(v) ? (u, v) : (v, u);
        l46 = new AMMPool(address(f0), address(f1), surplus);
        address[2] memory users = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            f0.mint(users[i], 1e9);
            f1.mint(users[i], 1e9);
            vm.startPrank(users[i]);
            f0.approve(address(l46), MAX);
            f1.approve(address(l46), MAX);
            vm.stopPrank();
        }
        vm.prank(alice);
        l46.addLiquidity(addParams(10_000, 20_000, 0, alice, block.timestamp));
        f1.setTax(MockFeeERC20.Path.TransferFrom, 1000);

        address[3] memory t;
        for (uint256 i; i < 3; ++i) {
            t[i] = address(new MockERC20("T", "T", 18));
        }
        for (uint256 i; i < 3; ++i) {
            for (uint256 j = i + 1; j < 3; ++j) {
                if (t[j] < t[i]) (t[i], t[j]) = (t[j], t[i]);
            }
        }
        (a, b, c) = (t[0], t[1], t[2]);
        factory = new AMMFactory(surplus);
        seeded = new AMMFactory(surplus);
        seeded.createPair(a, b);
        probe = new M11PairLookupProbe();
    }

    function _add(AMMPool pl, IAMMPool.AddLiquidityParams memory p, address payer, string memory label) internal {
        vm.prank(payer);
        uint256 g = gasleft();
        pl.addLiquidity(p);
        g -= gasleft();
        emit log_named_uint(string.concat("GAS ", label), g);
    }

    function _ordParams(bool token1First) internal view returns (IAMMPool.AddLiquidityParams memory) {
        return IAMMPool.AddLiquidityParams(1e18, 2e18, 1e18, 2e18, MAX, MAX, 0, alice, block.timestamp, token1First);
    }

    function _l46Params(bool taxedFirst) internal view returns (IAMMPool.AddLiquidityParams memory) {
        if (taxedFirst) {
            return IAMMPool.AddLiquidityParams(1_000, 2_500, 900, 2_000, 0, 1, 1_272, bob, block.timestamp, true);
        }
        return IAMMPool.AddLiquidityParams(1_000, 2_500, 1_000, 2_000, 100, 1, 1_272, bob, block.timestamp, false);
    }

    // ---------------- Deployments and pair creation ----------------

    function test_gas_deploy_factory() public {
        address r = surplus;
        uint256 g = gasleft();
        new AMMFactory(r);
        emit log_named_uint("GAS deploy AMMFactory", g - gasleft());
    }

    function test_gas_deploy_pool() public {
        (address x, address y, address r) = (address(o0), address(o1), surplus);
        uint256 g = gasleft();
        new AMMPool(x, y, r);
        emit log_named_uint("GAS deploy AMMPool (direct)", g - gasleft());
    }

    function test_gas_createPair_first() public {
        (AMMFactory f, address x, address y) = (factory, a, b);
        uint256 g = gasleft();
        f.createPair(x, y);
        emit log_named_uint("GAS createPair first (allPairs 0 -> 1)", g - gasleft());
    }

    function test_gas_createPair_subsequent() public {
        (AMMFactory f, address x, address y) = (seeded, a, c);
        uint256 g = gasleft();
        f.createPair(x, y);
        emit log_named_uint("GAS createPair subsequent (allPairs 1 -> 2)", g - gasleft());
    }

    // ---------------- Deposits ----------------

    function test_gas_add_initial() public {
        _add(fresh, addParams(1000e18, 2000e18, 0, alice, block.timestamp), alice, "add initial (token0 first)");
    }

    function test_gas_add_ord_token0First() public {
        _add(ord, _ordParams(false), alice, "add later ORD token0 first");
    }

    function test_gas_add_ord_token1First() public {
        _add(ord, _ordParams(true), alice, "add later ORD token1 first");
    }

    function test_gas_add_l46_taxedSecond() public {
        _add(l46, _l46Params(false), bob, "add later L46 taxed second (token0 first)");
    }

    function test_gas_add_l46_taxedFirst() public {
        _add(l46, _l46Params(true), bob, "add later L46 taxed first (token1 first, re-plan)");
    }

    // ---------------- getPair ----------------

    function _cold(address x, address y, string memory label) internal {
        AMMFactory f = seeded;
        uint256 g = gasleft();
        f.getPair(x, y);
        emit log_named_uint(string.concat("GAS getPair cold ", label), g - gasleft());
    }

    function test_gas_getPair_cold_sorted() public {
        _cold(a, b, "existing, sorted");
    }

    function test_gas_getPair_cold_reversed() public {
        _cold(b, a, "existing, reversed");
    }

    function test_gas_getPair_cold_missing() public {
        _cold(a, c, "missing, sorted");
    }

    function _inTx(address x1, address y1, address x2, address y2, string memory label) internal {
        (M11PairLookupProbe pr, AMMFactory f) = (probe, seeded);
        (uint256 first, uint256 second) = pr.twice(f, x1, y1, x2, y2);
        emit log_named_uint(string.concat("GAS getPair in-tx first ", label), first);
        emit log_named_uint(string.concat("GAS getPair in-tx second ", label), second);
    }

    function test_gas_getPair_inTx_sorted_sorted() public {
        _inTx(a, b, a, b, "sorted then sorted");
    }

    function test_gas_getPair_inTx_reversed_reversed() public {
        _inTx(b, a, b, a, "reversed then reversed");
    }

    function test_gas_getPair_inTx_sorted_reversed() public {
        _inTx(a, b, b, a, "sorted then reversed");
    }

    // ---------------- LP metadata ----------------

    function test_gas_name() public {
        AMMPool p = ord;
        uint256 g = gasleft();
        p.name();
        emit log_named_uint("GAS name()", g - gasleft());
    }

    function test_gas_symbol() public {
        AMMPool p = ord;
        uint256 g = gasleft();
        p.symbol();
        emit log_named_uint("GAS symbol()", g - gasleft());
    }

    // ---------------- Controls ----------------

    function test_gas_swap_token0In() public {
        (AMMPool p, address tin, address to) = (ord, address(o0), alice);
        vm.prank(alice);
        uint256 g = gasleft();
        p.swapExactInput(tin, 1e18, 0, to, block.timestamp);
        emit log_named_uint("GAS swapExactInput token0 in (control)", g - gasleft());
    }

    function test_gas_remove_partial() public {
        (AMMPool p, address to) = (ord, alice);
        vm.prank(alice);
        uint256 g = gasleft();
        p.removeLiquidity(1e18, 0, 0, to, block.timestamp);
        emit log_named_uint("GAS removeLiquidity partial (control)", g - gasleft());
    }
}
