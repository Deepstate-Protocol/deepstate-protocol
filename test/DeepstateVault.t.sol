// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {FeeFlowController} from "fee-flow/FeeFlowController.sol";
import {EthereumVaultConnector} from "evc/EthereumVaultConnector.sol";

import {DeepstateVault} from "../src/DeepstateVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockWETH} from "./mocks/MockWETH.sol";

contract DeepstateVaultHarness is DeepstateVault {
    constructor(
        address owner_,
        address depositToken_,
        address valueToken_,
        address wrappedNative_,
        string memory name_,
        string memory symbol_
    ) DeepstateVault(owner_, depositToken_, valueToken_, wrappedNative_, name_, symbol_) {}

    function exposedDeposit(address caller, address receiver, uint256 assets, uint256 shares) external {
        _deposit(caller, receiver, assets, shares);
    }
}

contract DeepstateVaultTest is Test {
    bytes32 internal constant DELEGATION_TYPEHASH =
        keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    uint256 internal constant INIT_PRICE = 100e6;
    uint256 internal constant MIN_INIT_PRICE = 1e6;
    uint256 internal constant EPOCH_PERIOD = 14 days;
    uint256 internal constant PRICE_MULTIPLIER = 2e18;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal buyer = makeAddr("buyer");
    address internal carol = makeAddr("carol");

    MockERC20 internal depositToken;
    MockERC20 internal valueToken;
    MockERC20 internal feeToken;
    MockWETH internal wrappedNative;
    DeepstateVault internal vault;
    EthereumVaultConnector internal evc;
    FeeFlowController internal auction;

    function setUp() public {
        depositToken = new MockERC20("Deposit", "DEP", 18);
        valueToken = new MockERC20("USD Coin", "USDC", 6);
        feeToken = new MockERC20("Fee Token", "FEE", 18);
        wrappedNative = new MockWETH();

        vault = new DeepstateVault(
            owner, address(depositToken), address(valueToken), address(wrappedNative), "Deepstate Governance", "STATE"
        );

        evc = new EthereumVaultConnector();
        auction = new FeeFlowController(
            address(evc),
            INIT_PRICE,
            address(valueToken),
            address(vault),
            EPOCH_PERIOD,
            PRICE_MULTIPLIER,
            MIN_INIT_PRICE
        );

        vm.prank(owner);
        vault.setAuction(address(auction));

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
        valueToken.approve(address(auction), type(uint256).max);
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
        assertEq(vault.wrappedNative(), address(wrappedNative));
        assertEq(vault.owner(), owner);

        vm.expectRevert(DeepstateVault.ZeroAddress.selector);
        new DeepstateVault(
            owner, address(0), address(valueToken), address(wrappedNative), "Deepstate Governance", "STATE"
        );

        vm.expectRevert(DeepstateVault.ZeroAddress.selector);
        new DeepstateVault(
            owner, address(depositToken), address(0), address(wrappedNative), "Deepstate Governance", "STATE"
        );
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

    function testInternalDepositRejectsZeroShares() public {
        DeepstateVaultHarness harness = new DeepstateVaultHarness(
            owner, address(depositToken), address(valueToken), address(wrappedNative), "Deepstate Governance", "STATE"
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

    function testSweepAndAuctionFeeAssetsForValueToken() public {
        feeToken.mint(address(vault), 10e18);
        vm.deal(address(vault), 2 ether);

        address[] memory tokens = new address[](1);
        tokens[0] = address(feeToken);

        vm.prank(owner);
        vault.sweepToAuction(tokens);
        vm.prank(owner);
        vault.sweepNativeToAuction();

        assertEq(feeToken.balanceOf(address(auction)), 10e18);
        assertEq(wrappedNative.balanceOf(address(auction)), 2 ether);

        uint256 price = auction.getPrice();
        address[] memory auctionAssets = new address[](2);
        auctionAssets[0] = address(feeToken);
        auctionAssets[1] = address(wrappedNative);

        vm.prank(buyer);
        uint256 paid = auction.buy(auctionAssets, buyer, 0, block.timestamp + 1, price);

        assertEq(paid, INIT_PRICE);
        assertEq(valueToken.balanceOf(address(vault)), INIT_PRICE);
        assertEq(feeToken.balanceOf(buyer), 10e18);
        assertEq(wrappedNative.balanceOf(buyer), 2 ether);
        assertEq(feeToken.balanceOf(address(auction)), 0);
        assertEq(wrappedNative.balanceOf(address(auction)), 0);
    }

    function testAuctionPriceDecaysAndNextEpochUsesMultiplier() public {
        feeToken.mint(address(auction), 1e18);

        skip(EPOCH_PERIOD / 2);

        uint256 price = auction.getPrice();
        assertEq(price, INIT_PRICE / 2);

        address[] memory assets = new address[](1);
        assets[0] = address(feeToken);

        vm.prank(buyer);
        auction.buy(assets, buyer, 0, block.timestamp + 1, price);

        FeeFlowController.Slot0 memory slot0 = auction.getSlot0();
        assertEq(slot0.epochId, 1);
        assertEq(slot0.initPrice, price * 2);
        assertEq(slot0.startTime, block.timestamp);
    }

    function testSweepRejectsProtectedTokens() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(valueToken);

        vm.prank(owner);
        vm.expectRevert(DeepstateVault.ProtectedToken.selector);
        vault.sweepToAuction(tokens);

        tokens[0] = address(depositToken);

        vm.prank(owner);
        vm.expectRevert(DeepstateVault.ProtectedToken.selector);
        vault.sweepToAuction(tokens);
    }

    function testSetAuctionRejectsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(DeepstateVault.ZeroAddress.selector);
        vault.setAuction(address(0));
    }

    function testSweepRequiresAuctionAndSkipsZeroBalances() public {
        DeepstateVault noAuctionVault = new DeepstateVault(
            owner, address(depositToken), address(valueToken), address(wrappedNative), "Deepstate Governance", "STATE"
        );

        address[] memory tokens = new address[](1);
        tokens[0] = address(feeToken);

        vm.prank(owner);
        vm.expectRevert(DeepstateVault.AuctionNotSet.selector);
        noAuctionVault.sweepToAuction(tokens);

        vm.prank(owner);
        vault.sweepToAuction(tokens);

        assertEq(feeToken.balanceOf(address(auction)), 0);
    }

    function testSweepNativeRequiresAuctionAndWrappedNativeWhenBalanceExists() public {
        DeepstateVault noAuctionVault = new DeepstateVault(
            owner, address(depositToken), address(valueToken), address(wrappedNative), "Deepstate Governance", "STATE"
        );

        vm.prank(owner);
        vm.expectRevert(DeepstateVault.AuctionNotSet.selector);
        noAuctionVault.sweepNativeToAuction();

        vm.prank(owner);
        vault.sweepNativeToAuction();

        assertEq(wrappedNative.balanceOf(address(auction)), 0);

        DeepstateVault noWrappedNativeVault = new DeepstateVault(
            owner, address(depositToken), address(valueToken), address(0), "Deepstate Governance", "STATE"
        );

        vm.prank(owner);
        noWrappedNativeVault.setAuction(address(auction));

        vm.prank(owner);
        vm.expectRevert(DeepstateVault.WrappedNativeNotSet.selector);
        noWrappedNativeVault.sweepNativeToAuction();

        vm.deal(address(noWrappedNativeVault), 1 ether);

        vm.prank(owner);
        vm.expectRevert(DeepstateVault.WrappedNativeNotSet.selector);
        noWrappedNativeVault.sweepNativeToAuction();
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
}
