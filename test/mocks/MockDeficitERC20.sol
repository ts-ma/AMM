// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {MockERC20} from "./MockERC20.sol";

/// @title MockDeficitERC20 — token whose balances can be reduced from outside. TEST-ONLY.
/// @notice Models behaviour OUTSIDE the supported token model (ARCHITECTURE §3), such as a
///         downward rebase or an issuer seizing funds: `slash` lowers any account's balance
///         without that account calling anything. Used to put a Pool into deficit
///         (`balance < reserve`, ARCHITECTURE §5.3) for TEST_MATRIX R08, R13–R22, B05
///         (DECISIONS M6-5). Transfers are otherwise standard (Tier 0).
contract MockDeficitERC20 is MockERC20 {
    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20(name_, symbol_, decimals_) {}

    /// @notice Destroy `amount` of `account`'s tokens. Test helper; no access control.
    /// @dev Reverts with OZ `ERC20InsufficientBalance` if `account` holds less than `amount`.
    function slash(address account, uint256 amount) external {
        _burn(account, amount);
    }
}
