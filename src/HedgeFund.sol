// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/// @title Altitude Hedge Fund
/// @notice ERC4626 shares priced by the owner after off-chain NAV and fee accounting.
contract HedgeFund is ERC4626, Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant PRICE_SCALE = 1e18;

    uint256 public priceStart = PRICE_SCALE;
    uint256 public priceTarget = PRICE_SCALE;
    uint256 public priceStartTime;
    uint256 public priceEndTime;
    uint256 public depositLimit = type(uint256).max;
    uint256 public totalPendingRedeemAssets;

    mapping(address account => uint256 assets) public pendingRedeemAssets;

    error ZeroAmount();
    error ZeroAddress();
    error InvalidSharePrice();

    event SharePriceUpdated(uint256 targetSharePrice, uint256 vestingSeconds);
    event DepositLimitUpdated(uint256 depositLimit);
    event RedeemRequested(address indexed account, uint256 shares, uint256 assets);
    event RedeemClaimed(address indexed account, uint256 assets);

    constructor(address owner_, address asset_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(IERC20(asset_))
        Ownable(owner_)
    {
        if (asset_ == address(0)) revert ZeroAddress();
    }

    /// @notice Owner reports a price that already includes all off-chain fees and NAV changes.
    function setSharePrice(uint256 newSharePrice, uint256 vestingSeconds) external onlyOwner {
        if (newSharePrice == 0) revert InvalidSharePrice();

        uint256 currentSharePrice = sharePrice();
        priceStart = currentSharePrice;
        priceTarget = newSharePrice;
        priceStartTime = block.timestamp;
        priceEndTime = newSharePrice > currentSharePrice ? block.timestamp + vestingSeconds : block.timestamp;

        emit SharePriceUpdated(newSharePrice, vestingSeconds);
    }

    /// @notice Current price used for deposits, mints, and redeem requests.
    function sharePrice() public view returns (uint256) {
        if (block.timestamp >= priceEndTime) return priceTarget;
        return priceStart
            + Math.mulDiv(priceTarget - priceStart, block.timestamp - priceStartTime, priceEndTime - priceStartTime);
    }

    /// @notice Owner may limit deposits and mints without affecting exits.
    function setDepositLimit(uint256 newDepositLimit) external onlyOwner {
        depositLimit = newDepositLimit;
        emit DepositLimitUpdated(newDepositLimit);
    }

    /// @notice request a redeem at the current effective price.
    function requestRedeem(uint256 shares) external returns (uint256 assets) {
        assets = previewRedeem(shares);
        if (assets == 0) revert ZeroAmount();

        _burn(msg.sender, shares);
        pendingRedeemAssets[msg.sender] += assets;
        totalPendingRedeemAssets += assets;

        emit RedeemRequested(msg.sender, shares, assets);
    }

    /// @notice Claim assets from a requested redeem. The owner must fund this contract first.
    function claimRedeem() external returns (uint256 assets) {
        assets = pendingRedeemAssets[msg.sender];
        if (assets == 0) revert ZeroAmount();

        pendingRedeemAssets[msg.sender] = 0;
        totalPendingRedeemAssets -= assets;
        IERC20(asset()).safeTransfer(msg.sender, assets);

        emit RedeemClaimed(msg.sender, assets);
    }

    /// @inheritdoc ERC4626
    function totalAssets() public view override returns (uint256) {
        return convertToAssets(totalSupply());
    }

    /// @inheritdoc ERC4626
    function maxDeposit(address) public view override returns (uint256) {
        uint256 limit = depositLimit;
        uint256 managedAssets = totalAssets();
        return managedAssets < limit ? limit - managedAssets : 0;
    }

    /// @inheritdoc ERC4626
    function maxMint(address receiver) public view override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        return maxAssets == type(uint256).max ? type(uint256).max : convertToShares(maxAssets);
    }

    /// @inheritdoc ERC4626
    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        return Math.mulDiv(assets, PRICE_SCALE, sharePrice(), rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        return Math.mulDiv(shares, sharePrice(), PRICE_SCALE, rounding);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (assets == 0 || shares == 0) revert ZeroAmount();

        IERC20(asset()).safeTransferFrom(caller, owner(), assets);
        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
    }
}
