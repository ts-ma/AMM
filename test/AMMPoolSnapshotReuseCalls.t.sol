// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {SnapshotReuseBase} from "./utils/SnapshotReuseBase.sol";

/// Snapshot reuse (DECISIONS M11-4). Token calls made by the Pool during one deposit,
/// from Foundry's recorded account accesses (`vm.startStateDiffRecording`), classified by token
/// target, caller, selector and — for `balanceOf` — the account argument (Pool / payer / other).
/// Recording runs in its own test, never inside a gas interval.
/// A later deposit makes 6 Pool reads + 4 payer reads (04eb336: 10 + 4); the initial deposit is
/// the unchanged control (8 + 4).
contract AMMPoolSnapshotReuseCallsTest is SnapshotReuseBase {
    /// @dev Pool `balanceOf(pool)` calls per token on a later deposit: 3 (entry reading, after
    ///      its own transfer, and either the before-reading of the second-pulled token or the end
    ///      reading of the first-pulled token). 04eb336: 5 (deficit check, start snapshot, before
    ///      and after its own transfer, end check).
    uint256 internal constant LATER_POOL_READS_PER_TOKEN = 3;
    /// @dev Unchanged by M11-4: payer reads per token (start, end) and the initial path.
    uint256 internal constant LATER_PAYER_READS_PER_TOKEN = 2;
    uint256 internal constant INIT_POOL_READS_PER_TOKEN = 4;
    uint256 internal constant INIT_PAYER_READS_PER_TOKEN = 2;

    function _check(TokenCalls memory c, uint256 poolReads, uint256 payerReads, string memory tag) internal {
        emit log_named_uint(string.concat(tag, " pool reads"), c.poolReads);
        emit log_named_uint(string.concat(tag, " payer reads"), c.payerReads);
        assertEq(c.poolReads, poolReads, string.concat(tag, ": balanceOf(pool)"));
        assertEq(c.payerReads, payerReads, string.concat(tag, ": balanceOf(payer)"));
        assertEq(c.otherReads, 0, string.concat(tag, ": balanceOf(other)"));
        assertEq(c.transferFroms, 1, string.concat(tag, ": transferFrom"));
        assertEq(c.otherCalls, 0, string.concat(tag, ": other calls or callers"));
    }

    function _later(bool ordTokens, bool flag) internal {
        (TokenCalls memory c0, TokenCalls memory c1) =
            ordTokens ? _record(ord, _ordParams(flag), alice) : _record(l46, _l46Params(flag), bob);
        string memory s =
            ordTokens ? (flag ? "ORD token1First" : "ORD token0First") : (flag ? "L46 taxedFirst" : "L46 taxedSecond");
        _check(c0, LATER_POOL_READS_PER_TOKEN, LATER_PAYER_READS_PER_TOKEN, string.concat(s, " token0"));
        _check(c1, LATER_POOL_READS_PER_TOKEN, LATER_PAYER_READS_PER_TOKEN, string.concat(s, " token1"));
    }

    function test_calls_ord_token0First() public {
        _later(true, false);
    }

    function test_calls_ord_token1First() public {
        _later(true, true);
    }

    function test_calls_l46_taxedSecond() public {
        _later(false, false);
    }

    function test_calls_l46_taxedFirst() public {
        _later(false, true);
    }

    function test_calls_initial_unchanged() public {
        (TokenCalls memory c0, TokenCalls memory c1) = _record(fresh, _initParams(), alice);
        _check(c0, INIT_POOL_READS_PER_TOKEN, INIT_PAYER_READS_PER_TOKEN, "INIT token0");
        _check(c1, INIT_POOL_READS_PER_TOKEN, INIT_PAYER_READS_PER_TOKEN, "INIT token1");
    }
}
