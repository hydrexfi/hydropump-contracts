// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployGaugeSeed} from "../../script/deploy/DeployGaugeSeed.s.sol";
import {HydropumpGaugeToken} from "../../contracts/helpers/HydropumpGaugeToken.sol";
import {IPair} from "../../contracts/interfaces/IPair.sol";
import {IPairFactory} from "../../contracts/interfaces/IPairFactory.sol";
import {HydropumpAddresses} from "../../contracts/libraries/HydropumpAddresses.sol";

/// @notice Runs the gauge seed against the live Hydrex classic factory on Base.
/// @dev Requires BASE_RPC_URL; skipped when unset.
contract GaugeSeedForkTest is Test {
    IPairFactory internal constant FACTORY = IPairFactory(HydropumpAddresses.PAIR_FACTORY);

    DeployGaugeSeed internal seed;
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        seed = new DeployGaugeSeed();
    }

    function test_SeedsAVolatilePairHoldingBothTokens() public {
        if (!forked) {
            vm.skip(true);
        }

        (address tokenOne, address tokenTwo, address pair) = seed.deploy(address(seed));

        // Tokens are fixed supply of exactly 1, all of it deployed into the pair.
        assertEq(IERC20(tokenOne).totalSupply(), 1e18);
        assertEq(IERC20(tokenTwo).totalSupply(), 1e18);
        assertEq(HydropumpGaugeToken(tokenOne).decimals(), 18);
        assertEq(IERC20(tokenOne).balanceOf(pair), 1e18);
        assertEq(IERC20(tokenTwo).balanceOf(pair), 1e18);
        assertEq(IERC20(tokenOne).balanceOf(address(seed)), 0);

        // The factory knows the pair, and it is volatile rather than stable.
        assertEq(FACTORY.getPair(tokenOne, tokenTwo, false), pair);
        assertEq(FACTORY.getPair(tokenOne, tokenTwo, true), address(0), "no stable pair should exist");
        assertFalse(IPair(pair).stable(), "pair must be volatile");

        // The deployer holds every LP token except the burned minimum.
        uint256 lp = IPair(pair).balanceOf(address(seed));
        assertGt(lp, 0);
        assertEq(lp, IPair(pair).totalSupply() - 1_000, "only MINIMUM_LIQUIDITY is withheld");

        (uint256 reserve0, uint256 reserve1,) = IPair(pair).getReserves();
        assertEq(reserve0, 1e18);
        assertEq(reserve1, 1e18);

        console2.log("tokenOne", tokenOne);
        console2.log("tokenTwo", tokenTwo);
        console2.log("pair    ", pair);
        console2.log("lp      ", lp);
    }

    function test_TokensCannotBeMintedAgain() public {
        if (!forked) {
            vm.skip(true);
        }

        (address tokenOne,,) = seed.deploy(address(seed));

        string[3] memory forbidden = ["mint(address,uint256)", "owner()", "mint(uint256)"];
        for (uint256 i = 0; i < forbidden.length; i++) {
            (bool ok,) = tokenOne.call(abi.encodeWithSignature(forbidden[i]));
            assertFalse(ok, forbidden[i]);
        }
        assertEq(IERC20(tokenOne).totalSupply(), 1e18);
    }
}
