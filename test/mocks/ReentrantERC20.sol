// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {MockERC20} from "./MockERC20.sol";

/// @title ReentrantERC20 — token that calls back into a target during transferFrom. TEST-ONLY.
/// @notice Models a token with a transfer hook (e.g. ERC-777-like) trying to re-enter the Pool.
///         If the re-entrant call reverts, its revert data is bubbled up unchanged so the test
///         can assert the exact reason (TEST_MATRIX L24; full attack suite in M5).
contract ReentrantERC20 is MockERC20 {
    address public target;
    bytes public payload;
    bool public armed;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20(name_, symbol_, decimals_) {}

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (armed) {
            armed = false;
            (bool ok, bytes memory ret) = target.call(payload);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        return super.transferFrom(from, to, value);
    }
}
