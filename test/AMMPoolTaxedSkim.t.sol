// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockTaxedERC20} from "./mocks/MockTaxedERC20.sol";
import {addParams} from "./utils/AddParams.sol";

/// @notice TEST_MATRIX R09 (moved from M8 to M10): `skim()` with U8 taxed tokens. Rules (M6-4,
///         A8, THREAT_MODEL T16): per token with surplus `x = balance − reserve`, the Pool's
///         balance falls by exactly `x` (A8, Pool side), `SurplusSkimmed(token, x)` reports the
///         Pool-side amount, reserves are unchanged, and `surplusRecipient` receives
///         `x − floor(x·taxBps/10000)` — less than `x`; that receipt is not measured by the Pool
///         (no MIN-NET in `skim`). Afterwards `balance == reserve`, and a second `skim()` is a
///         no-op (no event). Taxes: 1 % and 3 %, both tokens taxed.
contract AMMPoolTaxedSkimTest is Test {
    uint256 internal constant D = 10_000;
    address internal alice = makeAddr("alice");
    address internal surplus = makeAddr("surplusRecipient");

    AMMPool internal pool;
    MockTaxedERC20 internal t0;
    MockTaxedERC20 internal t1;

    function setUp() public {
        MockTaxedERC20 p = new MockTaxedERC20("P", "P", 18, 100);
        MockTaxedERC20 q = new MockTaxedERC20("Q", "Q", 18, 300);
        (t0, t1) = address(p) < address(q) ? (p, q) : (q, p);
        pool = new AMMPool(address(t0), address(t1), surplus);
        t0.mint(alice, 1e24);
        t1.mint(alice, 1e24);
        vm.startPrank(alice);
        t0.approve(address(pool), type(uint256).max);
        t1.approve(address(pool), type(uint256).max);
        pool.addLiquidity(addParams(1e21, 3e21, 0, alice, block.timestamp));
        vm.stopPrank();
    }

    function _skimChecked(uint256 x0, uint256 x1) internal {
        t0.mint(address(pool), x0); // direct transfer by mint: untaxed, becomes surplus
        t1.mint(address(pool), x1);
        (uint256 r0, uint256 r1) = pool.getReserves();
        uint256 p0 = t0.balanceOf(address(pool));
        uint256 p1 = t1.balanceOf(address(pool));
        uint256 w0 = t0.balanceOf(surplus);
        uint256 w1 = t1.balanceOf(surplus);
        assertEq(p0 - r0, x0, "surplus0 before");
        assertEq(p1 - r1, x1, "surplus1 before");

        if (x0 != 0) {
            vm.expectEmit(true, false, false, true, address(pool));
            emit AMMPool.SurplusSkimmed(address(t0), x0);
        }
        if (x1 != 0) {
            vm.expectEmit(true, false, false, true, address(pool));
            emit AMMPool.SurplusSkimmed(address(t1), x1);
        }
        pool.skim();

        assertEq(p0 - t0.balanceOf(address(pool)), x0, "A8: Pool token0 fell by exactly the surplus");
        assertEq(p1 - t1.balanceOf(address(pool)), x1, "A8: Pool token1 fell by exactly the surplus");
        (uint256 e0, uint256 e1) = pool.getReserves();
        assertEq(e0, r0, "reserve0 unchanged");
        assertEq(e1, r1, "reserve1 unchanged");
        assertEq(t0.balanceOf(address(pool)), e0, "balance0 == reserve0 after skim");
        assertEq(t1.balanceOf(address(pool)), e1, "balance1 == reserve1 after skim");
        assertEq(t0.balanceOf(surplus) - w0, x0 - (x0 * t0.taxBps()) / D, "recipient receives x0 minus tax");
        assertEq(t1.balanceOf(surplus) - w1, x1 - (x1 * t1.taxBps()) / D, "recipient receives x1 minus tax");

        vm.recordLogs();
        pool.skim();
        assertEq(vm.getRecordedLogs().length, 0, "second skim is a no-op");
    }

    function test_R09_taxedSkimExactPoolSideRecipientReceivesLess() public {
        _skimChecked(123_456_789, 987_654_321);
        // The recipient's shortfall is the tax, e.g. token with 3 %: 987,654,321 − 29,629,629.
        assertLt(t1.balanceOf(surplus), 987_654_321, "taxed recipient receives less than the surplus");
    }

    /// @dev Range: surplus per token [0, 1e27] (0 = no surplus in that token, skipped, no event).
    function testFuzz_R09_taxedSkim(uint256 x0, uint256 x1) public {
        _skimChecked(bound(x0, 0, 1e27), bound(x1, 0, 1e27));
    }
}
