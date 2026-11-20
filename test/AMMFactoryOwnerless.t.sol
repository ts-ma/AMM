// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AMMFactory} from "../src/AMMFactory.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice X03-F — Factory ownerless (D10, DECISIONS M7-7). Static: the compiled ABI exposes
///         exactly the approved functions, none payable, and no fallback/receive. Runtime:
///         admin-style and withdrawal selectors, unknown selectors, plain ETH transfers and ETH
///         sent to approved functions fail with empty return data and change nothing.
///         Report wording: "Factory does not expose payable entry points or token withdrawal
///         functions."
/// @dev Reads `out/AMMFactory.sol/AMMFactory.json` (Foundry's default read permission on `out`,
///      as X03 for the Pool). Adding a Factory function requires extending APPROVED in the same
///      commit.
contract AMMFactoryOwnerlessTest is Test {
    AMMFactory internal factory;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    address internal pool;
    address internal alice = makeAddr("alice");

    string internal constant ARTIFACT = "out/AMMFactory.sol/AMMFactory.json";

    function _approved() internal pure returns (string[5] memory a) {
        a = [
            "allPairs(uint256)",
            "allPairsLength()",
            "createPair(address,address)",
            "getPair(address,address)",
            "surplusRecipient()"
        ];
    }

    function setUp() public {
        factory = new AMMFactory(makeAddr("surplusRecipient"));
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);
        pool = factory.createPair(address(tokenA), address(tokenB));
        tokenA.mint(address(factory), 1e18); // a mistaken transfer to the Factory
    }

    // ------------------------------------------------------------------
    // Static: compiled ABI
    // ------------------------------------------------------------------

    function test_X03F_static_abiFunctionsEqualApprovedList() public view {
        string memory json = vm.readFile(ARTIFACT);
        string[] memory actual = vm.parseJsonKeys(json, ".methodIdentifiers");
        string[5] memory approved = _approved();
        assertEq(actual.length, approved.length, "number of external functions");
        for (uint256 i; i < actual.length; ++i) {
            bool found;
            for (uint256 j; j < approved.length; ++j) {
                if (keccak256(bytes(actual[i])) == keccak256(bytes(approved[j]))) found = true;
            }
            assertTrue(found, string.concat("unapproved function in ABI: ", actual[i]));
        }
    }

    /// @dev No fallback/receive, and no entry of the ABI (functions or constructor) is payable.
    function test_X03F_static_noFallbackReceiveOrPayable() public view {
        string memory json = vm.readFile(ARTIFACT);
        uint256 n;
        uint256 functions;
        while (vm.keyExistsJson(json, string.concat(".abi[", vm.toString(n), "].type"))) {
            string memory key = string.concat(".abi[", vm.toString(n), "]");
            bytes32 h = keccak256(bytes(vm.parseJsonString(json, string.concat(key, ".type"))));
            assertTrue(h != keccak256("fallback"), "fallback present");
            assertTrue(h != keccak256("receive"), "receive present");
            if (h == keccak256("function") || h == keccak256("constructor")) {
                bytes32 m = keccak256(bytes(vm.parseJsonString(json, string.concat(key, ".stateMutability"))));
                assertTrue(m != keccak256("payable"), "payable entry point");
            }
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
        uint256 length;
        address pair;
        address pairReverse;
        uint256 eth;
        uint256 tokenHeld;
    }

    function _snap() internal view returns (Snap memory s) {
        s.length = factory.allPairsLength();
        s.pair = factory.getPair(address(tokenA), address(tokenB));
        s.pairReverse = factory.getPair(address(tokenB), address(tokenA));
        s.eth = address(factory).balance;
        s.tokenHeld = tokenA.balanceOf(address(factory));
    }

    function _assertCallFails(bytes memory data, uint256 value) internal {
        Snap memory b = _snap();
        vm.deal(alice, value);
        vm.prank(alice);
        (bool ok, bytes memory ret) = address(factory).call{value: value}(data);
        assertFalse(ok, "call must fail");
        assertEq(ret.length, 0, "empty revert data");
        Snap memory a = _snap();
        assertEq(a.length, b.length);
        assertEq(a.pair, b.pair);
        assertEq(a.pairReverse, b.pairReverse);
        assertEq(a.eth, b.eth);
        assertEq(a.tokenHeld, b.tokenHeld);
    }

    function test_X03F_runtime_adminAndWithdrawalSelectorsFail() public {
        address x = makeAddr("x");
        _assertCallFails(abi.encodeWithSignature("owner()"), 0);
        _assertCallFails(abi.encodeWithSignature("transferOwnership(address)", x), 0);
        _assertCallFails(abi.encodeWithSignature("renounceOwnership()"), 0);
        _assertCallFails(abi.encodeWithSignature("setSurplusRecipient(address)", x), 0);
        _assertCallFails(abi.encodeWithSignature("setFeeTo(address)", x), 0);
        _assertCallFails(abi.encodeWithSignature("setFeeToSetter(address)", x), 0);
        _assertCallFails(abi.encodeWithSignature("feeTo()"), 0);
        _assertCallFails(abi.encodeWithSignature("removePair(address,address)", address(tokenA), address(tokenB)), 0);
        _assertCallFails(
            abi.encodeWithSignature("setPair(address,address,address)", address(tokenA), address(tokenB), x), 0
        );
        _assertCallFails(abi.encodeWithSignature("sweep(address,address,uint256)", address(tokenA), x, 1), 0);
        _assertCallFails(abi.encodeWithSignature("withdraw(address,uint256)", address(tokenA), 1), 0);
        _assertCallFails(abi.encodeWithSignature("pause()"), 0);
    }

    function test_X03F_runtime_plainEthTransferFails() public {
        _assertCallFails("", 1 ether);
        _assertCallFails(hex"deadbeef", 1 ether);
    }

    /// @dev Every approved function is non-payable: sending ETH with it reverts (empty data).
    function test_X03F_runtime_ethWithApprovedFunctionsFails() public {
        MockERC20 c = new MockERC20("Token C", "TKC", 18);
        _assertCallFails(abi.encodeCall(factory.createPair, (address(tokenA), address(c))), 1);
        _assertCallFails(abi.encodeCall(factory.allPairs, (0)), 1);
        _assertCallFails(abi.encodeCall(factory.allPairsLength, ()), 1);
        _assertCallFails(abi.encodeCall(factory.getPair, (address(tokenA), address(tokenB))), 1);
        _assertCallFails(abi.encodeCall(factory.surplusRecipient, ()), 1);
    }

    /// @dev Range: random selectors with two random 32-byte arguments; approved selectors excluded.
    function testFuzz_X03F_runtime_unknownSelectorFails(bytes4 selector, bytes32 arg0, bytes32 arg1) public {
        string[5] memory approved = _approved();
        for (uint256 i; i < approved.length; ++i) {
            vm.assume(selector != bytes4(keccak256(bytes(approved[i]))));
        }
        _assertCallFails(abi.encodePacked(selector, arg0, arg1), 0);
    }
}
