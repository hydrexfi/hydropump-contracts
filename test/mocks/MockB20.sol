// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Stand-in for a Base B20 tokenized stock, modelling the behaviours that differ from plain ERC20.
/// @dev B20s are native precompiles with no bytecode, so they cannot execute on a fork. This is etched at a
///      real B20 address to exercise the paths that matter:
///        - a policy-blocked transfer REVERTS rather than returning false
///        - `approve` is NOT policy gated, so an approval succeeding says nothing about the transfer
///        - transfers can be paused by the issuer
///        - multipliers change redemption value only; raw balances never rebase
contract MockB20 {
    string public name = "Mock B20";
    string public symbol = "MB20";
    uint8 public decimals;
    uint256 public totalSupply;
    bool public paused;

    /// @notice WAD-scaled redemption ratio. Corporate actions move this, not balances.
    uint256 public multiplier;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blocked;

    error TransferBlocked(address account);
    error TransferPaused();

    function init(uint8 _decimals) external {
        decimals = _decimals;
        multiplier = 1e18;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function setPaused(bool isPaused) external {
        paused = isPaused;
    }

    function setMultiplier(uint256 newMultiplier) external {
        multiplier = newMultiplier;
    }

    function scaledBalanceOf(address account) external view returns (uint256) {
        return (balanceOf[account] * multiplier) / 1e18;
    }

    /// @dev Deliberately not policy gated, matching the spec.
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (paused) revert TransferPaused();
        if (blocked[from]) revert TransferBlocked(from);
        if (blocked[to]) revert TransferBlocked(to);

        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
