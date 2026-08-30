// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Lockup} from "@sablier/lockup/src/types/Lockup.sol";
import {LockupLinear} from "@sablier/lockup/src/types/LockupLinear.sol";
import {OwnableRoles} from "solady/auth/OwnableRoles.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {DeepstateToken} from "./DeepstateToken.sol";
import {ISablierLockupLinearV4} from "./interfaces/ISablierLockupLinearV4.sol";

/// @title Deepstate Minter Controller
/// @notice Allocates 30% of every authorized DEEP issuance to a vesting recipient.
/// @dev The recipient allocation is placed in a new non-cancelable, non-transferable Sablier
/// Lockup v4 linear stream. This contract temporarily administers DEEP while remaining owned by governance.
contract DeepstateMinterController is OwnableRoles, ReentrancyGuard {
    using SafeTransferLib for address;

    uint256 public constant MINTER_ROLE = 1 << 0;
    uint256 public constant RECIPIENT_ALLOCATION_BPS = 30_00;
    uint256 public constant PRIMARY_ALLOCATION_BPS = 70_00;
    uint40 public constant VESTING_DURATION = 365 days;
    uint40 public constant TOKEN_ADMINISTRATION_DURATION = 2 * 365 days;

    DeepstateToken public immutable deepstateToken;
    ISablierLockupLinearV4 public immutable sablierLockup;
    address public immutable recipient;
    /// @notice Maximum live DEEP supply this controller will permit after a mint.
    uint256 public immutable mintCap;

    /// @notice Administration deadline, zero before locking, and uint40 max after permanent return.
    uint40 public tokenAdministrationEndsAt;

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
    error InvalidDeepstateToken();
    error InvalidSablierLockup();
    error InvalidRecipient();
    error InvalidMintCap();
    error InvalidMintRecipient();
    error MintAmountTooSmall();
    error VestingAmountTooLarge(uint256 amount);
    error ControllerNotTokenAdmin();
    error TokenAdministrationAlreadyActivated();
    error TokenAdministrationAlreadyReturned();
    error TokenAdministrationNotActive();
    error TokenAdministrationActive(uint40 endsAt);
    error MintCapExceeded(uint256 cap, uint256 attemptedSupply);

    constructor(address owner_, address deepstateToken_, address sablierLockup_, address recipient_, uint256 mintCap_) {
        if (owner_ == address(0)) revert InvalidOwner();
        if (deepstateToken_ == address(0) || deepstateToken_.code.length == 0) revert InvalidDeepstateToken();
        if (sablierLockup_ == address(0) || sablierLockup_.code.length == 0) revert InvalidSablierLockup();
        if (recipient_ == address(0)) revert InvalidRecipient();
        if (mintCap_ == 0) revert InvalidMintCap();

        deepstateToken = DeepstateToken(deepstateToken_);
        sablierLockup = ISablierLockupLinearV4(sablierLockup_);
        recipient = recipient_;
        mintCap = mintCap_;
        _initializeOwner(owner_);
    }

    /// @notice Lock DEEP administration in this contract for the initial two-year term.
    /// @dev Also ensures this controller holds DEEP's operational minter role.
    function lockTokenAdministration() external onlyOwner {
        if (tokenAdministrationEndsAt != 0) revert TokenAdministrationAlreadyActivated();

        bytes32 tokenAdminRole = deepstateToken.DEFAULT_ADMIN_ROLE();
        if (!deepstateToken.hasRole(tokenAdminRole, address(this))) revert ControllerNotTokenAdmin();
        if (!deepstateToken.hasRole(deepstateToken.MINTER_ROLE(), address(this))) {
            deepstateToken.grantRole(deepstateToken.MINTER_ROLE(), address(this));
        }

        uint40 endsAt = SafeCastLib.toUint40(block.timestamp + TOKEN_ADMINISTRATION_DURATION);
        tokenAdministrationEndsAt = endsAt;
        emit TokenAdministrationActivated(endsAt);
    }

    /// @notice Unlock DEEP administration to this contract's current governance owner after the term expires.
    /// @dev Anyone may trigger the unlock at or after the exact deadline.
    function unlockTokenAdministration() external {
        uint40 endsAt = tokenAdministrationEndsAt;
        if (endsAt == 0) revert TokenAdministrationNotActive();
        if (endsAt == type(uint40).max) revert TokenAdministrationAlreadyReturned();

        address owner_ = owner();
        if (block.timestamp < endsAt) revert TokenAdministrationActive(endsAt);

        bytes32 tokenAdminRole = deepstateToken.DEFAULT_ADMIN_ROLE();
        if (!deepstateToken.hasRole(tokenAdminRole, address(this))) revert ControllerNotTokenAdmin();

        tokenAdministrationEndsAt = type(uint40).max;
        // Grant first so DeepstateToken's final-admin invariant cannot strand the token.
        deepstateToken.grantRole(tokenAdminRole, owner_);
        deepstateToken.renounceRole(tokenAdminRole, address(this));

        emit TokenAdministrationReturned(owner_, msg.sender);
    }

    /// @notice Ownership cannot be renounced while this contract may administer DEEP.
    function renounceOwnership() public payable override onlyOwner {
        revert NewOwnerIsZeroAddress();
    }

    /// @notice Mint the 70% primary tranche `amount` to `to` and the 30% tranche into a one-year stream.
    /// @dev The recipient amount is `floor(amount * 30 / 70)`. Amounts that round it to zero revert.
    function mint(address to, uint256 amount)
        external
        onlyOwnerOrRoles(MINTER_ROLE)
        nonReentrant
        returns (uint256 streamId)
    {
        if (to == address(0)) revert InvalidMintRecipient();

        uint256 vestingAmount = FixedPointMathLib.fullMulDiv(amount, RECIPIENT_ALLOCATION_BPS, PRIMARY_ALLOCATION_BPS);
        if (vestingAmount == 0) revert MintAmountTooSmall();
        if (vestingAmount > type(uint128).max) revert VestingAmountTooLarge(vestingAmount);
        uint128 streamAmount = SafeCastLib.toUint128(vestingAmount);

        uint256 mintSupply = amount + vestingAmount;
        uint256 attemptedSupply = deepstateToken.totalSupply() + mintSupply;
        if (attemptedSupply > mintCap) revert MintCapExceeded(mintCap, attemptedSupply);

        deepstateToken.mint(to, amount);
        deepstateToken.mint(address(this), vestingAmount);

        address(deepstateToken).safeApproveWithRetry(address(sablierLockup), vestingAmount);
        streamId = sablierLockup.createWithDurationsLL(
            Lockup.CreateWithDurations({
                sender: address(this),
                recipient: recipient,
                depositAmount: streamAmount,
                token: IERC20(address(deepstateToken)),
                cancelable: false,
                transferable: false,
                shape: "Deepstate allocation"
            }),
            LockupLinear.UnlockAmounts({start: 0, cliff: 0}),
            0,
            LockupLinear.Durations({cliff: 0, total: VESTING_DURATION})
        );

        emit MintedWithVesting(msg.sender, to, amount, recipient, vestingAmount, streamId);
    }
}
