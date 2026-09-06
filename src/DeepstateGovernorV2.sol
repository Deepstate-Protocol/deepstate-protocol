// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {DeepstateGovernor} from "./DeepstateGovernor.sol";

/// @notice Deepstate Governor extended with a governance-managed cancellation guardian set.
contract DeepstateGovernorV2 is DeepstateGovernor {
    mapping(address guardian => bool enabled) public isGuardian;

    event GuardianSet(address indexed guardian, bool enabled);

    error InvalidGuardian();

    constructor(
        IVotes token_,
        uint48 governanceStartDelay,
        uint48 initialVotingDelay,
        uint32 initialVotingPeriod,
        uint256 initialProposalThresholdNumerator,
        uint256 quorumNumeratorValue,
        uint48 initialVoteExtension
    )
        DeepstateGovernor(
            token_,
            governanceStartDelay,
            initialVotingDelay,
            initialVotingPeriod,
            initialProposalThresholdNumerator,
            quorumNumeratorValue,
            initialVoteExtension
        )
    {}

    /// @notice Add or remove an address that may cancel any unexecuted proposal.
    function setGuardian(address guardian, bool enabled) external onlyGovernance {
        if (guardian == address(0)) revert InvalidGuardian();
        isGuardian[guardian] = enabled;
        emit GuardianSet(guardian, enabled);
    }

    function _validateCancel(uint256 proposalId, address caller) internal view override returns (bool) {
        return isGuardian[caller] || super._validateCancel(proposalId, caller);
    }
}
