// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20 as OZERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {DeepstateVault} from "../src/DeepstateVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DeepstateVaultHarness is DeepstateVault {
    uint256 private depositCap = type(uint256).max;
    uint256 private mintCap = type(uint256).max;

    constructor(address owner_, address depositToken_, address valueToken_, string memory name_, string memory symbol_)
        DeepstateVault(owner_, depositToken_, valueToken_, name_, symbol_)
    {}

    function setEntryCaps(uint256 depositCap_, uint256 mintCap_) external {
        depositCap = depositCap_;
        mintCap = mintCap_;
    }

    function maxDeposit(address) public view override returns (uint256) {
        return depositCap;
    }

    function maxMint(address) public view override returns (uint256) {
        return mintCap;
    }

    function exposedDeposit(address caller, address receiver, uint256 assets, uint256 shares) external {
        _deposit(caller, receiver, assets, shares);
    }
}

contract RejectingNativeReceiver {
    receive() external payable {
        revert();
    }
}

contract ReenteringNativeReceiver {
    DeepstateVault internal immutable vault;
    address internal immutable reentryToken;
    uint256 internal immutable reentryShares;

    bool public attempted;
    bool public reentered;

    constructor(DeepstateVault vault_, address reentryToken_, uint256 reentryShares_) {
        vault = vault_;
        reentryToken = reentryToken_;
        reentryShares = reentryShares_;
    }

    receive() external payable {
        attempted = true;

        address[] memory tokens = new address[](1);
        tokens[0] = reentryToken;
        uint256[] memory minimumAmounts = new uint256[](1);
        try vault.redeemAssets(reentryShares, address(this), address(this), tokens, minimumAmounts) {
            reentered = true;
        } catch {}
    }
}

contract FeeOnTransferERC20 is OZERC20 {
    constructor() OZERC20("Fee-on-transfer USDG", "fUSDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, amount);
            return;
        }

        uint256 fee = amount / 10;
        super._update(from, address(0), fee);
        super._update(from, to, amount - fee);
    }
}

