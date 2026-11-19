// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {PoolStateFixture} from "./utils/PoolStateFixture.sol";

/// @notice M6: downward-only `sync()` (ARCHITECTURE §5.3, §7.7; DECISIONS M6-4, Gate R=(b)).
///         TEST_MATRIX R02, R05, R11 (sync), R14, B05.
contract AMMPoolSyncTest is PoolStateFixture {
    event ReserveSynced(address indexed token, uint256 previousReserve, uint256 newReserve);

    /// R02: any address can call `sync()`; it lowers a deficit reserve to the balance.
    function testFuzz_R02_anyoneCanSync(address caller) public {
        vm.assume(caller != address(0));
        _slashPool(t0, 1000);
        vm.prank(caller);
        pool.sync();
        (uint256 r0, uint256 r1) = _reserves();
        assertEq(r0, 1_000_000 - 1000);
        assertEq(r1, 2_000_000);
    }

    /// R05 / BI-4: surplus is never absorbed (Gate R=(b)); reserves, surplus, events unchanged.
    function test_R05_surplusNotAbsorbed() public {
        _donate(t0, 500);
        _donate(t1, 700);
        Snap memory before = _snap();
        vm.recordLogs();
        vm.record();
        pool.sync();
        assertEq(_poolWrites(), 0, "no storage write");
        assertEq(vm.getRecordedLogs().length, 0, "no event");
        _assertSame(before, _snap());
    }

    /// R11 (sync part): no deficit → returns normally, no write, no event; also when repeated.
    function test_R11_syncNoOpAndRepeated() public {
        Snap memory before = _snap();
        vm.recordLogs();
        vm.record();
        pool.sync();
        assertEq(_poolWrites(), 0, "first call: no write");
        assertEq(vm.getRecordedLogs().length, 0, "first call: no event");
        _assertSame(before, _snap());

        // After a real reconciliation, a repeated sync() is a no-op.
        _slashPool(t1, 10);
        pool.sync();
        Snap memory mid = _snap();
        vm.recordLogs();
        vm.record();
        pool.sync();
        assertEq(_poolWrites(), 0, "repeated call: no write");
        assertEq(vm.getRecordedLogs().length, 0, "repeated call: no event");
        _assertSame(mid, _snap());
    }

    /// Deficit in one token: only that reserve is lowered, one event with exact fields.
    function test_syncDeficitToken1EmitsOneEvent() public {
        _slashPool(t1, 12_345);
        vm.expectEmit(true, false, false, true, address(pool));
        emit ReserveSynced(address(t1), 2_000_000, 2_000_000 - 12_345);
        vm.recordLogs();
        pool.sync();
        assertEq(vm.getRecordedLogs().length, 1, "exactly one event");
        (uint256 r0, uint256 r1) = _reserves();
        assertEq(r0, 1_000_000);
        assertEq(r1, 2_000_000 - 12_345);
        assertEq(t1.balanceOf(address(pool)), r1, "reserve == balance");
    }

    /// Both tokens in deficit: two events, token0 first.
    function test_syncBothDeficitsTwoEventsInOrder() public {
        _slashPool(t0, 1);
        _slashPool(t1, 2);
        vm.recordLogs();
        pool.sync();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(address(t0)))), "token0 first");
        (uint256 prev, uint256 next) = abi.decode(logs[0].data, (uint256, uint256));
        assertEq(prev, 1_000_000);
        assertEq(next, 1_000_000 - 1);
        assertEq(logs[1].topics[1], bytes32(uint256(uint160(address(t1)))), "token1 second");
        (prev, next) = abi.decode(logs[1].data, (uint256, uint256));
        assertEq(prev, 2_000_000);
        assertEq(next, 2_000_000 - 2);
    }

    /// Deficit in token0 and surplus in token1: token0 lowered, token1 surplus untouched.
    function test_syncDeficitAndSurplus() public {
        _slashPool(t0, 100);
        _donate(t1, 900);
        pool.sync();
        (uint256 r0, uint256 r1) = _reserves();
        assertEq(r0, 1_000_000 - 100);
        assertEq(r1, 2_000_000, "surplus not absorbed");
        assertEq(t1.balanceOf(address(pool)) - r1, 900, "surplus unchanged");
    }

    /// R14: sync lowers one reserve to 0 while totalSupply > 0 (terminal pool, DECISIONS M6-1).
    function test_R14_syncLowersReserveToZero() public {
        uint256 supply = pool.totalSupply();
        _slashPool(t0, 1_000_000);
        vm.expectEmit(true, false, false, true, address(pool));
        emit ReserveSynced(address(t0), 1_000_000, 0);
        pool.sync();
        (uint256 r0, uint256 r1) = _reserves();
        assertEq(r0, 0);
        assertEq(r1, 2_000_000);
        assertEq(pool.totalSupply(), supply, "LP supply unchanged");
        assertEq(pool.balanceOf(address(pool)), 1000, "lock unchanged");
    }

    /// B05 / BI-4 fuzz. Range: per token, either a deficit of any size up to the whole balance
    /// or a surplus up to 2^128, starting from the seeded reserves (1e6, 2e6). Asserts
    /// reserve_i' = min(old reserve_i, balance_i), balances and LP state unchanged.
    /// Not covered: reserves other than the seeded pair.
    function testFuzz_B05_syncIsMin(bool deficit0, uint256 x0, bool deficit1, uint256 x1) public {
        (uint256 old0, uint256 old1) = _reserves();
        x0 = deficit0 ? bound(x0, 0, old0) : bound(x0, 0, 2 ** 128);
        x1 = deficit1 ? bound(x1, 0, old1) : bound(x1, 0, 2 ** 128);
        if (deficit0) _slashPool(t0, x0);
        else _donate(t0, x0);
        if (deficit1) _slashPool(t1, x1);
        else _donate(t1, x1);

        Snap memory before = _snap();
        pool.sync();
        Snap memory afterSync = _snap();

        assertEq(afterSync.r0, _min(old0, before.pool0), "reserve0 = min");
        assertEq(afterSync.r1, _min(old1, before.pool1), "reserve1 = min");
        assertLe(afterSync.r0, old0, "never increases");
        assertLe(afterSync.r1, old1, "never increases");
        assertEq(afterSync.pool0, before.pool0, "balance0 unchanged");
        assertEq(afterSync.pool1, before.pool1, "balance1 unchanged");
        assertEq(afterSync.supply, before.supply, "LP supply unchanged");
        assertEq(afterSync.poolLP, 1000, "lock unchanged");
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
