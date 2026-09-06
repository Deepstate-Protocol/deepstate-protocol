// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {DeepstateToken} from "./DeepstateToken.sol";

/// @notice Capped, vote-enabled DEEP with automatic self-delegation on first receipt.
contract DeepstateTokenV2 is DeepstateToken, ERC20Votes {
    uint256 public supplyCap;

    event SupplyCapRaised(uint256 previousCap, uint256 newCap);

    error InvalidSupplyCap();
    error SupplyCapNotRaised(uint256 currentCap, uint256 proposedCap);
    error SupplyCapExceeded(uint256 cap, uint256 attemptedSupply);

    constructor(address admin_, uint256 initialSupplyCap)
        DeepstateToken(admin_, "Deepstate", "DEEP")
        EIP712("Deepstate", "1")
    {
        if (initialSupplyCap == 0 || initialSupplyCap > type(uint208).max) {
            revert InvalidSupplyCap();
        }
        supplyCap = initialSupplyCap;
    }

    /// @notice Governance may expand issuance but cannot reduce its prior cap commitment.
    function raiseSupplyCap(uint256 newCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 currentCap = supplyCap;
        if (newCap <= currentCap) revert SupplyCapNotRaised(currentCap, newCap);
        if (newCap > type(uint208).max) revert InvalidSupplyCap();

        supplyCap = newCap;
        emit SupplyCapRaised(currentCap, newCap);
    }

    function clock() public view override returns (uint48) {
        return SafeCast.toUint48(block.timestamp);
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    function _update(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        if (from == address(0)) {
            uint256 attemptedSupply = totalSupply() + amount;
            uint256 cap = supplyCap;
            if (attemptedSupply > cap) revert SupplyCapExceeded(cap, attemptedSupply);
        }

        super._update(from, to, amount);

        if (to != address(0) && delegates(to) == address(0)) {
            _delegate(to, to);
        }
    }
}
