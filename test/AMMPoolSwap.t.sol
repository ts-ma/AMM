// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {AMMMath} from "../src/libraries/AMMMath.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFailingERC20} from "./mocks/MockFailingERC20.sol";
import {MockOverDebitERC20} from "./mocks/MockOverDebitERC20.sol";
import {MockTaxedERC20} from "./mocks/MockTaxedERC20.sol";
import {MockNoReturnERC20} from "./mocks/MockNoReturnERC20.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";
import {Wide512} from "./utils/Wide512.sol";

/// @notice M5: exact-input swap (ARCHITECTURE §6.4, §6.5, §7.4; DECISIONS M5-1, M5-3, M5-6, M5-7).
///         TEST_MATRIX S01–S04, S09–S15, B03, B06 (swap), B07 (swap), X02, Z01, Z06 (swap).
///         Every revert asserts the exact error (DECISIONS M4-8) and every failed call is checked
///         for full rollback of reserves, Pool and user token balances, LP supply and LP balances,
///         and allowances (DECISIONS M5-6).
contract AMMPoolSwapTest is Test {
    uint256 internal constant D = 10_000;
    uint256 internal constant FEE_MUL = 9_970;
    uint256 internal constant FUND = 1e30;
    uint256 internal constant MAX = type(uint256).max;

    MockERC20 internal t0;
    MockERC20 internal t1;
    AMMPool internal pool;

    address internal alice = makeAddr("alice"); // LP
    address internal bob = makeAddr("bob"); // trader
    address internal carol = makeAddr("carol"); // swap recipient
    address internal surplus = makeAddr("surplusRecipient");

    function setUp() public {
        MockERC20 a = new MockERC20("Token A", "TKA", 18);
        MockERC20 b = new MockERC20("Token B", "TKB", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        pool = _newPool(address(t0), address(t1));
        _seed(pool, 1_000_000, 1_000_000);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Deploys a Pool for two tokens (any order), funds alice and bob with FUND of each and
    ///      approves the Pool. Works for every mock, including MockNoReturnERC20 (low-level approve).
    function _newPool(address x, address y) internal returns (AMMPool p) {
        (address lo, address hi) = x < y ? (x, y) : (y, x);
        p = new AMMPool(lo, hi, surplus);
        address[2] memory users = [alice, bob];
        address[2] memory toks = [lo, hi];
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 2; ++j) {
                MockERC20(toks[j]).mint(users[i], FUND);
                vm.prank(users[i]);
                (bool ok,) = toks[j].call(abi.encodeWithSignature("approve(address,uint256)", address(p), MAX));
                require(ok, "approve");
            }
        }
    }

    function _seed(AMMPool p, uint256 a0, uint256 a1) internal returns (uint256 s) {
        vm.prank(alice);
        (,, s) = p.addLiquidity(a0, a1, 0, 0, 0, alice, block.timestamp);
    }

    function _swap(AMMPool p, address tokenIn, uint256 amountIn, uint256 minOut) internal returns (uint256) {
        vm.prank(bob);
        return p.swapExactInput(tokenIn, amountIn, minOut, carol, block.timestamp);
    }

    /// @dev Recorded reserves ordered as (input, output) for `tokenIn`.
    function _inOut(AMMPool p, address tokenIn) internal view returns (uint256 rIn, uint256 rOut) {
        (uint256 r0, uint256 r1) = p.getReserves();
        (rIn, rOut) = tokenIn == p.token0() ? (r0, r1) : (r1, r0);
    }

    /// @dev Independent reference formula (ARCHITECTURE §6.4), exact for inputs up to 2^112.
    function _ref(uint256 a, uint256 rIn, uint256 rOut) internal pure returns (uint256) {
        return a * FEE_MUL * rOut / (rIn * D + a * FEE_MUL);
    }

    /// @dev §6.5 in exact 512-bit arithmetic: (rIn·D + a·9970)·(rOut − out) ≥ rIn·rOut·D.
    function _invariantHolds(uint256 rIn, uint256 rOut, uint256 a, uint256 out) internal pure returns (bool) {
        (uint256 lh, uint256 ll) = Wide512.mul(rIn * D + a * FEE_MUL, rOut - out);
        (uint256 rh, uint256 rl) = Wide512.mul(rIn * D, rOut);
        return Wide512.lte(rh, rl, lh, ll);
    }

    struct Snap {
        uint256 r0;
        uint256 r1;
        uint256 supply;
        uint256 poolLP;
        uint256 aliceLP;
        uint256 bobLP;
        uint256 pool0;
        uint256 pool1;
        uint256 bob0;
        uint256 bob1;
        uint256 carol0;
        uint256 carol1;
        uint256 allow0;
        uint256 allow1;
    }

    function _snap(AMMPool p) internal view returns (Snap memory s) {
        (s.r0, s.r1) = p.getReserves();
        s.supply = p.totalSupply();
        s.poolLP = p.balanceOf(address(p));
        s.aliceLP = p.balanceOf(alice);
        s.bobLP = p.balanceOf(bob);
        IERC20 a = IERC20(p.token0());
        IERC20 b = IERC20(p.token1());
        s.pool0 = a.balanceOf(address(p));
        s.pool1 = b.balanceOf(address(p));
        s.bob0 = a.balanceOf(bob);
        s.bob1 = b.balanceOf(bob);
        s.carol0 = a.balanceOf(carol);
        s.carol1 = b.balanceOf(carol);
        s.allow0 = a.allowance(bob, address(p));
        s.allow1 = b.allowance(bob, address(p));
    }

    /// @dev Full rollback (DECISIONS M5-6): every relevant quantity equals its pre-call value.
    function _assertSame(Snap memory a, Snap memory b) internal pure {
        assertEq(a.r0, b.r0, "reserve0");
        assertEq(a.r1, b.r1, "reserve1");
        assertEq(a.supply, b.supply, "LP totalSupply");
        assertEq(a.poolLP, b.poolLP, "Pool LP (lock)");
        assertEq(a.aliceLP, b.aliceLP, "alice LP");
        assertEq(a.bobLP, b.bobLP, "bob LP");
        assertEq(a.pool0, b.pool0, "Pool token0");
        assertEq(a.pool1, b.pool1, "Pool token1");
        assertEq(a.bob0, b.bob0, "bob token0");
        assertEq(a.bob1, b.bob1, "bob token1");
        assertEq(a.carol0, b.carol0, "carol token0");
        assertEq(a.carol1, b.carol1, "carol token1");
        assertEq(a.allow0, b.allow0, "allowance token0");
        assertEq(a.allow1, b.allow1, "allowance token1");
    }

    /// @dev Calls swapExactInput as bob, expects exactly `err`, and asserts full rollback.
    function _expectSwapRevert(AMMPool p, address tokenIn, uint256 amountIn, uint256 minOut, bytes memory err)
        internal
    {
        _expectSwapRevertTo(p, tokenIn, amountIn, minOut, carol, block.timestamp, err);
    }

    function _expectSwapRevertTo(
        AMMPool p,
        address tokenIn,
        uint256 amountIn,
        uint256 minOut,
        address to,
        uint256 deadline,
        bytes memory err
    ) internal {
        Snap memory b = _snap(p);
        vm.prank(bob);
        vm.expectRevert(err);
        p.swapExactInput(tokenIn, amountIn, minOut, to, deadline);
        _assertSame(b, _snap(p));
    }

    /// @dev Successful swap with full accounting checks; returns (out, netOut).
    function _checkedSwap(AMMPool p, address tokenIn, uint256 amountIn) internal returns (uint256 out) {
        bool zeroForOne = tokenIn == p.token0();
        Snap memory b = _snap(p);
        (uint256 rIn, uint256 rOut) = zeroForOne ? (b.r0, b.r1) : (b.r1, b.r0);
        out = _ref(amountIn, rIn, rOut);

        vm.expectEmit(true, true, false, true, address(p));
        emit AMMPool.Swap(bob, carol, tokenIn, amountIn, out, out);
        uint256 netOut = _swap(p, tokenIn, amountIn, out);
        Snap memory a = _snap(p);

        assertEq(netOut, out, "Tier 0: netOut == out");
        if (zeroForOne) {
            assertEq(a.r0, b.r0 + amountIn, "reserveIn += a");
            assertEq(a.r1, b.r1 - out, "reserveOut -= out");
            assertEq(a.pool0 - b.pool0, amountIn, "Pool input balance += a");
            assertEq(b.pool1 - a.pool1, out, "B06: Pool output balance fell by exactly out");
            assertEq(b.bob0 - a.bob0, amountIn, "bob paid amountIn");
            assertEq(a.carol1 - b.carol1, netOut, "carol received netOut");
            assertEq(a.bob1, b.bob1);
            assertEq(a.carol0, b.carol0);
        } else {
            assertEq(a.r1, b.r1 + amountIn, "reserveIn += a");
            assertEq(a.r0, b.r0 - out, "reserveOut -= out");
            assertEq(a.pool1 - b.pool1, amountIn, "Pool input balance += a");
            assertEq(b.pool0 - a.pool0, out, "B06: Pool output balance fell by exactly out");
            assertEq(b.bob1 - a.bob1, amountIn, "bob paid amountIn");
            assertEq(a.carol0 - b.carol0, netOut, "carol received netOut");
            assertEq(a.bob0, b.bob0);
            assertEq(a.carol1, b.carol1);
        }
        assertEq(a.supply, b.supply, "swap never mints or burns LP");
        assertEq(a.poolLP, 1000, "lock untouched");
        assertTrue(_invariantHolds(rIn, rOut, amountIn, out), "S11: fee-adjusted inequality");
    }

    // ------------------------------------------------------------------
    // S01, S02, S14 — both directions and reference cases at Pool level
    // ------------------------------------------------------------------

    function test_S01_S02_referenceCase1Token0In() public {
        assertEq(_checkedSwap(pool, address(t0), 10_000), 9_871);
    }

    function test_S01_S02_referenceCase1Token1In() public {
        assertEq(_checkedSwap(pool, address(t1), 10_000), 9_871);
    }

    function test_S01_bothDirectionsSequentially() public {
        uint256 out1 = _checkedSwap(pool, address(t0), 50_000);
        uint256 out2 = _checkedSwap(pool, address(t1), out1);
        assertLt(out2, 50_000, "round trip loses the fee and rounding");
    }

    function test_S14_referenceCase2() public {
        assertEq(_checkedSwap(pool, address(t0), 1_000_000), 499_248);
    }

    /// @dev Reference cases 4 and 5: 18-decimal / 6-decimal Pool (1,000e18 / 2,000e6).
    function _mixedPool() internal returns (AMMPool p, MockERC20 t18, MockERC20 t6) {
        t18 = new MockERC20("Eighteen", "E18", 18);
        t6 = new MockERC20("Six", "S6", 6);
        p = _newPool(address(t18), address(t6));
        (uint256 a0, uint256 a1) =
            address(t18) < address(t6) ? (uint256(1000e18), uint256(2000e6)) : (uint256(2000e6), uint256(1000e18));
        _seed(p, a0, a1);
    }

    function test_S14_referenceCase4_18In6Out() public {
        (AMMPool p, MockERC20 t18,) = _mixedPool();
        assertEq(_checkedSwap(p, address(t18), 1e18), 1_992_013);
    }

    function test_S14_referenceCase5_6In18Out() public {
        (AMMPool p,, MockERC20 t6) = _mixedPool();
        assertEq(_checkedSwap(p, address(t6), 1e6), 498_251_621_566_649_025);
    }

    // ------------------------------------------------------------------
    // S03 — zero input, zero reserves, zero output (reference case 3)
    // ------------------------------------------------------------------

    function test_S03_zeroAmountInReverts() public {
        _expectSwapRevert(pool, address(t0), 0, 0, abi.encodeWithSelector(AMMMath.InsufficientInputAmount.selector));
    }

    function test_S03_zeroReservesRevertBeforeTransfer() public {
        AMMPool empty = _newPool(address(t0), address(t1));
        _expectSwapRevert(empty, address(t0), 1e18, 0, abi.encodeWithSelector(AMMMath.InsufficientLiquidity.selector));
    }

    /// @dev Reference case 3: reserves 1,000 / 1,000 (reached by depositing 2,000 / 2,000 and
    ///      withdrawing alice's 1,000 shares), a = 1 → floored out = 0 → InsufficientOutputAmount.
    function test_S03_referenceCase3ZeroOutputReverts() public {
        AMMPool p = _newPool(address(t0), address(t1));
        uint256 s = _seed(p, 2000, 2000);
        vm.prank(alice);
        p.removeLiquidity(s, 0, 0, alice, block.timestamp);
        (uint256 r0, uint256 r1) = p.getReserves();
        assertEq(r0, 1000);
        assertEq(r1, 1000);
        assertEq(_ref(1, 1000, 1000), 0);
        _expectSwapRevert(p, address(t0), 1, 0, abi.encodeWithSelector(AMMPool.InsufficientOutputAmount.selector));
    }

    /// @dev amountIn > 0 but the Pool measures a == 0 (token withholds everything): AMMMath reverts.
    function test_S03_measuredZeroInputReverts() public {
        ReentrantERC20 r = new ReentrantERC20("Re", "RE", 18);
        AMMPool p = _newPool(address(r), address(t1));
        _seed(p, 1e18, 1e18);
        r.setFaults(0, 100);
        _expectSwapRevert(p, address(r), 100, 0, abi.encodeWithSelector(AMMMath.InsufficientInputAmount.selector));
    }

    // ------------------------------------------------------------------
    // S04, B07 — MIN-NET and deadline
    // ------------------------------------------------------------------

    function test_S04_minNetBoundary() public {
        uint256 out = _ref(10_000, 1_000_000, 1_000_000);
        _expectSwapRevert(
            pool, address(t0), 10_000, out + 1, abi.encodeWithSelector(AMMPool.InsufficientNetReceived.selector)
        );
        assertEq(_swap(pool, address(t0), 10_000, out), out, "min == out succeeds");
    }

    function test_S04_deadlineBoundary() public {
        _expectSwapRevertTo(
            pool,
            address(t0),
            10_000,
            0,
            carol,
            block.timestamp - 1,
            abi.encodeWithSelector(AMMPool.DeadlineExpired.selector)
        );
        vm.prank(bob);
        pool.swapExactInput(address(t0), 10_000, 0, carol, block.timestamp); // deadline == now is valid
    }

    // ------------------------------------------------------------------
    // S12 — recipient, tokenIn, check order (DECISIONS M5-1)
    // ------------------------------------------------------------------

    function test_S12_invalidRecipientReverts() public {
        bytes memory err = abi.encodeWithSelector(AMMPool.InvalidRecipient.selector);
        _expectSwapRevertTo(pool, address(t0), 10_000, 0, address(0), block.timestamp, err);
        _expectSwapRevertTo(pool, address(t0), 10_000, 0, address(pool), block.timestamp, err);
    }

    function test_S12_invalidTokenInReverts() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        bytes memory err = abi.encodeWithSelector(AMMPool.InvalidTokenIn.selector);
        _expectSwapRevert(pool, address(other), 10_000, 0, err);
        _expectSwapRevert(pool, address(0), 10_000, 0, err);
        _expectSwapRevert(pool, address(pool), 10_000, 0, err);
    }

    /// @dev Every check fails at first; fixing them one by one reveals the next error in order:
    ///      deadline → recipient → tokenIn → amountIn → reserves.
    function test_S12_checkOrder() public {
        AMMPool empty = _newPool(address(t0), address(t1));
        address bad = address(0xBAD);
        uint256 past = block.timestamp - 1;
        uint256 nowTs = block.timestamp;
        _expectSwapRevertTo(
            empty, bad, 0, 0, address(0), past, abi.encodeWithSelector(AMMPool.DeadlineExpired.selector)
        );
        _expectSwapRevertTo(
            empty, bad, 0, 0, address(0), nowTs, abi.encodeWithSelector(AMMPool.InvalidRecipient.selector)
        );
        _expectSwapRevertTo(empty, bad, 0, 0, carol, nowTs, abi.encodeWithSelector(AMMPool.InvalidTokenIn.selector));
        _expectSwapRevertTo(
            empty, address(t0), 0, 0, carol, nowTs, abi.encodeWithSelector(AMMMath.InsufficientInputAmount.selector)
        );
        _expectSwapRevertTo(
            empty, address(t0), 1, 0, carol, nowTs, abi.encodeWithSelector(AMMMath.InsufficientLiquidity.selector)
        );
    }

    // ------------------------------------------------------------------
    // S10 — fee stays in reserves; S13 — fees accrue to LPs
    // ------------------------------------------------------------------

    function test_S10_feeDifferenceStaysInReserves() public {
        uint256 outNoFee = 10_000 * uint256(1_000_000) / (1_000_000 + 10_000);
        assertEq(outNoFee, 9_900, "0 bps reference");
        uint256 out = _checkedSwap(pool, address(t0), 10_000);
        assertEq(out, 9_871, "30 bps result");
        (uint256 r0, uint256 r1) = pool.getReserves();
        assertEq(r1, 1_000_000 - 9_871, "the 29 units not paid out stay in reserveOut");
        assertEq(r0, 1_010_000, "the whole input, fee included, is in reserveIn");
        assertGt(r0 * r1, uint256(1_000_000) * 1_000_000, "k grew");
    }

    function test_S13_feesAccrueToLPs() public {
        AMMPool p = _newPool(address(t0), address(t1));
        uint256 shares = _seed(p, 1e24, 1e24);
        uint256 supply = p.totalSupply();
        uint256 claim0 = shares * 1e24 / supply;
        uint256 claim1 = shares * 1e24 / supply;

        uint256 amt = 1e22;
        for (uint256 i; i < 10; ++i) {
            amt = _swap(p, i % 2 == 0 ? address(t0) : address(t1), amt, 0);
        }

        vm.prank(alice);
        (uint256 n0, uint256 n1) = p.removeLiquidity(shares, 0, 0, alice, block.timestamp);
        assertGt(n0 * n1, claim0 * claim1, "redeemed product exceeds the initial claim");
        assertEq(p.balanceOf(address(p)), 1000, "lock untouched");
    }

    // ------------------------------------------------------------------
    // B03 — surplus untouched (created by direct transfer; sync/skim are M6)
    // ------------------------------------------------------------------

    function test_B03_swapLeavesSurplusUnchanged() public {
        vm.startPrank(bob);
        t0.transfer(address(pool), 777);
        t1.transfer(address(pool), 555);
        vm.stopPrank();
        Snap memory b = _snap(pool);
        assertEq(b.pool0 - b.r0, 777);
        assertEq(b.pool1 - b.r1, 555);

        uint256 out = _swap(pool, address(t0), 10_000, 0);
        assertEq(out, 9_871, "surplus not counted as input and not used for pricing");
        Snap memory a = _snap(pool);
        assertEq(a.pool0 - a.r0, 777, "token0 surplus unchanged");
        assertEq(a.pool1 - a.r1, 555, "token1 surplus unchanged");
    }

    // ------------------------------------------------------------------
    // B06 — A8 on the swap output; M5-3 event semantics
    // ------------------------------------------------------------------

    function test_B06_overDebitOutputReverts() public {
        MockOverDebitERC20 od = new MockOverDebitERC20("Over", "OVR", 18);
        AMMPool p = _newPool(address(od), address(t1));
        _seed(p, 1e18, 1e18);
        od.setExtra(1);
        _expectSwapRevert(p, address(t1), 1e15, 0, abi.encodeWithSelector(AMMPool.OutboundTransferMismatch.selector));
    }

    /// @dev amountIn (param) ≠ amountIn (event, measured a) ≠ amountOut (out) ≠ netOut (recipient):
    ///      input token withholds 7 units, output token taxes 1% (DECISIONS M5-3).
    function test_M5_3_eventFieldsAreDistinct() public {
        ReentrantERC20 r = new ReentrantERC20("Re", "RE", 18);
        MockTaxedERC20 tx_ = new MockTaxedERC20("Tax", "TAX", 18, 100);
        AMMPool p = _newPool(address(r), address(tx_));
        _seed(p, 1e21, 1e21);
        r.setFaults(0, 7);

        (uint256 rIn, uint256 rOut) = _inOut(p, address(r));
        uint256 a = 1e18 - 7;
        uint256 out = _ref(a, rIn, rOut);
        uint256 net = out - out * 100 / D;
        uint256 carolBefore = tx_.balanceOf(carol);

        vm.expectEmit(true, true, false, true, address(p));
        emit AMMPool.Swap(bob, carol, address(r), a, out, net);
        vm.prank(bob);
        uint256 netOut = p.swapExactInput(address(r), 1e18, net, carol, block.timestamp);

        assertEq(netOut, net, "return = recipient's measured increase");
        assertEq(tx_.balanceOf(carol) - carolBefore, net);
        (uint256 nIn, uint256 nOut) = _inOut(p, address(r));
        assertEq(nIn - rIn, a, "reserveIn grew by the measured a, not by amountIn");
        assertEq(rOut - nOut, out, "reserveOut fell by out, not by netOut");
    }

    /// @dev Both tokens withhold part of every transfer, so in BOTH directions the measured input
    ///      `a` differs from `amountIn`; reserveIn must grow by `a` and pricing must use `a` (§5.2).
    function test_M5_measuredInputUsedInBothDirections() public {
        ReentrantERC20 x = new ReentrantERC20("X", "X", 18);
        ReentrantERC20 y = new ReentrantERC20("Y", "Y", 18);
        AMMPool p = _newPool(address(x), address(y));
        _seed(p, 1e21, 1e21);
        x.setFaults(0, 5);
        y.setFaults(0, 5);
        address[2] memory ins = [p.token0(), p.token1()];
        for (uint256 i; i < 2; ++i) {
            (uint256 rIn, uint256 rOut) = _inOut(p, ins[i]);
            uint256 a = 1e18 - 5;
            uint256 out = _ref(a, rIn, rOut);
            vm.prank(bob);
            p.swapExactInput(ins[i], 1e18, 0, carol, block.timestamp);
            (uint256 nIn, uint256 nOut) = _inOut(p, ins[i]);
            assertEq(nIn, rIn + a, "reserveIn += measured a");
            assertEq(nOut, rOut - out, "priced on measured a");
        }
    }

    // ------------------------------------------------------------------
    // X02 — false / revert roll back; no-return tokens work on both sides (DECISIONS M5-7)
    // ------------------------------------------------------------------

    function _failingPool() internal returns (AMMPool p, MockFailingERC20 f) {
        f = new MockFailingERC20("Fail", "FAIL", 18);
        p = _newPool(address(f), address(t1));
        _seed(p, 1e18, 1e18);
    }

    function test_X02_inputTransferFromRevertRollsBack() public {
        (AMMPool p, MockFailingERC20 f) = _failingPool();
        f.setMode(MockFailingERC20.Mode.RevertTransferFrom);
        _expectSwapRevert(p, address(f), 1e15, 0, abi.encodeWithSelector(MockFailingERC20.MockFailure.selector));
    }

    function test_X02_inputTransferFromFalseRollsBack() public {
        (AMMPool p, MockFailingERC20 f) = _failingPool();
        f.setMode(MockFailingERC20.Mode.ReturnFalseTransferFrom);
        _expectSwapRevert(
            p, address(f), 1e15, 0, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(f))
        );
    }

    function test_X02_outputTransferRevertRollsBackInput() public {
        (AMMPool p, MockFailingERC20 f) = _failingPool();
        f.setMode(MockFailingERC20.Mode.RevertTransfer);
        _expectSwapRevert(p, address(t1), 1e15, 0, abi.encodeWithSelector(MockFailingERC20.MockFailure.selector));
    }

    function test_X02_outputTransferFalseRollsBackInput() public {
        (AMMPool p, MockFailingERC20 f) = _failingPool();
        f.setMode(MockFailingERC20.Mode.ReturnFalseTransfer);
        _expectSwapRevert(
            p, address(t1), 1e15, 0, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(f))
        );
    }

    function test_X02_balanceOfRevertRollsBack() public {
        (AMMPool p, MockFailingERC20 f) = _failingPool();
        Snap memory b = _snap(p); // snapshot while balanceOf still works
        f.setMode(MockFailingERC20.Mode.RevertBalanceOf);
        vm.prank(bob);
        vm.expectRevert(MockFailingERC20.MockFailure.selector);
        p.swapExactInput(address(t1), 1e15, 0, carol, block.timestamp);
        f.setMode(MockFailingERC20.Mode.None);
        _assertSame(b, _snap(p));
    }

    function test_X02_noReturnTokenAsInput() public {
        MockNoReturnERC20 nr = new MockNoReturnERC20("NoRet", "NR", 18);
        AMMPool p = _newPool(address(nr), address(t1));
        _seed(p, 1_000_000, 1_000_000);
        assertEq(_checkedSwap(p, address(nr), 10_000), 9_871);
    }

    function test_X02_noReturnTokenAsOutput() public {
        MockNoReturnERC20 nr = new MockNoReturnERC20("NoRet", "NR", 18);
        AMMPool p = _newPool(address(nr), address(t1));
        _seed(p, 1_000_000, 1_000_000);
        assertEq(_checkedSwap(p, address(t1), 10_000), 9_871);
    }

    // ------------------------------------------------------------------
    // Z01, S11, S15 — fuzz
    // Range: reserves in [1, 2^112] with r0·r1 ≥ 1001² (smaller pairs cannot be created by an
    // initial deposit; reference case 3 covers a 1,000 / 1,000 Pool reached by withdrawal);
    // a in [1, 2^112]; both directions.
    // ------------------------------------------------------------------

    function _fuzzPool(uint256 r0, uint256 r1) internal returns (AMMPool p, uint256 b0, uint256 b1) {
        b0 = bound(r0, 1, 2 ** 112);
        b1 = bound(r1, (1001 * 1001 + b0 - 1) / b0, 2 ** 112);
        p = new AMMPool(address(t0), address(t1), surplus);
        t0.mint(alice, b0);
        t1.mint(alice, b1);
        vm.startPrank(alice);
        t0.approve(address(p), b0);
        t1.approve(address(p), b1);
        p.addLiquidity(b0, b1, 0, 0, 0, alice, block.timestamp);
        vm.stopPrank();
        vm.startPrank(bob);
        t0.approve(address(p), MAX);
        t1.approve(address(p), MAX);
        vm.stopPrank();
    }

    function testFuzz_Z01_S11_S15_swapMatchesFormula(uint256 r0, uint256 r1, uint256 a, bool zeroForOne) public {
        (AMMPool p,,) = _fuzzPool(r0, r1);
        a = bound(a, 1, 2 ** 112);
        address tokenIn = zeroForOne ? address(t0) : address(t1);
        MockERC20(tokenIn).mint(bob, a);
        (uint256 rIn, uint256 rOut) = _inOut(p, tokenIn);
        uint256 expected = _ref(a, rIn, rOut);

        if (expected == 0) {
            _expectSwapRevert(p, tokenIn, a, 0, abi.encodeWithSelector(AMMPool.InsufficientOutputAmount.selector));
            return;
        }
        uint256 out = _swap(p, tokenIn, a, expected);
        assertEq(out, expected, "S15: exactly the reference formula");
        assertLt(out, rOut, "Z01: out < rOut");
        assertTrue(_invariantHolds(rIn, rOut, a, out), "S11: inequality holds");
        assertFalse(_invariantHolds(rIn, rOut, a, out + 1), "S15: out + 1 violates the inequality");
        (uint256 nIn, uint256 nOut) = _inOut(p, tokenIn);
        assertEq(nIn, rIn + a);
        assertEq(nOut, rOut - out);
    }

    // ------------------------------------------------------------------
    // Z06 — arithmetic boundaries of the swap formula at Pool level (ARCHITECTURE §6.6).
    // Shows that overflow fails SAFELY (Panic 0x11, full rollback); it does not show that every
    // uint256 input can trade (DECISIONS M5-7).
    // ------------------------------------------------------------------

    function test_Z06_denominatorBoundary() public {
        uint256 rIn = 1_000_000;
        uint256 aOk = (MAX - rIn * D) / FEE_MUL; // largest a with rIn·D + a·9970 ≤ 2^256 − 1
        t0.mint(bob, aOk + 1);

        _expectSwapRevert(pool, address(t0), aOk + 1, 0, stdError.arithmeticError);

        uint256 out = _swap(pool, address(t0), aOk, 0);
        assertEq(out, _wideMulDiv(aOk * FEE_MUL, 1_000_000, rIn * D + aOk * FEE_MUL), "just inside succeeds");
        assertLt(out, 1_000_000);
    }

    function test_Z06_aFeeOverflowReverts() public {
        uint256 a = MAX / FEE_MUL + 1; // a·9970 itself overflows
        t0.mint(bob, a);
        _expectSwapRevert(pool, address(t0), a, 0, stdError.arithmeticError);
    }

    /// @dev Exact floor(x·y / d) via 512-bit product; independent of OZ (d > hi guaranteed here).
    function _wideMulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 q) {
        (uint256 hi, uint256 lo) = Wide512.mul(x, y);
        require(hi < d, "range");
        // Long division, one bit at a time (test-only, slow but independent).
        uint256 rem = hi;
        unchecked {
            for (uint256 i = 256; i > 0; --i) {
                uint256 bit = (lo >> (i - 1)) & 1;
                bool carry = rem >> 255 == 1;
                rem = (rem << 1) | bit;
                q <<= 1;
                if (carry || rem >= d) {
                    rem -= d; // wraps correctly when carry is set: true value rem + 2^256 ≥ d
                    q |= 1;
                }
            }
        }
    }
}
