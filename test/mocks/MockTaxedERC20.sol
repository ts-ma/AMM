// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {MockERC20} from "./MockERC20.sol";

/// @title MockTaxedERC20 — Tier 1 (U8) inclusive fee-on-transfer token. TEST-ONLY.
/// @notice Satisfies all four U8 conditions (docs/ARCHITECTURE.md §3):
///         (1) inclusive: the sender is debited exactly the transfer amount g;
///         (2) the recipient receives g − floor(g × taxBps / 10000);
///         (3) taxBps is fixed at construction, identical for all addresses, < 10000;
///         (4) balanceOf is truthful. The fee is burned, so totalSupply stays truthful too.
/// @dev Mints and burns are not taxed. Moved forward from M8 for the M3 taxed initial-deposit
///      test (DECISIONS M3-6).
contract MockTaxedERC20 is MockERC20 {
    uint256 public immutable taxBps;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 taxBps_)
        MockERC20(name_, symbol_, decimals_)
    {
        require(taxBps_ < 10_000, "tax >= 100%");
        taxBps = taxBps_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || taxBps == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * taxBps) / 10_000;
        super._update(from, to, value - fee); // recipient credit
        super._update(from, address(0), fee); // sender debited the remainder: total = value
    }
}
