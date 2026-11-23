// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AMMFactory} from "../src/AMMFactory.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Handler for TEST_MATRIX I5: random `createPair` calls over a fixed candidate set.
///         Candidates (index → address): 0–4 five MockERC20 tokens, 5 `address(0)`, 6 an address
///         without code. The handler predicts each call's outcome from a ghost registry and the
///         Factory's check order (DECISIONS M7-4: zero, identical, sort, code, uniqueness):
///         an unexpected revert, or a revert with another error than predicted, fails the run.
contract AMMFactoryHandler is Test {
    uint256 internal constant N = 7;

    AMMFactory public immutable factory;
    address[N] internal cand;

    // Ghost registry, keyed by the sorted candidate indices.
    mapping(uint256 lo => mapping(uint256 hi => address pool)) public ghostPair;
    uint256 public ghostCount;
    uint256 public created;
    uint256 public rejected;

    constructor(AMMFactory factory_) {
        factory = factory_;
        for (uint256 i; i < 5; ++i) {
            cand[i] = address(new MockERC20("T", "T", 18));
        }
        cand[5] = address(0);
        cand[6] = makeAddr("noCode");
    }

    function candAt(uint256 i) external view returns (address) {
        return cand[i];
    }

    function candCount() external pure returns (uint256) {
        return N;
    }

    function _expected(uint256 i, uint256 j) internal view returns (bytes4) {
        address a = cand[i];
        address b = cand[j];
        if (a == address(0) || b == address(0)) return AMMFactory.ZeroAddress.selector;
        if (a == b) return AMMFactory.IdenticalTokens.selector;
        if (a.code.length == 0 || b.code.length == 0) return AMMFactory.TokenHasNoCode.selector;
        (uint256 lo, uint256 hi) = a < b ? (i, j) : (j, i);
        if (ghostPair[lo][hi] != address(0)) return AMMFactory.PairExists.selector;
        return bytes4(0);
    }

    function createPair(uint256 i, uint256 j) external {
        i = bound(i, 0, N - 1);
        j = bound(j, 0, N - 1);
        bytes4 want = _expected(i, j);
        uint256 lenBefore = factory.allPairsLength();
        try factory.createPair(cand[i], cand[j]) returns (address pool) {
            assertEq(want, bytes4(0), "createPair succeeded where a revert was predicted");
            (uint256 lo, uint256 hi) = cand[i] < cand[j] ? (i, j) : (j, i);
            assertGt(pool.code.length, 0, "pool deployed");
            assertEq(AMMPool(pool).token0(), cand[lo], "token0 = lower address");
            assertEq(AMMPool(pool).token1(), cand[hi], "token1 = higher address");
            assertEq(AMMPool(pool).surplusRecipient(), factory.surplusRecipient(), "shared surplusRecipient");
            assertEq(factory.getPair(cand[i], cand[j]), pool, "getPair(a, b)");
            assertEq(factory.getPair(cand[j], cand[i]), pool, "getPair(b, a)");
            assertEq(factory.allPairsLength(), lenBefore + 1, "allPairs grows by one");
            assertEq(factory.allPairs(lenBefore), pool, "appended last");
            ghostPair[lo][hi] = pool;
            ghostCount += 1;
            created += 1;
        } catch (bytes memory reason) {
            assertTrue(want != bytes4(0), "unexpected createPair revert");
            assertEq(bytes4(reason), want, "revert reason differs from the check order");
            assertEq(factory.allPairsLength(), lenBefore, "a rejected call registers nothing");
            rejected += 1;
        }
    }
}

/// @notice TEST_MATRIX I5 (M10 P2): the Factory has no duplicate or unregistered pair.
///         After every call: (a) `allPairsLength()` equals the number of successful creations;
///         (b) every `allPairs[k]` is a distinct Pool with `token0 < token1`, registered under
///         both orderings in `getPair`, and equal to the handler's ghost entry; (c) for every
///         candidate pair (all 7 × 7 orderings, including zero, identical and code-less
///         addresses) `getPair` is non-zero exactly when the ghost registry has that pair, so no
///         pair is registered without an `allPairs` entry. Model: one Factory, seven candidate
///         addresses, `createPair` only; tokens equal to `surplusRecipient` (Pool constructor
///         revert) are covered by the M7 unit tests, not here.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 50
/// forge-config: default.invariant.fail-on-revert = true
contract AMMFactoryInvariantTest is StdInvariant, Test {
    AMMFactory internal factory;
    AMMFactoryHandler internal handler;

    function setUp() public {
        factory = new AMMFactory(makeAddr("surplusRecipient"));
        handler = new AMMFactoryHandler(factory);
        bytes4[] memory sel = new bytes4[](1);
        sel[0] = AMMFactoryHandler.createPair.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    function invariant_I5_registryConsistent() public view {
        uint256 len = factory.allPairsLength();
        assertEq(len, handler.ghostCount(), "I5: allPairsLength = successful creations");
        for (uint256 k; k < len; ++k) {
            AMMPool p = AMMPool(factory.allPairs(k));
            address t0 = p.token0();
            address t1 = p.token1();
            assertLt(uint160(t0), uint160(t1), "I5: token0 < token1");
            assertEq(factory.getPair(t0, t1), address(p), "I5: getPair(token0, token1)");
            assertEq(factory.getPair(t1, t0), address(p), "I5: getPair(token1, token0)");
            for (uint256 m; m < k; ++m) {
                assertTrue(factory.allPairs(m) != address(p), "I5: no duplicate pool");
                AMMPool q = AMMPool(factory.allPairs(m));
                assertFalse(q.token0() == t0 && q.token1() == t1, "I5: no duplicate pair");
            }
        }
        uint256 n = handler.candCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address a = handler.candAt(i);
                address b = handler.candAt(j);
                (uint256 lo, uint256 hi) = a < b ? (i, j) : (j, i);
                assertEq(factory.getPair(a, b), handler.ghostPair(lo, hi), "I5: getPair matches the ghost registry");
            }
        }
    }

    function afterInvariant() external view {
        assertEq(handler.created(), handler.ghostCount());
        console.log("created / rejected (last run)", handler.created(), handler.rejected());
    }
}
