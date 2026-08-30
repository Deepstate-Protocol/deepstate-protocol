// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SablierLockup} from "@sablier/lockup/src/SablierLockup.sol";

import {DeepstateMinterController} from "../src/DeepstateMinterController.sol";
import {DeepstateToken} from "../src/DeepstateToken.sol";

contract SablierComptrollerStub {
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    function calculateMinFeeWeiFor(uint8, address) external pure returns (uint256) {
        return 0;
    }
}

contract DeepstateMinterControllerSablierIntegrationTest is Test {
    uint256 internal constant MINT_CAP = 20_000_000_000e18;

    DeepstateToken internal deep;
    DeepstateMinterController internal minterController;
    SablierLockup internal sablier;

    address internal recipient = makeAddr("recipient");
    address internal mintRecipient = makeAddr("mintRecipient");

    function setUp() public {
        deep = new DeepstateToken(address(this), "Deepstate", "DEEP");
        SablierComptrollerStub comptroller = new SablierComptrollerStub();
        sablier = new SablierLockup(address(comptroller), address(0));
        minterController =
            new DeepstateMinterController(address(this), address(deep), address(sablier), recipient, MINT_CAP);

        deep.grantRole(deep.MINTER_ROLE(), address(minterController));
    }

    function test_RealSablierV4StreamVestsLinearlyForOneYear() public {
        uint40 startTime = uint40(block.timestamp);
        uint128 vestingAmount = 30e18;
        uint256 streamId = minterController.mint(mintRecipient, 70e18);

        assertEq(streamId, 1);
        assertEq(sablier.ownerOf(streamId), recipient);
        assertEq(sablier.getRecipient(streamId), recipient);
        assertEq(sablier.getSender(streamId), address(minterController));
        assertEq(address(sablier.getUnderlyingToken(streamId)), address(deep));
        assertEq(sablier.getDepositedAmount(streamId), vestingAmount);
        assertEq(sablier.getStartTime(streamId), startTime);
        assertEq(sablier.getEndTime(streamId), startTime + 365 days);
        assertEq(sablier.getCliffTime(streamId), 0);
        assertEq(sablier.getGranularity(streamId), 1);
        assertFalse(sablier.isCancelable(streamId));
        assertFalse(sablier.isTransferable(streamId));
        assertEq(sablier.streamedAmountOf(streamId), 0);
        assertEq(deep.balanceOf(address(sablier)), vestingAmount);

        vm.warp(startTime + 365 days / 2);
        assertEq(sablier.streamedAmountOf(streamId), vestingAmount / 2);
        vm.prank(recipient);
        uint128 firstWithdrawal = sablier.withdrawMax(streamId, recipient);
        assertEq(firstWithdrawal, vestingAmount / 2);
        assertEq(deep.balanceOf(recipient), vestingAmount / 2);

        vm.warp(startTime + 365 days);
        assertEq(sablier.streamedAmountOf(streamId), vestingAmount);
        vm.prank(recipient);
        uint128 finalWithdrawal = sablier.withdrawMax(streamId, recipient);
        assertEq(finalWithdrawal, vestingAmount / 2);
        assertEq(deep.balanceOf(recipient), vestingAmount);
        assertEq(deep.balanceOf(address(sablier)), 0);
        assertTrue(sablier.isDepleted(streamId));
    }

    function test_RealSablierV4StreamCannotBeCanceledOrTransferred() public {
        uint256 streamId = minterController.mint(mintRecipient, 70e18);

        vm.expectRevert();
        sablier.cancel(streamId);

        vm.expectRevert();
        vm.prank(recipient);
        sablier.transferFrom(recipient, mintRecipient, streamId);

        assertEq(sablier.ownerOf(streamId), recipient);
        assertEq(deep.balanceOf(address(sablier)), 30e18);
    }
}
