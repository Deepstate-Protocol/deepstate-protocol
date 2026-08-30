// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Factory-facing interface for policy-controlled DEEP minting.
interface IDeepstateMinterController {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function deepstateToken() external view returns (address);
    /// @notice Mint `amount` as the primary 70% tranche and vest the corresponding 30% tranche.
    function mint(address to, uint256 amount) external returns (uint256 streamId);
}
