// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockTaxedERC20} from "./mocks/MockTaxedERC20.sol";
import {MockFailingERC20} from "./mocks/MockFailingERC20.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";
import {AMMPoolSupplyHarness} from "./harness/AMMPoolSupplyHarness.sol";

/// @notice M3: LP ERC-20, initial deposit and the permanent lock.
///         TEST_MATRIX L01, L02, L07, L17–L25, P01–P10, R01 (re-run), BI-7, BI-8 (mint part).
contract AMMPoolLiquidityTest is Test {
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

    /// @dev Deploys a Pool for two tokens (sorted here, as the future Factory will) and gives
    ///      alice funds and unlimited approval for both.
    function _newPool(address x, address y) internal returns (AMMPool p) {
        (address lo, address hi) = x < y ? (x, y) : (y, x);
        p = new AMMPool(lo, hi, recipient);
        MockERC20(lo).mint(alice, FUND);
        MockERC20(hi).mint(alice, FUND);
        vm.startPrank(alice);
        IERC20(lo).approve(address(p), type(uint256).max);
        IERC20(hi).approve(address(p), type(uint256).max);
        vm.stopPrank();
    }

    function _add(AMMPool p, uint256 a0, uint256 a1, uint256 minShares, address to)
        internal
        returns (uint256 n0, uint256 n1, uint256 s)
    {
        vm.prank(alice);
        return p.addLiquidity(a0, a1, 0, 0, minShares, to, block.timestamp);
    }

    function _reserves(AMMPool p) internal view returns (uint256 r0, uint256 r1) {
        return p.getReserves();
    }

    /// @dev Total LP held by the three test users (all non-Pool holders in these tests).
    function _userLP(AMMPool p) internal view returns (uint256) {
        return p.balanceOf(alice) + p.balanceOf(bob) + p.balanceOf(carol);
    }

    // ------------------------------------------------------------------
    // L01, L07, P03 — initial deposit
    // ------------------------------------------------------------------

    function test_L01_initialDepositSharesAndLock() public {
        (uint256 n0, uint256 n1, uint256 s) = _add(pool, 4e18, 1e18, 0, bob);
        assertEq(n0, 4e18);
        assertEq(n1, 1e18);
        assertEq(s, 2e18 - LOCK); // floor(sqrt(4e36)) = 2e18
        assertEq(pool.balanceOf(bob), 2e18 - LOCK);
        assertEq(pool.balanceOf(address(pool)), LOCK);
        assertEq(pool.totalSupply(), 2e18); // P03: minted = lock + provider
        (uint256 r0, uint256 r1) = _reserves(pool);
        assertEq(r0, 4e18);
        assertEq(r1, 1e18);
        assertEq(t0.balanceOf(alice), FUND - 4e18);
        assertEq(t1.balanceOf(alice), FUND - 1e18);
    }

    /// L07: the first depositor alone sets the initial price (reserve ratio); mixed decimals.
    function test_L07_firstDepositorSetsPrice() public {
        MockERC20 a = new MockERC20("Eighteen", "E18", 18);
        MockERC20 b = new MockERC20("Six", "S6", 6);
        AMMPool p = _newPool(address(a), address(b));
        bool aIsToken0 = p.token0() == address(a);
        uint256 amtA = 1_000e18;
        uint256 amtB = 2_000e6;
        vm.prank(alice);
        p.addLiquidity(aIsToken0 ? amtA : amtB, aIsToken0 ? amtB : amtA, 0, 0, 0, alice, block.timestamp);
        (uint256 r0, uint256 r1) = _reserves(p);
        assertEq(aIsToken0 ? r0 : r1, amtA);
        assertEq(aIsToken0 ? r1 : r0, amtB);
    }

    // ------------------------------------------------------------------
    // L02, L17, L18 — share thresholds
    // ------------------------------------------------------------------

    function test_L02_zeroAmountsRevert() public {
        vm.startPrank(alice);
        vm.expectRevert(AMMPool.ZeroAmount.selector);
        pool.addLiquidity(0, 1e18, 0, 0, 0, alice, block.timestamp);
        vm.expectRevert(AMMPool.ZeroAmount.selector);
        pool.addLiquidity(1e18, 0, 0, 0, 0, alice, block.timestamp);
        vm.stopPrank();
    }

    function test_L17_gross999Reverts() public {
        vm.expectRevert(AMMPool.InsufficientInitialLiquidity.selector);
        _add(pool, 999, 999, 0, alice);
    }

    function test_L17_gross1000Reverts() public {
        vm.expectRevert(AMMPool.InsufficientInitialLiquidity.selector);
        _add(pool, 1000, 1000, 0, alice);
        vm.expectRevert(AMMPool.InsufficientInitialLiquidity.selector);
        _add(pool, 1, 1_000_000, 0, alice); // asymmetric: sqrt(1e6) = 1000
    }

    function test_L17_gross1001SucceedsWithOneShare() public {
        (,, uint256 s) = _add(pool, 1001, 1001, 0, alice);
        assertEq(s, 1);
        assertEq(pool.balanceOf(address(pool)), LOCK);
        assertEq(pool.totalSupply(), 1001);
    }

    function test_L17_asymmetricGross1001() public {
        (,, uint256 s) = _add(pool, 1, 1_002_001, 0, alice); // sqrt(1,002,001) = 1001
        assertEq(s, 1);
    }

    function test_L18_minSharesEqualSucceeds() public {
        (,, uint256 s) = _add(pool, 4e18, 1e18, 2e18 - LOCK, alice);
        assertEq(s, 2e18 - LOCK);
    }

    function test_L18_minSharesPlusOneReverts() public {
        vm.expectRevert(AMMPool.InsufficientShares.selector);
        _add(pool, 4e18, 1e18, 2e18 - LOCK + 1, alice);
    }

    // ------------------------------------------------------------------
    // L19 — U8 taxed token: shares follow the measured balance difference
    // ------------------------------------------------------------------

    struct TaxedResult {
        uint256 netTaxed;
        uint256 netPlain;
        uint256 shares;
        uint256 debitTaxed;
    }

    /// @dev Fresh Pool with a 1% U8 taxed token and a plain token; alice deposits 1,000,000 of each.
    function _taxedDeposit(uint256 hintTaxed, uint256 hintPlain) internal returns (TaxedResult memory res) {
        MockTaxedERC20 taxed = new MockTaxedERC20("Taxed", "TAX", 18, 100); // 1%
        AMMPool p = _newPool(address(taxed), address(new MockERC20("Plain", "PLN", 18)));
        bool taxedIs0 = p.token0() == address(taxed);
        res.debitTaxed = taxed.balanceOf(alice);

        vm.prank(alice);
        (uint256 n0, uint256 n1, uint256 s) = p.addLiquidity(
            1_000_000,
            1_000_000,
            taxedIs0 ? hintTaxed : hintPlain,
            taxedIs0 ? hintPlain : hintTaxed,
            0,
            alice,
            block.timestamp
        );
        (res.netTaxed, res.netPlain) = taxedIs0 ? (n0, n1) : (n1, n0);
        res.shares = s;
        res.debitTaxed -= taxed.balanceOf(alice);

        (n0, n1) = p.getReserves();
        assertEq(taxedIs0 ? n0 : n1, res.netTaxed, "reserve = measured net");
        assertEq(taxed.balanceOf(address(p)), res.netTaxed, "pool balance = net");
    }

    function test_L19_taxedInitialDepositUsesMeasuredNet() public {
        TaxedResult memory r = _taxedDeposit(0, 0);
        assertEq(r.debitTaxed, 1_000_000, "inclusive: sender debited exactly the requested gross");
        assertEq(r.netTaxed, 990_000, "net = gross - floor(gross * 1%)");
        assertEq(r.netPlain, 1_000_000);
        // floor(sqrt(990,000 * 1,000,000)) = 994,987 (994,987^2 <= 9.9e11 < 994,988^2)
        assertEq(r.shares, 994_987 - LOCK, "shares from net, not from requested amounts");
    }

    function test_L19_taxHintsDoNotChangeInitialResult() public {
        TaxedResult memory a = _taxedDeposit(0, 0);
        TaxedResult memory b = _taxedDeposit(100, 0); // correct hint
        TaxedResult memory c = _taxedDeposit(9_999, 5_000); // wrong hints
        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(b)));
        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(c)));
    }

    function testFuzz_L19_anyValidHintGivesSameShares(uint256 hintTaxed, uint256 hintPlain) public {
        hintTaxed = bound(hintTaxed, 0, 9_999);
        hintPlain = bound(hintPlain, 0, 9_999);
        TaxedResult memory r = _taxedDeposit(hintTaxed, hintPlain);
        assertEq(r.shares, 994_987 - LOCK);
        assertEq(r.netTaxed, 990_000);
    }

    // ------------------------------------------------------------------
    // L20 — pre-existing surplus in both tokens (BI-2, initial path)
    // ------------------------------------------------------------------

    function test_L20_preExistingSurplusIsNotAttributed() public {
        uint256 s0 = 123e18;
        uint256 s1 = 7e18;
        t0.mint(address(pool), s0); // unsolicited transfers before the first deposit
        t1.mint(address(pool), s1);

        (uint256 n0, uint256 n1, uint256 s) = _add(pool, 4e18, 1e18, 0, alice);
        assertEq(n0, 4e18, "net0 = this call's transfer only");
        assertEq(n1, 1e18, "net1 = this call's transfer only");
        assertEq(s, 2e18 - LOCK, "shares ignore surplus");

        (uint256 r0, uint256 r1) = _reserves(pool);
        assertEq(r0, 4e18);
        assertEq(r1, 1e18);
        assertEq(t0.balanceOf(address(pool)) - r0, s0, "surplus0 unchanged");
        assertEq(t1.balanceOf(address(pool)) - r1, s1, "surplus1 unchanged");
    }

    // ------------------------------------------------------------------
    // L21 — argument checks on the initial path
    // ------------------------------------------------------------------

    function test_L21_deadlineBoundary() public {
        uint256 deadline = block.timestamp + 100;
        vm.warp(deadline + 1);
        vm.prank(alice);
        vm.expectRevert(AMMPool.DeadlineExpired.selector);
        pool.addLiquidity(4e18, 1e18, 0, 0, 0, alice, deadline);

        vm.warp(deadline);
        vm.prank(alice);
        pool.addLiquidity(4e18, 1e18, 0, 0, 0, alice, deadline); // == deadline succeeds
        assertEq(pool.totalSupply(), 2e18);
    }

    function test_L21_invalidRecipientReverts() public {
        vm.startPrank(alice);
        vm.expectRevert(AMMPool.InvalidRecipient.selector);
        pool.addLiquidity(4e18, 1e18, 0, 0, 0, address(0), block.timestamp);
        vm.expectRevert(AMMPool.InvalidRecipient.selector);
        pool.addLiquidity(4e18, 1e18, 0, 0, 0, address(pool), block.timestamp);
        vm.stopPrank();
    }

    function test_L21_L16_taxBpsBoundary() public {
        vm.startPrank(alice);
        vm.expectRevert(AMMPool.InvalidTaxBps.selector);
        pool.addLiquidity(4e18, 1e18, 10_000, 0, 0, alice, block.timestamp);
        vm.expectRevert(AMMPool.InvalidTaxBps.selector);
        pool.addLiquidity(4e18, 1e18, 0, 10_000, 0, alice, block.timestamp);
        pool.addLiquidity(4e18, 1e18, 9_999, 9_999, 0, alice, block.timestamp); // < 10000 accepted
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // L22 — temporary: later deposits arrive in M4
    // ------------------------------------------------------------------

    function test_L22_laterDepositRevertsUntilM4() public {
        _add(pool, 4e18, 1e18, 0, alice);
        vm.expectRevert(AMMPool.LaterDepositNotImplemented.selector);
        _add(pool, 4e18, 1e18, 0, alice);
    }

    // ------------------------------------------------------------------
    // L23 — a failure in token1 rolls back token0's completed transfer
    // ------------------------------------------------------------------

    function _failingPool() internal returns (AMMPool p, MockERC20 good, MockFailingERC20 bad) {
        // Highest possible address, so the failing token is token1 and token0 is processed first.
        address badAddr = address(type(uint160).max);
        deployCodeTo("MockFailingERC20.sol:MockFailingERC20", abi.encode("Failing", "FAIL", uint8(18)), badAddr);
        bad = MockFailingERC20(badAddr);
        good = new MockERC20("Good", "GOOD", 18);
        p = _newPool(address(good), address(bad));
        assertEq(p.token0(), address(good));
        assertEq(p.token1(), address(bad));
    }

    function _assertNothingChanged(AMMPool p, MockERC20 good, MockFailingERC20 bad) internal {
        bad.setMode(MockFailingERC20.Mode.None);
        assertEq(good.balanceOf(alice), FUND, "token0 transfer rolled back");
        assertEq(good.balanceOf(address(p)), 0);
        assertEq(bad.balanceOf(alice), FUND);
        assertEq(good.allowance(alice, address(p)), type(uint256).max, "allowance unchanged");
        assertEq(p.totalSupply(), 0);
        assertEq(p.balanceOf(address(p)), 0);
        (uint256 r0, uint256 r1) = p.getReserves();
        assertEq(r0, 0);
        assertEq(r1, 0);
    }

    function test_L23_token1TransferFromRevertRollsBackAll() public {
        (AMMPool p, MockERC20 good, MockFailingERC20 bad) = _failingPool();
        bad.setMode(MockFailingERC20.Mode.RevertTransferFrom);
        vm.prank(alice);
        vm.expectRevert(MockFailingERC20.MockFailure.selector);
        p.addLiquidity(4e18, 1e18, 0, 0, 0, alice, block.timestamp);
        _assertNothingChanged(p, good, bad);
    }

    function test_L23_token1ReturnsFalseRollsBackAll() public {
        (AMMPool p, MockERC20 good, MockFailingERC20 bad) = _failingPool();
        bad.setMode(MockFailingERC20.Mode.ReturnFalseTransferFrom);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad)));
        p.addLiquidity(4e18, 1e18, 0, 0, 0, alice, block.timestamp);
        _assertNothingChanged(p, good, bad);
    }

    function test_L23_token1BalanceOfRevertRollsBackAll() public {
        (AMMPool p, MockERC20 good, MockFailingERC20 bad) = _failingPool();
        bad.setMode(MockFailingERC20.Mode.RevertBalanceOf);
        vm.prank(alice);
        vm.expectRevert(MockFailingERC20.MockFailure.selector);
        p.addLiquidity(4e18, 1e18, 0, 0, 0, alice, block.timestamp);
        _assertNothingChanged(p, good, bad);
    }

    function test_L23_insufficientBalanceOrAllowanceRollsBack() public {
        address dave = makeAddr("dave");
        t0.mint(dave, 10e18);
        t1.mint(dave, 10e18);
        vm.startPrank(dave);
        t0.approve(address(pool), 10e18);
        t1.approve(address(pool), 1); // token1 allowance too small
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pool), 1, 1e18)
        );
        pool.addLiquidity(4e18, 1e18, 0, 0, 0, dave, block.timestamp);
        vm.stopPrank();
        assertEq(t0.balanceOf(dave), 10e18, "token0 pull rolled back");
        assertEq(t0.allowance(dave, address(pool)), 10e18, "token0 allowance restored");
        assertEq(pool.totalSupply(), 0);
    }

    // ------------------------------------------------------------------
    // L24 — reentrancy smoke test (full attack suite in M5)
    // ------------------------------------------------------------------

    function test_L24_tokenCallbackCannotReenterAddLiquidity() public {
        ReentrantERC20 evil = new ReentrantERC20("Evil", "EVL", 18);
        MockERC20 good = new MockERC20("Good", "GOOD", 18);
        AMMPool p = _newPool(address(evil), address(good));
        evil.arm(address(p), abi.encodeCall(AMMPool.addLiquidity, (1e18, 1e18, 0, 0, 0, alice, block.timestamp)));

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        p.addLiquidity(4e18, 1e18, 0, 0, 0, alice, block.timestamp);
        assertEq(p.totalSupply(), 0);
    }

    // ------------------------------------------------------------------
    // L25 — events
    // ------------------------------------------------------------------

    function test_L25_events() public {
        vm.expectEmit(true, true, false, true, address(pool));
        emit IERC20.Transfer(address(0), address(pool), LOCK);
        vm.expectEmit(true, true, false, true, address(pool));
        emit IERC20.Transfer(address(0), bob, 2e18 - LOCK);
        vm.expectEmit(true, true, false, true, address(pool));
        emit AMMPool.LiquidityAdded(alice, bob, 4e18, 1e18, 2e18 - LOCK);
        _add(pool, 4e18, 1e18, 0, bob);
    }

    // ------------------------------------------------------------------
    // P01, P02 — standard LP ERC-20 behaviour
    // ------------------------------------------------------------------

    function test_P01_transferMovesOwnership() public {
        (,, uint256 s) = _add(pool, 4e18, 1e18, 0, alice);
        vm.prank(alice);
        pool.transfer(bob, 1e18);
        assertEq(pool.balanceOf(alice), s - 1e18);
        assertEq(pool.balanceOf(bob), 1e18);
        assertEq(pool.totalSupply(), 2e18);
    }

    function test_P02_approveTransferFromAllowance() public {
        _add(pool, 4e18, 1e18, 0, alice);
        vm.prank(alice);
        pool.approve(bob, 5e17);
        vm.prank(bob);
        pool.transferFrom(alice, carol, 2e17);
        assertEq(pool.allowance(alice, bob), 3e17);
        assertEq(pool.balanceOf(carol), 2e17);
    }

    function test_P01_metadata() public view {
        assertEq(pool.name(), "AMM Liquidity Provider");
        assertEq(pool.symbol(), "AMM-LP");
        assertEq(pool.decimals(), 18);
    }

    // ------------------------------------------------------------------
    // P04 — no external mint/burn entry point
    // ------------------------------------------------------------------

    function test_P04_noExternalMintOrBurn() public {
        _add(pool, 4e18, 1e18, 0, alice);
        uint256 supply = pool.totalSupply();
        bytes[4] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", alice, 1),
            abi.encodeWithSignature("burn(address,uint256)", alice, 1),
            abi.encodeWithSignature("burn(uint256)", 1),
            abi.encodeWithSignature("_mint(address,uint256)", alice, 1)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(pool).call(calls[i]);
            assertFalse(ok);
        }
        assertEq(pool.totalSupply(), supply);
    }

    // ------------------------------------------------------------------
    // P05, P06, P07 — lock and LP-SELF
    // ------------------------------------------------------------------

    function test_P05_poolLPZeroBeforeAndExactlyLockAfter() public {
        assertEq(pool.balanceOf(address(pool)), 0);
        _add(pool, 4e18, 1e18, 0, alice);
        assertEq(pool.balanceOf(address(pool)), LOCK);
    }

    function test_P06_transferToPoolReverts() public {
        _add(pool, 4e18, 1e18, 0, alice);
        vm.startPrank(alice);
        vm.expectRevert(AMMPool.LPTransferToPool.selector);
        pool.transfer(address(pool), 1);
        vm.expectRevert(AMMPool.LPTransferToPool.selector);
        pool.transfer(address(pool), 0); // zero-value transfer to the Pool is also forbidden
        vm.stopPrank();
        assertEq(pool.balanceOf(address(pool)), LOCK);
    }

    function test_P06_transferFromToPoolReverts() public {
        _add(pool, 4e18, 1e18, 0, alice);
        vm.prank(alice);
        pool.approve(bob, 1e18);
        vm.startPrank(bob);
        vm.expectRevert(AMMPool.LPTransferToPool.selector);
        pool.transferFrom(alice, address(pool), 1);
        vm.expectRevert(AMMPool.LPTransferToPool.selector);
        pool.transferFrom(alice, address(pool), 0);
        vm.stopPrank();
    }

    /// Even if the Pool address could act (it cannot: no key, no code path), its LP stays locked.
    function test_P07_poolHeldLPCannotMove() public {
        _add(pool, 4e18, 1e18, 0, alice);
        vm.startPrank(address(pool));
        vm.expectRevert(AMMPool.LockedLiquidity.selector);
        pool.transfer(alice, 1);
        vm.expectRevert(AMMPool.LockedLiquidity.selector);
        pool.transfer(alice, 0);
        pool.approve(bob, LOCK); // approve itself does not move balances
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(AMMPool.LockedLiquidity.selector);
        pool.transferFrom(address(pool), bob, 1);
        assertEq(pool.balanceOf(address(pool)), LOCK);
    }

    // ------------------------------------------------------------------
    // P08 — mint/burn call sites are controlled (future-code simulation)
    // ------------------------------------------------------------------

    function test_P08_supplyChangesOutsideGuardRevert() public {
        AMMPoolSupplyHarness h = new AMMPoolSupplyHarness(address(t0), address(t1), recipient);
        vm.expectRevert(AMMPool.SupplyChangeOutsideGuard.selector);
        h.unguardedMint(alice, 1);
        vm.expectRevert(AMMPool.SupplyChangeOutsideGuard.selector);
        h.unguardedBurn(alice, 0);
    }

    function test_P08_secondMintToPoolRejectedEvenWhenGuarded() public {
        AMMPoolSupplyHarness h = new AMMPoolSupplyHarness(address(t0), address(t1), recipient);
        vm.expectRevert(AMMPool.LPTransferToPool.selector);
        h.guardedMint(address(h), 999); // wrong amount for the lock
        h.guardedMint(address(h), LOCK); // the one permitted lock mint (totalSupply == 0)
        vm.expectRevert(AMMPool.LPTransferToPool.selector);
        h.guardedMint(address(h), LOCK); // a second one is rejected
        vm.expectRevert(AMMPool.LockedLiquidity.selector);
        h.guardedBurn(address(h), 1);
        assertEq(h.balanceOf(address(h)), LOCK);
    }

    // ------------------------------------------------------------------
    // P09 — failed transfers leave no residue
    // ------------------------------------------------------------------

    function test_P09_failedTransferFromLeavesNoResidue() public {
        (,, uint256 s) = _add(pool, 4e18, 1e18, 0, alice);
        vm.prank(alice);
        pool.approve(bob, 1e18);

        vm.startPrank(bob);
        vm.expectRevert(AMMPool.LPTransferToPool.selector); // to the Pool
        pool.transferFrom(alice, address(pool), 5e17);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 1e18, 1e18 + 1));
        pool.transferFrom(alice, carol, 1e18 + 1); // above allowance
        vm.stopPrank();

        vm.prank(alice);
        pool.approve(bob, type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, s, s + 1));
        pool.transferFrom(alice, carol, s + 1); // above balance

        assertEq(pool.allowance(alice, bob), type(uint256).max);
        assertEq(pool.balanceOf(alice), s);
        assertEq(pool.balanceOf(carol), 0);
        assertEq(pool.balanceOf(address(pool)), LOCK);
    }

    function test_P09_allowanceUnchangedAfterRevertedTransferFrom() public {
        _add(pool, 4e18, 1e18, 0, alice);
        vm.prank(alice);
        pool.approve(bob, 1e18);
        vm.prank(bob);
        vm.expectRevert(AMMPool.LPTransferToPool.selector);
        pool.transferFrom(alice, address(pool), 1e18);
        assertEq(pool.allowance(alice, bob), 1e18, "spent allowance restored by the revert");
    }

    // ------------------------------------------------------------------
    // P10 — supply / lock accounting across operation sequences (BI-7, BI-8)
    // ------------------------------------------------------------------

    function testFuzz_P10_accountingHoldsAcrossSequences(uint256 a0, uint256 a1, uint256 x, uint256 y, uint256 z)
        public
    {
        a0 = bound(a0, 1e6, 1e27);
        a1 = bound(a1, 1e6, 1e27);
        (,, uint256 s) = _add(pool, a0, a1, 0, alice);
        uint256 supply = pool.totalSupply();
        assertEq(supply, s + LOCK);

        x = bound(x, 0, s);
        vm.prank(alice);
        pool.transfer(bob, x);
        y = bound(y, 0, x);
        vm.prank(bob);
        pool.approve(carol, y);
        z = bound(z, 0, y);
        vm.prank(carol);
        pool.transferFrom(bob, carol, z);

        // Failed operations in between must not disturb accounting.
        vm.prank(alice);
        vm.expectRevert(AMMPool.LPTransferToPool.selector);
        pool.transfer(address(pool), 0);
        vm.expectRevert(AMMPool.LaterDepositNotImplemented.selector);
        _add(pool, a0, a1, 0, alice);

        assertEq(pool.totalSupply(), supply, "BI-8: supply changes only by add/remove");
        assertEq(pool.totalSupply(), LOCK + _userLP(pool), "supply = lock + holders");
        assertEq(pool.balanceOf(address(pool)), LOCK, "BI-7");
    }

    // ------------------------------------------------------------------
    // R01 (re-run with a reserve writer present)
    // ------------------------------------------------------------------

    function test_R01_directTransferAfterDepositDoesNotChangeReserves() public {
        _add(pool, 4e18, 1e18, 0, alice);
        t0.mint(address(pool), 9e18);
        t1.mint(address(pool), 9e18);
        (uint256 r0, uint256 r1) = _reserves(pool);
        assertEq(r0, 4e18);
        assertEq(r1, 1e18);
    }
}
