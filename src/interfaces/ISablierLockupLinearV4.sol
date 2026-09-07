// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal ABI for creating a Sablier Lockup v4 linear stream.
interface ISablierLockupLinearV4 {
    struct CreateWithDurations {
        address sender;
        address recipient;
        uint128 depositAmount;
        IERC20 token;
        bool cancelable;
        bool transferable;
        string shape;
    }

    struct UnlockAmounts {
        uint128 start;
        uint128 cliff;
    }

    struct Durations {
        uint40 cliff;
        uint40 total;
    }

    function createWithDurationsLL(
        CreateWithDurations calldata params,
        UnlockAmounts calldata unlockAmounts,
        uint40 granularity,
        Durations calldata durations
    ) external payable returns (uint256 streamId);
}
