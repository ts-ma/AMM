// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AMMFactory} from "../src/AMMFactory.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {AMMMath} from "../src/libraries/AMMMath.sol";
import {MockDeficitERC20} from "./mocks/MockDeficitERC20.sol";
import {addParams} from "./utils/AddParams.sol";

/// @notice F04 — two Factory Pools sharing a token are isolated; F04b — a terminal Pool blocks
///         its pair permanently (DECISIONS M7-5).
/// @dev P1 = (A, B) and P2 = (A, C) share token A and the Factory's `surplusRecipient`.
///      Every test operates on P1 and asserts that P2's complete state is unchanged.
contract AMMFactoryIsolationTest is Test {
    uint256 internal constant MAX = type(uint256).max;

    AMMFactory internal factory;
    MockDeficitERC20 internal tA;
    MockDeficitERC20 internal tB;
    MockDeficitERC20 internal tC;
    AMMPool internal p1;
    AMMPool internal p2;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal surplus = makeAddr("surplusRecipient");

    function setUp() public {
        factory = new AMMFactory(surplus);
        tA = new MockDeficitERC20("Token A", "TKA", 18);
        tB = new MockDeficitERC20("Token B", "TKB", 18);
        tC = new MockDeficitERC20("Token C", "TKC", 18);
        p1 = AMMPool(factory.createPair(address(tA), address(tB)));
        p2 = AMMPool(factory.createPair(address(tA), address(tC)));
        _fund(alice);
        _fund(bob);
        vm.startPrank(alice);
        p1.addLiquidity(addParams(1_000_000, 1_000_000, 0, alice, block.timestamp));
        p2.addLiquidity(addParams(3_000_000, 3_000_000, 0, alice, block.timestamp));
        vm.stopPrank();
    }

    function _fund(address who) internal {
        MockDeficitERC20[3] memory ts = [tA, tB, tC];
        vm.startPrank(who);
        for (uint256 i; i < 3; ++i) {
            ts[i].mint(who, 1e30);
            ts[i].approve(address(p1), MAX);
            ts[i].approve(address(p2), MAX);
        }
        vm.stopPrank();
    }

    struct State {
        uint256 r0;
        uint256 r1;
        uint256 supply;
        uint256 lock;
        uint256 aliceLP;
        uint256 bobLP;
        uint256 bal0;
        uint256 bal1;
    }

    function _state(AMMPool p) internal view returns (State memory s) {
        (s.r0, s.r1) = p.getReserves();
        s.supply = p.totalSupply();
        s.lock = p.balanceOf(address(p));
        s.aliceLP = p.balanceOf(alice);
        s.bobLP = p.balanceOf(bob);
        s.bal0 = MockDeficitERC20(p.token0()).balanceOf(address(p));
        s.bal1 = MockDeficitERC20(p.token1()).balanceOf(address(p));
    }

    function _assertSameState(State memory x, State memory y) internal pure {
        assertEq(x.r0, y.r0, "P2 reserve0");
        assertEq(x.r1, y.r1, "P2 reserve1");
        assertEq(x.supply, y.supply, "P2 LP supply");
        assertEq(x.lock, y.lock, "P2 lock");
        assertEq(x.aliceLP, y.aliceLP, "P2 alice LP");
        assertEq(x.bobLP, y.bobLP, "P2 bob LP");
        assertEq(x.bal0, y.bal0, "P2 token0 balance");
        assertEq(x.bal1, y.bal1, "P2 token1 balance");
    }

    // ------------------------------------------------------------------
    // F04 — isolation
    // ------------------------------------------------------------------

    function test_F04_distinctPoolsAndLpTokens() public view {
        assertTrue(address(p1) != address(p2));
        assertEq(factory.getPair(address(tA), address(tB)), address(p1));
        assertEq(factory.getPair(address(tA), address(tC)), address(p2));
        assertEq(p1.balanceOf(alice), 1_000_000 - 1000);
        assertEq(p2.balanceOf(alice), 3_000_000 - 1000);
    }

    function test_F04_depositSwapWithdrawInP1LeaveP2Unchanged() public {
        State memory before = _state(p2);
        vm.startPrank(bob);
        (,, uint256 shares) = p1.addLiquidity(addParams(50_000, 50_000, 0, bob, block.timestamp));
        p1.swapExactInput(address(tA), 20_000, 0, bob, block.timestamp);
        p1.swapExactInput(address(tB), 10_000, 0, bob, block.timestamp);
        p1.removeLiquidity(shares, 0, 0, bob, block.timestamp);
        vm.stopPrank();
        _assertSameState(before, _state(p2));
    }

    function test_F04_lpTransferInP1LeavesP2Unchanged() public {
        State memory before = _state(p2);
        vm.prank(alice);
        p1.transfer(bob, 12_345);
        assertEq(p1.balanceOf(bob), 12_345);
        _assertSameState(before, _state(p2));
    }

    /// @dev Surplus of the shared token in P1 is P1's surplus only; skims of both Pools go to
    ///      the one shared recipient, each for its own surplus.
    function test_F04_surplusAndSkimArePerPool() public {
        tA.mint(address(p1), 700);
        State memory before = _state(p2);

        p2.skim(); // P2 has no surplus: no-op
        _assertSameState(before, _state(p2));
        assertEq(tA.balanceOf(surplus), 0);

        p1.skim();
        assertEq(tA.balanceOf(surplus), 700);
        _assertSameState(before, _state(p2));

        tA.mint(address(p2), 300);
        p2.skim();
        assertEq(tA.balanceOf(surplus), 1_000, "both Pools skim to the shared recipient");
        assertEq(p1.surplusRecipient(), p2.surplusRecipient());
    }

    function test_F04_deficitAndSyncInP1DoNotAffectP2() public {
        tA.slash(address(p1), 5_000);
        State memory before = _state(p2);

        vm.prank(bob);
        vm.expectRevert(AMMPool.ReserveDeficit.selector);
        p1.swapExactInput(address(tB), 1_000, 0, bob, block.timestamp);

        p1.sync();
        _assertSameState(before, _state(p2));

        vm.prank(bob);
        assertGt(p2.swapExactInput(address(tA), 1_000, 0, bob, block.timestamp), 0, "P2 trades normally");
    }

    // ------------------------------------------------------------------
    // F04b — a terminal Pool blocks its pair forever (M7-5)
    // ------------------------------------------------------------------

    function test_F04b_terminalPairCannotBeRecreated() public {
        tA.slash(address(p1), 1_000_000);
        p1.sync();
        (uint256 r0, uint256 r1) = p1.getReserves();
        assertTrue(r0 == 0 || r1 == 0, "P1 terminal");
        assertGt(p1.totalSupply(), 0);

        vm.prank(bob);
        vm.expectRevert(AMMMath.InsufficientLiquidity.selector);
        p1.swapExactInput(address(tB), 1_000, 0, bob, block.timestamp);

        vm.expectRevert(AMMFactory.PairExists.selector);
        factory.createPair(address(tA), address(tB));
        vm.expectRevert(AMMFactory.PairExists.selector);
        factory.createPair(address(tB), address(tA));

        assertEq(factory.getPair(address(tA), address(tB)), address(p1), "registry still points to P1");
        assertEq(factory.allPairsLength(), 2);
    }
}
