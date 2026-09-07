// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {DeepstateRewarder} from "./DeepstateRewarder.sol";
import {IBurnableERC20} from "./interfaces/IBurnableERC20.sol";

/// @notice Rewarder that starts a fresh schedule for orders already resting in the active market.
/// @dev Retains Rewarder V2's owner-controlled balance-burning capability.
contract DeepstateRewarderV3 is DeepstateRewarder {
    constructor(
        address owner_,
        address deepstate_,
        address rewardToken_,
        bytes32 poolId_,
        address token0_,
        address token1_,
        uint96 sideEmissionCap_,
        uint32 emissionDuration_,
        uint160 token0StartQuantity_,
        uint160 token0MaxQuantity_,
        uint160 token1StartQuantity_,
        uint160 token1MaxQuantity_
    )
        DeepstateRewarder(
            owner_,
            deepstate_,
            rewardToken_,
            poolId_,
            token0_,
            token1_,
            sideEmissionCap_,
            emissionDuration_,
            token0StartQuantity_,
            token0MaxQuantity_,
            token1StartQuantity_,
            token1MaxQuantity_
        )
    {}

    /// @notice Burn this rewarder's entire reward-token balance.
    function burnBalance() external onlyOwner {
        uint256 amount = SafeTransferLib.balanceOf(rewardToken, address(this));
        IBurnableERC20(rewardToken).burn(amount);
    }
}
