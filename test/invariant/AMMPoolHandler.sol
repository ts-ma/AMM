// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AMMPool} from "../../src/AMMPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {addParams, addParamsOrdered} from "../utils/AddParams.sol";

/// @notice Stateful-invariant handler for one AMMPool over two supported tokens (Tier 0 or U8
///         taxed with a known fixed rate, truthful `balanceOf`). TEST_MATRIX §12 (M10 P0).
/// @dev Actions: later deposit, withdrawal, swap (both directions), `sync`, `skim`, direct
///      donation (surplus), LP transfer between actors, LP transfer to the Pool (must revert).
///      Every Pool call runs inside try/catch; a revert is accepted only with the exact selector
///      that the independent expectation predicts, and the state must then be unchanged (I4
///      evidence). Per-operation properties (I3, I7, I9, I10) are asserted right after each
///      successful call against values computed here from the pre-call state and the token
///      model; global properties (I1, I2, I9) are asserted by the invariant function.
///      Assertions revert the handler call; the suites run with `fail_on_revert = true`, so such
///      a revert fails the campaign instead of being discarded.
contract AMMPoolHandler is Test {
    uint256 internal constant D = 10_000;
    uint256 internal constant FEE_MUL = 9_970;
    uint256 internal constant FUND = 1e30;

    AMMPool public immutable pool;
    MockERC20 public immutable t0;
    MockERC20 public immutable t1;
    uint256 public immutable tax0;
    uint256 public immutable tax1;
    address public immutable surplusRecipient;

    address[3] internal actors;

    // Ghost accounting.
    uint256 public ghostMinted; // includes the 1,000 lock
    uint256 public ghostBurned;
    uint256 public ghostSurplus0; // expected balance − reserve
    uint256 public ghostSurplus1;

    // Call statistics: [ok, expected revert] per action.
    mapping(bytes32 => uint256[2]) internal stats;
    bytes32[] internal statKeys;

    constructor(AMMPool pool_, uint256 tax0_, uint256 tax1_, address surplusRecipient_) {
        pool = pool_;
        t0 = MockERC20(pool_.token0());
        t1 = MockERC20(pool_.token1());
        tax0 = tax0_;
        tax1 = tax1_;
        surplusRecipient = surplusRecipient_;
        actors = [makeAddr("lp0"), makeAddr("lp1"), makeAddr("lp2")];
        for (uint256 i; i < 3; ++i) {
            t0.mint(actors[i], FUND);
            t1.mint(actors[i], FUND);
            vm.startPrank(actors[i]);
            t0.approve(address(pool_), type(uint256).max);
            t1.approve(address(pool_), type(uint256).max);
            vm.stopPrank();
        }
        // Initial deposit (S = 0 → S > 0); every action below runs on the later path.
        vm.prank(actors[0]);
        (,, uint256 shares) = pool_.addLiquidity(addParams(1e21, 3e21, 0, actors[0], block.timestamp));
        ghostMinted = 1000 + shares;
        for (uint256 k; k < 8; ++k) {
            statKeys.push(bytes32(k));
        }
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Picks an actor and tops its wallets up to FUND when they fall below 1e27 (minting to
    ///      an actor changes no Pool state), so long sequences do not starve on wallet balances.
    function _actor(uint256 seed) internal returns (address who) {
        who = actors[seed % 3];
        if (t0.balanceOf(who) < 1e27) t0.mint(who, FUND);
        if (t1.balanceOf(who) < 1e27) t1.mint(who, FUND);
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function _netOf(uint256 tax, uint256 g) internal pure returns (uint256) {
        return g - (g * tax) / D;
    }

    function _sel(bytes memory reason) internal pure returns (bytes4 s) {
        if (reason.length >= 4) s = bytes4(reason);
    }

    /// @dev a·b ≥ c·d, exact in 512 bits.
    function _geq(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (bool) {
        (uint256 h1, uint256 l1) = Math.mul512(a, b);
        (uint256 h2, uint256 l2) = Math.mul512(c, d);
        return h1 > h2 || (h1 == h2 && l1 >= l2);
    }

    function _count(uint256 action, bool ok) internal {
        stats[bytes32(action)][ok ? 0 : 1] += 1;
    }

    struct State {
        uint256 r0;
        uint256 r1;
        uint256 supply;
        uint256 pool0;
        uint256 pool1;
        uint256 lpSum;
    }

    function _state() internal view returns (State memory s) {
        (s.r0, s.r1) = pool.getReserves();
        s.supply = pool.totalSupply();
        s.pool0 = t0.balanceOf(address(pool));
        s.pool1 = t1.balanceOf(address(pool));
        for (uint256 i; i < 3; ++i) {
            s.lpSum += pool.balanceOf(actors[i]);
        }
    }

    /// @dev I4 evidence for an accepted revert: nothing observable changed.
    function _assertUnchanged(State memory a) internal view {
        State memory b = _state();
        assertEq(a.r0, b.r0, "I4 r0");
        assertEq(a.r1, b.r1, "I4 r1");
        assertEq(a.supply, b.supply, "I4 supply");
        assertEq(a.pool0, b.pool0, "I4 pool0");
        assertEq(a.pool1, b.pool1, "I4 pool1");
        assertEq(a.lpSum, b.lpSum, "I4 LP balances");
    }

    /// @dev I10 for add / remove: per-share reserves of both tokens never decrease.
    function _assertPerShareNotDown(State memory a, State memory b) internal pure {
        assertTrue(_geq(b.r0, a.supply, a.r0, b.supply), "I10 token0 per-share reserve decreased");
        assertTrue(_geq(b.r1, a.supply, a.r1, b.supply), "I10 token1 per-share reserve decreased");
    }

    // ------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------

    struct AddCtx {
        address who;
        uint256 w0;
        uint256 w1;
    }

    /// @dev Caps: `a0 ∈ [1, 1e24]`. If `independent`, `a1 ∈ [1, 1e24]` is drawn on its own (often
    ///      far off the ratio, so one cap binds and tiny caps exercise the expected reverts);
    ///      otherwise `a1 = ceil(a0·r1/r0) + slack` with `slack ∈ [0, a0]` (near the ratio, so most
    ///      deposits succeed and the re-plan runs for taxed tokens).
    function addLiquidity(uint256 actorSeed, uint256 a0, uint256 a1, bool token1First, bool independent) external {
        a0 = bound(a0, 1, 1e24);
        if (independent) {
            a1 = bound(a1, 1, 1e24);
        } else {
            (uint256 r0, uint256 r1) = pool.getReserves();
            a1 = Math.mulDiv(a0, r1, r0, Math.Rounding.Ceil) + bound(a1, 0, a0);
        }
        AddCtx memory c = AddCtx(_actor(actorSeed), 0, 0);
        // An actor cannot authorise more than it holds; after near-total exits the ratio can be
        // extreme, so the near-ratio cap is clipped to the wallet (a model bound, not a Pool rule).
        a0 = Math.min(a0, t0.balanceOf(c.who));
        a1 = Math.min(a1, t1.balanceOf(c.who));
        if (a0 == 0 || a1 == 0) return; // ZeroAmount is an argument check, covered by unit tests
        c.w0 = t0.balanceOf(c.who);
        c.w1 = t1.balanceOf(c.who);
        State memory a = _state();

        vm.prank(c.who);
        try pool.addLiquidity(addParamsOrdered(a0, a1, 0, c.who, block.timestamp, token1First)) returns (
            uint256 n0, uint256 n1, uint256 shares
        ) {
            State memory b = _state();
            assertEq(b.r0, a.r0 + n0, "I9 add: reserve0 += own measured net");
            assertEq(b.r1, a.r1 + n1, "I9 add: reserve1 += own measured net");
            assertEq(b.pool0 - a.pool0, n0, "I9 add: Pool token0 rose by the net only");
            assertEq(b.pool1 - a.pool1, n1, "I9 add: Pool token1 rose by the net only");
            assertEq(b.supply, a.supply + shares, "I1 add: supply += shares");
            uint256 d0 = c.w0 - t0.balanceOf(c.who);
            uint256 d1 = c.w1 - t1.balanceOf(c.who);
            assertTrue(d0 >= n0 && d0 <= a0, "add: net0 <= debit0 <= request cap");
            assertTrue(d1 >= n1 && d1 <= a1, "add: net1 <= debit1 <= request cap");
            _assertPerShareNotDown(a, b);
            ghostMinted += shares;
            _count(0, true);
        } catch (bytes memory reason) {
            bytes4 s = _sel(reason);
            assertTrue(
                s == AMMPool.InsufficientDepositAmount.selector || s == AMMPool.InsufficientShares.selector,
                "unexpected addLiquidity revert"
            );
            _assertUnchanged(a);
            _count(0, false);
        }
    }

    /// @dev Shares: a fraction `bps ∈ [1, 10000]` of the actor's LP (at least 1 unit), so both
    ///      small and full exits occur; the 1-unit case exercises the rounding-to-0 revert.
    function removeLiquidity(uint256 actorSeed, uint256 bps) external {
        address who = _actor(actorSeed);
        uint256 held = pool.balanceOf(who);
        if (held == 0) return;
        uint256 shares = Math.max(1, Math.mulDiv(held, bound(bps, 1, 10_000), 10_000));
        State memory a = _state();
        uint256 x0 = Math.mulDiv(shares, a.r0, a.supply);
        uint256 x1 = Math.mulDiv(shares, a.r1, a.supply);
        uint256 w0 = t0.balanceOf(who);
        uint256 w1 = t1.balanceOf(who);

        vm.prank(who);
        try pool.removeLiquidity(shares, 0, 0, who, block.timestamp) returns (uint256 n0, uint256 n1) {
            State memory b = _state();
            assertEq(a.pool0 - b.pool0, x0, "I7 remove: A8 token0");
            assertEq(a.pool1 - b.pool1, x1, "I7 remove: A8 token1");
            assertEq(t0.balanceOf(who) - w0, n0, "I7 remove: return0 = recipient increase");
            assertEq(t1.balanceOf(who) - w1, n1, "I7 remove: return1 = recipient increase");
            assertEq(n0, _netOf(tax0, x0), "remove: token0 net per token model");
            assertEq(n1, _netOf(tax1, x1), "remove: token1 net per token model");
            assertEq(b.r0, a.r0 - x0, "I9 remove: reserve0 -= amount0");
            assertEq(b.r1, a.r1 - x1, "I9 remove: reserve1 -= amount1");
            assertEq(b.supply, a.supply - shares, "I1 remove: supply -= shares");
            _assertPerShareNotDown(a, b);
            ghostBurned += shares;
            _count(1, true);
        } catch (bytes memory reason) {
            assertEq(_sel(reason), AMMPool.InsufficientLiquidityBurned.selector, "unexpected removeLiquidity revert");
            assertTrue(x0 == 0 || x1 == 0, "remove reverted although both amounts > 0");
            _assertUnchanged(a);
            _count(1, false);
        }
    }

    struct SwapCtx {
        address who;
        bool zeroForOne;
        MockERC20 tIn;
        MockERC20 tOut;
        uint256 rIn;
        uint256 rOut;
        uint256 a;
        uint256 out;
        uint256 wIn;
        uint256 wOut;
    }

    function swap(uint256 actorSeed, bool zeroForOne, uint256 g) external {
        g = bound(g, 1, 1e23);
        SwapCtx memory c;
        c.who = _actor(actorSeed);
        c.zeroForOne = zeroForOne;
        (c.tIn, c.tOut) = zeroForOne ? (t0, t1) : (t1, t0);
        State memory a = _state();
        (c.rIn, c.rOut) = zeroForOne ? (a.r0, a.r1) : (a.r1, a.r0);
        c.a = _netOf(zeroForOne ? tax0 : tax1, g);
        c.out = Math.mulDiv(c.a * FEE_MUL, c.rOut, c.rIn * D + c.a * FEE_MUL);
        c.wIn = c.tIn.balanceOf(c.who);
        c.wOut = c.tOut.balanceOf(c.who);

        vm.prank(c.who);
        try pool.swapExactInput(address(c.tIn), g, 0, c.who, block.timestamp) returns (uint256 netOut) {
            _checkSwap(c, a, g, netOut);
            _count(2, true);
        } catch (bytes memory reason) {
            assertEq(_sel(reason), AMMPool.InsufficientOutputAmount.selector, "unexpected swap revert");
            assertEq(c.out, 0, "swap reverted although the formula gives out > 0");
            _assertUnchanged(a);
            _count(2, false);
        }
    }

    function _checkSwap(SwapCtx memory c, State memory a, uint256 g, uint256 netOut) internal view {
        State memory b = _state();
        (uint256 nIn, uint256 nOut) = c.zeroForOne ? (b.r0, b.r1) : (b.r1, b.r0);
        (uint256 pIn0, uint256 pOut0) = c.zeroForOne ? (a.pool0, a.pool1) : (a.pool1, a.pool0);
        (uint256 pIn1, uint256 pOut1) = c.zeroForOne ? (b.pool0, b.pool1) : (b.pool1, b.pool0);
        assertEq(c.wIn - c.tIn.balanceOf(c.who), g, "swap: payer debited exactly g (U8 inclusive)");
        assertEq(pIn1 - pIn0, c.a, "I9 swap: Pool input rose by the measured a");
        assertEq(nIn, c.rIn + c.a, "I9 swap: reserveIn += a");
        assertEq(pOut0 - pOut1, c.out, "I7 swap: A8, Pool sent exactly out");
        assertEq(nOut, c.rOut - c.out, "I9 swap: reserveOut -= out");
        assertEq(c.tOut.balanceOf(c.who) - c.wOut, netOut, "I7 swap: return = recipient increase");
        assertEq(netOut, _netOf(c.zeroForOne ? tax1 : tax0, c.out), "swap: net per token model");
        assertEq(b.supply, a.supply, "I10 swap: S unchanged");
        // I3 / BI-9: (rIn·D + a·9970)·(rOut − out) ≥ rIn·rOut·D, exact in 512 bits.
        assertTrue(
            _geq(c.rIn * D + c.a * FEE_MUL, c.rOut - c.out, c.rIn * c.rOut, D), "I3 fee-adjusted invariant violated"
        );
        // I10 swap: k never decreases.
        assertTrue(_geq(b.r0, b.r1, a.r0, a.r1), "I10 swap: r0*r1 decreased");
    }

    /// @dev With supported tokens no deficit can exist, so `sync()` must change nothing (I9).
    function sync() external {
        State memory a = _state();
        try pool.sync() {
            _assertUnchanged(a);
            _count(3, true);
        } catch {
            assertTrue(false, "sync reverted");
        }
    }

    function skim() external {
        State memory a = _state();
        uint256 s0 = a.pool0 - a.r0;
        uint256 s1 = a.pool1 - a.r1;
        uint256 w0 = t0.balanceOf(surplusRecipient);
        uint256 w1 = t1.balanceOf(surplusRecipient);
        try pool.skim() {
            State memory b = _state();
            assertEq(b.r0, a.r0, "I9 skim: reserve0 unchanged");
            assertEq(b.r1, a.r1, "I9 skim: reserve1 unchanged");
            assertEq(a.pool0 - b.pool0, s0, "I7 skim: A8 token0, sends exactly the surplus");
            assertEq(a.pool1 - b.pool1, s1, "I7 skim: A8 token1, sends exactly the surplus");
            assertEq(t0.balanceOf(surplusRecipient) - w0, _netOf(tax0, s0), "skim: recipient credit token0");
            assertEq(t1.balanceOf(surplusRecipient) - w1, _netOf(tax1, s1), "skim: recipient credit token1");
            ghostSurplus0 = 0;
            ghostSurplus1 = 0;
            _count(4, true);
        } catch {
            assertTrue(false, "skim reverted");
        }
    }

    /// @dev Unsolicited transfer to the Pool (minted, so untaxed): becomes surplus only.
    function donate(bool token0Side, uint256 amount) external {
        amount = bound(amount, 1, 1e22);
        State memory a = _state();
        (token0Side ? t0 : t1).mint(address(pool), amount);
        if (token0Side) ghostSurplus0 += amount;
        else ghostSurplus1 += amount;
        (uint256 r0, uint256 r1) = pool.getReserves();
        assertEq(r0, a.r0, "donation must not change reserve0");
        assertEq(r1, a.r1, "donation must not change reserve1");
        _count(5, true);
    }

    function transferLP(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, pool.balanceOf(from));
        State memory a = _state();
        vm.prank(from);
        bool ok = pool.transfer(to, amount);
        assertTrue(ok, "LP transfer returned false");
        State memory b = _state();
        assertEq(b.supply, a.supply, "LP transfer must not change supply");
        assertEq(b.lpSum, a.lpSum, "LP transfer between actors keeps their sum");
        assertEq(b.r0, a.r0, "LP transfer must not change reserve0");
        assertEq(b.r1, a.r1, "LP transfer must not change reserve1");
        _count(6, true);
    }

    function transferLPToPool(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, pool.balanceOf(from));
        State memory a = _state();
        vm.prank(from);
        try pool.transfer(address(pool), amount) {
            assertTrue(false, "LP transfer to the Pool succeeded");
        } catch (bytes memory reason) {
            assertEq(_sel(reason), AMMPool.LPTransferToPool.selector, "unexpected LP-to-Pool revert");
            _assertUnchanged(a);
            _count(7, false);
        }
    }

    // ------------------------------------------------------------------
    // Statistics
    // ------------------------------------------------------------------

    function logStats() external view {
        string[8] memory names =
            ["addLiquidity", "removeLiquidity", "swap", "sync", "skim", "donate", "transferLP", "transferLPToPool"];
        for (uint256 k; k < 8; ++k) {
            uint256[2] memory s = stats[bytes32(k)];
            console.log(names[k], s[0], s[1]);
        }
    }
}
