// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {AMMMath} from "../src/libraries/AMMMath.sol";
import {MockDeficitERC20} from "./mocks/MockDeficitERC20.sol";
import {PoolStateFixture} from "./utils/PoolStateFixture.sol";

/// @notice M6: terminal pool — a reserve lowered to 0 by `sync()` while LP supply remains
///         (DECISIONS M6-1, M4-3r, ADR-023; THREAT_MODEL T25). TEST_MATRIX R15, R16, R18–R22.
///         Every revert asserts the exact error (M4-8) and full rollback (M5-6).
contract AMMPoolTerminalTest is PoolStateFixture {
    event LiquidityRemoved(
        address indexed sender, address indexed recipient, uint256 shares, uint256 amount0, uint256 amount1
    );

    bytes internal constant NO_LIQ = abi.encodeWithSelector(AMMMath.InsufficientLiquidity.selector);
    bytes internal constant BURNED = abi.encodeWithSelector(AMMPool.InsufficientLiquidityBurned.selector);
    bytes internal constant NET = abi.encodeWithSelector(AMMPool.InsufficientNetReceived.selector);

    /// @dev Bob also provides liquidity, so two LPs share the remaining asset.
    function setUp() public override {
        super.setUp();
        vm.prank(bob);
        pool.addLiquidity(500_000, 1_000_000, 0, 0, 0, bob, block.timestamp);
    }

    /// @dev Slash the whole Pool balance of `t` and sync: that reserve becomes 0.
    function _makeTerminal(MockDeficitERC20 t) internal {
        _slashPool(t, t.balanceOf(address(pool)));
        pool.sync();
    }

    function _remove(address who, uint256 shares, uint256 m0, uint256 m1) internal returns (uint256, uint256) {
        vm.prank(who);
        return pool.removeLiquidity(shares, m0, m1, carol, block.timestamp);
    }

    function _removeData(uint256 shares, uint256 m0, uint256 m1) internal view returns (bytes memory) {
        return abi.encodeCall(AMMPool.removeLiquidity, (shares, m0, m1, carol, block.timestamp));
    }

    // ------------------------------------------------------------------
    // R15: deposits and swaps refuse a terminal pool without a Panic
    // ------------------------------------------------------------------

    function _assertNoDepositOrSwap() internal {
        _expectRevertNoChange(
            alice, abi.encodeCall(AMMPool.addLiquidity, (1000, 1000, 0, 0, 0, alice, block.timestamp)), NO_LIQ
        );
        // Before the temporary non-zero-hint revert (M4-1).
        _expectRevertNoChange(
            alice, abi.encodeCall(AMMPool.addLiquidity, (1000, 1000, 100, 0, 0, alice, block.timestamp)), NO_LIQ
        );
        // Unbounded caps: still the custom error, never a division-by-zero Panic.
        _expectRevertNoChange(
            alice, abi.encodeCall(AMMPool.addLiquidity, (MAX, MAX, 0, 0, 0, alice, block.timestamp)), NO_LIQ
        );
        _expectRevertNoChange(
            bob, abi.encodeCall(AMMPool.swapExactInput, (address(t0), 1000, 0, carol, block.timestamp)), NO_LIQ
        );
        _expectRevertNoChange(
            bob, abi.encodeCall(AMMPool.swapExactInput, (address(t1), 1000, 0, carol, block.timestamp)), NO_LIQ
        );
        vm.expectRevert(AMMMath.InsufficientLiquidity.selector);
        pool.getAmountOut(address(t0), 1000);
        vm.expectRevert(AMMMath.InsufficientLiquidity.selector);
        pool.getAmountOut(address(t1), 1000);
    }

    function test_R15_token0ZeroBlocksDepositAndSwap() public {
        _makeTerminal(t0);
        _assertNoDepositOrSwap();
    }

    function test_R15_token1ZeroBlocksDepositAndSwap() public {
        _makeTerminal(t1);
        _assertNoDepositOrSwap();
    }

    /// R15 fuzz. Range: any caps in [1, MAX] with token0 or token1 at reserve 0. Always the
    /// custom error with full rollback; no Panic.
    function testFuzz_R15_depositNeverPanics(uint256 c0, uint256 c1, bool zeroToken0) public {
        c0 = bound(c0, 1, MAX);
        c1 = bound(c1, 1, MAX);
        _makeTerminal(zeroToken0 ? t0 : t1);
        _expectRevertNoChange(
            alice, abi.encodeCall(AMMPool.addLiquidity, (c0, c1, 0, 0, 0, alice, block.timestamp)), NO_LIQ
        );
    }

    // ------------------------------------------------------------------
    // R16: LPs recover the remaining asset
    // ------------------------------------------------------------------

    function _assertRecovers(bool zeroIsToken0) internal {
        _makeTerminal(zeroIsToken0 ? t0 : t1);
        (uint256 r0, uint256 r1) = _reserves();
        uint256 supply = pool.totalSupply();
        uint256 shares = pool.balanceOf(alice);
        uint256 e0 = Math.mulDiv(shares, r0, supply);
        uint256 e1 = Math.mulDiv(shares, r1, supply);
        assertTrue(zeroIsToken0 ? (e0 == 0 && e1 > 0) : (e1 == 0 && e0 > 0), "one side zero");
        Snap memory before = _snap();

        vm.expectEmit(true, true, false, true, address(pool));
        emit LiquidityRemoved(alice, carol, shares, e0, e1);
        (uint256 n0, uint256 n1) = _remove(alice, shares, e0, e1);

        Snap memory a = _snap();
        assertEq(n0, e0, "return net0");
        assertEq(n1, e1, "return net1");
        assertEq(a.carol0 - before.carol0, e0, "carol token0");
        assertEq(a.carol1 - before.carol1, e1, "carol token1");
        assertEq(a.r0, r0 - e0, "reserve0");
        assertEq(a.r1, r1 - e1, "reserve1");
        assertEq(before.pool0 - a.pool0, e0, "Pool token0 (A8 side)");
        assertEq(before.pool1 - a.pool1, e1, "Pool token1 (A8 side)");
        assertEq(a.supply, supply - shares, "LP burned");
        assertEq(a.aliceLP, 0);
        assertEq(a.poolLP, 1000, "lock untouched");

        // Bob, the other LP, recovers his proportional part too.
        uint256 bobShares = pool.balanceOf(bob);
        uint256 b0 = Math.mulDiv(bobShares, a.r0, a.supply);
        uint256 b1 = Math.mulDiv(bobShares, a.r1, a.supply);
        (uint256 m0, uint256 m1) = _remove(bob, bobShares, 0, 0);
        assertEq(m0, b0);
        assertEq(m1, b1);
        assertEq(pool.balanceOf(address(pool)), 1000, "lock untouched");
    }

    function test_R16_token0ZeroRecoversToken1() public {
        _assertRecovers(true);
    }

    function test_R16_token1ZeroRecoversToken0() public {
        _assertRecovers(false);
    }

    /// R16 fuzz. Range: shares in [1, alice's LP], token0 or token1 at reserve 0, the other
    /// reserve as seeded. Success iff the non-zero side's amount > 0 (M4-3r), else the exact
    /// error with rollback. Not covered: other non-zero reserve sizes.
    function testFuzz_R16_partialRecovery(uint256 shares, bool zeroIsToken0) public {
        _makeTerminal(zeroIsToken0 ? t0 : t1);
        shares = bound(shares, 1, pool.balanceOf(alice));
        (uint256 r0, uint256 r1) = _reserves();
        uint256 supply = pool.totalSupply();
        uint256 e = Math.mulDiv(shares, zeroIsToken0 ? r1 : r0, supply);
        if (e == 0) {
            _expectRevertNoChange(alice, _removeData(shares, 0, 0), BURNED);
            return;
        }
        (uint256 n0, uint256 n1) = _remove(alice, shares, 0, 0);
        assertEq(zeroIsToken0 ? n0 : n1, 0, "zero side pays 0");
        assertEq(zeroIsToken0 ? n1 : n0, e, "other side proportional");
        assertEq(pool.balanceOf(address(pool)), 1000, "lock untouched");
    }

    // ------------------------------------------------------------------
    // R18: slippage protection is not bypassed on either side
    // ------------------------------------------------------------------

    function test_R18_minNetOnZeroSideReverts() public {
        _makeTerminal(t0);
        uint256 shares = pool.balanceOf(alice);
        _expectRevertNoChange(alice, _removeData(shares, 1, 0), NET);
        _expectRevertNoChange(alice, _removeData(shares, MAX, 0), NET);
    }

    function test_R18_minNetOnZeroSideRevertsToken1() public {
        _makeTerminal(t1);
        uint256 shares = pool.balanceOf(alice);
        _expectRevertNoChange(alice, _removeData(shares, 0, 1), NET);
    }

    /// The non-zero side keeps the exact MIN-NET boundary: min == net succeeds, net + 1 reverts.
    function test_R18_minNetBoundaryOnNonZeroSide() public {
        _makeTerminal(t0);
        (, uint256 r1) = _reserves();
        uint256 shares = pool.balanceOf(alice);
        uint256 e1 = Math.mulDiv(shares, r1, pool.totalSupply());
        _expectRevertNoChange(alice, _removeData(shares, 0, e1 + 1), NET);
        (, uint256 n1) = _remove(alice, shares, 0, e1);
        assertEq(n1, e1);
    }

    // ------------------------------------------------------------------
    // R19: rounding to 0 against a non-zero reserve still reverts (M4-3 not loosened)
    // ------------------------------------------------------------------

    function test_R19_roundingToZeroRevertsInNormalPool() public {
        // r0 = 1.5e6 against S ≈ 2.12e6: one share pays 0 token0 although r0 > 0.
        _expectRevertNoChange(alice, _removeData(1, 0, 0), BURNED);
    }

    function test_R19_roundingToZeroRevertsInTerminalPool() public {
        _makeTerminal(t0);
        // Leave a tiny non-zero token1 reserve, so small withdrawals round it to 0.
        (, uint256 r1) = _reserves();
        _slashPool(t1, r1 - 10);
        pool.sync();
        (uint256 a0, uint256 a1) = _reserves();
        assertEq(a0, 0);
        assertEq(a1, 10);
        uint256 supply = pool.totalSupply();
        uint256 below = supply / 10 - 1; // floor(below · 10 / S) == 0
        assertEq(Math.mulDiv(below, 10, supply), 0);
        _expectRevertNoChange(alice, _removeData(below, 0, 0), BURNED);
        // One more share step makes the non-zero side pay 1: succeeds.
        uint256 enough = Math.mulDiv(supply, 1, 10, Math.Rounding.Ceil);
        (uint256 n0, uint256 n1) = _remove(alice, enough, 0, 0);
        assertEq(n0, 0);
        assertEq(n1, 1);
    }

    // ------------------------------------------------------------------
    // R20: both reserves 0
    // ------------------------------------------------------------------

    function test_R20_bothReservesZeroReverts() public {
        _slashPool(t0, t0.balanceOf(address(pool)));
        _slashPool(t1, t1.balanceOf(address(pool)));
        pool.sync();
        (uint256 r0, uint256 r1) = _reserves();
        assertEq(r0 + r1, 0);
        assertGt(pool.totalSupply(), 0);
        _expectRevertNoChange(alice, _removeData(1, 0, 0), BURNED);
        _expectRevertNoChange(alice, _removeData(pool.balanceOf(alice), 0, 0), BURNED);
        _expectRevertNoChange(
            alice, abi.encodeCall(AMMPool.addLiquidity, (1000, 1000, 0, 0, 0, alice, block.timestamp)), NO_LIQ
        );
    }

    // ------------------------------------------------------------------
    // R21: a withdrawal never pays surplus
    // ------------------------------------------------------------------

    function test_R21_terminalWithdrawalLeavesSurplus() public {
        _makeTerminal(t0);
        _donate(t0, 777); // surplus in the zero-reserve token
        _donate(t1, 999); // surplus in the other token
        (, uint256 r1) = _reserves();
        uint256 shares = pool.balanceOf(alice);
        uint256 e1 = Math.mulDiv(shares, r1, pool.totalSupply());

        (uint256 n0, uint256 n1) = _remove(alice, shares, 0, 0);
        assertEq(n0, 0, "zero-reserve token surplus not paid out");
        assertEq(n1, e1, "only the reserve-based amount");
        (uint256 a0, uint256 a1) = _reserves();
        assertEq(t0.balanceOf(address(pool)) - a0, 777, "token0 surplus unchanged");
        assertEq(t1.balanceOf(address(pool)) - a1, 999, "token1 surplus unchanged");
    }

    // ------------------------------------------------------------------
    // R22: the last redeemable LP exits; the 1,000 lock and its residual reserve remain
    // ------------------------------------------------------------------

    function test_R22_lastLPExitsTerminalPool() public {
        _makeTerminal(t0);
        _remove(alice, pool.balanceOf(alice), 0, 0);
        _remove(bob, pool.balanceOf(bob), 0, 0);

        assertEq(pool.totalSupply(), 1000, "only the lock remains");
        assertEq(pool.balanceOf(address(pool)), 1000, "lock unchanged");
        (uint256 r0, uint256 r1) = _reserves();
        assertEq(r0, 0);
        assertGt(r1, 0, "residual reserve backing the lock stays (M6-1 limitation b)");
        assertEq(t1.balanceOf(address(pool)), r1);

        // Nobody can redeem it: the Pool's LP cannot be burned, and no one else holds LP.
        vm.prank(address(pool));
        vm.expectRevert(AMMPool.LockedLiquidity.selector);
        pool.removeLiquidity(1000, 0, 0, carol, block.timestamp);
        // Nor can trading resume (M6-1 limitation a).
        _assertNoDepositOrSwap();
    }
}
