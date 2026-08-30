// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Lockup} from "@sablier/lockup/src/types/Lockup.sol";
import {LockupLinear} from "@sablier/lockup/src/types/LockupLinear.sol";

/// @notice Minimal Sablier Lockup v4 interface used to create linear streams.
interface ISablierLockupLinearV4 {
    function createWithDurationsLL(
        Lockup.CreateWithDurations calldata params,
        LockupLinear.UnlockAmounts calldata unlockAmounts,
        uint40 granularity,
        LockupLinear.Durations calldata durations
    ) external payable returns (uint256 streamId);
}
