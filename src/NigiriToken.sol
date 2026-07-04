// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "solady/auth/Ownable.sol";
import {ERC20Votes} from "solady/tokens/ERC20Votes.sol";

/// @notice Ecosystem ERC20 whose mint authority is controlled by the contract owner.
contract NigiriToken is ERC20Votes, Ownable {
    string internal tokenName;
    string internal tokenSymbol;
    address public minter;

    event MinterSet(address indexed minter);

    error ZeroAddress();
    error NotMinter();

    constructor(address owner_, string memory name_, string memory symbol_) {
        if (owner_ == address(0)) revert ZeroAddress();

        tokenName = name_;
        tokenSymbol = symbol_;

        _initializeOwner(owner_);
    }

    function name() public view override returns (string memory) {
        return tokenName;
    }

    function symbol() public view override returns (string memory) {
        return tokenSymbol;
    }

    /// @notice OZ Governor compatibility for Solady's ERC20Votes total-supply checkpoints.
    function getPastTotalSupply(uint256 timepoint) public view returns (uint256) {
        return getPastVotesTotalSupply(timepoint);
    }

    function setMinter(address minter_) external onlyOwner {
        minter = minter_;
        emit MinterSet(minter_);
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert NotMinter();
        if (to == address(0)) revert ZeroAddress();
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        ERC20Votes._afterTokenTransfer(from, to, amount);
    }
}
