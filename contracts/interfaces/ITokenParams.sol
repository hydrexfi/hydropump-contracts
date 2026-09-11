// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Implemented by whatever deploys a HydropumpToken, so the token's argument-less constructor can
///         read its own parameters back.
interface ITokenParams {
    function pendingToken()
        external
        view
        returns (string memory name, string memory symbol, uint256 supply, address recipient);
}
