// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IFeeUseRegistry {
    /// @notice Record which fee use a launch starts on. Launcher only, once, at launch.
    function setLaunchFeeUse(address token, bytes32 feeUse) external;

    function feeUseOf(address token) external view returns (bytes32);

    function feeUseImpl(bytes32 feeUse) external view returns (address);

    /// @notice The contract a launch's fees will reach, after the default is applied.
    function implementationFor(address token) external view returns (address);
}
