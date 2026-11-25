// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AMMFactory} from "../../src/AMMFactory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Measures `getPair` from inside one call (one transaction), so the second lookup sees the
///         Factory account and the slot(s) read by the first lookup as warm.
contract PairLookupProbe {
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

/// EXPERIMENT (TEST_MATRIX §14.9, experiment 2). Gas harness; identical on the baseline and the
/// variant commit. Method as G02 (TEST_MATRIX §14.6): arguments are locals before the first
/// `gasleft()`, one top-level call per test under `isolate = true`, so a top-level measurement is
/// cold (Factory account and storage). Warm lookups are measured inside `PairLookupProbe` (one
/// transaction: the second call repeats the same argument order; a reversed-order second lookup is
/// a separate scenario). Logs values only. Run: `forge test --match-contract GasFactoryPair -vv`.
contract GasFactoryPair is Test {
    AMMFactory internal factory; // empty
    AMMFactory internal seeded; // holds pair (a, b)
    PairLookupProbe internal probe;
    address internal a;
    address internal b;
    address internal c;
    address internal surplus = makeAddr("surplusRecipient");

    function setUp() public {
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
        probe = new PairLookupProbe();
    }

    function test_gas_createPair_first() public {
        (AMMFactory f, address x, address y) = (factory, a, b);
        uint256 g = gasleft();
        f.createPair(x, y);
        emit log_named_uint("GAS createPair first (allPairs 0 -> 1), sorted input", g - gasleft());
    }

    function test_gas_createPair_subsequent() public {
        (AMMFactory f, address x, address y) = (seeded, a, c);
        uint256 g = gasleft();
        f.createPair(x, y);
        emit log_named_uint("GAS createPair subsequent (allPairs 1 -> 2), sorted input", g - gasleft());
    }

    function _cold(address x, address y, string memory label) internal {
        AMMFactory f = seeded;
        uint256 g = gasleft();
        f.getPair(x, y);
        emit log_named_uint(string.concat("GAS getPair cold ", label), g - gasleft());
    }

    function test_gas_getPair_cold_sorted() public {
        _cold(a, b, "existing, sorted (token0, token1)");
    }

    function test_gas_getPair_cold_reversed() public {
        _cold(b, a, "existing, reversed (token1, token0)");
    }

    function test_gas_getPair_cold_missing_sorted() public {
        _cold(a, c, "missing, sorted");
    }

    function _warm(address x1, address y1, address x2, address y2, string memory label) internal {
        (PairLookupProbe pr, AMMFactory f) = (probe, seeded);
        (uint256 first, uint256 second) = pr.twice(f, x1, y1, x2, y2);
        emit log_named_uint(string.concat("GAS getPair in-tx first ", label), first);
        emit log_named_uint(string.concat("GAS getPair in-tx second ", label), second);
    }

    function test_gas_getPair_warm_sorted_sorted() public {
        _warm(a, b, a, b, "sorted then sorted");
    }

    function test_gas_getPair_warm_reversed_reversed() public {
        _warm(b, a, b, a, "reversed then reversed");
    }

    function test_gas_getPair_inTx_sorted_then_reversed() public {
        _warm(a, b, b, a, "sorted then reversed (separate scenario)");
    }

    function test_gas_deploy_factory() public {
        address r = surplus;
        uint256 g = gasleft();
        new AMMFactory(r);
        emit log_named_uint("GAS deployment new AMMFactory", g - gasleft());
    }
}
