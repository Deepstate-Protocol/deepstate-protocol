// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Ecosystem ERC20 with governance-administered mint authority.
contract DeepstateToken is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    uint256 private _defaultAdminCount;

    error ZeroAddress();
    error LastDefaultAdmin();

    constructor(address admin_, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        if (admin_ == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function defaultAdminCount() external view returns (uint256) {
        return _defaultAdminCount;
    }

    function _grantRole(bytes32 role, address account) internal override returns (bool) {
        if (role == DEFAULT_ADMIN_ROLE && account == address(0)) revert ZeroAddress();

        bool granted = super._grantRole(role, account);
        if (granted && role == DEFAULT_ADMIN_ROLE) ++_defaultAdminCount;
        return granted;
    }

    function _revokeRole(bytes32 role, address account) internal override returns (bool) {
        if (role == DEFAULT_ADMIN_ROLE && hasRole(role, account)) {
            if (_defaultAdminCount == 1) revert LastDefaultAdmin();

            bool revoked = super._revokeRole(role, account);
            if (revoked) --_defaultAdminCount;
            return revoked;
        }

        return super._revokeRole(role, account);
    }
}
