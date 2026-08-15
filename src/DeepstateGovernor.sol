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
import {IERC5805} from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Governor for the Deepstate ecosystem, backed directly by STATE vault shares.
contract DeepstateGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorPreventLateQuorum
{
    bytes32 private constant _TIMESTAMP_MODE_HASH = keccak256("mode=timestamp");
    uint256 public constant PROPOSAL_THRESHOLD_DENOMINATOR = 100;
    uint48 public constant MIN_VOTING_DELAY = 1 days;
    uint48 public constant MAX_VOTING_DELAY = 30 days;
    uint48 public constant MAX_LATE_QUORUM_VOTE_EXTENSION = 7 days;
    uint32 public constant MAX_VOTING_PERIOD = 30 days;
    uint256 public constant MINIMUM_QUORUM = 1e18;

    uint48 public immutable governanceStart;

    uint256 private _proposalThresholdNumerator;

    event ProposalThresholdNumeratorUpdated(uint256 oldNumerator, uint256 newNumerator);

    error TimestampClockRequired();
    error GovernanceNotStarted(uint48 currentTimepoint, uint48 governanceStart);
    error VotingDelayBelowMinimum(uint48 votingDelay, uint48 minimum);
    error VotingDelayAboveMaximum(uint48 votingDelay, uint48 maximum);
    error LateQuorumVoteExtensionAboveMaximum(uint48 voteExtension, uint48 maximum);
    error VotingPeriodAboveMaximum(uint32 votingPeriod, uint32 maximum);
    error InvalidProposalThresholdFraction(uint256 numerator, uint256 denominator);
    error AbsoluteProposalThresholdUnsupported();

    constructor(
        IVotes stateToken,
        uint48 governanceStartDelay,
        uint48 initialVotingDelay,
        uint32 initialVotingPeriod,
        uint256 initialProposalThresholdNumerator,
        uint256 quorumNumeratorValue,
        uint48 initialVoteExtension
    )
        Governor("DeepstateGovernor")
        GovernorSettings(initialVotingDelay, initialVotingPeriod, 0)
        GovernorVotes(stateToken)
        GovernorVotesQuorumFraction(quorumNumeratorValue)
        GovernorPreventLateQuorum(initialVoteExtension)
    {
        if (quorumNumeratorValue == 0) {
            revert GovernorInvalidQuorumFraction(quorumNumeratorValue, quorumDenominator());
        }
        if (!_usesTimestampClock(IERC5805(address(stateToken)))) {
            revert TimestampClockRequired();
        }
        _validateVotingDelayMinimum(initialVotingDelay);
        _validateVotingDelayMaximum(initialVotingDelay);
        _validateLateQuorumVoteExtension(initialVoteExtension);
        _validateVotingPeriod(initialVotingPeriod);

        governanceStart = SafeCast.toUint48(block.timestamp + governanceStartDelay);
        _updateProposalThresholdNumerator(initialProposalThresholdNumerator);
    }

    function _usesTimestampClock(IERC5805 stateToken) private view returns (bool) {
        try stateToken.clock() returns (uint48 timepoint) {
            if (timepoint != uint48(block.timestamp)) return false;
        } catch {
            return false;
        }

        try stateToken.CLOCK_MODE() returns (string memory mode) {
            return keccak256(bytes(mode)) == _TIMESTAMP_MODE_HASH;
        } catch {
            return false;
        }
    }

    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    function setVotingDelay(uint48 newVotingDelay) public override onlyGovernance {
        _validateVotingDelayMinimum(newVotingDelay);
        _validateVotingDelayMaximum(newVotingDelay);
        _setVotingDelay(newVotingDelay);
    }

    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    function setVotingPeriod(uint32 newVotingPeriod) public override onlyGovernance {
        _validateVotingPeriod(newVotingPeriod);
        _setVotingPeriod(newVotingPeriod);
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        uint256 numerator = _proposalThresholdNumerator;
        uint48 currentTimepoint = clock();
        if (currentTimepoint == 0) return numerator == 0 ? 0 : 1;

        uint256 pastTotalSupply = token().getPastTotalSupply(currentTimepoint - 1);
        if (pastTotalSupply == 0 && numerator != 0) return 1;

        return Math.mulDiv(pastTotalSupply, numerator, PROPOSAL_THRESHOLD_DENOMINATOR, Math.Rounding.Ceil);
    }

    function proposalThresholdNumerator() public view returns (uint256) {
        return _proposalThresholdNumerator;
    }

    function updateProposalThresholdNumerator(uint256 newNumerator) public onlyGovernance {
        _updateProposalThresholdNumerator(newNumerator);
    }

    function setProposalThreshold(uint256) public override onlyGovernance {
        revert AbsoluteProposalThresholdUnsupported();
    }

    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override returns (uint256) {
        uint48 currentTimepoint = clock();
        uint48 start = governanceStart;
        if (currentTimepoint < start) revert GovernanceNotStarted(currentTimepoint, start);
        return super.propose(targets, values, calldatas, description);
    }

    function quorum(uint256 timepoint) public view override(Governor, GovernorVotesQuorumFraction) returns (uint256) {
        return Math.max(super.quorum(timepoint), MINIMUM_QUORUM);
    }

    function _updateQuorumNumerator(uint256 newQuorumNumerator) internal override {
        if (newQuorumNumerator == 0) {
            revert GovernorInvalidQuorumFraction(newQuorumNumerator, quorumDenominator());
        }
        super._updateQuorumNumerator(newQuorumNumerator);
    }

    function proposalDeadline(uint256 proposalId)
        public
        view
        override(Governor, GovernorPreventLateQuorum)
        returns (uint256)
    {
        return super.proposalDeadline(proposalId);
    }

    function setLateQuorumVoteExtension(uint48 newVoteExtension) public override onlyGovernance {
        _validateLateQuorumVoteExtension(newVoteExtension);
        _setLateQuorumVoteExtension(newVoteExtension);
    }

    function _tallyUpdated(uint256 proposalId) internal override(Governor, GovernorPreventLateQuorum) {
        super._tallyUpdated(proposalId);
    }

    function _validateVotingDelayMaximum(uint48 votingDelay_) private pure {
        uint48 maximum = MAX_VOTING_DELAY;
        if (votingDelay_ > maximum) revert VotingDelayAboveMaximum(votingDelay_, maximum);
    }

    function _validateVotingDelayMinimum(uint48 votingDelay_) private pure {
        uint48 minimum = MIN_VOTING_DELAY;
        if (votingDelay_ < minimum) revert VotingDelayBelowMinimum(votingDelay_, minimum);
    }

    function _validateLateQuorumVoteExtension(uint48 voteExtension) private pure {
        uint48 maximum = MAX_LATE_QUORUM_VOTE_EXTENSION;
        if (voteExtension > maximum) revert LateQuorumVoteExtensionAboveMaximum(voteExtension, maximum);
    }

    function _validateVotingPeriod(uint32 votingPeriod_) private pure {
        uint32 maximum = MAX_VOTING_PERIOD;
        if (votingPeriod_ > maximum) revert VotingPeriodAboveMaximum(votingPeriod_, maximum);
    }

    function _updateProposalThresholdNumerator(uint256 newNumerator) internal {
        uint256 denominator = PROPOSAL_THRESHOLD_DENOMINATOR;
        if (newNumerator == 0 || newNumerator > denominator) {
            revert InvalidProposalThresholdFraction(newNumerator, denominator);
        }

        uint256 oldNumerator = _proposalThresholdNumerator;
        _proposalThresholdNumerator = newNumerator;
        emit ProposalThresholdNumeratorUpdated(oldNumerator, newNumerator);
    }
}
