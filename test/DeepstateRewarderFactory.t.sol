// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {DeepstateV1} from "deepstate-contracts/DeepstateV1.sol";

import {DeepstateRewarder} from "../src/DeepstateRewarder.sol";
import {DeepstateMinterController} from "../src/DeepstateMinterController.sol";
import {DeepstateRewarderFactory} from "../src/DeepstateRewarderFactory.sol";
import {DeepstateRewarderV2} from "../src/DeepstateRewarderV2.sol";
import {DeepstateV1Controller} from "../src/DeepstateV1Controller.sol";
import {DeepstateToken} from "../src/DeepstateToken.sol";
import {IDeepstateMinterController} from "../src/interfaces/IDeepstateMinterController.sol";
import {MockSablierLockupLinearV4} from "./mocks/MockSablierLockupLinearV4.sol";

contract InvalidRewardTokenMinterController is IDeepstateMinterController {
    address internal immutable _deepstateToken;
    address internal immutable _owner;

    constructor(address deepstateToken_) {
        _deepstateToken = deepstateToken_;
        _owner = msg.sender;
    }

    function owner() external view returns (address) {
        return _owner;
    }

    function deepstateToken() external view returns (address) {
        return _deepstateToken;
    }

    function mint(address, uint256) external pure returns (uint256) {
        return 0;
    }
}

