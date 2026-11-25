// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {AMMPool} from "../../src/AMMPool.sol";
import {IAMMPool} from "../../src/interfaces/IAMMPool.sol";
import {SnapshotReuseBase} from "./SnapshotReuseBase.sol";

/// EXPERIMENT (TEST_MATRIX §14.9, experiment 1). Gas harness; identical on the baseline and the
/// variant commit. Method as G02 (TEST_MATRIX §14.6): every argument is a local before the first
/// `gasleft()`, one top-level call per test under `isolate = true` (cold state), the ABI encoding
/// inside the interval, no 21,000 base or calldata cost. No recording, tracing cheatcode or
/// observer read runs inside the interval. Logs values only; asserts nothing about gas.
/// Run: `forge test --match-contract GasSnapshotReuse -vv`.
contract GasSnapshotReuse is SnapshotReuseBase {
    function _measure(AMMPool pl, IAMMPool.AddLiquidityParams memory p, address payer, string memory label) internal {
        vm.prank(payer);
        uint256 g = gasleft();
        pl.addLiquidity(p);
        g -= gasleft();
        emit log_named_uint(string.concat("GAS ", label), g);
    }

    function test_gas_ord_token0First() public {
        _measure(ord, _ordParams(false), alice, "ORD later, token0 first, finite maxDebit");
    }

    function test_gas_ord_token1First() public {
        _measure(ord, _ordParams(true), alice, "ORD later, token1First, finite maxDebit");
    }

    function test_gas_g02_token0Binds() public {
        _measure(ord, _g02Params(), alice, "G02 later, token0 cap binds, maxDebit MAX");
    }

    function test_gas_l46_taxedSecond() public {
        _measure(l46, _l46Params(false), bob, "L46 taxed second (token0 first)");
    }

    function test_gas_l46_taxedFirst() public {
        _measure(l46, _l46Params(true), bob, "L46 taxed first (token1First, re-plan)");
    }

    function test_gas_initial_control() public {
        _measure(fresh, _initParams(), alice, "INIT initial deposit (control)");
    }

    function test_gas_deploy_pool() public {
        (address a, address b, address r) = (address(o0), address(o1), surplus);
        uint256 g = gasleft();
        new AMMPool(a, b, r);
        g -= gasleft();
        emit log_named_uint("GAS deployment new AMMPool", g);
    }
}
