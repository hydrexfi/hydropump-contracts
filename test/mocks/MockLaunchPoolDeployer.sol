// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockAlgebra} from "./MockAlgebra.sol";
import {HydropumpAddresses} from "../../contracts/libraries/HydropumpAddresses.sol";

/// @dev Unit stand-in only. Real creation/plugin/namespace behavior is exercised on Base forks.
contract MockLaunchPoolDeployer {
    address public immutable launcher;
    address public constant algebraFactory = HydropumpAddresses.ALGEBRA_FACTORY;

    constructor(address launcher_) {
        launcher = launcher_;
    }

    function createPool(address token0, address token1) external returns (address) {
        require(msg.sender == launcher, "only launcher");
        return MockAlgebra(HydropumpAddresses.NONFUNGIBLE_POSITION_MANAGER).createAndInitializePoolIfNecessary(
            token0, token1, address(this), 0, ""
        );
    }
}
