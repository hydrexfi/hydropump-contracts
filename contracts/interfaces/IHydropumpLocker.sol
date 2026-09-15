// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HydropumpFeeEscrow} from "../HydropumpFeeEscrow.sol";

interface IHydropumpLocker {
    struct FeeRoute {
        uint8 routeType;
        uint64 bps;
        address strategy;
    }

    function registerLaunch(
        address token,
        address quoteToken,
        address pool,
        address creator,
        address creatorRecipient,
        uint256[] calldata positionIds
    ) external;

    function registerLaunchWithRoutes(
        address token,
        address quoteToken,
        address pool,
        address creator,
        address creatorRecipient,
        uint256[] calldata positionIds,
        FeeRoute[] calldata routes
    ) external;

    function feeEscrow() external view returns (HydropumpFeeEscrow);

    function protocolFeeRecipient() external view returns (address);
}
