// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {MockERC20} from "./MockERC20.sol";

/// @title MockFailingERC20 — token whose transferFrom / transfer / balanceOf can be made to fail. TEST-ONLY.
/// @notice Used to show that a failure in one external call rolls back the whole Pool call,
///         including transfers of the other token that already completed (TEST_MATRIX L23, W09).
/// @dev Outbound modes (RevertTransfer, ReturnFalseTransfer) appended in M4 (DECISIONS M4-4);
///      RevertAllTransfers appended in M8; existing modes keep their meaning and numbering.
///      `MockFailure()` is a mock-only error, so a test expecting it can never confuse it with
///      a Pool error (used as a tripwire for "must not be called" assertions, TEST_MATRIX L42).
contract MockFailingERC20 is MockERC20 {
    enum Mode {
        None,
        RevertTransferFrom,
        ReturnFalseTransferFrom,
        RevertBalanceOf,
        RevertTransfer,
        ReturnFalseTransfer,
        RevertAllTransfers // M8 (TEST_MATRIX X06 (B)): both transfer and transferFrom revert
    }

    error MockFailure();

    Mode public mode;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20(name_, symbol_, decimals_) {}

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (mode == Mode.RevertTransferFrom || mode == Mode.RevertAllTransfers) revert MockFailure();
        if (mode == Mode.ReturnFalseTransferFrom) return false;
        return super.transferFrom(from, to, value);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (mode == Mode.RevertTransfer || mode == Mode.RevertAllTransfers) revert MockFailure();
        if (mode == Mode.ReturnFalseTransfer) return false;
        return super.transfer(to, value);
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (mode == Mode.RevertBalanceOf) revert MockFailure();
        return super.balanceOf(account);
    }
}
