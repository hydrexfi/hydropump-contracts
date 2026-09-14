// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {HydropumpToken} from "./HydropumpToken.sol";
import {IHydropumpLocker} from "./interfaces/IHydropumpLocker.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {IAlgebraPool} from "./interfaces/IAlgebraPool.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";
import {HydropumpAddresses} from "./libraries/HydropumpAddresses.sol";
import {TickMath} from "./libraries/TickMath.sol";

/// @title HydropumpLauncher
/// @notice Clones an ERC20, opens its pool against a whitelisted quote token, seeds single-sided liquidity
///         bands, and hands every position to the locker permanently.
contract HydropumpLauncher is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    INonfungiblePositionManager public constant nonfungiblePositionManager =
        INonfungiblePositionManager(HydropumpAddresses.NONFUNGIBLE_POSITION_MANAGER);

    ISwapRouter public constant swapRouter = ISwapRouter(HydropumpAddresses.SWAP_ROUTER);

    uint256 public constant SUPPLY = 10_000_000_000e18;

    struct PendingToken {
        string name;
        string symbol;
        uint256 supply;
        address recipient;
    }

    struct QuoteConfig {
        bool enabled;
        int24 startTick;
        uint64 updatedAt;
    }

    struct LaunchParams {
        string name;
        string symbol;
        address quoteToken;
        bytes32 userSalt;
        address creatorRecipient;
        uint256 buyAmount; // 0 to skip
    }

    address public locker;
    uint96 public launchFee;
    address public admin;

    mapping(address quoteToken => QuoteConfig) public quoteTokens;

    /// @dev Set for the duration of one `launch` so the token's argument-less constructor can read it back.
    PendingToken private _pendingToken;

    /// @dev Reserved so added storage does not shift the layout. Keep vars + gap == 50.
    uint256[43] private __gap;

    event Launched(
        address indexed token,
        address indexed creator,
        address indexed quoteToken,
        address pool,
        int24 startTick,
        uint256[] positionIds,
        string name,
        string symbol,
        uint64 timestamp
    );
    event LaunchBought(address indexed token, address indexed buyer, uint256 quoteIn, uint256 tokensOut);
    event LaunchFeeUpdated(uint96 previousFee, uint96 newFee);
    event LaunchFeesClaimed(address indexed to, uint256 amount);
    event QuoteTokenConfigured(address indexed quoteToken, bool enabled, int24 startTick);
    event StartTickUpdated(address indexed quoteToken, int24 previousTick, int24 newTick);
    event AdminUpdated(address indexed previousAdmin, address indexed newAdmin);
    event LockerUpdated(address indexed previousLocker, address indexed newLocker);

    error QuoteTokenNotEnabled();
    error TokenNotBelowQuote();
    error NotAdmin();
    error ZeroAddress();
    error LengthMismatch();
    error StartTickUnset();
    error PoolCreationFailed();
    error InsufficientLaunchFee();
    error TransferFailed();
    error TokenAddressMismatch();
    error QuoteConsumed();

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        address _admin,
        address _locker,
        uint96 _launchFee
    ) external initializer {
        if (_owner == address(0) || _admin == address(0) || _locker == address(0)) revert ZeroAddress();
        __Ownable_init(_owner);
        __Ownable2Step_init();

        admin = _admin;
        locker = _locker;
        launchFee = _launchFee;

        emit AdminUpdated(address(0), _admin);
        emit LockerUpdated(address(0), _locker);
        emit LaunchFeeUpdated(0, _launchFee);
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                 READ
    //////////////////////////////////////////////////////////////*/

    /// @notice Address a launch token will land at, so the frontend can mine `userSalt` up front.
    /// @dev The init code hash is constant, so a salt can be mined before the user picks a name. A salt
    ///      mined for one sender is invalid for another, which stops a mempool watcher burning it.
    function predictToken(address deployer, bytes32 userSalt) public view returns (address) {
        return Create2.computeAddress(_finalSalt(deployer, userSalt), tokenInitCodeHash(), address(this));
    }

    /// @notice Whether a salt yields a token that sorts below `quoteToken`, i.e. one the pool will treat
    ///         as token0. The frontend bumps the salt until this holds.
    function isSaltValid(
        address deployer,
        bytes32 userSalt,
        address quoteToken
    ) external view returns (bool) {
        return predictToken(deployer, userSalt) < quoteToken;
    }

    /// @notice Constant across launches — the token constructor takes no arguments — so a salt mined once
    ///         stays valid regardless of the name and symbol the user later picks.
    function tokenInitCodeHash() public pure returns (bytes32) {
        return keccak256(type(HydropumpToken).creationCode);
    }

    /// @notice Read by a HydropumpToken's constructor, mid-`launch`. Empty at rest.
    function pendingToken() external view returns (string memory, string memory, uint256, address) {
        PendingToken storage pending = _pendingToken;
        return (pending.name, pending.symbol, pending.supply, pending.recipient);
    }

    function bandCount() public pure returns (uint256) {
        return 5;
    }

    /// @notice Band `i` as tick offsets from the start tick, plus its share of supply in bps.
    /// @dev Offsets, never absolute ticks: a tick encodes a raw wei ratio and shifts with the quote token's
    ///      decimals and price. Shares sum to 10000.
    function band(uint256 i) public pure returns (int24 offsetLower, int24 offsetUpper, uint256 shareBps) {
        if (i == 0) return (0, 14_000, 900);
        if (i == 1) return (14_000, 36_000, 2_200);
        if (i == 2) return (36_000, 62_000, 3_000);
        if (i == 3) return (62_000, 92_000, 3_700);
        return (92_000, 887_200, 200);
    }

    /*//////////////////////////////////////////////////////////////
                              USER WRITE
    //////////////////////////////////////////////////////////////*/

    function launch(
        LaunchParams calldata params
    ) external payable returns (address token, address pool, uint256[] memory positionIds) {
        // A minimum, and any surplus is kept. No refund path means no call back into the caller here.
        if (msg.value < launchFee) revert InsufficientLaunchFee();

        QuoteConfig memory quote = quoteTokens[params.quoteToken];
        if (!quote.enabled) revert QuoteTokenNotEnabled();
        if (quote.updatedAt == 0) revert StartTickUnset();

        bytes32 salt = _finalSalt(msg.sender, params.userSalt);
        token = Create2.computeAddress(salt, tokenInitCodeHash(), address(this));
        if (token >= params.quoteToken) revert TokenNotBelowQuote();

        _pendingToken = PendingToken(params.name, params.symbol, SUPPLY, address(this));
        if (address(new HydropumpToken{salt: salt}()) != token) {
            revert TokenAddressMismatch();
        }
        delete _pendingToken;

        pool = nonfungiblePositionManager.createAndInitializePoolIfNecessary(
            token,
            params.quoteToken,
            address(0),
            TickMath.getSqrtRatioAtTick(quote.startTick),
            ""
        );
        if (pool == address(0)) revert PoolCreationFailed();

        positionIds = _mintBands(token, params.quoteToken, pool, quote.startTick);

        if (params.buyAmount > 0) _buy(token, params.quoteToken, params.buyAmount);

        address creatorRecipient = params.creatorRecipient == address(0)
            ? msg.sender
            : params.creatorRecipient;
        IHydropumpLocker(locker).registerLaunch(
            token,
            params.quoteToken,
            pool,
            msg.sender,
            creatorRecipient,
            positionIds
        );

        uint256 dust = IERC20(token).balanceOf(address(this));
        if (dust > 0) IERC20(token).safeTransfer(msg.sender, dust);

        emit Launched(
            token,
            msg.sender,
            params.quoteToken,
            pool,
            quote.startTick,
            positionIds,
            params.name,
            params.symbol,
            uint64(block.timestamp)
        );
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Buys the launch token with the caller's quote, straight after the curve is seeded. No minimum
    ///      out: the pool is created in this same transaction at a start tick fixed before it, so the fill
    ///      is deterministic and there is no position for anyone to trade against first.
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

    /// @dev Bands are aligned to the pool's actual tick spacing and all sit at or above the current tick, so
    ///      every mint is pure token0 — asserted via `QuoteConsumed`, not assumed.
    function _mintBands(
        address token,
        address quoteToken,
        address pool,
        int24 startTick
    ) internal returns (uint256[] memory positionIds) {
        uint256 count = bandCount();
        positionIds = new uint256[](count);

        int24 spacing = IAlgebraPool(pool).tickSpacing();
        int24 maxUsable = (TickMath.MAX_TICK / spacing) * spacing;
        int24 base = _ceilToSpacing(startTick, spacing);

        IERC20(token).forceApprove(address(nonfungiblePositionManager), SUPPLY);

        uint256 assigned;
        for (uint256 i = 0; i < count; i++) {
            (int24 offsetLower, int24 offsetUpper, uint256 shareBps) = band(i);

            int24 tickUpper = base + _floorToSpacing(offsetUpper, spacing);
            if (tickUpper > maxUsable) tickUpper = maxUsable;

            uint256 amount = i == count - 1 ? SUPPLY - assigned : (SUPPLY * shareBps) / 10_000;
            assigned += amount;

            (uint256 positionId, , , uint256 quoteUsed) = nonfungiblePositionManager.mint(
                INonfungiblePositionManager.MintParams({
                    token0: token,
                    token1: quoteToken,
                    deployer: address(0),
                    tickLower: base + _floorToSpacing(offsetLower, spacing),
                    tickUpper: tickUpper,
                    amount0Desired: amount,
                    amount1Desired: 0,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: locker,
                    deadline: block.timestamp
                })
            );
            if (quoteUsed != 0) revert QuoteConsumed();
            positionIds[i] = positionId;
        }

        IERC20(token).forceApprove(address(nonfungiblePositionManager), 0);
    }

    function _finalSalt(address deployer, bytes32 userSalt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(deployer, userSalt));
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

    function _setStartTick(address quoteToken, int24 startTick) internal {
        QuoteConfig storage quote = quoteTokens[quoteToken];
        if (!quote.enabled) revert QuoteTokenNotEnabled();

        emit StartTickUpdated(quoteToken, quote.startTick, startTick);
        quote.startTick = startTick;
        quote.updatedAt = uint64(block.timestamp);
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    function configureQuoteTokens(
        address[] calldata quoteTokenList,
        bool[] calldata enabledList,
        int24[] calldata startTickList
    ) external onlyOwner {
        uint256 length = quoteTokenList.length;
        if (length != enabledList.length || length != startTickList.length) revert LengthMismatch();

        for (uint256 i = 0; i < length; i++) {
            address quoteToken = quoteTokenList[i];
            if (quoteToken == address(0)) revert ZeroAddress();

            quoteTokens[quoteToken] = QuoteConfig({
                enabled: enabledList[i],
                startTick: startTickList[i],
                updatedAt: uint64(block.timestamp)
            });
            emit QuoteTokenConfigured(quoteToken, enabledList[i], startTickList[i]);
        }
    }

    function setStartTicks(
        address[] calldata quoteTokenList,
        int24[] calldata startTickList
    ) external onlyOwner {
        if (quoteTokenList.length != startTickList.length) revert LengthMismatch();
        for (uint256 i = 0; i < quoteTokenList.length; i++) {
            _setStartTick(quoteTokenList[i], startTickList[i]);
        }
    }

    /// @dev Admin-gated, not owner-gated: if the owner could hand itself the admin role it would have the
    ///      upgrade path too, and the split would be decorative.
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
        (bool ok, ) = to.call{value: amount}("");
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
}
