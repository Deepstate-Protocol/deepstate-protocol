// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {
    GovernorVotesQuorumFraction
} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {ERC20Votes as SoladyERC20Votes} from "solady/tokens/ERC20Votes.sol";

import {NigiriGovernor} from "../src/NigiriGovernor.sol";
import {NigiriToken} from "../src/NigiriToken.sol";
import {NigiriVault} from "../src/NigiriVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockWETH} from "./mocks/MockWETH.sol";

contract GovernanceCallReceiver {
    uint256 public value;
    uint256 public paid;

    event Called(uint256 value, uint256 paid);

    function setValue(uint256 newValue) external payable {
        value = newValue;
        paid += msg.value;

        emit Called(newValue, msg.value);
    }
}

contract NigiriGovernanceOZCompatibilityTest is Test {
    uint48 internal constant VOTING_DELAY = 1;
    uint32 internal constant VOTING_PERIOD = 12;
    uint256 internal constant PROPOSAL_THRESHOLD = 0;
    uint256 internal constant QUORUM_NUMERATOR = 10;
    uint48 internal constant VOTE_EXTENSION = 4;

    uint256 internal constant ALICE_SHARES = 60e18;
    uint256 internal constant BOB_SHARES = 20e18;
    uint256 internal constant CAROL_SHARES = 15e18;
    uint256 internal constant DAVE_SHARES = 5e18;
    uint256 internal constant TOTAL_SHARES = ALICE_SHARES + BOB_SHARES + CAROL_SHARES + DAVE_SHARES;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal erin = makeAddr("erin");

    NigiriToken internal nigiri;
    MockERC20 internal valueToken;
    MockWETH internal wrappedNative;
    NigiriVault internal vault;
    NigiriGovernor internal governor;
    GovernanceCallReceiver internal receiver;

    function setUp() public {
        vm.startPrank(deployer);

        nigiri = new NigiriToken(deployer, "Nigiri", "NIGIRI");
        valueToken = new MockERC20("USD Coin", "USDC", 6);
        wrappedNative = new MockWETH();
        vault = new NigiriVault(
            deployer, address(nigiri), address(valueToken), address(wrappedNative), "vNigiri", "vNIGIRI"
        );
        governor = new NigiriGovernor(
            IVotes(address(vault)), VOTING_DELAY, VOTING_PERIOD, PROPOSAL_THRESHOLD, QUORUM_NUMERATOR, VOTE_EXTENSION
        );
        receiver = new GovernanceCallReceiver();

        nigiri.setMinter(deployer);
        vm.stopPrank();

        _depositAndDelegate(alice, ALICE_SHARES);
        _depositAndDelegate(bob, BOB_SHARES);
        _depositAndDelegate(carol, CAROL_SHARES);
        _depositAndDelegate(dave, DAVE_SHARES);

        vm.roll(vm.getBlockNumber() + 1);
    }

    function testGovernorConfigurationMatchesOZVotesModules() public view {
        assertEq(governor.name(), "NigiriGovernor");
        assertEq(address(governor.token()), address(vault));
        assertEq(governor.votingDelay(), VOTING_DELAY);
        assertEq(governor.votingPeriod(), VOTING_PERIOD);
        assertEq(governor.proposalThreshold(), PROPOSAL_THRESHOLD);
        assertEq(governor.quorumNumerator(), QUORUM_NUMERATOR);
        assertEq(governor.quorumDenominator(), 100);
        assertEq(governor.lateQuorumVoteExtension(), VOTE_EXTENSION);
        assertEq(governor.CLOCK_MODE(), vault.CLOCK_MODE());
        assertEq(governor.clock(), vault.clock());
        assertEq(governor.quorum(0), 0);
    }

    function testShimmedPastTotalSupplyTracksMintAndBurnCheckpoints() public {
        assertEq(vault.getPastTotalSupply(0), 0);

        uint256 initialCheckpoint = vm.getBlockNumber() - 1;
        assertEq(vault.getPastTotalSupply(initialCheckpoint), TOTAL_SHARES);
        assertEq(vault.getPastTotalSupply(initialCheckpoint), vault.getPastVotesTotalSupply(initialCheckpoint));

        _depositAndDelegate(erin, 10e18);
        assertEq(vault.totalSupply(), TOTAL_SHARES + 10e18);

        vm.roll(vm.getBlockNumber() + 1);
        uint256 mintCheckpoint = vm.getBlockNumber() - 1;
        assertEq(vault.getPastTotalSupply(mintCheckpoint), TOTAL_SHARES + 10e18);
        assertEq(vault.getPastTotalSupply(mintCheckpoint), vault.getPastVotesTotalSupply(mintCheckpoint));

        valueToken.mint(address(vault), 110e6);

        vm.prank(erin);
        vault.redeemValue(10e18, erin, erin);

        assertEq(vault.totalSupply(), TOTAL_SHARES);

        vm.roll(vm.getBlockNumber() + 1);
        uint256 burnCheckpoint = vm.getBlockNumber() - 1;
        assertEq(vault.getPastTotalSupply(burnCheckpoint), TOTAL_SHARES);
        assertEq(vault.getPastTotalSupply(burnCheckpoint), vault.getPastVotesTotalSupply(burnCheckpoint));

        vm.expectRevert(SoladyERC20Votes.ERC5805FutureLookup.selector);
        vault.getPastTotalSupply(vm.getBlockNumber());
    }

    function testGovernorVotesReadsSoladyVaultShareCheckpoints() public {
        uint256 checkpoint = vm.getBlockNumber() - 1;

        assertEq(vault.getPastVotes(alice, checkpoint), ALICE_SHARES);
        assertEq(governor.getVotes(alice, checkpoint), ALICE_SHARES);

        vm.prank(alice);
        vault.transfer(dave, 10e18);

        vm.roll(vm.getBlockNumber() + 1);
        uint256 transferCheckpoint = vm.getBlockNumber() - 1;

        assertEq(governor.getVotes(alice, transferCheckpoint), ALICE_SHARES - 10e18);
        assertEq(governor.getVotes(dave, transferCheckpoint), DAVE_SHARES + 10e18);
    }

    function testQuorumUsesShimmedPastTotalSupply() public {
        uint256 checkpoint = vm.getBlockNumber() - 1;

        assertEq(vault.getPastTotalSupply(checkpoint), TOTAL_SHARES);
        assertEq(governor.quorum(checkpoint), 10e18);

        _depositAndDelegate(erin, TOTAL_SHARES);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 doubledSupplyCheckpoint = vm.getBlockNumber() - 1;

        assertEq(governor.quorum(checkpoint), 10e18);
        assertEq(governor.quorum(doubledSupplyCheckpoint), 20e18);
    }

    function testProposalSucceedsAndExecutesWhenForVotesMeetShimmedQuorum() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleAction(address(receiver), 0, abi.encodeCall(GovernanceCallReceiver.setValue, (42)));

        uint256 proposalId = _propose(alice, targets, values, calldatas, "oz-compatible success");
        _advanceToVoteStart(proposalId);

        vm.prank(alice);
        assertEq(governor.castVote(proposalId, 1), ALICE_SHARES);

        (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) = governor.proposalVotes(proposalId);
        assertEq(againstVotes, 0);
        assertEq(forVotes, ALICE_SHARES);
        assertEq(abstainVotes, 0);

        _finishProposal(proposalId);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));

        governor.execute(targets, values, calldatas, keccak256(bytes("oz-compatible success")));

        assertEq(receiver.value(), 42);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
    }

    function testProposalIsDefeatedWhenForVotesDoNotMeetShimmedQuorum() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleAction(address(receiver), 0, abi.encodeCall(GovernanceCallReceiver.setValue, (7)));

        uint256 proposalId = _propose(alice, targets, values, calldatas, "oz-compatible defeated");
        _advanceToVoteStart(proposalId);

        vm.prank(dave);
        assertEq(governor.castVote(proposalId, 1), DAVE_SHARES);

        (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) = governor.proposalVotes(proposalId);
        assertEq(againstVotes, 0);
        assertEq(forVotes, DAVE_SHARES);
        assertEq(abstainVotes, 0);

        _finishProposal(proposalId);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));
    }

    function testProposalCanReachQuorumWithAbstainButStillNeedsMoreForThanAgainst() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleAction(address(receiver), 0, abi.encodeCall(GovernanceCallReceiver.setValue, (99)));

        uint256 proposalId = _propose(alice, targets, values, calldatas, "oz-compatible abstain quorum");
        _advanceToVoteStart(proposalId);

        vm.prank(bob);
        assertEq(governor.castVote(proposalId, 2), BOB_SHARES);

        vm.prank(dave);
        assertEq(governor.castVote(proposalId, 0), DAVE_SHARES);

        (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) = governor.proposalVotes(proposalId);
        assertEq(againstVotes, DAVE_SHARES);
        assertEq(forVotes, 0);
        assertEq(abstainVotes, BOB_SHARES);

        _finishProposal(proposalId);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));
    }

    function testQuorumNumeratorCanOnlyBeUpdatedThroughGovernanceWithOneBlockDelay() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, alice));
        governor.updateQuorumNumerator(20);

        uint256 oldQuorumCheckpoint = vm.getBlockNumber() - 1;
        assertEq(governor.quorum(oldQuorumCheckpoint), 10e18);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleAction(address(governor), 0, abi.encodeWithSignature("updateQuorumNumerator(uint256)", 20));

        uint256 proposalId = _passProposal(targets, values, calldatas, "oz-compatible quorum update");

        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
        assertEq(governor.quorumNumerator(), 20);
        assertEq(governor.quorum(vm.getBlockNumber() - 1), 10e18);

        vm.roll(vm.getBlockNumber() + 1);
        assertEq(governor.quorum(vm.getBlockNumber() - 1), 20e18);
    }

    function testInvalidQuorumNumeratorRevertsDuringGovernanceExecution() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleAction(address(governor), 0, abi.encodeWithSignature("updateQuorumNumerator(uint256)", 101));

        uint256 proposalId = _propose(alice, targets, values, calldatas, "oz-compatible invalid quorum");
        _advanceToVoteStart(proposalId);

        vm.prank(alice);
        governor.castVote(proposalId, 1);

        _finishProposal(proposalId);

        vm.expectRevert(
            abi.encodeWithSelector(GovernorVotesQuorumFraction.GovernorInvalidQuorumFraction.selector, 101, 100)
        );
        governor.execute(targets, values, calldatas, keccak256(bytes("oz-compatible invalid quorum")));
    }

    function testLateQuorumExtendsProposalDeadlineAndKeepsVotingOpen() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleAction(address(receiver), 0, abi.encodeCall(GovernanceCallReceiver.setValue, (123)));

        uint256 proposalId = _propose(alice, targets, values, calldatas, "oz-compatible late quorum");
        uint256 originalDeadline = governor.proposalDeadline(proposalId);

        vm.roll(originalDeadline - 1);

        vm.prank(alice);
        governor.castVote(proposalId, 1);

        uint256 extendedDeadline = governor.proposalDeadline(proposalId);
        assertGt(extendedDeadline, originalDeadline);
        assertEq(extendedDeadline, vm.getBlockNumber() + VOTE_EXTENSION);

        vm.roll(originalDeadline + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Active));

        vm.prank(dave);
        governor.castVote(proposalId, 0);

        vm.roll(extendedDeadline + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));
    }

    function testLateQuorumVoteExtensionCanOnlyBeUpdatedThroughGovernance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, alice));
        governor.setLateQuorumVoteExtension(6);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleAction(address(governor), 0, abi.encodeWithSignature("setLateQuorumVoteExtension(uint48)", 6));

        _passProposal(targets, values, calldatas, "oz-compatible late quorum update");

        assertEq(governor.lateQuorumVoteExtension(), 6);
    }

    function testProposalThresholdUsesVaultShareVotes() public {
        NigiriGovernor thresholdGovernor =
            new NigiriGovernor(IVotes(address(vault)), VOTING_DELAY, VOTING_PERIOD, 10e18, QUORUM_NUMERATOR, 0);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleAction(address(receiver), 0, abi.encodeCall(GovernanceCallReceiver.setValue, (321)));

        vm.prank(dave);
        vm.expectRevert(
            abi.encodeWithSelector(IGovernor.GovernorInsufficientProposerVotes.selector, dave, DAVE_SHARES, 10e18)
        );
        thresholdGovernor.propose(targets, values, calldatas, "oz-compatible threshold fail");

        vm.prank(alice);
        uint256 proposalId = thresholdGovernor.propose(targets, values, calldatas, "oz-compatible threshold pass");

        assertGt(proposalId, 0);
        assertEq(thresholdGovernor.proposalProposer(proposalId), alice);
    }

    function _depositAndDelegate(address account, uint256 amount) internal {
        vm.prank(deployer);
        nigiri.mint(account, amount);

        vm.startPrank(account);
        nigiri.approve(address(vault), type(uint256).max);
        vault.deposit(amount, account);
        vault.delegate(account);
        vm.stopPrank();
    }

    function _propose(
        address proposer,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal returns (uint256 proposalId) {
        vm.prank(proposer);
        proposalId = governor.propose(targets, values, calldatas, description);
    }

    function _passProposal(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal returns (uint256 proposalId) {
        proposalId = _propose(alice, targets, values, calldatas, description);
        _advanceToVoteStart(proposalId);

        vm.prank(alice);
        governor.castVote(proposalId, 1);

        _finishProposal(proposalId);
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));
    }

    function _advanceToVoteStart(uint256 proposalId) internal {
        vm.roll(governor.proposalSnapshot(proposalId) + 1);
    }

    function _finishProposal(uint256 proposalId) internal {
        vm.roll(governor.proposalDeadline(proposalId) + 1);
    }

    function _singleAction(address target, uint256 value, bytes memory data)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        targets[0] = target;

        values = new uint256[](1);
        values[0] = value;

        calldatas = new bytes[](1);
        calldatas[0] = data;
    }
}
