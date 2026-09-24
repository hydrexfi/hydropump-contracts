// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.20;

import "./HydrexBasePluginFactory.sol";

/// @notice Dedicated custom-pool namespace and plugin factory for one Hydropump launcher.
/// @dev Algebra governance must grant this contract CUSTOM_POOL_DEPLOYER. No global
/// default plugin changes or per-launch administrator transactions are required.
contract HydropumpPoolDeployer is HydrexBasePluginFactory {
    address public immutable launcher;
    address private pendingPool;

    error OnlyLauncher();
    error InvalidConfiguration();
    error InvalidCallback();
    error CreationInProgress();
    error ExistingPoolNotSupported();

    constructor(address factory_, address launcher_, address settingsSource) HydrexBasePluginFactory(factory_) {
        if (factory_.code.length == 0 || launcher_.code.length == 0 || settingsSource.code.length == 0) {
            revert InvalidConfiguration();
        }
        launcher = launcher_;
        IHydrexBasePluginFactory source = IHydrexBasePluginFactory(settingsSource);
        if (source.algebraFactory() != factory_) revert InvalidConfiguration();
        (uint16 a1, uint16 a2, uint32 b1, uint32 b2, uint16 g1, uint16 g2, uint16 base) =
            source.defaultFeeConfiguration();
        defaultFeeConfiguration = AlgebraFeeConfiguration(a1, a2, b1, b2, g1, g2, base);
        AdaptiveFee.validateFeeConfiguration(defaultFeeConfiguration);
        defaultBaseFee = source.defaultBaseFee();
        dynamicFeeStatus = source.dynamicFeeStatus();
        slidingFeeStatus = source.slidingFeeStatus();
        securityRegistry = source.securityRegistry();
        farmingAddress = source.farmingAddress();
        emit DefaultFeeConfiguration(defaultFeeConfiguration);
        emit DefaultBaseFee(defaultBaseFee);
        emit DynamicFeeStatus(dynamicFeeStatus);
        emit SlidingFeeStatus(slidingFeeStatus);
        emit SecurityRegistry(securityRegistry);
        emit FarmingAddress(farmingAddress);
    }

    /// @dev Only the bound launcher may create; quote assets may be precompiles.
    /// Postcondition: a fresh custom pool and its own plugin exist in this namespace.
    /// Initialization must follow atomically in the launch transaction, before minting/buying.
    function createPool(address token0, address token1) external returns (address pool) {
        if (msg.sender != launcher) revert OnlyLauncher();
        if (pendingPool != address(0)) revert CreationInProgress();
        if (token0 == address(0) || token0 >= token1) revert InvalidConfiguration();
        // Either side can be a quote precompile. The bound launcher deploys the launch
        // token and validates the quote with PairDirectory before reaching this call.
        pendingPool = IAlgebraFactory(algebraFactory).computeCustomPoolAddress(address(this), token0, token1);
        pool = IAlgebraFactory(algebraFactory).createCustomPool(address(this), launcher, token0, token1, "");
        if (pool != pendingPool) revert InvalidCallback();
        delete pendingPool;
    }

    function beforeCreatePoolHook(
        address pool,
        address creator,
        address deployer,
        address token0,
        address token1,
        bytes calldata
    ) external override returns (address) {
        if (
            msg.sender != algebraFactory || pendingPool == address(0) || pool != pendingPool || creator != launcher
                || deployer != address(this)
                || pool != IAlgebraFactory(algebraFactory).computeCustomPoolAddress(address(this), token0, token1)
        ) revert InvalidCallback();
        return _createPlugin(pool);
    }

    function afterCreatePoolHook(address plugin, address pool, address deployer) external view override {
        if (
            msg.sender != algebraFactory || pool != pendingPool || deployer != address(this) || plugin == address(0)
                || pluginByPool[pool] != plugin
        ) revert InvalidCallback();
    }

    /// @dev This factory is only for fresh launches; never retrofit the fee on existing pools.
    function createPluginForExistingPool(address, address) external pure override returns (address) {
        revert ExistingPoolNotSupported();
    }
}
