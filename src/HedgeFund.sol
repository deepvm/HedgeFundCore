// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC7540Deposit, IERC7540Operator, IERC7540Redeem} from "forge-std/interfaces/IERC7540.sol";
import {IERC7575} from "forge-std/interfaces/IERC7575.sol";
import {IERC165} from "forge-std/interfaces/IERC165.sol";

/// @title Altitude Hedge Fund
/// @notice Async deposit and redeem vault settled by owner-priced epochs.
contract HedgeFund is ERC4626, Ownable, ReentrancyGuard, IERC7540Deposit, IERC7540Redeem {
    using SafeERC20 for IERC20;

    uint256 public constant PRICE_SCALE = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant MIN_SHARE_PRICE = 1e12;
    uint256 public constant MAX_PRICE_CHANGE_BPS = 5_000;

    uint256 public currentEpoch;
    uint256 public sharePrice = PRICE_SCALE;
    uint256 public depositLimit = type(uint256).max;
    address public liquidityVault;

    uint256 public pendingDepositAssets;
    uint256 public totalPendingRedeemShares;
    uint256 public totalClaimableDepositShares;
    uint256 public totalClaimableRedeemAssets;
    uint256 public pendingLiquidityAssets;

    mapping(address controller => uint256[] epochs) private _userDepositEpochs;
    mapping(address controller => uint256 idx) private _userDepositIndex;
    mapping(address controller => uint256[] epochs) private _userRedeemEpochs;
    mapping(address controller => uint256 idx) private _userRedeemIndex;

    mapping(address controller => mapping(address operator => bool)) public override isOperator;
    mapping(uint256 epoch => uint256 price) public epochPrice;
    mapping(uint256 epoch => uint256 assets) public epochDepositAssets;
    mapping(uint256 epoch => uint256 shares) public epochDepositShares;
    mapping(uint256 epoch => uint256 shares) public epochRedeemShares;
    mapping(uint256 epoch => uint256 assets) public epochRedeemAssets;

    mapping(uint256 epoch => mapping(address controller => uint256 assets)) private _depositAssets;
    mapping(uint256 epoch => mapping(address controller => uint256 shares)) private _redeemShares;

    error AsyncDeposit();
    error AsyncRedeem();
    error DepositLimitExceeded();
    error EmptyEpoch();
    error NotRequestOwner();
    error NotOperator();
    error PriceDeviationTooLarge();
    error ZeroAmount();
    error ZeroAddress();
    error InvalidSharePrice();

    event SharePriceUpdated(uint256 sharePrice);
    event DepositLimitUpdated(uint256 depositLimit);
    event LiquidityVaultUpdated(address liquidityVault);
    event LiquidityAssetsClaimed(address indexed liquidityVault, uint256 assets);
    event DepositRequestCanceled(address indexed controller, uint256 indexed requestId, uint256 assets);
    event RedeemRequestCanceled(address indexed controller, uint256 indexed requestId, uint256 shares);
    event EpochSettled(
        uint256 indexed epoch,
        uint256 sharePrice,
        uint256 depositAssets,
        uint256 depositShares,
        uint256 redeemShares,
        uint256 redeemAssets
    );

    constructor(address owner_, address asset_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(IERC20(asset_))
        Ownable(owner_)
    {
        if (asset_ == address(0)) revert ZeroAddress();
        liquidityVault = owner_;
    }

    function setOperator(address operator, bool approved) external override returns (bool) {
        if (operator == address(0)) revert ZeroAddress();
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    function setDepositLimit(uint256 limit) external onlyOwner {
        depositLimit = limit;
        emit DepositLimitUpdated(limit);
    }

    function setLiquidityVault(address vault) external onlyOwner {
        if (vault == address(0)) revert ZeroAddress();
        liquidityVault = vault;
        emit LiquidityVaultUpdated(vault);
    }

    function claimLiquidityAssets() external nonReentrant returns (uint256 assets) {
        if (msg.sender != liquidityVault) revert NotOperator();
        assets = pendingLiquidityAssets;
        if (assets == 0) revert ZeroAmount();
        pendingLiquidityAssets = 0;
        IERC20(asset()).safeTransfer(msg.sender, assets);
        emit LiquidityAssetsClaimed(msg.sender, assets);
    }

    // --- Deposit & Redeem Requests ---

    function requestDeposit(uint256 assets) external returns (uint256) {
        return requestDeposit(assets, msg.sender, msg.sender);
    }

    function requestDeposit(uint256 assets, address controller, address owner_)
        public
        override
        nonReentrant
        returns (uint256 requestId)
    {
        if (assets == 0) revert ZeroAmount();
        if (controller == address(0) || owner_ == address(0)) revert ZeroAddress();
        if (msg.sender != owner_ || controller != owner_) revert NotRequestOwner();
        if (assets > maxRequestDeposit(controller)) revert DepositLimitExceeded();

        requestId = currentEpoch + 1;
        IERC20(asset()).safeTransferFrom(owner_, address(this), assets);
        if (_depositAssets[requestId][controller] == 0) _pushDepositRequest(controller, requestId);
        _depositAssets[requestId][controller] += assets;
        epochDepositAssets[requestId] += assets;
        pendingDepositAssets += assets;
        emit DepositRequest(controller, owner_, requestId, msg.sender, assets);
    }

    function cancelDepositRequest(uint256 id) external returns (uint256) {
        return cancelDepositRequest(id, msg.sender);
    }

    function cancelDepositRequest(uint256 id, address controller) public nonReentrant returns (uint256 assets) {
        _checkOperator(controller);
        if (epochPrice[id] != 0) revert ZeroAmount();
        assets = _depositAssets[id][controller];
        if (assets == 0) revert ZeroAmount();

        _depositAssets[id][controller] = 0;
        epochDepositAssets[id] -= assets;
        pendingDepositAssets -= assets;
        _advanceFirstDepositRequest(controller);
        IERC20(asset()).safeTransfer(controller, assets);
        emit DepositRequestCanceled(controller, id, assets);
    }

    function claimDeposit(uint256 id) external returns (uint256) {
        return claimDeposit(id, msg.sender, msg.sender);
    }

    function claimDeposit(uint256 id, address r, address c) public nonReentrant returns (uint256 s) {
        (, s) = _claimDeposit(id, _depositAssets[id][c], false, r, c);
    }

    function requestRedeem(uint256 shares) external returns (uint256) {
        return requestRedeem(shares, msg.sender, msg.sender);
    }

    function requestRedeem(uint256 shares, address controller, address owner_)
        public
        override
        nonReentrant
        returns (uint256 requestId)
    {
        if (shares == 0) revert ZeroAmount();
        if (controller == address(0) || owner_ == address(0)) revert ZeroAddress();
        if (controller != owner_) revert NotRequestOwner();
        if (msg.sender != owner_ && !isOperator[owner_][msg.sender]) _spendAllowance(owner_, msg.sender, shares);

        requestId = currentEpoch + 1;
        _transfer(owner_, address(this), shares);
        _requestRedeem(requestId, controller, shares);
    }

    function cancelRedeemRequest(uint256 id) external returns (uint256) {
        return cancelRedeemRequest(id, msg.sender);
    }

    function cancelRedeemRequest(uint256 id, address controller) public nonReentrant returns (uint256 shares) {
        _checkOperator(controller);
        if (epochPrice[id] != 0) revert ZeroAmount();
        shares = _redeemShares[id][controller];
        if (shares == 0) revert ZeroAmount();

        _redeemShares[id][controller] = 0;
        epochRedeemShares[id] -= shares;
        totalPendingRedeemShares -= shares;
        _advanceFirstRedeemRequest(controller);
        _transfer(address(this), controller, shares);
        emit RedeemRequestCanceled(controller, id, shares);
    }

    function requestRedeemClaimableDeposit(uint256 depId, uint256 shares) external returns (uint256) {
        return requestRedeemClaimableDeposit(depId, shares, msg.sender);
    }

    function requestRedeemClaimableDeposit(uint256 depId, uint256 shares, address controller)
        public
        nonReentrant
        returns (uint256 requestId)
    {
        _checkOperator(controller);
        uint256 price = epochPrice[depId];
        if (price == 0) revert ZeroAmount();

        uint256 assets = _depositAssets[depId][controller];
        uint256 maxShares = Math.mulDiv(assets, PRICE_SCALE, price);
        if (shares == 0 || shares > maxShares) revert ZeroAmount();

        uint256 spentAssets = Math.mulDiv(shares, price, PRICE_SCALE, Math.Rounding.Ceil);
        if (spentAssets > assets) revert ZeroAmount();

        _depositAssets[depId][controller] = assets - spentAssets;
        totalClaimableDepositShares -= shares;
        _advanceFirstDepositRequest(controller);

        requestId = currentEpoch + 1;
        _requestRedeem(requestId, controller, shares);
    }

    function claimRedeem(uint256 id) external returns (uint256) {
        return claimRedeem(id, msg.sender, msg.sender);
    }

    function claimRedeem(uint256 id, address r, address c) public nonReentrant returns (uint256 a) {
        (a,) = _claimRedeem(id, _redeemShares[id][c], false, r, c);
    }

    // --- Epoch Settlement ---

    function settleEpoch(uint256 newSharePrice) external onlyOwner nonReentrant {
        _checkSharePrice(newSharePrice);
        uint256 epoch = currentEpoch + 1;
        uint256 depositAssets = epochDepositAssets[epoch];
        uint256 redeemShares = epochRedeemShares[epoch];
        if (depositAssets == 0 && redeemShares == 0) revert EmptyEpoch();

        currentEpoch = epoch;
        sharePrice = newSharePrice;
        epochPrice[epoch] = newSharePrice;
        emit SharePriceUpdated(newSharePrice);

        uint256 depositShares = Math.mulDiv(depositAssets, PRICE_SCALE, newSharePrice);
        pendingDepositAssets -= depositAssets;
        epochDepositShares[epoch] = depositShares;
        totalClaimableDepositShares += depositShares;
        if (depositShares != 0) _mint(address(this), depositShares);

        uint256 redeemAssets = Math.mulDiv(redeemShares, newSharePrice, PRICE_SCALE);
        totalPendingRedeemShares -= redeemShares;
        epochRedeemAssets[epoch] = redeemAssets;
        if (redeemShares != 0) _burn(address(this), redeemShares);

        _settleAssets(redeemAssets);
        emit EpochSettled(epoch, newSharePrice, depositAssets, depositShares, redeemShares, redeemAssets);
    }

    // --- ERC-7540 & ERC-4626 Overrides ---

    function firstDepositRequest(address c) public view returns (uint256) {
        return _userDepositIndex[c] < _userDepositEpochs[c].length ? _userDepositEpochs[c][_userDepositIndex[c]] : 0;
    }

    function firstRedeemRequest(address c) public view returns (uint256) {
        return _userRedeemIndex[c] < _userRedeemEpochs[c].length ? _userRedeemEpochs[c][_userRedeemIndex[c]] : 0;
    }

    function pendingDepositRequest(uint256 id, address controller) public view override returns (uint256) {
        return id == 0
            ? _depositAssets[currentEpoch + 1][controller]
            : epochPrice[id] == 0 ? _depositAssets[id][controller] : 0;
    }

    function claimableDepositRequest(uint256 id, address controller) public view override returns (uint256 assets) {
        if (id == 0) (assets,) = _claimableDeposit(controller);
        else assets = epochPrice[id] == 0 ? 0 : _depositAssets[id][controller];
    }

    function claimableDepositShares(uint256 id, address c) public view returns (uint256) {
        uint256 p = epochPrice[id];
        return p == 0 ? 0 : Math.mulDiv(_depositAssets[id][c], PRICE_SCALE, p);
    }

    function pendingRedeemRequest(uint256 id, address controller) public view override returns (uint256) {
        return
            id == 0
                ? _redeemShares[currentEpoch + 1][controller]
                : epochPrice[id] == 0 ? _redeemShares[id][controller] : 0;
    }

    function claimableRedeemRequest(uint256 id, address controller) public view override returns (uint256 shares) {
        if (id == 0) (, shares) = _claimableRedeem(controller);
        else shares = epochPrice[id] == 0 ? 0 : _redeemShares[id][controller];
    }

    function totalAssets() public view override returns (uint256) {
        return convertToAssets(totalSupply());
    }

    function maxDeposit(address c) public view override returns (uint256 a) {
        (a,) = _claimableDeposit(c);
    }

    function maxRequestDeposit(address) public view returns (uint256 maxAssets) {
        uint256 managedAssets = totalAssets() + pendingDepositAssets + totalClaimableRedeemAssets;
        return managedAssets < depositLimit ? depositLimit - managedAssets : 0;
    }

    function maxMint(address r) public view override returns (uint256 s) {
        (, s) = _claimableDeposit(r);
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        return deposit(assets, receiver, msg.sender);
    }

    function deposit(uint256 assets, address receiver, address controller)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        (, shares) = _claimDeposit(0, assets, false, receiver, controller);
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        return mint(shares, receiver, msg.sender);
    }

    function mint(uint256 shares, address receiver, address controller)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        (assets,) = _claimDeposit(0, shares, true, receiver, controller);
    }

    function withdraw(uint256 assets, address receiver, address controller)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        (, shares) = _claimRedeem(0, assets, true, receiver, controller);
    }

    function redeem(uint256 shares, address receiver, address controller)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        (assets,) = _claimRedeem(0, shares, false, receiver, controller);
    }

    function maxWithdraw(address c) public view override returns (uint256 a) {
        (a,) = _claimableRedeem(c);
    }

    function maxRedeem(address c) public view override returns (uint256 s) {
        (, s) = _claimableRedeem(c);
    }

    function previewDeposit(uint256) public pure override returns (uint256) {
        revert AsyncDeposit();
    }

    function previewMint(uint256) public pure override returns (uint256) {
        revert AsyncDeposit();
    }

    function previewWithdraw(uint256) public pure override returns (uint256) {
        revert AsyncRedeem();
    }

    function previewRedeem(uint256) public pure override returns (uint256) {
        revert AsyncRedeem();
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        return Math.mulDiv(assets, PRICE_SCALE, sharePrice, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        return Math.mulDiv(shares, sharePrice, PRICE_SCALE, rounding);
    }

    // --- Internal Helpers ---

    function _claimableDeposit(address controller) private view returns (uint256 assets, uint256 shares) {
        uint256 idx = _userDepositIndex[controller];
        uint256[] storage epochs = _userDepositEpochs[controller];
        while (idx < epochs.length) {
            uint256 epoch = epochs[idx];
            if (epoch > currentEpoch) break;
            uint256 price = epochPrice[epoch];
            if (price != 0) {
                uint256 claimableAssets = _depositAssets[epoch][controller];
                assets += claimableAssets;
                shares += Math.mulDiv(claimableAssets, PRICE_SCALE, price);
            }
            idx++;
        }
    }

    function _claimableRedeem(address controller) private view returns (uint256 assets, uint256 shares) {
        uint256 idx = _userRedeemIndex[controller];
        uint256[] storage epochs = _userRedeemEpochs[controller];
        while (idx < epochs.length) {
            uint256 epoch = epochs[idx];
            if (epoch > currentEpoch) break;
            uint256 price = epochPrice[epoch];
            if (price != 0) {
                uint256 claimableShares = _redeemShares[epoch][controller];
                shares += claimableShares;
                assets += Math.mulDiv(claimableShares, price, PRICE_SCALE);
            }
            idx++;
        }
    }

    function share() external view returns (address) {
        return address(this);
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC7540Deposit).interfaceId || id == type(IERC7540Redeem).interfaceId
            || id == type(IERC7540Operator).interfaceId || id == type(IERC7575).interfaceId
            || id == type(IERC165).interfaceId;
    }

    function _requestRedeem(uint256 requestId, address controller, uint256 shares) private {
        if (_redeemShares[requestId][controller] == 0) _pushRedeemRequest(controller, requestId);
        _redeemShares[requestId][controller] += shares;
        epochRedeemShares[requestId] += shares;
        totalPendingRedeemShares += shares;
        emit RedeemRequest(controller, controller, requestId, msg.sender, shares);
    }

    function _claimDeposit(uint256 requestId, uint256 amount, bool exactShares, address receiver, address controller)
        private
        returns (uint256 assets, uint256 shares)
    {
        _checkOperator(controller);
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        uint256 remaining = amount;
        uint256 idx = _userDepositIndex[controller];
        uint256[] storage epochs = _userDepositEpochs[controller];
        while (remaining != 0) {
            uint256 epoch = requestId == 0 ? (idx >= epochs.length ? 0 : epochs[idx]) : requestId;
            if (epoch == 0 || (requestId == 0 && epoch > currentEpoch)) break;

            uint256 price = epochPrice[epoch];
            uint256 claimableAssets = _depositAssets[epoch][controller];
            if (claimableAssets != 0 && price != 0) {
                uint256 claimLimit = exactShares ? Math.mulDiv(claimableAssets, PRICE_SCALE, price) : claimableAssets;
                if (claimLimit != 0) {
                    uint256 claimed = remaining < claimLimit ? remaining : claimLimit;
                    uint256 claimedAssets =
                        exactShares ? Math.mulDiv(claimed, price, PRICE_SCALE, Math.Rounding.Ceil) : claimed;
                    uint256 claimedShares = exactShares ? claimed : Math.mulDiv(claimed, PRICE_SCALE, price);

                    _depositAssets[epoch][controller] -= claimedAssets;
                    assets += claimedAssets;
                    shares += claimedShares;
                    remaining -= claimed;
                }
            }
            if (_depositAssets[epoch][controller] == 0) {
                if (requestId != 0) break;
                idx++;
            } else {
                break;
            }
        }

        if (remaining != 0 || assets == 0 || shares == 0) revert ZeroAmount();
        totalClaimableDepositShares -= shares;
        _userDepositIndex[controller] = idx;
        _advanceFirstDepositRequest(controller);
        _transfer(address(this), receiver, shares);
        emit Deposit(controller, receiver, assets, shares);
    }

    function _claimRedeem(uint256 requestId, uint256 amount, bool exactAssets, address receiver, address controller)
        private
        returns (uint256 assets, uint256 shares)
    {
        _checkOperator(controller);
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        uint256 remaining = amount;
        uint256 accountedAssets;
        uint256 idx = _userRedeemIndex[controller];
        uint256[] storage epochs = _userRedeemEpochs[controller];
        while (remaining != 0) {
            uint256 epoch = requestId == 0 ? (idx >= epochs.length ? 0 : epochs[idx]) : requestId;
            if (epoch == 0 || (requestId == 0 && epoch > currentEpoch)) break;

            uint256 price = epochPrice[epoch];
            uint256 claimable = _redeemShares[epoch][controller];
            if (claimable != 0 && price != 0) {
                uint256 claimLimit = exactAssets ? Math.mulDiv(claimable, price, PRICE_SCALE) : claimable;
                if (claimLimit != 0) {
                    uint256 claimed = remaining < claimLimit ? remaining : claimLimit;
                    uint256 claimedShares =
                        exactAssets ? Math.mulDiv(claimed, PRICE_SCALE, price, Math.Rounding.Ceil) : claimed;
                    uint256 claimedAssets = exactAssets ? claimed : Math.mulDiv(claimed, price, PRICE_SCALE);

                    _redeemShares[epoch][controller] -= claimedShares;
                    shares += claimedShares;
                    assets += claimedAssets;
                    accountedAssets += exactAssets ? Math.mulDiv(claimedShares, price, PRICE_SCALE) : claimedAssets;
                    remaining -= claimed;
                }
            }
            if (_redeemShares[epoch][controller] == 0) {
                if (requestId != 0) break;
                idx++;
            } else {
                break;
            }
        }

        if (remaining != 0 || assets == 0 || shares == 0) revert ZeroAmount();
        totalClaimableRedeemAssets -= accountedAssets;
        _userRedeemIndex[controller] = idx;
        _advanceFirstRedeemRequest(controller);
        IERC20(asset()).safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    function _pushDepositRequest(address controller, uint256 requestId) private {
        uint256[] storage epochs = _userDepositEpochs[controller];
        if (epochs.length == 0 || epochs[epochs.length - 1] != requestId) epochs.push(requestId);
    }

    function _pushRedeemRequest(address controller, uint256 requestId) private {
        uint256[] storage epochs = _userRedeemEpochs[controller];
        if (epochs.length == 0 || epochs[epochs.length - 1] != requestId) epochs.push(requestId);
    }

    function _advanceFirstDepositRequest(address controller) private {
        uint256 idx = _userDepositIndex[controller];
        uint256[] storage epochs = _userDepositEpochs[controller];
        while (idx < epochs.length && _depositAssets[epochs[idx]][controller] == 0) idx++;
        _userDepositIndex[controller] = idx;
    }

    function _advanceFirstRedeemRequest(address controller) private {
        uint256 idx = _userRedeemIndex[controller];
        uint256[] storage epochs = _userRedeemEpochs[controller];
        while (idx < epochs.length && _redeemShares[epochs[idx]][controller] == 0) idx++;
        _userRedeemIndex[controller] = idx;
    }

    function _checkSharePrice(uint256 newSharePrice) private view {
        if (newSharePrice < MIN_SHARE_PRICE) revert InvalidSharePrice();
        if (
            newSharePrice < Math.mulDiv(sharePrice, BPS - MAX_PRICE_CHANGE_BPS, BPS)
                || newSharePrice > Math.mulDiv(sharePrice, BPS + MAX_PRICE_CHANGE_BPS, BPS)
        ) revert PriceDeviationTooLarge();
    }

    function _settleAssets(uint256 redeemAssets) private {
        IERC20 token = IERC20(asset());
        uint256 balance = token.balanceOf(address(this));
        uint256 available = balance > totalClaimableRedeemAssets ? balance - totalClaimableRedeemAssets : 0;

        if (available < redeemAssets) {
            pendingLiquidityAssets = 0;
            token.safeTransferFrom(liquidityVault, address(this), redeemAssets - available);
        } else {
            pendingLiquidityAssets = available - redeemAssets;
        }
        totalClaimableRedeemAssets += redeemAssets;
    }

    function _checkOperator(address controller) private view {
        if (msg.sender != controller && !isOperator[controller][msg.sender]) revert NotOperator();
    }
}
