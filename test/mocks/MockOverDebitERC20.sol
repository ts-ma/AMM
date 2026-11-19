// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {MockERC20} from "./MockERC20.sol";

/// @title MockOverDebitERC20 — token whose outbound `transfer` debits the sender MORE than
///        the amount (exclusive fee-on-transfer style). TEST-ONLY; unsupported by the Pool.
/// @notice The recipient is credited exactly `value`; the sender additionally loses `extra`
///         (burned). The Pool's A8 check (Pool balance must fall by exactly the amount sent,
///         BI-5) must detect this and revert (TEST_MATRIX B06 negative case, W09; X04 in M8).
/// @dev Only `transfer` (Pool -> recipient) over-debits; `transferFrom` (user -> Pool) is
///      standard, so deposits work. `extra` is configurable; 0 makes it a standard token.
contract MockOverDebitERC20 is MockERC20 {
    uint256 public extra;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20(name_, symbol_, decimals_) {}

    function setExtra(uint256 extra_) external {
        extra = extra_;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        bool ok = super.transfer(to, value);
        if (extra != 0) _burn(msg.sender, extra);
        return ok;
    }
}
