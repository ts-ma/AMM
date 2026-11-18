// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {MockERC20} from "./MockERC20.sol";

/// @title MockFailingERC20 — token whose transferFrom / balanceOf can be made to fail. TEST-ONLY.
/// @notice Used to show that a failure in one external call rolls back the whole Pool call,
///         including transfers of the other token that already completed (TEST_MATRIX L23).
contract MockFailingERC20 is MockERC20 {
    enum Mode {
        None,
        RevertTransferFrom,
        ReturnFalseTransferFrom,
        RevertBalanceOf
    }

    error MockFailure();

    Mode public mode;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20(name_, symbol_, decimals_) {}

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (mode == Mode.RevertTransferFrom) revert MockFailure();
        if (mode == Mode.ReturnFalseTransferFrom) return false;
        return super.transferFrom(from, to, value);
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (mode == Mode.RevertBalanceOf) revert MockFailure();
        return super.balanceOf(account);
    }
}
