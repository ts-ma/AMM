// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20 — Tier 0 standard ERC-20 used only in tests.
/// @notice TEST-ONLY. `mint` is unrestricted so any test can fund any account.
///         Never deploy outside a test environment.
/// @dev Tier 0 behaviour (docs/ARCHITECTURE.md §3): the amount debited equals the
///      amount credited. Configurable decimals let the AMM be tested with the
///      18- and 6-decimal tokens required by TEST_MATRIX T01 and reference cases 4–5
///      (ARCHITECTURE §6.7). All transfer/allowance logic is OpenZeppelin's ERC20.
contract MockERC20 is ERC20 {
    /// @dev Stored as `immutable`: fixed in the constructor, embedded in bytecode.
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    /// @inheritdoc ERC20
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Create `amount` new tokens for `to`. Test helper; no access control.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
