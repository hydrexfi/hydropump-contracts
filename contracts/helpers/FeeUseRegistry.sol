// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IFeeUseRegistry} from "../interfaces/IFeeUseRegistry.sol";

/// @title FeeUseRegistry
/// @notice Which fee use each launch's creator share is spent on.
contract FeeUseRegistry is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable, IFeeUseRegistry {
    address public launcher;

    /// @notice What a launch with no explicit choice falls back to.
    bytes32 public defaultFeeUse;

    mapping(bytes32 feeUse => address) public feeUseImpl;
    mapping(address token => bytes32) private _feeUseOf;

    /// @dev Reserved so added storage does not shift the layout. Keep vars + gap == 50.
    uint256[46] private __gap;

    event FeeUseRegistered(bytes32 indexed feeUse, address indexed implementation);
    event FeeUseReplaced(bytes32 indexed feeUse, address indexed previous, address indexed implementation);
    event DefaultFeeUseUpdated(bytes32 indexed previousFeeUse, bytes32 indexed newFeeUse);
    event LaunchFeeUseSet(address indexed token, bytes32 indexed feeUse, bool byCreator);
    event LauncherUpdated(address indexed previousLauncher, address indexed newLauncher);

    error NotLauncher();
    error ZeroAddress();
    error UnknownFeeUse();
    error FeeUseAlreadyRegistered();
    error AlreadySet();

    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner, address _launcher) external initializer {
        if (_owner == address(0)) revert ZeroAddress();
        __Ownable_init(_owner);
        __Ownable2Step_init();

        launcher = _launcher;
        emit LauncherUpdated(address(0), _launcher);
    }

    /*//////////////////////////////////////////////////////////////
                                 READ
    //////////////////////////////////////////////////////////////*/

    /// @notice Which fee use a launch is pointed at, falling back to the default.
    function feeUseOf(address token) public view returns (bytes32) {
        bytes32 chosen = _feeUseOf[token];
        return chosen == bytes32(0) ? defaultFeeUse : chosen;
    }

    /// @notice The contract a launch's fees will actually reach.
    function implementationFor(address token) public view returns (address) {
        return feeUseImpl[feeUseOf(token)];
    }

    /// @notice Whether a launch made its own choice, as opposed to sitting on the default.
    function hasExplicitFeeUse(address token) external view returns (bool) {
        return _feeUseOf[token] != bytes32(0);
    }

    /*//////////////////////////////////////////////////////////////
                              USER WRITE
    //////////////////////////////////////////////////////////////*/

    /// @notice The creator's choice, taken at launch. Launcher only, and only while nothing is set.
    function setLaunchFeeUse(address token, bytes32 feeUse) external {
        if (msg.sender != launcher) revert NotLauncher();
        if (feeUse == bytes32(0)) return; // no choice made; the launch rides the default
        if (_feeUseOf[token] != bytes32(0)) revert AlreadySet();
        if (feeUseImpl[feeUse] == address(0)) revert UnknownFeeUse();

        _feeUseOf[token] = feeUse;
        emit LaunchFeeUseSet(token, feeUse, true);
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @dev Write-once. Repointing an id under launches that already chose it would move their money
    ///      without their knowing, so a new strategy is a new id.
    function registerFeeUse(bytes32 feeUse, address implementation) external onlyOwner {
        if (feeUse == bytes32(0)) revert UnknownFeeUse();
        if (implementation == address(0)) revert ZeroAddress();
        if (feeUseImpl[feeUse] != address(0)) revert FeeUseAlreadyRegistered();

        feeUseImpl[feeUse] = implementation;
        emit FeeUseRegistered(feeUse, implementation);
    }

    /// @notice Swap what an id points at. For fixing a broken implementation, not for repurposing an id.
    /// @dev Every launch on this id moves at once, which is the point — the alternative is a new id and
    ///      repointing each launch by hand. Separate from `registerFeeUse` so an overwrite is always
    ///      deliberate rather than a mistyped first registration.
    function replaceFeeUse(bytes32 feeUse, address implementation) external onlyOwner {
        address previous = feeUseImpl[feeUse];
        if (previous == address(0)) revert UnknownFeeUse();
        if (implementation == address(0)) revert ZeroAddress();

        feeUseImpl[feeUse] = implementation;
        emit FeeUseReplaced(feeUse, previous, implementation);
    }

    function setDefaultFeeUse(bytes32 feeUse) external onlyOwner {
        if (feeUseImpl[feeUse] == address(0)) revert UnknownFeeUse();
        emit DefaultFeeUseUpdated(defaultFeeUse, feeUse);
        defaultFeeUse = feeUse;
    }

    /// @notice Repoint a launch. The escape hatch for a fee use that turns out to be broken.
    function setFeeUse(address token, bytes32 feeUse) external onlyOwner {
        if (feeUseImpl[feeUse] == address(0)) revert UnknownFeeUse();
        _feeUseOf[token] = feeUse;
        emit LaunchFeeUseSet(token, feeUse, false);
    }

    function setLauncher(address newLauncher) external onlyOwner {
        emit LauncherUpdated(launcher, newLauncher);
        launcher = newLauncher;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
