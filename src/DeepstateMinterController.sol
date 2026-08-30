// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Lockup} from "@sablier/lockup/src/types/Lockup.sol";
import {LockupLinear} from "@sablier/lockup/src/types/LockupLinear.sol";

import {DeepstateToken} from "./DeepstateToken.sol";
import {ISablierLockupLinearV4} from "./interfaces/ISablierLockupLinearV4.sol";

/// @title Deepstate Minter Controller
/// @notice Enforces an additional 30% recipient allocation on every authorized DEEP mint.
/// @dev The recipient allocation is placed in a new non-cancelable, non-transferable Sablier
/// Lockup v4 linear stream. This contract must be DEEP's only operational MINTER_ROLE holder.
contract DeepstateMinterController is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    uint256 public constant RECIPIENT_ALLOCATION_BPS = 3_000;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint40 public constant VESTING_DURATION = 365 days;

    DeepstateToken public immutable rewardToken;
    ISablierLockupLinearV4 public immutable sablierLockup;
    address public immutable recipient;

    event MintedWithVesting(
        address indexed caller,
        address indexed mintRecipient,
        uint256 mintAmount,
        address indexed vestingRecipient,
        uint256 vestingAmount,
        uint256 streamId
    );

    error InvalidAdmin();
    error InvalidRewardToken();
    error InvalidSablierLockup();
    error InvalidRecipient();
    error InvalidMintRecipient();
    error MintAmountTooSmall();
    error VestingAmountTooLarge(uint256 amount);
    error StreamFundingMismatch(uint256 expectedBalance, uint256 actualBalance);

    constructor(address admin_, address rewardToken_, address sablierLockup_, address recipient_) {
        if (admin_ == address(0)) revert InvalidAdmin();
        if (rewardToken_ == address(0) || rewardToken_.code.length == 0) revert InvalidRewardToken();
        if (sablierLockup_ == address(0) || sablierLockup_.code.length == 0) revert InvalidSablierLockup();
        if (recipient_ == address(0)) revert InvalidRecipient();

        rewardToken = DeepstateToken(rewardToken_);
        sablierLockup = ISablierLockupLinearV4(sablierLockup_);
        recipient = recipient_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    /// @notice Mint `amount` DEEP to `to` and an additional 30% into a one-year recipient stream.
    /// @dev The 30% calculation rounds down. Amounts that round the stream allocation to zero revert.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) nonReentrant returns (uint256 streamId) {
        if (to == address(0)) revert InvalidMintRecipient();

        uint256 vestingAmount = Math.mulDiv(amount, RECIPIENT_ALLOCATION_BPS, BPS_DENOMINATOR);
        if (vestingAmount == 0) revert MintAmountTooSmall();
        if (vestingAmount > type(uint128).max) revert VestingAmountTooLarge(vestingAmount);
        uint128 streamAmount = SafeCast.toUint128(vestingAmount);

        IERC20 token = IERC20(address(rewardToken));
        uint256 balanceBefore = token.balanceOf(address(this));

        rewardToken.mint(to, amount);
        rewardToken.mint(address(this), vestingAmount);

        token.forceApprove(address(sablierLockup), vestingAmount);
        streamId = sablierLockup.createWithDurationsLL(
            Lockup.CreateWithDurations({
                sender: address(this),
                recipient: recipient,
                depositAmount: streamAmount,
                token: token,
                cancelable: false,
                transferable: false,
                shape: "Deepstate allocation"
            }),
            LockupLinear.UnlockAmounts({start: 0, cliff: 0}),
            0,
            LockupLinear.Durations({cliff: 0, total: VESTING_DURATION})
        );
        token.forceApprove(address(sablierLockup), 0);

        uint256 balanceAfter = token.balanceOf(address(this));
        if (balanceAfter != balanceBefore) revert StreamFundingMismatch(balanceBefore, balanceAfter);

        emit MintedWithVesting(msg.sender, to, amount, recipient, vestingAmount, streamId);
    }
}
