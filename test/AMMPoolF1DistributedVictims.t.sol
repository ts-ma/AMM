// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {IAMMPool} from "../src/interfaces/IAMMPool.sol";
import {MockFeeERC20} from "./mocks/MockFeeERC20.sol";
import {MulDiv512} from "./utils/MulDiv512.sol";
import {addParams, addParamsOrdered} from "./utils/AddParams.sol";

/// @notice F1-T8: the same 50 deposits held and redeemed by ONE address (merged redemption) vs
///         by 50 addresses (each redeems its own shares). How much do the users actually
///         receive per token in each group? (THREAT_MODEL T4; L13b scenario.)
///
///         Fixed scenario, identical for both groups up to the redemption:
///         - L13b assumptions A1–A3: alice deposits (1e6, 1e6), then two bonus donations of
///           D = 1e25 per token (unsupported bonus mock; the bonus is free and is listed
///           separately in alice's P&L);
///         - 50 deposits, caps (w_k, max), token0 first, w_k from the L13b LCG (seed 2026),
///           unbounded `maxDebit` / `maxExcess` (absolute semantics, not used as a bound here);
///         - group M: all 50 by bob; group I: deposit k by its own address v_k;
///         - alice then removes all her LP (same point in both groups);
///         - group M: bob redeems the sum of the 50 share amounts in one call; group I: v_0 ... v_49
///           redeem in deposit order, each at the reserves and supply left by the previous one.
///
///         Expected values: an independent integer Python model of the same steps (literal
///         constants below) and, inside the test, a step-by-step model with MulDiv512 that never
///         reads the Pool's reserves after the starting point.
///         Measured outcome (per token, smallest units): both groups pay the same; group M
///         receives 3 token0 and 6 token1 more than group I in total; no redemption reverts.
contract AMMPoolF1DistributedVictimsTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant A = 1e6;
    uint256 internal constant D = 1e25;
    uint256 internal constant N = 50;
    MockFeeERC20.Path internal constant PULL = MockFeeERC20.Path.TransferFrom;

    // State after the donations (model; also F1-T7).
    uint256 internal constant R0_DON = 10_000_009_999_990_000_010_999_993;
    uint256 internal constant R1_DON = 10_000_000_000_000_000_001_000_002;
    uint256 internal constant S_DON = 1_000_002;
    // After the 50 deposits.
    uint256 internal constant R0_DEP = 10_050_421_394_292_409_429_842_462;
    uint256 internal constant R1_DEP = 10_050_411_343_891_115_940_019_987;
    uint256 internal constant S_DEP = 1_005_020;
    uint256 internal constant USER_SHARES = 5018;
    uint256 internal constant PAID0 = 50_411_394_302_409_418_842_469;
    uint256 internal constant PAID1 = 50_411_343_891_115_939_019_985;
    // alice's exit
    uint256 internal constant ALICE_LP = 999_002;
    uint256 internal constant ALICE_OUT0 = 9_990_240_068_596_550_919_615_011;
    uint256 internal constant ALICE_OUT1 = 9_990_230_078_376_462_763_240_380;
    uint256 internal constant ALICE_DEBIT0 = 9_999_990_000_010_999_993;
    uint256 internal constant ALICE_DEBIT1 = 1_000_002;
    // Redemptions
    uint256 internal constant MERGED0 = 50_181_105_407_414_091_778_223;
    uint256 internal constant MERGED1 = 50_181_055_226_409_046_374_221;
    uint256 internal constant INDIV0 = 50_181_105_407_414_091_778_220;
    uint256 internal constant INDIV1 = 50_181_055_226_409_046_374_215;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal surplusRecipient = makeAddr("surplusRecipient");

    AMMPool internal p;
    MockFeeERC20 internal f0;
    MockFeeERC20 internal f1;
    address[N] internal v;

    // in-test model of the Pool (reserves, supply)
    uint256 internal m0;
    uint256 internal m1;
    uint256 internal mS;

    function setUp() public {
        deployCodeTo("MockFeeERC20.sol:MockFeeERC20", abi.encode("T0", "T0", uint8(18)), address(0x72000));
        deployCodeTo(
            "MockFeeERC20.sol:MockFeeERC20", abi.encode("T1", "T1", uint8(18)), address(type(uint160).max - 0x7000)
        );
        f0 = MockFeeERC20(address(0x72000));
        f1 = MockFeeERC20(address(type(uint160).max - 0x7000));
        p = new AMMPool(address(f0), address(f1), surplusRecipient);
        _fund(alice, 1e27);
        _fund(bob, 1e27);
        for (uint256 k; k < N; ++k) {
            v[k] = makeAddr(string(abi.encodePacked("victim", vm.toString(k))));
            _fund(v[k], 1e23);
        }
        // L13b steps 1-2: initial deposit and the two bonus donations.
        vm.prank(alice);
        p.addLiquidity(addParams(A, A, 0, alice, block.timestamp));
        f0.setBonus(PULL, D);
        vm.prank(alice);
        p.addLiquidity(addParamsOrdered(1, 1, 0, alice, block.timestamp, true));
        f0.setBonus(PULL, 0);
        f1.setBonus(PULL, D);
        (uint256 r0, uint256 r1) = p.getReserves();
        vm.prank(alice);
        p.addLiquidity(addParams((r0 + r1 - 1) / r1, MAX, 0, alice, block.timestamp));
        f1.setBonus(PULL, 0);
    }

    function _fund(address who, uint256 amount) internal {
        f0.mint(who, amount);
        f1.mint(who, amount);
        vm.startPrank(who);
        f0.approve(address(p), MAX);
        f1.approve(address(p), MAX);
        vm.stopPrank();
    }

    function _lcg(uint256 x) internal pure returns (uint256) {
        return (6_364_136_223_846_793_005 * x + 1_442_695_040_888_963_407) % 2 ** 64;
    }

    // ------------------------------------------------------------------
    // Group run
    // ------------------------------------------------------------------

    struct Run {
        uint256[N] paid0;
        uint256[N] paid1;
        uint256[N] shares;
        uint256[N] recv0;
        uint256[N] recv1;
        uint256 totalRecv0;
        uint256 totalRecv1;
        uint256 aliceOut0;
        uint256 aliceOut1;
        uint256 aliceBal0;
        uint256 aliceBal1;
        uint256 endR0;
        uint256 endR1;
        uint256 endS;
    }

    /// @param merged true: all deposits by bob, one merged redemption; false: v_k each.
    function _run(bool merged) internal returns (Run memory run) {
        (m0, m1) = p.getReserves();
        mS = p.totalSupply();
        assertEq(m0, R0_DON, "donated reserve0");
        assertEq(m1, R1_DON, "donated reserve1");
        assertEq(mS, S_DON, "donated S");

        _deposits(run, merged);
        (uint256 r0, uint256 r1) = p.getReserves();
        assertEq(r0, R0_DEP, "reserve0 after deposits");
        assertEq(r1, R1_DEP, "reserve1 after deposits");
        assertEq(p.totalSupply(), S_DEP, "S after deposits");

        // alice exits at the same point in both groups
        (run.aliceOut0, run.aliceOut1) = _redeem(alice, ALICE_LP);
        run.aliceBal0 = f0.balanceOf(alice);
        run.aliceBal1 = f1.balanceOf(alice);

        if (merged) {
            (run.totalRecv0, run.totalRecv1) = _redeem(bob, USER_SHARES);
        } else {
            for (uint256 k; k < N; ++k) {
                (run.recv0[k], run.recv1[k]) = _redeem(v[k], run.shares[k]);
                run.totalRecv0 += run.recv0[k];
                run.totalRecv1 += run.recv1[k];
            }
        }
        (run.endR0, run.endR1) = p.getReserves();
        run.endS = p.totalSupply();
    }

    function _deposits(Run memory run, bool merged) internal {
        uint256 x = 2026;
        for (uint256 k; k < N; ++k) {
            x = _lcg(x);
            _depositOne(run, k, 1e21 + x % (1e22 - 1e21 + 1), merged ? bob : v[k]);
        }
        uint256 sumShares;
        uint256 sum0;
        uint256 sum1;
        for (uint256 k; k < N; ++k) {
            sumShares += run.shares[k];
            sum0 += run.paid0[k];
            sum1 += run.paid1[k];
        }
        assertEq(sumShares, USER_SHARES, "user shares (Python model)");
        assertEq(sum0, PAID0, "users paid token0 (Python model)");
        assertEq(sum1, PAID1, "users paid token1 (Python model)");
        assertEq(merged ? p.balanceOf(bob) : _sumVictimLP(), USER_SHARES, "users hold all their shares");
    }

    /// @dev One deposit, caps (w, max), token0 first; predicted from the in-test model:
    ///      the token0 cap binds (floor(w·r1/r0) < max), Tier 0 transfers.
    function _depositOne(Run memory run, uint256 k, uint256 w, address who) internal {
        (, uint256 t1) = MulDiv512.floorMulDiv(w, m1, m0);
        (, uint256 s0) = MulDiv512.floorMulDiv(w, mS, m0);
        (, uint256 s1) = MulDiv512.floorMulDiv(t1, mS, m1);
        uint256 sigma = s0 < s1 ? s0 : s1;
        uint256 b0 = f0.balanceOf(who);
        uint256 b1 = f1.balanceOf(who);
        vm.prank(who);
        (,, uint256 sh) = p.addLiquidity(addParams(w, MAX, 0, who, block.timestamp));
        run.paid0[k] = b0 - f0.balanceOf(who);
        run.paid1[k] = b1 - f1.balanceOf(who);
        assertEq(run.paid0[k], w, "debit0 = w");
        assertEq(run.paid1[k], t1, "debit1 = model target1");
        assertEq(sh, sigma, "sigma = model");
        run.shares[k] = sh;
        m0 += w;
        m1 += t1;
        mS += sigma;
    }

    function _sumVictimLP() internal view returns (uint256 s) {
        for (uint256 k; k < N; ++k) {
            s += p.balanceOf(v[k]);
        }
    }

    /// @dev Redeem `shares` of `who` to `who`; predicted from the in-test model state.
    ///      A predicted zero output would be asserted as a revert with the shares kept (none
    ///      occurs in this scenario; the Python model reports no failure).
    function _redeem(address who, uint256 shares) internal returns (uint256 got0, uint256 got1) {
        (, uint256 e0) = MulDiv512.floorMulDiv(shares, m0, mS);
        (, uint256 e1) = MulDiv512.floorMulDiv(shares, m1, mS);
        if (e0 == 0 || e1 == 0) {
            vm.prank(who);
            (bool ok, bytes memory ret) =
                address(p).call(abi.encodeCall(AMMPool.removeLiquidity, (shares, 0, 0, who, block.timestamp)));
            assertFalse(ok);
            assertEq(ret, abi.encodePacked(AMMPool.InsufficientLiquidityBurned.selector));
            assertEq(p.balanceOf(who), shares, "shares kept");
            return (0, 0);
        }
        uint256 b0 = f0.balanceOf(who);
        uint256 b1 = f1.balanceOf(who);
        vm.prank(who);
        p.removeLiquidity(shares, 0, 0, who, block.timestamp);
        got0 = f0.balanceOf(who) - b0;
        got1 = f1.balanceOf(who) - b1;
        assertEq(got0, e0, "redeem token0 = model");
        assertEq(got1, e1, "redeem token1 = model");
        assertEq(p.balanceOf(who), 0, "all shares redeemed");
        m0 -= e0;
        m1 -= e1;
        mS -= shares;
    }

    // ------------------------------------------------------------------
    // The comparison
    // ------------------------------------------------------------------

    function test_F1T8_mergedVsIndividualRedemption() public {
        uint256 snap = vm.snapshotState();
        Run memory mg = _run(true);
        vm.revertToState(snap);
        Run memory iv = _run(false);

        // Deposit phase identical (amounts, order, parameters, shares).
        for (uint256 k; k < N; ++k) {
            assertEq(mg.paid0[k], iv.paid0[k], "same debit0");
            assertEq(mg.paid1[k], iv.paid1[k], "same debit1");
            assertEq(mg.shares[k], iv.shares[k], "same shares");
        }

        // alice's exit is the same in both groups.
        assertEq(mg.aliceOut0, ALICE_OUT0, "alice out0");
        assertEq(mg.aliceOut1, ALICE_OUT1, "alice out1");
        assertEq(iv.aliceOut0, ALICE_OUT0);
        assertEq(iv.aliceOut1, ALICE_OUT1);

        // Users' total receipts (Python model) and the measured difference.
        assertEq(mg.totalRecv0, MERGED0, "merged receipt token0");
        assertEq(mg.totalRecv1, MERGED1, "merged receipt token1");
        assertEq(iv.totalRecv0, INDIV0, "individual receipts token0");
        assertEq(iv.totalRecv1, INDIV1, "individual receipts token1");
        assertEq(mg.totalRecv0 - iv.totalRecv0, 3, "merged - individual token0");
        assertEq(mg.totalRecv1 - iv.totalRecv1, 6, "merged - individual token1");

        // The difference stays in the Pool (backing the 1,000 locked LP).
        assertEq(mg.endS, 1000);
        assertEq(iv.endS, 1000);
        assertEq(iv.endR0 - mg.endR0, 3, "token0 left in the Pool");
        assertEq(iv.endR1 - mg.endR1, 6, "token1 left in the Pool");
        assertEq(mg.endR0, 10_000_220_288_444_418_449_228);
        assertEq(mg.endR1, 10_000_210_288_244_130_405_386);

        // Per-user losses in group I (paid − received, per token).
        (uint256 min0, uint256 i0, uint256 max0, uint256 j0) = _minMax(iv.paid0, iv.recv0);
        (uint256 min1, uint256 i1, uint256 max1, uint256 j1) = _minMax(iv.paid1, iv.recv1);
        assertEq(min0, 43_974_487_781_985_612, "min loss token0");
        assertEq(i0, 30);
        assertEq(max0, 9_331_871_098_641_087_073, "max loss token0");
        assertEq(j0, 49);
        assertEq(min1, 43_974_443_807_585_779, "min loss token1");
        assertEq(i1, 30);
        assertEq(max1, 9_331_861_766_788_652_136, "max loss token1");
        assertEq(j1, 49);

        // Users' total loss per token and alice's P&L.
        assertEq(PAID0 - MERGED0, 230_288_894_995_327_064_246);
        assertEq(PAID1 - MERGED1, 230_288_664_706_892_645_764);
        assertEq(PAID0 - INDIV0, 230_288_894_995_327_064_249);
        assertEq(PAID1 - INDIV1, 230_288_664_706_892_645_770);
        // wallet P&L (the bonus D was minted for free by the mock) and with D counted as paid (A3)
        // alice was funded 1e27 per token; her wallet change = received − debited (measured)
        assertEq(mg.aliceBal0, 1e27 - ALICE_DEBIT0 + ALICE_OUT0, "alice wallet token0");
        assertEq(mg.aliceBal1, 1e27 - ALICE_DEBIT1 + ALICE_OUT1, "alice wallet token1");
        assertEq(iv.aliceBal0, mg.aliceBal0);
        assertEq(iv.aliceBal1, mg.aliceBal1);
        assertEq(int256(ALICE_OUT0) - int256(ALICE_DEBIT0) - int256(D), -9_769_931_393_449_091_384_982);
        assertEq(int256(ALICE_OUT1) - int256(ALICE_DEBIT1) - int256(D), -9_769_921_623_537_237_759_622);
    }

    function _minMax(uint256[N] memory paid, uint256[N] memory recv)
        internal
        pure
        returns (uint256 mn, uint256 imn, uint256 mx, uint256 imx)
    {
        mn = type(uint256).max;
        for (uint256 k; k < N; ++k) {
            uint256 loss = paid[k] - recv[k];
            if (loss < mn) (mn, imn) = (loss, k);
            if (loss > mx) (mx, imx) = (loss, k);
        }
    }
}
