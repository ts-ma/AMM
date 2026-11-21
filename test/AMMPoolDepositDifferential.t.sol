// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Wide512} from "./utils/Wide512.sol";
import {addParams} from "./utils/AddParams.sol";

/// @notice Z06 by differential fuzzing (DECISIONS M4H-3): a later deposit over the FULL uint256
///         range of caps and caller balances, and extreme reserve ratios, is compared with an
///         independent oracle that uses only 512-bit test arithmetic (`Wide512` plus bitwise long
///         division; no OpenZeppelin `mulDiv`). The Pool must return exactly the predicted values
///         or revert with exactly the predicted error bytes, with no state change on revert.
/// @dev The oracle follows ARCHITECTURE §6.2 with t = 0 and DECISIONS M4-2 / M4H-2. Its two
///      `require`s encode claims from TEST_MATRIX Z06 that the fuzzer tries to falsify: the token1
///      branch never overflows, and the share `mulDiv` cannot overflow before another check fails.
contract AMMPoolDepositDifferentialTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant LOCK = 1000;

    MockERC20 internal t0;
    MockERC20 internal t1;
    AMMPool internal pool;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    // State of the Pool and the caller before the deposit under test.
    uint256 internal r0;
    uint256 internal r1;
    uint256 internal supply;
    uint256 internal fund0;
    uint256 internal fund1;

    struct Expected {
        bytes err; // empty = success expected
        uint256 n0;
        uint256 n1;
        uint256 shares;
    }

    // ------------------------------------------------------------------
    // Independent 512-bit oracle
    // ------------------------------------------------------------------

    /// @dev floor(x · y / d) computed from the exact 512-bit product; `overflow` when the quotient
    ///      does not fit in uint256 (i.e. hi ≥ d). Bitwise long division, independent of OZ.
    function _floorMulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (bool overflow, uint256 q) {
        (uint256 hi, uint256 lo) = Wide512.mul(x, y);
        if (hi >= d) return (true, 0);
        if (hi == 0) return (false, lo / d);
        uint256 rem = hi; // invariant: rem < d
        for (uint256 i; i < 256; ++i) {
            bool carry = rem >> 255 == 1; // the shifted remainder would exceed 2^256
            rem = (rem << 1) | ((lo >> (255 - i)) & 1);
            q <<= 1;
            if (carry || rem >= d) {
                unchecked {
                    rem -= d; // exact modulo 2^256 because the true remainder is < 2d
                }
                q |= 1;
            }
        }
    }

    function _lte512(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (bool) {
        (uint256 h1, uint256 l1) = Wide512.mul(a, b);
        (uint256 h2, uint256 l2) = Wide512.mul(c, d);
        return Wide512.lte(h1, l1, h2, l2);
    }

    function _predict(uint256 c0, uint256 c1) internal view returns (Expected memory e) {
        if (c0 == 0 || c1 == 0) {
            e.err = abi.encodeWithSelector(AMMPool.ZeroAmount.selector);
            return e;
        }
        (bool over, uint256 q) = _floorMulDiv(c0, r1, r0);
        e.n0 = c0;
        e.n1 = q;
        if (over || q > c1) {
            (bool over1, uint256 q1) = _floorMulDiv(c1, r0, r1);
            require(!over1, "claim falsified: token1 branch overflowed");
            require(q1 <= c0, "claim falsified: token1 branch exceeds cap0");
            e.n0 = q1;
            e.n1 = c1;
        }
        if (e.n0 == 0 || e.n1 == 0) {
            e.err = abi.encodeWithSelector(AMMPool.InsufficientDepositAmount.selector);
        } else if (fund0 < e.n0) {
            e.err = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, fund0, e.n0);
        } else if (fund1 < e.n1) {
            e.err = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, fund1, e.n1);
        } else {
            (bool o0, uint256 s0) = _floorMulDiv(e.n0, supply, r0);
            (bool o1, uint256 s1) = _floorMulDiv(e.n1, supply, r1);
            require(!o0 && !o1, "claim falsified: share mulDiv reachable overflow");
            e.shares = s0 < s1 ? s0 : s1;
            if (e.shares == 0) e.err = abi.encodeWithSelector(AMMPool.InsufficientShares.selector);
        }
    }

    // ------------------------------------------------------------------
    // Setup and comparison
    // ------------------------------------------------------------------

    /// @dev Fresh Pool; alice makes the initial deposit (a0, a1); bob may hold up to the whole
    ///      remaining token supply, so pulls near 2^256 are reachable.
    function _setUpPool(uint256 a0, uint256 a1, uint256 f0, uint256 f1) internal {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        pool = new AMMPool(address(t0), address(t1), makeAddr("surplusRecipient"));
        t0.mint(alice, a0);
        t1.mint(alice, a1);
        vm.startPrank(alice);
        t0.approve(address(pool), MAX);
        t1.approve(address(pool), MAX);
        pool.addLiquidity(addParams(a0, a1, 0, alice, block.timestamp));
        vm.stopPrank();

        fund0 = bound(f0, 0, MAX - t0.totalSupply());
        fund1 = bound(f1, 0, MAX - t1.totalSupply());
        t0.mint(bob, fund0);
        t1.mint(bob, fund1);
        vm.startPrank(bob);
        t0.approve(address(pool), MAX);
        t1.approve(address(pool), MAX);
        vm.stopPrank();
        (r0, r1) = pool.getReserves();
        supply = pool.totalSupply();
    }

    function _compare(uint256 c0, uint256 c1) internal {
        Expected memory e = _predict(c0, c1);
        vm.prank(bob);
        (bool ok, bytes memory ret) =
            address(pool).call(abi.encodeCall(AMMPool.addLiquidity, (addParams(c0, c1, 0, bob, block.timestamp))));
        (uint256 rr0, uint256 rr1) = pool.getReserves();

        if (e.err.length != 0) {
            assertFalse(ok, "expected a revert");
            assertEq(ret, e.err, "exact revert bytes");
            assertEq(rr0, r0, "reserve0 unchanged");
            assertEq(rr1, r1, "reserve1 unchanged");
            assertEq(pool.totalSupply(), supply, "supply unchanged");
            assertEq(t0.balanceOf(bob), fund0, "caller token0 unchanged");
            assertEq(t1.balanceOf(bob), fund1, "caller token1 unchanged");
            return;
        }
        assertTrue(ok, "expected success");
        (uint256 n0, uint256 n1, uint256 s) = abi.decode(ret, (uint256, uint256, uint256));
        assertEq(n0, e.n0, "net0");
        assertEq(n1, e.n1, "net1");
        assertEq(s, e.shares, "shares");
        assertLe(n0, c0, "L11: within cap0");
        assertLe(n1, c1, "L11: within cap1");
        assertEq(fund0 - t0.balanceOf(bob), n0, "debit0 == net0");
        assertEq(fund1 - t1.balanceOf(bob), n1, "debit1 == net1");
        assertEq(rr0, r0 + n0);
        assertEq(rr1, r1 + n1);
        assertEq(pool.totalSupply(), supply + s);
        assertEq(pool.balanceOf(address(pool)), LOCK, "lock untouched");
        // Fairness in exact 512-bit arithmetic.
        assertTrue(_lte512(s, rr0, n0, supply + s), "no free value token0");
        assertTrue(_lte512(s, rr1, n1, supply + s), "no free value token1");
        assertTrue(_lte512(r0, supply + s, rr0, supply), "no dilution token0");
        assertTrue(_lte512(r1, supply + s, rr1, supply), "no dilution token1");
    }

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------

    /// @dev Raw uint256 caps (the fuzzer's dictionary includes 0, 1, MAX and near-MAX values).
    function testFuzz_Z06_laterDepositMatchesOracle(
        uint256 a0,
        uint256 a1,
        uint256 c0,
        uint256 c1,
        uint256 f0,
        uint256 f1
    ) public {
        _setUpPool(bound(a0, 1001, type(uint128).max), bound(a1, 1001, type(uint128).max), f0, f1);
        _compare(c0, c1);
    }

    /// @dev Hand-picked corners: every combination of six extreme caps with four extreme reserve
    ///      shapes and a caller that holds the whole remaining supply.
    function test_Z06_extremeCapCorners() public {
        uint256[6] memory caps = [uint256(1), 2, MAX / 2, MAX / 2 + 1, MAX - 1, MAX];
        uint256[2][4] memory shapes = [
            [uint256(1e6), uint256(2e6)],
            [uint256(2e6), uint256(1e6)],
            [uint256(type(uint128).max), uint256(1001)],
            [uint256(1001), uint256(type(uint128).max)]
        ];
        for (uint256 k; k < 4; ++k) {
            for (uint256 i; i < 6; ++i) {
                for (uint256 j; j < 6; ++j) {
                    _setUpPool(shapes[k][0], shapes[k][1], MAX, MAX);
                    _compare(caps[i], caps[j]);
                }
            }
        }
    }
}
