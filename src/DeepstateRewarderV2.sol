// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeepstateRewarder} from "./DeepstateRewarder.sol";
import {IBurnableERC20} from "./interfaces/IBurnableERC20.sol";

/// @title Deepstate Rewarder V2
/// @notice Extends the original rewarder with owner-controlled burning of remaining rewards.
/// @dev Ownable is inherited through DeepstateRewarder.
contract DeepstateRewarderV2 is DeepstateRewarder {
    event RewardBalanceBurned(uint256 amount);

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

    /// @notice Burn an amount of the reward token held by this rewarder.
    /// @dev Outstanding claims remain accounted for and will revert until funding is restored.
    function burnBalance(uint256 amount) external onlyOwner {
        IBurnableERC20(rewardToken).burn(amount);
        emit RewardBalanceBurned(amount);
    }
}
