// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal view of a Hydrex gauge bribe contract
interface IBribe {
    function notifyRewardAmount(address _rewardsToken, uint256 reward) external;
}
