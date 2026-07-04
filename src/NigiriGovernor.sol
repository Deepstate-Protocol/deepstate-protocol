// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorPreventLateQuorum} from "@openzeppelin/contracts/governance/extensions/GovernorPreventLateQuorum.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {
    GovernorVotesQuorumFraction
} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {Votes} from "@openzeppelin/contracts/governance/utils/Votes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Governor for the Nigiri ecosystem, backed by escrowed vNIGIRI shares.
contract NigiriGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorPreventLateQuorum,
    ERC20Votes
{
    using SafeERC20 for IERC20;

    IERC20 public immutable vNigiri;

    event GovernanceEntered(address indexed account, uint256 shares);
    event GovernanceExited(address indexed account, uint256 shares);

    error ZeroAddress();
    error ZeroShares();

    constructor(
        IERC20 vNigiri_,
        uint48 initialVotingDelay,
        uint32 initialVotingPeriod,
        uint256 initialProposalThreshold,
        uint256 quorumNumeratorValue,
        uint48 initialVoteExtension
    )
        Governor("NigiriGovernor")
        ERC20("NigiriGovernor", "gNIGIRI")
        GovernorSettings(initialVotingDelay, initialVotingPeriod, initialProposalThreshold)
        GovernorVotes(IVotes(address(this)))
        GovernorVotesQuorumFraction(quorumNumeratorValue)
        GovernorPreventLateQuorum(initialVoteExtension)
    {
        if (address(vNigiri_) == address(0)) revert ZeroAddress();
        vNigiri = vNigiri_;
    }

    /// @notice Escrows vNIGIRI shares and mints 1:1 governance voting tokens.
    function enterGovernance(uint256 shares) external returns (uint256 minted) {
        if (shares == 0) revert ZeroShares();

        vNigiri.safeTransferFrom(msg.sender, address(this), shares);
        _mint(msg.sender, shares);

        emit GovernanceEntered(msg.sender, shares);
        return shares;
    }

    /// @notice Burns governance voting tokens and returns the escrowed vNIGIRI shares 1:1.
    function exitGovernance(uint256 shares) external returns (uint256 returnedShares) {
        if (shares == 0) revert ZeroShares();

        _burn(msg.sender, shares);
        vNigiri.safeTransfer(msg.sender, shares);

        emit GovernanceExited(msg.sender, shares);
        return shares;
    }

    function name() public view override(Governor, ERC20) returns (string memory) {
        return super.name();
    }

    function clock() public view override(Governor, GovernorVotes, Votes) returns (uint48) {
        return Votes.clock();
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public view override(Governor, GovernorVotes, Votes) returns (string memory) {
        return Votes.CLOCK_MODE();
    }

    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    function quorum(uint256 timepoint) public view override(Governor, GovernorVotesQuorumFraction) returns (uint256) {
        return super.quorum(timepoint);
    }

    function proposalDeadline(uint256 proposalId)
        public
        view
        override(Governor, GovernorPreventLateQuorum)
        returns (uint256)
    {
        return super.proposalDeadline(proposalId);
    }

    function _tallyUpdated(uint256 proposalId) internal override(Governor, GovernorPreventLateQuorum) {
        super._tallyUpdated(proposalId);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override returns (uint256) {
        return super.nonces(owner);
    }
}
