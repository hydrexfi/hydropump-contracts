// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {HydropumpToken} from "./HydropumpToken.sol";
import {IHydropumpLocker} from "../interfaces/IHydropumpLocker.sol";
import {IPairDirectory} from "../interfaces/IPairDirectory.sol";
import {IFeeUseRegistry} from "../interfaces/IFeeUseRegistry.sol";
import {INonfungiblePositionManager} from "../interfaces/INonfungiblePositionManager.sol";
import {IAlgebraPool} from "../interfaces/IAlgebraPool.sol";
import {ISwapRouter} from "../interfaces/ISwapRouter.sol";
import {HydropumpAddresses} from "../libraries/HydropumpAddresses.sol";
import {TickMath} from "../libraries/TickMath.sol";

/// @title HydropumpLauncher
/// @notice Clones an ERC20, opens its pool against a whitelisted quote token, seeds single-sided liquidity
///         bands, and hands every position to the locker permanently.
contract HydropumpLauncher is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    INonfungiblePositionManager public constant nonfungiblePositionManager =
        INonfungiblePositionManager(HydropumpAddresses.NONFUNGIBLE_POSITION_MANAGER);

    ISwapRouter public constant swapRouter = ISwapRouter(HydropumpAddresses.SWAP_ROUTER);

    uint256 public constant SUPPLY = 10_000_000_000e18;

    struct LaunchParams {
        string name;
        string symbol;
        address quoteToken;
        address creatorRecipient;
        uint256 buyAmount; // 0 to skip
        bytes32 feeUse;
    }

    address public locker;
    uint96 public launchFee;
    address public admin;
    address public pairDirectory;
    address public feeUseRegistry;

    /// @dev Reserved so added storage does not shift the layout. Keep vars + gap == 50.
    uint256[46] private __gap;

    event Launched(
        address indexed token,
        address indexed creator,
        address indexed quoteToken,
        address pool,
        int24 startTick,
        uint256[] positionIds,
        string name,
        string symbol,
        bytes32 feeUse,
        uint64 timestamp
    );
    event LaunchBought(address indexed token, address indexed buyer, uint256 quoteIn, uint256 tokensOut);
    event LaunchFeeUpdated(uint96 previousFee, uint96 newFee);
    event LaunchFeesClaimed(address indexed to, uint256 amount);
    event AdminUpdated(address indexed previousAdmin, address indexed newAdmin);
    event LockerUpdated(address indexed previousLocker, address indexed newLocker);
    event PairDirectoryUpdated(address indexed previousDirectory, address indexed newDirectory);
    event FeeUseRegistryUpdated(address indexed previousRegistry, address indexed newRegistry);

    error NotAdmin();
    error ZeroAddress();
    error PoolCreationFailed();
    error InsufficientLaunchFee();
    error TransferFailed();
    error QuoteConsumed();
    error BandOutOfRange();
    error DirectoryUnset();

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner, address _admin, address _locker, address _pairDirectory, uint96 _launchFee)
        external
        initializer
    {
        if (_owner == address(0) || _admin == address(0) || _locker == address(0) || _pairDirectory == address(0)) {
            revert ZeroAddress();
        }
        __Ownable_init(_owner);
        __Ownable2Step_init();

        admin = _admin;
        locker = _locker;
        pairDirectory = _pairDirectory;
        launchFee = _launchFee;

        emit AdminUpdated(address(0), _admin);
        emit LockerUpdated(address(0), _locker);
        emit PairDirectoryUpdated(address(0), _pairDirectory);
        emit LaunchFeeUpdated(0, _launchFee);
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                 READ
    //////////////////////////////////////////////////////////////*/

    /// @notice Whether the launch token sits on the token0 side of its pool, which is what decides the
    ///         direction the curve is mirrored in.
    function launchIsToken0(address token, address quoteToken) public pure returns (bool) {
        return token < quoteToken;
    }

    /// @notice The tick the pool for this pair will actually open at.
    function poolStartTick(address token, address quoteToken) public view returns (int24) {
        return IPairDirectory(pairDirectory).requirePoolStartTick(token, quoteToken);
    }

    /// @notice Whether a quote token can be launched against right now.
    function isQuoteEnabled(address quoteToken) external view returns (bool) {
        return IPairDirectory(pairDirectory).isEnabled(quoteToken);
    }

    function bandCount() public pure returns (uint256) {
        return 5;
    }

    /// @notice Band `i` as unsigned tick distances from the start tick, plus its share of supply in bps.
    /// @dev The four priced bands hold 0.6074 of what they used to, which scales the quote needed to
    ///      reach any price by the same factor — cost is the integral of the curve below it, and that is
    ///      linear in the tokens each band holds. A launch reaches $1m of valuation on about $70k of net
    ///      buying rather than $115k, having sold a third of its supply rather than half.
    ///
    ///      What those bands give up goes to the tail, which is why the tail now starts at 150k rather
    ///      than 92k: parked against the old boundary it made everything past ~$50m roughly twenty times
    ///      harder, a wall rather than a book. Spread to 150k it is about 1.5x, and pushing the boundary
    ///      further buys almost nothing.
    /// @dev Offsets, never absolute ticks: a tick encodes a raw wei ratio and shifts with the quote token's
    ///      decimals and price. Unsigned, never signed: the direction they run in is not a property of the
    ///      curve but of which side of the pair the launch token landed on, and `_mintBands` applies it.
    ///      Band 0 is always the one adjacent to the start price. Shares sum to 10000.
    function band(uint256 i) public pure returns (int24 offsetLower, int24 offsetUpper, uint256 shareBps) {
        if (i == 0) return (0, 14_000, 547);
        if (i == 1) return (14_000, 36_000, 1_336);
        if (i == 2) return (36_000, 62_000, 1_822);
        if (i == 3) return (62_000, 150_000, 2_247);
        return (150_000, 887_200, 4_048);
    }

    /*//////////////////////////////////////////////////////////////
                              USER WRITE
    //////////////////////////////////////////////////////////////*/

    function launch(LaunchParams calldata params)
        external
        payable
        returns (address token, address pool, uint256[] memory positionIds)
    {
        // A minimum, and any surplus is kept. No refund path means no call back into the caller here.
        if (msg.value < launchFee) revert InsufficientLaunchFee();

        address directory = pairDirectory;
        if (directory == address(0)) revert DirectoryUnset();

        token = address(new HydropumpToken(params.name, params.symbol, SUPPLY));

        bool isToken0 = token < params.quoteToken;
        int24 startTick = IPairDirectory(directory).requirePoolStartTick(token, params.quoteToken);

        (address token0, address token1) = isToken0 ? (token, params.quoteToken) : (params.quoteToken, token);

        pool = nonfungiblePositionManager.createAndInitializePoolIfNecessary(
            token0, token1, address(0), TickMath.getSqrtRatioAtTick(startTick), ""
        );
        if (pool == address(0)) revert PoolCreationFailed();

        positionIds = _mintBands(token, params.quoteToken, pool, startTick, isToken0);

        if (params.buyAmount > 0) _buy(token, params.quoteToken, params.buyAmount);

        address creatorRecipient = params.creatorRecipient == address(0) ? msg.sender : params.creatorRecipient;
        IHydropumpLocker(locker)
            .registerLaunch(token, params.quoteToken, pool, msg.sender, creatorRecipient, positionIds);

        if (feeUseRegistry != address(0)) {
            IFeeUseRegistry(feeUseRegistry).setLaunchFeeUse(token, params.feeUse);
        }

        // Rounding from minting five bands. Burnt rather than paid out, so a launch's supply is only
        // ever what reached the pool and nobody starts holding a balance they did not buy.
        uint256 dust = IERC20(token).balanceOf(address(this));
        if (dust > 0) HydropumpToken(token).burn(dust);

        emit Launched(
            token,
            msg.sender,
            params.quoteToken,
            pool,
            startTick,
            positionIds,
            params.name,
            params.symbol,
            params.feeUse,
            uint64(block.timestamp)
        );
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Buys the launch token with the caller's quote, straight after the curve is seeded.
    function _buy(address token, address quoteToken, uint256 buyAmount) internal {
        IERC20(quoteToken).safeTransferFrom(msg.sender, address(this), buyAmount);
        IERC20(quoteToken).forceApprove(address(swapRouter), buyAmount);

        uint256 tokensOut = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: quoteToken,
                tokenOut: token,
                deployer: address(0),
                recipient: msg.sender,
                deadline: block.timestamp,
                amountIn: buyAmount,
                amountOutMinimum: 0,
                limitSqrtPrice: 0
            })
        );

        IERC20(quoteToken).forceApprove(address(swapRouter), 0);
        emit LaunchBought(token, msg.sender, buyAmount, tokensOut);
    }

    /// @dev Bands are aligned to the pool's actual tick spacing and all sit on the launch token's side of the
    ///      current tick, so every mint is pure launch token.
    function _mintBands(address token, address quoteToken, address pool, int24 startTick, bool isToken0)
        internal
        returns (uint256[] memory positionIds)
    {
        uint256 count = bandCount();
        positionIds = new uint256[](count);

        int24 spacing = IAlgebraPool(pool).tickSpacing();
        int24 maxUsable = (TickMath.MAX_TICK / spacing) * spacing;
        int24 base = isToken0 ? _ceilToSpacing(startTick, spacing) : _floorToSpacing(startTick, spacing);

        (address token0, address token1) = isToken0 ? (token, quoteToken) : (quoteToken, token);

        IERC20(token).forceApprove(address(nonfungiblePositionManager), SUPPLY);

        uint256 assigned;
        for (uint256 i = 0; i < count; i++) {
            (int24 offsetLower, int24 offsetUpper, uint256 shareBps) = band(i);
            int24 nearOffset = _floorToSpacing(offsetLower, spacing);
            int24 farOffset = _floorToSpacing(offsetUpper, spacing);

            int24 tickLower;
            int24 tickUpper;
            if (isToken0) {
                tickLower = base + nearOffset;
                tickUpper = base + farOffset;
                if (tickUpper > maxUsable) tickUpper = maxUsable;
            } else {
                tickUpper = base - nearOffset;
                tickLower = base - farOffset;
                if (tickLower < -maxUsable) tickLower = -maxUsable;
            }
            // Only reachable from a start tick so close to the usable edge that the tail clamps past its own
            // lower bound. Caught here rather than left to fail somewhere inside the position manager.
            if (tickLower >= tickUpper) revert BandOutOfRange();

            uint256 amount = i == count - 1 ? SUPPLY - assigned : (SUPPLY * shareBps) / 10_000;
            assigned += amount;

            (uint256 positionId,, uint256 used0, uint256 used1) = nonfungiblePositionManager.mint(
                INonfungiblePositionManager.MintParams({
                    token0: token0,
                    token1: token1,
                    deployer: address(0),
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    amount0Desired: isToken0 ? amount : 0,
                    amount1Desired: isToken0 ? 0 : amount,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: locker,
                    deadline: block.timestamp
                })
            );
            if ((isToken0 ? used1 : used0) != 0) revert QuoteConsumed();
            positionIds[i] = positionId;
        }

        IERC20(token).forceApprove(address(nonfungiblePositionManager), 0);
    }

    /// @dev Solidity's `/` truncates toward zero, so negative ticks need the explicit floor.
    function _floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 quotient = tick / spacing;
        if (tick < 0 && quotient * spacing != tick) quotient -= 1;
        return quotient * spacing;
    }

    function _ceilToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 floored = _floorToSpacing(tick, spacing);
        return floored == tick ? tick : floored + spacing;
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        emit AdminUpdated(admin, newAdmin);
        admin = newAdmin;
    }

    function setLaunchFee(uint96 newLaunchFee) external onlyAdmin {
        emit LaunchFeeUpdated(launchFee, newLaunchFee);
        launchFee = newLaunchFee;
    }

    /// @notice Sweep collected launch fees.
    function claimLaunchFees(address to) external onlyAdmin returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();

        amount = address(this).balance;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit LaunchFeesClaimed(to, amount);
    }

    /// @dev Admin-gated, not owner-gated. Repointing the locker redirects where every future launch's
    ///      liquidity is locked, so it sits with the Safe rather than the key that runs the daily jobs.
    function setLocker(address newLocker) external onlyAdmin {
        if (newLocker == address(0)) revert ZeroAddress();
        emit LockerUpdated(locker, newLocker);
        locker = newLocker;
    }

    /// @dev Admin-gated. The directory sets the price every launch opens at, so repointing it is the same
    ///      authority as repointing the curve itself — not something the daily refresh key should hold.
    function setPairDirectory(address newDirectory) external onlyAdmin {
        if (newDirectory == address(0)) revert ZeroAddress();
        emit PairDirectoryUpdated(pairDirectory, newDirectory);
        pairDirectory = newDirectory;
    }

    /// @dev Allowed to be zero: a launcher with no registry still launches, it just leaves every launch
    ///      on whatever default the registry is later given.
    function setFeeUseRegistry(address newRegistry) external onlyAdmin {
        emit FeeUseRegistryUpdated(feeUseRegistry, newRegistry);
        feeUseRegistry = newRegistry;
    }
}
