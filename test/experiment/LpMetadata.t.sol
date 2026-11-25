// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AMMPool} from "../../src/AMMPool.sol";
import {AMMFactory} from "../../src/AMMFactory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// EXPERIMENT (branch m11-exp-lp-metadata; TEST_MATRIX §14.9, experiment 3). The LP metadata seen
/// by callers; must hold on the baseline (strings stored by the OpenZeppelin constructor) and on
/// the variant (constant overrides). Also checks the exact ABI-encoded return data.
contract LpMetadata is Test {
    address internal surplus = makeAddr("surplusRecipient");
    AMMPool internal direct;
    AMMPool internal viaFactory;

    function setUp() public {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (address t0, address t1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        direct = new AMMPool(t0, t1, surplus);
        viaFactory = AMMPool(new AMMFactory(surplus).createPair(t0, t1));
    }

    function _check(AMMPool pool) internal view {
        assertEq(pool.name(), "AMM Liquidity Provider");
        assertEq(pool.symbol(), "AMM-LP");
        assertEq(pool.decimals(), 18);
        (bool ok, bytes memory ret) = address(pool).staticcall(abi.encodeWithSignature("name()"));
        assertTrue(ok);
        assertEq(ret, abi.encode("AMM Liquidity Provider"), "name() return data");
        (ok, ret) = address(pool).staticcall(abi.encodeWithSignature("symbol()"));
        assertTrue(ok);
        assertEq(ret, abi.encode("AMM-LP"), "symbol() return data");
    }

    function test_metadata_direct() public view {
        _check(direct);
    }

    function test_metadata_viaFactory() public view {
        _check(viaFactory);
    }
}
