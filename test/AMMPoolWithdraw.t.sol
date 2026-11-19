// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFailingERC20} from "./mocks/MockFailingERC20.sol";
import {MockOverDebitERC20} from "./mocks/MockOverDebitERC20.sol";

/// @notice M4: proportional withdrawal with MIN-NET and A8 (ARCHITECTURE §6.3, §7.3; DECISIONS M4-3–M4-5).
///         TEST_MATRIX W01–W06, W08–W11, B02, B06, B07, P03 (burn part), Z06 (redemption), Z07.
///         Every revert asserts the exact error (DECISIONS M4-8); every failed call is checked
///         for full rollback (DECISIONS M4-4).
contract AMMPoolWithdrawTest is Test {
    uint256 internal constant LOCK = 1000;
    uint256 internal constant FUND = 1e30;
    address internal constant LOW = address(0x10000); // deploy target that sorts as token0
    address internal constant HIGH = address(type(uint160).max); // deploy target that sorts as token1

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
        _add(pool, alice, 1000e18, 2000e18);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _newPool(address x, address y) internal returns (AMMPool p) {
        (address lo, address hi) = x < y ? (x, y) : (y, x);
        p = new AMMPool(lo, hi, recipient);
        address[2] memory users = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            MockERC20(lo).mint(users[i], FUND);
            MockERC20(hi).mint(users[i], FUND);
            vm.startPrank(users[i]);
            IERC20(lo).approve(address(p), type(uint256).max);
            IERC20(hi).approve(address(p), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _add(AMMPool p, address from, uint256 a0, uint256 a1) internal returns (uint256 s) {
        vm.prank(from);
        (,, s) = p.addLiquidity(a0, a1, 0, 0, 0, from, block.timestamp);
    }

    function _remove(AMMPool p, address from, uint256 shares, uint256 m0, uint256 m1, address to)
        internal
        returns (uint256 n0, uint256 n1)
    {
        vm.prank(from);
        return p.removeLiquidity(shares, m0, m1, to, block.timestamp);
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
        uint256 to0;
        uint256 to1;
    }

    function _snap(AMMPool p, address caller, address to) internal view returns (Snap memory s) {
        (s.r0, s.r1) = p.getReserves();
        s.supply = p.totalSupply();
        s.poolLP = p.balanceOf(address(p));
        s.callerLP = p.balanceOf(caller);
        IERC20 a = IERC20(p.token0());
        IERC20 b = IERC20(p.token1());
        s.pool0 = a.balanceOf(address(p));
        s.pool1 = b.balanceOf(address(p));
        s.caller0 = a.balanceOf(caller);
        s.caller1 = b.balanceOf(caller);
        s.to0 = a.balanceOf(to);
        s.to1 = b.balanceOf(to);
    }

    /// @dev Full-rollback check (DECISIONS M4-4): caller LP, totalSupply, reserves and every
    ///      relevant token balance (Pool, caller, recipient) equal their pre-call values.
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
        assertEq(a.to0, b.to0, "recipient token0");
        assertEq(a.to1, b.to1, "recipient token1");
    }

    // ------------------------------------------------------------------
    // W01, B06, P03 — proportional redemption
    // ------------------------------------------------------------------

    function test_W01_proportionalRedemption() public {
        Snap memory b = _snap(pool, alice, carol);
        uint256 shares = 1e20;
        uint256 x0 = shares * b.r0 / b.supply;
        uint256 x1 = shares * b.r1 / b.supply;

        vm.expectEmit(true, true, false, true, address(pool));
        emit IERC20.Transfer(alice, address(0), shares);
        vm.expectEmit(true, true, false, true, address(pool));
        emit AMMPool.LiquidityRemoved(alice, carol, shares, x0, x1);
        (uint256 n0, uint256 n1) = _remove(pool, alice, shares, x0, x1, carol);

        Snap memory a = _snap(pool, alice, carol);
        assertEq(n0, x0, "net0 == floor(shares * r0 / S)");
        assertEq(n1, x1);
        assertEq(a.to0 - b.to0, n0, "recipient received net0");
        assertEq(a.to1 - b.to1, n1);
        assertEq(b.pool0 - a.pool0, x0, "B06: Pool balance fell by exactly amount0");
        assertEq(b.pool1 - a.pool1, x1, "B06: Pool balance fell by exactly amount1");
        assertEq(b.r0 - a.r0, x0);
        assertEq(b.r1 - a.r1, x1);
        assertEq(b.callerLP - a.callerLP, shares, "only the caller's shares burned");
        assertEq(b.supply - a.supply, shares, "P03: supply = minted - burned");
        assertEq(a.poolLP, LOCK, "W11: lock untouched");
        assertEq(a.caller0, b.caller0, "caller (not recipient) receives nothing");
    }

    /// @dev Fuzz: random initial reserves and share amount. Success matches the floor formula,
    ///      leaves both reserves > 0, never lowers the remaining LPs' reserve per share, and
    ///      keeps the lock; a zero side reverts InsufficientLiquidityBurned with full rollback.
    function testFuzz_W01_redemptionMatchesFormula(uint256 a0, uint256 a1, uint256 shares) public {
        a0 = bound(a0, 1e4, 1e29);
        a1 = bound(a1, 1e4, 1e29);
        AMMPool p = _newPool(address(new MockERC20("X", "X", 18)), address(new MockERC20("Y", "Y", 18)));
        uint256 owned = _add(p, alice, a0, a1);
        shares = bound(shares, 1, owned);
        Snap memory b = _snap(p, alice, alice);
        uint256 x0 = shares * b.r0 / b.supply;
        uint256 x1 = shares * b.r1 / b.supply;

        if (x0 == 0 || x1 == 0) {
            vm.prank(alice);
            vm.expectRevert(AMMPool.InsufficientLiquidityBurned.selector);
            p.removeLiquidity(shares, 0, 0, alice, block.timestamp);
            _assertSame(_snap(p, alice, alice), b);
            return;
        }
        (uint256 n0, uint256 n1) = _remove(p, alice, shares, x0, x1, alice);
        Snap memory a = _snap(p, alice, alice);
        assertEq(n0, x0);
        assertEq(n1, x1);
        assertEq(a.r0, b.r0 - x0);
        assertEq(a.r1, b.r1 - x1);
        assertGt(a.r0, 0, "reserve0 stays > 0 (lock)");
        assertGt(a.r1, 0, "reserve1 stays > 0 (lock)");
        assertGe(a.r0 * b.supply, b.r0 * a.supply, "remaining LPs not diluted (token0)");
        assertGe(a.r1 * b.supply, b.r1 * a.supply, "remaining LPs not diluted (token1)");
        assertEq(a.poolLP, LOCK);
        assertEq(a.supply, b.supply - shares);
    }

    // ------------------------------------------------------------------
    // W02 — only the caller's shares; a transferee can redeem
    // ------------------------------------------------------------------

    function test_W02_onlyCallersSharesBurned() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, 1e18));
        pool.removeLiquidity(1e18, 0, 0, bob, block.timestamp);

        vm.prank(alice);
        pool.transfer(bob, 5e18);
        uint256 aliceLP = pool.balanceOf(alice);
        (uint256 n0, uint256 n1) = _remove(pool, bob, 5e18, 0, 0, bob);
        assertGt(n0, 0);
        assertGt(n1, 0);
        assertEq(pool.balanceOf(bob), 0, "bob redeemed the transferred LP");
        assertEq(pool.balanceOf(alice), aliceLP, "alice's LP untouched by bob's withdrawal");
    }

    // ------------------------------------------------------------------
    // W03, W10 (class A), Z06 — invalid share amounts
    // ------------------------------------------------------------------

    function test_W03_zeroSharesReverts() public {
        Snap memory b = _snap(pool, alice, alice);
        vm.prank(alice);
        vm.expectRevert(AMMPool.ZeroAmount.selector);
        pool.removeLiquidity(0, 0, 0, alice, block.timestamp);
        _assertSame(_snap(pool, alice, alice), b);
    }

    /// @dev Class A (before withdrawal): balance + 1, the whole supply S (includes the lock) and
    ///      type(uint256).max all revert ERC20InsufficientBalance — never a mulDiv overflow Panic
    ///      (Z06 redemption boundary; the burn precedes the mulDiv, DECISIONS M4-3).
    function test_W10_classA_insufficientLPBeforeWithdrawal() public {
        Snap memory b = _snap(pool, alice, alice);
        uint256 bal = b.callerLP;
        uint256[3] memory tries = [bal + 1, b.supply, type(uint256).max];
        for (uint256 i; i < 3; ++i) {
            vm.prank(alice);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, bal, tries[i])
            );
            pool.removeLiquidity(tries[i], 0, 0, alice, block.timestamp);
        }
        _assertSame(_snap(pool, alice, alice), b);
    }

    /// @dev Z07: r = (2e6, 1000), S = 44,721. amount1 = floor(shares * 1000 / 44721):
    ///      shares = 44 → 0 reverts; shares = 45 → 1 succeeds.
    function test_Z07_zeroOutputBoundary() public {
        AMMPool p = _newPool(address(new MockERC20("X", "X", 18)), address(new MockERC20("Y", "Y", 18)));
        _add(p, alice, 2e6, 1000);
        assertEq(p.totalSupply(), 44_721);
        (uint256 r0, uint256 r1) = p.getReserves();
        assertEq(r0, 2e6, "token order: X/Y sorted so that r0 = 2e6");
        assertEq(r1, 1000);
        Snap memory b = _snap(p, alice, alice);
        vm.prank(alice);
        vm.expectRevert(AMMPool.InsufficientLiquidityBurned.selector);
        p.removeLiquidity(44, 0, 0, alice, block.timestamp);
        _assertSame(_snap(p, alice, alice), b);

        (uint256 n0, uint256 n1) = _remove(p, alice, 45, 0, 0, alice);
        assertEq(n0, uint256(45) * 2e6 / 44_721); // 2012
        assertEq(n1, 1);
    }

    // ------------------------------------------------------------------
    // W04, B07, W10 (class C) — MIN-NET boundary, each token independently
    // ------------------------------------------------------------------

    function test_W04_minNetBoundaryToken0() public {
        Snap memory b = _snap(pool, alice, alice);
        uint256 x0 = 1e20 * b.r0 / b.supply;
        vm.prank(alice);
        vm.expectRevert(AMMPool.InsufficientNetReceived.selector);
        pool.removeLiquidity(1e20, x0 + 1, 0, alice, block.timestamp);
        _assertSame(_snap(pool, alice, alice), b);
        (uint256 n0,) = _remove(pool, alice, 1e20, x0, 0, alice);
        assertEq(n0, x0, "receiving exactly min0Net succeeds");
    }

    function test_W04_minNetBoundaryToken1() public {
        Snap memory b = _snap(pool, alice, alice);
        uint256 x1 = 1e20 * b.r1 / b.supply;
        vm.prank(alice);
        vm.expectRevert(AMMPool.InsufficientNetReceived.selector);
        pool.removeLiquidity(1e20, 0, x1 + 1, alice, block.timestamp);
        _assertSame(_snap(pool, alice, alice), b);
        (, uint256 n1) = _remove(pool, alice, 1e20, 0, x1, alice);
        assertEq(n1, x1, "receiving exactly min1Net succeeds");
    }

    // ------------------------------------------------------------------
    // W05 — taxed output: MIN-NET is judged on the recipient's actual receipt (DECISIONS M4-5)
    // ------------------------------------------------------------------

    function test_W05_taxedToken0Output() public {
        _taxedOutput(LOW, true);
    }

    function test_W05_taxedToken1Output() public {
        _taxedOutput(HIGH, false);
    }

    function _taxedOutput(address taxedAt, bool isToken0) internal {
        deployCodeTo("MockTaxedERC20.sol:MockTaxedERC20", abi.encode("Taxed", "TAX", uint8(18), uint256(100)), taxedAt);
        AMMPool p = _newPool(taxedAt, address(new MockERC20("Plain", "PLN", 18)));
        assertEq(isToken0 ? p.token0() : p.token1(), taxedAt, "taxed token position");
        _add(p, alice, 1000e18, 2000e18);

        Snap memory b = _snap(p, alice, carol);
        uint256 shares = 1e20;
        uint256 x0 = shares * b.r0 / b.supply;
        uint256 x1 = shares * b.r1 / b.supply;
        uint256 xTaxed = isToken0 ? x0 : x1;
        uint256 netTaxed = xTaxed - xTaxed * 100 / 10_000; // U8: recipient gets g − floor(g · 1%)
        assertGe(xTaxed, netTaxed + 1, "amount exceeds net, so the boundary below is meaningful");

        // min = net + 1 reverts although the Pool-side amount is at least net + 1.
        vm.prank(alice);
        vm.expectRevert(AMMPool.InsufficientNetReceived.selector);
        p.removeLiquidity(shares, isToken0 ? netTaxed + 1 : 0, isToken0 ? 0 : netTaxed + 1, carol, block.timestamp);
        _assertSame(_snap(p, alice, carol), b);

        // min = net succeeds.
        vm.expectEmit(true, true, false, true, address(p));
        emit AMMPool.LiquidityRemoved(alice, carol, shares, x0, x1);
        (uint256 n0, uint256 n1) = _remove(p, alice, shares, isToken0 ? netTaxed : x0, isToken0 ? x1 : netTaxed, carol);

        Snap memory a = _snap(p, alice, carol);
        assertEq(isToken0 ? n0 : n1, netTaxed, "return value is the measured net");
        assertEq(isToken0 ? n1 : n0, isToken0 ? x1 : x0, "untaxed side: net == amount");
        assertEq(a.to0 - b.to0, n0, "return net0 == recipient balance change");
        assertEq(a.to1 - b.to1, n1, "return net1 == recipient balance change");
        assertLt(isToken0 ? n0 : n1, xTaxed, "taxed recipient received less than the Pool sent");
        assertEq(b.callerLP - a.callerLP, shares, "LP burned == shares");
        assertEq(b.r0 - a.r0, x0, "reserve decrease == amount0 (Pool side)");
        assertEq(b.r1 - a.r1, x1, "reserve decrease == amount1 (Pool side)");
        assertEq(b.pool0 - a.pool0, x0, "A8 holds for the inclusive taxed token");
        assertEq(b.pool1 - a.pool1, x1);
        assertEq(a.poolLP, LOCK);
    }

    // ------------------------------------------------------------------
    // W06, W11 — the last redeemable LP exits; the lock stays
    // ------------------------------------------------------------------

    function test_W06_lastLPExitsLockRemains() public {
        uint256 all = pool.balanceOf(alice);
        _remove(pool, alice, all, 0, 0, alice);
        assertEq(pool.totalSupply(), LOCK);
        assertEq(pool.balanceOf(address(pool)), LOCK, "Pool still holds exactly 1000 LP");
        (uint256 r0, uint256 r1) = pool.getReserves();
        assertGt(r0, 0);
        assertGt(r1, 0);
        // r_i = R_i − floor(all · R_i / S) with all = S − 1000.
        assertEq(r0, 1000e18 - all * 1000e18 / (all + LOCK));
        assertEq(r1, 2000e18 - all * 2000e18 / (all + LOCK));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        pool.removeLiquidity(1, 0, 0, alice, block.timestamp);

        // The Pool stays usable: a new later deposit at the remaining ratio succeeds.
        uint256 s = _add(pool, bob, 1e18, 1e18);
        assertGt(s, 0);
        assertEq(pool.balanceOf(address(pool)), LOCK);
    }

    /// @dev Even if the Pool itself were msg.sender, its LP cannot be burned (`_update` rule 1).
    function test_W11_poolHeldLPCannotBeRedeemed() public {
        vm.prank(address(pool));
        vm.expectRevert(AMMPool.LockedLiquidity.selector);
        pool.removeLiquidity(LOCK, 0, 0, alice, block.timestamp);
        assertEq(pool.balanceOf(address(pool)), LOCK);
    }

    // ------------------------------------------------------------------
    // W08 — recipient and deadline checks
    // ------------------------------------------------------------------

    function test_W08_invalidRecipientReverts() public {
        Snap memory b = _snap(pool, alice, alice);
        vm.startPrank(alice);
        vm.expectRevert(AMMPool.InvalidRecipient.selector);
        pool.removeLiquidity(1e18, 0, 0, address(0), block.timestamp);
        vm.expectRevert(AMMPool.InvalidRecipient.selector);
        pool.removeLiquidity(1e18, 0, 0, address(pool), block.timestamp);
        vm.stopPrank();
        _assertSame(_snap(pool, alice, alice), b);
    }

    function test_W08_deadlineBoundary() public {
        vm.warp(1000);
        vm.prank(alice);
        vm.expectRevert(AMMPool.DeadlineExpired.selector);
        pool.removeLiquidity(1e18, 0, 0, alice, 999);
        vm.prank(alice);
        pool.removeLiquidity(1e18, 0, 0, alice, 1000);
    }

    /// @dev Check order (DECISIONS M4-3): deadline → recipient → shares == 0 → LP balance.
    function test_W08_checkOrder() public {
        vm.warp(1000);
        vm.startPrank(bob); // bob holds no LP
        vm.expectRevert(AMMPool.DeadlineExpired.selector);
        pool.removeLiquidity(0, 0, 0, address(0), 999);
        vm.expectRevert(AMMPool.InvalidRecipient.selector);
        pool.removeLiquidity(0, 0, 0, address(0), 1000);
        vm.expectRevert(AMMPool.ZeroAmount.selector);
        pool.removeLiquidity(0, 0, 0, bob, 1000);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, 1));
        pool.removeLiquidity(1, type(uint256).max, type(uint256).max, bob, 1000);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // B02 — surplus unchanged by a withdrawal (BI-2)
    // ------------------------------------------------------------------

    function test_B02_withdrawalLeavesSurplusUnchanged() public {
        t0.mint(address(pool), 7e18);
        t1.mint(address(pool), 9e18);
        Snap memory b = _snap(pool, alice, alice);
        uint256 x0 = 1e20 * b.r0 / b.supply;
        uint256 x1 = 1e20 * b.r1 / b.supply;
        (uint256 n0, uint256 n1) = _remove(pool, alice, 1e20, 0, 0, alice);
        Snap memory a = _snap(pool, alice, alice);
        assertEq(n0, x0, "surplus does not enter the redemption");
        assertEq(n1, x1);
        assertEq(a.pool0 - a.r0, 7e18, "surplus0 unchanged");
        assertEq(a.pool1 - a.r1, 9e18, "surplus1 unchanged");
    }

    // ------------------------------------------------------------------
    // W09 — atomicity: token1 fails after token0 was already sent (DECISIONS M4-4)
    // ------------------------------------------------------------------

    function _poolWithBadToken1() internal returns (AMMPool p, MockFailingERC20 bad) {
        deployCodeTo("MockFailingERC20.sol:MockFailingERC20", abi.encode("Failing", "FAIL", uint8(18)), HIGH);
        bad = MockFailingERC20(HIGH);
        p = _newPool(address(new MockERC20("Good", "GOOD", 18)), HIGH);
        assertEq(p.token1(), HIGH);
        _add(p, alice, 1000e18, 2000e18);
    }

    function test_W09_token1TransferRevertRollsBackToken0() public {
        (AMMPool p, MockFailingERC20 bad) = _poolWithBadToken1();
        Snap memory b = _snap(p, alice, carol);
        bad.setMode(MockFailingERC20.Mode.RevertTransfer);
        vm.prank(alice);
        vm.expectRevert(MockFailingERC20.MockFailure.selector);
        p.removeLiquidity(1e20, 0, 0, carol, block.timestamp);
        bad.setMode(MockFailingERC20.Mode.None);
        _assertSame(_snap(p, alice, carol), b);
    }

    function test_W09_token1ReturnsFalseRollsBackToken0() public {
        (AMMPool p, MockFailingERC20 bad) = _poolWithBadToken1();
        Snap memory b = _snap(p, alice, carol);
        bad.setMode(MockFailingERC20.Mode.ReturnFalseTransfer);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, HIGH));
        p.removeLiquidity(1e20, 0, 0, carol, block.timestamp);
        bad.setMode(MockFailingERC20.Mode.None);
        _assertSame(_snap(p, alice, carol), b);
    }

    // ------------------------------------------------------------------
    // W10 (class B), B06 negative, W09 — over-debiting token caught by A8
    // ------------------------------------------------------------------

    function test_W10_classB_overDebitToken0Reverts() public {
        _overDebitReverts(LOW, true);
    }

    function test_W10_classB_W09_overDebitToken1RevertsAndRollsBackToken0() public {
        _overDebitReverts(HIGH, false);
    }

    function _overDebitReverts(address overAt, bool isToken0) internal {
        deployCodeTo("MockOverDebitERC20.sol:MockOverDebitERC20", abi.encode("Over", "OVR", uint8(18)), overAt);
        MockOverDebitERC20 over = MockOverDebitERC20(overAt);
        AMMPool p = _newPool(overAt, address(new MockERC20("Good", "GOOD", 18)));
        assertEq(isToken0 ? p.token0() : p.token1(), overAt, "over-debit token position");
        _add(p, alice, 1000e18, 2000e18);
        Snap memory b = _snap(p, alice, carol);

        over.setExtra(1); // the Pool loses one unit more than it sends
        vm.prank(alice);
        vm.expectRevert(AMMPool.OutboundTransferMismatch.selector);
        p.removeLiquidity(1e20, 0, 0, carol, block.timestamp);
        _assertSame(_snap(p, alice, carol), b);

        over.setExtra(0); // control: a standard transfer passes A8
        _remove(p, alice, 1e20, 0, 0, carol);
        assertEq(p.balanceOf(address(p)), LOCK);
    }
}
