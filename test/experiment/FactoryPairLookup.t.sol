// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AMMFactory} from "../../src/AMMFactory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// EXPERIMENT (branch m11-exp-factory-pair; TEST_MATRIX §14.9, experiment 2). Observable registry
/// behaviour; the same assertions must hold on the baseline (both orderings stored) and on the
/// variant (one sorted entry per unordered pair, explicit `getPair` getter).
contract FactoryPairLookup is Test {
    AMMFactory internal factory;
    address internal a; // token0 of pair 1 (lowest)
    address internal b; // token1 of pair 1
    address internal c; // third token (highest), for pair 2 = (a, c)
    address internal surplus = makeAddr("surplusRecipient");

    function setUp() public {
        address[3] memory t;
        for (uint256 i; i < 3; ++i) {
            t[i] = address(new MockERC20("T", "T", 18));
        }
        // sort ascending
        for (uint256 i; i < 3; ++i) {
            for (uint256 j = i + 1; j < 3; ++j) {
                if (t[j] < t[i]) (t[i], t[j]) = (t[j], t[i]);
            }
        }
        (a, b, c) = (t[0], t[1], t[2]);
        factory = new AMMFactory(surplus);
    }

    function _assertNone(address x, address y) internal view {
        assertEq(factory.getPair(x, y), address(0), "no pair");
        assertEq(factory.getPair(y, x), address(0), "no pair (reversed)");
    }

    function test_lookup_beforeCreation_allZero() public view {
        _assertNone(a, b);
        _assertNone(a, c);
        assertEq(factory.getPair(a, a), address(0), "identical");
        assertEq(factory.getPair(address(0), a), address(0), "zero");
        assertEq(factory.getPair(address(0), address(0)), address(0), "zero, zero");
        assertEq(factory.allPairsLength(), 0);
    }

    function test_createAndLookup_bothOrders_enumeration_events_duplicates() public {
        address expected = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        vm.expectEmit(true, true, false, true, address(factory));
        emit AMMFactory.PairCreated(a, b, expected, 1);
        address p1 = factory.createPair(b, a); // reversed input order
        assertEq(p1, expected);

        assertEq(factory.getPair(a, b), p1, "sorted order");
        assertEq(factory.getPair(b, a), p1, "reversed order");
        assertEq(factory.getPair(a, a), address(0), "identical a");
        assertEq(factory.getPair(b, b), address(0), "identical b");
        assertEq(factory.getPair(address(0), a), address(0), "zero");
        _assertNone(a, c);
        _assertNone(b, c);
        assertEq(factory.allPairsLength(), 1);
        assertEq(factory.allPairs(0), p1);

        vm.expectRevert(AMMFactory.PairExists.selector);
        factory.createPair(a, b);
        vm.expectRevert(AMMFactory.PairExists.selector);
        factory.createPair(b, a);

        expected = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        vm.expectEmit(true, true, false, true, address(factory));
        emit AMMFactory.PairCreated(a, c, expected, 2);
        address p2 = factory.createPair(a, c); // sorted input order
        assertEq(factory.getPair(a, c), p2);
        assertEq(factory.getPair(c, a), p2);
        assertEq(factory.getPair(a, b), p1, "pair 1 unchanged");
        assertEq(factory.getPair(b, a), p1, "pair 1 unchanged (reversed)");
        _assertNone(b, c);
        assertEq(factory.allPairsLength(), 2);
        assertEq(factory.allPairs(0), p1);
        assertEq(factory.allPairs(1), p2);

        vm.expectRevert(AMMFactory.PairExists.selector);
        factory.createPair(c, a);
    }

    /// @dev Range: any two addresses; before and after creating pair (a, b), every query other than
    ///      the created pair (either order) returns 0.
    function testFuzz_lookup_onlyCreatedPairIsRegistered(address x, address y) public {
        address p1 = factory.createPair(a, b);
        address got = factory.getPair(x, y);
        bool isPair = (x == a && y == b) || (x == b && y == a);
        assertEq(got, isPair ? p1 : address(0));
    }
}
