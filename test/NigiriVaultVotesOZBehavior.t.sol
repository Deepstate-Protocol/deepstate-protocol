// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20Votes as SoladyERC20Votes} from "solady/tokens/ERC20Votes.sol";

import {NigiriToken} from "../src/NigiriToken.sol";
import {NigiriVault} from "../src/NigiriVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockWETH} from "./mocks/MockWETH.sol";

/// @notice Ports the relevant OZ ERC20Votes/Votes.behavior cases to vNigiri shares.
contract NigiriVaultVotesOZBehaviorTest is Test {
    uint256 internal constant SUPPLY = 100e18;
    uint256 internal constant RECIPIENT_SUPPLY = 10e18;
    uint256 internal constant TRANSFER_AMOUNT = 1e18;
    uint256 internal constant SIGNER_PK = 0xA11CE;

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant DELEGATION_TYPEHASH =
        keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant DELEGATE_VOTES_CHANGED_TOPIC = keccak256("DelegateVotesChanged(address,uint256,uint256)");

    address internal deployer = makeAddr("deployer");
    address internal holder = makeAddr("holder");
    address internal recipient = makeAddr("recipient");
    address internal delegatee = makeAddr("delegatee");
    address internal other1 = makeAddr("other1");
    address internal other2 = makeAddr("other2");
    address internal spender = makeAddr("spender");
    address internal signer;

    NigiriToken internal nigiri;
    MockERC20 internal valueToken;
    MockWETH internal wrappedNative;
    NigiriVault internal vault;

    function setUp() public {
        signer = vm.addr(SIGNER_PK);

        vm.startPrank(deployer);
        nigiri = new NigiriToken(deployer, "Nigiri", "NIGIRI");
        valueToken = new MockERC20("USD Coin", "USDC", 6);
        wrappedNative = new MockWETH();
        vault = new NigiriVault(
            deployer, address(nigiri), address(valueToken), address(wrappedNative), "vNigiri", "vNIGIRI"
        );
        nigiri.setMinter(deployer);
        vm.stopPrank();
    }

    function testInitialVotesStateMatchesOZBehavior() public view {
        assertEq(vault.CLOCK_MODE(), "mode=blocknumber&from=default");
        assertEq(vault.clock(), vm.getBlockNumber());
        assertEq(vault.nonces(holder), 0);
        assertEq(vault.delegates(holder), address(0));
        assertEq(vault.getVotes(holder), 0);
        assertEq(vault.checkpointCount(holder), 0);
        assertEq(vault.getVotesTotalSupply(), 0);
        assertEq(vault.getPastVotes(holder, 0), 0);
        assertEq(vault.getPastTotalSupply(0), 0);
    }

    function testDelegationWithoutSharesSetsDelegateWithoutCheckpoints() public {
        vm.prank(holder);
        vault.delegate(holder);

        assertEq(vault.delegates(holder), holder);
        assertEq(vault.getVotes(holder), 0);
        assertEq(vault.checkpointCount(holder), 0);
    }

    function testDelegationWithSharesCreatesCurrentAndHistoricalCheckpoints() public {
        _deposit(holder, SUPPLY);
        assertEq(vault.delegates(holder), address(0));
        assertEq(vault.getVotes(holder), 0);

        uint256 timepoint = vm.getBlockNumber();
        vm.prank(holder);
        vault.delegate(holder);

        assertEq(vault.delegates(holder), holder);
        assertEq(vault.getVotes(holder), SUPPLY);
        assertEq(vault.getPastVotes(holder, timepoint - 1), 0);

        _mine();

        assertEq(vault.getPastVotes(holder, timepoint), SUPPLY);
        assertEq(vault.checkpointCount(holder), 1);
        _assertCheckpoint(holder, 0, uint48(timepoint), SUPPLY);
    }

    function testDelegationUpdateMovesVotesFromOldDelegateToNewDelegate() public {
        _deposit(holder, SUPPLY);

        vm.prank(holder);
        vault.delegate(holder);
        _mine();

        uint256 timepoint = vm.getBlockNumber();
        vm.prank(holder);
        vault.delegate(delegatee);

        assertEq(vault.delegates(holder), delegatee);
        assertEq(vault.getVotes(holder), 0);
        assertEq(vault.getVotes(delegatee), SUPPLY);
        assertEq(vault.getPastVotes(holder, timepoint - 1), SUPPLY);
        assertEq(vault.getPastVotes(delegatee, timepoint - 1), 0);

        _mine();

        assertEq(vault.getPastVotes(holder, timepoint), 0);
        assertEq(vault.getPastVotes(delegatee, timepoint), SUPPLY);
    }

    function testDelegatingToZeroClearsVotes() public {
        _depositAndDelegate(holder, SUPPLY, holder);
        _mine();

        uint256 timepoint = vm.getBlockNumber();
        vm.prank(holder);
        vault.delegate(address(0));

        assertEq(vault.delegates(holder), address(0));
        assertEq(vault.getVotes(holder), 0);
        assertEq(vault.getPastVotes(holder, timepoint - 1), SUPPLY);

        _mine();

        assertEq(vault.getPastVotes(holder, timepoint), 0);
    }

    function testDepositAfterDelegationCreditsExistingDelegate() public {
        vm.prank(holder);
        vault.delegate(delegatee);

        uint256 timepoint = vm.getBlockNumber();
        uint256 shares = _deposit(holder, SUPPLY);

        assertEq(shares, SUPPLY);
        assertEq(vault.getVotes(holder), 0);
        assertEq(vault.getVotes(delegatee), SUPPLY);
        assertEq(vault.getVotesTotalSupply(), SUPPLY);

        _mine();

        assertEq(vault.getPastVotes(delegatee, timepoint), SUPPLY);
        assertEq(vault.getPastTotalSupply(timepoint), SUPPLY);
    }

    function testTransferWithoutDelegationDoesNotMoveVotes() public {
        _deposit(holder, SUPPLY);

        uint256 timepoint = vm.getBlockNumber();
        vm.prank(holder);
        vault.transfer(recipient, TRANSFER_AMOUNT);

        _assertCurrentVotes(0, 0);
        _mine();
        _assertPastVotes(timepoint, 0, 0);
    }

    function testTransferWithSenderDelegatedDecrementsSenderVotesOnly() public {
        _depositAndDelegate(holder, SUPPLY, holder);

        uint256 timepoint = vm.getBlockNumber();
        vm.prank(holder);
        vault.transfer(recipient, TRANSFER_AMOUNT);

        _assertCurrentVotes(SUPPLY - TRANSFER_AMOUNT, 0);
        _mine();
        _assertPastVotes(timepoint, SUPPLY - TRANSFER_AMOUNT, 0);
    }

    function testTransferWithReceiverDelegatedIncrementsReceiverVotesOnly() public {
        _deposit(holder, SUPPLY);

        vm.prank(recipient);
        vault.delegate(recipient);

        uint256 timepoint = vm.getBlockNumber();
        vm.prank(holder);
        vault.transfer(recipient, TRANSFER_AMOUNT);

        _assertCurrentVotes(0, TRANSFER_AMOUNT);
        _mine();
        _assertPastVotes(timepoint, 0, TRANSFER_AMOUNT);
    }

    function testTransferWithBothSelfDelegatedMovesVotesBetweenAccounts() public {
        _depositAndDelegate(holder, SUPPLY, holder);

        vm.prank(recipient);
        vault.delegate(recipient);

        uint256 timepoint = vm.getBlockNumber();
        vm.prank(holder);
        vault.transfer(recipient, TRANSFER_AMOUNT);

        _assertCurrentVotes(SUPPLY - TRANSFER_AMOUNT, TRANSFER_AMOUNT);
        _mine();
        _assertPastVotes(timepoint, SUPPLY - TRANSFER_AMOUNT, TRANSFER_AMOUNT);
    }

    function testTransferBetweenAccountsDelegatedToThirdPartiesMovesDelegateVotes() public {
        _depositAndDelegate(holder, SUPPLY, other1);
        _depositAndDelegate(recipient, RECIPIENT_SUPPLY, other2);

        uint256 timepoint = vm.getBlockNumber();
        vm.prank(holder);
        vault.transfer(recipient, TRANSFER_AMOUNT);

        assertEq(vault.getVotes(holder), 0);
        assertEq(vault.getVotes(recipient), 0);
        assertEq(vault.getVotes(other1), SUPPLY - TRANSFER_AMOUNT);
        assertEq(vault.getVotes(other2), RECIPIENT_SUPPLY + TRANSFER_AMOUNT);

        _mine();

        assertEq(vault.getPastVotes(other1, timepoint), SUPPLY - TRANSFER_AMOUNT);
        assertEq(vault.getPastVotes(other2, timepoint), RECIPIENT_SUPPLY + TRANSFER_AMOUNT);
    }

    function testTransferBetweenAccountsWithSameDelegateLeavesDelegateVotesUnchanged() public {
        _depositAndDelegate(holder, SUPPLY, delegatee);
        _depositAndDelegate(recipient, RECIPIENT_SUPPLY, delegatee);

        uint256 checkpointCount = vault.checkpointCount(delegatee);
        uint256 votes = vault.getVotes(delegatee);
        uint256 timepoint = vm.getBlockNumber();

        vm.prank(holder);
        vault.transfer(recipient, TRANSFER_AMOUNT);

        assertEq(vault.getVotes(delegatee), votes);
        assertEq(vault.checkpointCount(delegatee), checkpointCount);

        _mine();

        assertEq(vault.getPastVotes(delegatee, timepoint), votes);
    }

    function testTransferFromMirrorsTransferVoteMovement() public {
        _depositAndDelegate(holder, SUPPLY, holder);

        vm.prank(recipient);
        vault.delegate(recipient);

        vm.prank(holder);
        vault.approve(spender, TRANSFER_AMOUNT);

        uint256 timepoint = vm.getBlockNumber();
        vm.prank(spender);
        vault.transferFrom(holder, recipient, TRANSFER_AMOUNT);

        _assertCurrentVotes(SUPPLY - TRANSFER_AMOUNT, TRANSFER_AMOUNT);
        assertEq(vault.allowance(holder, spender), 0);

        _mine();
        _assertPastVotes(timepoint, SUPPLY - TRANSFER_AMOUNT, TRANSFER_AMOUNT);
    }

    function testSelfTransferDoesNotChangeVotesOrAddDelegateCheckpoint() public {
        _depositAndDelegate(holder, SUPPLY, holder);

        uint256 checkpointCount = vault.checkpointCount(holder);
        uint256 timepoint = vm.getBlockNumber();

        vm.prank(holder);
        vault.transfer(holder, TRANSFER_AMOUNT);

        assertEq(vault.getVotes(holder), SUPPLY);
        assertEq(vault.checkpointCount(holder), checkpointCount);

        _mine();

        assertEq(vault.getPastVotes(holder, timepoint), SUPPLY);
    }

    function testTransferToUndelegatedAccountThenDelegateAddsFullReceiverBalance() public {
        _depositAndDelegate(holder, SUPPLY, holder);

        vm.prank(holder);
        vault.transfer(recipient, TRANSFER_AMOUNT);

        assertEq(vault.getVotes(holder), SUPPLY - TRANSFER_AMOUNT);
        assertEq(vault.getVotes(recipient), 0);

        uint256 timepoint = vm.getBlockNumber();
        vm.prank(recipient);
        vault.delegate(recipient);

        assertEq(vault.getVotes(recipient), TRANSFER_AMOUNT);

        _mine();

        assertEq(vault.getPastVotes(recipient, timepoint), TRANSFER_AMOUNT);
    }

    function testRedeemValueBurnDecrementsSelfDelegatedVotesAndTotalSupply() public {
        _depositAndDelegate(holder, SUPPLY, holder);
        valueToken.mint(address(vault), 1_000e6);

        uint256 timepoint = vm.getBlockNumber();
        vm.prank(holder);
        vault.redeemValue(TRANSFER_AMOUNT, holder, holder);

        assertEq(vault.getVotes(holder), SUPPLY - TRANSFER_AMOUNT);
        assertEq(vault.getVotesTotalSupply(), SUPPLY - TRANSFER_AMOUNT);

        _mine();

        assertEq(vault.getPastVotes(holder, timepoint), SUPPLY - TRANSFER_AMOUNT);
        assertEq(vault.getPastTotalSupply(timepoint), SUPPLY - TRANSFER_AMOUNT);
    }

    function testRedeemValueBurnDecrementsThirdPartyDelegateVotes() public {
        _depositAndDelegate(holder, SUPPLY, delegatee);
        valueToken.mint(address(vault), 1_000e6);

        uint256 timepoint = vm.getBlockNumber();
        vm.prank(holder);
        vault.redeemValue(TRANSFER_AMOUNT, holder, holder);

        assertEq(vault.getVotes(holder), 0);
        assertEq(vault.getVotes(delegatee), SUPPLY - TRANSFER_AMOUNT);

        _mine();

        assertEq(vault.getPastVotes(delegatee, timepoint), SUPPLY - TRANSFER_AMOUNT);
    }

    function testApprovedRedeemValueBurnDecrementsOwnerDelegateVotes() public {
        _depositAndDelegate(holder, SUPPLY, holder);
        valueToken.mint(address(vault), 1_000e6);

        vm.prank(holder);
        vault.approve(spender, TRANSFER_AMOUNT);

        uint256 timepoint = vm.getBlockNumber();
        vm.prank(spender);
        vault.redeemValue(TRANSFER_AMOUNT, recipient, holder);

        assertEq(vault.getVotes(holder), SUPPLY - TRANSFER_AMOUNT);
        assertEq(vault.allowance(holder, spender), 0);
        assertEq(valueToken.balanceOf(recipient), 10e6);

        _mine();

        assertEq(vault.getPastVotes(holder, timepoint), SUPPLY - TRANSFER_AMOUNT);
    }

    function testCheckpointCountAndValuesFollowOZCompoundScenario() public {
        _deposit(holder, SUPPLY);

        vm.prank(holder);
        vault.transfer(recipient, 10e18);

        uint256 t1 = vm.getBlockNumber();
        vm.prank(recipient);
        vault.delegate(other1);
        _mine();

        uint256 t2 = vm.getBlockNumber();
        vm.prank(recipient);
        vault.transfer(other2, 1e18);
        _mine();

        uint256 t3 = vm.getBlockNumber();
        vm.prank(recipient);
        vault.transfer(other2, 1e18);
        _mine();

        uint256 t4 = vm.getBlockNumber();
        vm.prank(holder);
        vault.transfer(recipient, 2e18);
        _mine();

        assertEq(vault.checkpointCount(other1), 4);
        _assertCheckpoint(other1, 0, uint48(t1), 10e18);
        _assertCheckpoint(other1, 1, uint48(t2), 9e18);
        _assertCheckpoint(other1, 2, uint48(t3), 8e18);
        _assertCheckpoint(other1, 3, uint48(t4), 10e18);

        assertEq(vault.getPastVotes(other1, t1), 10e18);
        assertEq(vault.getPastVotes(other1, t2), 9e18);
        assertEq(vault.getPastVotes(other1, t3), 8e18);
        assertEq(vault.getPastVotes(other1, t4), 10e18);
    }

    function testMultipleVoteChangesInSameBlockMergeIntoOneCheckpoint() public {
        _deposit(holder, SUPPLY);

        vm.prank(holder);
        vault.transfer(recipient, 10e18);

        uint256 sameBlock = vm.getBlockNumber();

        vm.prank(recipient);
        vault.delegate(other1);

        vm.prank(recipient);
        vault.transfer(other2, 1e18);

        vm.prank(recipient);
        vault.transfer(other2, 1e18);

        assertEq(vault.checkpointCount(other1), 1);
        _assertCheckpoint(other1, 0, uint48(sameBlock), 8e18);

        _mine();

        uint256 nextBlock = vm.getBlockNumber();
        vm.prank(holder);
        vault.transfer(recipient, 2e18);

        assertEq(vault.checkpointCount(other1), 2);
        _assertCheckpoint(other1, 1, uint48(nextBlock), 10e18);
    }

    function testPastVotesGenerallyReturnTheAppropriateCheckpoint() public {
        _deposit(holder, SUPPLY);

        uint256 t1 = vm.getBlockNumber();
        vm.prank(holder);
        vault.delegate(other1);
        _mine(2);

        uint256 t2 = vm.getBlockNumber();
        vm.prank(holder);
        vault.transfer(other2, 10e18);
        _mine(2);

        uint256 t3 = vm.getBlockNumber();
        vm.prank(holder);
        vault.transfer(other2, 10e18);
        _mine(2);

        uint256 t4 = vm.getBlockNumber();
        vm.prank(other2);
        vault.transfer(holder, 20e18);
        _mine(2);

        assertEq(vault.getPastVotes(other1, t1 - 1), 0);
        assertEq(vault.getPastVotes(other1, t1), SUPPLY);
        assertEq(vault.getPastVotes(other1, t1 + 1), SUPPLY);
        assertEq(vault.getPastVotes(other1, t2), SUPPLY - 10e18);
        assertEq(vault.getPastVotes(other1, t2 + 1), SUPPLY - 10e18);
        assertEq(vault.getPastVotes(other1, t3), SUPPLY - 20e18);
        assertEq(vault.getPastVotes(other1, t3 + 1), SUPPLY - 20e18);
        assertEq(vault.getPastVotes(other1, t4), SUPPLY);
        assertEq(vault.getPastVotes(other1, t4 + 1), SUPPLY);
    }

    function testPastTotalSupplyGenerallyReturnsTheAppropriateCheckpoint() public {
        vm.prank(holder);
        vault.delegate(holder);

        uint256 t1 = vm.getBlockNumber();
        _deposit(holder, SUPPLY);
        _mine(2);

        valueToken.mint(address(vault), 1_000e6);

        uint256 t2 = vm.getBlockNumber();
        vm.prank(holder);
        vault.redeemValue(10e18, holder, holder);
        _mine(2);

        uint256 t3 = vm.getBlockNumber();
        vm.prank(holder);
        vault.redeemValue(10e18, holder, holder);
        _mine(2);

        uint256 t4 = vm.getBlockNumber();
        uint256 mintedShares = _deposit(holder, 25e18);
        _mine(2);

        assertEq(mintedShares, 20e18);
        assertEq(vault.getPastTotalSupply(t1 - 1), 0);
        assertEq(vault.getPastTotalSupply(t1), SUPPLY);
        assertEq(vault.getPastTotalSupply(t1 + 1), SUPPLY);
        assertEq(vault.getPastTotalSupply(t2), SUPPLY - 10e18);
        assertEq(vault.getPastTotalSupply(t2 + 1), SUPPLY - 10e18);
        assertEq(vault.getPastTotalSupply(t3), SUPPLY - 20e18);
        assertEq(vault.getPastTotalSupply(t3 + 1), SUPPLY - 20e18);
        assertEq(vault.getPastTotalSupply(t4), SUPPLY);
        assertEq(vault.getPastTotalSupply(t4 + 1), SUPPLY);
    }

    function testPastLookupsRevertForCurrentOrFutureClock() public {
        _depositAndDelegate(holder, SUPPLY, holder);

        vm.expectRevert(SoladyERC20Votes.ERC5805FutureLookup.selector);
        vault.getPastVotes(holder, vm.getBlockNumber());

        vm.expectRevert(SoladyERC20Votes.ERC5805FutureLookup.selector);
        vault.getPastTotalSupply(vm.getBlockNumber());

        vm.expectRevert(SoladyERC20Votes.ERC5805FutureLookup.selector);
        vault.getPastVotes(holder, 50_000_000_000);
    }

    function testRecentAndNonRecentCheckpointsResolvePastVotes() public {
        vm.prank(holder);
        vault.delegate(holder);

        uint256 firstCheckpoint;
        uint256 lastCheckpoint;

        for (uint256 i; i < 6; ++i) {
            uint256 timepoint = vm.getBlockNumber();
            _deposit(holder, 1e18);
            if (i == 0) firstCheckpoint = timepoint;
            lastCheckpoint = timepoint;
            _mine();
        }

        assertEq(vault.checkpointCount(holder), 6);
        assertEq(vault.getPastVotes(holder, firstCheckpoint - 1), 0);
        assertEq(vault.getPastVotes(holder, firstCheckpoint), 1e18);
        assertEq(vault.getPastVotes(holder, lastCheckpoint), 6e18);
    }

    function testDelegateBySigAcceptsSignedDelegation() public {
        _deposit(signer, SUPPLY);

        uint256 expiry = type(uint256).max;
        (uint8 v, bytes32 r, bytes32 s) = _signDelegation(SIGNER_PK, delegatee, 0, expiry);

        uint256 timepoint = vm.getBlockNumber();
        vault.delegateBySig(delegatee, 0, expiry, v, r, s);

        assertEq(vault.nonces(signer), 1);
        assertEq(vault.delegates(signer), delegatee);
        assertEq(vault.getVotes(signer), 0);
        assertEq(vault.getVotes(delegatee), SUPPLY);

        _mine();

        assertEq(vault.getPastVotes(delegatee, timepoint), SUPPLY);
    }

    function testDelegateBySigRejectsReusedSignature() public {
        uint256 expiry = type(uint256).max;
        (uint8 v, bytes32 r, bytes32 s) = _signDelegation(SIGNER_PK, delegatee, 0, expiry);

        vault.delegateBySig(delegatee, 0, expiry, v, r, s);

        vm.expectRevert(SoladyERC20Votes.ERC5805DelegateInvalidSignature.selector);
        vault.delegateBySig(delegatee, 0, expiry, v, r, s);
    }

    function testDelegateBySigRejectsBadNonce() public {
        uint256 expiry = type(uint256).max;
        (uint8 v, bytes32 r, bytes32 s) = _signDelegation(SIGNER_PK, delegatee, 1, expiry);

        vm.expectRevert(SoladyERC20Votes.ERC5805DelegateInvalidSignature.selector);
        vault.delegateBySig(delegatee, 1, expiry, v, r, s);
    }

    function testDelegateBySigRejectsExpiredSignature() public {
        vm.warp(1_000);

        uint256 expiry = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _signDelegation(SIGNER_PK, delegatee, 0, expiry);

        vm.expectRevert(SoladyERC20Votes.ERC5805DelegateSignatureExpired.selector);
        vault.delegateBySig(delegatee, 0, expiry, v, r, s);
    }

    function testDelegateBySigWithWrongDelegateeDoesNotAffectOriginalSigner() public {
        _deposit(signer, SUPPLY);

        uint256 expiry = type(uint256).max;
        (uint8 v, bytes32 r, bytes32 s) = _signDelegation(SIGNER_PK, delegatee, 0, expiry);

        vault.delegateBySig(other1, 0, expiry, v, r, s);

        assertEq(vault.nonces(signer), 0);
        assertEq(vault.delegates(signer), address(0));
        assertEq(vault.getVotes(delegatee), 0);
        assertEq(vault.getVotes(other1), 0);
    }

    function testTransferEmitsTransferBeforeDelegateVoteChanges() public {
        _depositAndDelegate(holder, SUPPLY, holder);

        vm.prank(recipient);
        vault.delegate(recipient);

        vm.recordLogs();

        vm.prank(holder);
        vault.transfer(recipient, TRANSFER_AMOUNT);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertLt(_firstLogIndex(logs, TRANSFER_TOPIC), _firstLogIndex(logs, DELEGATE_VOTES_CHANGED_TOPIC));
    }

    function _depositAndDelegate(address account, uint256 assets, address delegate_) internal returns (uint256 shares) {
        shares = _deposit(account, assets);

        vm.prank(account);
        vault.delegate(delegate_);
    }

    function _deposit(address account, uint256 assets) internal returns (uint256 shares) {
        vm.prank(deployer);
        nigiri.mint(account, assets);

        vm.startPrank(account);
        nigiri.approve(address(vault), assets);
        shares = vault.deposit(assets, account);
        vm.stopPrank();
    }

    function _mine() internal {
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _mine(uint256 blocks_) internal {
        vm.roll(vm.getBlockNumber() + blocks_);
    }

    function _assertCurrentVotes(uint256 expectedHolderVotes, uint256 expectedRecipientVotes) internal view {
        assertEq(vault.getVotes(holder), expectedHolderVotes);
        assertEq(vault.getVotes(recipient), expectedRecipientVotes);
    }

    function _assertPastVotes(uint256 timepoint, uint256 expectedHolderVotes, uint256 expectedRecipientVotes)
        internal
        view
    {
        assertEq(vault.getPastVotes(holder, timepoint), expectedHolderVotes);
        assertEq(vault.getPastVotes(recipient, timepoint), expectedRecipientVotes);
    }

    function _assertCheckpoint(address account, uint256 index, uint48 expectedClock, uint256 expectedVotes)
        internal
        view
    {
        (uint48 checkpointClock, uint256 checkpointVotes) = vault.checkpointAt(account, index);
        assertEq(checkpointClock, expectedClock);
        assertEq(checkpointVotes, expectedVotes);
    }

    function _signDelegation(uint256 privateKey, address delegate_, uint256 nonce, uint256 expiry)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(abi.encode(DELEGATION_TYPEHASH, delegate_, nonce, expiry));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        return vm.sign(privateKey, digest);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(vault.name())),
                keccak256(bytes("1")),
                block.chainid,
                address(vault)
            )
        );
    }

    function _firstLogIndex(Vm.Log[] memory logs, bytes32 topic) internal pure returns (uint256) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic) {
                return i;
            }
        }

        revert("log not found");
    }
}
