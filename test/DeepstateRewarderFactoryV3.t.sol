// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeepstateTokenV2 as DeepstateToken} from "../src/DeepstateTokenV2.sol";
import {DeepstateRewarderV3} from "../src/DeepstateRewarderV3.sol";
import {DeepstateRewarderFactoryV3} from "../src/DeepstateRewarderFactoryV3.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MockRouterV3 {
    address public owner;
    mapping(bytes32 poolId => address hook) public poolHook;
    bytes32 public currentBookId = keccak256("book");

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function setPoolHookConfig(address token0, address token1, address hook, bool, bool) external onlyOwner {
        poolHook[keccak256(abi.encode(token0, token1))] = hook;
    }

    function setFeeConfig(address, uint16) external onlyOwner {}

    function activeBookId(address, address) external view returns (bytes32) {
        return currentBookId;
    }

    function topOrder(bytes32, bool isBid) external pure returns (uint32 nonce, uint160 soldAmount) {
        return isBid ? (uint32(11), uint160(2e18)) : (uint32(22), uint160(3e6));
    }

    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }
}

contract DeepstateRewarderFactoryV3Test is Test {
    address internal unauthorized = makeAddr("unauthorized");

    DeepstateToken internal token;
    MockRouterV3 internal router;
    DeepstateRewarderFactoryV3 internal factory;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    function setUp() public {
        token = new DeepstateToken(address(this), 3_000_000_000e18);
        router = new MockRouterV3();
        factory = new DeepstateRewarderFactoryV3(address(this), address(router), address(token));
        tokenA = new MockERC20("Token A", "A", 6);
        tokenB = new MockERC20("Token B", "B", 18);

        token.grantRole(token.MINTER_ROLE(), address(factory));
        router.transferOwnership(address(factory));
    }

    function testGovernanceDeploysFullyFundedRewarderAndCanReplaceIt() public {
        DeepstateRewarderFactoryV3.MarketConfig memory config = _config();
        DeepstateRewarderV3 first = factory.deployMarket(config);
        bytes32 poolId = keccak256(abi.encode(config.token0, config.token1));

        assertEq(token.balanceOf(address(first)), 100_000_000e18);
        assertEq(first.owner(), address(factory));
        assertEq(first.sideEmissionCap(), 50_000_000e18);
        assertEq(first.emissionDuration(), 365 days);
        assertEq(router.poolHook(poolId), address(first));
        (uint32 token0Nonce, uint64 token0StartedAt) = first.rewardees(config.token0);
        (uint32 token1Nonce, uint64 token1StartedAt) = first.rewardees(config.token1);
        assertEq(token0Nonce, 22);
        assertEq(token1Nonce, 11);
        assertEq(token0StartedAt, block.timestamp);
        assertEq(token1StartedAt, block.timestamp);

        DeepstateRewarderV3 second = factory.deployMarket(config);
        assertNotEq(address(first), address(second));
        assertEq(router.poolHook(poolId), address(second));
        assertEq(token.totalSupply(), 200_000_000e18);
    }

    function testUnauthorizedAddressCannotDeployMarket() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        factory.deployMarket(_config());
    }

    function testOnlyGovernorCanReturnRouterOwnership() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        factory.returnDeepstateOwnership();

        factory.returnDeepstateOwnership();
        assertEq(router.owner(), address(this));
    }

    function _config() private view returns (DeepstateRewarderFactoryV3.MarketConfig memory config) {
        (address token0, address token1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));
        bool tokenAIsToken0 = token0 == address(tokenA);

        config = DeepstateRewarderFactoryV3.MarketConfig({
            token0: token0,
            token1: token1,
            token0MaxUnits: tokenAIsToken0 ? 1_000_000 : 5_000,
            token1MaxUnits: tokenAIsToken0 ? 5_000 : 1_000_000,
            token0Active: true,
            token1Active: true
        });
    }
}
