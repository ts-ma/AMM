// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AMMPool} from "../../src/AMMPool.sol";
import {MockDeficitERC20} from "../mocks/MockDeficitERC20.sol";

/// @notice Shared M6 fixture: a Pool over two `MockDeficitERC20` tokens (standard transfers,
///         balances slashable to create a deficit), funded actors, and a full-state snapshot
///         used to prove complete rollback of failed calls (DECISIONS M5-6, M6-5).
abstract contract PoolStateFixture is Test {
    uint256 internal constant FUND = 1e30;
    uint256 internal constant MAX = type(uint256).max;

    MockDeficitERC20 internal t0;
    MockDeficitERC20 internal t1;
    AMMPool internal pool;

    address internal alice = makeAddr("alice"); // LP
    address internal bob = makeAddr("bob"); // trader / second LP
    address internal carol = makeAddr("carol"); // recipient
    address internal surplus = makeAddr("surplusRecipient");

    function setUp() public virtual {
        MockDeficitERC20 a = new MockDeficitERC20("Token A", "TKA", 18);
        MockDeficitERC20 b = new MockDeficitERC20("Token B", "TKB", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        pool = new AMMPool(address(t0), address(t1), surplus);
        _fund(alice);
        _fund(bob);
        _seed(1_000_000, 2_000_000);
    }

    function _fund(address who) internal {
        t0.mint(who, FUND);
        t1.mint(who, FUND);
        vm.startPrank(who);
        t0.approve(address(pool), MAX);
        t1.approve(address(pool), MAX);
        vm.stopPrank();
    }

    function _seed(uint256 a0, uint256 a1) internal returns (uint256 s) {
        vm.prank(alice);
        (,, s) = pool.addLiquidity(a0, a1, 0, 0, 0, alice, block.timestamp);
    }

    /// @dev Creates surplus by a direct transfer from a third party.
    function _donate(MockDeficitERC20 t, uint256 amount) internal {
        t.mint(address(pool), amount);
    }

    /// @dev Creates a deficit: the Pool's balance falls without any Pool call.
    function _slashPool(MockDeficitERC20 t, uint256 amount) internal {
        t.slash(address(pool), amount);
    }

    function _reserves() internal view returns (uint256 r0, uint256 r1) {
        (r0, r1) = pool.getReserves();
    }

    struct Snap {
        uint256 r0;
        uint256 r1;
        uint256 supply;
        uint256 poolLP;
        uint256 aliceLP;
        uint256 bobLP;
        uint256 pool0;
        uint256 pool1;
        uint256 alice0;
        uint256 alice1;
        uint256 bob0;
        uint256 bob1;
        uint256 carol0;
        uint256 carol1;
        uint256 surplus0;
        uint256 surplus1;
        uint256 allowA0;
        uint256 allowA1;
        uint256 allowB0;
        uint256 allowB1;
    }

    function _snap() internal view returns (Snap memory s) {
        (s.r0, s.r1) = pool.getReserves();
        s.supply = pool.totalSupply();
        s.poolLP = pool.balanceOf(address(pool));
        s.aliceLP = pool.balanceOf(alice);
        s.bobLP = pool.balanceOf(bob);
        IERC20 a = IERC20(pool.token0());
        IERC20 b = IERC20(pool.token1());
        s.pool0 = a.balanceOf(address(pool));
        s.pool1 = b.balanceOf(address(pool));
        s.alice0 = a.balanceOf(alice);
        s.alice1 = b.balanceOf(alice);
        s.bob0 = a.balanceOf(bob);
        s.bob1 = b.balanceOf(bob);
        s.carol0 = a.balanceOf(carol);
        s.carol1 = b.balanceOf(carol);
        s.surplus0 = a.balanceOf(surplus);
        s.surplus1 = b.balanceOf(surplus);
        s.allowA0 = a.allowance(alice, address(pool));
        s.allowA1 = b.allowance(alice, address(pool));
        s.allowB0 = a.allowance(bob, address(pool));
        s.allowB1 = b.allowance(bob, address(pool));
    }

    /// @dev Full rollback (DECISIONS M5-6): every relevant quantity equals its pre-call value.
    function _assertSame(Snap memory x, Snap memory y) internal pure {
        assertEq(x.r0, y.r0, "reserve0");
        assertEq(x.r1, y.r1, "reserve1");
        assertEq(x.supply, y.supply, "LP totalSupply");
        assertEq(x.poolLP, y.poolLP, "Pool LP (lock)");
        assertEq(x.aliceLP, y.aliceLP, "alice LP");
        assertEq(x.bobLP, y.bobLP, "bob LP");
        assertEq(x.pool0, y.pool0, "Pool token0");
        assertEq(x.pool1, y.pool1, "Pool token1");
        assertEq(x.alice0, y.alice0, "alice token0");
        assertEq(x.alice1, y.alice1, "alice token1");
        assertEq(x.bob0, y.bob0, "bob token0");
        assertEq(x.bob1, y.bob1, "bob token1");
        assertEq(x.carol0, y.carol0, "carol token0");
        assertEq(x.carol1, y.carol1, "carol token1");
        assertEq(x.surplus0, y.surplus0, "surplusRecipient token0");
        assertEq(x.surplus1, y.surplus1, "surplusRecipient token1");
        assertEq(x.allowA0, y.allowA0, "alice allowance0");
        assertEq(x.allowA1, y.allowA1, "alice allowance1");
        assertEq(x.allowB0, y.allowB0, "bob allowance0");
        assertEq(x.allowB1, y.allowB1, "bob allowance1");
    }

    /// @dev Calls the Pool as `caller` with `data`, expects exactly `err`, and proves rollback.
    function _expectRevertNoChange(address caller, bytes memory data, bytes memory err) internal {
        Snap memory before = _snap();
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(pool).call(data);
        assertFalse(ok, "call must revert");
        assertEq(ret, err, "exact revert data");
        _assertSame(before, _snap());
    }

    /// @dev Storage writes to the Pool during the call recorded since `vm.record()`.
    function _poolWrites() internal view returns (uint256) {
        (, bytes32[] memory writes) = vm.accesses(address(pool));
        return writes.length;
    }
}
