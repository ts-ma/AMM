// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {addParams, addParamsOrdered} from "./utils/AddParams.sol";

/// @notice TEST_MATRIX Z10 (M10 P1, approved 2026-11-23): upper bound on the LP shares minted
///         when only swaps happen between a quote and the deposit ("仅有 swap 时的 LP 铸造数量上界").
///         Tier 0 only (first version).
///         Definitions:
///         - quote state q: recorded reserves (r0, r1), LP supply S, k_q = r0·r1;
///         - A = `amount0RequestMax`, B = `amount1RequestMax` (the depositor's request caps,
///           smallest units);
///         - between q and the deposit only swaps run (1 or 2, any direction, by another
///           account), so S is unchanged and r0'·r1' ≥ k_q (§6.5);
///         - σ' = shares actually minted by the real Pool (return value, equal to the supply
///           increase); n_i = measured nets, premise n_i ≤ cap_i (Tier 0: n_i = T_i ≤ cap_i,
///           asserted).
///         Claim: σ'²·k_q ≤ S²·A·B. Proof (real numbers, then integers):
///         σ' ≤ min(n0·S/r0', n1·S/r1') ≤ min(A·S/r0', B·S/r1') (floors, n_i ≤ cap_i), and
///         min(x, y)² ≤ x·y, so σ'² ≤ S²·A·B/(r0'·r1') ≤ S²·A·B/k_q. ∎
///         This is a bound on the share count only; it says nothing about value, and nothing
///         about non-swap changes between quote and execution (deposits, withdrawals, sync).
///         The check is independent of the Pool's code: it uses only σ', S, k_q, A, B.
///         Overflow handling: inputs bounded to [1, 2^64] (reserves ≤ about 2^66 after the swaps),
///         so σ'², S², A·B and k_q each fit in a checked uint256 (an overflow would Panic and
///         fail the run, never truncate), and the two final products are formed exactly with
///         `Math.mul512` and compared as 512-bit numbers. Under the claim σ' < 2^118, so σ'²
///         cannot overflow unless the claim is already false.
///         Valid samples: runs in which at least one swap executed and the deposit succeeded;
///         other runs are discarded with `vm.assume(false)`, so the reported `runs` count is the
///         number of valid samples. Unexpected deposit reverts fail the run.
contract AMMPoolSwapOnlyMintBoundTest is Test {
    uint256 internal constant MAX = type(uint256).max;

    address internal alice = makeAddr("alice"); // seed LP
    address internal eve = makeAddr("eve"); // swapper between quote and deposit
    address internal bob = makeAddr("bob"); // depositor
    address internal surplus = makeAddr("surplusRecipient");

    MockERC20 internal t0;
    MockERC20 internal t1;
    AMMPool internal pool;

    function _build(uint256 x0, uint256 x1) internal {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        pool = new AMMPool(address(t0), address(t1), surplus);
        address[3] memory users = [alice, eve, bob];
        for (uint256 i; i < 3; ++i) {
            t0.mint(users[i], 2 ** 70);
            t1.mint(users[i], 2 ** 70);
            vm.startPrank(users[i]);
            t0.approve(address(pool), MAX);
            t1.approve(address(pool), MAX);
            vm.stopPrank();
        }
        vm.prank(alice);
        pool.addLiquidity(addParams(x0, x1, 0, alice, block.timestamp));
    }

    /// @return executed Whether the swap ran (a zero-output swap reverts and changes nothing).
    function _swap(bool zeroForOne, uint256 amount) internal returns (bool executed) {
        address tokenIn = zeroForOne ? address(t0) : address(t1);
        vm.prank(eve);
        try pool.swapExactInput(tokenIn, amount, 0, eve, block.timestamp) {
            executed = true;
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), AMMPool.InsufficientOutputAmount.selector, "unexpected swap revert");
        }
    }

    function _geq512(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (bool) {
        (uint256 h1, uint256 l1) = Math.mul512(a, b);
        (uint256 h2, uint256 l2) = Math.mul512(c, d);
        return h1 > h2 || (h1 == h2 && l1 >= l2);
    }

    struct Q {
        uint256 s;
        uint256 kq;
    }

    /// @dev Fuzz inputs, packed to stay within the stack limit.
    struct In {
        uint256 x0; // initial token0, [1e3, 2^64]
        uint256 x1; // initial token1, [1e3, 2^64]
        uint256 a; // A, [1, 2^64]
        uint256 b; // B, [1, 2^64]
        bool token1First;
        bool dir1; // first swap: true = token0 in
        uint256 amt1; // [1, 2^64]
        bool second; // whether a second swap runs
        bool dir2;
        uint256 amt2; // [1, 2^64]
    }

    function testFuzz_Z10_swapOnlyMintUpperBound(In memory f) public {
        f.x0 = bound(f.x0, 1e3, 2 ** 64);
        f.x1 = bound(f.x1, 1e3, 2 ** 64);
        vm.assume(f.x0 * f.x1 > 1001 * 1001);
        _build(f.x0, f.x1);

        // Quote state.
        Q memory q;
        (uint256 r0, uint256 r1) = pool.getReserves();
        q.s = pool.totalSupply();
        q.kq = r0 * r1;

        // Only swaps between the quote and the deposit.
        bool any = _swap(f.dir1, bound(f.amt1, 1, 2 ** 64));
        if (f.second) any = _swap(f.dir2, bound(f.amt2, 1, 2 ** 64)) || any;
        vm.assume(any);
        assertEq(pool.totalSupply(), q.s, "swaps do not change S");

        f.a = bound(f.a, 1, 2 ** 64);
        f.b = bound(f.b, 1, 2 ** 64);
        _depositAndCheck(f, q);
    }

    function _depositAndCheck(In memory f, Q memory q) internal {
        vm.prank(bob);
        try pool.addLiquidity(addParamsOrdered(f.a, f.b, 0, bob, block.timestamp, f.token1First)) returns (
            uint256 n0, uint256 n1, uint256 shares
        ) {
            assertEq(pool.totalSupply(), q.s + shares, "sigma' read from the real Pool");
            assertLe(n0, f.a, "premise n0 <= A");
            assertLe(n1, f.b, "premise n1 <= B");
            // σ'²·k_q ≤ S²·A·B, exact.
            assertTrue(_geq512(q.s * q.s, f.a * f.b, shares * shares, q.kq), "sigma'^2 * k_q > S^2 * A * B");
        } catch (bytes memory reason) {
            bytes4 sel = bytes4(reason);
            assertTrue(
                sel == AMMPool.InsufficientDepositAmount.selector || sel == AMMPool.InsufficientShares.selector,
                "unexpected deposit revert"
            );
            vm.assume(false); // not a valid sample
        }
    }
}
