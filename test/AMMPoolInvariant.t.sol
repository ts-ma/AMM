// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockTaxedERC20} from "./mocks/MockTaxedERC20.sol";
import {AMMPoolHandler} from "./invariant/AMMPoolHandler.sol";

/// @notice M10 P0 stateful invariants (TEST_MATRIX §12: I1, I2, I3, I7, I9, I10; I4 evidence).
///         Per-operation properties are asserted inside `AMMPoolHandler` after every call;
///         the global ones below are asserted after every call of the campaign.
///         Model and premises: one Pool, three actors, supported tokens only (Tier 0, or U8
///         taxed with fixed rates 1 % / 3 %), truthful `balanceOf`, no deficit-creating token;
///         the initial deposit (1e21, 3e21) is made in the handler's constructor, so every
///         sequence runs with `S > 0`. Ranges per call: deposit caps [1, 1e24] (independent or near the ratio), swap input
///         [1, 1e23], donation [1, 1e22]. Not modelled: unsupported tokens (deficits, hooks,
///         callbacks), reserves near 2^256, several Pools.
abstract contract AMMPoolInvariantBase is StdInvariant, Test {
    AMMPool internal pool;
    AMMPoolHandler internal handler;
    address internal surplus = makeAddr("surplusRecipient");

    function _deploy(MockERC20 a, MockERC20 b, uint256 taxA, uint256 taxB) internal {
        (MockERC20 lo, MockERC20 hi, uint256 taxLo, uint256 taxHi) =
            address(a) < address(b) ? (a, b, taxA, taxB) : (b, a, taxB, taxA);
        pool = new AMMPool(address(lo), address(hi), surplus);
        handler = new AMMPoolHandler(pool, taxLo, taxHi, surplus);

        bytes4[] memory sel = new bytes4[](8);
        sel[0] = AMMPoolHandler.addLiquidity.selector;
        sel[1] = AMMPoolHandler.removeLiquidity.selector;
        sel[2] = AMMPoolHandler.swap.selector;
        sel[3] = AMMPoolHandler.sync.selector;
        sel[4] = AMMPoolHandler.skim.selector;
        sel[5] = AMMPoolHandler.donate.selector;
        sel[6] = AMMPoolHandler.transferLP.selector;
        sel[7] = AMMPoolHandler.transferLPToPool.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    /// @dev I1 (BI-7, BI-8), I2 (BI-1), I9 (surplus moves only by donation and skim) and
    ///      positive reserves (the lock keeps both reserves > 0 for every reachable state).
    function _checkGlobal() internal view {
        (uint256 r0, uint256 r1) = pool.getReserves();
        uint256 b0 = MockERC20(pool.token0()).balanceOf(address(pool));
        uint256 b1 = MockERC20(pool.token1()).balanceOf(address(pool));
        uint256 supply = pool.totalSupply();

        assertEq(supply, handler.ghostMinted() - handler.ghostBurned(), "I1: supply = minted - burned");
        assertEq(pool.balanceOf(address(pool)), 1000, "I1: lock == 1000");
        uint256 lpSum = 1000;
        for (uint256 i; i < 3; ++i) {
            lpSum += pool.balanceOf(handler.actorAt(i));
        }
        assertEq(lpSum, supply, "I1: actors + lock hold the whole supply");

        assertGe(b0, r0, "I2: balance0 >= reserve0");
        assertGe(b1, r1, "I2: balance1 >= reserve1");
        assertEq(b0 - r0, handler.ghostSurplus0(), "I9: surplus0 only from donations, cleared by skim");
        assertEq(b1 - r1, handler.ghostSurplus1(), "I9: surplus1 only from donations, cleared by skim");
        assertGt(r0, 0, "reserve0 > 0");
        assertGt(r1, 0, "reserve1 > 0");
    }

    function afterInvariant() external view {
        handler.logStats();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 500
/// forge-config: default.invariant.fail-on-revert = true
contract AMMPoolInvariantTier0Test is AMMPoolInvariantBase {
    function setUp() public {
        _deploy(new MockERC20("A", "A", 18), new MockERC20("B", "B", 18), 0, 0);
    }

    function invariant_accounting() public view {
        _checkGlobal();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 500
/// forge-config: default.invariant.fail-on-revert = true
contract AMMPoolInvariantTaxedTest is AMMPoolInvariantBase {
    function setUp() public {
        _deploy(new MockTaxedERC20("P", "P", 18, 100), new MockTaxedERC20("Q", "Q", 18, 300), 100, 300);
    }

    function invariant_accounting() public view {
        _checkGlobal();
    }
}
