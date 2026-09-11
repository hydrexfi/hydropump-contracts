// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockBribe {
    mapping(address => uint256) public received;

    function notifyRewardAmount(address rewardsToken, uint256 reward) external {
        received[rewardsToken] += reward;
        IERC20(rewardsToken).transferFrom(msg.sender, address(this), reward);
    }
}
