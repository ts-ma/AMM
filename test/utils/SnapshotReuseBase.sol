// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test, Vm} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AMMPool} from "../../src/AMMPool.sol";
import {IAMMPool} from "../../src/interfaces/IAMMPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFeeERC20} from "../mocks/MockFeeERC20.sol";
import {addParams} from "./AddParams.sol";

/// Shared fixture for the later-deposit snapshot reuse (DECISIONS M11-4; ported from experiment
/// 1, TEST_MATRIX §14.9). Only the public `AMMPool` ABI is used, so the behaviour assertions also
/// held unchanged on the 04eb336 baseline.
///   ORD  `MockERC20` pair, Pool seeded by alice with (1000e18, 2000e18); alice is payer and
///        recipient; caps (1e18, 2e18), maxDebit (1e18, 2e18) = the exact debits, maxExcess MAX,
///        minShares 0 (the TEST_MATRIX §14.8 ORD scenario).
///   L46  report §5.2 example: `MockFeeERC20` pair, reserves (10,000, 20,000), S = 14,142,
///        token1 taxed 10 % on every `transferFrom`; bob is payer and recipient, caps
///        (1,000, 2,500), minShares 1,272. Taxed second (token0 first): maxDebit (1,000, 2,000),
///        maxExcess (100, 1). Taxed first (`token1First`, re-plan lowers token0 to 900):
///        maxDebit (900, 2,000), maxExcess (0, 1). All bounds equal the actual values.
///   INIT empty ORD-token Pool; initial deposit (1000e18, 2000e18) by alice (control).
abstract contract SnapshotReuseBase is Test {
    uint256 internal constant MAX = type(uint256).max;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal surplus = makeAddr("surplusRecipient");

    MockERC20 internal o0;
    MockERC20 internal o1;
    AMMPool internal ord; // seeded ORD Pool
    AMMPool internal fresh; // empty ORD-token Pool (initial-deposit control)

    MockFeeERC20 internal f0;
    MockFeeERC20 internal f1;
    AMMPool internal l46; // seeded L46 Pool

    function setUp() public virtual {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (o0, o1) = address(a) < address(b) ? (a, b) : (b, a);
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

        MockFeeERC20 c = new MockFeeERC20("C", "C", 18);
        MockFeeERC20 d = new MockFeeERC20("D", "D", 18);
        (f0, f1) = address(c) < address(d) ? (c, d) : (d, c);
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
    }

    // ------------------------------------------------------------------
    // Scenario parameters
    // ------------------------------------------------------------------

    function _ordParams(bool token1First) internal view returns (IAMMPool.AddLiquidityParams memory) {
        return IAMMPool.AddLiquidityParams(1e18, 2e18, 1e18, 2e18, MAX, MAX, 0, alice, block.timestamp, token1First);
    }

    function _l46Params(bool taxedFirst) internal view returns (IAMMPool.AddLiquidityParams memory) {
        if (taxedFirst) {
            return IAMMPool.AddLiquidityParams(1_000, 2_500, 900, 2_000, 0, 1, 1_272, bob, block.timestamp, true);
        }
        return IAMMPool.AddLiquidityParams(1_000, 2_500, 1_000, 2_000, 100, 1, 1_272, bob, block.timestamp, false);
    }

    function _initParams() internal view returns (IAMMPool.AddLiquidityParams memory) {
        return IAMMPool.AddLiquidityParams(1000e18, 2000e18, MAX, MAX, MAX, MAX, 0, alice, block.timestamp, false);
    }

    // ------------------------------------------------------------------
    // Call classification (outside any gas interval)
    // ------------------------------------------------------------------

    /// @dev Calls made by `pool` to `token`, by selector; for `balanceOf`, split by the account
    ///      argument: the Pool itself, the payer, or anything else.
    struct TokenCalls {
        uint256 poolReads; // balanceOf(pool) called by the Pool
        uint256 payerReads; // balanceOf(payer) called by the Pool
        uint256 otherReads; // balanceOf(other account) called by the Pool
        uint256 transferFroms; // transferFrom called by the Pool
        uint256 otherCalls; // any other call to the token (any caller) or any caller other than the Pool
    }

    function _classify(Vm.AccountAccess[] memory acc, address token, address pool, address payer)
        internal
        pure
        returns (TokenCalls memory c)
    {
        for (uint256 i; i < acc.length; ++i) {
            Vm.AccountAccess memory a = acc[i];
            if (a.account != token) continue;
            if (a.kind != VmSafe.AccountAccessKind.Call && a.kind != VmSafe.AccountAccessKind.StaticCall) continue;
            bytes4 sel = bytes4(a.data);
            if (a.accessor != pool) {
                ++c.otherCalls;
            } else if (sel == IERC20.balanceOf.selector) {
                address who = abi.decode(_args(a.data), (address));
                if (who == pool) ++c.poolReads;
                else if (who == payer) ++c.payerReads;
                else ++c.otherReads;
            } else if (sel == IERC20.transferFrom.selector) {
                ++c.transferFroms;
            } else {
                ++c.otherCalls;
            }
        }
    }

    function _args(bytes memory data) private pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[i + 4];
        }
    }

    /// @dev One recorded, unmeasured deposit; returns the per-token classification.
    function _record(AMMPool pool, IAMMPool.AddLiquidityParams memory p, address payer)
        internal
        returns (TokenCalls memory c0, TokenCalls memory c1)
    {
        address t0 = pool.token0();
        address t1 = pool.token1();
        vm.startStateDiffRecording();
        vm.prank(payer);
        pool.addLiquidity(p);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        c0 = _classify(acc, t0, address(pool), payer);
        c1 = _classify(acc, t1, address(pool), payer);
    }
}
