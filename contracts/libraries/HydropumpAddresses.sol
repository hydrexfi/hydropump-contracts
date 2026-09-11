// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title HydropumpAddresses
/// @notice Base mainnet addresses Hydropump builds on. Single source of truth.
library HydropumpAddresses {
    /// @notice Hydrex (Algebra Integral) NonfungiblePositionManager
    address internal constant NONFUNGIBLE_POSITION_MANAGER = 0xC63E9672f8e93234C73cE954a1d1292e4103Ab86;

    /// @notice Hydrex (Algebra Integral) factory
    address internal constant ALGEBRA_FACTORY = 0x36077D39cdC65E1e3FB65810430E5b2c4D5fA29E;

    /// @notice Hydrex (Algebra Integral) swap router, used for the single-hop dev buy at launch
    address internal constant SWAP_ROUTER = 0x6f4bE24d7dC93b6ffcBAb3Fd0747c5817Cea3F9e;

    /// @notice Hydrex multi router, used for the multi-hop buyback routes
    address internal constant MULTI_ROUTER = 0x599bFa1039C9e22603F15642B711D56BE62071f4;

    /// @notice Hydrex classic (solidly) pair factory, used for the gauge-carrying pair
    address internal constant PAIR_FACTORY = 0xC47F17c4fd96F50eFD2A2448ceDe5C185c084bf0;

    /// @notice Canonical WETH on Base
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    /// @notice The Hydropump gauge and its bribe contracts, from the placeholder vAMM-HPONE/HPTWO pair.
    ///         Bought-back HYDX goes to GAUGE_BRIBE, which is what veHYDX voters collect.
    address internal constant GAUGE = 0x7aDD6e6d16A42264F62d84412D182425cad443c4;
    address internal constant GAUGE_BRIBE = 0xAb444e493d0e6E03d1ce9353956e0E4ad2ff1642;
    address internal constant GAUGE_PAIR = 0x2778CF77C7BE4Fc9c0dbBb2006c0c0e2807157F8;

    /// @notice HYDX, the token the protocol fee share is bought back into
    address internal constant HYDX = 0x00000e7efa313F4E11Bfff432471eD9423AC6B30;
}
