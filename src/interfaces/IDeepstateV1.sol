// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Administrative surface of the Deepstate V1 router.
interface IDeepstateV1 {
    function owner() external view returns (address);
    function poolHook(bytes32 poolId) external view returns (address);
    function setPoolHookConfig(address token0, address token1, address hook, bool token0Active, bool token1Active)
        external;
    function setFeeConfig(address recipient, uint16 bps) external;
    function transferOwnership(address newOwner) external payable;
}
