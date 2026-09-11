// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {HydropumpLaunchpad} from "../contracts/HydropumpLaunchpad.sol";
import {HydropumpLocker} from "../contracts/HydropumpLocker.sol";

/// @title LaunchToken
/// @dev Calls launch() on an already-deployed launchpad to create a new token, pool, and per-token locker.
///      Set in .env: LAUNCHPAD_ADDRESS, DEPLOYER_KEY, TOKEN_NAME, TOKEN_SYMBOL, TOKEN_IMAGE (optional),
///      FEE_CLAIMER (optional, defaults to the deployer).
contract LaunchToken is Script {
    function run() public {
        address launchpadAddress = vm.envAddress("LAUNCHPAD_ADDRESS");
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        string memory name = vm.envString("TOKEN_NAME");
        string memory symbol = vm.envString("TOKEN_SYMBOL");
        string memory image = vm.envOr("TOKEN_IMAGE", string(""));
        address feeClaimer = vm.envOr("FEE_CLAIMER", deployer);

        HydropumpLaunchpad launchpad = HydropumpLaunchpad(launchpadAddress);

        console2.log("=== Launch Token via Hydropump ===");
        console2.log("Launchpad:", launchpadAddress);
        console2.log("Name:", name);
        console2.log("Symbol:", symbol);
        console2.log("Fee claimer:", feeClaimer);

        vm.startBroadcast(deployerKey);

        (address token, address pool, uint256 tokenId) = launchpad.launch(name, symbol, image, feeClaimer);
        HydropumpLocker locker = launchpad.tokenToLocker(token);

        vm.stopBroadcast();

        console2.log("\n=== Launch Successful ===");
        console2.log("Token:", token);
        console2.log("Pool:", pool);
        console2.log("LP NFT tokenId:", tokenId);
        console2.log("Locker:", address(locker));
        console2.log("\nVerify with:");
        console2.log("  source .env && ./script/verify-launch-base.sh", token, address(locker));
    }
}
