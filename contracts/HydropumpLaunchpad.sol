// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {IAlgebraPool} from "./interfaces/IAlgebraPool.sol";
import {HydropumpToken} from "./HydropumpToken.sol";
import {HydropumpLocker} from "./HydropumpLocker.sol";
import {HydropumpAddresses} from "./libraries/HydropumpAddresses.sol";

/// @title HydropumpLaunchpad
/// @notice Permissionless token launchpad: every launch is paired with WETH on Hydrex
/// @dev Deploys the token, creates and seeds the pool with single-sided liquidity, then locks the LP NFT in a
///      dedicated HydropumpLocker owned by `vaultOwner`.
contract HydropumpLaunchpad {
    INonfungiblePositionManager public constant nonfungiblePositionManager =
        INonfungiblePositionManager(HydropumpAddresses.NONFUNGIBLE_POSITION_MANAGER);
    address public constant WETH = HydropumpAddresses.WETH;

    /// @notice Total supply minted per launch: 1 billion tokens
    uint256 public constant DEFAULT_SUPPLY = 1_000_000_000 * 1e18;

    /// @notice Width of the single-sided liquidity range, in ticks, relative to the initial tick
    int24 public constant TICK_LOWER_OFFSET = -105972; // Range below current
    int24 public constant TICK_UPPER_OFFSET = 105972; // Range above current

    /// @notice Tick spacing used by Hydrex base pools
    int24 public constant TICK_SPACING = 60;

    /// @notice Owner set on each per-token locker (e.g. multisig / governance). Updatable by the current vault owner.
    address public vaultOwner;

    /// @notice Launch details stored for historical queries
    struct LaunchDetails {
        address token;
        address pool;
        address creator;
        address feeClaimer;
        uint256 tokenId;
        uint128 liquidity;
        address locker; // per-token locker holding this launch's LP NFT
        string name;
        string symbol;
        string image;
        uint256 timestamp;
    }

    /// @notice Array of all launches
    LaunchDetails[] public launches;

    /// @notice Mapping from token address to launch index + 1 (0 = not found)
    mapping(address => uint256) public tokenToLaunchIndex;

    /// @notice Mapping from token address to its locker
    mapping(address => HydropumpLocker) public tokenToLocker;

    /// @notice Emitted when the vault owner is updated
    event VaultOwnerUpdated(address indexed previousVaultOwner, address indexed newVaultOwner);

    /// @notice Emitted when a new token is launched
    event TokenLaunched(
        address indexed token,
        address indexed pool,
        address indexed creator,
        address feeClaimer,
        uint256 tokenId,
        uint128 liquidity,
        address locker,
        string image
    );

    constructor(address _vaultOwner) {
        require(_vaultOwner != address(0), "Invalid vault owner");
        vaultOwner = _vaultOwner;
    }

    // =============================
    //  VIEW
    // =============================

    /// @notice Get total number of launches
    /// @return Total launch count
    function getTotalLaunches() external view returns (uint256) {
        return launches.length;
    }

    /// @notice Get launch details for a specific token
    /// @param token The token address
    /// @return details The launch details
    function getLaunchByToken(address token) external view returns (LaunchDetails memory details) {
        uint256 indexPlusOne = tokenToLaunchIndex[token];
        require(indexPlusOne > 0, "Token not launched");
        return launches[indexPlusOne - 1];
    }

    /// @notice Get launch details by index
    /// @param index The launch index
    /// @return details The launch details
    function getLaunchByIndex(uint256 index) external view returns (LaunchDetails memory details) {
        require(index < launches.length, "Index out of bounds");
        return launches[index];
    }

    /// @notice Get paginated launch details
    /// @param skip Number of launches to skip
    /// @param limit Maximum number of launches to return
    /// @return launchList Array of launch details
    /// @return total Total number of launches
    function getLaunches(uint256 skip, uint256 limit)
        external
        view
        returns (LaunchDetails[] memory launchList, uint256 total)
    {
        total = launches.length;

        if (skip >= total) {
            return (new LaunchDetails[](0), total);
        }

        uint256 remaining = total - skip;
        uint256 size = remaining < limit ? remaining : limit;

        launchList = new LaunchDetails[](size);
        for (uint256 i = 0; i < size; i++) {
            launchList[i] = launches[skip + i];
        }

        return (launchList, total);
    }

    /// @notice Get latest launches (most recent first)
    /// @param limit Maximum number of launches to return
    /// @return launchList Array of launch details in reverse chronological order
    function getLatestLaunches(uint256 limit) external view returns (LaunchDetails[] memory launchList) {
        uint256 total = launches.length;
        if (total == 0) {
            return new LaunchDetails[](0);
        }

        uint256 size = total < limit ? total : limit;
        launchList = new LaunchDetails[](size);

        for (uint256 i = 0; i < size; i++) {
            launchList[i] = launches[total - 1 - i];
        }

        return launchList;
    }

    // =============================
    //  WRITE
    // =============================

    /// @notice Launch a new token paired with WETH
    /// @param name The token name
    /// @param symbol The token symbol
    /// @param image IPFS hash or URL for the token image
    /// @param feeClaimer Address that can claim LP fees (receives 50%; the other 50% goes to savings for bribes);
    ///        updatable by the current fee claimer
    /// @return token The deployed token address
    /// @return pool The created pool address
    /// @return tokenId The LP position NFT ID
    function launch(string memory name, string memory symbol, string memory image, address feeClaimer)
        external
        returns (address token, address pool, uint256 tokenId)
    {
        require(feeClaimer != address(0), "Invalid fee claimer");

        // Deploy token with entire supply to this contract
        address[] memory recipients = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        recipients[0] = address(this);
        amounts[0] = DEFAULT_SUPPLY;

        token = address(new HydropumpToken(name, symbol, recipients, amounts));

        // Determine token ordering (token0 < token1 by address)
        address token0 = token < WETH ? token : WETH;
        address token1 = token < WETH ? WETH : token;

        // Starting price: 0.000000010869565 WETH per launch token (FDV $25K with 1B supply)
        // Pool price = token1/token0
        uint160 sqrtPriceX96;
        if (token == token0) {
            // Launch token is token0, WETH is token1
            // Pool price = WETH/LaunchToken = 0.000000010869565
            sqrtPriceX96 = 8260106941740260000000000; // sqrt(0.000000010869565) * 2^96, tick -183383
        } else {
            // Launch token is token1, WETH is token0
            // Pool price = LaunchToken/WETH = 1/0.000000010869565 = 92000000
            sqrtPriceX96 = 760055264584471100000000000000000; // sqrt(92000000) * 2^96, tick 183383
        }

        // Create and initialize the Hydrex pool via the position manager
        pool = nonfungiblePositionManager.createAndInitializePoolIfNecessary(
            token0,
            token1,
            address(0), // Base pool deployer
            sqrtPriceX96,
            "" // Empty data for plugin initialization
        );
        require(pool != address(0), "Pool creation failed");

        // Get current tick from pool
        (, int24 currentTick,,,,) = IAlgebraPool(pool).globalState();

        int24 tickLower;
        int24 tickUpper;

        if (token == token1) {
            // Launch token is token1 - need range BELOW current tick
            // Current tick is positive (e.g., 183383), we add range below
            tickUpper = ((currentTick / TICK_SPACING) - 1) * TICK_SPACING;
            tickLower = tickUpper + TICK_LOWER_OFFSET; // TICK_LOWER_OFFSET is negative
            tickLower = (tickLower / TICK_SPACING) * TICK_SPACING;
        } else {
            // Launch token is token0 - need range ABOVE current tick
            // Current tick is negative (e.g., -183383), we add range above
            tickLower = ((currentTick / TICK_SPACING) + 1) * TICK_SPACING;
            tickUpper = tickLower + TICK_UPPER_OFFSET; // TICK_UPPER_OFFSET is positive
            tickUpper = (tickUpper / TICK_SPACING) * TICK_SPACING;
        }

        // Approve position manager
        IERC20(token).approve(address(nonfungiblePositionManager), DEFAULT_SUPPLY);

        // All tokens go in as single-sided liquidity
        uint256 amount0Desired = token == token0 ? DEFAULT_SUPPLY : 0;
        uint256 amount1Desired = token == token1 ? DEFAULT_SUPPLY : 0;

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            deployer: address(0), // Base pool
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this), // Mint to launchpad first
            deadline: block.timestamp
        });

        // Mint position - LP NFT comes to the launchpad
        uint128 liquidity;
        (tokenId, liquidity,,) = nonfungiblePositionManager.mint(mintParams);

        // Deploy a dedicated locker for this launch and transfer the NFT into it
        HydropumpLocker locker = new HydropumpLocker(vaultOwner);
        nonfungiblePositionManager.safeTransferFrom(
            address(this), address(locker), tokenId, abi.encode(feeClaimer, token)
        );

        // Refund any unused tokens to the caller
        uint256 remainingBalance = IERC20(token).balanceOf(address(this));
        if (remainingBalance > 0) {
            IERC20(token).transfer(msg.sender, remainingBalance);
        }

        // Store launch details and locker
        launches.push(
            LaunchDetails({
                token: token,
                pool: pool,
                creator: msg.sender,
                feeClaimer: feeClaimer,
                tokenId: tokenId,
                liquidity: liquidity,
                locker: address(locker),
                name: name,
                symbol: symbol,
                image: image,
                timestamp: block.timestamp
            })
        );

        tokenToLaunchIndex[token] = launches.length; // Store index + 1
        tokenToLocker[token] = locker;

        emit TokenLaunched(token, pool, msg.sender, feeClaimer, tokenId, liquidity, address(locker), image);
    }

    /// @notice Update the vault owner used as owner for each new per-token locker. Callable only by the current owner.
    function setVaultOwner(address newVaultOwner) external {
        require(msg.sender == vaultOwner, "Not vault owner");
        require(newVaultOwner != address(0), "Invalid vault owner");
        address previous = vaultOwner;
        vaultOwner = newVaultOwner;
        emit VaultOwnerUpdated(previous, newVaultOwner);
    }
}
