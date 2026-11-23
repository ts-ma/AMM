// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {IAMMPool} from "../src/interfaces/IAMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockTaxedERC20} from "./mocks/MockTaxedERC20.sol";
import {MulDiv512} from "./utils/MulDiv512.sol";
import {addParamsOrdered} from "./utils/AddParams.sol";

/// @notice F1-T5: a large unmatched amount in a reachable state, bounded by the absolute
///         `maxExcess` in a real deposit call (DECISIONS M8-2; THREAT_MODEL T4, T29).
///         State built only by normal calls: initial deposit with requests (1000, 1e9), then a
///         swap of 100 token0 in. Deposit under test: caps (type(uint256).max, 1e6).
///
///         Expected values (independent integer Python model, same steps):
///         | | Tier 0 | Tier 1 (token1 tax 10%, burned) |
///         |---|---|---|
///         | reserves before, S | (1100, 909,338,911), 1,000,000 | (1100, 818,405,020), 948,683 |
///         | step-2 targets = gross pulls | (1, 1,000,000) | (1, 1,000,000) |
///         | payer debit | (1, 1,000,000) | (1, 1,000,000) |
///         | token1 tax burned | 0 | 100,000 |
///         | net | (1, 1,000,000) | (1, 900,000) |
///         | σ = min(floor(n_i·S/r_i)) | 909 (909.09 vs 1,099.70) | 862 (862.44 vs 1,043.27) |
///         | matched ceil(σ·r_i/S) | (1, 826,590) | (1, 743,626) |
///         | u | (0, 173,410) | (0, 156,374) |
///         | unmatched ratio u1/net1 | 17.3410 % | 17.3749 % |
///
///         Sources. The transfer tax is the difference between the payer's debit and the
///         Pool's net (1,000,000 − 900,000 = 100,000, burned by the mock); it never reaches the
///         Pool. The unmatched amount is part of the net: σ is limited by token0, whose single
///         unit buys only 909.09 (Tier 0) or 862.44 (Tier 1) shares, so the token1 net exceeds the
///         token1 amount those shares are worth. The tax even lowers u1 here, because it lowers
///         token1's net while token0 still binds.
///         With token1 pulled first, the Tier 1 net 900,000 differs from the target, so token0
///         is re-planned: floor(900,000·1100/818,405,020) = 1, the same pull.
///
///         The boundary is checked on the side with u > 0 (token1), with token0's bound wide
///         open (`maxExcess0 = max`) so the only possible failure is token1's excess:
///         `maxExcess1 = u1` succeeds, `u1 − 1` reverts `ExcessContributionTooHigh`, each run
///         from the same pre-deposit state. A failed call must restore the payer's and the
///         Pool's balances of both tokens, both reserves, the LP supply and every LP holding,
///         and the taxed token's total supply (its burned fee is rolled back).
///         Book shortfall and actual redemption loss are verified separately in F1-T6.
contract AMMPoolF1LargeRelativeLossTest is Test {
    uint256 internal constant MAX = type(uint256).max;

    address internal alice = makeAddr("alice"); // initial LP and swapper
    address internal bob = makeAddr("bob"); // depositor under test
    address internal surplusRecipient = makeAddr("surplusRecipient");

    MockERC20 internal t0;
    MockERC20 internal t1;
    AMMPool internal pool;

    struct Expect {
        uint256 r0;
        uint256 r1;
        uint256 S;
        uint256 net1;
        uint256 sigma;
        uint256 matched1;
        uint256 u1;
        uint256 tax1;
    }

    function _tier0() internal pure returns (Expect memory) {
        return Expect(1100, 909_338_911, 1_000_000, 1_000_000, 909, 826_590, 173_410, 0);
    }

    function _tier1() internal pure returns (Expect memory) {
        return Expect(1100, 818_405_020, 948_683, 900_000, 862, 743_626, 156_374, 100_000);
    }

    // ------------------------------------------------------------------
    // Setup: the P3 state by normal calls
    // ------------------------------------------------------------------

    function _deploy(bool taxed) internal {
        t0 = new MockERC20("Plain", "PLN", 18);
        // token1 must be the higher address; salt the second deployment until it is.
        for (uint256 salt;; ++salt) {
            MockERC20 c = taxed
                ? MockERC20(address(new MockTaxedERC20{salt: bytes32(salt)}("Taxed", "TAX", 18, 1000)))
                : new MockERC20{salt: bytes32(salt)}("Plain1", "PL1", 18);
            if (address(c) > address(t0)) {
                t1 = c;
                break;
            }
        }
        pool = new AMMPool(address(t0), address(t1), surplusRecipient);
        _fund(alice);
        _fund(bob);
        vm.prank(alice);
        pool.addLiquidity(addParamsOrdered(1000, 1e9, 0, alice, block.timestamp, false));
        vm.prank(alice);
        pool.swapExactInput(address(t0), 100, 0, alice, block.timestamp);
    }

    function _fund(address who) internal {
        t0.mint(who, 1e30);
        t1.mint(who, 1e30);
        vm.startPrank(who);
        t0.approve(address(pool), MAX);
        t1.approve(address(pool), MAX);
        vm.stopPrank();
    }

    function _params(uint256 e0, uint256 e1, bool t1First)
        internal
        view
        returns (IAMMPool.AddLiquidityParams memory p)
    {
        p = addParamsOrdered(MAX, 1e6, 0, bob, block.timestamp, t1First);
        p.maxExcess0 = e0;
        p.maxExcess1 = e1;
    }

    // ------------------------------------------------------------------
    // Full state for rollback checks
    // ------------------------------------------------------------------

    struct State {
        uint256 r0;
        uint256 r1;
        uint256 lpSupply;
        uint256 poolLP;
        uint256 aliceLP;
        uint256 bobLP;
        uint256 pool0;
        uint256 pool1;
        uint256 bob0;
        uint256 bob1;
        uint256 alice0;
        uint256 alice1;
        uint256 supply0; // token totalSupply: the taxed token burns its fee
        uint256 supply1;
    }

    function _state() internal view returns (State memory s) {
        (s.r0, s.r1) = pool.getReserves();
        s.lpSupply = pool.totalSupply();
        s.poolLP = pool.balanceOf(address(pool));
        s.aliceLP = pool.balanceOf(alice);
        s.bobLP = pool.balanceOf(bob);
        s.pool0 = t0.balanceOf(address(pool));
        s.pool1 = t1.balanceOf(address(pool));
        s.bob0 = t0.balanceOf(bob);
        s.bob1 = t1.balanceOf(bob);
        s.alice0 = t0.balanceOf(alice);
        s.alice1 = t1.balanceOf(alice);
        s.supply0 = t0.totalSupply();
        s.supply1 = t1.totalSupply();
    }

    function _assertSame(State memory x, State memory y) internal pure {
        assertEq(x.r0, y.r0, "reserve0");
        assertEq(x.r1, y.r1, "reserve1");
        assertEq(x.lpSupply, y.lpSupply, "LP totalSupply");
        assertEq(x.poolLP, y.poolLP, "Pool LP (lock)");
        assertEq(x.aliceLP, y.aliceLP, "alice LP");
        assertEq(x.bobLP, y.bobLP, "bob LP");
        assertEq(x.pool0, y.pool0, "Pool token0");
        assertEq(x.pool1, y.pool1, "Pool token1");
        assertEq(x.bob0, y.bob0, "payer token0");
        assertEq(x.bob1, y.bob1, "payer token1");
        assertEq(x.alice0, y.alice0, "alice token0");
        assertEq(x.alice1, y.alice1, "alice token1");
        assertEq(x.supply0, y.supply0, "token0 totalSupply");
        assertEq(x.supply1, y.supply1, "token1 totalSupply (burned tax rolled back)");
    }

    // ------------------------------------------------------------------
    // The boundary run
    // ------------------------------------------------------------------

    function _run(bool taxed, bool t1First) internal {
        Expect memory e = taxed ? _tier1() : _tier0();
        _deploy(taxed);
        (uint256 r0, uint256 r1) = pool.getReserves();
        assertEq(r0, e.r0, "model reserve0");
        assertEq(r1, e.r1, "model reserve1");
        assertEq(pool.totalSupply(), e.S, "model S");
        State memory pre = _state();
        uint256 snap = vm.snapshotState();

        // Run 1: maxExcess1 = u1 - 1 reverts; full rollback.
        vm.prank(bob);
        (bool ok, bytes memory ret) =
            address(pool).call(abi.encodeCall(AMMPool.addLiquidity, (_params(MAX, e.u1 - 1, t1First))));
        assertFalse(ok, "u1 - 1 must revert");
        assertEq(ret, abi.encodePacked(AMMPool.ExcessContributionTooHigh.selector), "exact revert data");
        _assertSame(pre, _state());

        // Run 2, from the same pre-deposit state: maxExcess1 = u1 succeeds.
        vm.revertToState(snap);
        _assertSame(pre, _state());
        vm.prank(bob);
        (uint256 n0, uint256 n1, uint256 sh) = pool.addLiquidity(_params(MAX, e.u1, t1First));
        assertEq(n0, 1, "net0");
        assertEq(n1, e.net1, "net1");
        assertEq(sh, e.sigma, "sigma");
        // u recomputed from the call's outputs with the independent ceil
        assertEq(MulDiv512.ceilMulDiv(sh, e.r0, e.S), 1, "matched0");
        assertEq(MulDiv512.ceilMulDiv(sh, e.r1, e.S), e.matched1, "matched1");
        assertEq(n0 - 1, 0, "u0 = 0");
        assertEq(n1 - e.matched1, e.u1, "u1");

        State memory post = _state();
        assertEq(pre.bob0 - post.bob0, 1, "payer debit token0");
        assertEq(pre.bob1 - post.bob1, 1e6, "payer debit token1 (gross)");
        assertEq(pre.supply1 - post.supply1, e.tax1, "token1 tax burned");
        assertEq(pre.supply0, post.supply0, "token0 untaxed");
        assertEq(post.r0, e.r0 + 1, "reserve0 += net0");
        assertEq(post.r1, e.r1 + e.net1, "reserve1 += net1 (X1: u1 enters the reserves)");
        assertEq(post.pool1 - pre.pool1, e.net1, "Pool token1 increase = net1");
        assertEq(post.lpSupply, e.S + e.sigma, "LP supply");
        assertEq(post.bobLP, e.sigma, "bob LP");
        assertEq(post.aliceLP, pre.aliceLP, "alice LP");
    }

    function test_F1T5_tier0_maxExcessBoundary_token0First() public {
        _run(false, false);
    }

    function test_F1T5_tier0_maxExcessBoundary_token1First() public {
        _run(false, true);
    }

    function test_F1T5_tier1_maxExcessBoundary_token0First() public {
        _run(true, false);
    }

    /// @dev Exercises the re-plan of token0 (net1 900,000 ≠ target 1,000,000); same pulls.
    function test_F1T5_tier1_maxExcessBoundary_token1First() public {
        _run(true, true);
    }

    /// @dev Both bounds exact at once: (maxExcess0, maxExcess1) = (0, u1) succeeds, because
    ///      u0 = 0 in both tiers.
    function test_F1T5_bothBoundsExact() public {
        for (uint256 k; k < 2; ++k) {
            bool taxed = k == 1;
            Expect memory e = taxed ? _tier1() : _tier0();
            _deploy(taxed);
            vm.prank(bob);
            (,, uint256 sh) = pool.addLiquidity(_params(0, e.u1, false));
            assertEq(sh, e.sigma);
        }
    }
}
