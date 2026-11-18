// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {AMMPool} from "../../src/AMMPool.sol";

/// @notice TEST-ONLY subclass simulating a future developer adding new `_mint`/`_burn` call
///         sites, to show the `_update` supply rules reject them (TEST_MATRIX P08, DECISIONS M3-2).
contract AMMPoolSupplyHarness is AMMPool {
    constructor(address token0_, address token1_, address surplusRecipient_)
        AMMPool(token0_, token1_, surplusRecipient_)
    {}

    /// Mint without a reentrancy guard → must revert SupplyChangeOutsideGuard.
    function unguardedMint(address to, uint256 value) external {
        _mint(to, value);
    }

    /// Burn without a reentrancy guard → must revert SupplyChangeOutsideGuard.
    function unguardedBurn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// Guarded mint, used to show a second mint to the Pool is still rejected (LPTransferToPool).
    function guardedMint(address to, uint256 value) external nonReentrant {
        _mint(to, value);
    }

    /// Guarded burn of Pool-held LP → must revert LockedLiquidity.
    function guardedBurn(address from, uint256 value) external nonReentrant {
        _burn(from, value);
    }
}
