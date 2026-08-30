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
import {Ownable} from "solady/auth/Ownable.sol";

import {DeepstateToken} from "./DeepstateToken.sol";
import {ISablierLockupLinearV4} from "./interfaces/ISablierLockupLinearV4.sol";

/// @title Deepstate Minter Controller
/// @notice Enforces an additional 30% recipient allocation on every authorized DEEP mint.
/// @dev The recipient allocation is placed in a new non-cancelable, non-transferable Sablier
/// Lockup v4 linear stream. This contract temporarily administers DEEP while remaining owned by governance.
contract DeepstateMinterController is AccessControl, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    uint256 public constant RECIPIENT_ALLOCATION_BPS = 30_00;
    uint256 public constant BPS_DENOMINATOR = 100_00;
    uint40 public constant VESTING_DURATION = 365 days;
    uint40 public constant TOKEN_ADMINISTRATION_DURATION = 2 * 365 days;

    DeepstateToken public immutable rewardToken;
    ISablierLockupLinearV4 public immutable sablierLockup;
    address public immutable recipient;
    /// @notice Maximum live DEEP supply this controller will permit after a mint.
    uint256 public immutable mintCap;

    /// @notice Timestamp after which anyone may return DEEP administration to this contract's owner.
    uint40 public tokenAdministrationEndsAt;
    /// @notice Whether DEEP administration has already been returned.
    bool public tokenAdministrationReturned;

    event MintedWithVesting(
        address indexed caller,
        address indexed mintRecipient,
        uint256 mintAmount,
        address indexed vestingRecipient,
        uint256 vestingAmount,
        uint256 streamId
    );
    event TokenAdministrationActivated(uint40 indexed endsAt);
    event TokenAdministrationReturned(address indexed owner, address indexed caller);

    error InvalidOwner();
    error InvalidRewardToken();
    error InvalidSablierLockup();
    error InvalidRecipient();
    error InvalidMintCap();
    error InvalidMintRecipient();
    error MintAmountTooSmall();
    error VestingAmountTooLarge(uint256 amount);
    error StreamFundingMismatch(uint256 expectedBalance, uint256 actualBalance);
    error ControllerNotTokenAdmin();
    error TokenAdministrationAlreadyActivated();
    error TokenAdministrationAlreadyReturned();
    error TokenAdministrationNotActive();
    error TokenAdministrationActive(uint40 endsAt);
    error OwnerMustRetainDefaultAdmin();
    error MintCapExceeded(uint256 cap, uint256 attemptedSupply);

    constructor(address owner_, address rewardToken_, address sablierLockup_, address recipient_, uint256 mintCap_) {
        if (owner_ == address(0)) revert InvalidOwner();
        if (rewardToken_ == address(0) || rewardToken_.code.length == 0) revert InvalidRewardToken();
        if (sablierLockup_ == address(0) || sablierLockup_.code.length == 0) revert InvalidSablierLockup();
        if (recipient_ == address(0)) revert InvalidRecipient();
        if (mintCap_ == 0) revert InvalidMintCap();

        rewardToken = DeepstateToken(rewardToken_);
        sablierLockup = ISablierLockupLinearV4(sablierLockup_);
        recipient = recipient_;
        mintCap = mintCap_;
        _initializeOwner(owner_);
        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
        _grantRole(MINTER_ROLE, owner_);
    }

    /// @notice Start the two-year DEEP administration term after this contract receives token admin authority.
    /// @dev Also ensures this controller holds DEEP's operational minter role.
    function activateTokenAdministration() external onlyOwner {
        if (tokenAdministrationEndsAt != 0) revert TokenAdministrationAlreadyActivated();

        bytes32 tokenAdminRole = rewardToken.DEFAULT_ADMIN_ROLE();
        if (!rewardToken.hasRole(tokenAdminRole, address(this))) revert ControllerNotTokenAdmin();
        if (!rewardToken.hasRole(rewardToken.MINTER_ROLE(), address(this))) {
            rewardToken.grantRole(rewardToken.MINTER_ROLE(), address(this));
        }

        uint40 endsAt = SafeCast.toUint40(block.timestamp + TOKEN_ADMINISTRATION_DURATION);
        tokenAdministrationEndsAt = endsAt;
        emit TokenAdministrationActivated(endsAt);
    }

    /// @notice Return DEEP administration to this contract's current governance owner after the term expires.
    /// @dev Anyone may trigger the return at or after the exact deadline.
    function returnTokenAdministration() external {
        uint40 endsAt = tokenAdministrationEndsAt;
        if (endsAt == 0) revert TokenAdministrationNotActive();
        if (tokenAdministrationReturned) revert TokenAdministrationAlreadyReturned();

        address owner_ = owner();
        if (block.timestamp < endsAt) revert TokenAdministrationActive(endsAt);

        bytes32 tokenAdminRole = rewardToken.DEFAULT_ADMIN_ROLE();
        if (!rewardToken.hasRole(tokenAdminRole, address(this))) revert ControllerNotTokenAdmin();

        tokenAdministrationReturned = true;
        // Grant first so DeepstateToken's final-admin invariant cannot strand the token.
        rewardToken.grantRole(tokenAdminRole, owner_);
        rewardToken.renounceRole(tokenAdminRole, address(this));

        emit TokenAdministrationReturned(owner_, msg.sender);
    }

    /// @notice Mint `amount` DEEP to `to` and an additional 30% into a one-year recipient stream.
    /// @dev The 30% calculation rounds down. Amounts that round the stream allocation to zero revert.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) nonReentrant returns (uint256 streamId) {
        if (to == address(0)) revert InvalidMintRecipient();

        uint256 vestingAmount = Math.mulDiv(amount, RECIPIENT_ALLOCATION_BPS, BPS_DENOMINATOR);
        if (vestingAmount == 0) revert MintAmountTooSmall();
        if (vestingAmount > type(uint128).max) revert VestingAmountTooLarge(vestingAmount);
        uint128 streamAmount = SafeCast.toUint128(vestingAmount);

        uint256 mintSupply = amount + vestingAmount;
        uint256 attemptedSupply = rewardToken.totalSupply() + mintSupply;
        if (attemptedSupply > mintCap) revert MintCapExceeded(mintCap, attemptedSupply);

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

    /// @dev Keep EIP-173 ownership, AccessControl administration, and owner mint authority synchronized.
    function _setOwner(address newOwner) internal override {
        if (newOwner == address(0)) revert NewOwnerIsZeroAddress();

        address previousOwner = owner();
        super._setOwner(newOwner);
        if (newOwner != previousOwner) {
            _grantRole(DEFAULT_ADMIN_ROLE, newOwner);
            _grantRole(MINTER_ROLE, newOwner);
            if (previousOwner != address(0)) {
                _revokeRole(DEFAULT_ADMIN_ROLE, previousOwner);
                _revokeRole(MINTER_ROLE, previousOwner);
            }
        }
    }

    function grantRole(bytes32 role, address account) public override {
        if (role == DEFAULT_ADMIN_ROLE && account != owner()) revert OwnerMustRetainDefaultAdmin();
        super.grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) public override {
        if (role == DEFAULT_ADMIN_ROLE && account == owner()) revert OwnerMustRetainDefaultAdmin();
        super.revokeRole(role, account);
    }

    function renounceRole(bytes32 role, address callerConfirmation) public override {
        if (role == DEFAULT_ADMIN_ROLE && callerConfirmation == owner()) revert OwnerMustRetainDefaultAdmin();
        super.renounceRole(role, callerConfirmation);
    }
}
