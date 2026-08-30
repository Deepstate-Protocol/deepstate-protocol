// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";

import {IDeepstateV1} from "./interfaces/IDeepstateV1.sol";

/// @title Deepstate V1 Controller
/// @notice Governance-owned capability boundary around the single-owner Deepstate router.
contract DeepstateV1Controller is Ownable {
    IDeepstateV1 public immutable deepstate;

    /// @notice Revocable contract permitted only to configure pool hooks.
    address public hookManager;

    event HookManagerSet(address indexed previousHookManager, address indexed newHookManager);
    event DeepstateFeeConfigured(address indexed recipient, uint16 bps);
    event DeepstateOwnershipTransferred(address indexed newOwner);

    error InvalidOwner();
    error InvalidDeepstate();

    constructor(address owner_, address deepstate_) {
        if (owner_ == address(0)) revert InvalidOwner();
        if (deepstate_ == address(0) || deepstate_.code.length == 0) revert InvalidDeepstate();

        _initializeOwner(owner_);
        deepstate = IDeepstateV1(deepstate_);
    }

    modifier onlyHookManagerOrOwner() {
        _checkHookManagerOrOwner();
        _;
    }

    /// @notice Appoint or revoke the sole delegated pool-hook manager.
    function setHookManager(address newHookManager) external onlyOwner {
        address previousHookManager = hookManager;
        hookManager = newHookManager;
        emit HookManagerSet(previousHookManager, newHookManager);
    }

    /// @notice Configure one pool hook as governance or the delegated hook manager.
    function setPoolHookConfig(address token0, address token1, address hook, bool token0Active, bool token1Active)
        external
        onlyHookManagerOrOwner
    {
        deepstate.setPoolHookConfig(token0, token1, hook, token0Active, token1Active);
    }

    /// @notice Configure protocol fees. The hook manager has no access to this capability.
    function setDeepstateFeeConfig(address recipient, uint16 bps) external onlyOwner {
        deepstate.setFeeConfig(recipient, bps);
        emit DeepstateFeeConfigured(recipient, bps);
    }

    /// @notice Return router ownership to governance or another governance-approved owner.
    function transferDeepstateOwnership(address newOwner) external onlyOwner {
        deepstate.transferOwnership(newOwner);
        emit DeepstateOwnershipTransferred(newOwner);
    }

    function _checkHookManagerOrOwner() private view {
        if (msg.sender != hookManager) _checkOwner();
    }
}
