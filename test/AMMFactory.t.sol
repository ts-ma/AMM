// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AMMFactory} from "../src/AMMFactory.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice AMMFactory registry tests (TEST_MATRIX F01–F03, F05; DECISIONS M7-1, M7-4).
///         Every revert asserts the exact error (M4-8) and that the registry is unchanged.
contract AMMFactoryTest is Test {
    AMMFactory internal factory;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal tokenC;
    address internal recipient = makeAddr("surplusRecipient");

    function setUp() public {
        factory = new AMMFactory(recipient);
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 6);
        tokenC = new MockERC20("Token C", "TKC", 18);
    }

    function _sorted(address a, address b) internal pure returns (address, address) {
        return a < b ? (a, b) : (b, a);
    }

    /// @dev Address the Factory's next `new AMMPool(...)` will receive (CREATE).
    function _nextPool() internal view returns (address) {
        return vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
    }

    /// @dev Registry state compared before / after a reverted call.
    function _assertRegistryUnchanged(address a, address b, uint256 lengthBefore) internal view {
        assertEq(factory.getPair(a, b), address(0), "getPair(a,b) unchanged");
        assertEq(factory.getPair(b, a), address(0), "getPair(b,a) unchanged");
        assertEq(factory.allPairsLength(), lengthBefore, "allPairsLength unchanged");
    }

    // ------------------------------------------------------------------
    // F05 (constructor part) — shared recipient checks (M7-1)
    // ------------------------------------------------------------------

    function test_F05_constructorStoresRecipient() public view {
        assertEq(factory.surplusRecipient(), recipient);
        assertEq(factory.allPairsLength(), 0);
    }

    function test_F05_constructorRejectsZeroRecipient() public {
        vm.expectRevert(AMMFactory.InvalidSurplusRecipient.selector);
        new AMMFactory(address(0));
    }

    function test_F05_constructorRejectsFactoryItself() public {
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(AMMFactory.InvalidSurplusRecipient.selector);
        new AMMFactory(next);
    }

    // ------------------------------------------------------------------
    // F01 — unique pair created, registered and announced
    // ------------------------------------------------------------------

    function test_F01_createPairRegistersAndEmits() public {
        (address t0, address t1) = _sorted(address(tokenA), address(tokenB));
        address expected = _nextPool();

        vm.expectEmit(true, true, false, true, address(factory));
        emit AMMFactory.PairCreated(t0, t1, expected, 1);
        address pool = factory.createPair(address(tokenA), address(tokenB));

        assertEq(pool, expected, "CREATE address");
        assertEq(factory.getPair(t0, t1), pool);
        assertEq(factory.allPairs(0), pool);
        assertEq(factory.allPairsLength(), 1);
        assertEq(AMMPool(pool).token0(), t0, "sorted token0");
        assertEq(AMMPool(pool).token1(), t1, "sorted token1");
    }

    function test_F01_reverseArgumentOrderSortsTheSame() public {
        (address t0, address t1) = _sorted(address(tokenA), address(tokenB));
        address expected = _nextPool();

        vm.expectEmit(true, true, false, true, address(factory));
        emit AMMFactory.PairCreated(t0, t1, expected, 1);
        address pool = factory.createPair(t1, t0); // higher address first

        assertEq(AMMPool(pool).token0(), t0);
        assertEq(AMMPool(pool).token1(), t1);
    }

    function test_F01_secondPairAppendsAndCounts() public {
        address p1 = factory.createPair(address(tokenA), address(tokenB));
        (address t0, address t1) = _sorted(address(tokenA), address(tokenC));
        address expected = _nextPool();

        vm.expectEmit(true, true, false, true, address(factory));
        emit AMMFactory.PairCreated(t0, t1, expected, 2);
        address p2 = factory.createPair(address(tokenA), address(tokenC));

        assertTrue(p1 != p2, "distinct Pools");
        assertEq(factory.allPairs(0), p1);
        assertEq(factory.allPairs(1), p2);
        assertEq(factory.allPairsLength(), 2);
    }

    /// @dev The compiler-generated array getter reverts with empty data (not a Panic).
    function test_F01_allPairsOutOfRangeReverts() public {
        factory.createPair(address(tokenA), address(tokenB));
        (bool ok, bytes memory ret) = address(factory).staticcall(abi.encodeCall(factory.allPairs, (1)));
        assertFalse(ok, "out-of-range index reverts");
        assertEq(ret.length, 0, "empty revert data");
    }

    // ------------------------------------------------------------------
    // F02 — reverse lookup
    // ------------------------------------------------------------------

    function test_F02_getPairBothOrders() public {
        address pool = factory.createPair(address(tokenA), address(tokenB));
        assertEq(factory.getPair(address(tokenA), address(tokenB)), pool);
        assertEq(factory.getPair(address(tokenB), address(tokenA)), pool);
    }

    function test_F02_unknownPairIsZero() public {
        factory.createPair(address(tokenA), address(tokenB));
        assertEq(factory.getPair(address(tokenA), address(tokenC)), address(0));
        assertEq(factory.getPair(address(tokenC), address(tokenA)), address(0));
    }

    /// @dev Range: any two distinct addresses above the precompile range that have no code yet,
    ///      given placeholder code with `vm.etch` (so the test is independent of the M7-2 check).
    ///      Shows ordering-independence of the registry; not that such tokens are usable.
    function testFuzz_F02_getPairSymmetric(address a, address b) public {
        vm.assume(uint160(a) > 0xffff && uint160(b) > 0xffff && a != b);
        vm.assume(a.code.length == 0 && b.code.length == 0);
        vm.assume(a != recipient && b != recipient);
        vm.etch(a, hex"00");
        vm.etch(b, hex"00");

        address pool = factory.createPair(a, b);
        (address t0, address t1) = _sorted(a, b);
        assertEq(factory.getPair(a, b), pool);
        assertEq(factory.getPair(b, a), pool);
        assertEq(AMMPool(pool).token0(), t0);
        assertEq(AMMPool(pool).token1(), t1);
    }

    // ------------------------------------------------------------------
    // F03 — zero, identical and duplicate pairs revert (check order M7-4)
    // ------------------------------------------------------------------

    function test_F03_zeroFirstReverts() public {
        vm.expectRevert(AMMFactory.ZeroAddress.selector);
        factory.createPair(address(0), address(tokenA));
        _assertRegistryUnchanged(address(0), address(tokenA), 0);
    }

    function test_F03_zeroSecondReverts() public {
        vm.expectRevert(AMMFactory.ZeroAddress.selector);
        factory.createPair(address(tokenA), address(0));
        _assertRegistryUnchanged(address(tokenA), address(0), 0);
    }

    /// @dev `(0, 0)` is both zero and identical: zero is checked first (as M2-3).
    function test_F03_bothZeroReportsZeroAddress() public {
        vm.expectRevert(AMMFactory.ZeroAddress.selector);
        factory.createPair(address(0), address(0));
        assertEq(factory.allPairsLength(), 0);
    }

    function test_F03_identicalReverts() public {
        vm.expectRevert(AMMFactory.IdenticalTokens.selector);
        factory.createPair(address(tokenA), address(tokenA));
        assertEq(factory.getPair(address(tokenA), address(tokenA)), address(0));
        assertEq(factory.allPairsLength(), 0);
    }

    function test_F03_duplicateSameOrderReverts() public {
        address pool = factory.createPair(address(tokenA), address(tokenB));

        vm.expectRevert(AMMFactory.PairExists.selector);
        factory.createPair(address(tokenA), address(tokenB));

        assertEq(factory.getPair(address(tokenA), address(tokenB)), pool, "registration kept");
        assertEq(factory.getPair(address(tokenB), address(tokenA)), pool);
        assertEq(factory.allPairsLength(), 1);
    }

    function test_F03_duplicateReverseOrderReverts() public {
        address pool = factory.createPair(address(tokenA), address(tokenB));

        vm.expectRevert(AMMFactory.PairExists.selector);
        factory.createPair(address(tokenB), address(tokenA));

        assertEq(factory.getPair(address(tokenA), address(tokenB)), pool);
        assertEq(factory.allPairsLength(), 1);
    }

    // ------------------------------------------------------------------
    // F05 — every Pool receives the shared recipient (M7-1)
    // ------------------------------------------------------------------

    function test_F05_poolsShareFactoryRecipient() public {
        address p1 = factory.createPair(address(tokenA), address(tokenB));
        address p2 = factory.createPair(address(tokenA), address(tokenC));
        assertEq(AMMPool(p1).surplusRecipient(), recipient);
        assertEq(AMMPool(p2).surplusRecipient(), recipient);
    }

    /// @dev Side effect disclosed in M7-1: a recipient that is itself a token blocks every pair
    ///      containing that token; the Pool constructor's A3 check bubbles up unchanged.
    function test_F05_recipientEqualToTokenBlocksItsPairs() public {
        AMMFactory f = new AMMFactory(address(tokenA));

        vm.expectRevert(AMMPool.InvalidSurplusRecipient.selector);
        f.createPair(address(tokenA), address(tokenB));
        assertEq(f.getPair(address(tokenA), address(tokenB)), address(0));
        assertEq(f.allPairsLength(), 0);

        address pool = f.createPair(address(tokenB), address(tokenC)); // pairs without tokenA work
        assertEq(AMMPool(pool).surplusRecipient(), address(tokenA));
    }
}
