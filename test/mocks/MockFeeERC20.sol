// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "./MockERC20.sol";

/// @title MockFeeERC20 — configurable fee-on-transfer token for the M8 measured-net tests. TEST-ONLY.
/// @notice Each transfer path is configured separately: `Path.TransferFrom` (a pull such as
///         user → Pool) and `Path.Transfer` (a push such as Pool → user). For one transfer of
///         `value` on a path:
///         - inclusive tax `bps` (0..10_000, 100% allowed): fee = floor(value · bps / 10_000).
///           The sender is debited exactly `value`; the recipient is credited `value − fee`;
///           the fee is burned. The shortfall therefore appears on the recipient's side: the
///           sender pays the amount it sent, the recipient receives less than that amount.
///         - exclusive extra `extraBps`: extra = floor(value · extraBps / 10_000) is burned from
///           the **sender** on top of `value` (the sender loses `value + extra`; the recipient's
///           credit is unaffected). Allowance is spent by `value` only.
///         - `bonus`: an absolute amount minted to the recipient on top (credits more than sent).
///         Tax source, in priority order: (1) an explicit FIFO schedule of bps values
///         (predictable boundary values); (2) a seeded pseudo-random sequence
///         `bps = minBps + uint256(keccak256(abi.encode(seed, nonce))) % (maxBps − minBps + 1)`,
///         `nonce` starting at 0 and incremented per transfer (reproducible from the seed, no
///         environment randomness); (3) the fixed `taxBps`.
///         Mints and burns are never taxed. `balanceOf` is truthful; `totalSupply` decreases by
///         burned fees and extras and increases by bonuses.
/// @dev The whole transfer is atomic: if any step fails (e.g. the sender cannot cover
///      `value + extra`), the call reverts and every effect, including `callCount`, `nonce`
///      and the schedule position, is rolled back.
contract MockFeeERC20 is MockERC20 {
    enum Path {
        TransferFrom,
        Transfer
    }

    struct Config {
        uint256 taxBps;
        uint256 extraBps;
        uint256 bonus;
        bool random;
        uint256 seed;
        uint256 minBps;
        uint256 maxBps;
        uint256 nonce;
    }

    uint256 internal constant BPS = 10_000;

    error InvalidBps();

    Config[2] internal _cfg;
    uint256[][2] internal _schedule;
    uint256[2] internal _scheduleHead;

    /// @notice Number of completed transfers per path (index = uint256(Path)); a trace for tests.
    uint256[2] public callCount;
    /// @notice Tax bps applied by the most recent transfer on any path.
    uint256 public lastTaxBps;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20(name_, symbol_, decimals_) {}

    // ------------------------------------------------------------------
    // Configuration (no access control; test helper)
    // ------------------------------------------------------------------

    /// @notice Fixed inclusive tax; also switches the random sequence off.
    function setTax(Path p, uint256 bps) external {
        if (bps > BPS) revert InvalidBps();
        Config storage c = _cfg[uint256(p)];
        c.taxBps = bps;
        c.random = false;
    }

    /// @notice Exclusive extra charge taken from the sender, in bps of `value` (any size).
    function setExtra(Path p, uint256 extraBps) external {
        _cfg[uint256(p)].extraBps = extraBps;
    }

    /// @notice Absolute amount minted to the recipient on every transfer of this path.
    function setBonus(Path p, uint256 bonus) external {
        _cfg[uint256(p)].bonus = bonus;
    }

    /// @notice Seeded pseudo-random inclusive tax in [minBps, maxBps]; resets the nonce to 0.
    function setRandomTax(Path p, uint256 seed, uint256 minBps, uint256 maxBps) external {
        if (minBps > maxBps || maxBps > BPS) revert InvalidBps();
        Config storage c = _cfg[uint256(p)];
        c.random = true;
        c.seed = seed;
        c.minBps = minBps;
        c.maxBps = maxBps;
        c.nonce = 0;
    }

    /// @notice Append bps values consumed one per transfer, before the random or fixed tax.
    function pushTaxSchedule(Path p, uint256[] calldata bps) external {
        for (uint256 i; i < bps.length; ++i) {
            if (bps[i] > BPS) revert InvalidBps();
            _schedule[uint256(p)].push(bps[i]);
        }
    }

    function config(Path p) external view returns (Config memory) {
        return _cfg[uint256(p)];
    }

    function scheduleRemaining(Path p) external view returns (uint256) {
        return _schedule[uint256(p)].length - _scheduleHead[uint256(p)];
    }

    // ------------------------------------------------------------------
    // ERC-20 overrides
    // ------------------------------------------------------------------

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _spendAllowance(from, _msgSender(), value);
        _move(Path.TransferFrom, from, to, value);
        return true;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        _move(Path.Transfer, _msgSender(), to, value);
        return true;
    }

    function _move(Path p, address from, address to, uint256 value) private {
        uint256 i = uint256(p);
        Config storage c = _cfg[i];
        uint256 bps = _nextTaxBps(i, c);
        lastTaxBps = bps;
        ++callCount[i];

        uint256 fee = Math.mulDiv(value, bps, BPS);
        uint256 extra = c.extraBps == 0 ? 0 : Math.mulDiv(value, c.extraBps, BPS);
        _transfer(from, to, value - fee); // recipient credit (sender debited value - fee)
        if (fee != 0) _burn(from, fee); // inclusive fee: sender's total debit = value
        if (extra != 0) _burn(from, extra); // exclusive extra: sender's total debit = value + extra
        if (c.bonus != 0) _mint(to, c.bonus);
    }

    function _nextTaxBps(uint256 i, Config storage c) private returns (uint256) {
        uint256 head = _scheduleHead[i];
        if (head < _schedule[i].length) {
            _scheduleHead[i] = head + 1;
            return _schedule[i][head];
        }
        if (c.random) {
            uint256 n = c.nonce;
            c.nonce = n + 1;
            return c.minBps + uint256(keccak256(abi.encode(c.seed, n))) % (c.maxBps - c.minBps + 1);
        }
        return c.taxBps;
    }
}
