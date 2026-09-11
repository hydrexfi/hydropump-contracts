// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "./MockERC20.sol";

contract MockDistributor {
    function claim(address token, address to, uint256 amount) external {
        MockERC20(token).mint(to, amount);
    }

    function fail() external pure {
        revert("distributor down");
    }
}
