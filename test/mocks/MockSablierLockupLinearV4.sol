// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Lockup} from "@sablier/lockup/src/types/Lockup.sol";
import {LockupLinear} from "@sablier/lockup/src/types/LockupLinear.sol";

import {ISablierLockupLinearV4} from "../../src/interfaces/ISablierLockupLinearV4.sol";

contract MockSablierLockupLinearV4 is ISablierLockupLinearV4 {
    using SafeERC20 for IERC20;

    struct Stream {
        address funder;
        address sender;
        address recipient;
        address token;
        uint128 depositAmount;
        bool cancelable;
        bool transferable;
        string shape;
        uint128 startUnlockAmount;
        uint128 cliffUnlockAmount;
        uint40 granularity;
        uint40 cliffDuration;
        uint40 totalDuration;
    }

    uint256 public nextStreamId = 1;
    bool public revertCreate;
    bool public skipTokenPull;
    address public reentryTarget;
    bytes public reentryData;
    mapping(uint256 streamId => Stream stream) private _streams;

    error CreateReverted();

    function setRevertCreate(bool value) external {
        revertCreate = value;
    }

    function setSkipTokenPull(bool value) external {
        skipTokenPull = value;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function stream(uint256 streamId) external view returns (Stream memory) {
        return _streams[streamId];
    }

    function createWithDurationsLL(
        Lockup.CreateWithDurations calldata params,
        LockupLinear.UnlockAmounts calldata unlockAmounts,
        uint40 granularity,
        LockupLinear.Durations calldata durations
    ) external payable returns (uint256 streamId) {
        if (revertCreate) revert CreateReverted();

        address target = reentryTarget;
        if (target != address(0)) {
            (bool success, bytes memory result) = target.call(reentryData);
            if (!success) {
                assembly ("memory-safe") {
                    revert(add(result, 0x20), mload(result))
                }
            }
        }

        streamId = nextStreamId++;
        _streams[streamId] = Stream({
            funder: msg.sender,
            sender: params.sender,
            recipient: params.recipient,
            token: address(params.token),
            depositAmount: params.depositAmount,
            cancelable: params.cancelable,
            transferable: params.transferable,
            shape: params.shape,
            startUnlockAmount: unlockAmounts.start,
            cliffUnlockAmount: unlockAmounts.cliff,
            granularity: granularity,
            cliffDuration: durations.cliff,
            totalDuration: durations.total
        });

        if (!skipTokenPull) params.token.safeTransferFrom(msg.sender, address(this), params.depositAmount);
    }
}
