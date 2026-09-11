// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HydropumpLaunchpad} from "../../contracts/HydropumpLaunchpad.sol";
import {HydropumpLocker} from "../../contracts/HydropumpLocker.sol";
import {IAlgebraPool} from "../../contracts/interfaces/IAlgebraPool.sol";
import {INonfungiblePositionManager} from "../../contracts/interfaces/INonfungiblePositionManager.sol";
import {HydropumpAddresses} from "../../contracts/libraries/HydropumpAddresses.sol";

/// @notice End-to-end launch against live Hydrex contracts on Base.
/// @dev Requires BASE_RPC_URL; skipped when it is unset so `forge test` stays offline-clean.
contract HydropumpLaunchForkTest is Test {
    HydropumpLaunchpad internal launchpad;

    address internal vaultOwner = makeAddr("vaultOwner");
    address internal creator = makeAddr("creator");
    address internal feeClaimer = makeAddr("feeClaimer");

    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;

        vm.createSelectFork(rpc);
        forked = true;
        launchpad = new HydropumpLaunchpad(vaultOwner);
    }

    function test_LaunchCreatesPoolAndLocksLiquidity() public {
        if (!forked) {
            vm.skip(true);
        }

        vm.prank(creator);
        (address token, address pool, uint256 tokenId) = launchpad.launch("Alpha", "ALPHA", "ipfs://alpha", feeClaimer);

        // Pool is live and paired with WETH
        assertTrue(pool != address(0), "pool not created");
        address token0 = IAlgebraPool(pool).token0();
        address token1 = IAlgebraPool(pool).token1();
        assertTrue(token0 == token || token1 == token, "launch token not in pool");
        assertTrue(token0 == HydropumpAddresses.WETH || token1 == HydropumpAddresses.WETH, "pool not paired with WETH");
        assertGt(IAlgebraPool(pool).liquidity() + 1, 0);

        // Entire supply went into the position; the launchpad keeps nothing
        assertEq(IERC20(token).totalSupply(), launchpad.DEFAULT_SUPPLY());
        assertEq(IERC20(token).balanceOf(address(launchpad)), 0);

        // LP NFT is locked in a per-launch locker owned by the vault owner
        HydropumpLocker locker = launchpad.tokenToLocker(token);
        assertTrue(address(locker) != address(0), "locker not deployed");
        assertEq(locker.getNFTId(), tokenId);
        assertEq(locker.getLaunchToken(), token);
        assertEq(locker.feeClaimer(), feeClaimer);
        assertEq(locker.owner(), vaultOwner);

        (,,,,,,, uint128 liquidity,,,,) =
            INonfungiblePositionManager(HydropumpAddresses.NONFUNGIBLE_POSITION_MANAGER).positions(tokenId);
        assertGt(liquidity, 0, "no liquidity minted");

        // Bookkeeping
        assertEq(launchpad.getTotalLaunches(), 1);
        HydropumpLaunchpad.LaunchDetails memory details = launchpad.getLaunchByToken(token);
        assertEq(details.creator, creator);
        assertEq(details.pool, pool);
        assertEq(details.locker, address(locker));
        assertEq(details.symbol, "ALPHA");
        assertEq(details.image, "ipfs://alpha");
    }
}
