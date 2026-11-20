// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {AMMFactory} from "../src/AMMFactory.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {AMMMath} from "../src/libraries/AMMMath.sol";
import {MockDeficitERC20} from "./mocks/MockDeficitERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";
import {PoolStateFixture} from "./utils/PoolStateFixture.sol";

/// @notice F06 — Factory integration (DECISIONS M7-6). Representative M2–M6 flows on a
///         Factory-deployed Pool, a differential run against a directly deployed reference Pool,
///         and the runtime-`codehash` equivalence of both deployment paths.
/// @dev Scope: the M2–M6 unit suites keep deploying the Pool directly and are not re-run here.
///      Their results carry over to Factory Pools because (1) the runtime code is identical for
///      identical constructor arguments (`test_F06_codehashEqualsDirectDeployment`), and (2) the
///      Pool never reads its deployer (M7-3). This suite is a smoke check of that argument, not
///      a repetition of every unit test.
contract AMMFactoryIntegrationTest is PoolStateFixture {
    AMMFactory internal factory;
    AMMPool internal ref; // directly deployed reference Pool over the same tokens

    /// @dev Same tokens, actors and seed as the M6 fixture, but `pool` comes from the Factory.
    function setUp() public override {
        MockDeficitERC20 a = new MockDeficitERC20("Token A", "TKA", 18);
        MockDeficitERC20 b = new MockDeficitERC20("Token B", "TKB", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        factory = new AMMFactory(surplus);
        pool = AMMPool(factory.createPair(address(b), address(a))); // unsorted on purpose
        _fund(alice);
        _fund(bob);
        _seed(1_000_000, 2_000_000);

        ref = new AMMPool(address(t0), address(t1), surplus);
        _approve(alice, ref);
        _approve(bob, ref);
        vm.prank(alice);
        ref.addLiquidity(1_000_000, 2_000_000, 0, 0, 0, alice, block.timestamp);
    }

    function _approve(address who, AMMPool p) internal {
        vm.startPrank(who);
        t0.approve(address(p), MAX);
        t1.approve(address(p), MAX);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Equivalence of the two deployment paths
    // ------------------------------------------------------------------

    function test_F06_codehashEqualsDirectDeployment() public view {
        assertEq(address(pool).codehash, address(ref).codehash, "same runtime code");
        assertGt(address(pool).code.length, 0);
        assertEq(pool.token0(), ref.token0());
        assertEq(pool.token1(), ref.token1());
        assertEq(pool.surplusRecipient(), ref.surplusRecipient());
        assertEq(pool.name(), ref.name());
        assertEq(pool.symbol(), ref.symbol());
        assertEq(pool.decimals(), ref.decimals());
    }

    /// @dev Different constructor arguments give different code (immutables are embedded), so
    ///      the equality above is not a vacuous property of all Pools.
    function test_F06_codehashDiffersForOtherArguments() public {
        AMMPool other = new AMMPool(address(t0), address(t1), makeAddr("otherRecipient"));
        assertTrue(address(other).codehash != address(pool).codehash);
    }

    // ------------------------------------------------------------------
    // Differential run: Factory Pool vs. direct reference Pool
    // ------------------------------------------------------------------

    /// @dev Later deposit, both swap directions, quote, partial withdrawal; returns every
    ///      observable result in order.
    function _scenario(AMMPool p) internal returns (uint256[12] memory o) {
        vm.startPrank(bob);
        (o[0], o[1], o[2]) = p.addLiquidity(1_000, 5_000, 0, 0, 0, bob, block.timestamp);
        o[3] = p.swapExactInput(address(t0), 10_000, 0, carol, block.timestamp);
        o[4] = p.swapExactInput(address(t1), 7_000, 0, carol, block.timestamp);
        o[5] = p.getAmountOut(address(t0), 1_234);
        (o[6], o[7]) = p.removeLiquidity(o[2] / 2, 0, 0, bob, block.timestamp);
        vm.stopPrank();
        (o[8], o[9]) = p.getReserves();
        o[10] = p.totalSupply();
        o[11] = p.balanceOf(bob);
    }

    function test_F06_differentialMatchesDirectPool() public {
        uint256[12] memory viaFactory = _scenario(pool);
        uint256[12] memory direct = _scenario(ref);
        for (uint256 i; i < 12; ++i) {
            assertEq(viaFactory[i], direct[i], string.concat("result ", vm.toString(i)));
        }
        assertGt(viaFactory[2], 0, "shares minted");
        assertGt(viaFactory[3], 0, "swap output");
        assertEq(pool.balanceOf(address(pool)), 1000, "lock untouched");
    }

    // ------------------------------------------------------------------
    // Representative M3–M6 flows on the Factory Pool
    // ------------------------------------------------------------------

    function test_F06_initialDepositAndLock() public view {
        (uint256 r0, uint256 r1) = _reserves();
        assertEq(r0, 1_000_000);
        assertEq(r1, 2_000_000);
        assertEq(pool.totalSupply(), 1_414_213); // floor(sqrt(1e6 * 2e6))
        assertEq(pool.balanceOf(address(pool)), 1000, "1,000 locked in the Pool");
        assertEq(pool.balanceOf(alice), 1_414_213 - 1000);
    }

    function test_F06_deficitBlocksThenSyncReconciles() public {
        _slashPool(t0, 1_000);
        _expectRevertNoChange(
            bob,
            abi.encodeCall(pool.swapExactInput, (address(t0), 1_000, 0, bob, block.timestamp)),
            abi.encodeWithSelector(AMMPool.ReserveDeficit.selector)
        );

        vm.expectEmit(true, false, false, true, address(pool));
        emit AMMPool.ReserveSynced(address(t0), 1_000_000, 999_000);
        pool.sync();
        (uint256 r0,) = _reserves();
        assertEq(r0, 999_000);

        vm.prank(bob);
        assertGt(pool.swapExactInput(address(t0), 1_000, 0, bob, block.timestamp), 0, "trading resumes");
    }

    function test_F06_skimPaysSharedRecipient() public {
        _donate(t1, 777);
        vm.expectEmit(true, false, false, true, address(pool));
        emit AMMPool.SurplusSkimmed(address(t1), 777);
        pool.skim();
        assertEq(t1.balanceOf(surplus), 777);
        assertEq(factory.surplusRecipient(), surplus);
        (, uint256 r1) = _reserves();
        assertEq(r1, 2_000_000, "reserve unchanged");
    }

    function test_F06_terminalPoolPath() public {
        _slashPool(t0, 1_000_000);
        pool.sync();
        (uint256 r0, uint256 r1) = _reserves();
        assertEq(r0, 0);

        _expectRevertNoChange(
            bob,
            abi.encodeCall(pool.addLiquidity, (1_000, 2_000, 0, 0, 0, bob, block.timestamp)),
            abi.encodeWithSelector(AMMMath.InsufficientLiquidity.selector)
        );

        uint256 shares = pool.balanceOf(alice) / 2;
        uint256 expected1 = (shares * r1) / pool.totalSupply();
        vm.prank(alice);
        (uint256 n0, uint256 n1) = pool.removeLiquidity(shares, 0, 0, alice, block.timestamp);
        assertEq(n0, 0, "zero-reserve side pays 0");
        assertEq(n1, expected1, "proportional share of the remaining reserve");
    }

    // ------------------------------------------------------------------
    // Reentrancy smoke on a Factory Pool (M5-6 bubbling case)
    // ------------------------------------------------------------------

    function test_F06_reentrancyBubblesOnFactoryPool() public {
        ReentrantERC20 r = new ReentrantERC20("Hook", "HOOK", 18);
        MockERC20 m = new MockERC20("Plain", "PLN", 18);
        AMMPool p = AMMPool(factory.createPair(address(r), address(m)));
        r.mint(alice, 1e24);
        m.mint(alice, 1e24);
        vm.startPrank(alice);
        r.approve(address(p), MAX);
        m.approve(address(p), MAX);
        p.addLiquidity(1e21, 1e21, 0, 0, 0, alice, block.timestamp);
        vm.stopPrank();

        r.armWith(
            address(p),
            abi.encodeCall(p.swapExactInput, (address(m), 1e18, 0, alice, block.timestamp)),
            ReentrantERC20.Hook.TransferFrom,
            false
        );
        (uint256 r0, uint256 r1) = p.getReserves();
        uint256 aliceR = r.balanceOf(alice);
        uint256 aliceM = m.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector));
        p.swapExactInput(address(r), 1e18, 0, alice, block.timestamp);

        (uint256 a0, uint256 a1) = p.getReserves();
        assertEq(a0, r0);
        assertEq(a1, r1);
        assertEq(r.balanceOf(alice), aliceR);
        assertEq(m.balanceOf(alice), aliceM);
        assertEq(r.balanceOf(address(p)), 1e21);
        assertEq(m.balanceOf(address(p)), 1e21);
    }
}
