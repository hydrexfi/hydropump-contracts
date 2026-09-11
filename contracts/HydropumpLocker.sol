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

/// @title HydropumpLocker
/// @notice Holds every launch's positions permanently and splits their fees.
contract HydropumpLocker is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable, IERC721Receiver, IHydropumpLocker {
    using SafeERC20 for IERC20;

    INonfungiblePositionManager public constant nonfungiblePositionManager =
        INonfungiblePositionManager(HydropumpAddresses.NONFUNGIBLE_POSITION_MANAGER);

    /// @notice Cap on positions per launch, bounding `collect`'s loop and the mask width
    uint256 public constant MAX_POSITIONS = 12;

    struct ClaimableFees {
        address launchToken;
        address quoteToken;
        uint256 launchTokenAmount;
        uint256 quoteAmount;
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
    mapping(address token => mapping(address asset => uint256 amount)) public creatorOwed;

    /// @dev Reserved so added storage does not shift the layout. Keep vars + gap == 50.
    uint256[46] private __gap;

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
    event CreatorRecipientUpdated(address indexed token, address indexed from, address indexed to);
    event FeeSplitUpdated(uint64 creatorFee, uint64 protocolFee);
    event LauncherUpdated(address indexed previousLauncher, address indexed newLauncher);
    event ProtocolFeeRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);

    error NotLauncher();
    error NotNFTPositionManager();
    error NotCreatorRecipient();
    error AlreadyRegistered();
    error UnknownLaunch();
    error ZeroAddress();
    error EmptyMask();
    error InvalidPositionCount();
    error InvalidFeeSplit();

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
            launchTokenAmount: creatorOwed[token][token],
            quoteAmount: creatorOwed[token][quoteToken]
        });
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

        emit LaunchRegistered(token, creator, quoteToken, pool, positionIds, uint64(block.timestamp));
    }

    /// @notice Collect from the masked positions, credit the creator, forward the protocol share.
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

    /// @notice Send accrued creator fees to the recipient. Permissionless; destination is fixed.
    function claim(address token) external returns (uint256 amount0, uint256 amount1) {
        Launch storage launch = _launches[token];
        address recipient = launch.creatorRecipient;
        if (recipient == address(0)) revert UnknownLaunch();

        amount0 = _payOut(token, token, recipient);
        amount1 = _payOut(token, launch.quoteToken, recipient);
    }

    function setCreatorRecipient(address token, address newRecipient) external {
        Launch storage launch = _launches[token];
        if (msg.sender != launch.creatorRecipient) revert NotCreatorRecipient();
        if (newRecipient == address(0)) revert ZeroAddress();

        emit CreatorRecipientUpdated(token, launch.creatorRecipient, newRecipient);
        launch.creatorRecipient = newRecipient;
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

        creatorAmount = (amount * creatorFee) / (uint256(creatorFee) + protocolFee);
        protocolAmount = amount - creatorAmount;

        if (creatorAmount > 0) {
            creatorOwed[token][asset] += creatorAmount;
            emit CreatorAccrued(token, _launches[token].creatorRecipient, asset, creatorAmount);
        }
        if (protocolAmount > 0) IERC20(asset).safeTransfer(protocolFeeRecipient, protocolAmount);
    }

    function _payOut(address token, address asset, address recipient) internal returns (uint256 amount) {
        amount = creatorOwed[token][asset];
        if (amount == 0) return 0;

        creatorOwed[token][asset] = 0;
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
    }
}
