// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {DeepstateRewarder} from "./DeepstateRewarder.sol";

/// @title Deepstate Rewarder V2
/// @notice Extends the original rewarder with governance-controlled recovery of remaining rewards.
contract DeepstateRewarderV2 is DeepstateRewarder {
    using SafeERC20 for IERC20;

    event RewardBalanceWithdrawn(address indexed receiver, uint256 amount);

    error InvalidReceiver();

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

    /// @notice Withdraw the rewarder's entire remaining reward-token balance.
    /// @dev The owner is governance after deployment. Outstanding claims remain accounted for and
    /// will revert during distribution until governance restores sufficient funding.
    function withdrawRewardBalance(address receiver) external onlyOwner returns (uint256 amount) {
        if (receiver == address(0)) revert InvalidReceiver();

        IERC20 token = IERC20(rewardToken);
        amount = token.balanceOf(address(this));
        if (amount != 0) token.safeTransfer(receiver, amount);

        emit RewardBalanceWithdrawn(receiver, amount);
    }
}
