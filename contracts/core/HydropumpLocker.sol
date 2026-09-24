// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {IHydropumpLocker} from "../interfaces/IHydropumpLocker.sol";
import {IFeeUseRegistry} from "../interfaces/IFeeUseRegistry.sol";
import {IFeeUse} from "../interfaces/IFeeUse.sol";
import {INonfungiblePositionManager} from "../interfaces/INonfungiblePositionManager.sol";
import {ISwapRouter} from "../interfaces/ISwapRouter.sol";
import {HydropumpAddresses} from "../libraries/HydropumpAddresses.sol";

/// @title HydropumpLocker
/// @notice Holds every launch's positions permanently and splits the fees they earn.
contract HydropumpLocker is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable, IERC721Receiver, IHydropumpLocker {
    using SafeERC20 for IERC20;

    INonfungiblePositionManager public constant nonfungiblePositionManager =
        INonfungiblePositionManager(HydropumpAddresses.NONFUNGIBLE_POSITION_MANAGER);

    ISwapRouter public constant swapRouter = ISwapRouter(HydropumpAddresses.SWAP_ROUTER);

    /// @notice Cap on positions per launch, bounding `splitRewards`'s loop and the mask width
    uint256 public constant MAX_POSITIONS = 12;

    /// @notice Gross fees a launch has ever collected, before the split.
    struct FeeTotals {
        uint128 launchToken;
        uint128 quote;
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
    address public feeUseRegistry;
    uint64 public protocolFee;
    address public protocolFeeRecipient;

    mapping(address token => Launch) internal _launches;

    /// @notice Protocol share awaiting the buyback, per asset. Pooled across launches: it all goes to one
    ///         place, so there is nothing to gain from tracking which launch produced it.
    mapping(address asset => uint256 amount) public protocolOwed;

    /// @notice Lifetime gross fees per launch. Monotonic, and the only honest measure of a launch's volume.
    mapping(address token => FeeTotals) public lifetimeFees;

    /// @notice Creator share awaiting its fee use, per launch and asset. Booked by `splitRewards`, spent
    ///         by `spendCreatorShare`.
    mapping(address token => mapping(address asset => uint256)) public creatorOwed;

    /// @dev Reserved so added storage does not shift the layout. Keep vars + gap == 50.
    uint256[41] private __gap;

    event LaunchRegistered(
        address indexed token,
        address indexed creator,
        address indexed quoteToken,
        address pool,
        uint256[] positionIds,
        uint64 timestamp
    );
    /// @dev `launchTokenFees` and `quoteFees` are named by asset, not by pool side: a launch token sits on
    ///      whichever side of its pair its address sorts to, so amount0 is not reliably either one.
    event RewardsSplit(
        address indexed token,
        uint256 positionMask,
        uint256 launchTokenFees,
        uint256 quoteFees,
        uint256 toCreatorLaunchToken,
        uint256 toCreatorQuote,
        uint256 toProtocolLaunchToken,
        uint256 toProtocolQuote
    );
    event ProtocolShareConverted(address indexed token, uint256 launchTokenIn, uint256 quoteOut);
    event ProtocolAccrued(address indexed asset, uint256 amount);
    event ProtocolSwept(address indexed recipient, address indexed asset, uint256 amount);
    event CreatorRecipientUpdated(address indexed token, address indexed from, address indexed to);
    event FeeSplitUpdated(uint64 creatorFee, uint64 protocolFee);
    event LauncherUpdated(address indexed previousLauncher, address indexed newLauncher);
    event FeeUseRegistryUpdated(address indexed previousRegistry, address indexed newRegistry);
    event CreatorAccrued(address indexed token, address indexed asset, uint256 amount);
    event CreatorShareSpent(
        address indexed token, address indexed feeUse, uint256 launchTokenAmount, uint256 quoteAmount
    );
    event ProtocolFeeRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);

    error NotLauncher();
    error NotNFTPositionManager();
    error NotCreatorRecipient();
    error AlreadyRegistered();
    error UnknownLaunch();
    error ConvertFirst();
    error ZeroAddress();
    error EmptyMask();
    error InvalidPositionCount();
    error InvalidFeeSplit();
    error RegistryUnset();
    error UnknownFeeUse();
    error InvalidCreatorRecipient();

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

    function creatorRecipient(address token) external view returns (address) {
        return _launches[token].creatorRecipient;
    }

    function quoteTokenOf(address token) external view returns (address) {
        return _launches[token].quoteToken;
    }

    function poolOf(address token) external view returns (address) {
        return _launches[token].pool;
    }

    /// @notice Whether a launch token sits on the token0 side of its pool.
    function launchIsToken0(address token) public view returns (bool) {
        return token < _launches[token].quoteToken;
    }

    /// @notice Mask selecting every position of a launch.
    function fullMask(address token) public view returns (uint256) {
        uint256 count = _launches[token].positionIds.length;
        return count == 0 ? 0 : (uint256(1) << count) - 1;
    }

    /*//////////////////////////////////////////////////////////////
                              USER WRITE
    //////////////////////////////////////////////////////////////*/

    /// @notice Register a new launch and lock its positions.
    /// @dev Precondition: `_creatorRecipient` is neither this contract nor `feeUseRegistry`. Either would
    ///      pay a `spendCreatorShare` transfer back to this contract, whose balance-delta re-book credits
    ///      it straight back to `creatorOwed`, and only the recipient can call `setCreatorRecipient` — so
    ///      the share could never leave.
    function registerLaunch(
        address token,
        address quoteToken,
        address pool,
        address creator,
        address _creatorRecipient,
        uint256[] calldata positionIds
    ) external {
        if (msg.sender != launcher) revert NotLauncher();
        if (_launches[token].pool != address(0)) revert AlreadyRegistered();
        if (_creatorRecipient == address(0)) revert ZeroAddress();
        _requirePayableRecipient(_creatorRecipient);
        if (positionIds.length == 0 || positionIds.length > MAX_POSITIONS) revert InvalidPositionCount();

        Launch storage launch = _launches[token];
        launch.quoteToken = quoteToken;
        launch.pool = pool;
        launch.creator = creator;
        launch.creatorRecipient = _creatorRecipient;
        launch.createdAt = uint64(block.timestamp);
        launch.positionIds = positionIds;

        emit LaunchRegistered(token, creator, quoteToken, pool, positionIds, uint64(block.timestamp));
    }

    /// @notice Sweep every band and book both shares. Permissionless; destinations fixed.
    function splitRewards(address token) external returns (uint256 toCreator, uint256 toProtocol) {
        return splitRewards(token, fullMask(token));
    }

    /// @notice `splitRewards` over a chosen set of bands.
    /// @param positionMask Bit `i` selects position `i`. Use `fullMask(token)` for all. The keeper
    ///        `eth_call`s with the full mask to see per-band amounts, then sends only the bands worth the gas.
    /// @dev Books both shares and moves nothing out. Every creator's money flows through here, so it
    ///      must never be able to fail: it touches no pool, no swap and no third-party contract. Spending
    ///      is `spendCreatorShare` and `convertProtocolShare`, which may fail freely.
    function splitRewards(address token, uint256 positionMask) public returns (uint256 toCreator, uint256 toProtocol) {
        Launch storage launch = _launches[token];
        address quoteToken = launch.quoteToken;
        if (launch.pool == address(0)) revert UnknownLaunch();
        if (positionMask == 0) revert EmptyMask();

        (uint256 launchTokenFees, uint256 quoteFees) = _collect(token, quoteToken, positionMask);
        if (launchTokenFees == 0 && quoteFees == 0) {
            emit RewardsSplit(token, positionMask, 0, 0, 0, 0, 0, 0);
            return (0, 0);
        }

        FeeTotals storage totals = lifetimeFees[token];
        totals.launchToken += uint128(launchTokenFees);
        totals.quote += uint128(quoteFees);

        uint256 denominator = uint256(creatorFee) + protocolFee;
        uint256 protocolLaunchToken = (launchTokenFees * protocolFee) / denominator;
        uint256 protocolQuote = (quoteFees * protocolFee) / denominator;

        // The remainder, so rounding dust follows the creator rather than vanishing.
        uint256 creatorLaunchToken = launchTokenFees - protocolLaunchToken;
        uint256 creatorQuote = quoteFees - protocolQuote;

        if (creatorLaunchToken > 0) {
            creatorOwed[token][token] += creatorLaunchToken;
            emit CreatorAccrued(token, token, creatorLaunchToken);
        }
        if (creatorQuote > 0) {
            creatorOwed[token][quoteToken] += creatorQuote;
            emit CreatorAccrued(token, quoteToken, creatorQuote);
        }

        if (protocolLaunchToken > 0) {
            protocolOwed[token] += protocolLaunchToken;
            emit ProtocolAccrued(token, protocolLaunchToken);
        }
        if (protocolQuote > 0) {
            protocolOwed[quoteToken] += protocolQuote;
            emit ProtocolAccrued(quoteToken, protocolQuote);
        }

        toCreator = creatorLaunchToken + creatorQuote;
        toProtocol = protocolLaunchToken + protocolQuote;

        emit RewardsSplit(
            token,
            positionMask,
            launchTokenFees,
            quoteFees,
            creatorLaunchToken,
            creatorQuote,
            protocolLaunchToken,
            protocolQuote
        );
    }

    /// @notice Push the booked creator share to the launch's fee use, which spends it on arrival.
    ///         Permissionless; the destination was fixed at launch.
    /// @dev Separate from the split so a fee use that reverts cannot stop fees being collected. If it
    ///      does revert, the share stays booked here until the registry is repointed.
    function spendCreatorShare(address token) public returns (uint256 launchTokenAmount, uint256 quoteAmount) {
        address registry = feeUseRegistry;
        if (registry == address(0)) revert RegistryUnset();

        Launch storage launch = _launches[token];
        address quoteToken = launch.quoteToken;
        if (launch.pool == address(0)) revert UnknownLaunch();

        address feeUse = IFeeUseRegistry(registry).implementationFor(token);
        if (feeUse == address(0)) revert UnknownFeeUse();

        launchTokenAmount = creatorOwed[token][token];
        quoteAmount = creatorOwed[token][quoteToken];
        if (launchTokenAmount == 0 && quoteAmount == 0) return (0, 0);

        creatorOwed[token][token] = 0;
        creatorOwed[token][quoteToken] = 0;

        // One call with both sides: auto-LP needs them together to deposit into a band.
        address[] memory assets = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        (assets[0], assets[1]) = (token, quoteToken);
        (amounts[0], amounts[1]) = (launchTokenAmount, quoteAmount);

        if (launchTokenAmount > 0) IERC20(token).safeTransfer(feeUse, launchTokenAmount);
        if (quoteAmount > 0) IERC20(quoteToken).safeTransfer(feeUse, quoteAmount);

        // Measured after the transfer out, so any rise is what came back.
        uint256 heldLaunchToken = IERC20(token).balanceOf(address(this));
        uint256 heldQuote = IERC20(quoteToken).balanceOf(address(this));

        IFeeUse(feeUse).onFees(token, assets, amounts);

        // A fee use returns what it could not use — auto-LP does this on nearly every call, since a band
        // takes one ratio. Re-booking it keeps it payable instead of leaving it loose in this contract,
        // where no ledger would ever pay it out.
        _rebook(token, token, IERC20(token).balanceOf(address(this)) - heldLaunchToken);
        _rebook(token, quoteToken, IERC20(quoteToken).balanceOf(address(this)) - heldQuote);

        emit CreatorShareSpent(token, feeUse, launchTokenAmount, quoteAmount);
    }

    function _rebook(address token, address asset, uint256 amount) internal {
        if (amount == 0) return;

        creatorOwed[token][asset] += amount;
        emit CreatorAccrued(token, asset, amount);
    }

    /*//////////////////////////////////////////////////////////////
                             ENTRY POINTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Collect, then spend the creator's share on whatever the launch chose.
    /// @dev Permissionless and unpointable: the destination was fixed at launch, so "claim", "buy back
    ///      and burn" and "auto-LP" are all this call under three labels.
    function handleCreatorRewards(address token) external returns (uint256 launchTokenAmount, uint256 quoteAmount) {
        splitRewards(token, fullMask(token));
        return spendCreatorShare(token);
    }

    /// @notice Collect, then turn the protocol's share into the pair asset and send it to the buyback.
    /// @dev Permissionless; the recipient is fixed. Reverts if the pool cannot fill the sell, because a
    ///      caller asking for exactly this should hear about it — `handleAllRewards` is where it is
    ///      best-effort instead.
    function handleProtocolRewards(address token) external returns (uint256 delivered) {
        splitRewards(token, fullMask(token));
        return this.deliverProtocolShare(token);
    }

    /// @notice Both sides in one transaction. What the frontend button calls.
    /// @dev The protocol half is best-effort: it is the only part that touches the pool, and a pool that
    ///      cannot fill a sell must not stop a creator being paid. On failure the share stays booked in
    ///      `protocolOwed` for a later call.
    ///
    ///      Send this with a generous gas limit. The `try` succeeds whether or not its body runs, so gas
    ///      estimation can settle on a limit that starves it — observed on mainnet.
    function handleAllRewards(address token) external returns (uint256 toCreator, uint256 toProtocol) {
        (toCreator, toProtocol) = splitRewards(token, fullMask(token));
        spendCreatorShare(token);

        try this.deliverProtocolShare(token) {} catch {}
    }

    /// @notice Convert the protocol's launch-token share and deliver the quote to the buyback.
    /// @dev External so `handleAllRewards` can call it best-effort. Does not collect; the entry points do.
    function deliverProtocolShare(address token) external returns (uint256 delivered) {
        address quoteToken = _launches[token].quoteToken;
        if (quoteToken == address(0)) revert UnknownLaunch();

        if (protocolOwed[token] > 0) _convertProtocolShare(token, quoteToken);
        return _sweep(quoteToken);
    }

    /// @notice Sell the protocol's launch-token share into the launch's own pool, so only the quote token
    ///         ever reaches the buyback. Permissionless; every destination is fixed.
    /// @dev No price bound. Whoever calls this does not choose the price and takes none of the output —
    ///      it is credited to the protocol either way — so the worst a sandwich achieves is giving the
    ///      protocol less quote than it might have got. That is a cost worth paying to keep the call
    ///      simple and always executable; a bound that can fail is a call that can be stuck.
    ///
    ///      Isolated from `splitRewards` on purpose: this is the part that can fail, and nothing else
    ///      should fail with it.
    function convertProtocolShare(address token) external returns (uint256 quoteOut) {
        Launch storage launch = _launches[token];
        if (launch.pool == address(0)) revert UnknownLaunch();
        return _convertProtocolShare(token, launch.quoteToken);
    }

    function _convertProtocolShare(address token, address quoteToken) internal returns (uint256 quoteOut) {
        uint256 amount = protocolOwed[token];
        if (amount == 0) return 0;

        protocolOwed[token] = 0;
        quoteOut = _convert(token, quoteToken, amount);

        protocolOwed[quoteToken] += quoteOut;
        emit ProtocolAccrued(quoteToken, quoteOut);
    }

    /// @notice Move the accrued protocol share to the buyback. Permissionless; destination is fixed.
    /// @dev Pulled on the operator's schedule rather than pushed during someone else's split, so the daily
    ///      buyback job and a creator's fees can never block one another.
    function sweepProtocol(address[] calldata assets) external returns (uint256[] memory amounts) {
        amounts = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            amounts[i] = _sweep(assets[i]);
        }
    }

    function _sweep(address asset) internal returns (uint256 amount) {
        // A launch token has to be converted first. Sweeping one straight out would put it in the
        // buyback, which is meant to hold nothing but quote tokens.
        if (_launches[asset].pool != address(0)) revert ConvertFirst();

        amount = protocolOwed[asset];
        if (amount == 0) return 0;

        address recipient = protocolFeeRecipient;
        protocolOwed[asset] = 0;
        IERC20(asset).safeTransfer(recipient, amount);
        emit ProtocolSwept(recipient, asset, amount);
    }

    /// @dev Precondition: same as `registerLaunch` — `newRecipient` is neither this contract nor
    ///      `feeUseRegistry`, for the same reason.
    function setCreatorRecipient(address token, address newRecipient) external {
        Launch storage launch = _launches[token];
        if (msg.sender != launch.creatorRecipient) revert NotCreatorRecipient();
        if (newRecipient == address(0)) revert ZeroAddress();
        _requirePayableRecipient(newRecipient);

        emit CreatorRecipientUpdated(token, launch.creatorRecipient, newRecipient);
        launch.creatorRecipient = newRecipient;
    }

    /// @dev Rejects a recipient that could never actually receive its share: the locker itself, or the
    ///      fee-use registry it spends through. Fee-use implementations are not covered — the registry has
    ///      no reverse lookup from implementation to id, and adding one is a design change out of scope here.
    function _requirePayableRecipient(address recipient) internal view {
        if (recipient == address(this) || recipient == feeUseRegistry) revert InvalidCreatorRecipient();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view override returns (bytes4) {
        if (msg.sender != address(nonfungiblePositionManager)) revert NotNFTPositionManager();
        return this.onERC721Received.selector;
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Collects the masked bands and reports the two totals by asset rather than by pool side.
    function _collect(address token, address quoteToken, uint256 positionMask)
        internal
        returns (uint256 launchTokenFees, uint256 quoteFees)
    {
        uint256[] storage positionIds = _launches[token].positionIds;
        uint256 count = positionIds.length;

        uint256 total0;
        uint256 total1;
        for (uint256 i = 0; i < count; i++) {
            if (positionMask & (uint256(1) << i) == 0) continue;

            (uint256 amount0, uint256 amount1) = nonfungiblePositionManager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: positionIds[i],
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
            total0 += amount0;
            total1 += amount1;
        }

        return token < quoteToken ? (total0, total1) : (total1, total0);
    }

    /// @dev Sells into the launch's own pool with no minimum out. See `convertProtocolShare` for why the
    ///      absence of a bound is a deliberate trade rather than an oversight.
    function _convert(address token, address quoteToken, uint256 amountIn) internal returns (uint256 quoteOut) {
        IERC20(token).forceApprove(address(swapRouter), amountIn);
        quoteOut = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: quoteToken,
                deployer: address(0),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                limitSqrtPrice: 0
            })
        );
        IERC20(token).forceApprove(address(swapRouter), 0);

        emit ProtocolShareConverted(token, amountIn, quoteOut);
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

    /// @dev Applies to fees split from here on. Balances already sent onwards are untouched.
    function setFeeSplit(uint64 _creatorFee, uint64 _protocolFee) external onlyOwner {
        _setFeeSplit(_creatorFee, _protocolFee);
    }

    function setLauncher(address newLauncher) external onlyOwner {
        emit LauncherUpdated(launcher, newLauncher);
        launcher = newLauncher;
    }

    function setFeeUseRegistry(address newRegistry) external onlyOwner {
        if (newRegistry == address(0)) revert ZeroAddress();
        emit FeeUseRegistryUpdated(feeUseRegistry, newRegistry);
        feeUseRegistry = newRegistry;
    }

    function setProtocolFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        emit ProtocolFeeRecipientUpdated(protocolFeeRecipient, newRecipient);
        protocolFeeRecipient = newRecipient;
    }
}
