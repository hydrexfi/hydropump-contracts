// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HydropumpGaugeToken} from "../../contracts/HydropumpGaugeToken.sol";
import {IPair} from "../../contracts/interfaces/IPair.sol";
import {IPairFactory} from "../../contracts/interfaces/IPairFactory.sol";
import {HydropumpAddresses} from "../../contracts/libraries/HydropumpAddresses.sol";

/// @title DeployGaugeSeed
/// @dev Deploys the two placeholder tokens, pairs them as a volatile classic LP, and seeds it with the
///      entire supply of both. The deployer ends up holding every LP token, so once a gauge is created for
///      this pair it can stake the lot and collect the emissions the bribes attract.
contract DeployGaugeSeed is Script {
    uint256 internal constant SUPPLY = 1e18;

    function run() public returns (address tokenOne, address tokenTwo, address pair) {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);
        (tokenOne, tokenTwo, pair) = deploy(deployer);
        vm.stopBroadcast();

        (uint256 reserve0, uint256 reserve1,) = IPair(pair).getReserves();
        console2.log("=== Hydropump Gauge Seed ===");
        console2.log("Deployer:       ", deployer);
        console2.log("Hydropump One:  ", tokenOne);
        console2.log("Hydropump Two:  ", tokenTwo);
        console2.log("Pair (volatile):", pair);
        console2.log("Reserves:       ", reserve0, reserve1);
        console2.log("LP to deployer: ", IPair(pair).balanceOf(deployer));
        console2.log("\nNext: create a gauge for the pair via the voter, stake the LP, then point the");
        console2.log("buyback at the gauge's bribe contract with setGaugeBribe.");
    }

    /// @dev Split out so the fork test runs the identical sequence.
    function deploy(address recipient) public returns (address tokenOne, address tokenTwo, address pair) {
        tokenOne = address(new HydropumpGaugeToken("Hydropump One", "HPONE", recipient));
        tokenTwo = address(new HydropumpGaugeToken("Hydropump Two", "HPTWO", recipient));

        pair = IPairFactory(HydropumpAddresses.PAIR_FACTORY).createPair(tokenOne, tokenTwo, false);

        // Classic pairs take their liquidity as a plain transfer followed by mint.
        IERC20(tokenOne).transfer(pair, SUPPLY);
        IERC20(tokenTwo).transfer(pair, SUPPLY);
        IPair(pair).mint(recipient);
    }
}
