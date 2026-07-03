// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {FeeFlowController} from "fee-flow/FeeFlowController.sol";
import {EthereumVaultConnector} from "evc/EthereumVaultConnector.sol";

import {NigiriVault} from "../src/NigiriVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockWETH} from "./mocks/MockWETH.sol";

contract NigiriVaultTest is Test {
    uint256 internal constant INIT_PRICE = 100e6;
    uint256 internal constant MIN_INIT_PRICE = 1e6;
    uint256 internal constant EPOCH_PERIOD = 14 days;
    uint256 internal constant PRICE_MULTIPLIER = 2e18;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal buyer = makeAddr("buyer");

    MockERC20 internal depositToken;
    MockERC20 internal valueToken;
    MockERC20 internal feeToken;
    MockWETH internal wrappedNative;
    NigiriVault internal vault;
    EthereumVaultConnector internal evc;
    FeeFlowController internal auction;

    function setUp() public {
        depositToken = new MockERC20("Deposit", "DEP", 18);
        valueToken = new MockERC20("USD Coin", "USDC", 6);
        feeToken = new MockERC20("Fee Token", "FEE", 18);
        wrappedNative = new MockWETH();

        vault = new NigiriVault(
            owner, address(depositToken), address(valueToken), address(wrappedNative), "Nigiri Vault Share", "nVLT"
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
        valueToken.mint(buyer, 1_000_000e6);

        vm.prank(alice);
        depositToken.approve(address(vault), type(uint256).max);
        vm.prank(bob);
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
        assertEq(depositToken.balanceOf(address(vault)), 0);
        assertEq(depositToken.balanceOf(alice), 0);

        vm.prank(bob);
        uint256 bobShares = vault.deposit(50e18, bob);

        assertEq(bobShares, 50e18);
        assertEq(vault.totalAssets(), 150e18);
        assertEq(vault.totalSupply(), 150e18);
        assertEq(depositToken.balanceOf(address(vault)), 0);
        assertEq(vault.convertToShares(25e18), 25e18);
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
        vm.expectRevert(NigiriVault.ProtectedToken.selector);
        vault.sweepToAuction(tokens);
    }
}
