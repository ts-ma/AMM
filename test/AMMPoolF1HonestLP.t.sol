// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {MockFeeERC20} from "./mocks/MockFeeERC20.sol";
import {addParams, addParamsOrdered} from "./utils/AddParams.sol";

/// @notice F1-T9: effect of an honest LP present before the inflation on the attacker's
///         per-token P&L (THREAT_MODEL T4). Full L13b scale, executed on-chain.
///
///         Baseline (aligned with L13b, A1–A5): alice deposits (1e6, 1e6) (S = 1e6, lock 1000);
///         two bonus donations of D = 1e25 per token (free bonus mock, A3); bob makes 5,000
///         deposits with caps (w, max), w from the L13b LCG (seed 2026), unbounded `maxExcess`;
///         alice removes all her LP; bob removes all his LP. Without the honest LP this is
///         `test_L13b_5000Victims_unboundedExcess_profitable` (aggregate +18,166,023,885,590,118,188,675).
///
///         Honest LP (carol), group H only. The earlier "1 % honest LP" model is not recorded in
///         the repository beyond one sentence in THREAT_MODEL T4, so the baseline is defined
///         here: carol deposits (10,101, 10,101) right after alice's initial deposit and before
///         the donations; at r = (1e6, 1e6), S = 1e6 the deposit mints 10,101 shares (net and
///         shares exactly proportional). Fraction at that point: 10,101 / 1,010,101 = 0.99999901 %
///         of the total LP supply INCLUDING the 1,000 locked LP (1.00099 % excluding it); after
///         the donations 10,101 / 1,010,103; after the 5,000 deposits 0.66590 %. carol exits last.
///         Same deposit sequence, exit order (alice, bob, then carol in H) and A3 cost basis in
///         both groups.
///
///         Measured per token (all values from an independent integer Python model; the test
///         asserts them exactly). "Wallet" = balance change; "A3" = wallet − D (the donated
///         amount counted as paid; the mock mints the bonus to the Pool for free, so alice's
///         wallet does not pay it).
///         | alice | token0 | token1 |
///         |---|---|---|
///         | A3, no honest LP | +9,083,016,484,294,218,244,145 | +9,083,007,401,295,899,944,530 |
///         | A3, with honest LP | −91,153,837,011,029,980,641,690 | −91,153,746,768,909,116,702,138 |
///         | change | −100,236,853,495,324,198,885,835 | −100,236,754,170,205,016,646,668 |
///         So in this scenario the honest LP turns alice's A3 P&L from positive to negative in
///         each token. Not claimed: the same for other LP sizes, deposit sequences or channels.
contract AMMPoolF1HonestLPTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant A = 1e6;
    uint256 internal constant D = 1e25;
    uint256 internal constant H = 10_101;
    uint256 internal constant FUND = 1e27;
    MockFeeERC20.Path internal constant PULL = MockFeeERC20.Path.TransferFrom;

    address internal alice = makeAddr("alice"); // attacker
    address internal bob = makeAddr("bob"); // later depositor (5,000 deposits)
    address internal carol = makeAddr("carol"); // honest LP
    address internal surplusRecipient = makeAddr("surplusRecipient");

    AMMPool internal p;
    MockFeeERC20 internal f0;
    MockFeeERC20 internal f1;

    function setUp() public {
        deployCodeTo("MockFeeERC20.sol:MockFeeERC20", abi.encode("T0", "T0", uint8(18)), address(0x73000));
        deployCodeTo(
            "MockFeeERC20.sol:MockFeeERC20", abi.encode("T1", "T1", uint8(18)), address(type(uint160).max - 0x8000)
        );
        f0 = MockFeeERC20(address(0x73000));
        f1 = MockFeeERC20(address(type(uint160).max - 0x8000));
        p = new AMMPool(address(f0), address(f1), surplusRecipient);
        address[3] memory users = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            f0.mint(users[i], FUND);
            f1.mint(users[i], FUND);
            vm.startPrank(users[i]);
            f0.approve(address(p), MAX);
            f1.approve(address(p), MAX);
            vm.stopPrank();
        }
    }

    function _lcg(uint256 x) internal pure returns (uint256) {
        return (6_364_136_223_846_793_005 * x + 1_442_695_040_888_963_407) % 2 ** 64;
    }

    struct Out {
        int256 aliceWallet0;
        int256 aliceWallet1;
        int256 bobLoss0;
        int256 bobLoss1;
        int256 carolPnl0;
        int256 carolPnl1;
        uint256 carolLP;
        uint256 supplyAfterCarol;
        uint256 supplyAfterDonations;
        uint256 supplyAfterVictims;
        uint256 end0;
        uint256 end1;
    }

    function _scenario(bool honest) internal returns (Out memory o) {
        vm.prank(alice);
        p.addLiquidity(addParams(A, A, 0, alice, block.timestamp));
        if (honest) {
            vm.prank(carol);
            (uint256 n0, uint256 n1, uint256 sh) = p.addLiquidity(addParams(H, H, 0, carol, block.timestamp));
            assertEq(n0, H);
            assertEq(n1, H);
            o.carolLP = sh;
            o.supplyAfterCarol = p.totalSupply();
        }
        f0.setBonus(PULL, D);
        vm.prank(alice);
        p.addLiquidity(addParamsOrdered(1, 1, 0, alice, block.timestamp, true));
        f0.setBonus(PULL, 0);
        f1.setBonus(PULL, D);
        (uint256 r0, uint256 r1) = p.getReserves();
        vm.prank(alice);
        p.addLiquidity(addParams((r0 + r1 - 1) / r1, MAX, 0, alice, block.timestamp));
        f1.setBonus(PULL, 0);
        o.supplyAfterDonations = p.totalSupply();

        uint256 x = 2026;
        for (uint256 i; i < 5000; ++i) {
            x = _lcg(x);
            vm.prank(bob);
            p.addLiquidity(addParams(1e21 + x % (1e22 - 1e21 + 1), MAX, 0, bob, block.timestamp));
        }
        o.supplyAfterVictims = p.totalSupply();

        _exit(alice);
        _exit(bob);
        if (honest) _exit(carol);
        o.aliceWallet0 = int256(f0.balanceOf(alice)) - int256(FUND);
        o.aliceWallet1 = int256(f1.balanceOf(alice)) - int256(FUND);
        o.bobLoss0 = int256(FUND) - int256(f0.balanceOf(bob));
        o.bobLoss1 = int256(FUND) - int256(f1.balanceOf(bob));
        o.carolPnl0 = int256(f0.balanceOf(carol)) - int256(FUND);
        o.carolPnl1 = int256(f1.balanceOf(carol)) - int256(FUND);
        (o.end0, o.end1) = p.getReserves();
    }

    function _exit(address who) internal {
        uint256 lp = p.balanceOf(who);
        vm.prank(who);
        p.removeLiquidity(lp, 0, 0, who, block.timestamp);
    }

    /// @dev Control group, aligned with L13b: alice's A3 P&L is positive in EACH token, and the
    ///      two tokens sum to the L13b aggregate.
    function test_F1T9_baseline_noHonestLP_perTokenSigns() public {
        Out memory o = _scenario(false);
        assertEq(o.aliceWallet0, 10_009_083_016_484_294_218_244_145, "alice wallet token0");
        assertEq(o.aliceWallet1, 10_009_083_007_401_295_899_944_530, "alice wallet token1");
        int256 a3_0 = o.aliceWallet0 - int256(D);
        int256 a3_1 = o.aliceWallet1 - int256(D);
        assertEq(a3_0, 9_083_016_484_294_218_244_145, "alice A3 token0");
        assertEq(a3_1, 9_083_007_401_295_899_944_530, "alice A3 token1");
        assertGt(a3_0, 0, "positive in token0");
        assertGt(a3_1, 0, "positive in token1");
        assertEq(a3_0 + a3_1, 18_166_023_885_590_118_188_675, "equals the L13b aggregate");
        assertEq(o.bobLoss0, 19_102_108_554_654_732_266_384, "bob loss token0");
        assertEq(o.bobLoss1, 19_102_089_452_584_381_750_317, "bob loss token1");
        assertEq(o.end0, 10_019_092_070_360_514_022_239, "left behind the lock token0");
        assertEq(o.end1, 10_019_082_051_288_481_805_787, "left behind the lock token1");
        assertEq(p.totalSupply(), 1000);
    }

    /// @dev Group H: the same scenario with carol's 1 % deposit before the donations.
    function test_F1T9_withHonestLP_perTokenPnl() public {
        Out memory o = _scenario(true);
        assertEq(o.carolLP, H, "honest LP shares");
        assertEq(o.supplyAfterCarol, 1_010_101, "supply after the honest deposit (incl. lock)");
        assertEq(o.supplyAfterDonations, 1_010_103);
        assertEq(o.carolLP * 1e8 / o.supplyAfterCarol, 999_999, "fraction 0.99999901 % (x 1e8, floor)");
        assertEq(
            o.carolLP * 1e8 / (o.supplyAfterCarol - 1000), 1_000_989, "fraction excl. lock 1.00099 % (x 1e8, floor)"
        );
        assertEq(o.carolLP * 1e7 / o.supplyAfterVictims, 66_590, "fraction after the deposits 0.66590 %");

        assertEq(o.aliceWallet0, 9_908_846_162_988_970_019_358_310, "alice wallet token0");
        assertEq(o.aliceWallet1, 9_908_846_253_231_090_883_297_862, "alice wallet token1");
        int256 a3_0 = o.aliceWallet0 - int256(D);
        int256 a3_1 = o.aliceWallet1 - int256(D);
        assertEq(a3_0, -91_153_837_011_029_980_641_690, "alice A3 token0");
        assertEq(a3_1, -91_153_746_768_909_116_702_138, "alice A3 token1");
        assertLt(a3_0, 0, "negative in token0");
        assertLt(a3_1, 0, "negative in token1");
        // change against the control group (literals of the baseline test)
        assertEq(a3_0 - 9_083_016_484_294_218_244_145, -100_236_853_495_324_198_885_835, "change token0");
        assertEq(a3_1 - 9_083_007_401_295_899_944_530, -100_236_754_170_205_016_646_668, "change token1");

        assertEq(o.carolPnl0, 100_189_344_057_522_994_307_908, "honest LP P&L token0");
        assertEq(o.carolPnl1, 100_189_244_870_267_776_252_902, "honest LP P&L token1");
        assertEq(o.bobLoss0, 18_954_262_026_942_770_553_458, "bob loss token0");
        assertEq(o.bobLoss1, 18_954_243_262_260_330_302_473, "bob loss token1");
        assertEq(o.end0, 9_918_754_980_449_756_887_240);
        assertEq(o.end1, 9_918_745_160_901_670_751_709);
        assertEq(p.totalSupply(), 1000);
    }
}
