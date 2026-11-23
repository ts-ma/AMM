// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockTaxedERC20} from "./mocks/MockTaxedERC20.sol";
import {addParams, addParamsOrdered} from "./utils/AddParams.sol";

/// @notice M10 P0: TEST_MATRIX Z02 — a deposit followed by the full withdrawal of the minted
///         shares returns no more than was contributed ("no free value").
///         Properties per token i, for a later deposit at `(r_i, S)` with measured net `n_i` and
///         shares `σ`, followed by redeeming the same `σ` at `(r_i + n_i, S + σ)`:
///         (P1) Pool side [proven]: `floor(σ·(r_i + n_i)/(S + σ)) ≤ n_i`, because
///              `σ ≤ n_i·S/r_i` gives `σ·(r_i + n_i) ≤ n_i·(S + σ)`;
///         (P2) wallet side: the depositor's token balance after the round trip is not above its
///              balance before it (for taxed tokens the taxes on both legs make it strictly lower
///              whenever a taxed transfer is large enough to be taxed);
///         (P3) remaining LPs: `S` returns to its value before the deposit and each reserve is not
///              below its value before the deposit, so their per-share reserves did not decrease.
///         For the initial deposit (S = 0) P1–P2 are checked with the 1,000 lock remaining.
///         Expected reverts are classified by exact selector; any other revert fails the test.
contract AMMPoolRoundTripTest is Test {
    uint256 internal constant FUND = 1e30;
    uint256 internal constant MAX = type(uint256).max;

    address internal alice = makeAddr("alice"); // seed LP / trader
    address internal bob = makeAddr("bob"); // round-trip LP
    address internal surplus = makeAddr("surplusRecipient");

    AMMPool internal plain; // Tier 0, both tokens standard
    AMMPool internal taxed; // Tier 1, both tokens U8 taxed (1 % and 3 %)

    function setUp() public {
        plain = _newPool(address(new MockERC20("A", "A", 18)), address(new MockERC20("B", "B", 18)));
        taxed = _newPool(address(new MockTaxedERC20("P", "P", 18, 100)), address(new MockTaxedERC20("Q", "Q", 18, 300)));
        _seed(plain);
        _seed(taxed);
    }

    function _newPool(address a, address b) internal returns (AMMPool pl) {
        (address lo, address hi) = a < b ? (a, b) : (b, a);
        pl = new AMMPool(lo, hi, surplus);
        address[2] memory users = [alice, bob];
        address[2] memory toks = [lo, hi];
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 2; ++j) {
                MockERC20(toks[j]).mint(users[i], FUND);
                vm.prank(users[i]);
                MockERC20(toks[j]).approve(address(pl), MAX);
            }
        }
    }

    function _seed(AMMPool pl) internal {
        vm.prank(alice);
        pl.addLiquidity(addParams(1e21, 3e21, 0, alice, block.timestamp));
    }

    function _bal(AMMPool pl, uint256 i, address who) internal view returns (uint256) {
        return MockERC20(i == 0 ? pl.token0() : pl.token1()).balanceOf(who);
    }

    function _sel(bytes memory reason) internal pure returns (bytes4 s) {
        if (reason.length >= 4) s = bytes4(reason);
    }

    struct Trip {
        uint256 r0;
        uint256 r1;
        uint256 supply;
        uint256 bob0;
        uint256 bob1;
        uint256 n0;
        uint256 n1;
        uint256 shares;
    }

    /// @dev Moves the price first (alice swaps `pre` of one token, if `pre ≥ 1e3`), then runs the
    ///      round trip for bob and checks P1–P3.
    function _roundTrip(AMMPool pl, uint256 pre, bool preDir, uint256 a0, uint256 a1, bool token1First) internal {
        if (pre >= 1e3) {
            address tokenIn = preDir ? pl.token0() : pl.token1(); // before the prank (external call)
            vm.prank(alice);
            pl.swapExactInput(tokenIn, pre, 0, alice, block.timestamp);
        }
        Trip memory t;
        (t.r0, t.r1) = pl.getReserves();
        t.supply = pl.totalSupply();
        t.bob0 = _bal(pl, 0, bob);
        t.bob1 = _bal(pl, 1, bob);

        vm.prank(bob);
        try pl.addLiquidity(addParamsOrdered(a0, a1, 0, bob, block.timestamp, token1First)) returns (
            uint256 n0, uint256 n1, uint256 shares
        ) {
            (t.n0, t.n1, t.shares) = (n0, n1, shares);
        } catch (bytes memory reason) {
            bytes4 s = _sel(reason);
            assertTrue(
                s == AMMPool.InsufficientDepositAmount.selector || s == AMMPool.InsufficientShares.selector,
                "unexpected deposit revert"
            );
            return;
        }

        uint256 rem0 = Math.mulDiv(t.shares, t.r0 + t.n0, t.supply + t.shares);
        uint256 rem1 = Math.mulDiv(t.shares, t.r1 + t.n1, t.supply + t.shares);
        // P1 [proven], checked on the integers the Pool will use.
        assertLe(rem0, t.n0, "P1 token0: redeemable <= measured net");
        assertLe(rem1, t.n1, "P1 token1: redeemable <= measured net");

        vm.prank(bob);
        try pl.removeLiquidity(t.shares, 0, 0, bob, block.timestamp) returns (uint256, uint256) {
            assertEq(pl.totalSupply(), t.supply, "P3: S back to its value before the deposit");
        } catch (bytes memory reason) {
            // Both reserves are > 0, so only rounding of one side to 0 may stop the exit (M4-3r).
            assertEq(_sel(reason), AMMPool.InsufficientLiquidityBurned.selector, "unexpected withdrawal revert");
            assertTrue(rem0 == 0 || rem1 == 0, "revert only when one side rounds to 0");
            assertEq(pl.balanceOf(bob), t.shares, "bob keeps the shares");
        }

        assertLe(_bal(pl, 0, bob), t.bob0, "P2 token0: wallet not above its start");
        assertLe(_bal(pl, 1, bob), t.bob1, "P2 token1: wallet not above its start");
        (uint256 e0, uint256 e1) = pl.getReserves();
        assertGe(e0, t.r0, "P3 token0: reserve not below its start");
        assertGe(e1, t.r1, "P3 token1: reserve not below its start");
        assertEq(pl.balanceOf(address(pl)), 1000, "lock untouched");
    }

    /// @dev Range: `pre ∈ [0, 1e22]` (seed ≈ (1e21, 3e21)), caps `a_i ∈ [1, 1e24]`, either pull
    ///      order. Covers rounding-dominated tiny deposits (expected reverts) up to deposits
    ///      about 1,000× the reserves. Not covered: reserves or caps near 2^256 (Z08 / Z06).
    function testFuzz_Z02_roundTripTier0(uint256 pre, bool preDir, uint256 a0, uint256 a1, bool token1First) public {
        _roundTrip(plain, bound(pre, 0, 1e22), preDir, bound(a0, 1, 1e24), bound(a1, 1, 1e24), token1First);
    }

    /// @dev Same ranges with both tokens taxed (1 % / 3 %): the re-plan of the second token runs
    ///      whenever the first token's net differs from its target.
    function testFuzz_Z02_roundTripTaxed(uint256 pre, bool preDir, uint256 a0, uint256 a1, bool token1First) public {
        _roundTrip(taxed, bound(pre, 0, 1e22), preDir, bound(a0, 1, 1e24), bound(a1, 1, 1e24), token1First);
    }

    /// @dev Initial deposit round trip on a fresh Pool: the depositor receives at most what the
    ///      Pool measured (the 1,000 lock keeps its pro-rata part) and its wallet ends no higher.
    ///      Range: `a_i ∈ [1, 1e24]`; `floor(sqrt(n0·n1)) ≤ 1000` reverts
    ///      `InsufficientInitialLiquidity` (classified, not a failure).
    function testFuzz_Z02_initialRoundTrip(uint256 a0, uint256 a1, bool useTaxed) public {
        a0 = bound(a0, 1, 1e24);
        a1 = bound(a1, 1, 1e24);
        AMMPool pl = useTaxed
            ? _newPool(address(new MockTaxedERC20("P", "P", 18, 100)), address(new MockTaxedERC20("Q", "Q", 18, 300)))
            : _newPool(address(new MockERC20("A", "A", 18)), address(new MockERC20("B", "B", 18)));
        uint256 w0 = _bal(pl, 0, bob);
        uint256 w1 = _bal(pl, 1, bob);

        vm.prank(bob);
        try pl.addLiquidity(addParams(a0, a1, 0, bob, block.timestamp)) returns (
            uint256 n0, uint256 n1, uint256 shares
        ) {
            vm.prank(bob);
            try pl.removeLiquidity(shares, 0, 0, bob, block.timestamp) returns (uint256, uint256) {
                (uint256 e0, uint256 e1) = pl.getReserves();
                // The lock's pro-rata part stays: e_i ≥ n_i·1000/(shares + 1000) (redemption floors).
                // Products ≤ 1e24 · (1e24 + 1000), so they fit in uint256.
                assertGe(e0 * (shares + 1000), n0 * 1000, "lock's part of token0 stays");
                assertGe(e1 * (shares + 1000), n1 * 1000, "lock's part of token1 stays");
                assertEq(pl.totalSupply(), 1000, "only the lock remains");
            } catch (bytes memory reason) {
                assertEq(_sel(reason), AMMPool.InsufficientLiquidityBurned.selector, "unexpected withdrawal revert");
            }
            assertLe(_bal(pl, 0, bob), w0, "wallet token0 not above its start");
            assertLe(_bal(pl, 1, bob), w1, "wallet token1 not above its start");
        } catch (bytes memory reason) {
            assertEq(_sel(reason), AMMPool.InsufficientInitialLiquidity.selector, "unexpected deposit revert");
        }
    }
}
