// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {IAMMPool} from "../src/interfaces/IAMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeERC20} from "./mocks/MockFeeERC20.sol";
import {MockFailingERC20} from "./mocks/MockFailingERC20.sol";
import {MockDeficitERC20} from "./mocks/MockDeficitERC20.sol";
import {addParams, addParamsOrdered} from "./utils/AddParams.sol";

/// @notice M8 measured-net deposit, tests shipped with M8 commit 2 (WORK IN PROGRESS: maxDebit
///         and BI-2′ follow in commits 3 and 4). TEST_MATRIX L30 (interface), L42 (re-planned
///         zero target), L43 (canonical token order). Further M8 rows (L31–L41, Z08, Z09, …)
///         follow in later commits.
contract AMMPoolMeasuredDepositTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant FUND = 1e30;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal surplusRecipient = makeAddr("surplusRecipient");

    MockFeeERC20.Path internal constant PULL = MockFeeERC20.Path.TransferFrom;

    function _fund(AMMPool p) internal {
        address[2] memory users = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            MockERC20(p.token0()).mint(users[i], FUND);
            MockERC20(p.token1()).mint(users[i], FUND);
            vm.startPrank(users[i]);
            IERC20(p.token0()).approve(address(p), MAX);
            IERC20(p.token1()).approve(address(p), MAX);
            vm.stopPrank();
        }
    }

    function _pool(address x, address y) internal returns (AMMPool p) {
        (address lo, address hi) = x < y ? (x, y) : (y, x);
        p = new AMMPool(lo, hi, surplusRecipient);
        _fund(p);
    }

    // ------------------------------------------------------------------
    // L30 — interface (M8-5, M8-8, M8-10)
    // ------------------------------------------------------------------

    function _abiNames(string memory kind) internal view returns (bytes32[] memory names, uint256 n) {
        string memory json = vm.readFile("out/AMMPool.sol/AMMPool.json");
        names = new bytes32[](128);
        for (uint256 i; vm.keyExistsJson(json, string.concat(".abi[", vm.toString(i), "].type")); ++i) {
            string memory t = vm.parseJsonString(json, string.concat(".abi[", vm.toString(i), "].type"));
            if (keccak256(bytes(t)) != keccak256(bytes(kind))) continue;
            names[n++] = keccak256(bytes(vm.parseJsonString(json, string.concat(".abi[", vm.toString(i), "].name"))));
        }
    }

    function _has(bytes32[] memory names, uint256 n, string memory name) internal pure returns (bool) {
        for (uint256 i; i < n; ++i) {
            if (names[i] == keccak256(bytes(name))) return true;
        }
        return false;
    }

    function test_L30_removedErrorsAbsentFromCompiledAbi() public view {
        (bytes32[] memory errs, uint256 n) = _abiNames("error");
        assertGt(n, 0, "errors parsed");
        assertFalse(_has(errs, n, "InvalidTaxBps"), "InvalidTaxBps removed");
        assertFalse(_has(errs, n, "TaxedLaterDepositNotImplemented"), "temporary error removed");
        assertFalse(_has(errs, n, "NetAmountOutOfRange"), "[T, T+1] error removed");
        assertTrue(_has(errs, n, "ExcessContributionTooHigh"), "new error present");
        assertTrue(_has(errs, n, "InsufficientDepositAmount"), "kept error present");
    }

    function test_L30_liquidityAddedEventUnchanged() public pure {
        assertEq(
            AMMPool.LiquidityAdded.selector,
            keccak256("LiquidityAdded(address,address,uint256,uint256,uint256)"),
            "event signature unchanged (M8-5 (2))"
        );
    }

    // ------------------------------------------------------------------
    // Z08 (ii), shipped early with the code it tests: a saturated σ reverts with Panic 0x11
    // from the checked `supply + σ`, before the excess check (M8-13 (d)). The full Z08 row
    // follows in a later commit.
    // ------------------------------------------------------------------

    /// @dev Reserves pushed down to (1, 1) by slash + sync while the LP supply stays 1e30, so
    ///      n_i · S / r_i ≥ 2^256 on both sides → σ = type(uint256).max. maxExcess = 0 and
    ///      minShares = MAX (≤ σ) make Panic 0x11 the only possible first failure.
    function test_Z08_saturatedSharesPanicBeforeExcessCheck() public {
        MockDeficitERC20 d0 = new MockDeficitERC20("D0", "D0", 18);
        MockDeficitERC20 d1 = new MockDeficitERC20("D1", "D1", 18);
        AMMPool p = _pool(address(d0), address(d1));
        vm.prank(alice);
        p.addLiquidity(addParams(1e30, 1e30, 0, alice, block.timestamp));
        assertEq(p.totalSupply(), 1e30);
        d0.slash(address(p), 1e30 - 1);
        d1.slash(address(p), 1e30 - 1);
        p.sync();
        (uint256 r0, uint256 r1) = p.getReserves();
        assertEq(r0, 1);
        assertEq(r1, 1);

        uint256 big = 2 ** 200; // 2^200 · 1e30 / 1 ≥ 2^256 on both sides
        d0.mint(bob, big);
        d1.mint(bob, big);
        IAMMPool.AddLiquidityParams memory prm = addParams(big, big, MAX, bob, block.timestamp);
        (prm.maxExcess0, prm.maxExcess1) = (0, 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        p.addLiquidity(prm);
        assertEq(p.totalSupply(), 1e30, "nothing minted");
    }

    // ------------------------------------------------------------------
    // L42 — re-planned second target 0 → InsufficientDepositAmount before the second transfer
    // ------------------------------------------------------------------

    struct State {
        uint256 r0;
        uint256 r1;
        uint256 supply;
        uint256 bobLP;
        uint256 poolA;
        uint256 poolB;
        uint256 bobA;
        uint256 bobB;
        uint256 allowA;
        uint256 allowB;
        uint256 callsA;
        uint256 nonceA;
    }

    // L42 fixture, kept in storage (fewer stack slots per test function).
    AMMPool internal lp;
    MockFeeERC20 internal fa; // A: fee mock, always the first-pulled token
    MockFailingERC20 internal fb; // B: tripwire, any transferFrom reverts MockFailure() once armed
    bool internal aIsToken0;

    function _state() internal view returns (State memory s) {
        (s.r0, s.r1) = lp.getReserves();
        s.supply = lp.totalSupply();
        s.bobLP = lp.balanceOf(bob);
        s.poolA = fa.balanceOf(address(lp));
        s.poolB = fb.balanceOf(address(lp));
        s.bobA = fa.balanceOf(bob);
        s.bobB = fb.balanceOf(bob);
        s.allowA = fa.allowance(bob, address(lp));
        s.allowB = fb.allowance(bob, address(lp));
        s.callsA = fa.callCount(uint256(PULL));
        s.nonceA = fa.config(PULL).nonce;
    }

    /// @dev Pool of A and B. `aLow` puts A at token0 (pulled first with token1First = false) or
    ///      at token1 (pulled first with token1First = true). Initial reserves rA = 1e8, rB = 1e2,
    ///      so a request of 1e6 A (B unbounded) plans T = (1e6 A, 1 B).
    function _l42Setup(bool aLow) internal {
        aIsToken0 = aLow;
        fb = new MockFailingERC20("Trip", "TRIP", 18);
        address where = aLow ? address(0x10000) : address(type(uint160).max);
        deployCodeTo("MockFeeERC20.sol:MockFeeERC20", abi.encode("Fee", "FEE", uint8(18)), where);
        fa = MockFeeERC20(where);
        // deployCodeTo keeps storage at a reused address: reset the fee configuration.
        fa.setTax(PULL, 0);
        lp = _pool(address(fa), address(fb));
        assertEq(aLow ? lp.token0() : lp.token1(), address(fa), "A position");
        (uint256 x0, uint256 x1) = aLow ? (uint256(1e8), uint256(1e2)) : (uint256(1e2), uint256(1e8));
        vm.prank(alice);
        lp.addLiquidity(addParams(x0, x1, 0, alice, block.timestamp));
        (uint256 r0, uint256 r1) = lp.getReserves();
        assertEq(r0, x0, "fixture reserve0 exact");
        assertEq(r1, x1, "fixture reserve1 exact");
        fb.setMode(MockFailingERC20.Mode.RevertTransferFrom); // arm the tripwire
    }

    /// @dev A is pulled first in both positions: token1First = !aIsToken0.
    function _l42Params() internal view returns (IAMMPool.AddLiquidityParams memory) {
        (uint256 c0, uint256 c1) = aIsToken0 ? (uint256(1e6), MAX) : (MAX, uint256(1e6));
        return addParamsOrdered(c0, c1, 0, bob, block.timestamp, !aIsToken0);
    }

    function _assertSameState(State memory x, State memory y) internal pure {
        assertEq(keccak256(abi.encode(x)), keccak256(abi.encode(y)), "full rollback");
    }

    /// @dev Expects InsufficientDepositAmount, zero transferFrom calls to B, and full rollback.
    function _expectZeroReplanRevert() internal {
        State memory before = _state();
        IAMMPool.AddLiquidityParams memory prm = _l42Params();
        // Matches ANY transferFrom on B (selector prefix only), so a call with any arguments counts.
        vm.expectCall(address(fb), abi.encodeWithSelector(IERC20.transferFrom.selector), 0);
        vm.prank(bob);
        vm.expectRevert(AMMPool.InsufficientDepositAmount.selector);
        lp.addLiquidity(prm);
        _assertSameState(_state(), before);
    }

    /// @dev (i) The first token's measured net is 0 (100% tax).
    function test_L42_firstNetZero_bothPullOrders() public {
        for (uint256 k; k < 2; ++k) {
            _l42Setup(k == 0);
            fa.setTax(PULL, 10_000);
            _expectZeroReplanRevert();
        }
    }

    /// @dev (ii) The first net is > 0 (999,900 of 1e6 at 1 bps) but floor(999,900 · 1e2 / 1e8) = 0.
    function test_L42_firstNetPositiveReplanFloorsToZero_bothPullOrders() public {
        for (uint256 k; k < 2; ++k) {
            _l42Setup(k == 0);
            fa.setTax(PULL, 1);
            // Case (ii) precondition: the first pull delivers a positive net, 1e6 - floor(1e6 / 1e4).
            assertEq(uint256(1e6) - uint256(1e6) / 10_000, uint256(999_900));
            _expectZeroReplanRevert();
        }
    }

    /// @dev Seeded random tax in [1, 10_000] bps: every first net is below 1e6, so the re-plan is
    ///      always 0 (mixes cases (i) and (ii); reproducible from the seeds 1..8).
    function test_L42_randomTaxSeeded_bothPullOrders() public {
        for (uint256 k; k < 2; ++k) {
            for (uint256 seed = 1; seed <= 8; ++seed) {
                // Fresh fixture per seed: a counted expectCall can be set once per target.
                _l42Setup(k == 0);
                fa.setRandomTax(PULL, seed, 1, 10_000);
                _expectZeroReplanRevert();
            }
        }
    }

    /// @dev Reverse test: the detectors used above do see a second transferFrom when one happens.
    ///      With no tax the first net equals its target, there is no re-plan, the Pool calls B's
    ///      transferFrom (expected count 1), and the armed tripwire reports the mock-only
    ///      `MockFailure()` — not the Pool's `InsufficientDepositAmount()`. So a Pool that wrongly
    ///      made the second call in the L42 cases would fail those tests on both detectors.
    function test_L42_reverse_detectorsSeeTheSecondCall() public {
        for (uint256 k; k < 2; ++k) {
            _l42Setup(k == 0);
            State memory before = _state();
            IAMMPool.AddLiquidityParams memory prm = _l42Params();
            vm.expectCall(address(fb), abi.encodeWithSelector(IERC20.transferFrom.selector), 1);
            vm.prank(bob);
            vm.expectRevert(MockFailingERC20.MockFailure.selector);
            lp.addLiquidity(prm);
            _assertSameState(_state(), before);
        }
        assertTrue(MockFailingERC20.MockFailure.selector != AMMPool.InsufficientDepositAmount.selector);
    }

    // ------------------------------------------------------------------
    // L43 — canonical token order of return values and LiquidityAdded
    // ------------------------------------------------------------------

    /// @dev Two taxed tokens with different rates (token0 1%, token1 3%), so the two nets differ
    ///      and a swapped report would be detected. Initial and later deposit, both pull orders.
    function test_L43_netsReportedInTokenOrder_bothPullOrders() public {
        for (uint256 k; k < 2; ++k) {
            bool t1First = k == 1;
            uint256 snap = vm.snapshotState();
            deployCodeTo("MockFeeERC20.sol:MockFeeERC20", abi.encode("Zero", "T0", uint8(18)), address(0x10000));
            deployCodeTo(
                "MockFeeERC20.sol:MockFeeERC20", abi.encode("One", "T1", uint8(18)), address(type(uint160).max)
            );
            lp = _pool(address(0x10000), address(type(uint160).max));
            MockFeeERC20(lp.token0()).setTax(PULL, 100);
            MockFeeERC20(lp.token1()).setTax(PULL, 300);

            _depositAndCheckOrder(addParamsOrdered(1e21, 3e21, 0, alice, block.timestamp, t1First)); // initial
            _depositAndCheckOrder(addParamsOrdered(1e19, 1e20, 0, bob, block.timestamp, t1First)); // later
            vm.revertToState(snap);
        }
    }

    /// @dev Payer and recipient are the same account (`prm.recipient`).
    function _depositAndCheckOrder(IAMMPool.AddLiquidityParams memory prm) internal {
        uint256 b0 = IERC20(lp.token0()).balanceOf(address(lp));
        uint256 b1 = IERC20(lp.token1()).balanceOf(address(lp));
        vm.recordLogs();
        vm.prank(prm.recipient);
        (uint256 n0, uint256 n1, uint256 s) = lp.addLiquidity(prm);
        assertEq(n0, IERC20(lp.token0()).balanceOf(address(lp)) - b0, "net0 is token0's measured net");
        assertEq(n1, IERC20(lp.token1()).balanceOf(address(lp)) - b1, "net1 is token1's measured net");
        assertTrue(n0 != n1, "nets differ, so a swap would be visible");
        _checkLiquidityAddedEvent(address(lp), prm.recipient, abi.encode(n0, n1, s));
    }

    function _checkLiquidityAddedEvent(address p, address who, bytes memory expectedData) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != p || logs[i].topics[0] != AMMPool.LiquidityAdded.selector) continue;
            assertEq(logs[i].data, expectedData, "event (net0, net1, shares) in token0/token1 order");
            assertEq(address(uint160(uint256(logs[i].topics[1]))), who, "sender");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), who, "recipient");
            ++found;
        }
        assertEq(found, 1, "exactly one LiquidityAdded");
    }
}
