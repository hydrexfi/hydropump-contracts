// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title HydropumpFeeEscrow
/// @notice Holds collected fees in isolated accounts until their fixed recipient or strategy is paid.
/// @dev An account is an opaque identifier chosen by an approved depositor. The escrow deliberately knows
///      nothing about launches, LP positions, or what a recipient does after receiving its funds.
contract HydropumpFeeEscrow is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    mapping(address depositor => bool allowed) public depositors;
    mapping(bytes32 account => address depositor) public accountDepositor;
    mapping(bytes32 account => address recipient) public recipient;
    mapping(bytes32 account => mapping(address asset => uint256 amount)) private _claimable;

    event DepositorUpdated(address indexed depositor, bool allowed);
    event RecipientUpdated(bytes32 indexed account, address indexed previousRecipient, address indexed newRecipient);
    event Credited(bytes32 indexed account, address indexed recipient, address indexed asset, uint256 amount);
    event Claimed(bytes32 indexed account, address indexed recipient, address indexed asset, uint256 amount);

    error NotDepositor();
    error ZeroAddress();
    error RecipientMismatch();
    error NotAccountDepositor();

    modifier onlyDepositor() {
        if (!depositors[msg.sender]) revert NotDepositor();
        _;
    }

    constructor(address owner_, address initialDepositor) Ownable(owner_) {
        if (owner_ == address(0) || initialDepositor == address(0)) revert ZeroAddress();
        depositors[initialDepositor] = true;
        emit DepositorUpdated(initialDepositor, true);
    }

    function claimable(bytes32 account, address asset) external view returns (uint256) {
        return _claimable[account][asset];
    }

    /// @notice Pull an asset from an approved depositor and credit the amount actually received.
    function credit(bytes32 account, address recipient_, address asset, uint256 amount)
        external
        onlyDepositor
        nonReentrant
        returns (uint256 received)
    {
        if (recipient_ == address(0) || asset == address(0)) revert ZeroAddress();

        address currentRecipient = recipient[account];
        if (currentRecipient == address(0)) {
            accountDepositor[account] = msg.sender;
            recipient[account] = recipient_;
            emit RecipientUpdated(account, address(0), recipient_);
        } else if (accountDepositor[account] != msg.sender) {
            revert NotAccountDepositor();
        } else if (currentRecipient != recipient_) {
            revert RecipientMismatch();
        }

        if (amount == 0) return 0;

        IERC20 token = IERC20(asset);
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        received = token.balanceOf(address(this)) - beforeBalance;
        _claimable[account][asset] += received;

        emit Credited(account, recipient_, asset, received);
    }

    /// @notice Pay an account to its configured recipient. Anyone may trigger the fixed-destination payout.
    function claim(bytes32 account, address asset) external nonReentrant returns (uint256 amount) {
        amount = _claimable[account][asset];
        if (amount == 0) return 0;

        address recipient_ = recipient[account];
        _claimable[account][asset] = 0;
        IERC20(asset).safeTransfer(recipient_, amount);

        emit Claimed(account, recipient_, asset, amount);
    }

    /// @notice Change where an account pays without moving or re-crediting its existing balance.
    function setRecipient(bytes32 account, address newRecipient) external onlyDepositor {
        if (newRecipient == address(0)) revert ZeroAddress();
        address configuredDepositor = accountDepositor[account];
        if (configuredDepositor == address(0)) accountDepositor[account] = msg.sender;
        else if (configuredDepositor != msg.sender) revert NotAccountDepositor();
        address previousRecipient = recipient[account];
        recipient[account] = newRecipient;
        emit RecipientUpdated(account, previousRecipient, newRecipient);
    }

    function setDepositor(address depositor, bool allowed) external onlyOwner {
        if (depositor == address(0)) revert ZeroAddress();
        depositors[depositor] = allowed;
        emit DepositorUpdated(depositor, allowed);
    }
}
