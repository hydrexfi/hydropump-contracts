// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IPairDirectory} from "./interfaces/IPairDirectory.sol";
import {TickMath} from "./libraries/TickMath.sol";

/// @title PairDirectory
/// @notice Which tokens a launch may be quoted in, and what one launch token is worth in each of them.
contract PairDirectory is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable, IPairDirectory {
    int24 public constant CURVE_SPAN = 887_200;

    /// @notice Upgrade authority, held apart from the owner that runs the daily refresh.
    address public admin;

    mapping(address quoteToken => QuoteConfig) public quoteTokens;

    /// @dev Reserved so added storage does not shift the layout. Keep vars + gap == 50.
    uint256[48] private __gap;

    event QuoteTokenConfigured(address indexed quoteToken, bool enabled, int24 startTick);
    event StartTickUpdated(address indexed quoteToken, int24 previousTick, int24 newTick);
    event AdminUpdated(address indexed previousAdmin, address indexed newAdmin);

    error QuoteTokenNotEnabled();
    error StartTickUnset();
    error StartTickOutOfRange();
    error LengthMismatch();
    error ZeroAddress();
    error NotAdmin();

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner, address _admin) external initializer {
        if (_owner == address(0) || _admin == address(0)) revert ZeroAddress();
        __Ownable_init(_owner);
        __Ownable2Step_init();

        admin = _admin;
        emit AdminUpdated(address(0), _admin);
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                 READ
    //////////////////////////////////////////////////////////////*/

    function isEnabled(address quoteToken) external view returns (bool) {
        QuoteConfig memory quote = quoteTokens[quoteToken];
        return quote.enabled && quote.updatedAt != 0;
    }

    /// @notice Whether a launch token sits on the token0 side of its pool. Algebra sorts by address and
    ///         nothing else, so this is the whole of it.
    function launchIsToken0(address token, address quoteToken) public pure returns (bool) {
        return token < quoteToken;
    }

    /// @notice The tick a pool for this pair opens at: the stored reading, or its negation on the other side.
    /// @dev Does not check the quote is launchable — `requirePoolStartTick` is the one a launch goes through.
    function poolStartTick(address token, address quoteToken) public view returns (int24) {
        int24 startTick = quoteTokens[quoteToken].startTick;
        return launchIsToken0(token, quoteToken) ? startTick : -startTick;
    }

    /// @notice `poolStartTick`, refusing a quote that is disabled or has never been priced.
    function requirePoolStartTick(address token, address quoteToken) external view returns (int24) {
        QuoteConfig memory quote = quoteTokens[quoteToken];
        if (!quote.enabled) revert QuoteTokenNotEnabled();
        if (quote.updatedAt == 0) revert StartTickUnset();
        return launchIsToken0(token, quoteToken) ? quote.startTick : -quote.startTick;
    }

    /// @notice Every quote's config in one call, for a frontend filling a dropdown.
    function quoteConfigs(address[] calldata quoteTokenList) external view returns (QuoteConfig[] memory configs) {
        configs = new QuoteConfig[](quoteTokenList.length);
        for (uint256 i = 0; i < quoteTokenList.length; i++) {
            configs[i] = quoteTokens[quoteTokenList[i]];
        }
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @dev Upserts one address at a time, so dropping a token from the list leaves it live on-chain.
    ///      Delisting is an explicit write with `enabled = false`, never an omission.
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
            _validateStartTick(startTickList[i]);

            quoteTokens[quoteToken] =
                QuoteConfig({enabled: enabledList[i], startTick: startTickList[i], updatedAt: uint64(block.timestamp)});
            emit QuoteTokenConfigured(quoteToken, enabledList[i], startTickList[i]);
        }
    }

    /// @notice The daily job: reprice quotes that are already registered.
    function setStartTicks(address[] calldata quoteTokenList, int24[] calldata startTickList) external onlyOwner {
        if (quoteTokenList.length != startTickList.length) revert LengthMismatch();
        for (uint256 i = 0; i < quoteTokenList.length; i++) {
            QuoteConfig storage quote = quoteTokens[quoteTokenList[i]];
            if (!quote.enabled) revert QuoteTokenNotEnabled();
            _validateStartTick(startTickList[i]);

            emit StartTickUpdated(quoteTokenList[i], quote.startTick, startTickList[i]);
            quote.startTick = startTickList[i];
            quote.updatedAt = uint64(block.timestamp);
        }
    }

    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        emit AdminUpdated(admin, newAdmin);
        admin = newAdmin;
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev A launch negates this tick when the token lands on the token1 side, so the mirror has to be a
    ///      real tick too. Bounding it symmetrically is what makes that negation total — an int24 holds
    ///      values far outside the tick range, and -MIN_INT24 has no representation at all.
    function _validateStartTick(int24 startTick) internal pure {
        if (startTick < TickMath.MIN_TICK || startTick > TickMath.MAX_TICK) revert StartTickOutOfRange();
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}
}
