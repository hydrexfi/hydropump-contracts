// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFeeUse} from "../interfaces/IFeeUse.sol";
import {IHydropumpLocker} from "../interfaces/IHydropumpLocker.sol";

/// @title CreatorBalanceFeeUse
/// @notice The plain one: a launch's creator share is paid to its creator.
/// @dev Paid on arrival and nothing is stored. The recipient is read from the locker every call, so a
///      recipient that cannot receive reverts here and leaves the share booked in the locker until
///      `setCreatorRecipient` frees it.
contract CreatorBalanceFeeUse is IFeeUse {
    using SafeERC20 for IERC20;

    IHydropumpLocker public immutable locker;

    mapping(address token => mapping(address asset => uint256)) public lifetimePaid;

    event CreatorPaid(address indexed token, address indexed recipient, address indexed asset, uint256 amount);

    error NotLocker();
    error UnknownLaunch();
    error ZeroAddress();

    constructor(address _locker) {
        if (_locker == address(0)) revert ZeroAddress();
        locker = IHydropumpLocker(_locker);
    }

    function onFees(address token, address[] calldata assets, uint256[] calldata amounts) external {
        if (msg.sender != address(locker)) revert NotLocker();

        address recipient = locker.creatorRecipient(token);
        if (recipient == address(0)) revert UnknownLaunch();

        for (uint256 i = 0; i < assets.length; i++) {
            if (amounts[i] == 0) continue;

            lifetimePaid[token][assets[i]] += amounts[i];
            IERC20(assets[i]).safeTransfer(recipient, amounts[i]);

            emit CreatorPaid(token, recipient, assets[i], amounts[i]);
        }
    }
}
