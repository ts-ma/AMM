// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {IAMMPool} from "../src/interfaces/IAMMPool.sol";
import {MockFeeERC20} from "./mocks/MockFeeERC20.sol";
import {MulDiv512} from "./utils/MulDiv512.sol";
import {addParams, addParamsOrdered} from "./utils/AddParams.sol";

/// @notice F1-T7: `minShares` protects a depositor whose share quote was taken BEFORE the Pool
///         state changed (THREAT_MODEL T4; DECISIONS M3-4, M4-2). Complements L13b, where the
///         quote was taken after the inflation and so could not protect.
///
///         Scenario (the approved T7 scenario, L13b channel A3): alice makes the initial deposit
///         (1e6, 1e6); bob takes a quote for the deposit caps (1e21, max), token0 first; alice
///         then donates D = 1e25 of each token into the reserves through two deposits of a fee
///         mock with a bonus (an unsupported token behaviour: the bonus is minted to the Pool
///         inside its own `transferFrom` and is measured as net); then bob's deposit executes
///         with unchanged parameters. `maxDebit` and `maxExcess` are unbounded, so only
///         `minShares` can make bob's deposit fail.
///
///         Expected values (independent integer Python model of the same steps):
///         - quote state: r = (1e6, 1e6), S = 1e6; bob's net (1e21, 1e21); q_before = 1e21;
///         - donation 1 (caps (1, 1), token1 first, token0 bonus D): net (D + 1, 1), σ = 1;
///         - donation 2 (caps (9,999,990,000,009,999,992, max), token1 bonus D): net
///           (9,999,990,000,009,999,992, D + 1), σ = 1;
///         - changed state: r = (10,000,009,999,990,000,010,999,993,
///           10,000,000,000,000,000,001,000,002), S = 1,000,002;
///         - bob at the changed state: net (1e21, 999,999,000,001,999,996,000); q_after = 100.
///         So 0 < q_after < q_before. From the same changed state: minShares = q_before reverts
///         `InsufficientShares` with full rollback; minShares = q_after succeeds and mints exactly
///         q_after; minShares = q_after + 1 reverts.
///         Not claimed: that a fresh quote makes the deposit fair. The re-quoted deposit succeeds,
///         but its value loss is the subject of L13b and F1-T6.
contract AMMPoolF1QuoteProtectionTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant A = 1e6;
    uint256 internal constant D = 1e25;
    uint256 internal constant W = 1e21;
    uint256 internal constant Q_BEFORE = 1e21;
    uint256 internal constant Q_AFTER = 100;
    MockFeeERC20.Path internal constant PULL = MockFeeERC20.Path.TransferFrom;

    address internal alice = makeAddr("alice"); // initial LP and donor
    address internal bob = makeAddr("bob"); // quoted depositor
    address internal surplusRecipient = makeAddr("surplusRecipient");

    AMMPool internal p;
    MockFeeERC20 internal f0;
    MockFeeERC20 internal f1;

    function setUp() public {
        deployCodeTo("MockFeeERC20.sol:MockFeeERC20", abi.encode("T0", "T0", uint8(18)), address(0x71000));
        deployCodeTo(
            "MockFeeERC20.sol:MockFeeERC20", abi.encode("T1", "T1", uint8(18)), address(type(uint160).max - 0x6000)
        );
        f0 = MockFeeERC20(address(0x71000));
        f1 = MockFeeERC20(address(type(uint160).max - 0x6000));
        p = new AMMPool(address(f0), address(f1), surplusRecipient);
        address[2] memory users = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            f0.mint(users[i], 1e27);
            f1.mint(users[i], 1e27);
            vm.startPrank(users[i]);
            f0.approve(address(p), MAX);
            f1.approve(address(p), MAX);
            vm.stopPrank();
        }
        vm.prank(alice);
        p.addLiquidity(addParams(A, A, 0, alice, block.timestamp));
    }

    function _bobParams(uint256 minShares) internal view returns (IAMMPool.AddLiquidityParams memory) {
        return addParams(W, MAX, minShares, bob, block.timestamp);
    }

    /// @dev Share quote from the documented rule (step 2, σ = min floor(n_i·S/r_i)), MulDiv512
    ///      only, for Tier 0 behaviour of bob's own transfers (no bonus is active for them).
    function _quote() internal view returns (uint256 q) {
        (uint256 r0, uint256 r1) = p.getReserves();
        uint256 S = p.totalSupply();
        (bool over, uint256 t1) = MulDiv512.floorMulDiv(W, r1, r0);
        uint256 t0 = W;
        if (over) {
            // token1 cap (max) binds only if floor(W·r1/r0) does not fit
            (, t0) = MulDiv512.floorMulDiv(MAX, r0, r1);
            t1 = MAX;
        }
        (, uint256 s0) = MulDiv512.floorMulDiv(t0, S, r0);
        (, uint256 s1) = MulDiv512.floorMulDiv(t1, S, r1);
        q = s0 < s1 ? s0 : s1;
    }

    /// @dev The two bonus donations of L13b (A3), by alice.
    function _donate() internal {
        f0.setBonus(PULL, D);
        vm.prank(alice);
        p.addLiquidity(addParamsOrdered(1, 1, 0, alice, block.timestamp, true));
        f0.setBonus(PULL, 0);
        f1.setBonus(PULL, D);
        vm.prank(alice);
        p.addLiquidity(addParams(9_999_990_000_009_999_992, MAX, 0, alice, block.timestamp));
        f1.setBonus(PULL, 0);
    }

    struct State {
        uint256 r0;
        uint256 r1;
        uint256 lpSupply;
        uint256 bobLP;
        uint256 aliceLP;
        uint256 poolLP;
        uint256 pool0;
        uint256 pool1;
        uint256 bob0;
        uint256 bob1;
        uint256 supply0;
        uint256 supply1;
    }

    function _state() internal view returns (State memory s) {
        (s.r0, s.r1) = p.getReserves();
        s.lpSupply = p.totalSupply();
        s.bobLP = p.balanceOf(bob);
        s.aliceLP = p.balanceOf(alice);
        s.poolLP = p.balanceOf(address(p));
        s.pool0 = f0.balanceOf(address(p));
        s.pool1 = f1.balanceOf(address(p));
        s.bob0 = f0.balanceOf(bob);
        s.bob1 = f1.balanceOf(bob);
        s.supply0 = f0.totalSupply();
        s.supply1 = f1.totalSupply();
    }

    function _assertSame(State memory x, State memory y) internal pure {
        assertEq(x.r0, y.r0, "reserve0");
        assertEq(x.r1, y.r1, "reserve1");
        assertEq(x.lpSupply, y.lpSupply, "LP totalSupply");
        assertEq(x.bobLP, y.bobLP, "bob LP");
        assertEq(x.aliceLP, y.aliceLP, "alice LP");
        assertEq(x.poolLP, y.poolLP, "Pool LP (lock)");
        assertEq(x.pool0, y.pool0, "Pool token0");
        assertEq(x.pool1, y.pool1, "Pool token1");
        assertEq(x.bob0, y.bob0, "bob token0");
        assertEq(x.bob1, y.bob1, "bob token1");
        assertEq(x.supply0, y.supply0, "token0 totalSupply");
        assertEq(x.supply1, y.supply1, "token1 totalSupply");
    }

    function _expectInsufficientShares(uint256 minShares) internal {
        State memory pre = _state();
        vm.prank(bob);
        (bool ok, bytes memory ret) = address(p).call(abi.encodeCall(AMMPool.addLiquidity, (_bobParams(minShares))));
        assertFalse(ok, "deposit must revert");
        assertEq(ret, abi.encodePacked(AMMPool.InsufficientShares.selector), "exact revert data");
        _assertSame(pre, _state());
    }

    function test_F1T7_quoteBeforeStateChange_minSharesBlocksStaleQuote() public {
        // Quote state.
        (uint256 r0, uint256 r1) = p.getReserves();
        assertEq(r0, A);
        assertEq(r1, A);
        assertEq(p.totalSupply(), A);
        uint256 qBefore = _quote();
        assertEq(qBefore, Q_BEFORE, "q_before (model)");
        uint256 snap = vm.snapshotState();

        // The quoted deposit succeeds with minShares = q_before at the quote state.
        vm.prank(bob);
        (uint256 n0, uint256 n1, uint256 sh) = p.addLiquidity(_bobParams(qBefore));
        assertEq(n0, W);
        assertEq(n1, W);
        assertEq(sh, Q_BEFORE, "mints q_before");

        // From the same snapshot: the state changes before bob's deposit executes.
        vm.revertToState(snap);
        _donate();
        (r0, r1) = p.getReserves();
        assertEq(r0, 10_000_009_999_990_000_010_999_993, "changed reserve0 (model)");
        assertEq(r1, 10_000_000_000_000_000_001_000_002, "changed reserve1 (model)");
        assertEq(p.totalSupply(), 1_000_002, "changed S (model)");
        uint256 qAfter = _quote();
        assertEq(qAfter, Q_AFTER, "q_after (model)");
        assertGt(qAfter, 0);
        assertLt(qAfter, qBefore);
        uint256 snap2 = vm.snapshotState();

        // Boundary 1: the stale quote blocks the deposit, full rollback.
        _expectInsufficientShares(qBefore);

        // Boundary 2, same changed state: the fresh quote succeeds and mints exactly q_after.
        vm.revertToState(snap2);
        _expectInsufficientShares(qAfter + 1);
        vm.revertToState(snap2);
        State memory pre = _state();
        vm.prank(bob);
        (n0, n1, sh) = p.addLiquidity(_bobParams(qAfter));
        assertEq(sh, Q_AFTER, "mints exactly q_after");
        assertEq(n0, W, "net0");
        assertEq(n1, 999_999_000_001_999_996_000, "net1 (model)");
        State memory post = _state();
        assertEq(post.bobLP - pre.bobLP, Q_AFTER, "bob LP");
        assertEq(post.lpSupply - pre.lpSupply, Q_AFTER, "LP supply");
        assertEq(post.r0 - pre.r0, n0, "reserve0 += net0");
        assertEq(post.r1 - pre.r1, n1, "reserve1 += net1");
    }
}
