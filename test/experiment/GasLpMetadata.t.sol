// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AMMPool} from "../../src/AMMPool.sol";
import {AMMFactory} from "../../src/AMMFactory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// EXPERIMENT (TEST_MATRIX §14.9, experiment 3). Gas harness; identical on the baseline and the
/// variant commit. Method as G02 (TEST_MATRIX §14.6): arguments are locals before the first
/// `gasleft()`, one top-level call per test under `isolate = true` (cold). Standalone deployment
/// and `createPair` are separate comparisons (both contain one Pool creation). Logs values only.
/// Run: `forge test --match-contract GasLpMetadata -vv`.
contract GasLpMetadata is Test {
    address internal surplus = makeAddr("surplusRecipient");
    address internal t0;
    address internal t1;
    AMMFactory internal factory;
    AMMPool internal pool;

    function setUp() public {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        factory = new AMMFactory(surplus);
        pool = new AMMPool(t0, t1, surplus);
    }

    function test_gas_deploy_pool() public {
        (address a, address b, address r) = (t0, t1, surplus);
        uint256 g = gasleft();
        new AMMPool(a, b, r);
        emit log_named_uint("GAS deployment new AMMPool (standalone)", g - gasleft());
    }

    function test_gas_createPair_first() public {
        (AMMFactory f, address a, address b) = (factory, t0, t1);
        uint256 g = gasleft();
        f.createPair(a, b);
        emit log_named_uint("GAS createPair first", g - gasleft());
    }

    function test_gas_deploy_factory() public {
        address r = surplus;
        uint256 g = gasleft();
        new AMMFactory(r);
        emit log_named_uint("GAS deployment new AMMFactory", g - gasleft());
    }

    function test_gas_name() public {
        AMMPool p = pool;
        uint256 g = gasleft();
        p.name();
        emit log_named_uint("GAS name() cold", g - gasleft());
    }

    function test_gas_symbol() public {
        AMMPool p = pool;
        uint256 g = gasleft();
        p.symbol();
        emit log_named_uint("GAS symbol() cold", g - gasleft());
    }
}
