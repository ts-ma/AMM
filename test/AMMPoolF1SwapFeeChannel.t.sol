// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {addParams} from "./utils/AddParams.sol";

/// @notice F1-T3: reduced on-chain swap-fee channel with supported exact-delivery tokens
///         (Tier 0 `MockERC20`; THREAT_MODEL T4). Swap fees raise the reserves without minting
///         shares, so per-share value grows; this executes that channel at a small scale.
///
///         Setup: alice makes the initial deposit (1e6, 1e6) (S = 1e6, 1,000 locked) and is the
///         only other LP and the only trader. Round trip k (k = 0, 1, ...): the input token is
///         token0 for even k and token1 for odd k; swap x = c · (current reserve of the input
///         token), then swap the whole output back. One round trip = 2 swaps. Finally alice
///         removes all her LP (S − 1000).
///
///         Checked after every swap against an in-test model that uses only the §6.4 formula
///         out = floor(a·9970·rOut / (rIn·10000 + a·9970)): the swap output, both reserves, the
///         Pool's balances (= reserves, no surplus) and the LP supply (unchanged). At the end:
///         reserves before the exit, alice's exit amounts, what stays in the Pool and alice's
///         wallet change per token, all equal to an independent integer Python model; and
///         alice's wallet change equals exactly minus what stays in the Pool, per token.
///
///         Expected values (Python model):
///         | c | round trips | swaps | reserves before exit | Pool after exit | alice wallet change |
///         |---|---|---|---|---|---|
///         | 1 | 200 | 400 | (1,350,041, 1,350,040) | (1,351, 1,351) | (−1,351, −1,351) |
///         | 1 | 2,000 | 4,000 | (20,095,042, 20,095,155) | (20,096, 20,096) | (−20,096, −20,096) |
///         | 10 | 200 | 400 | (1,727,288, 1,727,357) | (1,728, 1,728) | (−1,728, −1,728) |
///         | 10 | 2,000 | 4,000 | (235,642,086, 235,646,772) | (235,643, 235,647) | (−235,643, −235,647) |
///
///         Gas: `gasleft()` difference around each external `swapExactInput` call inside the
///         test (execution gas of the call; no 21,000 intrinsic or calldata cost), logged as total,
///         mean, min and max per swap. Compiler configuration per foundry.toml (solc 0.8.38,
///         optimizer 200 runs, EVM osaka, via_ir false; verify with `forge config`).
///         Not shown here: the full L13b-scale P5 state (model only, F1-T4 deferred).
contract AMMPoolF1SwapFeeChannelTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant A = 1e6;
    uint256 internal constant FUND = 1e30;

    address internal alice = makeAddr("alice");
    address internal surplusRecipient = makeAddr("surplusRecipient");

    MockERC20 internal t0;
    MockERC20 internal t1;
    AMMPool internal p;

    // in-test model
    uint256[2] internal m;

    // gas
    uint256 internal gasTotal;
    uint256 internal gasMin;
    uint256 internal gasMax;

    function setUp() public {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        p = new AMMPool(address(t0), address(t1), surplusRecipient);
        t0.mint(alice, FUND);
        t1.mint(alice, FUND);
        vm.startPrank(alice);
        t0.approve(address(p), MAX);
        t1.approve(address(p), MAX);
        p.addLiquidity(addParams(A, A, 0, alice, block.timestamp));
        vm.stopPrank();
        m = [A, A];
    }

    function _out(uint256 a, uint256 rin, uint256 rout) internal pure returns (uint256) {
        return a * 9970 * rout / (rin * 10_000 + a * 9970);
    }

    /// @dev One swap of `amount` of token `i` in, checked against the model.
    function _swap(uint256 i, uint256 amount) internal returns (uint256 got) {
        uint256 j = 1 - i;
        uint256 expected = _out(amount, m[i], m[j]);
        address tin = i == 0 ? address(t0) : address(t1);
        vm.prank(alice);
        uint256 g = gasleft();
        got = p.swapExactInput(tin, amount, 0, alice, block.timestamp);
        g -= gasleft();
        gasTotal += g;
        if (g < gasMin) gasMin = g;
        if (g > gasMax) gasMax = g;
        assertEq(got, expected, "swap out = model");
        m[i] += amount;
        m[j] -= expected;
        (uint256 r0, uint256 r1) = p.getReserves();
        assertEq(r0, m[0], "reserve0 = model");
        assertEq(r1, m[1], "reserve1 = model");
        assertEq(t0.balanceOf(address(p)), r0, "no surplus token0");
        assertEq(t1.balanceOf(address(p)), r1, "no surplus token1");
        assertEq(p.totalSupply(), A, "LP supply unchanged by swaps");
    }

    struct Expect {
        uint256 pre0;
        uint256 pre1;
        uint256 left0;
        uint256 left1;
    }

    function _run(uint256 c, uint256 trips, Expect memory e) internal {
        gasMin = type(uint256).max;
        for (uint256 k; k < trips; ++k) {
            uint256 i = k % 2;
            uint256 got = _swap(i, c * m[i]);
            _swap(1 - i, got);
        }
        (uint256 r0, uint256 r1) = p.getReserves();
        assertEq(r0, e.pre0, "reserve0 before exit (Python model)");
        assertEq(r1, e.pre1, "reserve1 before exit (Python model)");

        uint256 lp = p.balanceOf(alice);
        assertEq(lp, A - 1000);
        vm.prank(alice);
        (uint256 o0, uint256 o1) = p.removeLiquidity(lp, 0, 0, alice, block.timestamp);
        assertEq(o0, lp * r0 / A, "exit token0");
        assertEq(o1, lp * r1 / A, "exit token1");
        (r0, r1) = p.getReserves();
        assertEq(r0, e.left0, "left in the Pool token0 (Python model)");
        assertEq(r1, e.left1, "left in the Pool token1 (Python model)");
        assertEq(t0.balanceOf(address(p)), r0);
        assertEq(t1.balanceOf(address(p)), r1);
        // alice is the only actor: her wallet change is exactly minus what stays in the Pool.
        int256 w0 = int256(t0.balanceOf(alice)) - int256(FUND);
        int256 w1 = int256(t1.balanceOf(alice)) - int256(FUND);
        assertEq(w0, -int256(e.left0), "alice wallet token0 = - Pool remainder");
        assertEq(w1, -int256(e.left1), "alice wallet token1 = - Pool remainder");
        assertEq(t0.balanceOf(surplusRecipient), 0);
        assertEq(t1.balanceOf(surplusRecipient), 0);

        uint256 swaps = 2 * trips;
        emit log_named_uint("round trips", trips);
        emit log_named_uint("swaps", swaps);
        emit log_named_uint("swap gas total", gasTotal);
        emit log_named_uint("swap gas mean", gasTotal / swaps);
        emit log_named_uint("swap gas min", gasMin);
        emit log_named_uint("swap gas max", gasMax);
    }

    function test_F1T3_c1_200roundTrips() public {
        _run(1, 200, Expect(1_350_041, 1_350_040, 1351, 1351));
    }

    function test_F1T3_c1_2000roundTrips() public {
        _run(1, 2000, Expect(20_095_042, 20_095_155, 20_096, 20_096));
    }

    function test_F1T3_c10_200roundTrips() public {
        _run(10, 200, Expect(1_727_288, 1_727_357, 1728, 1728));
    }

    function test_F1T3_c10_2000roundTrips() public {
        _run(10, 2000, Expect(235_642_086, 235_646_772, 235_643, 235_647));
    }
}
