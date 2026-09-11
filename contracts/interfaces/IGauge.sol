// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Hydrex classic gauge.
interface IGauge {
    function deposit(uint256 amount) external;

    function depositAll() external;

    function withdraw(uint256 amount) external;

    function getReward() external;

    function balanceOf(address account) external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function rewardToken() external view returns (address);

    function earned(address account) external view returns (uint256);
}
