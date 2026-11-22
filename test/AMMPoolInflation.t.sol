// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {IAMMPool} from "../src/interfaces/IAMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeERC20} from "./mocks/MockFeeERC20.sol";
import {addParams, addParamsOrdered} from "./utils/AddParams.sol";

/// @notice M8 commit 5d (tests only; M8 remains WIP): L13b, redefined at the student's request.
///         The question is measured, not assumed: what is the attacker's REAL profit and loss
///         (tokens received minus tokens paid, both tokens valued 1:1) in each scenario?
///
///         Explicit assumptions:
///         - A1 Two 18-decimal tokens worth 1:1; no external price movement; no arbitrage.
///         - A2 Attacker = alice: initial deposit (A, A) with A = 1e6, so S = 1e6 and the lock is
///           1000 LP (0.1%). The attacker exits last-but-one by removing all its LP.
///         - A3 Donation channel: "value enters both reserves without shares". On-chain M8 offers
///           X1 excess (fee-on-transfer or bonus tokens) and swap fees; direct transfers do not
///           enter reserves and `sync` only lowers them. In the multi-victim tests the channel is
///           a fee mock's bonus, switched on only for the attacker's two donation deposits: it is
///           free, so it is the attacker-FAVOURABLE bound; the donated D per token is counted as
///           paid. The multi-deposit test uses the bonus mock. The costs and resulting P&L of
///           other channels depend on the channel and its assumptions.
///         - A4 Victims = bob: N deposits from one address, redeemed together at the end; request
///           (w, MAX), token0 first, w from a fixed LCG in [1e21, 1e21 + 2^64 − 1] (the LCG
///           output is below 2^64, so the modulus never reduces it); for N = 5,000,
///           Σw ≈ 5.046e24 is the total token0 request; maxExcess per token =
///           floor(w · tolBps / 10000) or unbounded.
///         - A5 Gas is not in the P&L; the attacker's own gas is measured and reported separately.
///         The exact P&L values are cross-checked against an independent integer model of the
///         same steps (Python; see the commit report). The tests state the measured sign; they
///         do not assume that any attack is unprofitable.
contract AMMPoolInflationTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant A = 1e6;
    uint256 internal constant D = 1e25;
    MockFeeERC20.Path internal constant PULL = MockFeeERC20.Path.TransferFrom;

    address internal alice = makeAddr("alice"); // attacker
    address internal bob = makeAddr("bob"); // victims
    address internal surplusRecipient = makeAddr("surplusRecipient");

    AMMPool internal p;
    MockFeeERC20 internal f0;
    MockFeeERC20 internal f1;
    uint160 internal nextLow = 0x70000;
    uint160 internal nextHigh = type(uint160).max - 0x5000;

    function _deploy(bool low) internal returns (MockFeeERC20 t) {
        address at = low ? address(nextLow++) : address(nextHigh--);
        require(at.code.length == 0, "address reused");
        deployCodeTo("MockFeeERC20.sol:MockFeeERC20", abi.encode("T", "T", uint8(18)), at);
        t = MockFeeERC20(at);
    }

    function _fresh() internal {
        f0 = _deploy(true);
        f1 = _deploy(false);
        p = new AMMPool(address(f0), address(f1), surplusRecipient);
        address[2] memory users = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            f0.mint(users[i], 1e27);
            f1.mint(users[i], 1e27);
            vm.startPrank(users[i]);
            f0.approve(address(p), MAX);
            f1.approve(address(p), MAX);
            vm.stopPrank();
        }
    }

    function _bal(address who) internal view returns (uint256) {
        return f0.balanceOf(who) + f1.balanceOf(who);
    }

    struct Result {
        int256 attackerPnl;
        uint256 accepted;
        uint256 rejected;
        int256 victimsLoss; // paid minus received after exiting
        uint256 attackerGas;
    }

    function _lcg(uint256 x) internal pure returns (uint256) {
        return (6_364_136_223_846_793_005 * x + 1_442_695_040_888_963_407) % 2 ** 64;
    }

    /// @dev Runs steps 1–4 of the documented scenario on a fresh Pool.
    function _scenario(uint256 donation, uint256 n, uint256 tolBps) internal returns (Result memory r) {
        _fresh();
        uint256 a0 = _bal(alice);
        uint256 g = gasleft();
        vm.prank(alice);
        p.addLiquidity(addParams(A, A, 0, alice, block.timestamp));
        r.attackerGas += g - gasleft();
        uint256 paidExtra; // donated value, counted as paid (A3)
        if (donation > 0) {
            f0.setBonus(PULL, donation);
            g = gasleft();
            vm.prank(alice);
            p.addLiquidity(addParamsOrdered(1, 1, 0, alice, block.timestamp, true));
            r.attackerGas += g - gasleft();
            f0.setBonus(PULL, 0);
            f1.setBonus(PULL, donation);
            (uint256 r0, uint256 r1) = p.getReserves();
            uint256 c0 = (r0 + r1 - 1) / r1;
            g = gasleft();
            vm.prank(alice);
            p.addLiquidity(addParams(c0, MAX, 0, alice, block.timestamp));
            r.attackerGas += g - gasleft();
            f1.setBonus(PULL, 0);
            paidExtra = 2 * donation;
        }
        uint256 b0 = _bal(bob);
        uint256 x = 2026;
        for (uint256 i; i < n; ++i) {
            x = _lcg(x);
            uint256 w = 1e21 + x % (1e22 - 1e21 + 1);
            IAMMPool.AddLiquidityParams memory prm = addParams(w, MAX, 0, bob, block.timestamp);
            if (tolBps != MAX) {
                uint256 me = w * tolBps / 10_000;
                (prm.maxExcess0, prm.maxExcess1) = (me, me);
            }
            vm.prank(bob);
            (bool ok,) = address(p).call(abi.encodeCall(AMMPool.addLiquidity, (prm)));
            if (ok) ++r.accepted;
            else ++r.rejected;
        }
        uint256 attackerLP = p.balanceOf(alice);
        g = gasleft();
        vm.prank(alice);
        p.removeLiquidity(attackerLP, 0, 0, alice, block.timestamp);
        r.attackerGas += g - gasleft();
        r.attackerPnl = int256(_bal(alice)) - int256(a0) - int256(paidExtra);
        uint256 victimLP = p.balanceOf(bob);
        if (victimLP > 0) {
            vm.prank(bob);
            p.removeLiquidity(victimLP, 0, 0, bob, block.timestamp);
        }
        r.victimsLoss = int256(b0) - int256(_bal(bob));
    }

    // ------------------------------------------------------------------
    // Baseline: no donation — the lock costs exactly 1000 of each token
    // ------------------------------------------------------------------

    function test_L13b_baseline_noDonation_lockCostOnly() public {
        Result memory r = _scenario(0, 100, MAX);
        assertEq(r.attackerPnl, -2000, "baseline: the attacker loses exactly the 1000 + 1000 lock");
        assertEq(r.victimsLoss, 0, "victims lose nothing at per-share value 1");
        emit log_named_uint("attacker gas (4 txs)", r.attackerGas);
    }

    // ------------------------------------------------------------------
    // Single victim and few victims: donating loses money (measured)
    // ------------------------------------------------------------------

    function test_L13b_singleVictim_donationLoses() public {
        Result memory r = _scenario(D, 1, MAX);
        assertEq(r.attackerPnl, -19_998_152_847_762_923_531_356, "matches the independent model");
        assertLt(r.attackerPnl, -2000, "worse than not attacking");
        assertGt(r.victimsLoss, 0);
    }

    function test_L13b_1000Victims_unbounded_stillLoses() public {
        Result memory r = _scenario(D, 1000, MAX);
        assertEq(r.attackerPnl, -11_105_279_878_487_883_917_245, "matches the independent model");
        assertLt(r.attackerPnl, 0);
    }

    // ------------------------------------------------------------------
    // The 5,000-deposit counterexample: PROFITABLE when victims accept unbounded excess
    // ------------------------------------------------------------------

    /// @dev Finding (contradicts the earlier THREAT_MODEL T4 sentence "donating never increases
    ///      profit", which holds only for one victim): with 5,000 deposits from one address that
    ///      accept any unmatched amount, the attacker's P&L is POSITIVE. Each deposit loses up to
    ///      one share's worth to rounding; the attacker's INITIAL share of the pool is ~99.9%
    ///      (it falls as the deposits mint shares), while the donation costs it only the lock's
    ///      0.1% share. The depositing address loses more than the attacker gains.
    function test_L13b_5000Victims_unboundedExcess_profitable() public {
        Result memory r = _scenario(D, 5000, MAX);
        assertEq(r.attackerPnl, 18_166_023_885_590_118_188_675, "matches the independent model");
        assertGt(r.attackerPnl, 0, "MEASURED: the attack is profitable under A1-A5");
        assertEq(r.accepted, 5000);
        assertGt(r.victimsLoss, r.attackerPnl, "victims lose more than the attacker gains");
        emit log_named_int("attacker P&L (wei, 1:1)", r.attackerPnl);
        emit log_named_int("victims' total loss (wei)", r.victimsLoss);
        emit log_named_uint("attacker gas (4 txs)", r.attackerGas);
    }

    /// @dev Victims bound their unmatched contribution at 10 bps of the request: most deposits
    ///      revert (griefing / denial of service, no theft) and the attack loses money.
    function test_L13b_5000Victims_tolerance10bps_unprofitable_butGriefs() public {
        Result memory r = _scenario(D, 5000, 10);
        assertEq(r.attackerPnl, -19_453_511_173_263_290_587_278, "matches the independent model");
        assertLt(r.attackerPnl, 0);
        assertEq(r.accepted, 558);
        assertEq(r.rejected, 4442, "rejected deposits: the victims keep their tokens, pay only gas");
    }

    // ------------------------------------------------------------------
    // minShares does not stop the rounding loss; a value-based tolerance does
    // ------------------------------------------------------------------

    /// @dev After the donation one victim sets minShares to the exact quote (what a UI quoting
    ///      floor(min(n_i·S/r_i)) would compute): the deposit passes minShares and still loses
    ///      value, because the floor is already in the quote. Only a value-based bound (here
    ///      maxExcess) rejects it.
    function test_L13b_minSharesEqualToQuote_doesNotPreventLoss() public {
        _fresh();
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

        (r0, r1) = p.getReserves();
        uint256 S = p.totalSupply();
        uint256 w = 3_333_333_333_333_333_333_333;
        uint256 t1 = w * r1 / r0;
        uint256 s0 = w * S / r0;
        uint256 s1 = t1 * S / r1;
        uint256 quote = s0 < s1 ? s0 : s1;
        uint256 before = _bal(bob);
        uint256 id = vm.snapshotState();
        vm.prank(bob);
        (,, uint256 got) = p.addLiquidity(addParams(w, MAX, quote, bob, block.timestamp)); // minShares = quote
        assertEq(got, quote, "minShares satisfied");
        vm.prank(bob);
        p.removeLiquidity(got, 0, 0, bob, block.timestamp);
        assertGt(before - _bal(bob), 1e18, "victim still lost more than one whole token");
        vm.revertToState(id);
        IAMMPool.AddLiquidityParams memory prm = addParams(w, MAX, quote, bob, block.timestamp);
        (prm.maxExcess0, prm.maxExcess1) = (w / 10_000, w / 10_000);
        vm.prank(bob);
        vm.expectRevert(AMMPool.ExcessContributionTooHigh.selector);
        p.addLiquidity(prm);
    }

    // ------------------------------------------------------------------
    // Donation + sync: cannot inflate (sync only lowers reserves)
    // ------------------------------------------------------------------

    function test_L13b_directDonationPlusSync_doesNotInflate() public {
        _fresh();
        vm.prank(alice);
        p.addLiquidity(addParams(A, A, 0, alice, block.timestamp));
        uint256 id = vm.snapshotState();
        vm.prank(bob);
        (,, uint256 control) = p.addLiquidity(addParams(1e21, MAX, 0, bob, block.timestamp));
        vm.revertToState(id);

        vm.startPrank(alice);
        f0.transfer(address(p), D);
        f1.transfer(address(p), D);
        vm.stopPrank();
        p.sync();
        (uint256 r0, uint256 r1) = p.getReserves();
        assertEq(r0, A, "sync never raises a reserve");
        assertEq(r1, A);
        vm.prank(bob);
        (,, uint256 s) = p.addLiquidity(addParams(1e21, MAX, 0, bob, block.timestamp));
        assertEq(s, control, "victim's shares unaffected by the direct donation");
        p.skim();
        assertEq(f0.balanceOf(surplusRecipient), D, "the donation leaves through skim");
        assertEq(f1.balanceOf(surplusRecipient), D);
    }

    // ------------------------------------------------------------------
    // Own maxExcess with a REAL channel: fee-on-transfer second token (overhead included)
    // ------------------------------------------------------------------

    /// @dev Token1 has a 10% inclusive tax for everyone. The attacker donates token0 through X1:
    ///      token0 first, token1 second, unbounded maxExcess, so ~10% of its token0 stays
    ///      unmatched in the reserve; it also burns 10% of its token1 to the tax. One victim then
    ///      deposits (token1 first, the order without excess). Measured: the donation makes the
    ///      attacker's P&L worse than not donating.
    function test_L13b_ownMaxExcess_realTaxChannel_singleVictim() public {
        int256 base = _realChannel(false);
        int256 attack = _realChannel(true);
        assertLt(attack, base, "MEASURED: donating via own maxExcess loses money with one victim");
        emit log_named_int("baseline P&L", base);
        emit log_named_int("attack P&L", attack);
    }

    function _realChannel(bool donate) internal returns (int256) {
        _fresh();
        vm.prank(alice);
        p.addLiquidity(addParams(A, A, 0, alice, block.timestamp));
        f1.setTax(PULL, 1000);
        uint256 a0 = _bal(alice);
        if (donate) {
            vm.prank(alice);
            p.addLiquidity(addParams(1e24, MAX, 0, alice, block.timestamp)); // token0 first
        }
        vm.prank(bob);
        p.addLiquidity(addParamsOrdered(MAX, 3e21, 0, bob, block.timestamp, true)); // token1 first
        uint256 lp = p.balanceOf(alice);
        vm.prank(alice);
        p.removeLiquidity(lp, 0, 0, alice, block.timestamp);
        return int256(_bal(alice)) - int256(a0);
    }
}
