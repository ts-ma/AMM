// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {AMMMath} from "../src/libraries/AMMMath.sol";
import {MockDeficitERC20} from "./mocks/MockDeficitERC20.sol";
import {PoolStateFixture} from "./utils/PoolStateFixture.sol";
import {addParams} from "./utils/AddParams.sol";

/// @notice M6 cross-state scenarios: surplus isolation and transitions between normal, surplus
///         and deficit states (ARCHITECTURE §5; Gate R=(b); DECISIONS M6-5).
///         TEST_MATRIX S07, L13, R07, R17, B01 (M6 re-check).
contract AMMPoolSyncSkimScenariosTest is PoolStateFixture {
    bytes internal constant DEFICIT = abi.encodeWithSelector(AMMPool.ReserveDeficit.selector);

    enum State {
        Normal,
        Surplus,
        Deficit
    }

    function _state(MockDeficitERC20 t, uint256 reserve) internal view returns (State) {
        uint256 b = t.balanceOf(address(pool));
        if (b > reserve) return State.Surplus;
        if (b < reserve) return State.Deficit;
        return State.Normal;
    }

    function _states() internal view returns (State s0, State s1) {
        (uint256 r0, uint256 r1) = _reserves();
        return (_state(t0, r0), _state(t1, r1));
    }

    function _surpluses() internal view returns (uint256 s0, uint256 s1) {
        (uint256 r0, uint256 r1) = _reserves();
        s0 = t0.balanceOf(address(pool)) - r0;
        s1 = t1.balanceOf(address(pool)) - r1;
    }

    function _swap(address tokenIn, uint256 amountIn) internal returns (uint256) {
        vm.prank(bob);
        return pool.swapExactInput(tokenIn, amountIn, 0, carol, block.timestamp);
    }

    // ------------------------------------------------------------------
    // S07 / R07 / B01: historical surplus is never counted as the caller's input
    // ------------------------------------------------------------------

    /// S07: surplus in the INPUT token is not counted as input; both surpluses unchanged.
    function test_S07_surplusNotCountedAsSwapInput() public {
        _donate(t0, 50_000);
        _donate(t1, 70_000);
        (uint256 r0, uint256 r1) = _reserves();
        uint256 expected = AMMMath.getAmountOut(10_000, r0, r1); // a = 10,000, not 60,000
        assertEq(_swap(address(t0), 10_000), expected);
        (uint256 a0, uint256 a1) = _reserves();
        assertEq(a0, r0 + 10_000, "reserveIn += measured a only");
        assertEq(a1, r1 - expected);
        (uint256 s0, uint256 s1) = _surpluses();
        assertEq(s0, 50_000, "input-token surplus unchanged");
        assertEq(s1, 70_000, "output-token surplus unchanged");

        // Other direction.
        (r0, r1) = _reserves();
        expected = AMMMath.getAmountOut(10_000, r1, r0);
        assertEq(_swap(address(t1), 10_000), expected);
        (s0, s1) = _surpluses();
        assertEq(s0, 50_000);
        assertEq(s1, 70_000);
    }

    /// R07 / B01: a later deposit with pre-existing surplus pulls and credits only the optimal
    /// amounts; shares from those nets; surpluses unchanged (re-checked with the M6 entry check).
    function test_R07_B01_surplusNotCountedAsDepositInput() public {
        _donate(t0, 123_456);
        _donate(t1, 654_321);
        (uint256 r0, uint256 r1) = _reserves();
        uint256 supply = pool.totalSupply();
        vm.prank(bob);
        (uint256 n0, uint256 n1, uint256 shares) = pool.addLiquidity(addParams(1000, 1e9, 0, bob, block.timestamp));
        assertEq(n0, 1000);
        assertEq(n1, Math.mulDiv(1000, r1, r0));
        assertEq(shares, Math.min(Math.mulDiv(n0, supply, r0), Math.mulDiv(n1, supply, r1)));
        (uint256 s0, uint256 s1) = _surpluses();
        assertEq(s0, 123_456);
        assertEq(s1, 654_321);
        // And skim still delivers exactly the historical surplus afterwards.
        pool.skim();
        assertEq(t0.balanceOf(surplus), 123_456);
        assertEq(t1.balanceOf(surplus), 654_321);
    }

    // ------------------------------------------------------------------
    // L13: first-depositor inflation attempt
    // ------------------------------------------------------------------

    /// L13 (THREAT_MODEL T4): an attacker makes the smallest possible first deposit (1 share),
    /// then transfers a huge amount directly to the Pool. The transfer never enters reserves,
    /// so a later LP's shares are not rounded to zero, and `skim()` sends the transfer to
    /// surplusRecipient — the attacker loses it.
    function test_L13_inflationAttemptFails() public {
        MockDeficitERC20 a = new MockDeficitERC20("A", "A", 18);
        MockDeficitERC20 b = new MockDeficitERC20("B", "B", 18);
        (MockDeficitERC20 x, MockDeficitERC20 y) = address(a) < address(b) ? (a, b) : (b, a);
        AMMPool p = new AMMPool(address(x), address(y), surplus);
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");
        address[2] memory users = [attacker, victim];
        for (uint256 i; i < 2; ++i) {
            x.mint(users[i], 1e30);
            y.mint(users[i], 1e30);
            vm.startPrank(users[i]);
            x.approve(address(p), MAX);
            y.approve(address(p), MAX);
            vm.stopPrank();
        }

        vm.prank(attacker);
        (,, uint256 attackerShares) = p.addLiquidity(addParams(1001, 1001, 0, attacker, block.timestamp));
        assertEq(attackerShares, 1, "minimal position");

        vm.startPrank(attacker);
        x.transfer(address(p), 1e24);
        y.transfer(address(p), 1e24);
        vm.stopPrank();
        (uint256 r0, uint256 r1) = p.getReserves();
        assertEq(r0, 1001, "direct transfer not in reserves");
        assertEq(r1, 1001);

        vm.prank(victim);
        (uint256 n0, uint256 n1, uint256 victimShares) =
            p.addLiquidity(addParams(1e18, 1e18, 0, victim, block.timestamp));
        assertEq(n0, 1e18);
        assertEq(n1, 1e18);
        assertEq(victimShares, Math.mulDiv(1e18, 1001, 1001), "full value, not rounded to 0");

        // The victim can redeem (almost) everything; the attacker's donation is not theirs.
        vm.prank(victim);
        (uint256 o0, uint256 o1) = p.removeLiquidity(victimShares, 0, 0, victim, block.timestamp);
        assertGe(o0, 1e18 - 1);
        assertGe(o1, 1e18 - 1);
        p.skim();
        assertEq(x.balanceOf(surplus), 1e24, "donation goes to surplusRecipient");
        assertEq(y.balanceOf(surplus), 1e24);
    }

    // ------------------------------------------------------------------
    // R17: transitions between states, each token independently
    // ------------------------------------------------------------------

    function test_R17_transitionSequence() public {
        (State s0, State s1) = _states();
        assertTrue(s0 == State.Normal && s1 == State.Normal);

        // normal → surplus (token0); operations still work.
        _donate(t0, 1000);
        (s0, s1) = _states();
        assertTrue(s0 == State.Surplus && s1 == State.Normal);
        _swap(address(t0), 10_000);

        // surplus (token0) + deficit (token1): operations blocked.
        _slashPool(t1, 500);
        (s0, s1) = _states();
        assertTrue(s0 == State.Surplus && s1 == State.Deficit);
        _expectRevertNoChange(
            bob, abi.encodeCall(AMMPool.swapExactInput, (address(t0), 10_000, 0, carol, block.timestamp)), DEFICIT
        );

        // skim: token0 → normal; token1 stays in deficit (A2).
        pool.skim();
        (s0, s1) = _states();
        assertTrue(s0 == State.Normal && s1 == State.Deficit);

        // sync: token1 → normal; operations resume.
        pool.sync();
        (s0, s1) = _states();
        assertTrue(s0 == State.Normal && s1 == State.Normal);
        _swap(address(t1), 10_000);

        // surplus → deficit in the same token without passing through normal.
        _donate(t1, 100);
        _slashPool(t1, 300);
        (s0, s1) = _states();
        assertTrue(s1 == State.Deficit, "net -200");
        pool.skim(); // nothing to skim for token1
        (, s1) = _states();
        assertTrue(s1 == State.Deficit);
        pool.sync();
        (, s1) = _states();
        assertTrue(s1 == State.Normal);

        // A slash smaller than the surplus leaves a (smaller) surplus, not a deficit.
        _donate(t0, 100);
        _slashPool(t0, 40);
        (s0,) = _states();
        assertTrue(s0 == State.Surplus);
        _swap(address(t0), 10_000);
        pool.skim();
        assertEq(t0.balanceOf(surplus), 1000 + 60);
    }

    /// R17 fuzz: random sequences of 12 actions (donate, slash, sync, skim, swap in either
    /// direction) on random tokens. Range: donations up to 1e24; slashes up to half the current
    /// balance (so no reserve reaches 0 — terminal pools are R14–R22); swaps of 1,000..1e6.
    /// After every action the specified state holds:
    ///   sync  → no token in deficit, no reserve increased, surplus unchanged;
    ///   skim  → no token in surplus, reserves unchanged, deficits unchanged;
    ///   swap  → reverts ReserveDeficit with no change iff some token was in deficit; otherwise
    ///           succeeds and leaves both surpluses unchanged (BI-2).
    function testFuzz_R17_randomTransitions(uint256 seed) public {
        for (uint256 step; step < 12; ++step) {
            uint256 rnd = uint256(keccak256(abi.encode(seed, step)));
            uint256 action = rnd % 6;
            MockDeficitERC20 t = (rnd >> 8) % 2 == 0 ? t0 : t1;
            uint256 amt = rnd >> 16;
            (uint256 r0, uint256 r1) = _reserves();
            uint256 b0 = t0.balanceOf(address(pool));
            uint256 b1 = t1.balanceOf(address(pool));

            if (action == 0) {
                _donate(t, bound(amt, 1, 1e24));
            } else if (action == 1) {
                uint256 bal = t.balanceOf(address(pool));
                _slashPool(t, bound(amt, 0, bal / 2));
            } else if (action == 2) {
                pool.sync();
                (uint256 a0, uint256 a1) = _reserves();
                assertEq(a0, b0 < r0 ? b0 : r0, "sync min (0)");
                assertEq(a1, b1 < r1 ? b1 : r1, "sync min (1)");
            } else if (action == 3) {
                pool.skim();
                (uint256 a0, uint256 a1) = _reserves();
                assertEq(a0, r0, "skim keeps reserve0");
                assertEq(a1, r1, "skim keeps reserve1");
                assertEq(t0.balanceOf(address(pool)), b0 > r0 ? r0 : b0, "skim balance0");
                assertEq(t1.balanceOf(address(pool)), b1 > r1 ? r1 : b1, "skim balance1");
            } else {
                address tokenIn = action == 4 ? address(t0) : address(t1);
                uint256 amountIn = bound(amt, 1000, 1e6);
                bytes memory data =
                    abi.encodeCall(AMMPool.swapExactInput, (tokenIn, amountIn, 0, carol, block.timestamp));
                if (b0 < r0 || b1 < r1) {
                    _expectRevertNoChange(bob, data, DEFICIT);
                } else {
                    uint256 s0 = b0 - r0;
                    uint256 s1 = b1 - r1;
                    vm.prank(bob);
                    (bool ok,) = address(pool).call(data);
                    assertTrue(ok, "swap succeeds without deficit");
                    (uint256 a0, uint256 a1) = _reserves();
                    assertEq(t0.balanceOf(address(pool)) - a0, s0, "surplus0 unchanged");
                    assertEq(t1.balanceOf(address(pool)) - a1, s1, "surplus1 unchanged");
                }
            }
        }
    }
}
