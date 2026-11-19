// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/// @title MockNoReturnERC20 — ERC-20 whose `transfer`, `transferFrom` and `approve` return NO
///        value (USDT style). TEST-ONLY.
/// @notice Tier 0 economics (debit == credit), non-standard ABI. OpenZeppelin `SafeERC20`
///         treats empty return data from a contract as success, so the Pool must work with it
///         on both the input and the output side (TEST_MATRIX X02, DECISIONS M5-7).
/// @dev Written from scratch because OZ `ERC20` functions cannot be overridden with a different
///      return type. Failures revert with `InsufficientBalance` / `InsufficientAllowance`.
contract MockNoReturnERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance();
    error InsufficientAllowance();

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    /// @notice Test helper; no access control.
    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 value) external {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
    }

    function transfer(address to, uint256 value) external {
        _move(msg.sender, to, value);
    }

    function transferFrom(address from, address to, uint256 value) external {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < value) revert InsufficientAllowance();
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - value;
        _move(from, to, value);
    }

    function _move(address from, address to, uint256 value) private {
        uint256 bal = balanceOf[from];
        if (bal < value) revert InsufficientBalance();
        balanceOf[from] = bal - value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }
}