contract DeepstateVaultTest is Test {
    bytes32 internal constant DELEGATION_TYPEHASH =
        keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    event DepositAccountingReset(uint256 previousBurnedAssets);

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal buyer = makeAddr("buyer");
    address internal carol = makeAddr("carol");

    MockERC20 internal depositToken;
    MockERC20 internal valueToken;
    MockERC20 internal feeToken;
    MockERC20 internal otherFeeToken;
    DeepstateVault internal vault;

    function setUp() public {
        depositToken = new MockERC20("Deposit", "DEP", 18);
        valueToken = new MockERC20("USDG", "USDG", 6);
        feeToken = new MockERC20("Fee Token", "FEE", 18);
        otherFeeToken = new MockERC20("Other Fee Token", "OTHER", 8);

        vault = new DeepstateVault(owner, address(depositToken), address(valueToken), "Deepstate Governance", "STATE");

        depositToken.mint(alice, 100e18);
        depositToken.mint(bob, 100e18);
        depositToken.mint(carol, 100e18);
        valueToken.mint(buyer, 1_000_000e6);

        vm.prank(alice);
        depositToken.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        depositToken.approve(address(vault), type(uint256).max);
        vm.prank(carol);
        depositToken.approve(address(vault), type(uint256).max);
        vm.prank(buyer);
        valueToken.approve(address(vault), type(uint256).max);
    }

    function testDepositsBurnAssetsAndMaintainShareRatio() public {
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(100e18, alice);

        assertEq(aliceShares, 100e18);
        assertEq(vault.totalAssets(), 100e18);
        assertEq(vault.totalSupply(), 100e18);
        assertEq(vault.delegates(alice), alice);
        assertEq(vault.getVotes(alice), 100e18);
        assertEq(depositToken.balanceOf(address(vault)), 0);
        assertEq(depositToken.balanceOf(alice), 0);

        vm.prank(bob);
        uint256 bobShares = vault.deposit(50e18, bob);

        assertEq(bobShares, 50e18);
        assertEq(vault.totalAssets(), 150e18);
        assertEq(vault.totalSupply(), 150e18);
        assertEq(vault.delegates(bob), bob);
        assertEq(vault.getVotes(bob), 50e18);
        assertEq(depositToken.balanceOf(address(vault)), 0);
        assertEq(vault.convertToShares(25e18), 25e18);
    }

    function testConstructorAndMetadataValidation() public {
        assertEq(vault.name(), "Deepstate Governance");
        assertEq(vault.symbol(), "STATE");
        assertEq(vault.decimals(), 18);
        assertEq(vault.asset(), address(depositToken));
        assertEq(vault.depositToken(), address(depositToken));
        assertEq(vault.valueToken(), address(valueToken));
        assertEq(vault.FEE_PURCHASE_PRICE(), 10_000e6);
        assertEq(vault.DEPOSIT_TOKEN_DECIMALS(), 18);
        assertEq(vault.VALUE_TOKEN_DECIMALS(), 6);
        assertEq(vault.owner(), owner);
        assertEq(vault.CLOCK_MODE(), "mode=timestamp");

        vm.expectRevert(DeepstateVault.ZeroAddress.selector);
        new DeepstateVault(owner, address(0), address(valueToken), "Deepstate Governance", "STATE");

        vm.expectRevert(DeepstateVault.ZeroAddress.selector);
        new DeepstateVault(owner, address(depositToken), address(0), "Deepstate Governance", "STATE");
    }

    function testFuzzConstructorRejectsNonEighteenDecimalDepositToken(uint8 depositTokenDecimals) public {
        vm.assume(depositTokenDecimals != 18);
        MockERC20 invalidDepositToken = new MockERC20("Invalid DEEP", "iDEEP", depositTokenDecimals);

        vm.expectRevert(
            abi.encodeWithSelector(DeepstateVault.InvalidDepositTokenDecimals.selector, depositTokenDecimals)
        );
        new DeepstateVault(owner, address(invalidDepositToken), address(valueToken), "Deepstate Governance", "STATE");
    }

    function testFuzzConstructorRejectsNonSixDecimalValueToken(uint8 valueTokenDecimals) public {
        vm.assume(valueTokenDecimals != 6);
        MockERC20 invalidValueToken = new MockERC20("Invalid USDG", "iUSDG", valueTokenDecimals);

        vm.expectRevert(abi.encodeWithSelector(DeepstateVault.InvalidValueTokenDecimals.selector, valueTokenDecimals));
        new DeepstateVault(owner, address(depositToken), address(invalidValueToken), "Deepstate Governance", "STATE");
    }

    function testPreviewRedeemValueReturnsZeroBeforeSupplyExists() public view {
        assertEq(vault.convertToValueAssets(1e18), 0);
        assertEq(vault.previewRedeemValue(1e18), 0);
    }

    function testDepositAndMintRejectZeroAmounts() public {
        vm.startPrank(alice);

        vm.expectRevert(DeepstateVault.ZeroAssets.selector);
        vault.deposit(0, alice);

        vm.expectRevert(DeepstateVault.ZeroAssets.selector);
        vault.mint(0, alice);

        vm.stopPrank();
    }

    function testBoundedDepositAndMintAcceptExactLiveLimits() public {
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(25e18, alice, 25e18);

        vm.prank(bob);
        uint256 bobAssets = vault.mint(25e18, bob, 25e18);

        assertEq(aliceShares, 25e18);
        assertEq(bobAssets, 25e18);
        assertEq(vault.balanceOf(alice), 25e18);
        assertEq(vault.balanceOf(bob), 25e18);
        assertEq(vault.totalSupply(), 50e18);
        assertEq(vault.totalBurnedDepositAssets(), 50e18);
    }

    function testBoundedDepositAndMintEnforceVaultEntryCaps() public {
        DeepstateVaultHarness harness = new DeepstateVaultHarness(
            owner, address(depositToken), address(valueToken), "Deepstate Governance", "STATE"
        );
        harness.setEntryCaps(10e18, 20e18);

        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, alice, 10e18 + 1, 10e18));
        harness.deposit(10e18 + 1, alice, 0);

        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxMint.selector, alice, 20e18 + 1, 20e18));
        harness.mint(20e18 + 1, alice, type(uint256).max);
    }

    function testBoundedDepositRejectsWorsenedLiveShareQuoteWithoutBurningAssets() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        valueToken.mint(address(vault), 100e6);

        uint256 victimAssets = 50e18;
        uint256 quotedShares = vault.previewDeposit(victimAssets);
        vm.prank(alice);
        vault.redeemValue(50e18, alice, alice);

        uint256 liveShares = vault.previewDeposit(victimAssets);
        assertEq(quotedShares, 50e18);
        assertEq(liveShares, 25e18);

        uint256 bobAssetsBefore = depositToken.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DeepstateVault.MinimumSharesNotMet.selector, liveShares, quotedShares));
        vault.deposit(victimAssets, bob, quotedShares);

        assertEq(depositToken.balanceOf(bob), bobAssetsBefore);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.totalBurnedDepositAssets(), 100e18);
    }

    function testBoundedMintRejectsWorsenedLiveAssetQuoteWithoutBurningAssets() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        valueToken.mint(address(vault), 100e6);

        uint256 targetShares = 50e18;
        uint256 quotedAssets = vault.previewMint(targetShares);
        vm.prank(alice);
        vault.redeemValue(50e18, alice, alice);

        uint256 liveAssets = vault.previewMint(targetShares);
        assertEq(quotedAssets, 50e18);
        assertEq(liveAssets, 100e18);

        uint256 bobAssetsBefore = depositToken.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DeepstateVault.MaximumAssetsExceeded.selector, liveAssets, quotedAssets));
        vault.mint(targetShares, bob, quotedAssets);

        assertEq(depositToken.balanceOf(bob), bobAssetsBefore);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.totalBurnedDepositAssets(), 100e18);
    }

    function testInternalDepositRejectsZeroShares() public {
        DeepstateVaultHarness harness = new DeepstateVaultHarness(
            owner, address(depositToken), address(valueToken), "Deepstate Governance", "STATE"
        );

        vm.expectRevert(DeepstateVault.ZeroShares.selector);
        harness.exposedDeposit(alice, alice, 1e18, 0);
    }

    function testPreviewAndConversionMathTracksBurnedDepositAccounting() public {
        assertEq(vault.convertToShares(10e18), 10e18);
        assertEq(vault.convertToAssets(10e18), 10e18);
        assertEq(vault.previewDeposit(10e18), 10e18);
        assertEq(vault.previewMint(10e18), 10e18);

        vm.prank(alice);
        vault.deposit(100e18, alice);

        assertEq(vault.convertToShares(10e18), 10e18);
        assertEq(vault.convertToAssets(10e18), 10e18);
        assertEq(vault.previewDeposit(10e18), 10e18);
        assertEq(vault.previewMint(10e18), 10e18);
    }

    function testDepositDoesNotOverrideExistingDelegate() public {
        vm.prank(bob);
        vault.delegate(alice);

        vm.prank(bob);
        vault.deposit(50e18, bob);

        assertEq(vault.delegates(bob), alice);
        assertEq(vault.getVotes(bob), 0);
        assertEq(vault.getVotes(alice), 50e18);
    }

    function testDepositForReceiverSelfDelegatesReceiverNotCaller() public {
        vm.prank(alice);
        vault.deposit(40e18, bob);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 40e18);
        assertEq(vault.delegates(alice), address(0));
        assertEq(vault.getVotes(alice), 0);
        assertEq(vault.delegates(bob), bob);
        assertEq(vault.getVotes(bob), 40e18);
    }

    function testDepositForReceiverDoesNotOverrideReceiverDelegate() public {
        vm.prank(bob);
        vault.delegate(carol);

        vm.prank(alice);
        vault.deposit(40e18, bob);

        assertEq(vault.delegates(bob), carol);
        assertEq(vault.getVotes(bob), 0);
        assertEq(vault.getVotes(carol), 40e18);
    }

    function testAdditionalDepositOnlyAddsNewVotesToExistingDelegate() public {
        vm.prank(bob);
        vault.delegate(alice);

        vm.prank(bob);
        vault.deposit(40e18, bob);
        uint48 firstCheckpointTime = vault.clock();

        assertEq(vault.getVotes(alice), 40e18);
        assertEq(vault.numCheckpoints(alice), 1);

        vm.warp(uint256(vault.clock()) + 1);
        vm.prank(bob);
        vault.deposit(25e18, bob);
        vm.warp(uint256(vault.clock()) + 1);

        assertEq(vault.delegates(bob), alice);
        assertEq(vault.getVotes(alice), 65e18);
        assertEq(vault.numCheckpoints(alice), 2);
        assertEq(vault.getPastVotes(alice, firstCheckpointTime), 40e18);
    }

    function testTransferUpdatesVotesForDelegatedSenderAndUndelegatedReceiver() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.prank(alice);
        vault.transfer(bob, 40e18);

        assertEq(vault.balanceOf(alice), 60e18);
        assertEq(vault.balanceOf(bob), 40e18);
        assertEq(vault.delegates(alice), alice);
        assertEq(vault.delegates(bob), address(0));
        assertEq(vault.getVotes(alice), 60e18);
        assertEq(vault.getVotes(bob), 0);

        vm.prank(bob);
        vault.delegate(bob);

        assertEq(vault.getVotes(bob), 40e18);
    }

    function testNonzeroStateCannotBeTransferredOrMintedToVault() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.prank(alice);
        vm.expectRevert(DeepstateVault.ProtectedToken.selector);
        vault.transfer(address(vault), 1);

        vm.prank(alice);
        vault.approve(carol, 1);
        vm.prank(carol);
        vm.expectRevert(DeepstateVault.ProtectedToken.selector);
        vault.transferFrom(alice, address(vault), 1);

        uint256 bobAssetsBefore = depositToken.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(DeepstateVault.ProtectedToken.selector);
        vault.deposit(1e18, address(vault));

        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.balanceOf(alice), 100e18);
        assertEq(vault.totalSupply(), 100e18);
        assertEq(vault.totalBurnedDepositAssets(), 100e18);
        assertEq(vault.allowance(alice, carol), 1);
        assertEq(depositToken.balanceOf(bob), bobAssetsBefore);
    }

    function testZeroStateTransferToVaultRemainsPermitted() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.prank(alice);
        assertTrue(vault.transfer(address(vault), 0));

        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.balanceOf(alice), 100e18);
    }

    function testTransferUpdatesVotesBetweenDelegatedAccounts() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(50e18, bob);

        vm.prank(alice);
        vault.transfer(bob, 25e18);

        assertEq(vault.getVotes(alice), 75e18);
        assertEq(vault.getVotes(bob), 75e18);
    }

    function testTransferFromUpdatesVotesAndConsumesFiniteAllowance() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(50e18, bob);

        vm.prank(alice);
        vault.approve(carol, 30e18);

        vm.prank(carol);
        vault.transferFrom(alice, bob, 20e18);

        assertEq(vault.allowance(alice, carol), 10e18);
        assertEq(vault.balanceOf(alice), 80e18);
        assertEq(vault.balanceOf(bob), 70e18);
        assertEq(vault.getVotes(alice), 80e18);
        assertEq(vault.getVotes(bob), 70e18);
    }

    function testRedeemValueBurnDecrementsVotesAndTotalSupplyCheckpoints() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint48 depositTime = vault.clock();

        valueToken.mint(address(vault), 1_000e6);

        vm.warp(uint256(vault.clock()) + 1);
        vm.prank(alice);
        vault.redeemValue(40e18, alice, alice);
        uint48 redeemTime = vault.clock();

        assertEq(vault.balanceOf(alice), 60e18);
        assertEq(vault.totalSupply(), 60e18);
        assertEq(vault.getVotes(alice), 60e18);

        vm.warp(uint256(vault.clock()) + 1);
        assertEq(vault.getPastVotes(alice, depositTime), 100e18);
        assertEq(vault.getPastVotes(alice, redeemTime), 60e18);
        assertEq(vault.getPastTotalSupply(depositTime), 100e18);
        assertEq(vault.getPastTotalSupply(redeemTime), 60e18);
    }

    function testRedeemValueByApprovedSpenderDecrementsOwnerDelegateVotes() public {
        vm.prank(alice);
        vault.delegate(bob);
        vm.prank(alice);
        vault.deposit(100e18, alice);
        valueToken.mint(address(vault), 1_000e6);

        vm.prank(alice);
        vault.approve(carol, 40e18);

        vm.prank(carol);
        vault.redeemValue(40e18, carol, alice);

        assertEq(vault.allowance(alice, carol), 0);
        assertEq(vault.balanceOf(alice), 60e18);
        assertEq(vault.getVotes(alice), 0);
        assertEq(vault.getVotes(bob), 60e18);
        assertEq(valueToken.balanceOf(carol), 400e6);
    }

    function testRedeemValueRejectsZeroReceiverBeforeBurnOrAllowanceSpend() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        valueToken.mint(address(vault), 1_000e6);

        vm.prank(alice);
        vault.approve(bob, 40e18);

        vm.prank(bob);
        vm.expectRevert(DeepstateVault.ZeroAddress.selector);
        vault.redeemValue(40e18, address(0), alice);

        assertEq(vault.balanceOf(alice), 100e18);
        assertEq(vault.allowance(alice, bob), 40e18);
        assertEq(valueToken.balanceOf(address(vault)), 1_000e6);
        assertEq(valueToken.balanceOf(address(0)), 0);
    }

    function testDelegateBySigMovesVotesAndConsumesNonce() public {
        uint256 signerPrivateKey = 0xA11CE;
        address signer = vm.addr(signerPrivateKey);

        depositToken.mint(signer, 100e18);
        vm.startPrank(signer);
        depositToken.approve(address(vault), type(uint256).max);
        vault.deposit(100e18, signer);
        vm.stopPrank();

        uint256 expiry = block.timestamp + 1 days;
        bytes32 structHash = keccak256(abi.encode(DELEGATION_TYPEHASH, bob, vault.nonces(signer), expiry));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);

        vault.delegateBySig(bob, 0, expiry, v, r, s);

        assertEq(vault.nonces(signer), 1);
        assertEq(vault.delegates(signer), bob);
        assertEq(vault.getVotes(signer), 0);
        assertEq(vault.getVotes(bob), 100e18);
    }

    function testDelegateBySigCannotReplayOrUseExpiredSignature() public {
        uint256 signerPrivateKey = 0xB0B;
        address signer = vm.addr(signerPrivateKey);

        depositToken.mint(signer, 100e18);
        vm.startPrank(signer);
        depositToken.approve(address(vault), type(uint256).max);
        vault.deposit(100e18, signer);
        vm.stopPrank();

        uint256 expiry = block.timestamp + 1 days;
        bytes32 structHash = keccak256(abi.encode(DELEGATION_TYPEHASH, bob, vault.nonces(signer), expiry));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);

        vault.delegateBySig(bob, 0, expiry, v, r, s);

        vm.expectRevert();
        vault.delegateBySig(bob, 0, expiry, v, r, s);

        uint256 expiredNonce = vault.nonces(signer);
        uint256 expiredAt = block.timestamp - 1;
        structHash = keccak256(abi.encode(DELEGATION_TYPEHASH, alice, expiredNonce, expiredAt));
        digest = keccak256(bytes.concat("\x19\x01", _domainSeparator(), structHash));
        (v, r, s) = vm.sign(signerPrivateKey, digest);

        vm.expectRevert();
        vault.delegateBySig(alice, expiredNonce, expiredAt, v, r, s);
    }

    function testMintPathBurnsAssetsAndSelfDelegates() public {
        vm.prank(alice);
        uint256 assets = vault.mint(25e18, alice);

        assertEq(assets, 25e18);
        assertEq(vault.balanceOf(alice), 25e18);
        assertEq(vault.totalAssets(), 25e18);
        assertEq(vault.totalSupply(), 25e18);
        assertEq(depositToken.balanceOf(address(vault)), 0);
        assertEq(vault.delegates(alice), alice);
        assertEq(vault.getVotes(alice), 25e18);
    }

    function testStandardWithdrawAndRedeemRemainDisabled() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.startPrank(alice);
        vm.expectRevert(DeepstateVault.UseRedeemValue.selector);
        vault.withdraw(1e18, alice, alice);
        vm.expectRevert(DeepstateVault.UseRedeemValue.selector);
        vault.redeem(1e18, alice, alice);
        vm.stopPrank();

        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.maxRedeemValue(alice), 100e18);
    }

    function testRedeemsProRataValueToken() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);

        valueToken.mint(address(vault), 1_000e6);

        vm.prank(alice);
        uint256 redeemed = vault.redeemValue(50e18, alice, alice);

        assertEq(redeemed, 250e6);
        assertEq(valueToken.balanceOf(alice), 250e6);
        assertEq(vault.balanceOf(alice), 50e18);
        assertEq(vault.totalSupply(), 150e18);

        assertEq(vault.convertToValueAssets(50e18), 250e6);
    }

    function testFinalStateBurnResetsAccountingAndStartsFreshEpoch() public {
        uint256 deepSupplyBefore = depositToken.totalSupply();

        vm.prank(alice);
        vault.deposit(100e18, alice);
        valueToken.mint(address(vault), 500e6);

        vm.expectEmit(false, false, false, true, address(vault));
        emit DepositAccountingReset(100e18);
        vm.prank(alice);
        uint256 redeemed = vault.redeemValue(100e18, alice, alice);

        assertEq(redeemed, 500e6);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalBurnedDepositAssets(), 0);
        assertEq(vault.getVotes(alice), 0);
        assertEq(depositToken.totalSupply(), deepSupplyBefore - 100e18);

        vm.prank(bob);
        uint256 bobShares = vault.deposit(1, bob);
        vm.prank(carol);
        uint256 carolShares = vault.deposit(50e18, carol);

        assertEq(bobShares, 1);
        assertEq(carolShares, 50e18);
        assertEq(vault.totalAssets(), 50e18 + 1);
        assertEq(vault.totalSupply(), 50e18 + 1);
        assertEq(depositToken.totalSupply(), deepSupplyBefore - 150e18 - 1);
    }

    function testValueRedeemRevertsWhenNoValueAssetsOrZeroShares() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.prank(alice);
        vm.expectRevert(DeepstateVault.ZeroShares.selector);
        vault.redeemValue(0, alice, alice);

        vm.prank(alice);
        vm.expectRevert(DeepstateVault.InsufficientValueAssets.selector);
        vault.redeemValue(1e18, alice, alice);
    }

    function testRedeemValueRevertsWhenSharesExceedOwnerBalance() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        valueToken.mint(address(vault), 1_000e6);

        vm.prank(alice);
        vm.expectRevert();
        vault.redeemValue(101e18, alice, alice);
    }

    function testAllowanceCanRedeemValueForOwner() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        valueToken.mint(address(vault), 500e6);

        vm.prank(alice);
        vault.approve(bob, 40e18);

        vm.prank(bob);
        uint256 redeemed = vault.redeemValue(40e18, bob, alice);

        assertEq(redeemed, 200e6);
        assertEq(valueToken.balanceOf(bob), 200e6);
        assertEq(vault.balanceOf(alice), 60e18);
    }

    function testRedeemAssetsPaysProRataERC20AndNativeBalances() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);

        valueToken.mint(address(vault), 1_000e6);
        feeToken.mint(address(vault), 10e18);
        vm.deal(address(vault), 2 ether);

        address[] memory tokens = new address[](3);
        tokens[0] = address(valueToken);
        tokens[1] = address(feeToken);
        tokens[2] = address(0);
        uint256[] memory minimumAmounts = new uint256[](3);
        minimumAmounts[0] = 250e6;
        minimumAmounts[1] = 2.5e18;
        minimumAmounts[2] = 0.5 ether;

        uint256 aliceNativeBefore = alice.balance;
        vm.prank(alice);
        uint256[] memory assets = vault.redeemAssets(50e18, alice, alice, tokens, minimumAmounts);

        assertEq(assets.length, 3);
        assertEq(assets[0], 250e6);
        assertEq(assets[1], 2.5e18);
        assertEq(assets[2], 0.5 ether);
        assertEq(valueToken.balanceOf(alice), 250e6);
        assertEq(feeToken.balanceOf(alice), 2.5e18);
        assertEq(alice.balance, aliceNativeBefore + 0.5 ether);
        assertEq(valueToken.balanceOf(address(vault)), 750e6);
        assertEq(feeToken.balanceOf(address(vault)), 7.5e18);
        assertEq(address(vault).balance, 1.5 ether);
        assertEq(vault.balanceOf(alice), 50e18);
        assertEq(vault.totalSupply(), 150e18);
        assertEq(vault.getVotes(alice), 50e18);
    }

    function testLegacyRedeemAssetsRequiresMinimumAmounts() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(valueToken);

        vm.expectRevert(DeepstateVault.MinimumAmountsRequired.selector);
        vault.redeemAssets(1e18, alice, alice, tokens);
    }

    function testRedeemAssetsMinimumsRejectDegradedBasketBeforeAllowanceOrBurn() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);

        feeToken.mint(address(vault), 10e18);
        otherFeeToken.mint(address(vault), 20e8);

        uint256 shares = 50e18;
        address[] memory tokens = new address[](2);
        tokens[0] = address(feeToken);
        tokens[1] = address(otherFeeToken);
        uint256[] memory minimumAmounts = new uint256[](2);
        minimumAmounts[0] = 2.5e18;
        minimumAmounts[1] = 5e8;

        address[] memory purchaseTokens = new address[](1);
        purchaseTokens[0] = address(feeToken);
        uint256[] memory purchaseMinimums = new uint256[](1);
        purchaseMinimums[0] = 10e18;
        vm.prank(buyer);
        vault.buyFees(purchaseTokens, purchaseMinimums, buyer);

        vm.prank(alice);
        vault.approve(carol, shares);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateVault.MinimumAssetAmountNotMet.selector, address(feeToken), uint256(0), minimumAmounts[0]
            )
        );
        vault.redeemAssets(shares, alice, alice, tokens, minimumAmounts);

        assertEq(vault.allowance(alice, carol), shares);
        assertEq(vault.balanceOf(alice), 100e18);
        assertEq(vault.totalSupply(), 200e18);
        assertEq(otherFeeToken.balanceOf(address(vault)), 20e8);
        assertEq(otherFeeToken.balanceOf(alice), 0);
    }

    function testFinalMultiAssetRedemptionResetsDepositAccounting() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        feeToken.mint(address(vault), 10e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(feeToken);

        vm.prank(alice);
        uint256[] memory assets = vault.redeemAssets(100e18, alice, alice, tokens, _zeroMinimums(tokens));

        assertEq(assets[0], 10e18);
        assertEq(feeToken.balanceOf(alice), 10e18);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalBurnedDepositAssets(), 0);
    }

    function testRedeemAssetsLeavesUnlistedAndZeroBalanceAssetsUntouched() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);
        valueToken.mint(address(vault), 1_000e6);
        vm.deal(address(vault), 2 ether);

        address[] memory tokens = new address[](2);
        tokens[0] = address(valueToken);
        tokens[1] = address(feeToken);

        vm.prank(alice);
        uint256[] memory assets = vault.redeemAssets(50e18, alice, alice, tokens, _zeroMinimums(tokens));

        assertEq(assets[0], 250e6);
        assertEq(assets[1], 0);
        assertEq(valueToken.balanceOf(address(vault)), 750e6);
        assertEq(address(vault).balance, 2 ether);
    }

    function testAllowanceCanRedeemMultipleAssetsForOwner() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        valueToken.mint(address(vault), 500e6);
        feeToken.mint(address(vault), 25e18);

        vm.prank(alice);
        vault.approve(bob, 40e18);

        address[] memory tokens = new address[](2);
        tokens[0] = address(valueToken);
        tokens[1] = address(feeToken);

        vm.prank(bob);
        uint256[] memory assets = vault.redeemAssets(40e18, carol, alice, tokens, _zeroMinimums(tokens));

        assertEq(assets[0], 200e6);
        assertEq(assets[1], 10e18);
        assertEq(vault.allowance(alice, bob), 0);
        assertEq(vault.balanceOf(alice), 60e18);
        assertEq(vault.getVotes(alice), 60e18);
        assertEq(valueToken.balanceOf(carol), 200e6);
        assertEq(feeToken.balanceOf(carol), 10e18);
    }

    function testRedeemAssetsRejectsDuplicateERC20AndNativeEntries() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        valueToken.mint(address(vault), 500e6);
        feeToken.mint(address(vault), 25e18);
        vm.deal(address(vault), 1 ether);

        address[] memory tokens = new address[](3);
        tokens[0] = address(valueToken);
        tokens[1] = address(feeToken);
        tokens[2] = address(valueToken);

        vm.prank(alice);
        vm.expectRevert(DeepstateVault.DuplicateAsset.selector);
        vault.redeemAssets(40e18, alice, alice, tokens, _zeroMinimums(tokens));

        tokens = new address[](2);
        tokens[0] = address(0);
        tokens[1] = address(0);

        vm.prank(alice);
        vm.expectRevert(DeepstateVault.DuplicateAsset.selector);
        vault.redeemAssets(40e18, alice, alice, tokens, _zeroMinimums(tokens));

        assertEq(vault.balanceOf(alice), 100e18);
        assertEq(vault.totalSupply(), 100e18);
        assertEq(valueToken.balanceOf(address(vault)), 500e6);
        assertEq(address(vault).balance, 1 ether);
    }

    function testRedeemAssetsTransientDuplicateStateIsScopedPerCall() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);
        valueToken.mint(address(vault), 1_000e6);

        address[] memory tokens = new address[](1);
        tokens[0] = address(valueToken);

        vm.startPrank(alice);
        uint256[] memory first = vault.redeemAssets(25e18, alice, alice, tokens, _zeroMinimums(tokens));
        uint256[] memory second = vault.redeemAssets(25e18, alice, alice, tokens, _zeroMinimums(tokens));
        vm.stopPrank();

        assertEq(first[0], 125e6);
        assertEq(second[0], 125e6);
        assertEq(valueToken.balanceOf(alice), 250e6);
        assertEq(vault.balanceOf(alice), 50e18);
        assertEq(vault.totalSupply(), 150e18);
    }

    function testRedeemAssetsRejectsInvalidAndProtectedLists() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        address[] memory tokens = new address[](1);
        tokens[0] = address(valueToken);

        vm.prank(alice);
        vm.expectRevert(DeepstateVault.ArrayLengthMismatch.selector);
        vault.redeemAssets(1e18, alice, alice, tokens, new uint256[](0));

        vm.prank(alice);
        vm.expectRevert(DeepstateVault.ZeroShares.selector);
        vault.redeemAssets(0, alice, alice, tokens, _zeroMinimums(tokens));

        vm.prank(alice);
        vm.expectRevert(DeepstateVault.ZeroAddress.selector);
        vault.redeemAssets(1e18, address(0), alice, tokens, _zeroMinimums(tokens));

        vm.prank(alice);
        vm.expectRevert();
        vault.redeemAssets(101e18, alice, alice, tokens, _zeroMinimums(tokens));

        tokens = new address[](0);
        vm.prank(alice);
        vm.expectRevert(DeepstateVault.EmptyAssetList.selector);
        vault.redeemAssets(1e18, alice, alice, tokens, _zeroMinimums(tokens));

        tokens = new address[](1);
        tokens[0] = address(feeToken);
        vm.prank(alice);
        vm.expectRevert(DeepstateVault.InsufficientRedeemableAssets.selector);
        vault.redeemAssets(1e18, alice, alice, tokens, _zeroMinimums(tokens));

        tokens[0] = address(depositToken);
        vm.prank(alice);
        vm.expectRevert(DeepstateVault.ProtectedToken.selector);
        vault.redeemAssets(1e18, alice, alice, tokens, _zeroMinimums(tokens));

        tokens[0] = address(vault);
        vm.prank(alice);
        vm.expectRevert(DeepstateVault.ProtectedToken.selector);
        vault.redeemAssets(1e18, alice, alice, tokens, _zeroMinimums(tokens));

        assertEq(vault.balanceOf(alice), 100e18);
        assertEq(vault.totalSupply(), 100e18);
    }

    function testRedeemAssetsFailedNativeTransferRollsBackBurnAndPayouts() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        valueToken.mint(address(vault), 500e6);
        vm.deal(address(vault), 1 ether);

        address[] memory tokens = new address[](2);
        tokens[0] = address(valueToken);
        tokens[1] = address(0);
        RejectingNativeReceiver receiver = new RejectingNativeReceiver();

        vm.prank(alice);
        vm.expectRevert();
        vault.redeemAssets(40e18, address(receiver), alice, tokens, _zeroMinimums(tokens));

        assertEq(vault.balanceOf(alice), 100e18);
        assertEq(vault.totalSupply(), 100e18);
        assertEq(valueToken.balanceOf(address(vault)), 500e6);
        assertEq(valueToken.balanceOf(address(receiver)), 0);
        assertEq(address(vault).balance, 1 ether);
    }

    function testRedeemAssetsBlocksNativeReceiverReentrancy() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.deal(address(vault), 1 ether);

        ReenteringNativeReceiver receiver = new ReenteringNativeReceiver(vault, address(0), 1e18);
        vm.prank(alice);
        assertTrue(vault.transfer(address(receiver), 20e18));

        address[] memory tokens = new address[](1);
        tokens[0] = address(0);

        vm.prank(address(receiver));
        uint256[] memory assets =
            vault.redeemAssets(10e18, address(receiver), address(receiver), tokens, _zeroMinimums(tokens));

        assertEq(assets[0], 0.1 ether);
        assertTrue(receiver.attempted());
        assertFalse(receiver.reentered());
        assertEq(address(receiver).balance, 0.1 ether);
        assertEq(vault.balanceOf(address(receiver)), 10e18);
        assertEq(vault.totalSupply(), 90e18);
        assertEq(address(vault).balance, 0.9 ether);
    }

    function testBuyFeesTransfersCompleteListedBalancesForFixedUSDG() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        feeToken.mint(address(vault), 10e18);
        otherFeeToken.mint(address(vault), 2_500e8);
        vm.deal(address(vault), 2 ether);

        address[] memory tokens = new address[](3);
        tokens[0] = address(feeToken);
        tokens[1] = address(otherFeeToken);
        tokens[2] = address(0);
        uint256[] memory minimumAmounts = new uint256[](3);
        minimumAmounts[0] = 10e18;
        minimumAmounts[1] = 2_500e8;
        minimumAmounts[2] = 2 ether;

        uint256 buyerPaymentBefore = valueToken.balanceOf(buyer);
        vm.prank(buyer);
        uint256[] memory assets = vault.buyFees(tokens, minimumAmounts, carol);

        assertEq(assets.length, 3);
        assertEq(assets[0], 10e18);
        assertEq(assets[1], 2_500e8);
        assertEq(assets[2], 2 ether);
        assertEq(feeToken.balanceOf(carol), 10e18);
        assertEq(otherFeeToken.balanceOf(carol), 2_500e8);
        assertEq(carol.balance, 2 ether);
        assertEq(feeToken.balanceOf(address(vault)), 0);
        assertEq(otherFeeToken.balanceOf(address(vault)), 0);
        assertEq(address(vault).balance, 0);
        assertEq(valueToken.balanceOf(buyer), buyerPaymentBefore - vault.FEE_PURCHASE_PRICE());
        assertEq(valueToken.balanceOf(address(vault)), vault.FEE_PURCHASE_PRICE());
        assertEq(vault.previewRedeemValue(100e18), vault.FEE_PURCHASE_PRICE());
    }

    function testBuyFeesLeavesUnlistedAndZeroBalanceAssetsUntouched() public {
        feeToken.mint(address(vault), 10e18);
        vm.deal(address(vault), 2 ether);

        address[] memory tokens = new address[](2);
        tokens[0] = address(feeToken);
        tokens[1] = address(otherFeeToken);
        uint256[] memory minimumAmounts = new uint256[](2);

        vm.prank(buyer);
        uint256[] memory assets = vault.buyFees(tokens, minimumAmounts, buyer);

        assertEq(assets[0], 10e18);
        assertEq(assets[1], 0);
        assertEq(feeToken.balanceOf(buyer), 10e18);
        assertEq(address(vault).balance, 2 ether);
        assertEq(valueToken.balanceOf(address(vault)), vault.FEE_PURCHASE_PRICE());
    }

    function testBuyFeesRejectsDEEPSTATEAndUSDG() public {
        feeToken.mint(address(vault), 1e18);
        address[] memory tokens = new address[](1);
        uint256[] memory minimumAmounts = new uint256[](1);

        tokens[0] = address(depositToken);
        vm.prank(buyer);
        vm.expectRevert(DeepstateVault.ProtectedToken.selector);
        vault.buyFees(tokens, minimumAmounts, buyer);

        tokens[0] = address(vault);
        vm.prank(buyer);
        vm.expectRevert(DeepstateVault.ProtectedToken.selector);
        vault.buyFees(tokens, minimumAmounts, buyer);

        tokens[0] = address(valueToken);
        vm.prank(buyer);
        vm.expectRevert(DeepstateVault.ProtectedToken.selector);
        vault.buyFees(tokens, minimumAmounts, buyer);

        assertEq(valueToken.balanceOf(address(vault)), 0);
        assertEq(valueToken.balanceOf(buyer), 1_000_000e6);
    }

    function testBuyFeesRejectsDuplicateERC20AndNativeEntries() public {
        feeToken.mint(address(vault), 1e18);
        vm.deal(address(vault), 1 ether);

        address[] memory tokens = new address[](2);
        tokens[0] = address(feeToken);
        tokens[1] = address(feeToken);
        uint256[] memory minimumAmounts = new uint256[](2);

        vm.prank(buyer);
        vm.expectRevert(DeepstateVault.DuplicateAsset.selector);
        vault.buyFees(tokens, minimumAmounts, buyer);

        tokens[0] = address(0);
        tokens[1] = address(0);
        vm.prank(buyer);
        vm.expectRevert(DeepstateVault.DuplicateAsset.selector);
        vault.buyFees(tokens, minimumAmounts, buyer);

        assertEq(valueToken.balanceOf(address(vault)), 0);
        assertEq(feeToken.balanceOf(address(vault)), 1e18);
        assertEq(address(vault).balance, 1 ether);
    }

    function testBuyFeesRejectsInvalidListsAndInsufficientBalances() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(feeToken);
        uint256[] memory minimumAmounts = new uint256[](1);

        vm.prank(buyer);
        vm.expectRevert(DeepstateVault.ZeroAddress.selector);
        vault.buyFees(tokens, minimumAmounts, address(0));

        tokens = new address[](0);
        minimumAmounts = new uint256[](0);
        vm.prank(buyer);
        vm.expectRevert(DeepstateVault.EmptyAssetList.selector);
        vault.buyFees(tokens, minimumAmounts, buyer);

        tokens = new address[](1);
        tokens[0] = address(feeToken);
        vm.prank(buyer);
        vm.expectRevert(DeepstateVault.ArrayLengthMismatch.selector);
        vault.buyFees(tokens, minimumAmounts, buyer);

        minimumAmounts = new uint256[](1);
        vm.prank(buyer);
        vm.expectRevert(DeepstateVault.InsufficientFeeAssets.selector);
        vault.buyFees(tokens, minimumAmounts, buyer);

        feeToken.mint(address(vault), 1e18);
        minimumAmounts[0] = 2e18;
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateVault.MinimumAssetAmountNotMet.selector, address(feeToken), uint256(1e18), uint256(2e18)
            )
        );
        vault.buyFees(tokens, minimumAmounts, buyer);

        assertEq(valueToken.balanceOf(address(vault)), 0);
        assertEq(valueToken.balanceOf(buyer), 1_000_000e6);
    }

    function testBuyFeesFailedNativeTransferRollsBackPaymentAndERC20Payout() public {
        feeToken.mint(address(vault), 10e18);
        vm.deal(address(vault), 2 ether);
        RejectingNativeReceiver receiver = new RejectingNativeReceiver();

        address[] memory tokens = new address[](2);
        tokens[0] = address(feeToken);
        tokens[1] = address(0);
        uint256[] memory minimumAmounts = new uint256[](2);

        uint256 buyerPaymentBefore = valueToken.balanceOf(buyer);
        vm.prank(buyer);
        vm.expectRevert();
        vault.buyFees(tokens, minimumAmounts, address(receiver));

        assertEq(valueToken.balanceOf(buyer), buyerPaymentBefore);
        assertEq(valueToken.balanceOf(address(vault)), 0);
        assertEq(feeToken.balanceOf(address(vault)), 10e18);
        assertEq(feeToken.balanceOf(address(receiver)), 0);
        assertEq(address(vault).balance, 2 ether);
    }

    function testBuyFeesBlocksReceiverReentrancy() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        feeToken.mint(address(vault), 10e18);
        vm.deal(address(vault), 1 ether);

        ReenteringNativeReceiver receiver = new ReenteringNativeReceiver(vault, address(valueToken), 1e18);
        vm.prank(alice);
        assertTrue(vault.transfer(address(receiver), 10e18));

        address[] memory tokens = new address[](2);
        tokens[0] = address(feeToken);
        tokens[1] = address(0);
        uint256[] memory minimumAmounts = new uint256[](2);

        vm.prank(buyer);
        vault.buyFees(tokens, minimumAmounts, address(receiver));

        assertTrue(receiver.attempted());
        assertFalse(receiver.reentered());
        assertEq(valueToken.balanceOf(address(receiver)), 0);
        assertEq(vault.balanceOf(address(receiver)), 10e18);
        assertEq(valueToken.balanceOf(address(vault)), vault.FEE_PURCHASE_PRICE());
        assertEq(feeToken.balanceOf(address(receiver)), 10e18);
        assertEq(address(receiver).balance, 1 ether);
    }

    function testBuyFeesRejectsFeeOnTransferUSDGPayment() public {
        FeeOnTransferERC20 feeOnTransferValueToken = new FeeOnTransferERC20();
        DeepstateVault feeOnTransferVault = new DeepstateVault(
            owner, address(depositToken), address(feeOnTransferValueToken), "Deepstate Governance", "STATE"
        );
        feeOnTransferValueToken.mint(buyer, feeOnTransferVault.FEE_PURCHASE_PRICE());
        vm.prank(buyer);
        feeOnTransferValueToken.approve(address(feeOnTransferVault), type(uint256).max);
        feeToken.mint(address(feeOnTransferVault), 10e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(feeToken);
        uint256[] memory minimumAmounts = new uint256[](1);

        vm.prank(buyer);
        vm.expectRevert(DeepstateVault.InvalidFeePayment.selector);
        feeOnTransferVault.buyFees(tokens, minimumAmounts, buyer);

        assertEq(feeOnTransferValueToken.balanceOf(buyer), feeOnTransferVault.FEE_PURCHASE_PRICE());
        assertEq(feeOnTransferValueToken.balanceOf(address(feeOnTransferVault)), 0);
        assertEq(feeToken.balanceOf(address(feeOnTransferVault)), 10e18);
    }

    function testBuyFeesTransientDuplicateStateIsScopedPerCall() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(feeToken);
        uint256[] memory minimumAmounts = new uint256[](1);

        feeToken.mint(address(vault), 1e18);
        vm.prank(buyer);
        vault.buyFees(tokens, minimumAmounts, buyer);

        feeToken.mint(address(vault), 2e18);
        vm.prank(buyer);
        vault.buyFees(tokens, minimumAmounts, buyer);

        assertEq(feeToken.balanceOf(buyer), 3e18);
        assertEq(valueToken.balanceOf(address(vault)), 2 * vault.FEE_PURCHASE_PRICE());
    }

    function testFuzzDepositRedeemValueAccounting(uint96 aliceAssets, uint96 bobAssets, uint96 valueAssets) public {
        uint256 aliceDeposit = bound(uint256(aliceAssets), 2, 100e18);
        uint256 bobDeposit = bound(uint256(bobAssets), 1, 100e18);
        uint256 valueDeposit = bound(uint256(valueAssets), 1e6, 1_000_000e6);

        vm.prank(alice);
        uint256 aliceShares = vault.deposit(aliceDeposit, alice);
        vm.prank(bob);
        uint256 bobShares = vault.deposit(bobDeposit, bob);

        valueToken.mint(address(vault), valueDeposit);

        uint256 aliceRedeemShares = aliceShares / 2;
        uint256 expectedValue = aliceRedeemShares * valueDeposit / (aliceShares + bobShares);
        vm.assume(expectedValue != 0);

        vm.prank(alice);
        uint256 redeemed = vault.redeemValue(aliceRedeemShares, alice, alice);

        assertEq(redeemed, expectedValue);
        assertEq(valueToken.balanceOf(alice), expectedValue);
        assertEq(vault.totalAssets(), aliceDeposit + bobDeposit);
        assertEq(vault.totalSupply(), aliceShares + bobShares - aliceRedeemShares);
        assertEq(vault.getVotes(alice), aliceShares - aliceRedeemShares);
        assertEq(vault.getVotes(bob), bobShares);
        assertEq(depositToken.balanceOf(address(vault)), 0);
    }

    function testFuzzFinalRedemptionStartsFreshOneToOneEpoch(
        uint96 firstDepositSeed,
        uint96 nextDepositSeed,
        uint96 valueDepositSeed
    ) public {
        uint256 firstDeposit = bound(uint256(firstDepositSeed), 1, 100e18);
        uint256 nextDeposit = bound(uint256(nextDepositSeed), 1, 100e18);
        uint256 valueDeposit = bound(uint256(valueDepositSeed), 1, 1_000_000e6);
        uint256 deepSupplyBefore = depositToken.totalSupply();

        vm.prank(alice);
        uint256 firstShares = vault.deposit(firstDeposit, alice);
        valueToken.mint(address(vault), valueDeposit);

        vm.prank(alice);
        uint256 redeemed = vault.redeemValue(firstShares, alice, alice);

        assertEq(redeemed, valueDeposit);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
        assertEq(depositToken.totalSupply(), deepSupplyBefore - firstDeposit);

        vm.prank(bob);
        uint256 nextShares = vault.deposit(nextDeposit, bob);

        assertEq(nextShares, nextDeposit);
        assertEq(vault.totalSupply(), nextDeposit);
        assertEq(vault.totalAssets(), nextDeposit);
        assertEq(depositToken.totalSupply(), deepSupplyBefore - firstDeposit - nextDeposit);
    }

    function testFuzzRedeemAssetsAccounting(
        uint96 aliceAssets,
        uint96 bobAssets,
        uint96 redeemShares,
        uint96 valueAssets,
        uint96 feeAssets,
        uint96 nativeAssets
    ) public {
        uint256 aliceDeposit = bound(uint256(aliceAssets), 2e18, 100e18);
        uint256 bobDeposit = bound(uint256(bobAssets), 1e18, 100e18);
        uint256 sharesToRedeem = bound(uint256(redeemShares), 1e18, aliceDeposit);
        uint256 valueDeposit = bound(uint256(valueAssets), 1e6, 1_000_000e6);
        uint256 feeDeposit = bound(uint256(feeAssets), 1e18, 1_000_000e18);
        uint256 nativeDeposit = bound(uint256(nativeAssets), 1 ether, 1_000_000 ether);

        vm.prank(alice);
        vault.deposit(aliceDeposit, alice);
        vm.prank(bob);
        vault.deposit(bobDeposit, bob);

        valueToken.mint(address(vault), valueDeposit);
        feeToken.mint(address(vault), feeDeposit);
        vm.deal(address(vault), nativeDeposit);

        uint256 supply = aliceDeposit + bobDeposit;
        uint256 expectedValue = sharesToRedeem * valueDeposit / supply;
        uint256 expectedFee = sharesToRedeem * feeDeposit / supply;
        uint256 expectedNative = sharesToRedeem * nativeDeposit / supply;
        address[] memory tokens = new address[](3);
        tokens[0] = address(valueToken);
        tokens[1] = address(feeToken);
        tokens[2] = address(0);

        vm.prank(alice);
        uint256[] memory assets = vault.redeemAssets(sharesToRedeem, alice, alice, tokens, _zeroMinimums(tokens));

        assertEq(assets[0], expectedValue);
        assertEq(assets[1], expectedFee);
        assertEq(assets[2], expectedNative);
        assertEq(valueToken.balanceOf(alice), expectedValue);
        assertEq(feeToken.balanceOf(alice), expectedFee);
        assertEq(alice.balance, expectedNative);
        assertEq(valueToken.balanceOf(address(vault)), valueDeposit - expectedValue);
        assertEq(feeToken.balanceOf(address(vault)), feeDeposit - expectedFee);
        assertEq(address(vault).balance, nativeDeposit - expectedNative);
        assertEq(vault.balanceOf(alice), aliceDeposit - sharesToRedeem);
        assertEq(vault.totalSupply(), supply - sharesToRedeem);
        assertEq(vault.getVotes(alice), aliceDeposit - sharesToRedeem);
        assertEq(vault.getVotes(bob), bobDeposit);
        assertEq(vault.totalAssets(), supply);
    }

    function testFuzzBuyFeesTransfersCompleteListedBalances(uint96 feeAssets, uint96 otherAssets, uint96 nativeAssets)
        public
    {
        uint256 feeDeposit = bound(uint256(feeAssets), 1, 1_000_000e18);
        uint256 otherDeposit = bound(uint256(otherAssets), 1, 1_000_000e8);
        uint256 nativeDeposit = bound(uint256(nativeAssets), 1, 1_000_000 ether);

        feeToken.mint(address(vault), feeDeposit);
        otherFeeToken.mint(address(vault), otherDeposit);
        vm.deal(address(vault), nativeDeposit);

        address[] memory tokens = new address[](3);
        tokens[0] = address(feeToken);
        tokens[1] = address(otherFeeToken);
        tokens[2] = address(0);
        uint256[] memory minimumAmounts = new uint256[](3);
        minimumAmounts[0] = feeDeposit;
        minimumAmounts[1] = otherDeposit;
        minimumAmounts[2] = nativeDeposit;

        uint256 buyerPaymentBefore = valueToken.balanceOf(buyer);
        vm.prank(buyer);
        uint256[] memory purchased = vault.buyFees(tokens, minimumAmounts, carol);

        assertEq(purchased[0], feeDeposit);
        assertEq(purchased[1], otherDeposit);
        assertEq(purchased[2], nativeDeposit);
        assertEq(feeToken.balanceOf(carol), feeDeposit);
        assertEq(otherFeeToken.balanceOf(carol), otherDeposit);
        assertEq(carol.balance, nativeDeposit);
        assertEq(feeToken.balanceOf(address(vault)), 0);
        assertEq(otherFeeToken.balanceOf(address(vault)), 0);
        assertEq(address(vault).balance, 0);
        assertEq(valueToken.balanceOf(buyer), buyerPaymentBefore - vault.FEE_PURCHASE_PRICE());
        assertEq(valueToken.balanceOf(address(vault)), vault.FEE_PURCHASE_PRICE());
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

    function _zeroMinimums(address[] memory tokens) private pure returns (uint256[] memory) {
        return new uint256[](tokens.length);
    }
}
