// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFailingERC20} from "./mocks/MockFailingERC20.sol";
import {addParams, addParamsOrdered} from "./utils/AddParams.sol";

/// @notice M4: Tier 0 later deposits (ARCHITECTURE §6.2 with t = 0; DECISIONS M4-1, M4-2).
///         TEST_MATRIX L03, L04, L06, L08, L11, L12, L14, L26 (M8: measured net), B01 (later path),
///         Z06 (step-2 target), Z07 (deposit business boundaries). L27 retired in M8.
///         Every revert asserts the exact error (DECISIONS M4-8).
contract AMMPoolDepositTest is Test {
    uint256 internal constant LOCK = 1000;
    uint256 internal constant FUND = 1e30;

    MockERC20 internal t0;
    MockERC20 internal t1;
    AMMPool internal pool;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal recipient = makeAddr("surplusRecipient");

    function setUp() public {
        MockERC20 a = new MockERC20("Token A", "TKA", 18);
        MockERC20 b = new MockERC20("Token B", "TKB", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        pool = _newPool(address(t0), address(t1));
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Deploys a Pool for two (unsorted) tokens; funds alice, bob and carol with FUND of
    ///      each token and unlimited approval.
    function _newPool(address x, address y) internal returns (AMMPool p) {
        (address lo, address hi) = x < y ? (x, y) : (y, x);
        p = new AMMPool(lo, hi, recipient);
        address[3] memory users = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            MockERC20(lo).mint(users[i], FUND);
            MockERC20(hi).mint(users[i], FUND);
            vm.startPrank(users[i]);
            IERC20(lo).approve(address(p), type(uint256).max);
            IERC20(hi).approve(address(p), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _add(AMMPool p, address from, uint256 a0, uint256 a1, uint256 minShares, address to)
        internal
        returns (uint256 n0, uint256 n1, uint256 s)
    {
        vm.prank(from);
        return p.addLiquidity(addParams(a0, a1, minShares, to, block.timestamp));
    }

    /// @dev Independent reference for §6.2 with t = 0 (plain arithmetic; callers keep products
    ///      below 2^256). Returns zero targets when step 2 rounds a side to 0.
    function _expected(uint256 r0, uint256 r1, uint256 s, uint256 c0, uint256 c1)
        internal
        pure
        returns (uint256 x0, uint256 x1, uint256 shares)
    {
        x0 = c0;
        x1 = c0 * r1 / r0;
        if (x1 > c1) {
            x0 = c1 * r0 / r1;
            x1 = c1;
        }
        if (x0 == 0 || x1 == 0) return (x0, x1, 0);
        uint256 s0 = x0 * s / r0;
        uint256 s1 = x1 * s / r1;
        shares = s0 < s1 ? s0 : s1;
    }

    struct Snap {
        uint256 r0;
        uint256 r1;
        uint256 supply;
        uint256 poolLP;
        uint256 callerLP;
        uint256 pool0;
        uint256 pool1;
        uint256 caller0;
        uint256 caller1;
    }

    function _snap(AMMPool p, address caller) internal view returns (Snap memory s) {
        (s.r0, s.r1) = p.getReserves();
        s.supply = p.totalSupply();
        s.poolLP = p.balanceOf(address(p));
        s.callerLP = p.balanceOf(caller);
        s.pool0 = IERC20(p.token0()).balanceOf(address(p));
        s.pool1 = IERC20(p.token1()).balanceOf(address(p));
        s.caller0 = IERC20(p.token0()).balanceOf(caller);
        s.caller1 = IERC20(p.token1()).balanceOf(caller);
    }

    function _assertSame(Snap memory a, Snap memory b) internal pure {
        assertEq(a.r0, b.r0, "reserve0");
        assertEq(a.r1, b.r1, "reserve1");
        assertEq(a.supply, b.supply, "LP totalSupply");
        assertEq(a.poolLP, b.poolLP, "Pool LP (lock)");
        assertEq(a.callerLP, b.callerLP, "caller LP");
        assertEq(a.pool0, b.pool0, "Pool token0");
        assertEq(a.pool1, b.pool1, "Pool token1");
        assertEq(a.caller0, b.caller0, "caller token0");
        assertEq(a.caller1, b.caller1, "caller token1");
    }

    // ------------------------------------------------------------------
    // L03 — later deposit pulls only the optimal amounts
    // ------------------------------------------------------------------

    /// @dev The worked example of the M4 brief: r = (1000, 2000), S = 1414, caps (100, 300).
    function test_L03_workedExampleSmallUnits() public {
        _add(pool, alice, 1000, 2000, 0, alice);
        assertEq(pool.totalSupply(), 1414);
        Snap memory b = _snap(pool, bob);

        (uint256 n0, uint256 n1, uint256 s) = _add(pool, bob, 100, 300, 0, bob);

        assertEq(n0, 100);
        assertEq(n1, 200, "excess token1 cap not pulled");
        assertEq(s, 141, "min(100*1414/1000, 200*1414/2000)");
        assertEq(b.caller0 - t0.balanceOf(bob), 100, "bob debited exactly T0");
        assertEq(b.caller1 - t1.balanceOf(bob), 200, "bob debited exactly T1");
        (uint256 r0, uint256 r1) = pool.getReserves();
        assertEq(r0, 1100);
        assertEq(r1, 2200);
        assertEq(pool.balanceOf(bob), 141);
        assertEq(pool.totalSupply(), 1414 + 141);
        assertEq(pool.balanceOf(address(pool)), LOCK, "lock untouched");
    }

    /// @dev token0 cap binds (n1 <= cap1): T = (cap0, cap0 * r1 / r0).
    function test_L03_token0CapBinds() public {
        _add(pool, alice, 1000e18, 2000e18, 0, alice);
        (uint256 n0, uint256 n1,) = _add(pool, bob, 100e18, 300e18, 0, bob);
        assertEq(n0, 100e18);
        assertEq(n1, 200e18);
    }

    /// @dev token1 cap binds (n1 > cap1): T = (cap1 * r0 / r1, cap1).
    function test_L03_token1CapBinds() public {
        _add(pool, alice, 1000e18, 2000e18, 0, alice);
        (uint256 n0, uint256 n1,) = _add(pool, bob, 100e18, 150e18, 0, bob);
        assertEq(n0, 75e18);
        assertEq(n1, 150e18);
    }

    /// @dev Flooring in step 2 (3 * 2000 / 1001 = 5.99 → 5) and in the share formula.
    function test_L03_roundingDustStaysWithLPs() public {
        _add(pool, alice, 1001, 2000, 0, alice);
        uint256 s0 = pool.totalSupply(); // floor(sqrt(2,002,000)) = 1414
        assertEq(s0, 1414);
        (uint256 n0, uint256 n1, uint256 s) = _add(pool, bob, 3, 100, 0, bob);
        assertEq(n0, 3, "T0 = cap0");
        assertEq(n1, 5, "T1 = floor(3 * 2000 / 1001) = floor(5.99)");
        assertEq(s, 3, "min(floor(3*1414/1001) = 4, floor(5*1414/2000) = 3)");
        // Dust: bob's claim (3/1417 of each reserve) is worth less than he paid; the
        // difference stays with all LPs.
        (uint256 r0, uint256 r1) = pool.getReserves();
        assertLt(s * r0, n0 * pool.totalSupply(), "claim0 < paid0");
        assertLt(s * r1, n1 * pool.totalSupply(), "claim1 < paid1");
    }

    // ------------------------------------------------------------------
    // L04 — several LPs receive shares proportional to their contributions
    // ------------------------------------------------------------------

    function test_L04_sharesProportionalToContributions() public {
        _add(pool, alice, 1000e18, 2000e18, 0, alice);
        uint256 s0 = pool.totalSupply();
        (,, uint256 sb) = _add(pool, bob, 100e18, 200e18, 0, bob);
        assertEq(sb, s0 / 10, "bob contributed 10% of reserves");
        uint256 s1 = pool.totalSupply();
        (,, uint256 sc) = _add(pool, carol, 50e18, 100e18, 0, carol);
        assertEq(sc, s1 * 50e18 / 1100e18, "carol: exact floor formula");
        // bob contributed twice carol's amounts; the shares differ only by rounding.
        assertApproxEqAbs(sb, 2 * sc, 2);
        assertEq(pool.totalSupply(), LOCK + pool.balanceOf(alice) + sb + sc);
    }

    /// @dev Fairness fuzz (L04, L11, L12): random initial reserves and caps.
    ///      Success: nets == independent reference T; debit == T <= caps (L11); caller balances
    ///      never increase (L12); shares == reference; the depositor's new claim is worth no more
    ///      than it paid on either side; existing LPs' per-share reserves never decrease.
    ///      Failure: exactly the specified business error, with no state change.
    function testFuzz_L04_L11_L12_laterDepositFairness(uint256 a0, uint256 a1, uint256 c0, uint256 c1) public {
        a0 = bound(a0, 1e4, 1e29);
        a1 = bound(a1, 1e4, 1e29);
        c0 = bound(c0, 1, 1e29);
        c1 = bound(c1, 1, 1e29);
        _add(pool, alice, a0, a1, 0, alice);
        Snap memory b = _snap(pool, bob);
        (uint256 x0, uint256 x1, uint256 xs) = _expected(b.r0, b.r1, b.supply, c0, c1);

        if (x0 == 0 || x1 == 0 || xs == 0) {
            vm.expectRevert(
                x0 == 0 || x1 == 0 ? AMMPool.InsufficientDepositAmount.selector : AMMPool.InsufficientShares.selector
            );
            vm.prank(bob);
            pool.addLiquidity(addParams(c0, c1, 0, bob, block.timestamp));
            _assertSame(_snap(pool, bob), b);
            return;
        }

        (uint256 n0, uint256 n1, uint256 s) = _add(pool, bob, c0, c1, 0, bob);
        assertEq(n0, x0);
        assertEq(n1, x1);
        assertEq(s, xs);
        Snap memory a = _snap(pool, bob);
        assertEq(b.caller0 - a.caller0, n0, "L11 debit == net (Tier 0)");
        assertEq(b.caller1 - a.caller1, n1);
        assertLe(n0, c0, "L11 debit <= cap0");
        assertLe(n1, c1, "L11 debit <= cap1");
        assertLe(a.caller0, b.caller0, "L12 no refund path");
        assertLe(a.caller1, b.caller1, "L12 no refund path");
        assertEq(a.r0, b.r0 + n0);
        assertEq(a.r1, b.r1 + n1);
        assertEq(a.supply, b.supply + s);
        assertEq(a.poolLP, LOCK);
        // Depositor's claim: s/S' of each new reserve is at most what it paid.
        assertLe(s * a.r0, n0 * a.supply, "no free value in token0");
        assertLe(s * a.r1, n1 * a.supply, "no free value in token1");
        // Existing LPs: reserve per share does not decrease (r'/S' >= r/S).
        assertGe(a.r0 * b.supply, b.r0 * a.supply, "no dilution token0");
        assertGe(a.r1 * b.supply, b.r1 * a.supply, "no dilution token1");
    }

    // ------------------------------------------------------------------
    // L06 — failed transfer, insufficient balance or allowance: full rollback
    // ------------------------------------------------------------------

    function test_L06_insufficientAllowanceRollsBack() public {
        _add(pool, alice, 1000e18, 2000e18, 0, alice);
        vm.prank(bob);
        t1.approve(address(pool), 1);
        Snap memory b = _snap(pool, bob);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pool), 1, 200e18)
        );
        pool.addLiquidity(addParams(100e18, 300e18, 0, bob, block.timestamp));
        _assertSame(_snap(pool, bob), b);
    }

    function test_L06_insufficientBalanceRollsBack() public {
        _add(pool, alice, 1000e18, 2000e18, 0, alice);
        address dave = makeAddr("dave");
        t0.mint(dave, 100e18);
        t1.mint(dave, 199e18);
        vm.startPrank(dave);
        t0.approve(address(pool), type(uint256).max);
        t1.approve(address(pool), type(uint256).max);
        vm.stopPrank();
        Snap memory b = _snap(pool, dave);
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, dave, 199e18, 200e18));
        pool.addLiquidity(addParams(100e18, 300e18, 0, dave, block.timestamp));
        _assertSame(_snap(pool, dave), b);
    }

    function _failingPool() internal returns (AMMPool p, MockFailingERC20 bad) {
        address badAddr = address(type(uint160).max); // highest address: token1
        deployCodeTo("MockFailingERC20.sol:MockFailingERC20", abi.encode("Failing", "FAIL", uint8(18)), badAddr);
        bad = MockFailingERC20(badAddr);
        MockERC20 good = new MockERC20("Good", "GOOD", 18);
        p = _newPool(address(good), address(bad));
        assertEq(p.token1(), address(bad));
        _add(p, alice, 1000e18, 2000e18, 0, alice);
    }

    function test_L06_token1TransferFromRevertRollsBackToken0() public {
        (AMMPool p, MockFailingERC20 bad) = _failingPool();
        Snap memory b = _snap(p, bob);
        bad.setMode(MockFailingERC20.Mode.RevertTransferFrom);
        vm.prank(bob);
        vm.expectRevert(MockFailingERC20.MockFailure.selector);
        p.addLiquidity(addParams(100e18, 300e18, 0, bob, block.timestamp));
        bad.setMode(MockFailingERC20.Mode.None);
        _assertSame(_snap(p, bob), b);
    }

    function test_L06_token1ReturnsFalseRollsBackToken0() public {
        (AMMPool p, MockFailingERC20 bad) = _failingPool();
        Snap memory b = _snap(p, bob);
        bad.setMode(MockFailingERC20.Mode.ReturnFalseTransferFrom);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad)));
        p.addLiquidity(addParams(100e18, 300e18, 0, bob, block.timestamp));
        bad.setMode(MockFailingERC20.Mode.None);
        _assertSame(_snap(p, bob), b);
    }

    // ------------------------------------------------------------------
    // L08 — minShares and deadline (later path)
    // ------------------------------------------------------------------

    function test_L08_minSharesEqualSucceedsPlusOneReverts() public {
        _add(pool, alice, 1000, 2000, 0, alice);
        Snap memory b = _snap(pool, bob);
        vm.prank(bob);
        vm.expectRevert(AMMPool.InsufficientShares.selector);
        pool.addLiquidity(addParams(100, 300, 142, bob, block.timestamp));
        _assertSame(_snap(pool, bob), b);
        (,, uint256 s) = _add(pool, bob, 100, 300, 141, bob);
        assertEq(s, 141);
    }

    function test_L08_deadlineBoundary() public {
        _add(pool, alice, 1000e18, 2000e18, 0, alice);
        vm.warp(1000);
        vm.prank(bob);
        vm.expectRevert(AMMPool.DeadlineExpired.selector);
        pool.addLiquidity(addParams(100e18, 300e18, 0, bob, 999));
        vm.prank(bob);
        pool.addLiquidity(addParams(100e18, 300e18, 0, bob, 1000));
        assertGt(pool.balanceOf(bob), 0);
    }

    // ------------------------------------------------------------------
    // L14 — invalid recipient (later path)
    // ------------------------------------------------------------------

    function test_L14_invalidRecipientRevertsOnLaterDeposit() public {
        _add(pool, alice, 1000e18, 2000e18, 0, alice);
        vm.startPrank(bob);
        vm.expectRevert(AMMPool.InvalidRecipient.selector);
        pool.addLiquidity(addParams(100e18, 300e18, 0, address(0), block.timestamp));
        vm.expectRevert(AMMPool.InvalidRecipient.selector);
        pool.addLiquidity(addParams(100e18, 300e18, 0, address(pool), block.timestamp));
        vm.stopPrank();
    }

    /// @dev Shares go to `recipient`, tokens come from msg.sender; event fields match.
    function test_L14_recipientReceivesSharesAndEvent() public {
        _add(pool, alice, 1000, 2000, 0, alice);
        vm.expectEmit(true, true, false, true, address(pool));
        emit IERC20.Transfer(address(0), carol, 141);
        vm.expectEmit(true, true, false, true, address(pool));
        emit AMMPool.LiquidityAdded(bob, carol, 100, 200, 141);
        _add(pool, bob, 100, 300, 0, carol);
        assertEq(pool.balanceOf(carol), 141);
        assertEq(pool.balanceOf(bob), 0);
    }

    // ------------------------------------------------------------------
    // L26 — M8: a taxed token on a later deposit is accepted and accounted by measured net
    // (replaces the pre-M8 `[T, T + 1]` rejection; TEST_MATRIX §3.3)
    // ------------------------------------------------------------------

    /// @dev Taxed token placed explicitly as token0 and as token1, each with both pull orders.
    ///      Kept security property (from the old L26): a short delivery never earns shares for
    ///      tokens that did not arrive. Now shown positively: shares come from the measured nets.
    function test_L26_taxedToken0LaterDepositUsesMeasuredNet() public {
        _taxedLaterDeposit(address(0x10000), false); // low address: token0
        _taxedLaterDeposit(address(0x10001), true);
    }

    function test_L26_taxedToken1LaterDepositUsesMeasuredNet() public {
        _taxedLaterDeposit(address(type(uint160).max), false); // highest address: token1
        _taxedLaterDeposit(address(type(uint160).max - 1), true);
    }

    function _taxedLaterDeposit(address taxedAt, bool token1First) internal {
        deployCodeTo("MockTaxedERC20.sol:MockTaxedERC20", abi.encode("Taxed", "TAX", uint8(18), uint256(100)), taxedAt);
        MockERC20 plain = new MockERC20("Plain", "PLN", 18);
        AMMPool p = _newPool(taxedAt, address(plain));
        bool taxedIs0 = p.token0() == taxedAt;
        assertEq(taxedIs0 ? p.token0() : p.token1(), taxedAt, "taxed token position");
        _add(p, alice, 1000e18, 2000e18, 0, alice);
        Snap memory b = _snap(p, bob);

        vm.prank(bob);
        (uint256 n0, uint256 n1, uint256 s) =
            p.addLiquidity(addParamsOrdered(100e18, 300e18, 0, bob, block.timestamp, token1First));
        Snap memory a = _snap(p, bob);

        // Measured: the returned nets are the Pool's balance increases, in token0/token1 order.
        assertEq(n0, a.pool0 - b.pool0, "net0 = pool token0 increase");
        assertEq(n1, a.pool1 - b.pool1, "net1 = pool token1 increase");
        // The taxed side really arrived short of its step-2 target (T = (100e18, 200e18)).
        assertLt(taxedIs0 ? n0 : n1, taxedIs0 ? 100e18 : 200e18, "taxed side short");
        // X1: reserves grow by the measured nets.
        assertEq(a.r0, b.r0 + n0, "reserve0 += net0");
        assertEq(a.r1, b.r1 + n1, "reserve1 += net1");
        // Shares from measured nets only (values are small: no overflow in the reference).
        uint256 s0 = n0 * b.supply / b.r0;
        uint256 s1 = n1 * b.supply / b.r1;
        assertEq(s, s0 < s1 ? s0 : s1, "shares = min(floor(n_i * S / r_i))");
        assertEq(a.callerLP - b.callerLP, s, "bob received the shares");
        assertEq(a.supply, b.supply + s);
        // Existing LPs' per-share reserves never decrease.
        assertGe(a.r0 * b.supply, b.r0 * a.supply, "per-share reserve0");
        assertGe(a.r1 * b.supply, b.r1 * a.supply, "per-share reserve1");
    }

    // ------------------------------------------------------------------
    // L27 — retired in M8 (TEST_MATRIX §3.3): the tax-hint parameters and the temporary
    // TaxedLaterDepositNotImplemented / InvalidTaxBps errors no longer exist (L30 proves their
    // absence from the ABI). The initial-path property "caller inputs other than the amounts
    // do not change the result" is kept by L19 (pull order and excess fields).
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // B01 (later path) — pre-existing surplus is not attributed and stays unchanged (BI-2)
    // ------------------------------------------------------------------

    function test_B01_laterDepositLeavesSurplusUnchanged() public {
        _add(pool, alice, 1000e18, 2000e18, 0, alice);
        t0.mint(address(pool), 7e18);
        t1.mint(address(pool), 9e18);
        Snap memory b = _snap(pool, bob);
        (uint256 n0, uint256 n1, uint256 s) = _add(pool, bob, 100e18, 300e18, 0, bob);
        Snap memory a = _snap(pool, bob);
        assertEq(n0, 100e18, "net is this call's transfer only");
        assertEq(n1, 200e18);
        assertEq(s, b.supply / 10, "surplus does not change the share price");
        assertEq(a.r0, b.r0 + n0);
        assertEq(a.r1, b.r1 + n1);
        assertEq(a.pool0 - a.r0, b.pool0 - b.r0, "surplus0 unchanged");
        assertEq(a.pool1 - a.r1, b.pool1 - b.r1, "surplus1 unchanged");
        assertEq(a.pool0 - a.r0, 7e18);
        assertEq(a.pool1 - a.r1, 9e18);
    }

    // ------------------------------------------------------------------
    // Z07 — business-invariant boundaries of the later deposit
    // ------------------------------------------------------------------

    /// @dev r = (2e6, 1000): T1 = floor(amount0Max * 1000 / 2e6). 1999 → 0 reverts; 2000 → 1 succeeds.
    function test_Z07_targetZeroBoundary() public {
        _add(pool, alice, 2e6, 1000, 0, alice);
        Snap memory b = _snap(pool, bob);
        vm.prank(bob);
        vm.expectRevert(AMMPool.InsufficientDepositAmount.selector);
        pool.addLiquidity(addParams(1999, 1, 0, bob, block.timestamp));
        _assertSame(_snap(pool, bob), b);
        (uint256 n0, uint256 n1, uint256 s) = _add(pool, bob, 2000, 1, 0, bob);
        assertEq(n0, 2000);
        assertEq(n1, 1);
        assertGt(s, 0);
    }

    /// @dev T0 side: the token1 cap binds and T0 = floor(amount1Max * r0 / r1) rounds to 0.
    function test_Z07_targetZeroBoundaryToken0Side() public {
        _add(pool, alice, 1000, 2e6, 0, alice);
        vm.prank(bob);
        vm.expectRevert(AMMPool.InsufficientDepositAmount.selector);
        pool.addLiquidity(addParams(1e18, 1999, 0, bob, block.timestamp));
        (uint256 n0, uint256 n1,) = _add(pool, bob, 1e18, 2000, 0, bob);
        assertEq(n0, 1);
        assertEq(n1, 2000);
    }

    /// @dev T = (1, 1) but shares = min(1*1001/1001, 1*1001/1002) = min(1, 0) = 0.
    ///      With minShares = 0 the call must still revert: shares must be at least 1.
    function test_Z07_zeroSharesReverts() public {
        _add(pool, alice, 1001, 1002, 0, alice);
        assertEq(pool.totalSupply(), 1001);
        Snap memory b = _snap(pool, bob);
        vm.prank(bob);
        vm.expectRevert(AMMPool.InsufficientShares.selector);
        pool.addLiquidity(addParams(1, 1, 0, bob, block.timestamp));
        _assertSame(_snap(pool, bob), b);
        // One more unit of each makes shares = min(2, 1) = 1.
        (,, uint256 s) = _add(pool, bob, 2, 2, 0, bob);
        assertEq(s, 1);
    }

    // ------------------------------------------------------------------
    // Z06 / M4H-2 — the L-α target never overflows (ARCHITECTURE §6.6; DECISIONS M4H-2)
    // ------------------------------------------------------------------

    /// @dev r = (1e6, 2e6): exact T1 = 2 · amount0Max. Bob holds 2^255 token0, so the token0 pull
    ///      succeeds and the token1 pull reveals which branch was taken via the needed amount:
    ///      amount0Max = 2^255 − 1 → T1 = 2^256 − 2 fits → token0 branch → needs 2^256 − 2 token1;
    ///      amount0Max = 2^255     → T1 = 2^256 does not fit → token1 branch (before M4H-2: Panic
    ///      0x11) → T0 = floor(MAX / 2) = 2^255 − 1, T1 = MAX → needs MAX token1.
    function test_Z06_laterTargetOverflowTakesToken1Branch() public {
        _add(pool, alice, 1e6, 2e6, 0, alice);
        t0.mint(bob, 2 ** 255 - FUND);
        Snap memory b = _snap(pool, bob);
        uint256 inside = 2 ** 255 - 1;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, FUND, 2 * inside));
        pool.addLiquidity(addParams(inside, type(uint256).max, 0, bob, block.timestamp));

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, FUND, type(uint256).max)
        );
        pool.addLiquidity(addParams(inside + 1, type(uint256).max, 0, bob, block.timestamp));
        _assertSame(_snap(pool, bob), b);
    }

    /// @dev Regression for M4H-2: "token0 unlimited, token1 = 100e18" with r1 > r0 used to Panic.
    ///      Now the token1 cap binds: T = (100e18 · 1000 / 2000, 100e18) = (50e18, 100e18).
    function test_M4H2_unboundedToken0CapUsesToken1Cap() public {
        _add(pool, alice, 1000e18, 2000e18, 0, alice);
        uint256 s0 = pool.totalSupply();
        (uint256 n0, uint256 n1, uint256 s) = _add(pool, bob, type(uint256).max, 100e18, 0, bob);
        assertEq(n0, 50e18);
        assertEq(n1, 100e18);
        assertEq(s, s0 / 20);
        (uint256 r0, uint256 r1) = pool.getReserves();
        assertEq(r0, 1050e18);
        assertEq(r1, 2100e18);
    }

    /// @dev The other unbounded combinations (both reserve orientations) give the expected targets.
    function test_M4H2_unboundedCapsBothOrientations() public {
        _add(pool, alice, 2000e18, 1000e18, 0, alice); // r0 > r1: no overflow on either side
        (uint256 n0, uint256 n1,) = _add(pool, bob, type(uint256).max, 100e18, 0, bob);
        assertEq(n0, 200e18);
        assertEq(n1, 100e18);
        (n0, n1,) = _add(pool, bob, 100e18, type(uint256).max, 0, bob);
        assertEq(n0, 100e18);
        assertEq(n1, 50e18);
    }

    /// @dev Middle path (0 < hi < r0): the product exceeds 2^256 but the quotient fits, so `mulDiv`
    ///      is used. r = (2^100, 2^101), amount0Max = 2^200 → product 2^301, T1 = 2^201.
    function test_M4H2_productAbove2pow256QuotientFits() public {
        AMMPool p = _newPool(address(t0), address(t1));
        t0.mint(alice, 2 ** 100);
        t1.mint(alice, 2 ** 101);
        _add(p, alice, 2 ** 100, 2 ** 101, 0, alice);
        t0.mint(bob, 2 ** 200);
        t1.mint(bob, 2 ** 201);
        uint256 s0 = p.totalSupply();
        (uint256 n0, uint256 n1, uint256 s) = _add(p, bob, 2 ** 200, type(uint256).max, 0, bob);
        assertEq(n0, 2 ** 200);
        assertEq(n1, 2 ** 201, "T1 = 2^200 * 2^101 / 2^100");
        assertEq(s, s0 * 2 ** 100, "shares = net0 * S / r0");
    }
}
