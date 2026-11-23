// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {IAMMPool} from "../src/interfaces/IAMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeERC20} from "./mocks/MockFeeERC20.sol";
import {addParams, addParamsOrdered} from "./utils/AddParams.sol";

/// @notice M8 commit 5b (tests only): the maxExcess bound (DECISIONS M8-2).
///         TEST_MATRIX L36. The expected unmatched amount u_i = n_i − ceil(σ·r_i/S) is computed
///         here from the pre-deposit state and the returned nets with plain integer arithmetic;
///         the Pool's own result is then checked at the boundary: maxExcess = u succeeds,
///         maxExcess = u − 1 reverts ExcessContributionTooHigh with full rollback, per token.
contract AMMPoolMaxExcessTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    MockFeeERC20.Path internal constant PULL = MockFeeERC20.Path.TransferFrom;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal surplusRecipient = makeAddr("surplusRecipient");

    AMMPool internal p;
    uint160 internal nextLow = 0x50000;
    uint160 internal nextHigh = type(uint160).max - 0x3000;

    function _deploy(string memory artifact, bool low) internal returns (address at) {
        at = low ? address(nextLow++) : address(nextHigh--);
        require(at.code.length == 0, "address reused");
        deployCodeTo(artifact, abi.encode("T", "T", uint8(18)), at);
    }

    function _pool(address x, address y, uint256 i0, uint256 i1) internal {
        (address lo, address hi) = x < y ? (x, y) : (y, x);
        p = new AMMPool(lo, hi, surplusRecipient);
        address[2] memory users = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            MockERC20(lo).mint(users[i], 1e30);
            MockERC20(hi).mint(users[i], 1e30);
            vm.startPrank(users[i]);
            MockERC20(lo).approve(address(p), MAX);
            MockERC20(hi).approve(address(p), MAX);
            vm.stopPrank();
        }
        vm.prank(alice);
        p.addLiquidity(addParams(i0, i1, 0, alice, block.timestamp));
    }

    struct Expect {
        uint256 u0;
        uint256 u1;
        uint256 sigma;
        bool inexact0; // σ·r0 not divisible by S (ceil ≠ floor)
        bool inexact1;
    }

    /// @dev Dry run with unbounded excess; the expected u_i from the pre-state and the nets.
    function _expect(IAMMPool.AddLiquidityParams memory prm) internal returns (Expect memory e) {
        (uint256 r0, uint256 r1) = p.getReserves();
        uint256 S = p.totalSupply();
        uint256 id = vm.snapshotState();
        (prm.maxExcess0, prm.maxExcess1) = (MAX, MAX);
        vm.prank(bob);
        (uint256 n0, uint256 n1, uint256 s) = p.addLiquidity(prm);
        vm.revertToState(id);
        uint256 s0 = n0 * S / r0;
        uint256 s1 = n1 * S / r1;
        e.sigma = s0 < s1 ? s0 : s1;
        assertEq(s, e.sigma, "shares match the reference");
        e.u0 = n0 - _ceilDiv(e.sigma * r0, S);
        e.u1 = n1 - _ceilDiv(e.sigma * r1, S);
        e.inexact0 = (e.sigma * r0) % S != 0;
        e.inexact1 = (e.sigma * r1) % S != 0;
    }

    struct State {
        uint256 r0;
        uint256 r1;
        uint256 supply;
        uint256 bobLP;
        uint256 pool0;
        uint256 pool1;
        uint256 bob0;
        uint256 bob1;
    }

    function _state() internal view returns (State memory s) {
        (s.r0, s.r1) = p.getReserves();
        s.supply = p.totalSupply();
        s.bobLP = p.balanceOf(bob);
        MockERC20 a = MockERC20(p.token0());
        MockERC20 c = MockERC20(p.token1());
        (s.pool0, s.pool1) = (a.balanceOf(address(p)), c.balanceOf(address(p)));
        (s.bob0, s.bob1) = (a.balanceOf(bob), c.balanceOf(bob));
    }

    /// @dev The boundary for both tokens: exact limits succeed; one below on a token with u > 0
    ///      reverts with full rollback.
    function _boundary(IAMMPool.AddLiquidityParams memory prm) internal returns (Expect memory e) {
        e = _expect(prm);
        uint256 id = vm.snapshotState();
        (prm.maxExcess0, prm.maxExcess1) = (e.u0, e.u1);
        vm.prank(bob);
        p.addLiquidity(prm); // u == maxExcess on both tokens: succeeds
        vm.revertToState(id);
        if (e.u0 > 0) _expectExcessRevert(prm, e.u0 - 1, e.u1);
        if (e.u1 > 0) _expectExcessRevert(prm, e.u0, e.u1 - 1);
    }

    function _expectExcessRevert(IAMMPool.AddLiquidityParams memory prm, uint256 m0, uint256 m1) internal {
        (prm.maxExcess0, prm.maxExcess1) = (m0, m1);
        State memory b = _state();
        vm.prank(bob);
        vm.expectRevert(AMMPool.ExcessContributionTooHigh.selector);
        p.addLiquidity(prm);
        assertEq(keccak256(abi.encode(_state())), keccak256(abi.encode(b)), "full-state rollback");
    }

    /// @dev Token X plain and pulled first, token Y with a 10% inclusive tax pulled second: X's
    ///      unmatched part is ~10% of its net. X as token0 and as token1.
    function test_L36_excessOnEachToken_boundary() public {
        for (uint256 pos; pos < 2; ++pos) {
            bool xLow = pos == 0;
            MockERC20 x = MockERC20(_deploy("MockERC20.sol:MockERC20", xLow));
            MockFeeERC20 y = MockFeeERC20(_deploy("MockFeeERC20.sol:MockFeeERC20", !xLow));
            _pool(address(x), address(y), 1e21, 1e21);
            y.setTax(PULL, 1000);
            Expect memory e = _boundary(addParamsOrdered(1e18, 1e18, 0, bob, block.timestamp, !xLow));
            assertGt(xLow ? e.u0 : e.u1, 9e16, "X carries the ~10% excess");
        }
    }

    /// @dev Tier 0 dust: plain tokens at an awkward ratio; a deposit with u_i in {0, small} and
    ///      ceil ≠ floor on at least one side. Checks maxExcess = u exactly, also when u == 0
    ///      (maxExcess = 0 must then succeed).
    function test_L36_tier0Dust_boundaryIncludingZero() public {
        MockERC20 a = MockERC20(_deploy("MockERC20.sol:MockERC20", true));
        MockERC20 c = MockERC20(_deploy("MockERC20.sol:MockERC20", false));
        _pool(address(a), address(c), 1_000_003, 2_999_999);
        bool sawZero;
        bool sawPositive;
        bool sawInexact;
        uint256[4] memory amts = [uint256(1000), 12_345, 777_777, 1_000_003];
        for (uint256 i; i < 4; ++i) {
            Expect memory e = _boundary(addParams(amts[i], MAX, 0, bob, block.timestamp));
            if (e.u0 == 0 || e.u1 == 0) sawZero = true;
            if (e.u0 > 0 || e.u1 > 0) sawPositive = true;
            if (e.inexact0 || e.inexact1) sawInexact = true;
            if (e.u0 == 0 && e.u1 == 0) {
                IAMMPool.AddLiquidityParams memory prm = addParams(amts[i], MAX, 0, bob, block.timestamp);
                (prm.maxExcess0, prm.maxExcess1) = (0, 0);
                uint256 id = vm.snapshotState();
                vm.prank(bob);
                p.addLiquidity(prm); // u == 0 == maxExcess: succeeds
                vm.revertToState(id);
            }
        }
        assertTrue(sawZero && sawPositive && sawInexact, "the cases cover u == 0, u > 0 and ceil != floor");
    }

    /// @dev Fuzz: for plain tokens at random ratios, the Pool accepts exactly maxExcess_i >= u_i.
    function testFuzz_L36_tier0Boundary(uint256 r0, uint256 r1, uint256 c0) public {
        r0 = bound(r0, 1e3, 1e27);
        r1 = bound(r1, 1e3, 1e27);
        vm.assume(r0 * r1 > 1e6 + 2e3 + 1); // initial shares > 1000
        MockERC20 a = MockERC20(_deploy("MockERC20.sol:MockERC20", true));
        MockERC20 c = MockERC20(_deploy("MockERC20.sol:MockERC20", false));
        _pool(address(a), address(c), r0, r1);
        c0 = bound(c0, 1, 1e28);
        IAMMPool.AddLiquidityParams memory prm = addParams(c0, MAX, 0, bob, block.timestamp);
        uint256 id = vm.snapshotState();
        vm.prank(bob);
        (bool ok,) = address(p).call(abi.encodeCall(AMMPool.addLiquidity, (prm)));
        vm.revertToState(id);
        vm.assume(ok); // only successful deposits have a defined u (others: L42/Z07 rows)
        _boundary(prm);
    }

    function _ceilDiv(uint256 n, uint256 d) internal pure returns (uint256) {
        return n == 0 ? 0 : (n - 1) / d + 1;
    }
}
