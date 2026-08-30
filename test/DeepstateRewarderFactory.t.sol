// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
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

    constructor(address deepstateToken_) {
        _deepstateToken = deepstateToken_;
    }

    function hasRole(bytes32, address) external pure returns (bool) {
        return true;
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
    DeepstateV1Controller internal routerController;
    DeepstateMinterController internal minterController;
    DeepstateRewarderFactory internal factory;
    MockSablierLockupLinearV4 internal sablier;

    address internal controller = makeAddr("controller");
    address internal alice = makeAddr("alice");
    address internal vestingRecipient = makeAddr("vestingRecipient");

    function setUp() public {
        vm.warp(1_000_000);

        deep = new DeepstateToken(address(this), "Deepstate", "DEEP");
        sablier = new MockSablierLockupLinearV4();
        deepstate = new DeepstateV1();
        routerController = new DeepstateV1Controller(address(this), address(deepstate));
        minterController = _newMinterController(address(this), deep);
        factory = new DeepstateRewarderFactory(address(this), address(routerController), address(minterController));

        minterController.grantRole(minterController.MINTER_ROLE(), address(factory));
        deepstate.transferOwnership(address(routerController));
        routerController.setHookManager(address(factory));
        factory.setController(controller);
    }

    function test_ImmutableConfigurationAndInitialAuthority() public view {
        assertEq(factory.owner(), address(this));
        assertEq(factory.controller(), controller);
        assertEq(address(factory.routerController()), address(routerController));
        assertEq(address(factory.deepstate()), address(deepstate));
        assertEq(address(factory.minterController()), address(minterController));
        assertEq(address(factory.rewardToken()), address(deep));
        assertEq(factory.DEPLOYMENT_COOLDOWN(), 3 days);
        assertEq(factory.EMISSION_DURATION(), 395 days);
        assertEq(factory.SIDE_EMISSION_CAP(), 500_000_000e18);
        assertEq(factory.INITIAL_FUNDING(), 100_000_000e18);
        assertTrue(deep.hasRole(deep.MINTER_ROLE(), address(minterController)));
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), address(factory)));
        assertTrue(minterController.hasRole(minterController.MINTER_ROLE(), address(factory)));
        assertEq(deepstate.owner(), address(routerController));
        assertEq(routerController.hookManager(), address(factory));
        assertEq(factory.nextDeploymentAt(), 0);
        assertEq(factory.deploymentCount(), 0);
    }

    function test_ConstructorValidation() public {
        vm.expectRevert(DeepstateRewarderFactory.InvalidOwner.selector);
        new DeepstateRewarderFactory(address(0), address(routerController), address(minterController));

        vm.expectRevert(DeepstateRewarderFactory.InvalidRouterController.selector);
        new DeepstateRewarderFactory(address(this), address(0), address(minterController));

        vm.expectRevert(DeepstateRewarderFactory.InvalidRouterController.selector);
        new DeepstateRewarderFactory(address(this), alice, address(minterController));

        DeepstateV1Controller mismatchedController = new DeepstateV1Controller(alice, address(deepstate));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateRewarderFactory.RouterControllerOwnerMismatch.selector, address(this), alice
            )
        );
        new DeepstateRewarderFactory(address(this), address(mismatchedController), address(minterController));

        vm.expectRevert(DeepstateRewarderFactory.InvalidMinterController.selector);
        new DeepstateRewarderFactory(address(this), address(routerController), address(0));

        vm.expectRevert(DeepstateRewarderFactory.InvalidMinterController.selector);
        new DeepstateRewarderFactory(address(this), address(routerController), alice);

        DeepstateMinterController mismatchedMinter = _newMinterController(alice, deep);
        vm.expectRevert(
            abi.encodeWithSelector(DeepstateRewarderFactory.MinterControllerAdminMismatch.selector, address(this))
        );
        new DeepstateRewarderFactory(address(this), address(routerController), address(mismatchedMinter));

        InvalidRewardTokenMinterController zeroTokenController = new InvalidRewardTokenMinterController(address(0));
        vm.expectRevert(DeepstateRewarderFactory.InvalidRewardToken.selector);
        new DeepstateRewarderFactory(address(this), address(routerController), address(zeroTokenController));

        InvalidRewardTokenMinterController eoaTokenController = new InvalidRewardTokenMinterController(alice);
        vm.expectRevert(DeepstateRewarderFactory.InvalidRewardToken.selector);
        new DeepstateRewarderFactory(address(this), address(routerController), address(eoaTokenController));
    }

    function test_GovernanceOwnerIsIndependentFromFactoryDeployer() public {
        address governance = makeAddr("governance");
        DeepstateToken secondToken = new DeepstateToken(address(this), "Second", "SECOND");
        DeepstateV1 secondRouter = new DeepstateV1();
        DeepstateV1Controller secondRouterController = new DeepstateV1Controller(governance, address(secondRouter));
        DeepstateMinterController secondMinterController = _newMinterController(governance, secondToken);
        DeepstateRewarderFactory secondFactory =
            new DeepstateRewarderFactory(governance, address(secondRouterController), address(secondMinterController));
        secondRouter.transferOwnership(address(secondRouterController));

        vm.expectRevert(Ownable.Unauthorized.selector);
        secondFactory.setController(controller);

        vm.startPrank(governance);
        secondMinterController.grantRole(secondMinterController.MINTER_ROLE(), address(secondFactory));
        secondRouterController.setHookManager(address(secondFactory));
        secondFactory.setController(controller);
        vm.stopPrank();
        vm.prank(controller);
        DeepstateRewarderV2 rewarder = secondFactory.deployMarket(_market(TOKEN_A, TOKEN_B));

        assertEq(secondFactory.owner(), governance);
        assertEq(rewarder.owner(), address(secondFactory));
        assertEq(secondToken.balanceOf(address(rewarder)), 100_000_000e18);
        assertEq(secondToken.balanceOf(address(sablier)), _vestingAllocation(100_000_000e18));
    }

    function test_ControllerDeploysPredictedCreate2MarketWithFixedScheduleAndFunding() public {
        DeepstateRewarderFactory.MarketConfig memory config = _market(TOKEN_A, TOKEN_B);
        address predicted = factory.predictRewarderAddress(config, 0);
        bytes32 poolId = _poolId(TOKEN_A, TOKEN_B);
        bytes32 expectedSalt = keccak256(abi.encode(poolId, uint256(0)));

        vm.expectEmit(true, true, true, true, address(factory));
        emit DeepstateRewarderFactory.MarketDeployed(poolId, 0, predicted, expectedSalt, TOKEN_A, TOKEN_B, true, true);
        vm.prank(controller);
        DeepstateRewarderV2 rewarder = factory.deployMarket(config);

        assertEq(address(rewarder), predicted);
        assertGt(predicted.code.length, 0);
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
        assertEq(factory.deploymentCount(), 1);
        assertEq(factory.nextDeploymentAt(), block.timestamp + 3 days);
        assertEq(factory.marketSalt(poolId, 0), expectedSalt);
    }

    function test_DeploymentCooldownIsGlobalAndAllowsExactBoundary() public {
        vm.prank(controller);
        factory.deployMarket(_market(TOKEN_A, TOKEN_B));

        uint256 next = factory.nextDeploymentAt();
        vm.expectRevert(abi.encodeWithSelector(DeepstateRewarderFactory.DeploymentCooldown.selector, next));
        vm.prank(controller);
        factory.deployMarket(_market(TOKEN_C, TOKEN_D));

        vm.warp(next - 1);
        vm.expectRevert(abi.encodeWithSelector(DeepstateRewarderFactory.DeploymentCooldown.selector, next));
        vm.prank(controller);
        factory.deployMarket(_market(TOKEN_C, TOKEN_D));

        vm.warp(next);
        vm.prank(controller);
        DeepstateRewarderV2 second = factory.deployMarket(_market(TOKEN_C, TOKEN_D));

        assertEq(factory.deploymentCount(), 2);
        assertEq(deep.balanceOf(address(second)), 100_000_000e18);
        assertEq(deep.balanceOf(address(sablier)), 2 * _vestingAllocation(100_000_000e18));
        assertEq(deep.totalSupply(), 200_000_000e18 + 2 * _vestingAllocation(100_000_000e18));
    }

    function test_GovernanceCanDeployWithoutControllerButStillObeysCooldown() public {
        factory.setController(address(0));
        DeepstateRewarderV2 rewarder = factory.deployMarket(_market(TOKEN_A, TOKEN_B));
        assertEq(rewarder.owner(), address(factory));

        uint256 next = factory.nextDeploymentAt();
        vm.expectRevert(abi.encodeWithSelector(DeepstateRewarderFactory.DeploymentCooldown.selector, next));
        factory.deployMarket(_market(TOKEN_C, TOKEN_D));
    }

    function test_GovernanceCanRevokeControllerImmediately() public {
        vm.expectEmit(true, true, false, false, address(factory));
        emit DeepstateRewarderFactory.ControllerSet(controller, address(0));
        factory.setController(address(0));

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(controller);
        factory.deployMarket(_market(TOKEN_A, TOKEN_B));

        assertEq(factory.controller(), address(0));
        assertEq(factory.deploymentCount(), 0);
        assertEq(deep.totalSupply(), 0);
    }

    function test_OnlyGovernanceCanSetController() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(controller);
        factory.setController(alice);

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(alice);
        factory.setController(alice);

        assertEq(factory.controller(), controller);
    }

    function test_ControllerCanRemoveMarketAndBurnAllRemainingFunding() public {
        DeepstateRewarderFactory.MarketConfig memory config = _market(TOKEN_A, TOKEN_B);
        vm.prank(controller);
        DeepstateRewarderV2 rewarder = factory.deployMarket(config);
        bytes32 poolId = _poolId(TOKEN_A, TOKEN_B);

        vm.expectEmit(true, true, false, true, address(factory));
        emit DeepstateRewarderFactory.MarketRemoved(poolId, address(rewarder), 100_000_000e18);
        vm.prank(controller);
        uint256 burned = factory.removeMarket(TOKEN_A, TOKEN_B);

        assertEq(burned, 100_000_000e18);
        assertEq(deepstate.poolHook(poolId), address(0));
        assertEq(factory.activeRewarder(poolId), address(0));
        assertEq(factory.rewarderPool(address(rewarder)), bytes32(0));
        assertEq(deep.balanceOf(address(rewarder)), 0);
        assertEq(deep.balanceOf(address(factory)), 0);
        assertEq(deep.balanceOf(address(sablier)), _vestingAllocation(100_000_000e18));
        assertEq(deep.totalSupply(), _vestingAllocation(100_000_000e18));
    }

    function test_RemovalBurnsLiveBalanceAfterPriorClaim() public {
        vm.prank(controller);
        DeepstateRewarderV2 rewarder = factory.deployMarket(_market(TOKEN_A, TOKEN_B));
        uint256 claimed = 25_000_000e18;

        vm.prank(address(rewarder));
        deep.transfer(alice, claimed);

        vm.prank(controller);
        uint256 burned = factory.removeMarket(TOKEN_A, TOKEN_B);

        assertEq(burned, 75_000_000e18);
        assertEq(deep.balanceOf(address(rewarder)), 0);
        assertEq(deep.balanceOf(alice), claimed);
        assertEq(deep.balanceOf(address(sablier)), _vestingAllocation(100_000_000e18));
        assertEq(deep.totalSupply(), claimed + _vestingAllocation(100_000_000e18));
    }

    function test_ControllerCannotBurnRewarderDirectly() public {
        vm.prank(controller);
        DeepstateRewarderV2 rewarder = factory.deployMarket(_market(TOKEN_A, TOKEN_B));

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(controller);
        rewarder.burnBalance();

        assertEq(deep.balanceOf(address(rewarder)), 100_000_000e18);
        assertEq(deep.balanceOf(controller), 0);
    }

    function test_RemovalBurnsGovernanceTopUpAlongWithInitialFunding() public {
        vm.prank(controller);
        DeepstateRewarderV2 rewarder = factory.deployMarket(_market(TOKEN_A, TOKEN_B));

        minterController.grantRole(minterController.MINTER_ROLE(), address(this));
        minterController.mint(address(rewarder), 900_000_000e18);
        minterController.revokeRole(minterController.MINTER_ROLE(), address(this));
        assertEq(deep.balanceOf(address(rewarder)), 1_000_000_000e18);
        uint256 vested = _vestingAllocation(100_000_000e18) + _vestingAllocation(900_000_000e18);
        assertEq(deep.balanceOf(address(sablier)), vested);

        vm.prank(controller);
        uint256 burned = factory.removeMarket(TOKEN_A, TOKEN_B);

        assertEq(burned, 1_000_000_000e18);
        assertEq(deep.totalSupply(), vested);
    }

    function test_GovernanceCanRemoveMarketAfterRevokingController() public {
        vm.prank(controller);
        factory.deployMarket(_market(TOKEN_A, TOKEN_B));
        factory.setController(address(0));

        uint256 burned = factory.removeMarket(TOKEN_A, TOKEN_B);

        assertEq(burned, 100_000_000e18);
        assertEq(deep.totalSupply(), _vestingAllocation(100_000_000e18));
    }

    function test_RemovedPoolCanBeResetWithFreshCreate2AddressAfterCooldown() public {
        DeepstateRewarderFactory.MarketConfig memory config = _market(TOKEN_A, TOKEN_B);
        vm.startPrank(controller);
        DeepstateRewarderV2 first = factory.deployMarket(config);
        factory.removeMarket(TOKEN_A, TOKEN_B);

        uint256 next = factory.nextDeploymentAt();
        vm.expectRevert(abi.encodeWithSelector(DeepstateRewarderFactory.DeploymentCooldown.selector, next));
        factory.deployMarket(config);

        vm.warp(next);
        address predicted = factory.predictRewarderAddress(config, 1);
        DeepstateRewarderV2 second = factory.deployMarket(config);
        vm.stopPrank();

        assertNotEq(address(first), address(second));
        assertEq(address(second), predicted);
        assertEq(factory.activeRewarder(_poolId(TOKEN_A, TOKEN_B)), address(second));
        assertEq(deep.balanceOf(address(second)), 100_000_000e18);
        assertEq(deep.balanceOf(address(sablier)), 2 * _vestingAllocation(100_000_000e18));
        assertEq(deep.totalSupply(), 100_000_000e18 + 2 * _vestingAllocation(100_000_000e18));
    }

    function test_CannotDeployOverActiveFactoryMarketOrExistingRouterHook() public {
        DeepstateRewarderFactory.MarketConfig memory config = _market(TOKEN_A, TOKEN_B);
        vm.prank(controller);
        DeepstateRewarderV2 rewarder = factory.deployMarket(config);
        vm.warp(factory.nextDeploymentAt());

        bytes32 poolId = _poolId(TOKEN_A, TOKEN_B);
        vm.expectRevert(
            abi.encodeWithSelector(DeepstateRewarderFactory.ActiveMarketExists.selector, poolId, address(rewarder))
        );
        vm.prank(controller);
        factory.deployMarket(config);

        DeepstateV1 secondRouter = new DeepstateV1();
        DeepstateV1Controller secondRouterController = new DeepstateV1Controller(address(this), address(secondRouter));
        DeepstateRewarderFactory secondFactory =
            new DeepstateRewarderFactory(address(this), address(secondRouterController), address(minterController));
        secondRouter.setPoolHookConfig(TOKEN_C, TOKEN_D, alice, true, false);
        secondRouter.transferOwnership(address(secondRouterController));
        minterController.grantRole(minterController.MINTER_ROLE(), address(secondFactory));
        secondRouterController.setHookManager(address(secondFactory));
        secondFactory.setController(controller);

        bytes32 secondPoolId = _poolId(TOKEN_C, TOKEN_D);
        vm.expectRevert(abi.encodeWithSelector(DeepstateRewarderFactory.ExistingPoolHook.selector, secondPoolId, alice));
        vm.prank(controller);
        secondFactory.deployMarket(_market(TOKEN_C, TOKEN_D));

        assertEq(secondFactory.deploymentCount(), 0);
        assertEq(deep.balanceOf(address(secondFactory)), 0);
    }

    function test_DeploymentWithoutMinterRoleRevertsAtomically() public {
        DeepstateToken secondToken = new DeepstateToken(address(this), "Second", "SECOND");
        DeepstateV1 secondRouter = new DeepstateV1();
        DeepstateV1Controller secondRouterController = new DeepstateV1Controller(address(this), address(secondRouter));
        DeepstateMinterController secondMinterController = _newMinterController(address(this), secondToken);
        DeepstateRewarderFactory secondFactory = new DeepstateRewarderFactory(
            address(this), address(secondRouterController), address(secondMinterController)
        );
        secondRouter.transferOwnership(address(secondRouterController));
        secondRouterController.setHookManager(address(secondFactory));
        secondFactory.setController(controller);

        DeepstateRewarderFactory.MarketConfig memory config = _market(TOKEN_A, TOKEN_B);
        address predicted = secondFactory.predictRewarderAddress(config, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(secondFactory),
                secondMinterController.MINTER_ROLE()
            )
        );
        vm.prank(controller);
        secondFactory.deployMarket(config);

        assertEq(predicted.code.length, 0);
        assertEq(secondFactory.deploymentCount(), 0);
        assertEq(secondFactory.nextDeploymentAt(), 0);
        assertEq(secondToken.totalSupply(), 0);
        assertEq(secondRouter.poolHook(_poolId(TOKEN_A, TOKEN_B)), address(0));
    }

    function test_DeploymentWithoutRouterOwnershipRevertsAtomically() public {
        DeepstateToken secondToken = new DeepstateToken(address(this), "Second", "SECOND");
        DeepstateV1 secondRouter = new DeepstateV1();
        DeepstateV1Controller secondRouterController = new DeepstateV1Controller(address(this), address(secondRouter));
        DeepstateMinterController secondMinterController = _newMinterController(address(this), secondToken);
        DeepstateRewarderFactory secondFactory = new DeepstateRewarderFactory(
            address(this), address(secondRouterController), address(secondMinterController)
        );
        secondMinterController.grantRole(secondMinterController.MINTER_ROLE(), address(secondFactory));
        secondRouterController.setHookManager(address(secondFactory));
        secondFactory.setController(controller);

        DeepstateRewarderFactory.MarketConfig memory config = _market(TOKEN_A, TOKEN_B);
        address predicted = secondFactory.predictRewarderAddress(config, 0);

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(controller);
        secondFactory.deployMarket(config);

        assertEq(predicted.code.length, 0);
        assertEq(secondFactory.deploymentCount(), 0);
        assertEq(secondToken.totalSupply(), 0);
    }

    function test_DeploymentWithoutDelegatedHookPermissionRevertsAtomically() public {
        DeepstateToken secondToken = new DeepstateToken(address(this), "Second", "SECOND");
        DeepstateV1 secondRouter = new DeepstateV1();
        DeepstateV1Controller secondRouterController = new DeepstateV1Controller(address(this), address(secondRouter));
        DeepstateMinterController secondMinterController = _newMinterController(address(this), secondToken);
        DeepstateRewarderFactory secondFactory = new DeepstateRewarderFactory(
            address(this), address(secondRouterController), address(secondMinterController)
        );
        secondMinterController.grantRole(secondMinterController.MINTER_ROLE(), address(secondFactory));
        secondRouter.transferOwnership(address(secondRouterController));
        secondFactory.setController(controller);

        DeepstateRewarderFactory.MarketConfig memory config = _market(TOKEN_A, TOKEN_B);
        address predicted = secondFactory.predictRewarderAddress(config, 0);

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(controller);
        secondFactory.deployMarket(config);

        assertEq(predicted.code.length, 0);
        assertEq(secondFactory.deploymentCount(), 0);
        assertEq(secondToken.totalSupply(), 0);
        assertEq(secondRouter.poolHook(_poolId(TOKEN_A, TOKEN_B)), address(0));
    }

    function test_GovernanceCanCleanUpAfterRevokingFactoryHookPermission() public {
        vm.prank(controller);
        DeepstateRewarderV2 rewarder = factory.deployMarket(_market(TOKEN_A, TOKEN_B));
        bytes32 poolId = _poolId(TOKEN_A, TOKEN_B);
        routerController.setHookManager(address(0));

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(controller);
        factory.removeMarket(TOKEN_A, TOKEN_B);
        assertEq(factory.activeRewarder(poolId), address(rewarder));
        assertEq(deep.balanceOf(address(rewarder)), 100_000_000e18);

        routerController.setPoolHookConfig(TOKEN_A, TOKEN_B, address(0), false, false);
        uint256 burned = factory.removeMarket(TOKEN_A, TOKEN_B);

        assertEq(burned, 100_000_000e18);
        assertEq(factory.activeRewarder(poolId), address(0));
        assertEq(deep.balanceOf(address(rewarder)), 0);
        assertEq(deep.totalSupply(), _vestingAllocation(100_000_000e18));
    }

    function test_RemovalRejectsUnexpectedReplacementHook() public {
        vm.prank(controller);
        DeepstateRewarderV2 rewarder = factory.deployMarket(_market(TOKEN_A, TOKEN_B));
        bytes32 poolId = _poolId(TOKEN_A, TOKEN_B);
        routerController.setPoolHookConfig(TOKEN_A, TOKEN_B, alice, true, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateRewarderFactory.UnexpectedPoolHook.selector, poolId, address(rewarder), alice
            )
        );
        vm.prank(controller);
        factory.removeMarket(TOKEN_A, TOKEN_B);

        assertEq(deepstate.poolHook(poolId), alice);
        assertEq(factory.activeRewarder(poolId), address(rewarder));
        assertEq(deep.balanceOf(address(rewarder)), 100_000_000e18);
    }

    function test_InvalidMarketConfigurationRevertsBeforeDeployment() public {
        DeepstateRewarderFactory.MarketConfig memory config = _market(TOKEN_B, TOKEN_A);
        vm.expectRevert(DeepstateRewarderFactory.InvalidPool.selector);
        vm.prank(controller);
        factory.deployMarket(config);

        config = _market(TOKEN_A, TOKEN_B);
        config.token0Active = false;
        config.token1Active = false;
        vm.expectRevert(DeepstateRewarderFactory.InvalidHookFlags.selector);
        vm.prank(controller);
        factory.deployMarket(config);

        config = _market(TOKEN_A, TOKEN_B);
        config.token0StartQuantity = 0;
        vm.expectRevert(DeepstateRewarder.InvalidQuantitySchedule.selector);
        vm.prank(controller);
        factory.deployMarket(config);

        assertEq(factory.deploymentCount(), 0);
        assertEq(factory.nextDeploymentAt(), 0);
        assertEq(deep.totalSupply(), 0);
    }

    function test_UnauthorizedAccountCannotDeployOrRemoveMarket() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(alice);
        factory.deployMarket(_market(TOKEN_A, TOKEN_B));

        vm.prank(controller);
        factory.deployMarket(_market(TOKEN_A, TOKEN_B));

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(alice);
        factory.removeMarket(TOKEN_A, TOKEN_B);
    }

    function test_RemoveUnknownOrUnsortedMarketReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(DeepstateRewarderFactory.MarketNotActive.selector, _poolId(TOKEN_A, TOKEN_B))
        );
        vm.prank(controller);
        factory.removeMarket(TOKEN_A, TOKEN_B);

        vm.expectRevert(DeepstateRewarderFactory.InvalidPool.selector);
        vm.prank(controller);
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
