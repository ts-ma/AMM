// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// Candidate B micro-benchmark (experiment only): the per-call cost of reaching code through an
/// ERC-1167 clone with immutable args, versus a directly deployed contract with immutables.
/// `f()` reads the three addresses a Pool keeps as immutables (token0, token1, recipient).
contract Direct {
    address public immutable a;
    address public immutable b;
    address public immutable c;

    constructor(address a_, address b_, address c_) {
        (a, b, c) = (a_, b_, c_);
    }

    function f() external view returns (uint256) {
        return uint160(a) ^ uint160(b) ^ uint160(c);
    }

    /// Control: same result, the three addresses are not read.
    function g() external pure returns (uint256) {
        return uint160(address(1)) ^ uint160(address(2)) ^ uint160(address(3));
    }
}

contract Impl {
    function f() external view returns (uint256) {
        (address a, address b, address c) = abi.decode(Clones.fetchCloneArgs(address(this)), (address, address, address));
        return uint160(a) ^ uint160(b) ^ uint160(c);
    }

    /// Control: same result, the clone arguments are not read.
    function g() external pure returns (uint256) {
        return uint160(address(1)) ^ uint160(address(2)) ^ uint160(address(3));
    }
}

contract GasM11Clone is Test {
    Direct internal d;
    Impl internal impl;
    address internal cl;

    function setUp() public {
        d = new Direct(address(1), address(2), address(3));
        impl = new Impl();
        cl = Clones.cloneWithImmutableArgs(address(impl), abi.encode(address(1), address(2), address(3)));
    }

    function test_call_direct() public {
        Direct x = d;
        uint256 g = gasleft();
        x.f();
        emit log_named_uint("GAS call direct (immutables)", g - gasleft());
    }

    function test_call_clone() public {
        Impl x = Impl(cl);
        uint256 g = gasleft();
        x.f();
        emit log_named_uint("GAS call via clone (delegatecall + fetchCloneArgs)", g - gasleft());
    }

    function test_call_direct_noRead() public {
        Direct x = d;
        uint256 g = gasleft();
        x.g();
        emit log_named_uint("GAS call direct, no argument read", g - gasleft());
    }

    function test_call_clone_noRead() public {
        Impl x = Impl(cl);
        uint256 g = gasleft();
        x.g();
        emit log_named_uint("GAS call via clone, no argument read (delegatecall only)", g - gasleft());
    }

    function test_sameResults() public view {
        assertEq(d.f(), Impl(cl).f());
        assertEq(d.g(), Impl(cl).g());
        assertEq(d.f(), d.g());
    }

    function test_create_clone() public {
        address i = address(impl);
        bytes memory args = abi.encode(address(4), address(5), address(6));
        uint256 g = gasleft();
        Clones.cloneWithImmutableArgs(i, args);
        emit log_named_uint("GAS create clone with 3 address args", g - gasleft());
    }
}
