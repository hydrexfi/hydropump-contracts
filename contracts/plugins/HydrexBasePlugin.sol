// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.20;

import '@cryptoalgebra/integral-core/contracts/libraries/Plugins.sol';
import '@cryptoalgebra/integral-core/contracts/interfaces/plugin/IAlgebraPlugin.sol';

import './plugins/DynamicFeePlugin.sol';
import './plugins/VolatilityOraclePlugin.sol';
import './plugins/SlidingFeePlugin.sol';
import './plugins/SecurityPlugin.sol';
import './plugins/FarmingProxyPlugin.sol';

/// @title Hydropump Algebra plugin with a ten-block launch fee
/// @notice Preserves adaptive/sliding fees, security, oracle and farming behavior.
contract HydrexBasePlugin is DynamicFeePlugin, VolatilityOraclePlugin, SlidingFeePlugin, SecurityPlugin, FarmingProxyPlugin {
  using Plugins for uint8;

  /// @notice Fees use millionths: 990000 = 99% (not basis points).
  uint24 public constant LAUNCH_FEE_START = 990000;
  uint256 public constant LAUNCH_FEE_BLOCKS = 10;
  uint256 public launchBlock;
  bool public launchFeeStarted;

  error PluginAlreadyInitialized();
  event LaunchFeeStarted(uint256 indexed startBlock, uint24 startingFee, uint256 durationBlocks);

  /// @inheritdoc IAlgebraPlugin
  uint8 public constant override defaultPluginConfig =
    uint8(
      Plugins.BEFORE_POSITION_MODIFY_FLAG |
        Plugins.AFTER_INIT_FLAG |
        Plugins.BEFORE_SWAP_FLAG |
        Plugins.AFTER_SWAP_FLAG |
        Plugins.DYNAMIC_FEE |
        Plugins.BEFORE_FLASH_FLAG
    );

  constructor(
    address _pool,
    address _factory,
    address _pluginFactory,
    AlgebraFeeConfiguration memory _config,
    uint16 _baseFee
  ) AlgebraBasePlugin(_pool, _factory, _pluginFactory) DynamicFeePlugin(_config) SlidingFeePlugin(_baseFee) {}

  // ###### HOOKS ######

  function beforeInitialize(address, uint160) external override onlyPool returns (bytes4) {
    _updatePluginConfigInPool(defaultPluginConfig);
    return IAlgebraPlugin.beforeInitialize.selector;
  }

  function afterInitialize(address, uint160, int24 tick) external override onlyPool returns (bytes4) {
    // The public oracle initializer supports existing pools, but must not restart a launch.
    if (isInitialized) revert PluginAlreadyInitialized();
    _initialize_TWAP(tick);
    launchBlock = block.number;
    launchFeeStarted = true;
    emit LaunchFeeStarted(block.number, LAUNCH_FEE_START, LAUNCH_FEE_BLOCKS);
    return IAlgebraPlugin.afterInitialize.selector;
  }

  /// @dev unused
  function beforeModifyPosition(
    address,
    address,
    int24,
    int24,
    int128 liquidity,
    bytes calldata
  ) external override onlyPool returns (bytes4, uint24) {
    if (liquidity < 0) {
      _checkStatusOnBurn();
    } else {
      _checkStatus();
    }
    return (IAlgebraPlugin.beforeModifyPosition.selector, 0);
  }

  /// @dev unused
  function afterModifyPosition(address, address, int24, int24, int128, uint256, uint256, bytes calldata) external override onlyPool returns (bytes4) {
    _updatePluginConfigInPool(defaultPluginConfig); // should not be called, reset config
    return IAlgebraPlugin.afterModifyPosition.selector;
  }

  function beforeSwap(
    address,
    address,
    bool zeroToOne,
    int256,
    uint160,
    bool,
    bytes calldata
  ) external override onlyPool returns (bytes4, uint24, uint24) {
    uint16 newFee;
    bool _dynamicFeeEnabled = dynamicFeeEnabled;
    /// security plugin check
    _checkStatus();
    /// get ticks for slidiing fee calculation
    (, int24 currentTick, uint16 poolFee, ) = _getPoolState();
    int24 lastTick = _getLastTick();
    /// write timepoint to oracle
    _writeTimepoint();
    /// calculate volatility and dynamic fee if enabled
    if (_dynamicFeeEnabled) {
      uint88 volatilityAverage = _getAverageVolatilityLast();
      newFee = _getCurrentFee(volatilityAverage);
    }
    /// calcucalate sliding fee based on dynamic fee if enabled
    if (slidingFeeEnabled) {
      newFee = _getFeeAndUpdateFactors(zeroToOne, currentTick, lastTick, _dynamicFeeEnabled, newFee);
    }

    return (IAlgebraPlugin.beforeSwap.selector, _launchFee(newFee, poolFee), 0);
  }

  /// @dev Preconditions: normalOverride and poolFee are the current normal fee inputs.
  /// During blocks [launchBlock, launchBlock + 10), return a linear interpolation
  /// from 99% to this swap's normal fee, rounding the fee up by at most one unit.
  /// Invariant: normalFee <= result <= 990000 < 1000000 during the launch window.
  /// At expiry return the original override, including zero (the pool's fallback
  /// sentinel). Applies to both directions and exact input/output; no caller exemption.
  /// Existing pools initialized through the public oracle initializer have no launch window.
  function _launchFee(uint16 normalOverride, uint16 poolFee) internal view returns (uint24) {
    if (!launchFeeStarted) return normalOverride;
    uint256 elapsed = block.number - launchBlock;
    if (elapsed >= LAUNCH_FEE_BLOCKS) return normalOverride;
    uint256 normalFee = normalOverride == 0 ? poolFee : normalOverride;
    return uint24(LAUNCH_FEE_START - ((LAUNCH_FEE_START - normalFee) * elapsed) / LAUNCH_FEE_BLOCKS);
  }

  function afterSwap(address, address, bool zeroToOne, int256, uint160, int256, int256, bytes calldata) external override onlyPool returns (bytes4) {
    _updateVirtualPoolTick(zeroToOne);
    return IAlgebraPlugin.afterSwap.selector;
  }

  /// @dev unused
  function beforeFlash(address, address, uint256, uint256, bytes calldata) external override onlyPool returns (bytes4) {
    _checkStatus();
    return IAlgebraPlugin.beforeFlash.selector;
  }

  /// @dev unused
  function afterFlash(address, address, uint256, uint256, uint256, uint256, bytes calldata) external override onlyPool returns (bytes4) {
    _updatePluginConfigInPool(defaultPluginConfig); // should not be called, reset config
    return IAlgebraPlugin.afterFlash.selector;
  }

  function getCurrentFee() external view override returns (uint16 fee) {
    uint88 volatilityAverage = _getAverageVolatilityLast();
    fee = _getCurrentFee(volatilityAverage);
  }
}
