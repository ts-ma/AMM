// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {IAMMPool} from "../src/interfaces/IAMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeERC20} from "./mocks/MockFeeERC20.sol";
import {MockDeficitERC20} from "./mocks/MockDeficitERC20.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";
import {addParams, addParamsOrdered} from "./utils/AddParams.sol";

/// @notice M8 commit 3 (WORK IN PROGRESS; BI-2′ follows in commit 4): whole-call payer-debit
///         bound `maxDebit` (DECISIONS M8-3). TEST_MATRIX L37 (boundaries, inclusive/exclusive
///         fees), L38 (cross-token hook, both directions), L40 (check order, PayerDebitTooHigh
///         part), Z09-style seeded random tax. Every revert asserts the exact error and full
///         rollback. Fixture isolation: every token is deployed at a never-reused address, so no
///         storage survives between cases or seeds.
contract AMMPoolPayerDebitTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant FUND = 1e30;
    MockFeeERC20.Path internal constant PULL = MockFeeERC20.Path.TransferFrom;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob"); // the payer in every case
    address internal surplusRecipient = makeAddr("surplusRecipient");

    AMMPool internal p;
    uint160 internal nextLow = 0x20000;
    uint160 internal nextHigh = type(uint160).max - 0x10;

    bytes internal debitErr = abi.encodeWithSelector(AMMPool.PayerDebitTooHigh.selector);

    // ------------------------------------------------------------------
    // Fixture
    // ------------------------------------------------------------------

    /// @dev Deploys `artifact` (constructor (string, string, uint8)) at a fresh low or high address.
    function _deploy(string memory artifact, bool low) internal returns (address at) {
        at = low ? address(nextLow++) : address(nextHigh--);
        require(at.code.length == 0, "address reused");
        deployCodeTo(artifact, abi.encode("T", "T", uint8(18)), at);
    }

    /// @dev Pool of x and y (any order); alice and bob funded and approved; alice deposits
    ///      (i0, i1) in token order. Fees configured afterwards do not affect this deposit.
    function _pool(address x, address y, uint256 i0, uint256 i1) internal {
        (address lo, address hi) = x < y ? (x, y) : (y, x);
        p = new AMMPool(lo, hi, surplusRecipient);
        address[2] memory users = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            MockERC20(lo).mint(users[i], FUND);
            MockERC20(hi).mint(users[i], FUND);
            vm.startPrank(users[i]);
            IERC20(lo).approve(address(p), MAX);
            IERC20(hi).approve(address(p), MAX);
            vm.stopPrank();
        }
        if (i0 != 0) {
            vm.prank(alice);
            p.addLiquidity(addParams(i0, i1, 0, alice, block.timestamp));
        }
    }

    struct State {
        uint256 r0;
        uint256 r1;
        uint256 supply;
        uint256 bobLP;
        uint256 pool0;
        uint256 pool1;
        uint256 bob0;
        uint256 bob1;
        uint256 allow0;
        uint256 allow1;
    }

    function _state() internal view returns (State memory s) {
        (s.r0, s.r1) = p.getReserves();
        s.supply = p.totalSupply();
        s.bobLP = p.balanceOf(bob);
        IERC20 a = IERC20(p.token0());
        IERC20 b = IERC20(p.token1());
        (s.pool0, s.pool1) = (a.balanceOf(address(p)), b.balanceOf(address(p)));
        (s.bob0, s.bob1) = (a.balanceOf(bob), b.balanceOf(bob));
        (s.allow0, s.allow1) = (a.allowance(bob, address(p)), b.allowance(bob, address(p)));
    }

    struct Run {
        bool ok;
        bytes ret;
        uint256 d0; // bob's net token0 decrease over the call (0 if it rose)
        uint256 d1;
    }

    function _run(IAMMPool.AddLiquidityParams memory prm) internal returns (Run memory r) {
        State memory b = _state();
        vm.prank(bob);
        (r.ok, r.ret) = address(p).call(abi.encodeCall(AMMPool.addLiquidity, (prm)));
        State memory a = _state();
        r.d0 = b.bob0 > a.bob0 ? b.bob0 - a.bob0 : 0;
        r.d1 = b.bob1 > a.bob1 ? b.bob1 - a.bob1 : 0;
    }

    function _expectRevert(IAMMPool.AddLiquidityParams memory prm, bytes memory err) internal {
        State memory b = _state();
        Run memory r = _run(prm);
        assertFalse(r.ok, "must revert");
        assertEq(r.ret, err, "exact error");
        assertEq(keccak256(abi.encode(_state())), keccak256(abi.encode(b)), "full-state rollback");
    }

    /// @dev Boundary driver for one deposit `prm` (its maxDebit fields are overwritten):
    ///      measures the payer's debit with unbounded limits, then checks: limits above the
    ///      debit and exactly equal succeed with identical results; one unit below on token0,
    ///      on token1, and on both → PayerDebitTooHigh with full rollback. maxDebit does not
    ///      change what is pulled, so the measured debit is the debit of every run.
    function _boundary(IAMMPool.AddLiquidityParams memory prm) internal returns (Run memory base) {
        uint256 id = vm.snapshotState();
        (prm.maxDebit0, prm.maxDebit1) = (MAX, MAX);
        base = _run(prm);
        assertTrue(base.ok, "unbounded run succeeds");
        vm.revertToState(id);

        (prm.maxDebit0, prm.maxDebit1) = (base.d0 + 1, base.d1 + 1); // below the limit
        Run memory r = _run(prm);
        assertTrue(r.ok, "debit below limit succeeds");
        assertEq(r.ret, base.ret, "same result");
        vm.revertToState(id);

        (prm.maxDebit0, prm.maxDebit1) = (base.d0, base.d1); // exactly at the limit
        r = _run(prm);
        assertTrue(r.ok, "debit == limit succeeds");
        assertEq(r.ret, base.ret, "same result");
        assertEq(r.d0, base.d0);
        assertEq(r.d1, base.d1);
        vm.revertToState(id);

        if (base.d0 > 0) {
            (prm.maxDebit0, prm.maxDebit1) = (base.d0 - 1, base.d1);
            _expectRevert(prm, debitErr);
            vm.revertToState(id);
        }
        if (base.d1 > 0) {
            (prm.maxDebit0, prm.maxDebit1) = (base.d0, base.d1 - 1);
            _expectRevert(prm, debitErr);
            vm.revertToState(id);
        }
        if (base.d0 > 0 && base.d1 > 0) {
            (prm.maxDebit0, prm.maxDebit1) = (base.d0 - 1, base.d1 - 1); // both sides over
            _expectRevert(prm, debitErr);
            vm.revertToState(id);
        }
    }

    // ------------------------------------------------------------------
    // L37 — boundaries: plain, inclusive fee, exclusive fee; both positions and pull orders
    // ------------------------------------------------------------------

    function test_L37_plainTokens_bothPullOrders() public {
        for (uint256 k; k < 2; ++k) {
            _pool(_deploy("MockERC20.sol:MockERC20", true), _deploy("MockERC20.sol:MockERC20", false), 1e21, 2e21);
            Run memory r = _boundary(addParamsOrdered(1e18, 5e18, 0, bob, block.timestamp, k == 1));
            assertEq(r.d0, 1e18, "plain: debit = pulled");
            assertEq(r.d1, 2e18);
        }
    }

    /// @dev Inclusive 10% fee on token X: the payer is debited exactly what the Pool requested,
    ///      the Pool receives 10% less. Debit > net on X, debit = net on the plain side.
    function test_L37_inclusiveFee_bothPositions_bothPullOrders() public {
        for (uint256 k; k < 4; ++k) {
            bool feeLow = k < 2;
            MockFeeERC20 f = MockFeeERC20(_deploy("MockFeeERC20.sol:MockFeeERC20", feeLow));
            _pool(address(f), _deploy("MockERC20.sol:MockERC20", !feeLow), 1e21, 1e21);
            f.setTax(PULL, 1000);
            Run memory r = _boundary(addParamsOrdered(1e18, 1e18, 0, bob, block.timestamp, k % 2 == 1));
            (uint256 n0, uint256 n1,) = abi.decode(r.ret, (uint256, uint256, uint256));
            (uint256 dFee, uint256 nFee, uint256 dPlain, uint256 nPlain) =
                feeLow ? (r.d0, n0, r.d1, n1) : (r.d1, n1, r.d0, n0);
            assertEq(nFee, dFee - dFee / 10, "inclusive: Pool receives debit - 10%");
            assertEq(dPlain, nPlain, "plain side: debit = net");
        }
    }

    /// @dev Exclusive 10% extra on token X: the Pool receives the full request, the payer loses
    ///      request + 10% (the extra is taken from the payer's balance, not from the allowance).
    function test_L37_exclusiveFee_bothPositions_bothPullOrders() public {
        for (uint256 k; k < 4; ++k) {
            bool feeLow = k < 2;
            MockFeeERC20 f = MockFeeERC20(_deploy("MockFeeERC20.sol:MockFeeERC20", feeLow));
            _pool(address(f), _deploy("MockERC20.sol:MockERC20", !feeLow), 1e21, 1e21);
            f.setExtra(PULL, 1000);
            Run memory r = _boundary(addParamsOrdered(1e18, 1e18, 0, bob, block.timestamp, k % 2 == 1));
            (uint256 n0, uint256 n1,) = abi.decode(r.ret, (uint256, uint256, uint256));
            (uint256 dFee, uint256 nFee) = feeLow ? (r.d0, n0) : (r.d1, n1);
            assertEq(nFee, 1e18, "exclusive: Pool receives the request");
            assertEq(dFee, 1e18 + 1e17, "payer debited request + 10%");
        }
    }

    /// @dev maxDebit also applies to the initial deposit (both caps pulled in full).
    function test_L37_initialDeposit_exclusiveFee_bothPullOrders() public {
        for (uint256 k; k < 2; ++k) {
            MockFeeERC20 f = MockFeeERC20(_deploy("MockFeeERC20.sol:MockFeeERC20", true));
            _pool(address(f), _deploy("MockERC20.sol:MockERC20", false), 0, 0);
            f.setExtra(PULL, 500);
            Run memory r = _boundary(addParamsOrdered(4e18, 1e18, 0, bob, block.timestamp, k == 1));
            assertEq(r.d0, 4e18 + 2e17, "initial: token0 debit = cap + 5%");
            assertEq(r.d1, 1e18);
        }
    }

    // ------------------------------------------------------------------
    // Balance increase during the call: net debit 0, no underflow
    // ------------------------------------------------------------------

    /// @dev The hook token's callback mints 10e18 of the OTHER token to the payer, more than the
    ///      Pool pulls of it, so that token's payer balance rises: net debit 0, and maxDebit = 0
    ///      for it succeeds. An implementation computing `start − end` would underflow here.
    function test_L37_payerBalanceRises_countsAsZero_bothPositions_bothPullOrders() public {
        for (uint256 k; k < 4; ++k) {
            bool hookLow = k < 2;
            ReentrantERC20 h = ReentrantERC20(_deploy("ReentrantERC20.sol:ReentrantERC20", hookLow));
            MockERC20 m = MockERC20(_deploy("MockERC20.sol:MockERC20", !hookLow));
            _pool(address(h), address(m), 1e21, 1e21);
            h.armWith(address(m), abi.encodeCall(MockERC20.mint, (bob, 10e18)), ReentrantERC20.Hook.TransferFrom, false);

            IAMMPool.AddLiquidityParams memory prm = addParamsOrdered(1e18, 1e18, 0, bob, block.timestamp, k % 2 == 1);
            (prm.maxDebit0, prm.maxDebit1) = hookLow ? (uint256(1e18), uint256(0)) : (uint256(0), uint256(1e18));
            Run memory r = _run(prm);
            assertTrue(r.ok, "other token's balance rose: debit 0 <= maxDebit 0");
            assertTrue(h.callbackRan());
            assertEq(hookLow ? r.d1 : r.d0, 0, "net debit of the other token is 0");
        }
    }

    // ------------------------------------------------------------------
    // L38 — cross-token hook debits the payer's OTHER token, both directions
    // ------------------------------------------------------------------

    /// @dev Hook token H (token0 or token1) slashes 7e17 of the payer's other token D during H's
    ///      own transferFrom — outside D's transfer window, before or after it depending on the
    ///      pull order. The whole-call snapshot catches it on D's maxDebit: the limit that fits
    ///      the deposit alone reverts; the limit including the slash succeeds.
    function test_L38_crossTokenHook_bothDirections_bothPullOrders() public {
        for (uint256 k; k < 4; ++k) {
            bool hookLow = k < 2;
            bool t1First = k % 2 == 1;
            ReentrantERC20 h = ReentrantERC20(_deploy("ReentrantERC20.sol:ReentrantERC20", hookLow));
            MockDeficitERC20 d = MockDeficitERC20(_deploy("MockDeficitERC20.sol:MockDeficitERC20", !hookLow));
            _pool(address(h), address(d), 1e21, 1e21);
            IAMMPool.AddLiquidityParams memory prm = addParamsOrdered(1e18, 1e18, 0, bob, block.timestamp, t1First);

            // Without the hook the payer's D debit is exactly the 1e18 pulled.
            uint256 id = vm.snapshotState();
            Run memory clean = _run(prm);
            assertTrue(clean.ok);
            assertEq(hookLow ? clean.d1 : clean.d0, 1e18);
            vm.revertToState(id);

            h.armWith(
                address(d), abi.encodeCall(MockDeficitERC20.slash, (bob, 7e17)), ReentrantERC20.Hook.TransferFrom, false
            );
            // A limit that covers only the deposit itself: the extra slash is caught.
            (prm.maxDebit0, prm.maxDebit1) = (1e18, 1e18);
            _expectRevert(prm, debitErr);
            // The limit including the slash, exactly: succeeds; the same result as the clean run.
            (prm.maxDebit0, prm.maxDebit1) = hookLow ? (uint256(1e18), uint256(17e17)) : (uint256(17e17), uint256(1e18));
            Run memory r = _run(prm);
            assertTrue(r.ok, "limit including the slash succeeds");
            assertTrue(h.callbackRan(), "the hook ran");
            assertEq(hookLow ? r.d1 : r.d0, 17e17, "whole-call debit includes the slash");
            assertEq(r.ret, clean.ret, "Pool accounting unaffected by a payer-side slash");
        }
    }

    // ------------------------------------------------------------------
    // L40 (PayerDebitTooHigh part) — order relative to the later checks (M8-13 (d))
    // ------------------------------------------------------------------

    /// @dev σ == 0 (Z07 case) and debit over the limit: PayerDebitTooHigh is reported first.
    function test_L40_payerDebitBeforeInsufficientShares() public {
        _pool(_deploy("MockERC20.sol:MockERC20", true), _deploy("MockERC20.sol:MockERC20", false), 1001, 1002);
        IAMMPool.AddLiquidityParams memory prm = addParams(1, 1, 0, bob, block.timestamp);
        _expectRevert(prm, abi.encodeWithSelector(AMMPool.InsufficientShares.selector)); // control
        prm.maxDebit1 = 0;
        _expectRevert(prm, debitErr);
    }

    /// @dev Unmatched excess above maxExcess and debit over the limit: PayerDebitTooHigh first.
    function test_L40_payerDebitBeforeExcessContributionTooHigh() public {
        MockFeeERC20 f = MockFeeERC20(_deploy("MockFeeERC20.sol:MockFeeERC20", false));
        _pool(_deploy("MockERC20.sol:MockERC20", true), address(f), 1e21, 1e21);
        f.setTax(PULL, 1000); // token1 taxed and pulled second: token0's excess is ~10%
        IAMMPool.AddLiquidityParams memory prm = addParams(1e18, 1e18, 0, bob, block.timestamp);
        (prm.maxExcess0, prm.maxExcess1) = (0, 0);
        _expectRevert(prm, abi.encodeWithSelector(AMMPool.ExcessContributionTooHigh.selector)); // control
        prm.maxDebit0 = 1e18 - 1;
        _expectRevert(prm, debitErr);
    }

    /// @dev Saturated σ (Z08 (ii) setup) and debit over the limit: PayerDebitTooHigh first,
    ///      before the checked `supply + σ` Panic.
    function test_L40_payerDebitBeforeCheckedSupplyPanic() public {
        MockDeficitERC20 d0 = MockDeficitERC20(_deploy("MockDeficitERC20.sol:MockDeficitERC20", true));
        MockDeficitERC20 d1 = MockDeficitERC20(_deploy("MockDeficitERC20.sol:MockDeficitERC20", false));
        _pool(address(d0), address(d1), 1e30, 1e30);
        d0.slash(address(p), 1e30 - 1);
        d1.slash(address(p), 1e30 - 1);
        p.sync();
        uint256 big = 2 ** 200;
        d0.mint(bob, big);
        d1.mint(bob, big);
        IAMMPool.AddLiquidityParams memory prm = addParams(big, big, 0, bob, block.timestamp);
        _expectRevert(prm, abi.encodeWithSignature("Panic(uint256)", 0x11)); // control
        prm.maxDebit1 = big - 1;
        _expectRevert(prm, debitErr);
    }

    /// @dev Initial path: PayerDebitTooHigh before InsufficientInitialLiquidity (sqrt = 1000).
    function test_L40_initial_payerDebitBeforeInsufficientInitialLiquidity() public {
        _pool(_deploy("MockERC20.sol:MockERC20", true), _deploy("MockERC20.sol:MockERC20", false), 0, 0);
        IAMMPool.AddLiquidityParams memory prm = addParams(1000, 1000, 0, bob, block.timestamp);
        _expectRevert(prm, abi.encodeWithSelector(AMMPool.InsufficientInitialLiquidity.selector)); // control
        prm.maxDebit0 = 999;
        _expectRevert(prm, debitErr);
    }

    // ------------------------------------------------------------------
    // Seeded random tax on both tokens, both pull orders (fresh fixture per seed)
    // ------------------------------------------------------------------

    function test_L37_randomTaxBothTokens_seeded_bothPullOrders() public {
        for (uint256 seed = 1; seed <= 8; ++seed) {
            for (uint256 k; k < 2; ++k) {
                MockFeeERC20 f0 = MockFeeERC20(_deploy("MockFeeERC20.sol:MockFeeERC20", true));
                MockFeeERC20 f1 = MockFeeERC20(_deploy("MockFeeERC20.sol:MockFeeERC20", false));
                _pool(address(f0), address(f1), 1e21, 3e21);
                assertEq(f0.config(PULL).nonce, 0, "fresh fixture");
                f0.setRandomTax(PULL, seed, 0, 5000);
                f1.setRandomTax(PULL, seed + 1000, 0, 5000);
                _boundary(addParamsOrdered(1e19, 1e20, 0, bob, block.timestamp, k == 1));
            }
        }
    }
}
