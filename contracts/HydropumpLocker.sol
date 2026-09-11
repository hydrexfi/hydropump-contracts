// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {IBribe} from "./interfaces/IBribe.sol";
import {HydropumpAddresses} from "./libraries/HydropumpAddresses.sol";

/// @title HydropumpLocker
/// @notice One locker per launch: holds that launch's LP NFT permanently. Half of collected fees go to the fee
///         claimer, half to savings earmarked for gauge bribes.
/// @dev Deployed by HydropumpLaunchpad per token; accepts exactly one NFT in onERC721Received. Fee claimer or owner
///      can collect fees, place bribes, and run claimAndForward.
contract HydropumpLocker is IERC721Receiver {
    using SafeERC20 for IERC20;

    INonfungiblePositionManager public constant nonfungiblePositionManager =
        INonfungiblePositionManager(HydropumpAddresses.NONFUNGIBLE_POSITION_MANAGER);

    /// @notice Token whitelisted for claimAndForward out of the box (oHYDX)
    address public constant DEFAULT_FORWARD_WHITELIST_TOKEN = HydropumpAddresses.OHYDX;

    address public owner;

    /// @notice Set once when the single LP NFT is received
    uint256 public lpTokenId;
    address public feeClaimer;
    address public launchToken;

    /// @notice Savings per token (token0/token1 of the LP, or reward tokens from claimAndForward)
    mapping(address => uint256) public savings;

    /// @notice Gauge bribe contract; only this can receive bribes from savings. Set by owner.
    address public gaugeBribe;

    /// @notice Tokens allowed to be forwarded in claimAndForward. Only owner can update.
    mapping(address => bool) public forwardWhitelist;

    bool private initialized;

    event Deposited(uint256 indexed nftId, address indexed launchToken, address indexed feeClaimer);
    event FeesCollected(
        uint256 indexed nftId,
        address indexed feeClaimer,
        uint256 amount0ToClaimer,
        uint256 amount1ToClaimer,
        uint256 amount0ToSavings,
        uint256 amount1ToSavings
    );
    event FeeClaimerUpdated(address indexed previousClaimer, address indexed newClaimer);
    event GaugeBribeSet(address indexed gaugeBribe);
    event BribePlaced(address indexed gaugeBribe, address indexed rewardToken, uint256 amount);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event OwnerUpdated(address indexed previousOwner, address indexed newOwner);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);
    event ClaimedAndForwarded(address indexed feeClaimer, address indexed token, uint256 amount);
    event ForwardWhitelistUpdated(address indexed token, bool allowed);

    error InvalidFeeClaimer();
    error InvalidLaunchToken();
    error AlreadyInitialized();
    error NotNFTPositionManager();
    error NotInitialized();
    error InvalidFeeClaimerAddress();
    error NotOwner();
    error NotFeeClaimerOrOwner();
    error GaugeBribeNotSet();
    error InsufficientSavings();
    error InvalidRecipient();
    error InvalidLengths();
    error DistributorCallFailed();
    error TokenNotWhitelisted();

    constructor(address _owner) {
        owner = _owner;
        emit OwnerUpdated(address(0), _owner);
        forwardWhitelist[DEFAULT_FORWARD_WHITELIST_TOKEN] = true;
        emit ForwardWhitelistUpdated(DEFAULT_FORWARD_WHITELIST_TOKEN, true);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyFeeClaimerOrOwner() {
        if (!initialized) revert NotInitialized();
        if (msg.sender != feeClaimer && msg.sender != owner) revert NotFeeClaimerOrOwner();
        _;
    }

    // =============================
    //  VIEW
    // =============================

    /// @notice LP position NFT ID held by this locker (set once on deposit)
    function getNFTId() external view returns (uint256) {
        return lpTokenId;
    }

    /// @notice Launch token this locker belongs to (set once on deposit)
    function getLaunchToken() external view returns (address) {
        return launchToken;
    }

    function getSavings(address token) external view returns (uint256) {
        return savings[token];
    }

    // =============================
    //  WRITE
    // =============================

    function setFeeClaimer(address newFeeClaimer) external onlyFeeClaimerOrOwner {
        if (newFeeClaimer == address(0)) revert InvalidFeeClaimerAddress();
        address previousClaimer = feeClaimer;
        feeClaimer = newFeeClaimer;
        emit FeeClaimerUpdated(previousClaimer, newFeeClaimer);
    }

    /// @notice Collect fees from the locked LP: half to the fee claimer, half to savings
    function collectFees() external onlyFeeClaimerOrOwner returns (uint256 amount0ToClaimer, uint256 amount1ToClaimer) {
        (,, address token0, address token1,,,,,,,,) = nonfungiblePositionManager.positions(lpTokenId);

        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
            tokenId: lpTokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
        });

        (uint256 amount0, uint256 amount1) = nonfungiblePositionManager.collect(params);

        amount0ToClaimer = amount0 / 2;
        amount1ToClaimer = amount1 / 2;
        uint256 amount0ToSavings = amount0 - amount0ToClaimer;
        uint256 amount1ToSavings = amount1 - amount1ToClaimer;

        if (amount0ToClaimer > 0) IERC20(token0).safeTransfer(feeClaimer, amount0ToClaimer);
        if (amount1ToClaimer > 0) IERC20(token1).safeTransfer(feeClaimer, amount1ToClaimer);

        if (amount0ToSavings > 0) savings[token0] += amount0ToSavings;
        if (amount1ToSavings > 0) savings[token1] += amount1ToSavings;

        emit FeesCollected(
            lpTokenId, feeClaimer, amount0ToClaimer, amount1ToClaimer, amount0ToSavings, amount1ToSavings
        );
    }

    function placeBribe(address rewardToken, uint256 amount) external onlyFeeClaimerOrOwner {
        if (gaugeBribe == address(0)) revert GaugeBribeNotSet();
        if (savings[rewardToken] < amount) revert InsufficientSavings();

        savings[rewardToken] -= amount;
        IERC20(rewardToken).forceApprove(gaugeBribe, amount);
        IBribe(gaugeBribe).notifyRewardAmount(rewardToken, amount);

        emit BribePlaced(gaugeBribe, rewardToken, amount);
    }

    /// @notice Call distributor contracts (e.g. yield / incentive claims) and forward the resulting balance increases
    ///         to the fee claimer. Only whitelisted tokens can be forwarded; the owner sets the whitelist.
    function claimAndForward(
        address[] calldata distributorTargets,
        bytes[] calldata distributorCalldata,
        address[] calldata tokensToForward
    ) external onlyFeeClaimerOrOwner {
        if (distributorTargets.length != distributorCalldata.length) {
            revert InvalidLengths();
        }

        uint256[] memory balanceBefore = new uint256[](tokensToForward.length);
        for (uint256 i = 0; i < tokensToForward.length; i++) {
            if (!forwardWhitelist[tokensToForward[i]]) revert TokenNotWhitelisted();
            balanceBefore[i] = IERC20(tokensToForward[i]).balanceOf(address(this));
        }

        for (uint256 i = 0; i < distributorTargets.length; i++) {
            (bool success,) = distributorTargets[i].call(distributorCalldata[i]);
            if (!success) revert DistributorCallFailed();
        }

        for (uint256 i = 0; i < tokensToForward.length; i++) {
            address token = tokensToForward[i];
            uint256 amount = IERC20(token).balanceOf(address(this)) - balanceBefore[i];
            if (amount > 0) {
                IERC20(token).safeTransfer(feeClaimer, amount);
                emit ClaimedAndForwarded(feeClaimer, token, amount);
            }
        }
    }

    /// @notice Called when the LP NFT is transferred in. Accepts exactly one NFT; data = abi.encode(feeClaimer, launchToken).
    function onERC721Received(address, address, uint256 tokenId, bytes calldata data)
        external
        override
        returns (bytes4)
    {
        if (msg.sender != address(nonfungiblePositionManager)) revert NotNFTPositionManager();
        if (initialized) revert AlreadyInitialized();

        (address _feeClaimer, address _launchToken) = abi.decode(data, (address, address));
        if (_feeClaimer == address(0)) revert InvalidFeeClaimer();
        if (_launchToken == address(0)) revert InvalidLaunchToken();

        initialized = true;
        lpTokenId = tokenId;
        feeClaimer = _feeClaimer;
        launchToken = _launchToken;

        emit Deposited(tokenId, _launchToken, _feeClaimer);

        return this.onERC721Received.selector;
    }

    // =============================
    //  ADMIN
    // =============================

    function setGaugeBribe(address _gaugeBribe) external onlyOwner {
        gaugeBribe = _gaugeBribe;
        emit GaugeBribeSet(_gaugeBribe);
    }

    /// @notice Set whether a token is allowed to be forwarded in claimAndForward
    function setForwardWhitelist(address token, bool allowed) external onlyOwner {
        forwardWhitelist[token] = allowed;
        emit ForwardWhitelistUpdated(token, allowed);
    }

    function setOwner(address newOwner) external onlyOwner {
        address previousOwner = owner;
        owner = newOwner;
        emit OwnerUpdated(previousOwner, newOwner);
    }

    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidRecipient();
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyWithdraw(token, to, amount);
    }

    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidRecipient();
        if (savings[token] < amount) revert InsufficientSavings();

        savings[token] -= amount;
        IERC20(token).safeTransfer(to, amount);

        emit Withdrawn(token, to, amount);
    }
}
