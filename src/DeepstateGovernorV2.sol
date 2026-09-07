// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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

    /// @notice The live proposal threshold is always a percentage of the current 2DEEP supply.
    function proposalThreshold() public view override returns (uint256) {
        uint256 supply = IERC20(address(token())).totalSupply();
        return Math.max(
            Math.mulDiv(supply, proposalThresholdNumerator(), PROPOSAL_THRESHOLD_DENOMINATOR, Math.Rounding.Ceil), 1
        );
    }

    /// @notice Quorum is always a percentage of the current 2DEEP supply; `timepoint` is intentionally ignored.
    function quorum(uint256) public view override returns (uint256) {
        uint256 supply = IERC20(address(token())).totalSupply();
        return Math.max(Math.mulDiv(supply, quorumNumerator(), quorumDenominator()), MINIMUM_QUORUM);
    }

    function _validateCancel(uint256 proposalId, address caller) internal view override returns (bool) {
        return isGuardian[caller] || super._validateCancel(proposalId, caller);
    }
}
