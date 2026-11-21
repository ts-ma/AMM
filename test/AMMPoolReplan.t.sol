// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {IAMMPool} from "../src/interfaces/IAMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeERC20} from "./mocks/MockFeeERC20.sol";
import {addParams, addParamsOrdered} from "./utils/AddParams.sol";

/// @notice M8 commit 5 (tests only; M8 remains WIP): the re-plan of the second token
///         (DECISIONS M8-12) and the request cap (M8-13 (a)). TEST_MATRIX L32 (bonus first token:
///         upward re-plan capped by RequestMax), Z08 (iv) (re-plan saturation), and the bonus-second
///         case. Expected values are computed here from the documented formulas with plain
///         integer arithmetic, independent of the Pool's code path. Fresh addresses per fixture.
contract AMMPoolReplanTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    MockFeeERC20.Path internal constant PULL = MockFeeERC20.Path.TransferFrom;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal surplusRecipient = makeAddr("surplusRecipient");

    AMMPool internal p;
    MockFeeERC20 internal b; // bonus token
    MockERC20 internal m; // plain token
    bool internal bIsToken0;
    uint160 internal nextLow = 0x40000;
    uint160 internal nextHigh = type(uint160).max - 0x2000;

    function _deploy(string memory artifact, bool low) internal returns (address at) {
        at = low ? address(nextLow++) : address(nextHigh--);
        require(at.code.length == 0, "address reused");
        deployCodeTo(artifact, abi.encode("T", "T", uint8(18)), at);
    }

    /// @dev Pool of bonus token B and plain token M; alice's initial deposit gives reserves
    ///      (rB, rM); bob holds `fundBob` of each. The bonus is switched on afterwards.
    function _setUp(bool bLow, uint256 rB, uint256 rM, uint256 fundBob) internal {
        bIsToken0 = bLow;
        b = MockFeeERC20(_deploy("MockFeeERC20.sol:MockFeeERC20", bLow));
        m = MockERC20(_deploy("MockERC20.sol:MockERC20", !bLow));
        p = new AMMPool(bLow ? address(b) : address(m), bLow ? address(m) : address(b), surplusRecipient);
        b.mint(alice, rB);
        m.mint(alice, rM);
        b.mint(bob, fundBob);
        m.mint(bob, fundBob);
        address[2] memory users = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(users[i]);
            b.approve(address(p), MAX);
            m.approve(address(p), MAX);
            vm.stopPrank();
        }
        vm.prank(alice);
        p.addLiquidity(addParams(bLow ? rB : rM, bLow ? rM : rB, 0, alice, block.timestamp));
    }

    /// @dev Builds bob's params from per-token values (B, M), mapped to token0/token1.
    function _prm(uint256 capB, uint256 capM, uint256 maxExcessB, uint256 maxExcessM, bool bFirst)
        internal
        view
        returns (IAMMPool.AddLiquidityParams memory prm)
    {
        bool t1First = bFirst ? !bIsToken0 : bIsToken0;
        prm = bIsToken0
            ? addParamsOrdered(capB, capM, 0, bob, block.timestamp, t1First)
            : addParamsOrdered(capM, capB, 0, bob, block.timestamp, t1First);
        (prm.maxExcess0, prm.maxExcess1) = bIsToken0 ? (maxExcessB, maxExcessM) : (maxExcessM, maxExcessB);
    }

    struct Out {
        uint256 nB;
        uint256 nM;
        uint256 shares;
        uint256 debitB;
        uint256 debitM;
    }

    function _deposit(IAMMPool.AddLiquidityParams memory prm) internal returns (Out memory o) {
        uint256 bB = b.balanceOf(bob);
        uint256 bM = m.balanceOf(bob);
        vm.prank(bob);
        (uint256 n0, uint256 n1, uint256 s) = p.addLiquidity(prm);
        (o.nB, o.nM) = bIsToken0 ? (n0, n1) : (n1, n0);
        o.shares = s;
        o.debitB = bB - b.balanceOf(bob);
        o.debitM = bM - m.balanceOf(bob);
    }

    // ------------------------------------------------------------------
    // L32 — bonus first token: upward re-plan, capped by the second token's RequestMax
    // ------------------------------------------------------------------

    /// @dev r = (B 1e21, M 2e21); request B 1e18 → step-2 T = (1e18 B, 2e18 M). B credits a
    ///      1e18 bonus, so n_B = 2e18 ≠ T_B and the re-plan asks min(capM, floor(2e18·2e21/1e21))
    ///      = min(capM, 4e18) of M. Three caps: unbounded (4e18 pulled, above the step-2 target),
    ///      3e18 (cap binds), 2e18 (cap equal to the step-2 target). B position × both cases.
    function test_L32_bonusFirst_upwardReplanCappedByRequestMax() public {
        uint256[3] memory caps = [MAX, uint256(3e18), uint256(2e18)];
        for (uint256 pos; pos < 2; ++pos) {
            for (uint256 c; c < 3; ++c) {
                _setUp(pos == 0, 1e21, 2e21, 1e22);
                b.setBonus(PULL, 1e18);
                uint256 expectedM = caps[c] < 4e18 ? caps[c] : 4e18;
                Out memory o = _deposit(_prm(1e18, caps[c], MAX, MAX, true));
                assertEq(o.debitB, 1e18, "B: payer debited the step-2 target only");
                assertEq(o.nB, 2e18, "B: target + bonus arrived");
                assertEq(o.debitM, expectedM, "M: re-planned request = min(cap, 4e18)");
                assertLe(o.debitM, caps[c], "M request never above its RequestMax");
                assertEq(o.nM, expectedM);
                uint256 S = 2e21 * 1e21;
                S = _sqrt(S); // initial supply = floor(sqrt(rB · rM))
                uint256 sB = o.nB * S / 1e21;
                uint256 sM = o.nM * S / 2e21;
                assertEq(o.shares, sB < sM ? sB : sM, "shares from measured nets");
            }
        }
    }

    /// @dev Cap 3e18 (binding): matched B = ceil(σ·rB/S) = 1.5e18 (up to rounding), so the bonus
    ///      leaves u_B ≈ 0.5e18 unmatched. maxExcess_B = u_B succeeds, u_B − 1 reverts.
    function test_L32_bonusFirst_cappedReplanExcessBoundedByMaxExcess() public {
        for (uint256 pos; pos < 2; ++pos) {
            _setUp(pos == 0, 1e21, 2e21, 1e22);
            b.setBonus(PULL, 1e18);
            uint256 S = _sqrt(2e21 * 1e21);
            uint256 sigma = uint256(3e18) * S / 2e21; // M side binds: 3e18·S/2e21 < 2e18·S/1e21
            uint256 uB = 2e18 - _ceilDiv(sigma * 1e21, S);
            assertGt(uB, 0);
            uint256 id = vm.snapshotState();
            Out memory o = _deposit(_prm(1e18, 3e18, uB, 0, true));
            assertEq(o.shares, sigma);
            vm.revertToState(id);
            IAMMPool.AddLiquidityParams memory prm = _prm(1e18, 3e18, uB - 1, 0, true);
            vm.prank(bob);
            vm.expectRevert(AMMPool.ExcessContributionTooHigh.selector);
            p.addLiquidity(prm);
        }
    }

    /// @dev Bonus token pulled SECOND: no re-plan (the first net equals its target); the bonus is
    ///      unmatched B and enters the reserves, bounded by maxExcess_B.
    function test_L32_bonusSecond_noReplan_bonusIsExcess() public {
        for (uint256 pos; pos < 2; ++pos) {
            _setUp(pos == 0, 1e21, 2e21, 1e22);
            b.setBonus(PULL, 7e17);
            Out memory o = _deposit(_prm(1e18, MAX, MAX, MAX, false));
            assertEq(o.debitM, 2e18, "M first: step-2 target, no re-plan");
            assertEq(o.debitB, 1e18, "B second: its step-2 target");
            assertEq(o.nB, 1e18 + 7e17, "bonus arrived");
            (uint256 r0, uint256 r1) = p.getReserves();
            assertEq(bIsToken0 ? r0 : r1, 1e21 + 1e18 + 7e17, "X1: the bonus entered the reserve");
        }
    }

    // ------------------------------------------------------------------
    // Z08 (iv) — re-plan saturation: sat(n_f · r_s / r_f) = MAX, so the request is the cap
    // ------------------------------------------------------------------

    /// @dev r = (B 1, M 1e30); request B 1 → T = (1 B, 1e30 M). B credits a 2^200 bonus, so
    ///      n_B · r_M / r_B = (1 + 2^200) · 1e30 ≥ 2^256: the re-plan saturates and the request
    ///      becomes capM = 5e30 exactly. σ = min((1 + 2^200)·S/1, 5e30·S/1e30) = 5e30·S/1e30.
    function test_Z08iv_replanSaturates_requestIsCap() public {
        for (uint256 pos; pos < 2; ++pos) {
            _setUp(pos == 0, 1, 1e30, 1e31);
            b.setBonus(PULL, 2 ** 200);
            uint256 S = p.totalSupply();
            assertEq(S, 1e15, "S = floor(sqrt(1 * 1e30))");
            Out memory o = _deposit(_prm(1, 5e30, MAX, MAX, true));
            assertEq(o.debitB, 1);
            assertEq(o.nB, 1 + 2 ** 200);
            assertEq(o.debitM, 5e30, "saturated re-plan: request = RequestMax");
            assertEq(o.nM, 5e30);
            assertEq(o.shares, uint256(5e30) * S / 1e30);
        }
    }

    // ------------------------------------------------------------------
    // helpers (independent of the Pool)
    // ------------------------------------------------------------------

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _ceilDiv(uint256 a, uint256 d) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / d + 1;
    }
}
