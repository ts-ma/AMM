// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {AMMPool} from "../src/AMMPool.sol";
import {AMMMath} from "../src/libraries/AMMMath.sol";
import {MockDeficitERC20} from "./mocks/MockDeficitERC20.sol";
import {PoolStateFixture} from "./utils/PoolStateFixture.sol";
import {addParams, addParamsOrdered} from "./utils/AddParams.sol";

/// @notice M6: deficit entry check on add, remove and swap (U4, ARCHITECTURE §5.3;
///         DECISIONS M6-2). TEST_MATRIX R08. Every revert asserts the exact error (M4-8) and
///         full rollback of the PoolStateFixture snapshot (M5-6).
contract AMMPoolDeficitTest is PoolStateFixture {
    bytes internal constant DEFICIT = abi.encodeWithSelector(AMMPool.ReserveDeficit.selector);

    function _addData(bool token1First) internal view returns (bytes memory) {
        return
            abi.encodeCall(AMMPool.addLiquidity, (addParamsOrdered(1000, 4000, 0, alice, block.timestamp, token1First)));
    }

    function _removeData(uint256 shares) internal view returns (bytes memory) {
        return abi.encodeCall(AMMPool.removeLiquidity, (shares, 0, 0, carol, block.timestamp));
    }

    function _swapData(address tokenIn) internal view returns (bytes memory) {
        return abi.encodeCall(AMMPool.swapExactInput, (tokenIn, 10_000, 0, carol, block.timestamp));
    }

    /// @dev All four operations revert ReserveDeficit with full rollback.
    function _assertAllRevert() internal {
        _expectRevertNoChange(alice, _addData(false), DEFICIT);
        _expectRevertNoChange(alice, _addData(true), DEFICIT);
        _expectRevertNoChange(alice, _removeData(1000), DEFICIT);
        _expectRevertNoChange(bob, _swapData(address(t0)), DEFICIT);
        _expectRevertNoChange(bob, _swapData(address(t1)), DEFICIT);
    }

    /// R08: a deficit in token0, in token1, or in both blocks add, remove and swap (both directions).
    function test_R08_deficitToken0BlocksAll() public {
        _slashPool(t0, 1);
        _assertAllRevert();
    }

    function test_R08_deficitToken1BlocksAll() public {
        _slashPool(t1, 1);
        _assertAllRevert();
    }

    function test_R08_deficitBothBlocksAll() public {
        _slashPool(t0, 500);
        _slashPool(t1, 700);
        _assertAllRevert();
    }

    /// A deficit in one token is not masked by surplus in the other.
    function test_R08_deficitWithOtherTokenSurplusBlocksAll() public {
        _slashPool(t0, 1);
        _donate(t1, 1e18);
        _assertAllRevert();
        _donate(t0, 1); // token0 back to balance == reserve, token1 still in surplus
        vm.prank(bob);
        pool.swapExactInput(address(t0), 10_000, 0, carol, block.timestamp);
    }

    /// Boundary: balance == reserve passes; balance == reserve − 1 reverts (kills `<=` vs `<`).
    function test_R08_boundaryEqualPassesMinusOneReverts() public {
        _slashPool(t1, 1);
        _expectRevertNoChange(bob, _swapData(address(t0)), DEFICIT);
        _donate(t1, 1); // exactly back to balance == reserve
        vm.prank(bob);
        pool.swapExactInput(address(t0), 10_000, 0, carol, block.timestamp);
        vm.prank(alice);
        pool.addLiquidity(addParams(1000, 4000, 0, alice, block.timestamp));
        vm.prank(alice);
        pool.removeLiquidity(1000, 0, 0, carol, block.timestamp);
    }

    /// R08 fuzz. Range: deficit of 1..reserve in token0 and/or token1 from the seeded reserves
    /// (1e6, 2e6). Every operation reverts ReserveDeficit with full rollback.
    function testFuzz_R08_anyDeficitBlocksAll(uint256 d0, uint256 d1, uint8 which) public {
        which = uint8(bound(which, 1, 3));
        (uint256 r0, uint256 r1) = _reserves();
        if (which & 1 != 0) _slashPool(t0, bound(d0, 1, r0));
        if (which & 2 != 0) _slashPool(t1, bound(d1, 1, r1));
        _assertAllRevert();
    }

    /// R08: after sync() the operations resume, priced from the reconciled reserves.
    function test_R08_operationsResumeAfterSync() public {
        _slashPool(t0, 200_000);
        _assertAllRevert();
        pool.sync();
        (uint256 r0, uint256 r1) = _reserves();
        assertEq(r0, 800_000);
        assertEq(r1, 2_000_000);

        uint256 expected = AMMMath.getAmountOut(10_000, r0, r1);
        vm.prank(bob);
        uint256 out = pool.swapExactInput(address(t0), 10_000, 0, carol, block.timestamp);
        assertEq(out, expected, "priced from reconciled reserves");

        vm.prank(alice);
        (uint256 n0, uint256 n1, uint256 s) = pool.addLiquidity(addParams(1000, 1_000_000, 0, alice, block.timestamp));
        assertGt(s, 0);
        assertGt(n0, 0);
        assertGt(n1, 0);

        vm.prank(alice);
        (uint256 o0, uint256 o1) = pool.removeLiquidity(1000, 0, 0, carol, block.timestamp);
        assertGt(o0, 0);
        assertGt(o1, 0);
    }

    // ------------------------------------------------------------------
    // Check order (M6-2): the deficit check comes after the argument checks and before any
    // effect or transfer.
    // ------------------------------------------------------------------

    function test_R08_checkOrderAdd() public {
        _slashPool(t0, 1);
        uint256 late = block.timestamp - 1;
        _expectRevertNoChange(
            alice,
            abi.encodeCall(AMMPool.addLiquidity, (addParams(1000, 4000, 0, alice, late))),
            abi.encodeWithSelector(AMMPool.DeadlineExpired.selector)
        );
        _expectRevertNoChange(
            alice,
            abi.encodeCall(AMMPool.addLiquidity, (addParams(1000, 4000, 0, address(pool), block.timestamp))),
            abi.encodeWithSelector(AMMPool.InvalidRecipient.selector)
        );
        _expectRevertNoChange(
            alice,
            abi.encodeCall(AMMPool.addLiquidity, (addParams(0, 4000, 0, alice, block.timestamp))),
            abi.encodeWithSelector(AMMPool.ZeroAmount.selector)
        );
        // M8: the tax-hint range check (InvalidTaxBps) no longer exists. The deficit is still
        // reported before any transfer, whichever token the caller pulls first.
        _expectRevertNoChange(alice, _addData(false), DEFICIT);
        _expectRevertNoChange(alice, _addData(true), DEFICIT);
    }

    function test_R08_checkOrderRemove() public {
        _slashPool(t1, 1);
        _expectRevertNoChange(
            alice,
            abi.encodeCall(AMMPool.removeLiquidity, (1000, 0, 0, carol, block.timestamp - 1)),
            abi.encodeWithSelector(AMMPool.DeadlineExpired.selector)
        );
        _expectRevertNoChange(
            alice,
            abi.encodeCall(AMMPool.removeLiquidity, (1000, 0, 0, address(0), block.timestamp)),
            abi.encodeWithSelector(AMMPool.InvalidRecipient.selector)
        );
        _expectRevertNoChange(alice, _removeData(0), abi.encodeWithSelector(AMMPool.ZeroAmount.selector));
        // Before the burn: even shares above the caller's balance report the deficit.
        _expectRevertNoChange(bob, _removeData(1), DEFICIT);
        _expectRevertNoChange(alice, _removeData(MAX), DEFICIT);
    }

    function test_R08_checkOrderSwap() public {
        _slashPool(t0, 1);
        _expectRevertNoChange(
            bob,
            abi.encodeCall(AMMPool.swapExactInput, (address(t0), 10_000, 0, carol, block.timestamp - 1)),
            abi.encodeWithSelector(AMMPool.DeadlineExpired.selector)
        );
        _expectRevertNoChange(
            bob,
            abi.encodeCall(AMMPool.swapExactInput, (address(t0), 10_000, 0, address(pool), block.timestamp)),
            abi.encodeWithSelector(AMMPool.InvalidRecipient.selector)
        );
        _expectRevertNoChange(
            bob,
            abi.encodeCall(AMMPool.swapExactInput, (address(0xBEEF), 10_000, 0, carol, block.timestamp)),
            abi.encodeWithSelector(AMMPool.InvalidTokenIn.selector)
        );
        _expectRevertNoChange(
            bob,
            abi.encodeCall(AMMPool.swapExactInput, (address(t0), 0, 0, carol, block.timestamp)),
            abi.encodeWithSelector(AMMMath.InsufficientInputAmount.selector)
        );
        _expectRevertNoChange(bob, _swapData(address(t1)), DEFICIT);
    }

    /// The initial path has no deficit check (both reserves are 0): pre-existing balances are
    /// surplus, and the first deposit still works (M6-2).
    function test_R08_initialPathUnaffected() public {
        MockDeficitERC20 a = new MockDeficitERC20("A", "A", 18);
        MockDeficitERC20 b = new MockDeficitERC20("B", "B", 18);
        (MockDeficitERC20 x, MockDeficitERC20 y) = address(a) < address(b) ? (a, b) : (b, a);
        AMMPool p = new AMMPool(address(x), address(y), surplus);
        x.mint(address(p), 5);
        x.mint(alice, 1e6);
        y.mint(alice, 1e6);
        vm.startPrank(alice);
        x.approve(address(p), MAX);
        y.approve(address(p), MAX);
        (uint256 n0, uint256 n1,) = p.addLiquidity(addParams(1e6, 1e6, 0, alice, block.timestamp));
        vm.stopPrank();
        assertEq(n0, 1e6);
        assertEq(n1, 1e6);
        (uint256 r0,) = p.getReserves();
        assertEq(x.balanceOf(address(p)) - r0, 5, "earlier balance stays surplus");
    }

    /// The quote has no deficit check (DECISIONS M6-2 places it in add, remove and swap only):
    /// in a deficit it still prices from the recorded reserves while the swap reverts.
    function test_R08_quoteDoesNotCheckDeficit() public {
        (uint256 r0, uint256 r1) = _reserves();
        _slashPool(t0, 1);
        assertEq(pool.getAmountOut(address(t0), 10_000), AMMMath.getAmountOut(10_000, r0, r1));
        _expectRevertNoChange(bob, _swapData(address(t0)), DEFICIT);
    }
}
