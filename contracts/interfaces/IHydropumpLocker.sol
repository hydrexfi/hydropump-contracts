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
}
