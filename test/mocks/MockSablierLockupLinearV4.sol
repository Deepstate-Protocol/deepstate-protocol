// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ISablierLockupLinearV4} from "../../src/interfaces/ISablierLockupLinearV4.sol";

contract MockSablierLockupLinearV4 is ISablierLockupLinearV4 {
    struct Stream {
        address sender;
        address recipient;
        uint128 depositAmount;
        IERC20 token;
        bool cancelable;
        bool transferable;
        string shape;
        UnlockAmounts unlockAmounts;
        uint40 granularity;
        Durations durations;
        uint256 nativeFee;
    }

    uint256 public nextStreamId = 1;
    mapping(uint256 streamId => Stream stream) internal _streams;

    function createWithDurationsLL(
        CreateWithDurations calldata params,
        UnlockAmounts calldata unlockAmounts,
        uint40 granularity,
        Durations calldata durations
    ) external payable returns (uint256 streamId) {
        IERC20(params.token).transferFrom(msg.sender, address(this), params.depositAmount);
        streamId = nextStreamId++;
        _streams[streamId] = Stream({
            sender: params.sender,
            recipient: params.recipient,
            depositAmount: params.depositAmount,
            token: params.token,
            cancelable: params.cancelable,
            transferable: params.transferable,
            shape: params.shape,
            unlockAmounts: unlockAmounts,
            granularity: granularity,
            durations: durations,
            nativeFee: msg.value
        });
    }

    function stream(uint256 streamId) external view returns (Stream memory) {
        return _streams[streamId];
    }
}
