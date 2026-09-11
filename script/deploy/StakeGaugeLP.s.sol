// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IGauge} from "../../contracts/interfaces/IGauge.sol";
import {HydropumpAddresses} from "../../contracts/libraries/HydropumpAddresses.sol";

/// @title StakeGaugeLP
/// @dev Stakes the whole vAMM-HPONE/HPTWO balance into the Hydropump gauge, so the emissions the bribes
///      attract accrue to us rather than to nobody. The pair has no other holder.
contract StakeGaugeLP is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);
        uint256 staked = stake(deployer);
        vm.stopBroadcast();

        console2.log("=== Stake Gauge LP ===");
        console2.log("Staker:  ", deployer);
        console2.log("Gauge:   ", HydropumpAddresses.GAUGE);
        console2.log("Staked:  ", staked);
        console2.log("Gauge total supply:", IGauge(HydropumpAddresses.GAUGE).totalSupply());
    }

    /// @dev Split out so the fork test runs the identical sequence.
    function stake(address staker) public returns (uint256 staked) {
        IERC20 pair = IERC20(HydropumpAddresses.GAUGE_PAIR);
        staked = pair.balanceOf(staker);
        require(staked > 0, "no LP to stake");

        pair.approve(HydropumpAddresses.GAUGE, staked);
        IGauge(HydropumpAddresses.GAUGE).depositAll();
    }
}
