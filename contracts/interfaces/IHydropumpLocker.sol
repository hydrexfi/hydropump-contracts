// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HydropumpFeeEscrow} from "../HydropumpFeeEscrow.sol";

interface IHydropumpLocker {
    function registerLaunch(
        address token,
        address quoteToken,
        address pool,
        address creator,
        address creatorRecipient,
        uint256[] calldata positionIds
    ) external;

    function registerLaunchWithAutoLp(
        address token,
        address quoteToken,
        address pool,
        address creator,
        address creatorRecipient,
        uint256[] calldata positionIds,
        address strategy,
        uint64 autoLpBps
    ) external;

    function feeEscrow() external view returns (HydropumpFeeEscrow);
}
