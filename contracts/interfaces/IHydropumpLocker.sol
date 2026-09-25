// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IHydropumpLocker {
    function registerLaunch(
        address token,
        address quoteToken,
        address pool,
        address creator,
        address creatorRecipient,
        uint256[] calldata positionIds
    ) external;

    /// @notice Where a launch's creator share is paid. The single source of truth — fee uses read it
    ///         rather than keeping their own copy, so redirecting it moves every strategy at once.
    function creatorRecipient(address token) external view returns (address);

    function creatorOf(address token) external view returns (address);

    function executeKeeperBuyback(address token, uint256 veTokenId)
        external
        returns (uint256 launchTokenAmount, uint256 quoteAmount);

    /// @notice The registry the locker spends a creator's share through.
    function feeUseRegistry() external view returns (address);

    function quoteTokenOf(address token) external view returns (address);

    function poolOf(address token) external view returns (address);

    function getPositions(address token) external view returns (uint256[] memory);
}
