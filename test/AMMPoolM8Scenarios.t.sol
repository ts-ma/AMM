// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {IAMMPool} from "../src/interfaces/IAMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeERC20} from "./mocks/MockFeeERC20.sol";
import {MockDeficitERC20} from "./mocks/MockDeficitERC20.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";
import {addParams, addParamsOrdered} from "./utils/AddParams.sol";

/// @notice M8 commit 5e (tests only). TEST_MATRIX L31 (taxed first token,
///         re-plan; the REPORT_NOTES §1.5 worked numbers), L33 (both taxed, each pull order),
///         L34 (pull-order comparison), L35 (second net 0), L39 (request cap is not a promise),
///         L40 (full error chain with several simultaneous failures), L41 (JIT capture).
///         Worked numbers come from the independent Python model recorded in REPORT_NOTES §1.5;
///         the other expected values are computed here from the documented formulas.
contract AMMPoolM8ScenariosTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    MockFeeERC20.Path internal constant PULL = MockFeeERC20.Path.TransferFrom;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal surplusRecipient = makeAddr("surplusRecipient");

    AMMPool internal p;
    MockFeeERC20 internal f0;
    MockFeeERC20 internal f1;
    uint160 internal nextLow = 0x80000;
    uint160 internal nextHigh = type(uint160).max - 0x6000;

    function _deploy(string memory artifact, bool low) internal returns (address at) {
        at = low ? address(nextLow++) : address(nextHigh--);
        require(at.code.length == 0, "address reused");
        deployCodeTo(artifact, abi.encode("T", "T", uint8(18)), at);
    }

    function _fund(address t0, address t1) internal {
        address[3] memory users = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            MockERC20(t0).mint(users[i], 1e30);
            MockERC20(t1).mint(users[i], 1e30);
            vm.startPrank(users[i]);
            MockERC20(t0).approve(address(p), MAX);
            MockERC20(t1).approve(address(p), MAX);
            vm.stopPrank();
        }
    }

    /// @dev REPORT_NOTES §1.5 state: r = (1,000,000, 2,000,000), S = 1,414,213 (both fee mocks).
    function _worked(uint256 tax0, uint256 tax1) internal {
        f0 = MockFeeERC20(_deploy("MockFeeERC20.sol:MockFeeERC20", true));
        f1 = MockFeeERC20(_deploy("MockFeeERC20.sol:MockFeeERC20", false));
        p = new AMMPool(address(f0), address(f1), surplusRecipient);
        _fund(address(f0), address(f1));
        vm.prank(alice);
        p.addLiquidity(addParams(1_000_000, 2_000_000, 0, alice, block.timestamp));
        assertEq(p.totalSupply(), 1_414_213);
        f0.setTax(PULL, tax0);
        f1.setTax(PULL, tax1);
    }

    struct Out {
        uint256 n0;
        uint256 n1;
        uint256 s;
        uint256 d0;
        uint256 d1;
        uint256 u0;
        uint256 u1;
    }

    function _ceil(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /// @dev bob deposits the §1.5 request (10,000, 30,000) in the given order.
    function _dep(bool t1First) internal returns (Out memory o) {
        (uint256 r0, uint256 r1) = p.getReserves();
        uint256 S = p.totalSupply();
        uint256 b0 = f0.balanceOf(bob);
        uint256 b1 = f1.balanceOf(bob);
        vm.prank(bob);
        (o.n0, o.n1, o.s) = p.addLiquidity(addParamsOrdered(10_000, 30_000, 0, bob, block.timestamp, t1First));
        o.d0 = b0 - f0.balanceOf(bob);
        o.d1 = b1 - f1.balanceOf(bob);
        o.u0 = o.n0 - _ceil(o.s * r0, S);
        o.u1 = o.n1 - _ceil(o.s * r1, S);
    }

    // ------------------------------------------------------------------
    // L31 / L34 — worked numbers (REPORT_NOTES §1.5)
    // ------------------------------------------------------------------

    function test_L31_standard_eitherOrder() public {
        for (uint256 k; k < 2; ++k) {
            _worked(0, 0);
            Out memory o = _dep(k == 1);
            assertEq(o.n0, 10_000);
            assertEq(o.n1, 20_000);
            assertEq(o.s, 14_142);
            assertEq(o.u0, 0);
            assertEq(o.u1, 0);
        }
    }

    /// @dev token1 taxed 5%. token1 first: the measured 19,000 re-plans token0 down to 9,500,
    ///      nothing unmatched. token0 first: no re-plan possible after the fact, 500 token0 unmatched.
    function test_L31_L34_token1Taxed_pullOrderDecidesTheExcess() public {
        _worked(0, 500);
        Out memory o = _dep(true); // token1 first
        assertEq(o.d1, 20_000, "token1 request: step-2 target");
        assertEq(o.n1, 19_000);
        assertEq(o.d0, 9_500, "token0 re-planned from the measured 19,000");
        assertEq(o.n0, 9_500);
        assertEq(o.s, 13_435);
        assertEq(o.u0, 0);
        assertEq(o.u1, 0);

        _worked(0, 500);
        o = _dep(false); // token0 first
        assertEq(o.d0, 10_000);
        assertEq(o.d1, 20_000);
        assertEq(o.n0, 10_000);
        assertEq(o.n1, 19_000);
        assertEq(o.s, 13_435);
        assertEq(o.u0, 500, "unmatched token0 (REPORT_NOTES 1.5)");
        assertEq(o.u1, 0);
    }

    // ------------------------------------------------------------------
    // L33 — both tokens taxed, each pull order
    // ------------------------------------------------------------------

    /// @dev t0 = 5%, t1 = 3%. token0 first (§1.5): n = (9,500, 18,430), σ = 13,031, u = (285, 1).
    ///      token1 first (computed): n1 = 19,400, token0 re-planned to 9,700, n0 = 9,215,
    ///      σ = min(floor(9,215·S/1e6), floor(19,400·S/2e6)) = 13,031, u = (0, 971).
    function test_L33_bothTaxed_eachPullOrder() public {
        _worked(500, 300);
        Out memory o = _dep(false);
        assertEq(o.n0, 9_500);
        assertEq(o.n1, 18_430);
        assertEq(o.s, 13_031);
        assertEq(o.u0, 285);
        assertEq(o.u1, 1);

        _worked(500, 300);
        o = _dep(true);
        assertEq(o.d1, 20_000);
        assertEq(o.n1, 19_400);
        assertEq(o.d0, 9_700, "re-plan: floor(19,400 * 1e6 / 2e6)");
        assertEq(o.n0, 9_215);
        uint256 S = 1_414_213;
        uint256 s0 = uint256(9_215) * S / 1_000_000;
        uint256 s1 = uint256(19_400) * S / 2_000_000;
        assertEq(o.s, s0 < s1 ? s0 : s1);
        assertEq(o.s, 13_031);
        assertEq(o.u0, 0);
        assertEq(o.u1, 971);
    }

    // ------------------------------------------------------------------
    // L35 — the second token delivers nothing (100% tax)
    // ------------------------------------------------------------------

    function test_L35_secondNetZero_insufficientShares_fullRollback() public {
        for (uint256 k; k < 2; ++k) {
            bool t1First = k == 1;
            _worked(t1First ? 10_000 : 0, t1First ? 0 : 10_000); // the SECOND-pulled token is 100% taxed
            (uint256 r0, uint256 r1) = p.getReserves();
            uint256 S = p.totalSupply();
            uint256 b0 = f0.balanceOf(bob);
            uint256 b1 = f1.balanceOf(bob);
            uint256 pb0 = f0.balanceOf(address(p));
            uint256 pb1 = f1.balanceOf(address(p));
            vm.prank(bob);
            vm.expectRevert(AMMPool.InsufficientShares.selector);
            p.addLiquidity(addParamsOrdered(10_000, 30_000, 0, bob, block.timestamp, t1First));
            (uint256 rr0, uint256 rr1) = p.getReserves();
            assertEq(rr0, r0);
            assertEq(rr1, r1);
            assertEq(p.totalSupply(), S);
            assertEq(f0.balanceOf(bob), b0, "first transfer rolled back");
            assertEq(f1.balanceOf(bob), b1);
            assertEq(f0.balanceOf(address(p)), pb0);
            assertEq(f1.balanceOf(address(p)), pb1);
        }
    }

    // ------------------------------------------------------------------
    // L39 — the request cap is a cap, not a promise
    // ------------------------------------------------------------------

    function test_L39_requestCapIsNotAPromise() public {
        _worked(0, 0);
        Out memory o = _dep(false);
        assertEq(o.d1, 20_000, "token1 debit is the step-2 target, below its 30,000 cap");
        assertLt(o.d1, 30_000);
        _worked(0, 500);
        o = _dep(true);
        assertEq(o.d0, 9_500, "token0 re-planned below its 10,000 cap");
        assertLt(o.d0, 10_000);
    }

    // ------------------------------------------------------------------
    // L40 — error chain with several simultaneous failures
    // ------------------------------------------------------------------

    /// @dev One deposit that violates BI-2′, maxDebit and σ > 0 at once (Z07 numbers with a hook
    ///      that removes 1 unit of the Pool's token1 surplus). Each step removes the reported
    ///      condition: InCallBalanceLoss → PayerDebitTooHigh → InsufficientShares → success.
    function test_L40_fullChain_threeSimultaneousFailures() public {
        ReentrantERC20 h = ReentrantERC20(_deploy("ReentrantERC20.sol:ReentrantERC20", true));
        MockDeficitERC20 d = MockDeficitERC20(_deploy("MockDeficitERC20.sol:MockDeficitERC20", false));
        p = new AMMPool(address(h), address(d), surplusRecipient);
        _fund(address(h), address(d));
        vm.prank(alice);
        p.addLiquidity(addParams(1001, 1002, 0, alice, block.timestamp));
        d.mint(address(p), 10);

        IAMMPool.AddLiquidityParams memory prm = addParams(1, 1, 0, bob, block.timestamp);
        prm.maxDebit1 = 0; // token1 debit 1 > 0
        h.armWith(
            address(d), abi.encodeCall(MockDeficitERC20.slash, (address(p), 1)), ReentrantERC20.Hook.TransferFrom, false
        );
        vm.prank(bob);
        vm.expectRevert(AMMPool.InCallBalanceLoss.selector);
        p.addLiquidity(prm);

        h.armWith(address(0), "", ReentrantERC20.Hook.Transfer, false); // disarm the inbound hook
        vm.prank(bob);
        vm.expectRevert(AMMPool.PayerDebitTooHigh.selector);
        p.addLiquidity(prm);

        prm.maxDebit1 = MAX;
        vm.prank(bob);
        vm.expectRevert(AMMPool.InsufficientShares.selector);
        p.addLiquidity(prm);

        prm.amount0RequestMax = 2;
        prm.amount1RequestMax = 2;
        vm.prank(bob);
        (,, uint256 s) = p.addLiquidity(prm);
        assertEq(s, 1);
    }

    // ------------------------------------------------------------------
    // L41 — JIT capture of a victim's unmatched contribution
    // ------------------------------------------------------------------

    /// @dev Victim bob deposits with token1 taxed 5% in the bad order (token0 first), leaving 500
    ///      token0 unmatched (bounded by his maxExcess = 500). Carol adds a large position just
    ///      before and removes it just after. Measured: carol's gain, valued at the pool price
    ///      (1 token0 = 2 token1), is positive and below the victim's unmatched value; without the
    ///      victim's deposit carol's round trip gains nothing.
    function test_L41_jitCapture_boundedByVictimsExcess() public {
        int256 withVictim = _jit(true);
        int256 without = _jit(false);
        assertLe(without, 0, "round trip alone does not profit");
        assertGt(withVictim, 0, "JIT captures part of the victim's excess");
        assertLt(withVictim, 2 * 500, "capture below the victim's unmatched value (500 token0 = 1000 token1)");
        emit log_named_int("JIT gain with victim (token1 units)", withVictim);
    }

    function _jit(bool victim) internal returns (int256) {
        _worked(0, 0);
        // carol's JIT deposit (plain at this point)
        uint256 c0 = f0.balanceOf(carol);
        uint256 c1 = f1.balanceOf(carol);
        vm.prank(carol);
        (,, uint256 cs) = p.addLiquidity(addParams(9_000_000, MAX, 0, carol, block.timestamp));
        if (victim) {
            f1.setTax(PULL, 500);
            IAMMPool.AddLiquidityParams memory prm = addParams(10_000, 30_000, 0, bob, block.timestamp);
            (prm.maxExcess0, prm.maxExcess1) = (500, 0);
            vm.prank(bob);
            p.addLiquidity(prm);
            f1.setTax(PULL, 0);
        }
        vm.prank(carol);
        p.removeLiquidity(cs, 0, 0, carol, block.timestamp);
        int256 g0 = int256(f0.balanceOf(carol)) - int256(c0);
        int256 g1 = int256(f1.balanceOf(carol)) - int256(c1);
        return 2 * g0 + g1; // value in token1 at the pool price 1 token0 = 2 token1
    }
}