contract DeepstateRewarderFactoryTest is Test {
    address internal constant TOKEN_A = address(0x1000);
    address internal constant TOKEN_B = address(0x2000);
    address internal constant TOKEN_C = address(0x3000);
    address internal constant TOKEN_D = address(0x4000);

    DeepstateToken internal deep;
    DeepstateV1 internal deepstate;
    DeepstateV1Controller internal deepstateV1Controller;
    DeepstateMinterController internal minterController;
    DeepstateRewarderFactory internal factory;
    MockSablierLockupLinearV4 internal sablier;

    address internal operator = makeAddr("operator");
    address internal alice = makeAddr("alice");
    address internal vestingRecipient = makeAddr("vestingRecipient");

    function setUp() public {
        vm.warp(1_000_000);

        deep = new DeepstateToken(address(this), "Deepstate", "DEEP");
        sablier = new MockSablierLockupLinearV4();
        deepstate = new DeepstateV1();
        deepstateV1Controller = new DeepstateV1Controller(address(this), address(deepstate));
        minterController = _newMinterController(address(this), deep);
        factory = new DeepstateRewarderFactory(address(this), address(deepstateV1Controller), address(minterController));

        minterController.grantRoles(address(factory), minterController.MINTER_ROLE());
        deepstate.transferOwnership(address(deepstateV1Controller));
        deepstateV1Controller.grantRoles(address(factory), deepstateV1Controller.HOOK_MANAGER_ROLE());
        factory.setOperator(operator);
    }

    function test_ImmutableConfigurationAndInitialAuthority() public view {
        assertEq(factory.owner(), address(this));
        assertEq(factory.operator(), operator);
        assertEq(address(factory.deepstateV1Controller()), address(deepstateV1Controller));
        assertEq(address(factory.deepstate()), address(deepstate));
        assertEq(address(factory.minterController()), address(minterController));
        assertEq(address(factory.rewardToken()), address(deep));
        assertEq(factory.DEPLOYMENT_COOLDOWN(), 3 days);
        assertEq(factory.EMISSION_DURATION(), 395 days);
        assertEq(factory.SIDE_EMISSION_CAP(), 500_000_000e18);
        assertEq(factory.INITIAL_FUNDING(), 100_000_000e18);
        assertTrue(deep.hasRole(deep.MINTER_ROLE(), address(minterController)));
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), address(factory)));
        assertTrue(minterController.hasAnyRole(address(factory), minterController.MINTER_ROLE()));
        assertEq(deepstate.owner(), address(deepstateV1Controller));
        assertTrue(deepstateV1Controller.hasAnyRole(address(factory), deepstateV1Controller.HOOK_MANAGER_ROLE()));
        assertEq(factory.nextDeploymentAt(), 0);
    }

    function test_ConstructorValidation() public {
        vm.expectRevert(DeepstateRewarderFactory.InvalidOwner.selector);
        new DeepstateRewarderFactory(address(0), address(deepstateV1Controller), address(minterController));

        vm.expectRevert(DeepstateRewarderFactory.InvalidDeepstateV1Controller.selector);
        new DeepstateRewarderFactory(address(this), address(0), address(minterController));

        vm.expectRevert(DeepstateRewarderFactory.InvalidDeepstateV1Controller.selector);
        new DeepstateRewarderFactory(address(this), alice, address(minterController));

        DeepstateV1Controller independentlyOwnedController = new DeepstateV1Controller(alice, address(deepstate));
        DeepstateRewarderFactory independentlyOwnedControllerFactory = new DeepstateRewarderFactory(
            address(this), address(independentlyOwnedController), address(minterController)
        );
        assertEq(independentlyOwnedControllerFactory.owner(), address(this));
        assertEq(independentlyOwnedController.owner(), alice);

        vm.expectRevert(DeepstateRewarderFactory.InvalidMinterController.selector);
        new DeepstateRewarderFactory(address(this), address(deepstateV1Controller), address(0));

        vm.expectRevert(DeepstateRewarderFactory.InvalidMinterController.selector);
        new DeepstateRewarderFactory(address(this), address(deepstateV1Controller), alice);

        DeepstateMinterController mismatchedMinter = _newMinterController(alice, deep);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateRewarderFactory.MinterControllerOwnerMismatch.selector, address(this), alice
            )
        );
        new DeepstateRewarderFactory(address(this), address(deepstateV1Controller), address(mismatchedMinter));

        InvalidRewardTokenMinterController zeroTokenController = new InvalidRewardTokenMinterController(address(0));
        vm.expectRevert(DeepstateRewarderFactory.InvalidRewardToken.selector);
        new DeepstateRewarderFactory(address(this), address(deepstateV1Controller), address(zeroTokenController));

        InvalidRewardTokenMinterController eoaTokenController = new InvalidRewardTokenMinterController(alice);
        vm.expectRevert(DeepstateRewarderFactory.InvalidRewardToken.selector);
        new DeepstateRewarderFactory(address(this), address(deepstateV1Controller), address(eoaTokenController));
    }

    function test_GovernanceOwnerIsIndependentFromFactoryDeployer() public {
        address governance = makeAddr("governance");
        DeepstateToken secondToken = new DeepstateToken(address(this), "Second", "SECOND");
        DeepstateV1 secondDeepstate = new DeepstateV1();
        DeepstateV1Controller secondDeepstateV1Controller =
            new DeepstateV1Controller(governance, address(secondDeepstate));
        DeepstateMinterController secondMinterController = _newMinterController(governance, secondToken);
        DeepstateRewarderFactory secondFactory = new DeepstateRewarderFactory(
            governance, address(secondDeepstateV1Controller), address(secondMinterController)
        );
        secondDeepstate.transferOwnership(address(secondDeepstateV1Controller));

        vm.expectRevert(Ownable.Unauthorized.selector);
        secondFactory.setOperator(operator);

        vm.startPrank(governance);
        secondMinterController.grantRoles(address(secondFactory), secondMinterController.MINTER_ROLE());
        secondDeepstateV1Controller.grantRoles(address(secondFactory), secondDeepstateV1Controller.HOOK_MANAGER_ROLE());
        secondFactory.setOperator(operator);
        vm.stopPrank();
        vm.prank(operator);
        DeepstateRewarderV2 rewarder = secondFactory.deployMarket(_market(TOKEN_A, TOKEN_B));

        assertEq(secondFactory.owner(), governance);
        assertEq(rewarder.owner(), address(secondFactory));
        assertEq(secondToken.balanceOf(address(rewarder)), 100_000_000e18);
        assertEq(secondToken.balanceOf(address(sablier)), _vestingAllocation(100_000_000e18));
    }

    function test_OperatorDeploysMarketWithFixedScheduleAndFunding() public {
        DeepstateRewarderFactory.MarketConfig memory config = _market(TOKEN_A, TOKEN_B);
        bytes32 poolId = _poolId(TOKEN_A, TOKEN_B);

        vm.expectEmit(true, false, false, true, address(factory));
        emit DeepstateRewarderFactory.MarketDeployed(poolId, address(0), TOKEN_A, TOKEN_B, true, true);
        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(config);

        assertGt(address(rewarder).code.length, 0);
        assertEq(rewarder.owner(), address(factory));
        assertEq(rewarder.deepstate(), address(deepstate));
        assertEq(rewarder.rewardToken(), address(deep));
        assertEq(rewarder.poolId(), poolId);
        assertEq(rewarder.token0(), TOKEN_A);
        assertEq(rewarder.token1(), TOKEN_B);
        assertEq(rewarder.sideEmissionCap(), 500_000_000e18);
        assertEq(rewarder.emissionDuration(), 395 days);
        assertEq(rewarder.token0StartQuantity(), 1e18);
        assertEq(rewarder.token0MaxQuantity(), 5_000e18);
        assertEq(rewarder.token1StartQuantity(), 1e6);
        assertEq(rewarder.token1MaxQuantity(), 1_000_000e6);
        assertEq(deep.balanceOf(address(rewarder)), 100_000_000e18);
        assertEq(deep.balanceOf(address(sablier)), _vestingAllocation(100_000_000e18));
        assertEq(deep.totalSupply(), 100_000_000e18 + _vestingAllocation(100_000_000e18));
        assertEq(deepstate.poolHook(poolId), address(rewarder));
        assertEq(factory.activeRewarder(poolId), address(rewarder));
        assertEq(factory.rewarderPool(address(rewarder)), poolId);
        assertEq(factory.nextDeploymentAt(), block.timestamp + 3 days);
    }

    function test_DeploymentCooldownIsGlobalAndAllowsExactBoundary() public {
        vm.prank(operator);
        factory.deployMarket(_market(TOKEN_A, TOKEN_B));

        uint256 next = factory.nextDeploymentAt();
        vm.expectRevert(abi.encodeWithSelector(DeepstateRewarderFactory.DeploymentCooldown.selector, next));
        vm.prank(operator);
        factory.deployMarket(_market(TOKEN_C, TOKEN_D));

        vm.warp(next - 1);
        vm.expectRevert(abi.encodeWithSelector(DeepstateRewarderFactory.DeploymentCooldown.selector, next));
        vm.prank(operator);
        factory.deployMarket(_market(TOKEN_C, TOKEN_D));

        vm.warp(next);
        vm.prank(operator);
        DeepstateRewarderV2 second = factory.deployMarket(_market(TOKEN_C, TOKEN_D));

        assertEq(deep.balanceOf(address(second)), 100_000_000e18);
        assertEq(deep.balanceOf(address(sablier)), 2 * _vestingAllocation(100_000_000e18));
        assertEq(deep.totalSupply(), 200_000_000e18 + 2 * _vestingAllocation(100_000_000e18));
    }

    function test_GovernanceCanDeployWithoutOperatorButStillObeysCooldown() public {
        factory.setOperator(address(0));
        DeepstateRewarderV2 rewarder = factory.deployMarket(_market(TOKEN_A, TOKEN_B));
        assertEq(rewarder.owner(), address(factory));

        uint256 next = factory.nextDeploymentAt();
        vm.expectRevert(abi.encodeWithSelector(DeepstateRewarderFactory.DeploymentCooldown.selector, next));
        factory.deployMarket(_market(TOKEN_C, TOKEN_D));
    }

    function test_GovernanceCanRevokeOperatorImmediately() public {
        vm.expectEmit(true, true, false, false, address(factory));
        emit DeepstateRewarderFactory.OperatorSet(operator, address(0));
        factory.setOperator(address(0));

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(operator);
        factory.deployMarket(_market(TOKEN_A, TOKEN_B));

        assertEq(factory.operator(), address(0));
        assertEq(deep.totalSupply(), 0);
    }

    function test_OnlyGovernanceCanSetOperator() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(operator);
        factory.setOperator(alice);

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(alice);
        factory.setOperator(alice);

        assertEq(factory.operator(), operator);
    }

    function test_OperatorCanRemoveMarketAndBurnAllRemainingFunding() public {
        DeepstateRewarderFactory.MarketConfig memory config = _market(TOKEN_A, TOKEN_B);
        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(config);
        bytes32 poolId = _poolId(TOKEN_A, TOKEN_B);

        vm.expectEmit(false, false, false, true, address(rewarder));
        emit DeepstateRewarderV2.RewardBalanceBurned(100_000_000e18);
        vm.expectEmit(true, true, false, false, address(factory));
        emit DeepstateRewarderFactory.MarketRemoved(poolId, address(rewarder));
        vm.prank(operator);
        factory.removeMarket(TOKEN_A, TOKEN_B);

        assertEq(deepstate.poolHook(poolId), address(0));
        assertEq(factory.activeRewarder(poolId), address(0));
        assertEq(factory.rewarderPool(address(rewarder)), bytes32(0));
        assertEq(deep.balanceOf(address(rewarder)), 0);
        assertEq(deep.balanceOf(address(factory)), 0);
        assertEq(deep.balanceOf(address(sablier)), _vestingAllocation(100_000_000e18));
        assertEq(deep.totalSupply(), _vestingAllocation(100_000_000e18));
    }

    function test_RemovalBurnsLiveBalanceAfterPriorClaim() public {
        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(_market(TOKEN_A, TOKEN_B));
        uint256 claimed = 25_000_000e18;

        vm.prank(address(rewarder));
        deep.transfer(alice, claimed);

        vm.prank(operator);
        factory.removeMarket(TOKEN_A, TOKEN_B);

        assertEq(deep.balanceOf(address(rewarder)), 0);
        assertEq(deep.balanceOf(alice), claimed);
        assertEq(deep.balanceOf(address(sablier)), _vestingAllocation(100_000_000e18));
        assertEq(deep.totalSupply(), claimed + _vestingAllocation(100_000_000e18));
    }

    function test_OperatorCannotBurnRewarderDirectly() public {
        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(_market(TOKEN_A, TOKEN_B));

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(operator);
        rewarder.burnBalance();

        assertEq(deep.balanceOf(address(rewarder)), 100_000_000e18);
        assertEq(deep.balanceOf(operator), 0);
    }

    function test_RemovalBurnsGovernanceTopUpAlongWithInitialFunding() public {
        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(_market(TOKEN_A, TOKEN_B));

        minterController.mint(address(rewarder), 900_000_000e18);
        assertEq(deep.balanceOf(address(rewarder)), 1_000_000_000e18);
        uint256 vested = _vestingAllocation(100_000_000e18) + _vestingAllocation(900_000_000e18);
        assertEq(deep.balanceOf(address(sablier)), vested);

        vm.prank(operator);
        factory.removeMarket(TOKEN_A, TOKEN_B);

        assertEq(deep.totalSupply(), vested);
    }

    function test_GovernanceCanRemoveMarketAfterRevokingOperator() public {
        vm.prank(operator);
        factory.deployMarket(_market(TOKEN_A, TOKEN_B));
        factory.setOperator(address(0));

        factory.removeMarket(TOKEN_A, TOKEN_B);

        assertEq(deep.totalSupply(), _vestingAllocation(100_000_000e18));
    }

    function test_RemovedPoolCanBeResetWithFreshAddressAfterCooldown() public {
        DeepstateRewarderFactory.MarketConfig memory config = _market(TOKEN_A, TOKEN_B);
        vm.startPrank(operator);
        DeepstateRewarderV2 first = factory.deployMarket(config);
        factory.removeMarket(TOKEN_A, TOKEN_B);

        uint256 next = factory.nextDeploymentAt();
        vm.expectRevert(abi.encodeWithSelector(DeepstateRewarderFactory.DeploymentCooldown.selector, next));
        factory.deployMarket(config);

        vm.warp(next);
        DeepstateRewarderV2 second = factory.deployMarket(config);
        vm.stopPrank();

        assertNotEq(address(first), address(second));
        assertEq(factory.activeRewarder(_poolId(TOKEN_A, TOKEN_B)), address(second));
        assertEq(deep.balanceOf(address(second)), 100_000_000e18);
        assertEq(deep.balanceOf(address(sablier)), 2 * _vestingAllocation(100_000_000e18));
        assertEq(deep.totalSupply(), 100_000_000e18 + 2 * _vestingAllocation(100_000_000e18));
    }

    function test_CannotDeployOverActiveFactoryMarketOrExistingDeepstateV1Hook() public {
        DeepstateRewarderFactory.MarketConfig memory config = _market(TOKEN_A, TOKEN_B);
        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(config);
        vm.warp(factory.nextDeploymentAt());

        bytes32 poolId = _poolId(TOKEN_A, TOKEN_B);
        vm.expectRevert(
            abi.encodeWithSelector(DeepstateRewarderFactory.ActiveMarketExists.selector, poolId, address(rewarder))
        );
        vm.prank(operator);
        factory.deployMarket(config);

        DeepstateV1 secondDeepstate = new DeepstateV1();
        DeepstateV1Controller secondDeepstateV1Controller =
            new DeepstateV1Controller(address(this), address(secondDeepstate));
        DeepstateRewarderFactory secondFactory = new DeepstateRewarderFactory(
            address(this), address(secondDeepstateV1Controller), address(minterController)
        );
        secondDeepstate.setPoolHookConfig(TOKEN_C, TOKEN_D, alice, true, false);
        secondDeepstate.transferOwnership(address(secondDeepstateV1Controller));
        minterController.grantRoles(address(secondFactory), minterController.MINTER_ROLE());
        secondDeepstateV1Controller.grantRoles(address(secondFactory), secondDeepstateV1Controller.HOOK_MANAGER_ROLE());
        secondFactory.setOperator(operator);

        bytes32 secondPoolId = _poolId(TOKEN_C, TOKEN_D);
        vm.expectRevert(abi.encodeWithSelector(DeepstateRewarderFactory.ExistingPoolHook.selector, secondPoolId, alice));
        vm.prank(operator);
        secondFactory.deployMarket(_market(TOKEN_C, TOKEN_D));

        assertEq(deep.balanceOf(address(secondFactory)), 0);
    }

    function test_DeploymentWithoutMinterRoleRevertsAtomically() public {
        DeepstateToken secondToken = new DeepstateToken(address(this), "Second", "SECOND");
        DeepstateV1 secondDeepstate = new DeepstateV1();
        DeepstateV1Controller secondDeepstateV1Controller =
            new DeepstateV1Controller(address(this), address(secondDeepstate));
        DeepstateMinterController secondMinterController = _newMinterController(address(this), secondToken);
        DeepstateRewarderFactory secondFactory = new DeepstateRewarderFactory(
            address(this), address(secondDeepstateV1Controller), address(secondMinterController)
        );
        secondDeepstate.transferOwnership(address(secondDeepstateV1Controller));
        secondDeepstateV1Controller.grantRoles(address(secondFactory), secondDeepstateV1Controller.HOOK_MANAGER_ROLE());
        secondFactory.setOperator(operator);

        DeepstateRewarderFactory.MarketConfig memory config = _market(TOKEN_A, TOKEN_B);

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(operator);
        secondFactory.deployMarket(config);

        assertEq(secondFactory.nextDeploymentAt(), 0);
        assertEq(secondToken.totalSupply(), 0);
        assertEq(secondDeepstate.poolHook(_poolId(TOKEN_A, TOKEN_B)), address(0));
    }

    function test_DeploymentWithoutDeepstateV1OwnershipRevertsAtomically() public {
        DeepstateToken secondToken = new DeepstateToken(address(this), "Second", "SECOND");
        DeepstateV1 secondDeepstate = new DeepstateV1();
        DeepstateV1Controller secondDeepstateV1Controller =
            new DeepstateV1Controller(address(this), address(secondDeepstate));
        DeepstateMinterController secondMinterController = _newMinterController(address(this), secondToken);
        DeepstateRewarderFactory secondFactory = new DeepstateRewarderFactory(
            address(this), address(secondDeepstateV1Controller), address(secondMinterController)
        );
        secondMinterController.grantRoles(address(secondFactory), secondMinterController.MINTER_ROLE());
        secondDeepstateV1Controller.grantRoles(address(secondFactory), secondDeepstateV1Controller.HOOK_MANAGER_ROLE());
        secondFactory.setOperator(operator);

        DeepstateRewarderFactory.MarketConfig memory config = _market(TOKEN_A, TOKEN_B);

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(operator);
        secondFactory.deployMarket(config);

        assertEq(secondFactory.nextDeploymentAt(), 0);
        assertEq(secondToken.totalSupply(), 0);
    }

    function test_DeploymentWithoutDelegatedHookPermissionRevertsAtomically() public {
        DeepstateToken secondToken = new DeepstateToken(address(this), "Second", "SECOND");
        DeepstateV1 secondDeepstate = new DeepstateV1();
        DeepstateV1Controller secondDeepstateV1Controller =
            new DeepstateV1Controller(address(this), address(secondDeepstate));
        DeepstateMinterController secondMinterController = _newMinterController(address(this), secondToken);
        DeepstateRewarderFactory secondFactory = new DeepstateRewarderFactory(
            address(this), address(secondDeepstateV1Controller), address(secondMinterController)
        );
        secondMinterController.grantRoles(address(secondFactory), secondMinterController.MINTER_ROLE());
        secondDeepstate.transferOwnership(address(secondDeepstateV1Controller));
        secondFactory.setOperator(operator);

        DeepstateRewarderFactory.MarketConfig memory config = _market(TOKEN_A, TOKEN_B);

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(operator);
        secondFactory.deployMarket(config);

        assertEq(secondFactory.nextDeploymentAt(), 0);
        assertEq(secondToken.totalSupply(), 0);
        assertEq(secondDeepstate.poolHook(_poolId(TOKEN_A, TOKEN_B)), address(0));
    }

    function test_GovernanceCanCleanUpAfterRevokingFactoryHookPermission() public {
        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(_market(TOKEN_A, TOKEN_B));
        bytes32 poolId = _poolId(TOKEN_A, TOKEN_B);
        deepstateV1Controller.revokeRoles(address(factory), deepstateV1Controller.HOOK_MANAGER_ROLE());

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(operator);
        factory.removeMarket(TOKEN_A, TOKEN_B);
        assertEq(factory.activeRewarder(poolId), address(rewarder));
        assertEq(deep.balanceOf(address(rewarder)), 100_000_000e18);

        deepstateV1Controller.setPoolHookConfig(TOKEN_A, TOKEN_B, address(0), false, false);
        factory.removeMarket(TOKEN_A, TOKEN_B);

        assertEq(factory.activeRewarder(poolId), address(0));
        assertEq(deep.balanceOf(address(rewarder)), 0);
        assertEq(deep.totalSupply(), _vestingAllocation(100_000_000e18));
    }

    function test_RemovalRejectsUnexpectedReplacementHook() public {
        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(_market(TOKEN_A, TOKEN_B));
        bytes32 poolId = _poolId(TOKEN_A, TOKEN_B);
        deepstateV1Controller.setPoolHookConfig(TOKEN_A, TOKEN_B, alice, true, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateRewarderFactory.UnexpectedPoolHook.selector, poolId, address(rewarder), alice
            )
        );
        vm.prank(operator);
        factory.removeMarket(TOKEN_A, TOKEN_B);

        assertEq(deepstate.poolHook(poolId), alice);
        assertEq(factory.activeRewarder(poolId), address(rewarder));
        assertEq(deep.balanceOf(address(rewarder)), 100_000_000e18);
    }

    function test_InvalidMarketConfigurationRevertsBeforeDeployment() public {
        DeepstateRewarderFactory.MarketConfig memory config = _market(TOKEN_B, TOKEN_A);
        vm.expectRevert(DeepstateRewarderFactory.InvalidPool.selector);
        vm.prank(operator);
        factory.deployMarket(config);

        config = _market(TOKEN_A, TOKEN_B);
        config.token0Active = false;
        config.token1Active = false;
        vm.expectRevert(DeepstateRewarderFactory.InvalidHookFlags.selector);
        vm.prank(operator);
        factory.deployMarket(config);

        config = _market(TOKEN_A, TOKEN_B);
        config.token0StartQuantity = 0;
        vm.expectRevert(DeepstateRewarder.InvalidQuantitySchedule.selector);
        vm.prank(operator);
        factory.deployMarket(config);

        assertEq(factory.nextDeploymentAt(), 0);
        assertEq(deep.totalSupply(), 0);
    }

    function test_UnauthorizedAccountCannotDeployOrRemoveMarket() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(alice);
        factory.deployMarket(_market(TOKEN_A, TOKEN_B));

        vm.prank(operator);
        factory.deployMarket(_market(TOKEN_A, TOKEN_B));

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(alice);
        factory.removeMarket(TOKEN_A, TOKEN_B);
    }

    function test_RemoveUnknownOrUnsortedMarketReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(DeepstateRewarderFactory.MarketNotActive.selector, _poolId(TOKEN_A, TOKEN_B))
        );
        vm.prank(operator);
        factory.removeMarket(TOKEN_A, TOKEN_B);

        vm.expectRevert(DeepstateRewarderFactory.InvalidPool.selector);
        vm.prank(operator);
        factory.removeMarket(TOKEN_B, TOKEN_A);
    }

    function _market(address token0, address token1)
        internal
        pure
        returns (DeepstateRewarderFactory.MarketConfig memory config)
    {
        config = DeepstateRewarderFactory.MarketConfig({
            token0: token0,
            token1: token1,
            token0StartQuantity: 1e18,
            token0MaxQuantity: 5_000e18,
            token1StartQuantity: 1e6,
            token1MaxQuantity: 1_000_000e6,
            token0Active: true,
            token1Active: true
        });
    }

    function _poolId(address token0, address token1) internal pure returns (bytes32) {
        return keccak256(abi.encode(token0, token1));
    }

    function _vestingAllocation(uint256 primaryAmount) internal pure returns (uint256) {
        return Math.mulDiv(primaryAmount, 30_00, 70_00);
    }

    function _newMinterController(address admin, DeepstateToken token)
        internal
        returns (DeepstateMinterController controller_)
    {
        controller_ = new DeepstateMinterController(
            admin, address(token), address(sablier), vestingRecipient, 20_000_000_000e18
        );
        token.grantRole(token.MINTER_ROLE(), address(controller_));
    }
}
