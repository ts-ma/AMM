// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockTaxedERC20} from "./mocks/MockTaxedERC20.sol";
import {addParams} from "./utils/AddParams.sol";

/// @notice M10 P0: swap and withdrawal with Tier 1 (U8) taxed tokens — TEST_MATRIX S05, S06 and
///         the swap / remove part of Z04 (moved from M8 to M10 at the M8 acceptance).
///         Accounting rules under test (ARCHITECTURE §5.2, §6.3, §6.4; DECISIONS M5-1, M5-3, M4-3):
///         - swap input: pricing and `reserveIn` use the Pool's measured increase `a`, never the
///           requested gross `g`; the payer is debited exactly `g` (U8 condition 1);
///         - swap / remove output: `reserveOut` (or `reserve_i`) falls by the Pool-side amount, the
///           Pool's balance falls by exactly that amount (A8), and MIN-NET is judged on the
///           recipient's measured increase;
///         - surplus (balance − reserve) is unchanged by the call in both tokens.
///         Token model: `MockTaxedERC20` burns `floor(g × taxBps / 10000)` of every transfer
///         (so a transfer with `g × taxBps < 10000` is not taxed). Expected values are computed
///         independently from the formulas, not read back from the Pool.
contract AMMPoolTaxedSwapRemoveTest is Test {
    uint256 internal constant D = 10_000;
    uint256 internal constant FEE_MUL = 9_970;
    uint256 internal constant FUND = 1e30;
    uint256 internal constant MAX = type(uint256).max;

    address internal alice = makeAddr("alice"); // LP
    address internal bob = makeAddr("bob"); // trader
    address internal carol = makeAddr("carol"); // recipient
    address internal surplus = makeAddr("surplusRecipient");

    // Pool A: one taxed token X (2.5 %) and one standard token Y.
    MockTaxedERC20 internal x;
    MockERC20 internal y;
    AMMPool internal poolA;

    // Pool B: both tokens taxed (1 % and 3 %), assigned to token0/token1 by address order.
    AMMPool internal poolB;

    function setUp() public {
        x = new MockTaxedERC20("Taxed X", "TX", 18, 250);
        y = new MockERC20("Plain Y", "PY", 18);
        poolA = _newPool(address(x), address(y));
        _seed(poolA, 1e21, 3e21);

        MockTaxedERC20 p = new MockTaxedERC20("Taxed P", "TP", 18, 100);
        MockTaxedERC20 q = new MockTaxedERC20("Taxed Q", "TQ", 18, 300);
        poolB = _newPool(address(p), address(q));
        _seed(poolB, 1e21, 3e21);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

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

    function _seed(AMMPool pl, uint256 a0, uint256 a1) internal {
        vm.prank(alice);
        pl.addLiquidity(addParams(a0, a1, 0, alice, block.timestamp));
    }

    function _tax(address token) internal view returns (uint256) {
        if (token == address(y)) return 0;
        return MockTaxedERC20(token).taxBps();
    }

    /// @dev Recipient credit of a U8 transfer of `g` (fee floored, MockTaxedERC20).
    function _netOf(address token, uint256 g) internal view returns (uint256) {
        return g - (g * _tax(token)) / D;
    }

    /// @dev ARCHITECTURE §6.4, computed independently of AMMMath.
    function _ref(uint256 a, uint256 rIn, uint256 rOut) internal pure returns (uint256) {
        return Math.mulDiv(a * FEE_MUL, rOut, rIn * D + a * FEE_MUL);
    }

    function _inOut(AMMPool pl, address tokenIn) internal view returns (uint256 rIn, uint256 rOut) {
        (uint256 r0, uint256 r1) = pl.getReserves();
        (rIn, rOut) = tokenIn == pl.token0() ? (r0, r1) : (r1, r0);
    }

    function _bal(address token, address who) internal view returns (uint256) {
        return MockERC20(token).balanceOf(who);
    }

    function _surplus(AMMPool pl) internal view returns (uint256 s0, uint256 s1) {
        (uint256 r0, uint256 r1) = pl.getReserves();
        s0 = _bal(pl.token0(), address(pl)) - r0;
        s1 = _bal(pl.token1(), address(pl)) - r1;
    }

    struct Snap {
        uint256 r0;
        uint256 r1;
        uint256 supply;
        uint256 poolLP;
        uint256 aliceLP;
        uint256 pool0;
        uint256 pool1;
        uint256 alice0;
        uint256 alice1;
        uint256 bob0;
        uint256 bob1;
        uint256 carol0;
        uint256 carol1;
    }

    function _snap(AMMPool pl) internal view returns (Snap memory s) {
        (s.r0, s.r1) = pl.getReserves();
        s.supply = pl.totalSupply();
        s.poolLP = pl.balanceOf(address(pl));
        s.aliceLP = pl.balanceOf(alice);
        address t0 = pl.token0();
        address t1 = pl.token1();
        s.pool0 = _bal(t0, address(pl));
        s.pool1 = _bal(t1, address(pl));
        s.alice0 = _bal(t0, alice);
        s.alice1 = _bal(t1, alice);
        s.bob0 = _bal(t0, bob);
        s.bob1 = _bal(t1, bob);
        s.carol0 = _bal(t0, carol);
        s.carol1 = _bal(t1, carol);
    }

    function _assertSame(Snap memory a, Snap memory b) internal pure {
        assertEq(a.r0, b.r0, "reserve0");
        assertEq(a.r1, b.r1, "reserve1");
        assertEq(a.supply, b.supply, "LP supply");
        assertEq(a.poolLP, b.poolLP, "lock");
        assertEq(a.aliceLP, b.aliceLP, "alice LP");
        assertEq(a.pool0, b.pool0, "pool token0");
        assertEq(a.pool1, b.pool1, "pool token1");
        assertEq(a.alice0, b.alice0, "alice token0");
        assertEq(a.alice1, b.alice1, "alice token1");
        assertEq(a.bob0, b.bob0, "bob token0");
        assertEq(a.bob1, b.bob1, "bob token1");
        assertEq(a.carol0, b.carol0, "carol token0");
        assertEq(a.carol1, b.carol1, "carol token1");
    }

    /// @dev Executes a swap and checks every accounting equation against independent expectations.
    struct SwapExp {
        address tokenOut;
        uint256 rIn;
        uint256 rOut;
        uint256 s0;
        uint256 s1;
        uint256 a;
        uint256 out;
        uint256 net;
        uint256 bobIn;
        uint256 poolIn;
        uint256 poolOut;
        uint256 carolOut;
    }

    function _checkedSwap(AMMPool pl, address tokenIn, uint256 g) internal returns (uint256 netOut) {
        SwapExp memory e;
        e.tokenOut = tokenIn == pl.token0() ? pl.token1() : pl.token0();
        (e.rIn, e.rOut) = _inOut(pl, tokenIn);
        (e.s0, e.s1) = _surplus(pl);
        e.a = _netOf(tokenIn, g);
        e.out = _ref(e.a, e.rIn, e.rOut);
        e.net = _netOf(e.tokenOut, e.out);
        e.bobIn = _bal(tokenIn, bob);
        e.poolIn = _bal(tokenIn, address(pl));
        e.poolOut = _bal(e.tokenOut, address(pl));
        e.carolOut = _bal(e.tokenOut, carol);

        vm.expectEmit(true, true, false, true, address(pl));
        emit AMMPool.Swap(bob, carol, tokenIn, e.a, e.out, e.net);
        vm.prank(bob);
        netOut = pl.swapExactInput(tokenIn, g, e.net, carol, block.timestamp);

        assertEq(netOut, e.net, "return = recipient's measured increase");
        assertEq(_bal(e.tokenOut, carol) - e.carolOut, e.net, "recipient credit");
        assertEq(e.bobIn - _bal(tokenIn, bob), g, "payer debited exactly g (U8 inclusive)");
        assertEq(_bal(tokenIn, address(pl)) - e.poolIn, e.a, "Pool received a");
        assertEq(e.poolOut - _bal(e.tokenOut, address(pl)), e.out, "A8: Pool sent exactly out");
        (uint256 nIn, uint256 nOut) = _inOut(pl, tokenIn);
        assertEq(nIn, e.rIn + e.a, "reserveIn += measured a");
        assertEq(nOut, e.rOut - e.out, "reserveOut -= out (Pool side, not netOut)");
        (uint256 t0s, uint256 t1s) = _surplus(pl);
        assertEq(t0s, e.s0, "surplus0 unchanged");
        assertEq(t1s, e.s1, "surplus1 unchanged");
    }

    // ------------------------------------------------------------------
    // S05 — taxed input: pricing and accounting use the measured net
    // ------------------------------------------------------------------

    /// @dev X (2.5 %) in, Y out. g = 1e19: a = 9.75e18. Pricing on g would pay more than pricing
    ///      on a, so the test also shows that the two differ for these inputs.
    function test_S05_taxedInputPricedOnMeasuredNet() public {
        uint256 g = 1e19;
        (uint256 rIn, uint256 rOut) = _inOut(poolA, address(x));
        uint256 a = _netOf(address(x), g);
        assertEq(a, 9.75e18, "a = g - floor(g * 250 / 10000)");
        assertLt(_ref(a, rIn, rOut), _ref(g, rIn, rOut), "pricing on gross would differ");
        uint256 netOut = _checkedSwap(poolA, address(x), g);
        assertEq(netOut, _ref(a, rIn, rOut), "standard output: netOut == out");
    }

    // ------------------------------------------------------------------
    // S06 — taxed output: the minimum is judged on the recipient's actual receipt
    // ------------------------------------------------------------------

    /// @dev Y in, X (2.5 %) out: `min = net + 1` reverts `InsufficientNetReceived` with full
    ///      rollback although the Pool-side `out` exceeds `net + 1`; `min = net` succeeds.
    function test_S06_taxedOutputMinNetBoundary() public {
        uint256 g = 1e19;
        (uint256 rIn, uint256 rOut) = _inOut(poolA, address(y));
        uint256 out = _ref(g, rIn, rOut);
        uint256 net = _netOf(address(x), out);
        assertGt(out, net + 1, "Pool-side out is above the failing minimum");

        Snap memory before = _snap(poolA);
        vm.expectRevert(AMMPool.InsufficientNetReceived.selector);
        vm.prank(bob);
        poolA.swapExactInput(address(y), g, net + 1, carol, block.timestamp);
        _assertSame(before, _snap(poolA));

        assertEq(_checkedSwap(poolA, address(y), g), net);
    }

    // ------------------------------------------------------------------
    // Z04 (swap) — fuzz gross vs net, both tokens taxed, both directions
    // ------------------------------------------------------------------

    /// @dev Range: an optional prior swap of `pre ∈ [0, 1e22]` (any direction) moves the state
    ///      away from the seed (r ≈ (0.99e21, 2.91e21) after the taxed initial deposit); then
    ///      `g ∈ [1e3, 1e23]`. With these sizes `out > 0` always holds, so every run is a success
    ///      case; zero-output swaps are covered by Q04 / S03. Not covered: reserves near 2^256.
    function testFuzz_Z04_swapGrossVsNet(uint256 pre, bool preDir, uint256 g, bool zeroForOne) public {
        pre = bound(pre, 0, 1e22);
        g = bound(g, 1e3, 1e23);
        address t0 = poolB.token0();
        address t1 = poolB.token1();
        if (pre >= 1e3) _checkedSwap(poolB, preDir ? t0 : t1, pre);
        _checkedSwap(poolB, zeroForOne ? t0 : t1, g);
    }

    // ------------------------------------------------------------------
    // Z04 (remove) — fuzz gross vs net, both tokens taxed
    // ------------------------------------------------------------------

    /// @dev Range: optional prior swap as above; `shares ∈ [1, alice's LP]`. Expected per token
    ///      (ARCHITECTURE §6.3, M4-3): `amount_i = floor(shares·r_i/S)`; if either is 0 (both
    ///      reserves > 0 here) the call reverts `InsufficientLiquidityBurned` with full rollback;
    ///      otherwise reserves fall by `amount_i`, the Pool's balance falls by exactly `amount_i`
    ///      (A8), the recipient receives `amount_i − floor(amount_i·t_i/10000)`, which is the
    ///      return value and the MIN-NET basis (`min_i = net_i` passes), and surplus is unchanged.
    function testFuzz_Z04_removeGrossVsNet(uint256 pre, bool preDir, uint256 shares) public {
        pre = bound(pre, 0, 1e22);
        address t0 = poolB.token0();
        address t1 = poolB.token1();
        if (pre >= 1e3) _checkedSwap(poolB, preDir ? t0 : t1, pre);

        shares = bound(shares, 1, poolB.balanceOf(alice));
        _checkedRemove(poolB, shares);
    }

    struct RemoveExp {
        uint256 a0;
        uint256 a1;
        uint256 n0;
        uint256 n1;
        uint256 s0;
        uint256 s1;
    }

    /// @dev Executes a withdrawal by alice to carol and checks every equation of the Z04 (remove)
    ///      description above against independent expectations.
    function _checkedRemove(AMMPool pl, uint256 shares) internal {
        Snap memory b = _snap(pl);
        RemoveExp memory x_;
        x_.a0 = Math.mulDiv(shares, b.r0, b.supply);
        x_.a1 = Math.mulDiv(shares, b.r1, b.supply);

        if (x_.a0 == 0 || x_.a1 == 0) {
            vm.expectRevert(AMMPool.InsufficientLiquidityBurned.selector);
            vm.prank(alice);
            pl.removeLiquidity(shares, 0, 0, carol, block.timestamp);
            _assertSame(b, _snap(pl));
            return;
        }

        x_.n0 = _netOf(pl.token0(), x_.a0);
        x_.n1 = _netOf(pl.token1(), x_.a1);
        (x_.s0, x_.s1) = _surplus(pl);

        vm.expectEmit(true, true, false, true, address(pl));
        emit AMMPool.LiquidityRemoved(alice, carol, shares, x_.a0, x_.a1);
        vm.prank(alice);
        (uint256 got0, uint256 got1) = pl.removeLiquidity(shares, x_.n0, x_.n1, carol, block.timestamp);

        Snap memory e = _snap(pl);
        assertEq(got0, x_.n0, "return0 = recipient's measured increase");
        assertEq(got1, x_.n1, "return1 = recipient's measured increase");
        assertEq(e.carol0 - b.carol0, x_.n0, "recipient credit token0");
        assertEq(e.carol1 - b.carol1, x_.n1, "recipient credit token1");
        assertEq(b.pool0 - e.pool0, x_.a0, "A8 token0");
        assertEq(b.pool1 - e.pool1, x_.a1, "A8 token1");
        assertEq(e.r0, b.r0 - x_.a0, "reserve0 -= amount0");
        assertEq(e.r1, b.r1 - x_.a1, "reserve1 -= amount1");
        assertEq(e.supply, b.supply - shares, "LP burned");
        assertEq(e.aliceLP, b.aliceLP - shares, "caller's shares burned");
        assertEq(e.poolLP, 1000, "lock untouched");
        (uint256 t0s, uint256 t1s) = _surplus(pl);
        assertEq(t0s, x_.s0, "surplus0 unchanged");
        assertEq(t1s, x_.s1, "surplus1 unchanged");
    }

    /// @dev Z04 (remove) MIN-NET boundary per token with both tokens taxed: `net_i + 1` reverts
    ///      `InsufficientNetReceived` with full rollback, although `amount_i ≥ net_i + 1`.
    function test_Z04_removeMinNetBoundaryBothTaxed() public {
        uint256 shares = poolB.balanceOf(alice) / 3;
        (uint256 r0, uint256 r1) = poolB.getReserves();
        uint256 supply = poolB.totalSupply();
        uint256 n0 = _netOf(poolB.token0(), Math.mulDiv(shares, r0, supply));
        uint256 n1 = _netOf(poolB.token1(), Math.mulDiv(shares, r1, supply));

        Snap memory before = _snap(poolB);
        vm.expectRevert(AMMPool.InsufficientNetReceived.selector);
        vm.prank(alice);
        poolB.removeLiquidity(shares, n0 + 1, n1, carol, block.timestamp);
        _assertSame(before, _snap(poolB));

        vm.expectRevert(AMMPool.InsufficientNetReceived.selector);
        vm.prank(alice);
        poolB.removeLiquidity(shares, n0, n1 + 1, carol, block.timestamp);
        _assertSame(before, _snap(poolB));

        vm.prank(alice);
        (uint256 got0, uint256 got1) = poolB.removeLiquidity(shares, n0, n1, carol, block.timestamp);
        assertEq(got0, n0);
        assertEq(got1, n1);
    }
}
