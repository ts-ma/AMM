// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {AMMMath} from "../../src/libraries/AMMMath.sol";

/// @notice TEST-ONLY wrapper exposing AMMMath's internal functions as external calls,
///         so tests can observe reverts with `vm.expectRevert`.
contract AMMMathHarness {
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) external pure returns (uint256) {
        return AMMMath.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function initialShares(uint256 net0, uint256 net1) external pure returns (uint256) {
        return AMMMath.initialShares(net0, net1);
    }

    function feeBps() external pure returns (uint256) {
        return AMMMath.FEE_BPS;
    }

    function bpsDenominator() external pure returns (uint256) {
        return AMMMath.BPS_DENOMINATOR;
    }
}
