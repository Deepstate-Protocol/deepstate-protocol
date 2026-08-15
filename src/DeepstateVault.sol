// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";

import {IBurnableERC20} from "./interfaces/IBurnableERC20.sol";

/// @notice STATE governance share vault with ERC-4626 deposit math over burned DEEP.
/// @dev ERC-4626 has one underlying asset. This vault deliberately separates the
/// deposit/accounting asset from the value token redeemed by share holders.
contract DeepstateVault is ERC4626, ERC20Votes, Ownable, ReentrancyGuard {
    using Math for uint256;
    using SafeERC20 for IERC20;
    using SlotDerivation for bytes32;
    using TransientSlot for *;

    bytes32 private constant _ASSET_LIST_CALL_MARKER_SLOT = keccak256("DeepstateVault.assetList.callMarker");
    bytes32 private constant _ASSET_LIST_SEEN_SEED = keccak256("DeepstateVault.assetList.seen");

    /// @notice Fixed price for purchasing the vault's listed non-USDG fee balances.
    uint256 public constant FEE_PURCHASE_PRICE = 10_000e6;
    uint8 public constant VALUE_TOKEN_DECIMALS = 6;

    address public immutable depositToken;
    address public immutable valueToken;

    /// @notice Burned DEEP used to price STATE in the current nonempty supply epoch.
    uint256 public totalBurnedDepositAssets;

    event DepositAssetBurned(address indexed by, uint256 amount);
    event DepositAccountingReset(uint256 previousBurnedAssets);
    event ValueRedeemed(
        address indexed by, address indexed receiver, address indexed owner, uint256 shares, uint256 valueAssets
    );
    event AssetsRedeemed(address indexed by, address indexed receiver, address indexed owner, uint256 shares);
    event AssetRedeemed(address indexed receiver, address indexed asset, uint256 amount);
    event FeesPurchased(address indexed buyer, address indexed receiver, uint256 paymentAmount);
    event FeeAssetPurchased(address indexed receiver, address indexed asset, uint256 amount);

    error ZeroAddress();
    error ZeroShares();
    error ZeroAssets();
    error ProtectedToken();
    error InsufficientValueAssets();
    error UseRedeemValue();
    error EmptyAssetList();
    error DuplicateAsset();
    error InsufficientRedeemableAssets();
    error InsufficientFeeAssets();
    error ArrayLengthMismatch();
    error MinimumAssetAmountNotMet(address token, uint256 amount, uint256 minimum);
    error InvalidFeePayment();
    error InvalidValueTokenDecimals(uint8 actualDecimals);
    error MinimumSharesNotMet(uint256 shares, uint256 minimum);
    error MaximumAssetsExceeded(uint256 assets, uint256 maximum);

    constructor(address owner_, address depositToken_, address valueToken_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(IERC20(depositToken_))
        EIP712(name_, "1")
        Ownable(owner_)
    {
        if (depositToken_ == address(0) || valueToken_ == address(0)) {
            revert ZeroAddress();
        }
        uint8 valueTokenDecimals = IERC20Metadata(valueToken_).decimals();
        if (valueTokenDecimals != VALUE_TOKEN_DECIMALS) revert InvalidValueTokenDecimals(valueTokenDecimals);

        depositToken = depositToken_;
        valueToken = valueToken_;
    }

    receive() external payable {}

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return ERC4626.decimals();
    }

    /// @notice Use wall-clock time for vote checkpoints and Governor settings.
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @notice ERC-6372 clock mode consumed by GovernorVotes.
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    /// @notice ERC-4626 accounting asset. Deposits burn this token instead of retaining it.
    function totalAssets() public view override returns (uint256) {
        return totalBurnedDepositAssets;
    }

    /// @notice Returns the value token amount currently redeemable for `shares`.
    function convertToValueAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return shares.mulDiv(IERC20(valueToken).balanceOf(address(this)), supply);
    }

    function previewRedeemValue(uint256 shares) external view returns (uint256) {
        return convertToValueAssets(shares);
    }

    /// @notice Burns shares and pays the owner a pro-rata amount of the value token.
    function redeemValue(uint256 shares, address receiver, address owner)
        public
        nonReentrant
        returns (uint256 valueAssets)
    {
        if (shares == 0) revert ZeroShares();
        if (shares > balanceOf(owner)) revert ERC4626ExceededMaxRedeem(owner, shares, balanceOf(owner));

        valueAssets = convertToValueAssets(shares);
        if (valueAssets == 0) revert InsufficientValueAssets();

        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        _burn(owner, shares);
        IERC20(valueToken).safeTransfer(receiver, valueAssets);

        emit ValueRedeemed(msg.sender, receiver, owner, shares, valueAssets);
    }

    /// @notice Burns STATE and pays a pro-rata share of each explicitly listed vault asset.
    /// @dev Use address(0) for native ETH. DEEP and STATE cannot be redeemed through this path.
    /// All payouts use pre-burn balances and supply; omitted assets remain in the vault.
    function redeemAssets(uint256 shares, address receiver, address owner, address[] calldata tokens)
        external
        nonReentrant
        returns (uint256[] memory assets)
    {
        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert ZeroAddress();

        uint256 ownerBalance = balanceOf(owner);
        if (shares > ownerBalance) revert ERC4626ExceededMaxRedeem(owner, shares, ownerBalance);

        uint256 length = tokens.length;
        if (length == 0) revert EmptyAssetList();

        uint256 supply = totalSupply();
        uint256 marker = _nextAssetListCallMarker();
        assets = new uint256[](length);
        bool hasAssets;

        for (uint256 i; i < length; ++i) {
            address token = tokens[i];
            _validateListedAsset(token, marker);

            uint256 amount = shares.mulDiv(_vaultBalance(token), supply);
            assets[i] = amount;
            if (amount != 0) hasAssets = true;
        }

        if (!hasAssets) revert InsufficientRedeemableAssets();
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        _burn(owner, shares);

        for (uint256 i; i < length; ++i) {
            uint256 amount = assets[i];
            if (amount == 0) continue;

            address token = tokens[i];
            _transferAsset(token, receiver, amount);

            emit AssetRedeemed(receiver, token, amount);
        }

        emit AssetsRedeemed(msg.sender, receiver, owner, shares);
    }

    /// @notice Pays 10,000 USDG for the vault's complete balances of the explicitly listed fee assets.
    /// @dev Use address(0) for native ETH. DEEP, STATE, and USDG cannot be purchased.
    function buyFees(address[] calldata tokens, uint256[] calldata minimumAmounts, address receiver)
        external
        nonReentrant
        returns (uint256[] memory assets)
    {
        if (receiver == address(0)) revert ZeroAddress();

        uint256 length = tokens.length;
        if (length == 0) revert EmptyAssetList();
        if (minimumAmounts.length != length) revert ArrayLengthMismatch();

        uint256 marker = _nextAssetListCallMarker();
        assets = new uint256[](length);
        bool hasAssets;

        for (uint256 i; i < length; ++i) {
            address token = tokens[i];
            _validateListedAsset(token, marker);
            if (token == valueToken) revert ProtectedToken();

            uint256 amount = _vaultBalance(token);
            uint256 minimum = minimumAmounts[i];
            if (amount < minimum) revert MinimumAssetAmountNotMet(token, amount, minimum);

            assets[i] = amount;
            if (amount != 0) hasAssets = true;
        }

        if (!hasAssets) revert InsufficientFeeAssets();

        uint256 paymentBalanceBefore = IERC20(valueToken).balanceOf(address(this));
        IERC20(valueToken).safeTransferFrom(msg.sender, address(this), FEE_PURCHASE_PRICE);
        uint256 paymentBalanceAfter = IERC20(valueToken).balanceOf(address(this));
        if (paymentBalanceAfter != paymentBalanceBefore + FEE_PURCHASE_PRICE) {
            revert InvalidFeePayment();
        }

        for (uint256 i; i < length; ++i) {
            uint256 amount = assets[i];
            if (amount == 0) continue;

            address token = tokens[i];
            _transferAsset(token, receiver, amount);
            emit FeeAssetPurchased(receiver, token, amount);
        }

        emit FeesPurchased(msg.sender, receiver, FEE_PURCHASE_PRICE);
    }

    /// @notice Deposits assets only if the live conversion mints at least `minShares`.
    function deposit(uint256 assets, address receiver, uint256 minShares) public returns (uint256 shares) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);

        shares = previewDeposit(assets);
        if (shares < minShares) revert MinimumSharesNotMet(shares, minShares);
        _deposit(_msgSender(), receiver, assets, shares);
    }

    /// @notice Mints shares only if the live conversion consumes at most `maxAssets`.
    function mint(uint256 shares, address receiver, uint256 maxAssets) public returns (uint256 assets) {
        uint256 maxShares = maxMint(receiver);
        if (shares > maxShares) revert ERC4626ExceededMaxMint(receiver, shares, maxShares);

        assets = previewMint(shares);
        if (assets > maxAssets) revert MaximumAssetsExceeded(assets, maxAssets);
        _deposit(_msgSender(), receiver, assets, shares);
    }

    /// @dev Strict ERC-4626 withdrawal would return the deposit asset, which is burned here.
    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert UseRedeemValue();
    }

    /// @dev Use `redeemValue` to redeem shares for the value token.
    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert UseRedeemValue();
    }

    /// @dev Standard DEEP withdrawals are unavailable because deposited DEEP is burned.
    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    /// @dev Standard DEEP redemptions are unavailable; use `redeemValue` for the value token.
    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }

    /// @notice Maximum STATE shares an owner may redeem for the value token.
    function maxRedeemValue(address owner) public view returns (uint256) {
        return balanceOf(owner);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        if (assets == 0) revert ZeroAssets();
        if (shares == 0) revert ZeroShares();

        IERC20(depositToken).safeTransferFrom(caller, address(this), assets);
        IBurnableERC20(depositToken).burn(assets);
        totalBurnedDepositAssets += assets;
        _mint(receiver, shares);
        _selfDelegateIfUnset(receiver);

        emit Deposit(caller, receiver, assets, shares);
        emit DepositAssetBurned(caller, assets);
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets : assets.mulDiv(supply, totalAssets(), rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : shares.mulDiv(totalAssets(), supply, rounding);
    }

    function _selfDelegateIfUnset(address account) private {
        if (delegates(account) == address(0)) _delegate(account, account);
    }

    function _vaultBalance(address token) private view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    function _validateListedAsset(address token, uint256 marker) private {
        if (token == depositToken || token == address(this)) revert ProtectedToken();
        _markAssetSeen(token, marker);
    }

    function _transferAsset(address token, address receiver, uint256 amount) private {
        if (token == address(0)) Address.sendValue(payable(receiver), amount);
        else IERC20(token).safeTransfer(receiver, amount);
    }

    function _nextAssetListCallMarker() private returns (uint256 marker) {
        TransientSlot.Uint256Slot slot = _ASSET_LIST_CALL_MARKER_SLOT.asUint256();
        marker = slot.tload() + 1;
        slot.tstore(marker);
    }

    function _markAssetSeen(address token, uint256 marker) private {
        TransientSlot.Uint256Slot slot = _ASSET_LIST_SEEN_SEED.deriveMapping(token).asUint256();
        if (slot.tload() == marker) revert DuplicateAsset();
        slot.tstore(marker);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        if (to == address(this) && value != 0) revert ProtectedToken();

        super._update(from, to, value);

        if (to == address(0) && totalSupply() == 0) {
            // No STATE remains to price against historical burns; the next epoch starts 1:1.
            uint256 previousBurnedAssets = totalBurnedDepositAssets;
            totalBurnedDepositAssets = 0;
            emit DepositAccountingReset(previousBurnedAssets);
        }
    }
}
