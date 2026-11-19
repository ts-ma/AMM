// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {MockERC20} from "./MockERC20.sol";

/// @title ReentrantERC20 — token that calls back into a target during a transfer. TEST-ONLY.
/// @notice Models a token with a transfer hook (e.g. ERC-777-like) trying to re-enter the Pool
///         (THREAT_MODEL T1, T13; TEST_MATRIX L24, W07, S08, X01, X05; DECISIONS M5-6).
///         Configuration (all one-shot per `arm*` call):
///         - Hook point: `transferFrom` (inbound to the Pool) or `transfer` (outbound from it).
///         - Bubble or catch: if the callback reverts, either bubble its revert data unchanged
///           (the whole outer call fails) or swallow it and continue with the transfer.
///         - Faults (independent of the callback, apply to both transfer functions while set):
///           `extraDebit` burns extra tokens from the sender after the move (the sender loses
///           more than `value`, so a Pool's A8 check fails); `withhold` burns tokens from the
///           receiver after the move (the receiver gets less than `value`, so MIN-NET or the
///           `[T, T + 1]` check fails).
///         The callback's success flag and return data are recorded, so a test can read what a
///         view function returned mid-call (X05) or which error the re-entry hit.
/// @dev The callback runs BEFORE the balance move, as a hook would; the move itself is
///      OpenZeppelin's ERC20.
contract ReentrantERC20 is MockERC20 {
    enum Hook {
        TransferFrom,
        Transfer
    }

    address public target;
    bytes public payload;
    bool public armed;
    Hook public hook;
    bool public catchRevert;

    uint256 public extraDebit;
    uint256 public withhold;

    bool public callbackRan;
    bool public lastCallOk;
    bytes public lastReturnData;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20(name_, symbol_, decimals_) {}

    /// @notice Original M3 behaviour: call back during the next `transferFrom`, bubbling reverts.
    function arm(address target_, bytes calldata payload_) external {
        _arm(target_, payload_, Hook.TransferFrom, false);
    }

    /// @notice Call back at `hook_`; if `catch_` is true a reverting callback is swallowed.
    function armWith(address target_, bytes calldata payload_, Hook hook_, bool catch_) external {
        _arm(target_, payload_, hook_, catch_);
    }

    function setFaults(uint256 extraDebit_, uint256 withhold_) external {
        extraDebit = extraDebit_;
        withhold = withhold_;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _maybeCallback(Hook.TransferFrom);
        bool ok = super.transferFrom(from, to, value);
        _applyFaults(from, to);
        return ok;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        _maybeCallback(Hook.Transfer);
        bool ok = super.transfer(to, value);
        _applyFaults(msg.sender, to);
        return ok;
    }

    function _arm(address target_, bytes calldata payload_, Hook hook_, bool catch_) private {
        target = target_;
        payload = payload_;
        hook = hook_;
        catchRevert = catch_;
        armed = true;
        callbackRan = false;
        lastCallOk = false;
        delete lastReturnData;
    }

    function _maybeCallback(Hook at) private {
        if (!armed || hook != at) return;
        armed = false;
        callbackRan = true;
        (bool ok, bytes memory ret) = target.call(payload);
        lastCallOk = ok;
        lastReturnData = ret;
        if (!ok && !catchRevert) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function _applyFaults(address from, address to) private {
        if (extraDebit != 0) _burn(from, extraDebit);
        if (withhold != 0) _burn(to, withhold);
    }
}
