// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AMMPool} from "../src/AMMPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {addParams} from "./utils/AddParams.sol";

/// @notice X03 — D10 ownerless (DECISIONS M5-7). Static: the compiled ABI exposes exactly the
///         approved functions and no fallback/receive. Runtime: admin-style selectors, unknown
///         selectors and plain ETH transfers fail with empty return data and change nothing.
/// @dev The static part reads `out/AMMPool.sol/AMMPool.json` through Foundry's default read
///      permission on `out` (confirmed with `forge config`; foundry.toml unchanged). When a later
///      milestone adds an approved function (e.g. M6 `sync`/`skim`), APPROVED must be extended in
///      the same commit — an unexpected interface change makes this test fail.
contract AMMPoolOwnerlessTest is Test {
    AMMPool internal pool;
    MockERC20 internal t0;
    MockERC20 internal t1;
    address internal alice = makeAddr("alice");

    function _approved() internal pure returns (string[22] memory a) {
        a = [
            // ERC-20 (LP token, OpenZeppelin)
            "allowance(address,address)",
            "approve(address,uint256)",
            "balanceOf(address)",
            "decimals()",
            "name()",
            "symbol()",
            "totalSupply()",
            "transfer(address,uint256)",
            "transferFrom(address,address,uint256)",
            // constants and immutables
            "BPS_DENOMINATOR()",
            "FEE_BPS()",
            "MINIMUM_LIQUIDITY()",
            "surplusRecipient()",
            "token0()",
            "token1()",
            // Pool operations and views
            // M8 (DECISIONS M8-8): replaces addLiquidity(uint256,uint256,uint256,uint256,uint256,address,uint256)
            "addLiquidity((uint256,uint256,uint256,uint256,uint256,uint256,uint256,address,uint256,bool))",
            "removeLiquidity(uint256,uint256,uint256,address,uint256)",
            "swapExactInput(address,uint256,uint256,address,uint256)",
            "getAmountOut(address,uint256)",
            "getReserves()",
            // reserve reconciliation (M6)
            "sync()",
            "skim()"
        ];
    }

    function setUp() public {
        MockERC20 a = new MockERC20("Token A", "TKA", 18);
        MockERC20 b = new MockERC20("Token B", "TKB", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        pool = new AMMPool(address(t0), address(t1), makeAddr("surplusRecipient"));
        t0.mint(alice, 1e24);
        t1.mint(alice, 1e24);
        vm.startPrank(alice);
        t0.approve(address(pool), type(uint256).max);
        t1.approve(address(pool), type(uint256).max);
        pool.addLiquidity(addParams(1e21, 1e21, 0, alice, block.timestamp));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Static: compiled ABI
    // ------------------------------------------------------------------

    function test_X03_static_abiFunctionsEqualApprovedList() public view {
        string memory json = vm.readFile("out/AMMPool.sol/AMMPool.json");
        string[] memory actual = vm.parseJsonKeys(json, ".methodIdentifiers");
        string[22] memory approved = _approved();
        assertEq(actual.length, approved.length, "number of external functions");
        for (uint256 i; i < actual.length; ++i) {
            bool found;
            for (uint256 j; j < approved.length; ++j) {
                if (keccak256(bytes(actual[i])) == keccak256(bytes(approved[j]))) found = true;
            }
            assertTrue(found, string.concat("unapproved function in ABI: ", actual[i]));
        }
    }

    /// @dev M8-5 (1)/(3), M8-8: the old addLiquidity entry is gone, the new one is present with the
    ///      approved selector, and the function count is still 22 (one replacement, nothing added).
    function test_X03_static_addLiquidityReplaced() public view {
        string memory oldSig = "addLiquidity(uint256,uint256,uint256,uint256,uint256,address,uint256)";
        string memory newSig =
            "addLiquidity((uint256,uint256,uint256,uint256,uint256,uint256,uint256,address,uint256,bool))";
        assertEq(bytes4(keccak256(bytes(oldSig))), bytes4(0x12c62f32), "old selector value");
        assertEq(bytes4(keccak256(bytes(newSig))), bytes4(0x7713f77f), "new selector value");
        assertEq(AMMPool.addLiquidity.selector, bytes4(0x7713f77f), "compiled selector = approved");

        string[] memory actual = vm.parseJsonKeys(vm.readFile("out/AMMPool.sol/AMMPool.json"), ".methodIdentifiers");
        assertEq(actual.length, 22, "still 22 functions");
        bool hasNew;
        for (uint256 i; i < actual.length; ++i) {
            bytes32 h = keccak256(bytes(actual[i]));
            assertTrue(h != keccak256(bytes(oldSig)), "old addLiquidity absent");
            if (h == keccak256(bytes(newSig))) hasNew = true;
        }
        assertTrue(hasNew, "new addLiquidity present");
    }

    /// @dev Runtime: the old selector with its old 7-word arguments reaches no code path.
    function test_X03_runtime_oldAddLiquiditySelectorFails() public {
        _assertCallFails(
            abi.encodeWithSelector(
                bytes4(0x12c62f32),
                uint256(1e18),
                uint256(1e18),
                uint256(0),
                uint256(0),
                uint256(0),
                alice,
                block.timestamp
            ),
            0
        );
    }

    function test_X03_static_noFallbackOrReceive() public view {
        string memory json = vm.readFile("out/AMMPool.sol/AMMPool.json");
        uint256 n;
        uint256 functions;
        while (vm.keyExistsJson(json, string.concat(".abi[", vm.toString(n), "].type"))) {
            bytes32 h = keccak256(bytes(vm.parseJsonString(json, string.concat(".abi[", vm.toString(n), "].type"))));
            assertTrue(h != keccak256("fallback"), "fallback present");
            assertTrue(h != keccak256("receive"), "receive present");
            if (h == keccak256("function")) ++functions;
            ++n;
        }
        assertGt(n, 0, "ABI parsed");
        assertEq(functions, _approved().length, "every ABI entry was inspected");
    }

    // ------------------------------------------------------------------
    // Runtime
    // ------------------------------------------------------------------

    struct Snap {
        uint256 r0;
        uint256 r1;
        uint256 supply;
        uint256 pool0;
        uint256 pool1;
        uint256 eth;
    }

    function _snap() internal view returns (Snap memory s) {
        (s.r0, s.r1) = pool.getReserves();
        s.supply = pool.totalSupply();
        s.pool0 = t0.balanceOf(address(pool));
        s.pool1 = t1.balanceOf(address(pool));
        s.eth = address(pool).balance;
    }

    function _assertCallFails(bytes memory data, uint256 value) internal {
        Snap memory b = _snap();
        vm.deal(alice, value);
        vm.prank(alice);
        (bool ok, bytes memory ret) = address(pool).call{value: value}(data);
        assertFalse(ok, "call must fail");
        assertEq(ret.length, 0, "no function matched: empty revert data");
        Snap memory a = _snap();
        assertEq(a.r0, b.r0);
        assertEq(a.r1, b.r1);
        assertEq(a.supply, b.supply);
        assertEq(a.pool0, b.pool0);
        assertEq(a.pool1, b.pool1);
        assertEq(a.eth, b.eth);
    }

    function test_X03_runtime_adminSelectorsFail() public {
        address x = makeAddr("x");
        _assertCallFails(abi.encodeWithSignature("owner()"), 0);
        _assertCallFails(abi.encodeWithSignature("transferOwnership(address)", x), 0);
        _assertCallFails(abi.encodeWithSignature("renounceOwnership()"), 0);
        _assertCallFails(abi.encodeWithSignature("setSurplusRecipient(address)", x), 0);
        _assertCallFails(abi.encodeWithSignature("setFee(uint256)", 0), 0);
        _assertCallFails(abi.encodeWithSignature("setFeeTo(address)", x), 0);
        _assertCallFails(abi.encodeWithSignature("sweep(address,address,uint256)", address(t0), x, 1), 0);
        _assertCallFails(abi.encodeWithSignature("pause()"), 0);
        _assertCallFails(abi.encodeWithSignature("unpause()"), 0);
        _assertCallFails(abi.encodeWithSignature("mint(address,uint256)", x, 1), 0);
        _assertCallFails(abi.encodeWithSignature("burn(address,uint256)", x, 1), 0);
    }

    function test_X03_runtime_plainEthTransferFails() public {
        _assertCallFails("", 1 ether);
        _assertCallFails(hex"deadbeef", 1 ether);
    }

    /// @dev Any selector that is not an approved function reaches no code path (no fallback).
    function testFuzz_X03_runtime_unknownSelectorFails(bytes4 selector, bytes32 arg0, bytes32 arg1) public {
        string[22] memory approved = _approved();
        for (uint256 i; i < approved.length; ++i) {
            vm.assume(selector != bytes4(keccak256(bytes(approved[i]))));
        }
        _assertCallFails(abi.encodePacked(selector, arg0, arg1), 0);
    }
}
