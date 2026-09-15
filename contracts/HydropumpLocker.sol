// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {IHydropumpLocker} from "./interfaces/IHydropumpLocker.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {HydropumpAddresses} from "./libraries/HydropumpAddresses.sol";
import {HydropumpFeeEscrow} from "./HydropumpFeeEscrow.sol";
import {IAlgebraPool} from "./interfaces/IAlgebraPool.sol";
import {HydropumpStakingRewards} from "./HydropumpStakingRewards.sol";

/// @title HydropumpLocker
/// @notice Holds every launch's positions permanently and splits their fees.
contract HydropumpLocker is
    Initializable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    IERC721Receiver,
    IHydropumpLocker
{
    using SafeERC20 for IERC20;

    INonfungiblePositionManager public constant nonfungiblePositionManager =
        INonfungiblePositionManager(HydropumpAddresses.NONFUNGIBLE_POSITION_MANAGER);

    /// @notice Cap on positions per launch, bounding `collect`'s loop and the mask width
    uint256 public constant MAX_POSITIONS = 12;
    bytes32 public constant PROTOCOL_ACCOUNT = keccak256("HYDROPUMP_PROTOCOL_FEES");
    uint8 public constant AUTO_LP_ROUTE = 1;
    uint8 public constant STAKING_REWARDS_ROUTE = 2;
    uint8 public constant VEHYDX_INCENTIVES_ROUTE = 3;
    uint8 public constant DIRECT_RECIPIENT_ROUTE = 4;

    struct ClaimableFees {
        address launchToken;
        address quoteToken;
        uint256 launchTokenAmount;
        uint256 quoteAmount;
    }

    /// @notice Gross fees a launch has ever collected, before the creator/protocol split.
    /// @dev Packed into one slot, so recording it costs a single SSTORE per `collect`. uint128 holds 3.4e38;
    ///      an entire 10B/18-decimal supply is 1e28, so the headroom is ten orders of magnitude.
    struct FeeTotals {
        uint128 launchToken;
        uint128 quote;
    }

    struct FeeAllocation {
        uint64 creatorBps;
        uint64 protocolBps;
        uint64 autoLpBps;
        uint64 stakingRewardsBps;
        uint64 veHydxIncentivesBps;
        uint64 directRecipientBps;
    }

    struct Launch {
        address quoteToken;
        address pool;
        address creator;
        address creatorRecipient;
        uint64 createdAt;
        uint256[] positionIds;
    }

    address public launcher;
    uint64 public creatorFee;
    address public protocolFeeRecipient;
    uint64 public protocolFee;

    mapping(address token => Launch) internal _launches;
    /// @dev Legacy in-locker balances are retained in their original storage slots for upgrade safety.
    mapping(address token => mapping(address asset => uint256 amount)) private _legacyCreatorOwed;

    /// @notice Protocol share awaiting the buyback, per asset. Pooled across launches: it all goes to one
    ///         place, so there is nothing to gain from tracking which launch produced it.
    mapping(address asset => uint256 amount) private _legacyProtocolOwed;

    /// @notice Lifetime gross fees per launch. Kept in storage, unlike the split — which the events already
    ///         carry — because claiming zeroes `creatorOwed`, so nothing else survives to say what a launch
    ///         has earned. It is the only honest measure of a launch's real volume, and it is monotonic.
    mapping(address token => FeeTotals) public lifetimeFees;

    /// @notice External custody and accounting for fees collected after it is configured.
    HydropumpFeeEscrow public feeEscrow;

    /// @notice Per-launch strategy allowed only to add liquidity to an existing active position.
    mapping(address token => address strategy) public autoLpStrategy;
    mapping(address token => FeeAllocation allocation) public feeAllocation;
    /// @notice Lifetime fees assigned to active-band auto-LP, before compounding.
    mapping(address token => FeeTotals) public lifetimeAutoLpFees;
    mapping(address token => IHydropumpLocker.FeeRoute[] routes) internal _feeRoutes;
    mapping(address token => address strategy) public stakingRewardsStrategy;
    mapping(address token => FeeTotals) public lifetimeStakingRewardsFees;
    mapping(address token => address strategy) public veHydxIncentivesStrategy;
    mapping(address token => FeeTotals) public lifetimeVeHydxIncentivesFees;
    mapping(address token => address recipient) public directFeeRecipient;
    mapping(address token => FeeTotals) public lifetimeDirectRecipientFees;

    /// @dev Reserved so added storage does not shift the layout. Keep vars + gap == 50.
    uint256[33] private __gap;

    event LaunchRegistered(
        address indexed token,
        address indexed creator,
        address indexed quoteToken,
        address pool,
        uint256[] positionIds,
        uint64 timestamp
    );
    event FeesCollected(
        address indexed token,
        uint256 positionMask,
        uint256 amount0,
        uint256 amount1,
        uint256 creator0,
        uint256 creator1,
        uint256 protocol0,
        uint256 protocol1
    );
    event CreatorAccrued(address indexed token, address indexed recipient, address indexed asset, uint256 amount);
    event CreatorClaimed(address indexed token, address indexed recipient, address indexed asset, uint256 amount);
    event ProtocolAccrued(address indexed asset, uint256 amount);
    event ProtocolSwept(address indexed recipient, address indexed asset, uint256 amount);
    event CreatorRecipientUpdated(address indexed token, address indexed from, address indexed to);
    event FeeSplitUpdated(uint64 creatorFee, uint64 protocolFee);
    event LauncherUpdated(address indexed previousLauncher, address indexed newLauncher);
    event ProtocolFeeRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);
    event FeeEscrowSet(address indexed feeEscrow);
    event AutoLpStrategySet(address indexed token, address indexed strategy);
    event AutoLpAccrued(address indexed token, address indexed strategy, address indexed asset, uint256 amount);
    event FeeRouteRegistered(address indexed token, uint8 indexed routeType, uint64 bps, address strategy);
    event StakingRewardsAccrued(address indexed token, address indexed strategy, address indexed asset, uint256 amount);
    event VeHydxIncentivesAccrued(
        address indexed token, address indexed strategy, address indexed asset, uint256 amount
    );
    event DirectRecipientAccrued(
        address indexed token, address indexed recipient, address indexed asset, uint256 amount
    );
    event LiquidityCompounded(
        address indexed token, uint256 indexed positionId, uint256 amount0, uint256 amount1, uint128 liquidity
    );

    error NotLauncher();
    error NotNFTPositionManager();
    error NotCreatorRecipient();
    error AlreadyRegistered();
    error UnknownLaunch();
    error ZeroAddress();
    error EmptyMask();
    error InvalidPositionCount();
    error InvalidFeeSplit();
    error FeeEscrowAlreadySet();
    error NotAutoLpStrategy();
    error AutoLpStrategyAlreadySet();
    error InvalidPositionIndex();
    error PositionNotActive();
    error TickDeviationExceeded();
    error InvalidFeeRouteAllocation();
    error FeeEscrowNotSet();
    error UnsupportedFeeRoute();
    error DuplicateFeeRoute();
    error InvalidFeeRouteStrategy();

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        address _launcher,
        address _protocolFeeRecipient,
        uint64 _creatorFee,
        uint64 _protocolFee
    ) external initializer {
        if (_owner == address(0) || _protocolFeeRecipient == address(0)) revert ZeroAddress();
        __Ownable_init(_owner);
        __Ownable2Step_init();

        launcher = _launcher;
        protocolFeeRecipient = _protocolFeeRecipient;
        _setFeeSplit(_creatorFee, _protocolFee);

        emit LauncherUpdated(address(0), _launcher);
        emit ProtocolFeeRecipientUpdated(address(0), _protocolFeeRecipient);
    }

    /*//////////////////////////////////////////////////////////////
                                 READ
    //////////////////////////////////////////////////////////////*/

    function getLaunch(address token) external view returns (Launch memory) {
        return _launches[token];
    }

    function getPositions(address token) external view returns (uint256[] memory) {
        return _launches[token].positionIds;
    }

    function positionCount(address token) external view returns (uint256) {
        return _launches[token].positionIds.length;
    }

    /// @notice Mask selecting every position of a launch.
    function fullMask(address token) public view returns (uint256) {
        uint256 count = _launches[token].positionIds.length;
        return count == 0 ? 0 : (uint256(1) << count) - 1;
    }

    /// @notice Fees already collected and credited to a launch's creator, ready to claim right now.
    /// @dev Excludes fees still sitting uncollected in the positions — see `totalOwed` for those.
    function claimable(address token) public view returns (ClaimableFees memory) {
        address quoteToken = _launches[token].quoteToken;
        return ClaimableFees({
            launchToken: token,
            quoteToken: quoteToken,
            launchTokenAmount: creatorOwed(token, token),
            quoteAmount: creatorOwed(token, quoteToken)
        });
    }

    function creatorAccount(address token) public pure returns (bytes32) {
        return keccak256(abi.encode("HYDROPUMP_CREATOR_FEES", token));
    }

    function autoLpAccount(address token) public pure returns (bytes32) {
        return keccak256(abi.encode("HYDROPUMP_AUTO_LP_FEES", token));
    }

    function stakingRewardsAccount(address token) public pure returns (bytes32) {
        return keccak256(abi.encode("HYDROPUMP_STAKING_REWARDS", token));
    }

    function veHydxIncentivesAccount(address token) public pure returns (bytes32) {
        return keccak256(abi.encode("HYDROPUMP_VEHYDX_INCENTIVES", token));
    }

    function directRecipientAccount(address token) public pure returns (bytes32) {
        return keccak256(abi.encode("HYDROPUMP_DIRECT_RECIPIENT_FEES", token));
    }

    function getFeeRoutes(address token) external view returns (IHydropumpLocker.FeeRoute[] memory) {
        return _feeRoutes[token];
    }

    /// @notice Creator balance across legacy locker storage and the external fee escrow.
    function creatorOwed(address token, address asset) public view returns (uint256 amount) {
        amount = _legacyCreatorOwed[token][asset];
        if (address(feeEscrow) != address(0)) {
            amount += feeEscrow.claimable(creatorAccount(token), asset);
        }
    }

    /// @notice Protocol balance across legacy locker storage and the external fee escrow.
    function protocolOwed(address asset) public view returns (uint256 amount) {
        amount = _legacyProtocolOwed[asset];
        if (address(feeEscrow) != address(0)) {
            amount += feeEscrow.claimable(PROTOCOL_ACCOUNT, asset);
        }
    }

    /// @notice `claimable` across several launches, for a creator page listing all of theirs at once.
    function claimableMany(address[] calldata tokens) external view returns (ClaimableFees[] memory fees) {
        fees = new ClaimableFees[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            fees[i] = claimable(tokens[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              USER WRITE
    //////////////////////////////////////////////////////////////*/

    function registerLaunch(
        address token,
        address quoteToken,
        address pool,
        address creator,
        address creatorRecipient,
        uint256[] calldata positionIds
    ) external {
        _registerLaunch(
            token,
            quoteToken,
            pool,
            creator,
            creatorRecipient,
            positionIds,
            address(0),
            address(0),
            address(0),
            address(0),
            0,
            0,
            0,
            0,
            0,
            0
        );
    }

    function registerLaunchWithRoutes(
        address token,
        address quoteToken,
        address pool,
        address creator,
        address creatorRecipient,
        uint256[] calldata positionIds,
        IHydropumpLocker.FeeRoute[] calldata routes
    ) external {
        uint64 autoLpBps;
        address autoLpStrategy_;
        uint64 stakingRewardsBps;
        address stakingRewardsStrategy_;
        uint64 veHydxIncentivesBps;
        address veHydxIncentivesStrategy_;
        uint64 directRecipientBps;
        address directRecipient_;
        for (uint256 i = 0; i < routes.length; i++) {
            IHydropumpLocker.FeeRoute calldata route = routes[i];
            if (route.strategy == address(0) || route.bps == 0) revert InvalidFeeRouteAllocation();
            if (route.routeType == AUTO_LP_ROUTE) {
                if (autoLpStrategy_ != address(0)) revert DuplicateFeeRoute();
                autoLpStrategy_ = route.strategy;
                autoLpBps = route.bps;
            } else if (route.routeType == STAKING_REWARDS_ROUTE) {
                if (stakingRewardsStrategy_ != address(0)) revert DuplicateFeeRoute();
                stakingRewardsStrategy_ = route.strategy;
                stakingRewardsBps = route.bps;
            } else if (route.routeType == VEHYDX_INCENTIVES_ROUTE) {
                if (veHydxIncentivesStrategy_ != address(0)) revert DuplicateFeeRoute();
                if (route.strategy != protocolFeeRecipient) revert InvalidFeeRouteStrategy();
                veHydxIncentivesStrategy_ = route.strategy;
                veHydxIncentivesBps = route.bps;
            } else if (route.routeType == DIRECT_RECIPIENT_ROUTE) {
                if (directRecipient_ != address(0)) revert DuplicateFeeRoute();
                directRecipient_ = route.strategy;
                directRecipientBps = route.bps;
            } else {
                revert UnsupportedFeeRoute();
            }
        }
        if (
            autoLpStrategy_ == address(0) && stakingRewardsStrategy_ == address(0)
                && veHydxIncentivesStrategy_ == address(0) && directRecipient_ == address(0)
        ) {
            revert InvalidFeeRouteAllocation();
        }
        uint256 totalFee = uint256(creatorFee) + protocolFee;
        uint64 protocolBps = uint64((uint256(protocolFee) * 10_000) / totalFee);
        uint64 creatorBps = 10_000 - protocolBps;
        uint256 strategyBps = uint256(autoLpBps) + stakingRewardsBps + veHydxIncentivesBps + directRecipientBps;
        if (strategyBps > creatorBps) revert InvalidFeeRouteAllocation();
        if (address(feeEscrow) == address(0)) revert FeeEscrowNotSet();
        _registerLaunch(
            token,
            quoteToken,
            pool,
            creator,
            creatorRecipient,
            positionIds,
            autoLpStrategy_,
            stakingRewardsStrategy_,
            veHydxIncentivesStrategy_,
            directRecipient_,
            autoLpBps,
            stakingRewardsBps,
            veHydxIncentivesBps,
            directRecipientBps,
            uint64(uint256(creatorBps) - strategyBps),
            protocolBps
        );
        for (uint256 i = 0; i < routes.length; i++) {
            _feeRoutes[token].push(routes[i]);
            emit FeeRouteRegistered(token, routes[i].routeType, routes[i].bps, routes[i].strategy);
        }
    }

    function _registerLaunch(
        address token,
        address quoteToken,
        address pool,
        address creator,
        address creatorRecipient,
        uint256[] calldata positionIds,
        address autoLpStrategy_,
        address stakingRewardsStrategy_,
        address veHydxIncentivesStrategy_,
        address directRecipient_,
        uint64 autoLpBps,
        uint64 stakingRewardsBps,
        uint64 veHydxIncentivesBps,
        uint64 directRecipientBps,
        uint64 creatorFee_,
        uint64 protocolFee_
    ) internal {
        if (msg.sender != launcher) revert NotLauncher();
        if (_launches[token].pool != address(0)) revert AlreadyRegistered();
        if (creatorRecipient == address(0)) revert ZeroAddress();
        if (positionIds.length == 0 || positionIds.length > MAX_POSITIONS) revert InvalidPositionCount();

        Launch storage launch = _launches[token];
        launch.quoteToken = quoteToken;
        launch.pool = pool;
        launch.creator = creator;
        launch.creatorRecipient = creatorRecipient;
        launch.createdAt = uint64(block.timestamp);
        launch.positionIds = positionIds;

        if (
            autoLpStrategy_ != address(0) || stakingRewardsStrategy_ != address(0)
                || veHydxIncentivesStrategy_ != address(0) || directRecipient_ != address(0)
        ) {
            feeAllocation[token] = FeeAllocation({
                creatorBps: creatorFee_,
                protocolBps: protocolFee_,
                autoLpBps: autoLpBps,
                stakingRewardsBps: stakingRewardsBps,
                veHydxIncentivesBps: veHydxIncentivesBps,
                directRecipientBps: directRecipientBps
            });
        }
        if (autoLpStrategy_ != address(0)) {
            autoLpStrategy[token] = autoLpStrategy_;
            emit AutoLpStrategySet(token, autoLpStrategy_);
        }
        if (stakingRewardsStrategy_ != address(0)) {
            stakingRewardsStrategy[token] = stakingRewardsStrategy_;
        }
        if (veHydxIncentivesStrategy_ != address(0)) {
            veHydxIncentivesStrategy[token] = veHydxIncentivesStrategy_;
        }
        if (directRecipient_ != address(0)) directFeeRecipient[token] = directRecipient_;

        emit LaunchRegistered(token, creator, quoteToken, pool, positionIds, uint64(block.timestamp));
    }

    /// @notice Collect from the masked positions and credit both shares. Moves nothing out of the locker.
    /// @param positionMask Bit `i` selects position `i`. Use `fullMask(token)` for all.
    /// @dev Permissionless; destinations are fixed. The keeper `eth_call`s this with the full mask to read
    ///      per-position amounts, then sends a transaction with only the bands worth the gas.
    function collect(address token, uint256 positionMask)
        public
        returns (uint256[] memory collected0, uint256[] memory collected1)
    {
        Launch storage launch = _launches[token];
        if (launch.pool == address(0)) revert UnknownLaunch();
        if (positionMask == 0) revert EmptyMask();

        uint256 count = launch.positionIds.length;
        collected0 = new uint256[](count);
        collected1 = new uint256[](count);

        uint256 total0;
        uint256 total1;
        for (uint256 i = 0; i < count; i++) {
            if (positionMask & (uint256(1) << i) == 0) continue;

            (uint256 amount0, uint256 amount1) = nonfungiblePositionManager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: launch.positionIds[i],
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
            collected0[i] = amount0;
            collected1[i] = amount1;
            total0 += amount0;
            total1 += amount1;
        }

        if (total0 != 0 || total1 != 0) {
            FeeTotals storage totals = lifetimeFees[token];
            totals.launchToken += uint128(total0);
            totals.quote += uint128(total1);
        }

        // The launch token is always token0 — the launcher mines for it.
        (uint256 creator0, uint256 protocol0) = _distribute(token, token, total0);
        (uint256 creator1, uint256 protocol1) = _distribute(token, launch.quoteToken, total1);

        emit FeesCollected(token, positionMask, total0, total1, creator0, creator1, protocol0, protocol1);
    }

    /// @notice Everything a launch's creator is owed: already credited, plus their share of whatever is
    ///         still uncollected in the positions.
    /// @dev Deliberately not a `view` — it has to collect first, because uncollected fees only become
    ///      knowable by asking the position manager for them. `eth_call` this from a frontend to read the
    ///      number; sending it as a transaction just performs an ordinary full collect, which is harmless
    ///      and is what the keeper does anyway.
    function totalOwed(address token) external returns (ClaimableFees memory) {
        uint256 mask = fullMask(token);
        if (mask != 0) collect(token, mask);
        return claimable(token);
    }

    /// @notice Sweep the positions and send everything the creator is owed. Permissionless; destination is fixed.
    /// @dev Collects first so a caller never has to know whether fees are already credited or still sitting in
    ///      the positions — that distinction is an implementation detail, not something a creator should have
    ///      to reason about.
    ///
    ///      The collect is deliberately NOT wrapped in try/catch. `eth_estimateGas` binary-searches for the
    ///      cheapest gas at which a call succeeds, so a swallowed failure is a *cheaper success*: the estimator
    ///      settles on a limit that starves the collect, the catch hides the out-of-gas, and the claim pays
    ///      nothing while reporting success. Letting it revert keeps estimation honest — there is no cheap
    ///      path to find.
    ///
    ///      Collecting moves no money to anyone but this contract, so the only transfer here is to the
    ///      creator's own recipient. Nothing the protocol side does can block a creator being paid.
    function claim(address token) external returns (uint256 amount0, uint256 amount1) {
        uint256 mask = fullMask(token);
        if (mask != 0) collect(token, mask);
        return claimCredited(token);
    }

    /// @notice Pay out only what is already credited, without touching the positions.
    /// @dev Skips the sweep entirely — useful when the balance is known to be credited already and paying for
    ///      a five-position collect would be waste, and as a way out should `collect` itself ever revert.
    function claimCredited(address token) public returns (uint256 amount0, uint256 amount1) {
        Launch storage launch = _launches[token];
        address recipient = launch.creatorRecipient;
        if (recipient == address(0)) revert UnknownLaunch();

        amount0 = _payOutLegacy(token, token, recipient);
        amount1 = _payOutLegacy(token, launch.quoteToken, recipient);
        if (address(feeEscrow) != address(0)) {
            bytes32 account = creatorAccount(token);
            uint256 escrowAmount0 = feeEscrow.claim(account, token);
            uint256 escrowAmount1 = feeEscrow.claim(account, launch.quoteToken);
            amount0 += escrowAmount0;
            amount1 += escrowAmount1;
            if (escrowAmount0 > 0) emit CreatorClaimed(token, recipient, token, escrowAmount0);
            if (escrowAmount1 > 0) emit CreatorClaimed(token, recipient, launch.quoteToken, escrowAmount1);
        }
    }

    /// @notice Move the accrued protocol share to the buyback. Permissionless; destination is fixed.
    /// @dev Pulled on the operator's schedule rather than pushed during someone else's collect, so the daily
    ///      buyback job and a creator's claim can never block one another. Assets are passed in because the
    ///      locker does not enumerate them — the job already knows which it is converting this cycle.
    function sweepProtocol(address[] calldata assets) external returns (uint256[] memory amounts) {
        address recipient = protocolFeeRecipient;
        amounts = new uint256[](assets.length);

        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            uint256 legacyAmount = _legacyProtocolOwed[asset];
            uint256 amount = legacyAmount;
            if (address(feeEscrow) != address(0)) {
                amount += feeEscrow.claim(PROTOCOL_ACCOUNT, asset);
            }
            if (amount == 0) continue;

            _legacyProtocolOwed[asset] = 0;
            amounts[i] = amount;
            if (legacyAmount > 0) IERC20(asset).safeTransfer(recipient, legacyAmount);
            emit ProtocolSwept(recipient, asset, amount);
        }
    }

    function setCreatorRecipient(address token, address newRecipient) external {
        Launch storage launch = _launches[token];
        if (msg.sender != launch.creatorRecipient) revert NotCreatorRecipient();
        if (newRecipient == address(0)) revert ZeroAddress();

        emit CreatorRecipientUpdated(token, launch.creatorRecipient, newRecipient);
        launch.creatorRecipient = newRecipient;
        if (address(feeEscrow) != address(0)) {
            feeEscrow.setRecipient(creatorAccount(token), newRecipient);
        }
        address stakingStrategy = stakingRewardsStrategy[token];
        if (stakingStrategy != address(0)) {
            HydropumpStakingRewards(stakingStrategy).setNoStakerRecipient(newRecipient);
        }
    }

    /// @notice Add strategy-owned assets to one of a launch's existing positions.
    /// @dev The current tick must be both close to the keeper's expected tick and inside the selected range.
    ///      Any desired assets that the position manager does not consume are returned to the strategy.
    function compound(
        address token,
        uint256 positionIndex,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        int24 expectedTick,
        uint24 maxTickDeviation
    ) external returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        if (msg.sender != autoLpStrategy[token]) revert NotAutoLpStrategy();

        Launch storage launch = _launches[token];
        if (positionIndex >= launch.positionIds.length) revert InvalidPositionIndex();

        (, int24 currentTick,,,,) = IAlgebraPool(launch.pool).globalState();
        int256 deviation = int256(currentTick) - int256(expectedTick);
        if (deviation < 0) deviation = -deviation;
        if (uint256(deviation) > maxTickDeviation) revert TickDeviationExceeded();

        uint256 positionId = launch.positionIds[positionIndex];
        (,,,,, int24 tickLower, int24 tickUpper,,,,,) = nonfungiblePositionManager.positions(positionId);
        if (currentTick < tickLower || currentTick >= tickUpper) revert PositionNotActive();

        if (amount0Desired > 0) IERC20(token).safeTransferFrom(msg.sender, address(this), amount0Desired);
        if (amount1Desired > 0) {
            IERC20(launch.quoteToken).safeTransferFrom(msg.sender, address(this), amount1Desired);
        }

        IERC20(token).forceApprove(address(nonfungiblePositionManager), amount0Desired);
        IERC20(launch.quoteToken).forceApprove(address(nonfungiblePositionManager), amount1Desired);
        (liquidity, amount0, amount1) = nonfungiblePositionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: positionId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: block.timestamp
            })
        );
        IERC20(token).forceApprove(address(nonfungiblePositionManager), 0);
        IERC20(launch.quoteToken).forceApprove(address(nonfungiblePositionManager), 0);

        if (amount0Desired > amount0) IERC20(token).safeTransfer(msg.sender, amount0Desired - amount0);
        if (amount1Desired > amount1) {
            IERC20(launch.quoteToken).safeTransfer(msg.sender, amount1Desired - amount1);
        }

        emit LiquidityCompounded(token, positionId, amount0, amount1, liquidity);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view override returns (bytes4) {
        if (msg.sender != address(nonfungiblePositionManager)) revert NotNFTPositionManager();
        return this.onERC721Received.selector;
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _distribute(address token, address asset, uint256 amount)
        internal
        returns (uint256 creatorAmount, uint256 protocolAmount)
    {
        if (amount == 0) return (0, 0);

        FeeAllocation memory allocation = feeAllocation[token];
        uint256 creatorFee_ = creatorFee;
        uint256 protocolFee_ = protocolFee;
        uint256 autoLpAmount;
        uint256 stakingRewardsAmount;
        uint256 veHydxIncentivesAmount;
        uint256 directRecipientAmount;
        if (
            allocation.autoLpBps > 0 || allocation.stakingRewardsBps > 0 || allocation.veHydxIncentivesBps > 0
                || allocation.directRecipientBps > 0
        ) {
            creatorFee_ = allocation.creatorBps;
            protocolFee_ = allocation.protocolBps;
        }
        uint256 totalFee = creatorFee_ + protocolFee_ + allocation.autoLpBps + allocation.stakingRewardsBps
            + allocation.veHydxIncentivesBps;
        totalFee += allocation.directRecipientBps;
        if (allocation.autoLpBps > 0) autoLpAmount = (amount * allocation.autoLpBps) / totalFee;
        if (allocation.stakingRewardsBps > 0) {
            stakingRewardsAmount = (amount * allocation.stakingRewardsBps) / totalFee;
        }
        if (allocation.veHydxIncentivesBps > 0) {
            veHydxIncentivesAmount = (amount * allocation.veHydxIncentivesBps) / totalFee;
        }
        if (allocation.directRecipientBps > 0) {
            directRecipientAmount = (amount * allocation.directRecipientBps) / totalFee;
        }
        creatorAmount = (amount * creatorFee_) / totalFee;
        protocolAmount = amount - creatorAmount - autoLpAmount - stakingRewardsAmount - veHydxIncentivesAmount
            - directRecipientAmount;

        if (creatorAmount > 0) {
            _credit(creatorAccount(token), _launches[token].creatorRecipient, token, asset, creatorAmount, true);
            emit CreatorAccrued(token, _launches[token].creatorRecipient, asset, creatorAmount);
        }
        if (protocolAmount > 0) {
            _credit(PROTOCOL_ACCOUNT, protocolFeeRecipient, token, asset, protocolAmount, false);
            emit ProtocolAccrued(asset, protocolAmount);
        }
        if (autoLpAmount > 0) {
            address strategy = autoLpStrategy[token];
            FeeTotals storage totals = lifetimeAutoLpFees[token];
            if (asset == token) totals.launchToken += uint128(autoLpAmount);
            else totals.quote += uint128(autoLpAmount);
            _credit(autoLpAccount(token), strategy, token, asset, autoLpAmount, false);
            emit AutoLpAccrued(token, strategy, asset, autoLpAmount);
        }
        if (stakingRewardsAmount > 0) {
            address strategy = stakingRewardsStrategy[token];
            FeeTotals storage totals = lifetimeStakingRewardsFees[token];
            if (asset == token) totals.launchToken += uint128(stakingRewardsAmount);
            else totals.quote += uint128(stakingRewardsAmount);
            _credit(stakingRewardsAccount(token), strategy, token, asset, stakingRewardsAmount, false);
            emit StakingRewardsAccrued(token, strategy, asset, stakingRewardsAmount);
        }
        if (veHydxIncentivesAmount > 0) {
            address strategy = veHydxIncentivesStrategy[token];
            FeeTotals storage totals = lifetimeVeHydxIncentivesFees[token];
            if (asset == token) totals.launchToken += uint128(veHydxIncentivesAmount);
            else totals.quote += uint128(veHydxIncentivesAmount);
            _credit(veHydxIncentivesAccount(token), strategy, token, asset, veHydxIncentivesAmount, false);
            emit VeHydxIncentivesAccrued(token, strategy, asset, veHydxIncentivesAmount);
        }
        if (directRecipientAmount > 0) {
            address recipient = directFeeRecipient[token];
            FeeTotals storage totals = lifetimeDirectRecipientFees[token];
            if (asset == token) totals.launchToken += uint128(directRecipientAmount);
            else totals.quote += uint128(directRecipientAmount);
            _credit(directRecipientAccount(token), recipient, token, asset, directRecipientAmount, false);
            emit DirectRecipientAccrued(token, recipient, asset, directRecipientAmount);
        }
    }

    function _credit(
        bytes32 account,
        address recipient,
        address token,
        address asset,
        uint256 amount,
        bool creatorCredit
    ) internal {
        if (address(feeEscrow) == address(0)) {
            if (creatorCredit) _legacyCreatorOwed[token][asset] += amount;
            else _legacyProtocolOwed[asset] += amount;
            return;
        }

        IERC20(asset).forceApprove(address(feeEscrow), amount);
        feeEscrow.credit(account, recipient, asset, amount);
        IERC20(asset).forceApprove(address(feeEscrow), 0);
    }

    function _payOutLegacy(address token, address asset, address recipient) internal returns (uint256 amount) {
        amount = _legacyCreatorOwed[token][asset];
        if (amount == 0) return 0;

        _legacyCreatorOwed[token][asset] = 0;
        IERC20(asset).safeTransfer(recipient, amount);
        emit CreatorClaimed(token, recipient, asset, amount);
    }

    function _setFeeSplit(uint64 _creatorFee, uint64 _protocolFee) internal {
        if (uint256(_creatorFee) + _protocolFee == 0) revert InvalidFeeSplit();

        creatorFee = _creatorFee;
        protocolFee = _protocolFee;
        emit FeeSplitUpdated(_creatorFee, _protocolFee);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @dev Applies to fees collected from here on. Balances already credited to creators are untouched.
    function setFeeSplit(uint64 _creatorFee, uint64 _protocolFee) external onlyOwner {
        _setFeeSplit(_creatorFee, _protocolFee);
    }

    function setLauncher(address newLauncher) external onlyOwner {
        emit LauncherUpdated(launcher, newLauncher);
        launcher = newLauncher;
    }

    function setProtocolFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        emit ProtocolFeeRecipientUpdated(protocolFeeRecipient, newRecipient);
        protocolFeeRecipient = newRecipient;
        if (address(feeEscrow) != address(0)) feeEscrow.setRecipient(PROTOCOL_ACCOUNT, newRecipient);
    }

    /// @notice Configure external fee custody once. Legacy credited balances remain claimable in the locker.
    function setFeeEscrow(address newFeeEscrow) external onlyOwner {
        if (address(feeEscrow) != address(0)) revert FeeEscrowAlreadySet();
        if (newFeeEscrow == address(0) || newFeeEscrow.code.length == 0) revert ZeroAddress();
        feeEscrow = HydropumpFeeEscrow(newFeeEscrow);
        feeEscrow.setRecipient(PROTOCOL_ACCOUNT, protocolFeeRecipient);
        emit FeeEscrowSet(newFeeEscrow);
    }

    /// @notice Bind a launch to its auto-LP strategy once. The allocation layer will deploy and set this atomically.
    function setAutoLpStrategy(address token, address strategy) external onlyOwner {
        if (_launches[token].pool == address(0)) revert UnknownLaunch();
        if (strategy == address(0)) revert ZeroAddress();
        if (autoLpStrategy[token] != address(0)) revert AutoLpStrategyAlreadySet();
        autoLpStrategy[token] = strategy;
        emit AutoLpStrategySet(token, strategy);
    }
}
