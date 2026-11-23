// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {IAMMPool} from "../src/interfaces/IAMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {addParams} from "./utils/AddParams.sol";

/// @notice M10 item 1 (TEST_MATRIX L44): setting `maxExcess` for exact-delivery (Tier 0) tokens.
///         Floor-shares (M8-14) leave an unmatched `u_i = n_i − ceil(σ·r_i/S) ≥ 0` even for
///         Tier 0, so `maxExcess_i = 0` can make an honest deposit revert
///         `ExcessContributionTooHigh` (safe failure, no loss). F1-T1 proves `u_i < X_i` with
///         `X_i = r_i/S + r_i/r_j` (r, S at execution). The smallest integer setting that is
///         guaranteed never to reject a Tier 0 deposit for its excess is therefore
///         `M_i = ceil(X_i) − 1 = floor((r_i·(r_j + S) − 1) / (S·r_j))`.
///         Scope: Tier 0 only (no re-plan, `n_i = T_i ≤ cap_i`), `σ` not saturated, `M_i`
///         computed from the state at execution. If the state changes between a quote and the
///         execution, a value computed at the quote may be too small; the deposit then reverts
///         (safe), it never mints differently. Taxed tokens: the bound does not apply.
contract AMMPoolMaxExcessTier0Test is Test {
    uint256 internal constant MAX = type(uint256).max;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal surplus = makeAddr("surplusRecipient");

    MockERC20 internal t0;
    MockERC20 internal t1;
    AMMPool internal pool;

    function _build(uint256 x0, uint256 x1) internal {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        pool = new AMMPool(address(t0), address(t1), surplus);
        address[2] memory users = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            t0.mint(users[i], 2 ** 110);
            t1.mint(users[i], 2 ** 110);
            vm.startPrank(users[i]);
            t0.approve(address(pool), MAX);
            t1.approve(address(pool), MAX);
            vm.stopPrank();
        }
        vm.prank(alice);
        pool.addLiquidity(addParams(x0, x1, 0, alice, block.timestamp));
    }

    function _params(uint256 a0, uint256 a1, uint256 m0, uint256 m1, bool token1First)
        internal
        view
        returns (IAMMPool.AddLiquidityParams memory)
    {
        return IAMMPool.AddLiquidityParams({
            amount0RequestMax: a0,
            amount1RequestMax: a1,
            maxDebit0: MAX,
            maxDebit1: MAX,
            maxExcess0: m0,
            maxExcess1: m1,
            minShares: 0,
            recipient: bob,
            deadline: block.timestamp,
            token1First: token1First
        });
    }

    /// @dev M_i = floor((r_i·(r_j + S) − 1)/(S·r_j)); products fit in uint256 for r, S < 2^120.
    function _safeMaxExcess() internal view returns (uint256 m0, uint256 m1) {
        (uint256 r0, uint256 r1) = pool.getReserves();
        uint256 s = pool.totalSupply();
        m0 = (r0 * (r1 + s) - 1) / (s * r1);
        m1 = (r1 * (r0 + s) - 1) / (s * r0);
    }

    /// @dev Worked example from the M10 review model (integer Python model, not the Solidity
    ///      code): r = (623,347,348,957, 884,107,996,871), S = isqrt(r0·r1) = 742,365,392,540,
    ///      caps (820,096,754, 67,760,437) → σ = 56,896,898, u = (0, 1).
    ///      `maxExcess = (0, 0)` reverts with no state change; `M = (1, 2)` succeeds.
    function test_L44_tier0ZeroMaxExcessRevertsSafeSettingPasses() public {
        _build(623_347_348_957, 884_107_996_871);
        assertEq(pool.totalSupply(), 742_365_392_540, "S = isqrt(r0*r1)");
        (uint256 m0, uint256 m1) = _safeMaxExcess();
        assertEq(m0, 1, "M0");
        assertEq(m1, 2, "M1");

        (uint256 r0, uint256 r1) = pool.getReserves();
        uint256 bob0 = t0.balanceOf(bob);
        uint256 bob1 = t1.balanceOf(bob);
        vm.expectRevert(AMMPool.ExcessContributionTooHigh.selector);
        vm.prank(bob);
        pool.addLiquidity(_params(820_096_754, 67_760_437, 0, 0, false));
        (uint256 e0, uint256 e1) = pool.getReserves();
        assertEq(e0, r0);
        assertEq(e1, r1);
        assertEq(t0.balanceOf(bob), bob0, "no token0 moved");
        assertEq(t1.balanceOf(bob), bob1, "no token1 moved");
        assertEq(pool.totalSupply(), 742_365_392_540, "no shares minted");

        // maxExcess1 = u1 = 1 is the exact boundary (F1-T1 style); M = (1, 2) passes as well.
        vm.prank(bob);
        (uint256 n0, uint256 n1, uint256 shares) = pool.addLiquidity(_params(820_096_754, 67_760_437, m0, m1, false));
        assertEq(shares, 56_896_898, "sigma");
        assertEq(n0 - (shares * r0 + 742_365_392_540 - 1) / 742_365_392_540, 0, "u0 = 0");
        assertEq(n1 - (shares * r1 + 742_365_392_540 - 1) / 742_365_392_540, 1, "u1 = 1");
    }

    /// @dev Fuzz (Tier 0): with `maxExcess_i = M_i` computed just before the deposit, the deposit
    ///      never reverts `ExcessContributionTooHigh`, and the measured `u_i ≤ M_i`.
    ///      Range: initial amounts [1e3, 2^100] (geometric mean > 1000), optional swap
    ///      [1, 2^100], caps [1, 2^100], either pull order. Accepted reverts:
    ///      `InsufficientDepositAmount`, `InsufficientShares` (rounding to 0); any other fails.
    function testFuzz_L44_safeMaxExcessNeverRejectsTier0(
        uint256 x0,
        uint256 x1,
        uint256 swapAmt,
        uint8 swapDir,
        uint256 a0,
        uint256 a1,
        bool token1First
    ) public {
        x0 = bound(x0, 1e3, 2 ** 100);
        x1 = bound(x1, 1e3, 2 ** 100);
        vm.assume(x0 * x1 > 1001 * 1001);
        _build(x0, x1);
        swapDir = swapDir % 3;
        if (swapDir != 0) {
            address tokenIn = swapDir == 1 ? address(t0) : address(t1);
            vm.prank(alice);
            try pool.swapExactInput(tokenIn, bound(swapAmt, 1, 2 ** 100), 0, alice, block.timestamp) {} catch {}
        }
        a0 = bound(a0, 1, 2 ** 100);
        a1 = bound(a1, 1, 2 ** 100);
        (uint256 m0, uint256 m1) = _safeMaxExcess();
        (uint256 r0, uint256 r1) = pool.getReserves();
        uint256 s = pool.totalSupply();

        vm.prank(bob);
        try pool.addLiquidity(_params(a0, a1, m0, m1, token1First)) returns (uint256 n0, uint256 n1, uint256 shares) {
            assertLe(n0 - (shares * r0 + s - 1) / s, m0, "u0 <= M0");
            assertLe(n1 - (shares * r1 + s - 1) / s, m1, "u1 <= M1");
        } catch (bytes memory reason) {
            bytes4 sel = bytes4(reason);
            assertTrue(
                sel == AMMPool.InsufficientDepositAmount.selector || sel == AMMPool.InsufficientShares.selector,
                "unexpected revert (ExcessContributionTooHigh would contradict u < X)"
            );
        }
    }
}
