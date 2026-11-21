// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {IAMMPool} from "../src/interfaces/IAMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockDeficitERC20} from "./mocks/MockDeficitERC20.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";
import {addParams, addParamsOrdered} from "./utils/AddParams.sol";

/// @notice M8 commit 4 (WORK IN PROGRESS until M8 acceptance): in-call balance rule BI-2′ for
///         `addLiquidity` (DECISIONS M8-11, X1; ARCHITECTURE §5.5). TEST_MATRIX B09 and the
///         InCallBalanceLoss part of L40. Hook token H (`ReentrantERC20`) calls the victim token
///         V (`MockDeficitERC20`) during H's own `transferFrom`: `slash(pool, x)` removes Pool
///         tokens (foreign loss), `mint(pool, x)` adds them (foreign gift). H is placed as token0
///         and as token1 (both directions); both pull orders. Every revert asserts the exact
///         error and full-state rollback. Fresh, never-reused addresses for every fixture.
contract AMMPoolInCallBalanceTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant FUND = 1e30;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal surplusRecipient = makeAddr("surplusRecipient");

    AMMPool internal p;
    ReentrantERC20 internal h;
    MockDeficitERC20 internal v;
    bool internal hIsToken0;
    uint160 internal nextLow = 0x30000;
    uint160 internal nextHigh = type(uint160).max - 0x1000;

    bytes internal lossErr = abi.encodeWithSelector(AMMPool.InCallBalanceLoss.selector);

    // ------------------------------------------------------------------
    // Fixture
    // ------------------------------------------------------------------

    function _deploy(string memory artifact, bool low) internal returns (address at) {
        at = low ? address(nextLow++) : address(nextHigh--);
        require(at.code.length == 0, "address reused");
        deployCodeTo(artifact, abi.encode("T", "T", uint8(18)), at);
    }

    /// @dev k in 0..3: H is token0 for k < 2; token1First = (k odd). Alice's initial deposit is
    ///      (i0, i1) in token order, skipped when i0 == 0 (initial-path cases).
    function _setUp(uint256 k, uint256 i0, uint256 i1) internal returns (bool t1First) {
        hIsToken0 = k < 2;
        t1First = k % 2 == 1;
        h = ReentrantERC20(_deploy("ReentrantERC20.sol:ReentrantERC20", hIsToken0));
        v = MockDeficitERC20(_deploy("MockDeficitERC20.sol:MockDeficitERC20", !hIsToken0));
        p = new AMMPool(hIsToken0 ? address(h) : address(v), hIsToken0 ? address(v) : address(h), surplusRecipient);
        address[2] memory users = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            h.mint(users[i], FUND);
            v.mint(users[i], FUND);
            vm.startPrank(users[i]);
            h.approve(address(p), MAX);
            v.approve(address(p), MAX);
            vm.stopPrank();
        }
        if (i0 != 0) {
            vm.prank(alice);
            p.addLiquidity(addParams(i0, i1, 0, alice, block.timestamp));
        }
    }

    function _armSlashPool(uint256 x) internal {
        h.armWith(
            address(v), abi.encodeCall(MockDeficitERC20.slash, (address(p), x)), ReentrantERC20.Hook.TransferFrom, false
        );
    }

    function _armGiftPool(uint256 x) internal {
        h.armWith(address(v), abi.encodeCall(MockERC20.mint, (address(p), x)), ReentrantERC20.Hook.TransferFrom, false);
    }

    function _surplusV() internal view returns (uint256) {
        (uint256 r0, uint256 r1) = p.getReserves();
        return v.balanceOf(address(p)) - (hIsToken0 ? r1 : r0);
    }

    function _surplusH() internal view returns (uint256) {
        (uint256 r0, uint256 r1) = p.getReserves();
        return h.balanceOf(address(p)) - (hIsToken0 ? r0 : r1);
    }

    struct State {
        uint256 r0;
        uint256 r1;
        uint256 supply;
        uint256 bobLP;
        uint256 poolH;
        uint256 poolV;
        uint256 bobH;
        uint256 bobV;
        uint256 allowH;
        uint256 allowV;
        bool armed;
    }

    function _state() internal view returns (State memory s) {
        (s.r0, s.r1) = p.getReserves();
        s.supply = p.totalSupply();
        s.bobLP = p.balanceOf(bob);
        (s.poolH, s.poolV) = (h.balanceOf(address(p)), v.balanceOf(address(p)));
        (s.bobH, s.bobV) = (h.balanceOf(bob), v.balanceOf(bob));
        (s.allowH, s.allowV) = (h.allowance(bob, address(p)), v.allowance(bob, address(p)));
        s.armed = h.armed();
    }

    function _expectRevert(IAMMPool.AddLiquidityParams memory prm, bytes memory err) internal {
        State memory b = _state();
        vm.prank(bob);
        (bool ok, bytes memory ret) = address(p).call(abi.encodeCall(AMMPool.addLiquidity, (prm)));
        assertFalse(ok, "must revert");
        assertEq(ret, err, "exact error");
        assertEq(keccak256(abi.encode(_state())), keccak256(abi.encode(b)), "full-state rollback");
    }

    function _add(IAMMPool.AddLiquidityParams memory prm) internal returns (uint256 n0, uint256 n1, uint256 s) {
        vm.prank(bob);
        return p.addLiquidity(prm);
    }

    // ------------------------------------------------------------------
    // (a) surplus unchanged: pre-existing surplus in both tokens, no foreign change
    // ------------------------------------------------------------------

    function test_B09a_preExistingSurplusUnchanged_later_allCases() public {
        for (uint256 k; k < 4; ++k) {
            bool t1First = _setUp(k, 1e21, 1e21);
            h.mint(address(p), 300e18);
            v.mint(address(p), 700e18);
            _add(addParamsOrdered(1e18, 1e18, 0, bob, block.timestamp, t1First));
            assertEq(_surplusH(), 300e18, "H surplus unchanged");
            assertEq(_surplusV(), 700e18, "V surplus unchanged");
        }
    }

    function test_B09a_preExistingSurplusUnchanged_initial_allCases() public {
        for (uint256 k; k < 4; ++k) {
            bool t1First = _setUp(k, 0, 0);
            h.mint(address(p), 300e18);
            v.mint(address(p), 700e18);
            _add(addParamsOrdered(4e18, 1e18, 0, bob, block.timestamp, t1First));
            assertEq(_surplusH(), 300e18);
            assertEq(_surplusV(), 700e18);
        }
    }

    /// @dev The hook token's own shortfall (it withholds 2 units from the Pool after the move) is
    ///      part of its own measured net, not a foreign loss: BI-2′ passes, surplus unchanged.
    function test_B09a_ownShortfallIsNotAForeignLoss_allCases() public {
        for (uint256 k; k < 4; ++k) {
            bool t1First = _setUp(k, 1e21, 1e21);
            v.mint(address(p), 5e18);
            h.setFaults(0, 2);
            (uint256 n0, uint256 n1,) = _add(addParamsOrdered(1e18, 1e18, 0, bob, block.timestamp, t1First));
            assertEq(hIsToken0 ? n0 : n1, 1e18 - 2, "H arrived 2 short");
            assertEq(_surplusH(), 0);
            assertEq(_surplusV(), 5e18);
        }
    }

    // ------------------------------------------------------------------
    // (b) surplus increases: foreign gift during H's pull (B08 generalised)
    // ------------------------------------------------------------------

    function test_B09b_foreignGiftIncreasesSurplus_later_allCases() public {
        for (uint256 k; k < 4; ++k) {
            bool t1First = _setUp(k, 1e21, 1e21);
            _armGiftPool(31_337);
            (uint256 n0, uint256 n1,) = _add(addParamsOrdered(1e18, 1e18, 0, bob, block.timestamp, t1First));
            assertTrue(h.callbackRan());
            assertEq(hIsToken0 ? n1 : n0, 1e18, "the gift is not counted as the payer's input");
            assertEq(_surplusV(), 31_337, "surplus rose by the gift");
            assertEq(_surplusH(), 0);
        }
    }

    function test_B09b_foreignGiftIncreasesSurplus_initial_allCases() public {
        for (uint256 k; k < 4; ++k) {
            bool t1First = _setUp(k, 0, 0);
            _armGiftPool(31_337);
            _add(addParamsOrdered(4e18, 1e18, 0, bob, block.timestamp, t1First));
            assertEq(_surplusV(), 31_337);
        }
    }

    // ------------------------------------------------------------------
    // (c) surplus decreases, masked: no deficit would result, still rejected
    // ------------------------------------------------------------------

    /// @dev M8-11 example scaled by 1e18: r_V = 1000, B_V = 1300 (surplus 300), 200 removed
    ///      during H's pull, n_V = 500. End balance 1600 ≥ new reserve 1500 (no deficit), but
    ///      the surplus fell from 300 to 100 → InCallBalanceLoss, full rollback.
    function test_B09c_maskedSurplusLoss_later_allCases() public {
        for (uint256 k; k < 4; ++k) {
            bool t1First = _setUp(k, 1000e18, 1000e18);
            v.mint(address(p), 300e18);
            _armSlashPool(200e18);
            _expectRevert(addParamsOrdered(500e18, 500e18, 0, bob, block.timestamp, t1First), lossErr);
        }
    }

    function test_B09c_maskedSurplusLoss_initial_allCases() public {
        for (uint256 k; k < 4; ++k) {
            bool t1First = _setUp(k, 0, 0);
            v.mint(address(p), 300e18);
            _armSlashPool(200e18);
            _expectRevert(addParamsOrdered(4e18, 4e18, 0, bob, block.timestamp, t1First), lossErr);
        }
    }

    // ------------------------------------------------------------------
    // (d) loss that would create a deficit; loss larger than the own net (end < start)
    // ------------------------------------------------------------------

    function test_B09d_zeroSurplusLossOfOneUnit_allCases() public {
        for (uint256 k; k < 4; ++k) {
            bool t1First = _setUp(k, 1e21, 1e21);
            _armSlashPool(1);
            _expectRevert(addParamsOrdered(1e18, 1e18, 0, bob, block.timestamp, t1First), lossErr);
        }
    }

    /// @dev 3e18 removed while only 1e18 is added: the Pool's V balance ends BELOW its start.
    ///      The check reports InCallBalanceLoss, never an underflow Panic.
    function test_B09d_lossLargerThanOwnNet_endBelowStart_allCases() public {
        for (uint256 k; k < 4; ++k) {
            bool t1First = _setUp(k, 1e21, 1e21);
            _armSlashPool(3e18);
            _expectRevert(addParamsOrdered(1e18, 1e18, 0, bob, block.timestamp, t1First), lossErr);
        }
    }

    // ------------------------------------------------------------------
    // (e) subtraction form near type(uint256).max
    // ------------------------------------------------------------------

    /// @dev V surplus near the token's maximum supply: a 1-unit foreign loss is still caught and
    ///      the success case still passes; no overflow anywhere in the comparison.
    function testFuzz_B09e_largeBalances(uint256 surplus, uint256 loss, uint256 k) public {
        k = bound(k, 0, 3);
        bool t1First = _setUp(k, 1e21, 1e21);
        surplus = bound(surplus, 0, MAX - v.totalSupply() - 1e18);
        loss = bound(loss, 0, surplus);
        v.mint(address(p), surplus);
        IAMMPool.AddLiquidityParams memory prm = addParamsOrdered(1e18, 1e18, 0, bob, block.timestamp, t1First);
        if (loss == 0) {
            _add(prm);
            assertEq(_surplusV(), surplus);
        } else {
            _armSlashPool(loss);
            _expectRevert(prm, lossErr);
        }
    }

    // ------------------------------------------------------------------
    // L40 (InCallBalanceLoss part) — priority over PayerDebitTooHigh and the later checks
    // ------------------------------------------------------------------

    /// @dev Both conditions fail (Pool V slashed; H's maxDebit one below its debit):
    ///      InCallBalanceLoss is reported first. Control without the hook: PayerDebitTooHigh.
    function test_L40_inCallBalanceLossBeforePayerDebitTooHigh_allCases() public {
        for (uint256 k; k < 4; ++k) {
            bool t1First = _setUp(k, 1e21, 1e21);
            IAMMPool.AddLiquidityParams memory prm = addParamsOrdered(1e18, 1e18, 0, bob, block.timestamp, t1First);
            if (hIsToken0) prm.maxDebit0 = 1e18 - 1;
            else prm.maxDebit1 = 1e18 - 1;
            _expectRevert(prm, abi.encodeWithSelector(AMMPool.PayerDebitTooHigh.selector)); // control
            _armSlashPool(1);
            _expectRevert(prm, lossErr);
        }
    }

    /// @dev σ == 0 (Z07 numbers) together with a foreign loss: InCallBalanceLoss first.
    function test_L40_inCallBalanceLossBeforeInsufficientShares() public {
        _setUp(0, 1001, 1002);
        IAMMPool.AddLiquidityParams memory prm = addParams(1, 1, 0, bob, block.timestamp);
        _expectRevert(prm, abi.encodeWithSelector(AMMPool.InsufficientShares.selector)); // control
        v.mint(address(p), 10);
        _armSlashPool(1);
        _expectRevert(prm, lossErr);
    }
}
