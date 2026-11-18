// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice AMMPool skeleton tests (TEST_MATRIX K01–K04, R01; DECISIONS M2-2 … M2-6).
contract AMMPoolTest is Test {
    MockERC20 internal tokenA; // 18 decimals
    MockERC20 internal tokenB; // 6 decimals
    address internal token0; // sorted lower address
    address internal token1; // sorted higher address
    address internal recipient = makeAddr("surplusRecipient");

    function setUp() public {
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 6);
        (token0, token1) = _sorted(address(tokenA), address(tokenB));
    }

    /// @dev Mirrors the sorting a future Factory performs before deploying (not implemented, M7).
    function _sorted(address a, address b) internal pure returns (address, address) {
        return a < b ? (a, b) : (b, a);
    }

    /// @dev Address the next `new AMMPool(...)` from this test contract will receive (CREATE).
    function _nextPoolAddress() internal view returns (address) {
        return vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
    }

    function _deploy() internal returns (AMMPool) {
        return new AMMPool(token0, token1, recipient);
    }

    // ------------------------------------------------------------------
    // K01 — token checks (DECISIONS M2-3)
    // ------------------------------------------------------------------

    function test_K01_zeroToken0Reverts() public {
        vm.expectRevert(AMMPool.ZeroAddress.selector);
        new AMMPool(address(0), token1, recipient);
    }

    /// A zero token1 is also "unsorted" (token0 > 0); ZeroAddress must still be reported.
    function test_K01_zeroToken1RevertsWithZeroAddress() public {
        vm.expectRevert(AMMPool.ZeroAddress.selector);
        new AMMPool(token0, address(0), recipient);
    }

    function test_K01_bothZeroRevertsWithZeroAddress() public {
        vm.expectRevert(AMMPool.ZeroAddress.selector);
        new AMMPool(address(0), address(0), recipient);
    }

    function test_K01_identicalTokensReverts() public {
        vm.expectRevert(AMMPool.IdenticalTokens.selector);
        new AMMPool(token0, token0, recipient);
    }

    function test_K01_unsortedTokensReverts() public {
        vm.expectRevert(AMMPool.TokensNotSorted.selector);
        new AMMPool(token1, token0, recipient);
    }

    /// Any (t0, t1, r): constructor outcome equals an independent classifier in the M2-3 order.
    function testFuzz_K01_K04_constructorMatchesClassifier(address t0, address t1, address r) public {
        address predicted = _nextPoolAddress();
        bytes4 expected;
        if (t0 == address(0) || t1 == address(0)) {
            expected = AMMPool.ZeroAddress.selector;
        } else if (t0 == t1) {
            expected = AMMPool.IdenticalTokens.selector;
        } else if (t0 > t1) {
            expected = AMMPool.TokensNotSorted.selector;
        } else if (r == address(0) || r == t0 || r == t1 || r == predicted) {
            expected = AMMPool.InvalidSurplusRecipient.selector;
        }

        if (expected != bytes4(0)) {
            vm.expectRevert(expected);
            new AMMPool(t0, t1, r);
        } else {
            AMMPool pool = new AMMPool(t0, t1, r);
            assertEq(address(pool), predicted);
            assertEq(pool.token0(), t0);
            assertEq(pool.token1(), t1);
            assertEq(pool.surplusRecipient(), r);
        }
    }

    /// Fuzz with the zero-address case forced into either position (rare for random addresses).
    function testFuzz_K01_zeroInEitherPosition(address other, bool zeroFirst) public {
        vm.assume(other != address(0)); // the both-zero case is covered by a unit test
        vm.expectRevert(AMMPool.ZeroAddress.selector);
        if (zeroFirst) new AMMPool(address(0), other, recipient);
        else new AMMPool(other, address(0), recipient);
    }

    // ------------------------------------------------------------------
    // K02, K04 — surplusRecipient checks (A3)
    // ------------------------------------------------------------------

    function test_K02_zeroRecipientReverts() public {
        vm.expectRevert(AMMPool.InvalidSurplusRecipient.selector);
        new AMMPool(token0, token1, address(0));
    }

    function test_K04_recipientEqualsToken0Reverts() public {
        vm.expectRevert(AMMPool.InvalidSurplusRecipient.selector);
        new AMMPool(token0, token1, token0);
    }

    function test_K04_recipientEqualsToken1Reverts() public {
        vm.expectRevert(AMMPool.InvalidSurplusRecipient.selector);
        new AMMPool(token0, token1, token1);
    }

    function test_K04_recipientEqualsPoolItselfReverts() public {
        address predicted = _nextPoolAddress();
        vm.expectRevert(AMMPool.InvalidSurplusRecipient.selector);
        new AMMPool(token0, token1, predicted);
    }

    /// Positive control: the prediction used above really is the deployed address.
    function test_K04_predictionMatchesDeployedAddress() public {
        address predicted = _nextPoolAddress();
        assertEq(address(_deploy()), predicted);
    }

    // ------------------------------------------------------------------
    // K03 — immutables, reserves, constants
    // ------------------------------------------------------------------

    function test_K03_initialState() public {
        AMMPool pool = _deploy();
        assertEq(pool.token0(), token0);
        assertEq(pool.token1(), token1);
        assertLt(uint160(pool.token0()), uint160(pool.token1()));
        assertEq(pool.surplusRecipient(), recipient);
        (uint256 r0, uint256 r1) = pool.getReserves();
        assertEq(r0, 0);
        assertEq(r1, 0);
        assertEq(pool.FEE_BPS(), 30);
        assertEq(pool.BPS_DENOMINATOR(), 10_000);
        // M3 part of K03: the LP token exists and starts empty.
        assertEq(pool.totalSupply(), 0);
        assertEq(pool.balanceOf(address(pool)), 0);
        assertEq(pool.MINIMUM_LIQUIDITY(), 1000);
    }

    /// DECISIONS M2-2: no code-existence check in M2 (left PENDING for M7).
    function test_M2_2_noCodeExistenceCheck() public {
        AMMPool pool = new AMMPool(address(1), address(2), recipient);
        assertEq(pool.token0(), address(1));
    }

    // ------------------------------------------------------------------
    // R01 — recorded reserves are not live balances
    // ------------------------------------------------------------------

    function test_R01_directTransferDoesNotChangeReserves() public {
        AMMPool pool = _deploy();
        tokenA.mint(address(pool), 5e18);
        tokenB.mint(address(pool), 7e6);
        assertEq(tokenA.balanceOf(address(pool)), 5e18);
        assertEq(tokenB.balanceOf(address(pool)), 7e6);

        (uint256 r0, uint256 r1) = pool.getReserves();
        assertEq(r0, 0);
        assertEq(r1, 0);
    }
}
