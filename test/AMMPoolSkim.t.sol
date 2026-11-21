// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockDeficitERC20} from "./mocks/MockDeficitERC20.sol";
import {MockOverDebitERC20} from "./mocks/MockOverDebitERC20.sol";
import {PoolStateFixture} from "./utils/PoolStateFixture.sol";
import {addParams} from "./utils/AddParams.sol";

/// @notice M6: per-token `skim()` to the immutable `surplusRecipient` (ARCHITECTURE §5.4, §7.8;
///         DECISIONS M6-4, A2, A8). TEST_MATRIX R03, R04, R06, R10–R13, R21 (skim), B04,
///         B06 (skim). Every revert asserts the exact error (M4-8) and full rollback (M5-6).
contract AMMPoolSkimTest is PoolStateFixture {
    event SurplusSkimmed(address indexed token, uint256 amount);

    function _skimData() internal pure returns (bytes memory) {
        return abi.encodeCall(AMMPool.skim, ());
    }

    /// R03 / R04 / BI-3: all surplus of both tokens reaches surplusRecipient; reserves and the
    /// price are unchanged; any caller, and the caller gains nothing.
    function testFuzz_R03_R04_skimSendsAllSurplus(address caller, uint256 s0, uint256 s1) public {
        vm.assume(caller != address(0) && caller != surplus && caller != address(pool));
        s0 = bound(s0, 1, 2 ** 128);
        s1 = bound(s1, 1, 2 ** 128);
        _donate(t0, s0);
        _donate(t1, s1);
        (uint256 r0, uint256 r1) = _reserves();
        uint256 quote = pool.getAmountOut(address(t0), 1000);
        uint256 c0 = t0.balanceOf(caller);
        uint256 c1 = t1.balanceOf(caller);

        vm.expectEmit(true, false, false, true, address(pool));
        emit SurplusSkimmed(address(t0), s0);
        vm.expectEmit(true, false, false, true, address(pool));
        emit SurplusSkimmed(address(t1), s1);
        vm.prank(caller);
        pool.skim();

        (uint256 a0, uint256 a1) = _reserves();
        assertEq(a0, r0, "reserve0 unchanged");
        assertEq(a1, r1, "reserve1 unchanged");
        assertEq(pool.getAmountOut(address(t0), 1000), quote, "price unchanged");
        assertEq(t0.balanceOf(surplus), s0, "recipient token0");
        assertEq(t1.balanceOf(surplus), s1, "recipient token1");
        assertEq(t0.balanceOf(address(pool)), r0, "balance0 == reserve0");
        assertEq(t1.balanceOf(address(pool)), r1, "balance1 == reserve1");
        assertEq(t0.balanceOf(caller), c0, "caller gains nothing (token0)");
        assertEq(t1.balanceOf(caller), c1, "caller gains nothing (token1)");
    }

    /// R04: the interface has no recipient parameter: the only skim selector is `skim()`.
    function test_R04_noRecipientParameter() public {
        assertEq(AMMPool.skim.selector, bytes4(keccak256("skim()")));
        _donate(t0, 5);
        (bool ok, bytes memory ret) = address(pool).call(abi.encodeWithSignature("skim(address)", address(this)));
        assertFalse(ok, "no skim(address)");
        assertEq(ret.length, 0);
        assertEq(t0.balanceOf(address(this)), 0);
    }

    /// R06: direct transfer → skim → sync: surplus reaches the recipient; sync is a no-op.
    function test_R06_skimThenSyncIsNoOp() public {
        _donate(t1, 4242);
        pool.skim();
        assertEq(t1.balanceOf(surplus), 4242);
        Snap memory before = _snap();
        vm.recordLogs();
        vm.record();
        pool.sync();
        assertEq(_poolWrites(), 0, "sync: no write");
        assertEq(vm.getRecordedLogs().length, 0, "sync: no event");
        _assertSame(before, _snap());
    }

    /// R10 fuzz: order independence. Range: each token independently in deficit (up to its
    /// whole reserve), surplus (up to 2^128) or balanced, from the seeded reserves. sync→skim and
    /// skim→sync reach the same reserves and balances.
    function testFuzz_R10_orderIndependence(uint8 m0, uint256 x0, uint8 m1, uint256 x1) public {
        _perturb(t0, m0, x0, 1_000_000);
        _perturb(t1, m1, x1, 2_000_000);
        uint256 id = vm.snapshotState();

        pool.sync();
        pool.skim();
        Snap memory a = _snap();

        vm.revertToState(id);
        pool.skim();
        pool.sync();
        Snap memory b = _snap();

        _assertSame(a, b);
        assertEq(a.pool0, a.r0, "balanced afterwards (token0)");
        assertEq(a.pool1, a.r1, "balanced afterwards (token1)");
    }

    /// @dev mode 0: balanced; 1: deficit of 1..reserve; 2: surplus of 1..2^128.
    function _perturb(MockDeficitERC20 t, uint8 mode, uint256 x, uint256 reserve) internal {
        mode = uint8(bound(mode, 0, 2));
        if (mode == 1) _slashPool(t, bound(x, 1, reserve));
        else if (mode == 2) _donate(t, bound(x, 1, 2 ** 128));
    }

    /// R11 (skim part): no surplus → no transfer, no write, no event; also when repeated.
    function test_R11_skimNoOpAndRepeated() public {
        Snap memory before = _snap();
        vm.recordLogs();
        vm.record();
        pool.skim();
        assertEq(_poolWrites(), 0, "first call: no write");
        assertEq(vm.getRecordedLogs().length, 0, "first call: no event");
        _assertSame(before, _snap());

        _donate(t0, 10);
        pool.skim();
        Snap memory mid = _snap();
        vm.recordLogs();
        vm.record();
        pool.skim();
        assertEq(_poolWrites(), 0, "repeated call: no write");
        assertEq(vm.getRecordedLogs().length, 0, "repeated call: no event");
        _assertSame(mid, _snap());
    }

    /// R12: a failing skim transfer reverts skim only (neither token skimmed); swap, add and
    /// remove still work. The failure is a token refusing the transfer to surplusRecipient.
    function test_R12_failingSkimRevertsOnlySkim() public {
        _donate(t0, 100);
        _donate(t1, 200);
        bytes memory refusal = abi.encodeWithSignature("Error(string)", "blocked");
        vm.mockCallRevert(address(t1), abi.encodeCall(IERC20.transfer, (surplus, 200)), refusal);
        _expectRevertNoChange(address(this), _skimData(), refusal);

        vm.prank(bob);
        pool.swapExactInput(address(t0), 10_000, 0, carol, block.timestamp);
        vm.prank(bob);
        pool.swapExactInput(address(t1), 10_000, 0, carol, block.timestamp);
        vm.prank(alice);
        pool.addLiquidity(addParams(1000, 4000, 0, alice, block.timestamp));
        vm.prank(alice);
        pool.removeLiquidity(1000, 0, 0, carol, block.timestamp);
        vm.clearMockedCalls();
        pool.skim();
        assertEq(t0.balanceOf(surplus), 100);
        assertEq(t1.balanceOf(surplus), 200);
    }

    /// A transfer returning false is rejected by SafeERC20, with full rollback.
    function test_R12_falseReturnRevertsSkim() public {
        _donate(t0, 100);
        vm.mockCall(address(t0), abi.encodeCall(IERC20.transfer, (surplus, 100)), abi.encode(false));
        _expectRevertNoChange(
            address(this), _skimData(), abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(t0))
        );
    }

    /// R13 / A2: token1 in deficit and token0 with surplus → token0 skimmed, token1 untouched;
    /// and the mirror case.
    function test_R13_deficitDoesNotBlockOtherSurplus() public {
        _slashPool(t1, 300);
        _donate(t0, 400);
        vm.recordLogs();
        pool.skim();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 skims;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool)) {
                ++skims;
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(t0)))), "only token0");
            }
        }
        assertEq(skims, 1, "one SurplusSkimmed");
        assertEq(t0.balanceOf(surplus), 400);
        assertEq(t1.balanceOf(surplus), 0);
        (uint256 r0, uint256 r1) = _reserves();
        assertEq(r1, 2_000_000, "deficit reserve untouched by skim");
        assertEq(t1.balanceOf(address(pool)), r1 - 300, "deficit unchanged");
        assertEq(t0.balanceOf(address(pool)), r0);
    }

    function test_R13_mirror() public {
        _slashPool(t0, 1);
        _donate(t1, 2);
        pool.skim();
        assertEq(t0.balanceOf(surplus), 0);
        assertEq(t1.balanceOf(surplus), 2);
        (uint256 r0,) = _reserves();
        assertEq(t0.balanceOf(address(pool)), r0 - 1, "deficit unchanged");
    }

    function test_R13_bothDeficitIsNoOp() public {
        _slashPool(t0, 1);
        _slashPool(t1, 1);
        Snap memory before = _snap();
        vm.recordLogs();
        pool.skim();
        assertEq(vm.getRecordedLogs().length, 0);
        _assertSame(before, _snap());
    }

    /// R21 (skim part): in a terminal pool, surplus of the zero-reserve token is skimmed.
    function test_R21_skimInTerminalPool() public {
        _slashPool(t0, t0.balanceOf(address(pool)));
        pool.sync();
        _donate(t0, 77);
        pool.skim();
        assertEq(t0.balanceOf(surplus), 77);
        assertEq(t0.balanceOf(address(pool)), 0);
        (uint256 r0,) = _reserves();
        assertEq(r0, 0);
    }

    /// Before the first deposit every balance is surplus (reserves 0) and can be skimmed.
    function test_skimBeforeFirstDeposit() public {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (MockERC20 x, MockERC20 y) = address(a) < address(b) ? (a, b) : (b, a);
        AMMPool p = new AMMPool(address(x), address(y), surplus);
        x.mint(address(p), 9);
        p.skim();
        assertEq(x.balanceOf(surplus), 9);
        assertEq(p.totalSupply(), 0);
    }

    /// B04 / BI-3 fuzz. Range: as R10. After skim: reserves unchanged; every token that had
    /// surplus has balance == reserve and the recipient got exactly the surplus; tokens without
    /// surplus are untouched.
    function testFuzz_B04_skimLeavesBalanceEqualReserve(uint8 m0, uint256 x0, uint8 m1, uint256 x1) public {
        _perturb(t0, m0, x0, 1_000_000);
        _perturb(t1, m1, x1, 2_000_000);
        Snap memory b = _snap();
        pool.skim();
        Snap memory a = _snap();
        assertEq(a.r0, b.r0, "reserve0 unchanged");
        assertEq(a.r1, b.r1, "reserve1 unchanged");
        assertEq(a.supply, b.supply);
        assertEq(a.poolLP, 1000);
        if (b.pool0 > b.r0) {
            assertEq(a.pool0, a.r0);
            assertEq(a.surplus0, b.pool0 - b.r0);
        } else {
            assertEq(a.pool0, b.pool0);
            assertEq(a.surplus0, 0);
        }
        if (b.pool1 > b.r1) {
            assertEq(a.pool1, a.r1);
            assertEq(a.surplus1, b.pool1 - b.r1);
        } else {
            assertEq(a.pool1, b.pool1);
            assertEq(a.surplus1, 0);
        }
    }

    /// B06 (skim) / A8 negative: a token that over-debits the Pool on transfer makes skim revert
    /// OutboundTransferMismatch with full rollback.
    function test_B06_overDebitRejectedByA8() public {
        MockOverDebitERC20 od = new MockOverDebitERC20("Over", "OVR", 18);
        MockERC20 std = new MockERC20("Std", "STD", 18);
        (address lo, address hi) =
            address(od) < address(std) ? (address(od), address(std)) : (address(std), address(od));
        AMMPool p = new AMMPool(lo, hi, surplus);
        // Seed reserves, so the Pool holds more than the surplus and the extra debit succeeds.
        od.mint(alice, 1e6);
        std.mint(alice, 1e6);
        vm.startPrank(alice);
        od.approve(address(p), MAX);
        std.approve(address(p), MAX);
        p.addLiquidity(addParams(1e6, 1e6, 0, alice, block.timestamp));
        vm.stopPrank();
        od.mint(address(p), 1000);
        od.setExtra(1);
        uint256 poolBal = od.balanceOf(address(p));
        vm.expectRevert(AMMPool.OutboundTransferMismatch.selector);
        p.skim();
        assertEq(od.balanceOf(address(p)), poolBal, "rolled back");
        assertEq(od.balanceOf(surplus), 0, "nothing sent");
        // With extra = 0 the same token is skimmed exactly.
        od.setExtra(0);
        p.skim();
        assertEq(od.balanceOf(surplus), 1000);
        assertEq(od.balanceOf(address(p)), 1e6, "balance == reserve");
    }
}
