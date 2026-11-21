// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MockFeeERC20} from "./mocks/MockFeeERC20.sol";
import {MockFailingERC20} from "./mocks/MockFailingERC20.sol";

/// @notice Self-tests for the M8 mocks (TEST_MATRIX §3.2 test-method rules): every behaviour a
///         Pool test relies on — payer debit, recipient credit, who bears an inclusive fee, where
///         an exclusive extra is taken, reproducible random tax, full restore after a failed
///         transfer — is checked here first, so a later Pool failure points at the Pool.
contract FeeMocksTest is Test {
    address internal payer = makeAddr("payer");
    address internal pool = makeAddr("pool"); // plays the Pool: the spender of transferFrom
    address internal user = makeAddr("user");

    MockFeeERC20 internal t;

    MockFeeERC20.Path internal constant PULL = MockFeeERC20.Path.TransferFrom;
    MockFeeERC20.Path internal constant PUSH = MockFeeERC20.Path.Transfer;

    function setUp() public {
        t = new MockFeeERC20("Fee", "FEE", 18);
        t.mint(payer, 10_000);
        vm.prank(payer);
        t.approve(pool, type(uint256).max);
    }

    struct Bal {
        uint256 payer;
        uint256 pool;
        uint256 supply;
        uint256 allowance;
    }

    function _bal() internal view returns (Bal memory b) {
        b.payer = t.balanceOf(payer);
        b.pool = t.balanceOf(pool);
        b.supply = t.totalSupply();
        b.allowance = t.allowance(payer, pool);
    }

    function _pull(uint256 value) internal {
        vm.prank(pool);
        t.transferFrom(payer, pool, value);
    }

    // ------------------------------------------------------------------
    // Fixed amounts: 10% on a transfer of 1000
    // ------------------------------------------------------------------

    function test_inclusiveTax_payerPaysValue_recipientBearsShortfall() public {
        t.setTax(PULL, 1000);
        vm.prank(payer);
        t.approve(pool, 1000);
        _pull(1000);
        assertEq(t.balanceOf(payer), 9000, "payer debited exactly value");
        assertEq(t.balanceOf(pool), 900, "recipient receives value - fee");
        assertEq(t.totalSupply(), 9900, "fee burned");
        assertEq(t.allowance(payer, pool), 0, "allowance spent by value");
        assertEq(t.lastTaxBps(), 1000);
        assertEq(t.callCount(uint256(PULL)), 1);
    }

    function test_exclusiveExtra_takenFromSender_recipientGetsValue() public {
        t.setExtra(PULL, 1000);
        vm.prank(payer);
        t.approve(pool, 1000);
        _pull(1000);
        assertEq(t.balanceOf(payer), 10_000 - 1100, "payer loses value + extra");
        assertEq(t.balanceOf(pool), 1000, "recipient credited exactly value");
        assertEq(t.totalSupply(), 10_000 - 100, "extra burned");
        assertEq(t.allowance(payer, pool), 0, "allowance spent by value only, not by the extra");
    }

    function test_bonus_recipientCreditedMore() public {
        t.setBonus(PULL, 7);
        _pull(1000);
        assertEq(t.balanceOf(payer), 9000);
        assertEq(t.balanceOf(pool), 1007, "recipient receives value + bonus");
        assertEq(t.totalSupply(), 10_007, "bonus minted");
    }

    function test_combined_taxExtraBonus() public {
        t.setTax(PULL, 1000);
        t.setExtra(PULL, 500);
        t.setBonus(PULL, 3);
        _pull(1000);
        assertEq(t.balanceOf(payer), 10_000 - 1000 - 50);
        assertEq(t.balanceOf(pool), 900 + 3);
        assertEq(t.totalSupply(), 10_000 - 100 - 50 + 3);
    }

    function test_fullTax_recipientReceivesZero() public {
        t.setTax(PULL, 10_000);
        _pull(1000);
        assertEq(t.balanceOf(payer), 9000, "payer still debited value");
        assertEq(t.balanceOf(pool), 0, "100% tax: nothing arrives");
        assertEq(t.totalSupply(), 9000);
    }

    function test_floorRounding_smallValues() public {
        t.setTax(PULL, 999); // 9.99%
        _pull(1000); // fee = floor(99.9) = 99
        assertEq(t.balanceOf(pool), 901);
        _pull(10); // fee = floor(0.999) = 0: small transfers escape the tax
        assertEq(t.balanceOf(pool), 911);
        assertEq(t.balanceOf(payer), 10_000 - 1010, "payer always debited value");
    }

    // ------------------------------------------------------------------
    // Path separation and switching after the fact
    // ------------------------------------------------------------------

    function test_pathsAreIndependent() public {
        t.setTax(PULL, 1000);
        _pull(1000);
        assertEq(t.balanceOf(pool), 900);
        // Push is untouched by the pull setting.
        vm.prank(pool);
        t.transfer(user, 100);
        assertEq(t.balanceOf(user), 100, "transfer path standard");
        assertEq(t.balanceOf(pool), 800);

        // And the other way round.
        t.setTax(PULL, 0);
        t.setExtra(PUSH, 1000);
        _pull(1000);
        assertEq(t.balanceOf(pool), 1800, "pull now standard");
        vm.prank(pool);
        t.transfer(user, 100);
        assertEq(t.balanceOf(user), 200);
        assertEq(t.balanceOf(pool), 1800 - 110, "push over-debits the sender");
        assertEq(t.callCount(uint256(PULL)), 2);
        assertEq(t.callCount(uint256(PUSH)), 2);
    }

    function test_mintAndBurnUntaxed() public {
        t.setTax(PULL, 5000);
        t.setTax(PUSH, 5000);
        t.setExtra(PULL, 5000);
        t.setExtra(PUSH, 5000);
        t.setBonus(PUSH, 9);
        t.mint(user, 1234);
        assertEq(t.balanceOf(user), 1234);
        assertEq(t.callCount(uint256(PULL)) + t.callCount(uint256(PUSH)), 0);
    }

    // ------------------------------------------------------------------
    // Schedule and reproducible random tax
    // ------------------------------------------------------------------

    function test_schedule_fifoThenFallbackToFixed() public {
        t.setTax(PULL, 250);
        uint256[] memory s = new uint256[](4);
        (s[0], s[1], s[2], s[3]) = (0, 10_000, 1, 9999);
        t.pushTaxSchedule(PULL, s);
        assertEq(t.scheduleRemaining(PULL), 4);
        for (uint256 i; i < 4; ++i) {
            _pull(100);
            assertEq(t.lastTaxBps(), s[i], "schedule order");
        }
        assertEq(t.scheduleRemaining(PULL), 0);
        _pull(100);
        assertEq(t.lastTaxBps(), 250, "falls back to the fixed tax");
        assertEq(t.scheduleRemaining(PUSH), 0, "other path's schedule untouched");
    }

    function test_schedule_takesPriorityOverRandom() public {
        t.setRandomTax(PULL, 42, 0, 10_000);
        uint256[] memory s = new uint256[](1);
        s[0] = 7;
        t.pushTaxSchedule(PULL, s);
        _pull(100);
        assertEq(t.lastTaxBps(), 7);
        assertEq(t.config(PULL).nonce, 0, "random nonce not consumed by a scheduled transfer");
    }

    /// @dev Independent oracle for the documented formula.
    function _expectedBps(uint256 seed, uint256 nonce, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + uint256(keccak256(abi.encode(seed, nonce))) % (hi - lo + 1);
    }

    function test_random_reproducibleFromSeed() public {
        MockFeeERC20 u = new MockFeeERC20("Fee2", "FEE2", 18);
        u.mint(payer, 10_000);
        vm.prank(payer);
        u.approve(pool, type(uint256).max);
        t.setRandomTax(PULL, 2026, 100, 900);
        u.setRandomTax(PULL, 2026, 100, 900);
        for (uint256 i; i < 20; ++i) {
            _pull(10);
            vm.prank(pool);
            u.transferFrom(payer, pool, 10);
            uint256 e = _expectedBps(2026, i, 100, 900);
            assertEq(t.lastTaxBps(), e, "matches the formula");
            assertEq(u.lastTaxBps(), e, "same seed, same sequence");
        }
        // Re-seeding resets the nonce: the sequence restarts.
        t.setRandomTax(PULL, 2026, 100, 900);
        _pull(10);
        assertEq(t.lastTaxBps(), _expectedBps(2026, 0, 100, 900));
    }

    function test_random_setTaxSwitchesRandomOff() public {
        t.setRandomTax(PULL, 1, 0, 10_000);
        t.setTax(PULL, 30);
        _pull(1000);
        assertEq(t.lastTaxBps(), 30);
    }

    function testFuzz_random_withinRange(uint256 seed, uint256 lo, uint256 hi) public {
        lo = bound(lo, 0, 10_000);
        hi = bound(hi, lo, 10_000);
        t.setRandomTax(PULL, seed, lo, hi);
        for (uint256 i; i < 5; ++i) {
            _pull(1);
            uint256 bps = t.lastTaxBps();
            assertGe(bps, lo);
            assertLe(bps, hi);
            assertEq(bps, _expectedBps(seed, i, lo, hi));
        }
    }

    function test_invalidConfigReverts() public {
        vm.expectRevert(MockFeeERC20.InvalidBps.selector);
        t.setTax(PULL, 10_001);
        vm.expectRevert(MockFeeERC20.InvalidBps.selector);
        t.setRandomTax(PULL, 0, 10, 9);
        vm.expectRevert(MockFeeERC20.InvalidBps.selector);
        t.setRandomTax(PULL, 0, 0, 10_001);
        uint256[] memory s = new uint256[](2);
        (s[0], s[1]) = (1, 10_001);
        vm.expectRevert(MockFeeERC20.InvalidBps.selector);
        t.pushTaxSchedule(PULL, s);
        assertEq(t.scheduleRemaining(PULL), 0, "a rejected schedule is not partly stored");
    }

    // ------------------------------------------------------------------
    // Failure restores everything
    // ------------------------------------------------------------------

    function _assertUnchanged(Bal memory b) internal view {
        Bal memory a = _bal();
        assertEq(a.payer, b.payer, "payer balance restored");
        assertEq(a.pool, b.pool, "recipient balance restored");
        assertEq(a.supply, b.supply, "supply restored");
        assertEq(a.allowance, b.allowance, "allowance restored");
    }

    function test_failure_extraNotCoveredRevertsAndRestores() public {
        t.setExtra(PULL, 1000);
        t.setRandomTax(PULL, 5, 0, 500);
        Bal memory b = _bal();
        // payer holds 10_000: value 10_000 is covered, but value + extra (11_000) is not.
        vm.prank(pool);
        vm.expectRevert(); // OZ ERC20InsufficientBalance from the extra burn
        t.transferFrom(payer, pool, 10_000);
        _assertUnchanged(b);
        assertEq(t.callCount(uint256(PULL)), 0, "trace rolled back");
        assertEq(t.config(PULL).nonce, 0, "random nonce rolled back");
    }

    function test_failure_insufficientAllowanceRestores() public {
        t.setTax(PULL, 1000);
        vm.prank(payer);
        t.approve(pool, 999);
        Bal memory b = _bal();
        vm.prank(pool);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, pool, 999, 1000));
        t.transferFrom(payer, pool, 1000);
        _assertUnchanged(b);
    }

    function test_failure_scheduleRolledBack() public {
        uint256[] memory s = new uint256[](1);
        s[0] = 100;
        t.pushTaxSchedule(PULL, s);
        vm.prank(pool);
        vm.expectRevert();
        t.transferFrom(payer, pool, 10_001); // exceeds the payer's balance
        assertEq(t.scheduleRemaining(PULL), 1, "schedule position rolled back");
    }

    // ------------------------------------------------------------------
    // Conservation (fuzz)
    // ------------------------------------------------------------------

    function testFuzz_conservation(uint256 value, uint256 taxBps, uint256 extraBps, uint256 bonus) public {
        value = bound(value, 0, 1e30);
        taxBps = bound(taxBps, 0, 10_000);
        extraBps = bound(extraBps, 0, 20_000);
        bonus = bound(bonus, 0, 1e30);
        t.mint(payer, 3e30);
        t.setTax(PULL, taxBps);
        t.setExtra(PULL, extraBps);
        t.setBonus(PULL, bonus);
        Bal memory b = _bal();
        _pull(value);
        uint256 fee = value * taxBps / 10_000;
        uint256 extra = value * extraBps / 10_000;
        Bal memory a = _bal();
        assertEq(b.payer - a.payer, value + extra, "payer debit");
        assertEq(a.pool - b.pool, value - fee + bonus, "recipient credit");
        assertEq(a.supply + fee + extra, b.supply + bonus, "supply change");
    }

    // ------------------------------------------------------------------
    // MockFailingERC20: appended RevertAllTransfers mode
    // ------------------------------------------------------------------

    function test_failing_modeNumberingUnchanged() public pure {
        assertEq(uint8(MockFailingERC20.Mode.None), 0);
        assertEq(uint8(MockFailingERC20.Mode.RevertTransferFrom), 1);
        assertEq(uint8(MockFailingERC20.Mode.ReturnFalseTransferFrom), 2);
        assertEq(uint8(MockFailingERC20.Mode.RevertBalanceOf), 3);
        assertEq(uint8(MockFailingERC20.Mode.RevertTransfer), 4);
        assertEq(uint8(MockFailingERC20.Mode.ReturnFalseTransfer), 5);
        assertEq(uint8(MockFailingERC20.Mode.RevertAllTransfers), 6);
    }

    function test_failing_revertAllTransfers() public {
        MockFailingERC20 f = new MockFailingERC20("Fail", "FAIL", 18);
        f.mint(payer, 1000);
        vm.prank(payer);
        f.approve(pool, 1000);
        f.setMode(MockFailingERC20.Mode.RevertAllTransfers);

        vm.prank(payer);
        vm.expectRevert(MockFailingERC20.MockFailure.selector);
        f.transfer(user, 1);

        vm.prank(pool);
        vm.expectRevert(MockFailingERC20.MockFailure.selector);
        f.transferFrom(payer, pool, 1);

        assertEq(f.balanceOf(payer), 1000, "balanceOf still works; nothing moved");
        assertEq(f.balanceOf(pool), 0);
        assertEq(f.allowance(payer, pool), 1000);

        // Switching back restores normal behaviour (X06: "restoring X makes exit work again").
        f.setMode(MockFailingERC20.Mode.None);
        vm.prank(pool);
        f.transferFrom(payer, pool, 1);
        assertEq(f.balanceOf(pool), 1);
    }
}
