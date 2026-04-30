// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IERC7540Deposit, IERC7540Operator, IERC7540Redeem} from "forge-std/interfaces/IERC7540.sol";
import {IERC7575} from "forge-std/interfaces/IERC7575.sol";
import {IERC165} from "forge-std/interfaces/IERC165.sol";

/// @title Altitude Hedge Fund
/// @notice Async deposit and redeem vault settled by owner-priced epochs.
/// @dev
/// Implements the ERC7540 deposit and redeem request interfaces on top of OZ ERC4626 accounting.
/// Users enter with `requestDeposit` and later pull shares with `deposit`/`mint`.
/// Users exit with `requestRedeem` and later pull assets with `redeem`/`withdraw`.
/// Epoch timing is deliberately off-chain: the owner decides when to settle the next epoch and
/// supplies the epoch share price. The owner and `liquidityVault` are trusted roles.
/// The asset is expected to be a plain non-rebasing ERC20 without transfer fees, such as USDT.
contract HedgeFund is ERC4626, Ownable, ReentrancyGuard, IERC7540Deposit, IERC7540Redeem {
    using SafeERC20 for IERC20;

    /// @notice Fixed-point scale for share prices.
    /// @dev A price of `1e18` means 1 share is worth 1 asset unit before asset decimals are considered.
    uint256 public constant PRICE_SCALE = 1e18;

    /// @notice Basis point scale used for price-change bounds.
    uint256 public constant BPS = 10_000;

    /// @notice Lowest accepted share price.
    /// @dev Catches unit mistakes such as passing `1` instead of `1e18`.
    uint256 public constant MIN_SHARE_PRICE = 1e12;

    /// @notice Maximum allowed price change per settled epoch.
    /// @dev This is a typo/manipulation guard, not a substitute for a trusted NAV process.
    uint256 public constant MAX_PRICE_CHANGE_BPS = 5_000;

    /// @notice Last epoch settled by the owner.
    /// @dev New requests are always assigned to `currentEpoch + 1`.
    uint256 public currentEpoch;

    /// @notice Latest settled share price, scaled by `PRICE_SCALE`.
    /// @dev Used by ERC4626 `convertToShares` and `convertToAssets`.
    uint256 public sharePrice = PRICE_SCALE;

    /// @notice Maximum managed assets accepted through deposit requests.
    /// @dev New request capacity is exposed through `maxRequestDeposit`; ERC7540 `maxDeposit` is claimable assets.
    uint256 public depositLimit = type(uint256).max;

    /// @notice Asset source/sink used during settlement netting.
    /// @dev Surplus assets are sent here and redemption deficits are pulled from here via allowance.
    address public liquidityVault;

    /// @notice Aggregate assets in deposit requests that have not been settled yet.
    uint256 public pendingDepositAssets;

    /// @notice Aggregate shares in redeem requests that have not been settled yet.
    uint256 public totalPendingRedeemShares;

    /// @notice Aggregate shares minted to this vault and awaiting deposit claims.
    uint256 public totalClaimableDepositShares;

    /// @notice Aggregate assets reserved in this vault and awaiting redeem claims.
    uint256 public totalClaimableRedeemAssets;

    /// @notice Earliest epoch that may contain a deposit request for a controller.
    mapping(address controller => uint256 epoch) public firstDepositRequest;

    /// @notice Earliest epoch that may contain a redeem request for a controller.
    mapping(address controller => uint256 epoch) public firstRedeemRequest;

    /// @inheritdoc IERC7540Operator
    mapping(address controller => mapping(address operator => bool)) public override isOperator;

    /// @notice Settled price for each epoch, scaled by `PRICE_SCALE`.
    /// @dev A zero price means the epoch is still pending or nonexistent.
    mapping(uint256 epoch => uint256 price) public epochPrice;

    /// @notice Aggregate deposit assets requested for an epoch.
    mapping(uint256 epoch => uint256 assets) public epochDepositAssets;

    /// @notice Aggregate deposit shares minted for an epoch after settlement.
    mapping(uint256 epoch => uint256 shares) public epochDepositShares;

    /// @notice Aggregate redeem shares requested for an epoch.
    mapping(uint256 epoch => uint256 shares) public epochRedeemShares;

    /// @notice Aggregate redeem assets reserved for an epoch after settlement.
    mapping(uint256 epoch => uint256 assets) public epochRedeemAssets;

    /// @dev Per-controller deposit assets keyed by epoch request id.
    mapping(uint256 epoch => mapping(address controller => uint256 assets)) private _depositAssets;

    /// @dev Per-controller redeem shares keyed by epoch request id.
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
    event DepositRequestCanceled(address indexed controller, uint256 indexed requestId, uint256 assets);
    event RedeemRequestCanceled(address indexed controller, uint256 indexed requestId, uint256 shares);

    /// @notice Emitted when owner settles an epoch price and makes requests claimable.
    /// @param epoch Settled epoch id.
    /// @param sharePrice Settled price scaled by `PRICE_SCALE`.
    /// @param depositAssets Aggregate deposit assets converted in this epoch.
    /// @param depositShares Aggregate deposit shares made claimable in this epoch.
    /// @param redeemShares Aggregate redeem shares converted in this epoch.
    /// @param redeemAssets Aggregate redeem assets reserved in this epoch.
    event EpochSettled(
        uint256 indexed epoch,
        uint256 sharePrice,
        uint256 depositAssets,
        uint256 depositShares,
        uint256 redeemShares,
        uint256 redeemAssets
    );

    /// @notice Deploys the async vault.
    /// @param owner_ Owner account, expected to be the Safe multisig that settles epochs.
    /// @param asset_ ERC20 asset accepted by the vault.
    /// @param name_ ERC20 share token name.
    /// @param symbol_ ERC20 share token symbol.
    constructor(address owner_, address asset_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(IERC20(asset_))
        Ownable(owner_)
    {
        if (asset_ == address(0)) revert ZeroAddress();
        liquidityVault = owner_;
    }

    /// @inheritdoc IERC7540Operator
    function setOperator(address operator, bool approved) external override returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    /// @notice Sets the maximum managed assets accepted through new deposit requests.
    /// @dev This does not block claims or redemptions. If current managed assets exceed the new limit,
    /// `maxRequestDeposit` returns zero until managed assets fall below the limit.
    /// @param newDepositLimit New limit in asset units.
    function setDepositLimit(uint256 newDepositLimit) external onlyOwner {
        depositLimit = newDepositLimit;
        emit DepositLimitUpdated(newDepositLimit);
    }

    /// @notice Sets the external asset vault used for settlement funding and surplus transfers.
    /// @dev The new vault must approve this contract for deficits before `settleEpoch` if redemptions
    /// exceed assets already held by this contract.
    /// @param newLiquidityVault Address that receives surplus assets and funds redemption deficits.
    function setLiquidityVault(address newLiquidityVault) external onlyOwner {
        if (newLiquidityVault == address(0)) revert ZeroAddress();
        liquidityVault = newLiquidityVault;
        emit LiquidityVaultUpdated(newLiquidityVault);
    }

    /// @notice Requests an async deposit for the caller.
    /// @dev Transfers assets from the caller into this vault and assigns the request to the next epoch.
    /// @param assets Amount of asset tokens to request for deposit.
    /// @return requestId Epoch id assigned to the request.
    function requestDeposit(uint256 assets) external returns (uint256 requestId) {
        return requestDeposit(assets, msg.sender, msg.sender);
    }

    /// @inheritdoc IERC7540Deposit
    /// @dev Deposits must be initiated by the token owner. Operators can claim later, but cannot pull
    /// asset tokens into a new deposit request. The ERC20 allowance must be granted from `owner_` to this vault.
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
        requestId = _nextRequestId();

        IERC20(asset()).safeTransferFrom(owner_, address(this), assets);
        _depositAssets[requestId][controller] += assets;
        _setFirstDepositRequest(controller, requestId);
        epochDepositAssets[requestId] += assets;
        pendingDepositAssets += assets;

        emit DepositRequest(controller, owner_, requestId, msg.sender, assets);
    }

    /// @notice Cancels an unsettled deposit request and returns assets to the controller.
    /// @dev Only pending requests can be canceled. Settled requests must be claimed or redeemed.
    /// @param requestId Pending epoch request id.
    /// @return assets Amount returned to the controller.
    function cancelDepositRequest(uint256 requestId) external returns (uint256 assets) {
        return cancelDepositRequest(requestId, msg.sender);
    }

    /// @notice Cancels an unsettled deposit request for a controller.
    /// @dev Reverts unless caller is `controller` or operator.
    /// @param requestId Pending epoch request id.
    /// @param controller Account controlling the request.
    /// @return assets Amount returned to `controller`.
    function cancelDepositRequest(uint256 requestId, address controller) public nonReentrant returns (uint256 assets) {
        _checkOperator(controller);
        if (epochPrice[requestId] != 0) revert ZeroAmount();

        assets = _depositAssets[requestId][controller];
        if (assets == 0) revert ZeroAmount();

        _depositAssets[requestId][controller] = 0;
        epochDepositAssets[requestId] -= assets;
        pendingDepositAssets -= assets;
        _advanceFirstDepositRequest(controller);
        IERC20(asset()).safeTransfer(controller, assets);

        emit DepositRequestCanceled(controller, requestId, assets);
    }

    /// @notice Claims all settled deposit assets for a specific epoch into shares for the caller.
    /// @dev Compatibility helper. ERC7540 integrations should normally use `deposit` or `mint`.
    /// @param requestId Epoch request id to claim.
    /// @return shares Amount of shares transferred to the caller.
    function claimDeposit(uint256 requestId) external returns (uint256 shares) {
        return claimDeposit(requestId, msg.sender, msg.sender);
    }

    /// @notice Claims all settled deposit assets for a specific epoch into shares.
    /// @dev Compatibility helper with explicit request id. Reverts unless caller is `controller` or operator.
    /// @param requestId Epoch request id to claim.
    /// @param receiver Account receiving shares.
    /// @param controller Account controlling the request.
    /// @return shares Amount of shares transferred to `receiver`.
    function claimDeposit(uint256 requestId, address receiver, address controller)
        public
        nonReentrant
        returns (uint256 shares)
    {
        return _claimDeposit(requestId, _depositAssets[requestId][controller], receiver, controller);
    }

    /// @notice Requests an async redeem for caller-owned shares.
    /// @dev Moves shares from the caller into this vault and assigns the request to the next epoch.
    /// @param shares Amount of shares to request for redemption.
    /// @return requestId Epoch id assigned to the request.
    function requestRedeem(uint256 shares) external returns (uint256 requestId) {
        return requestRedeem(shares, msg.sender, msg.sender);
    }

    /// @inheritdoc IERC7540Redeem
    /// @dev `controller` must equal `owner_` so canceled shares always return to the same account.
    /// If caller is not `owner_` and is not an approved operator, ERC20 share allowance is spent.
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
        requestId = _nextRequestId();

        _transfer(owner_, address(this), shares);
        _requestRedeem(requestId, controller, owner_, shares);
    }

    /// @notice Cancels an unsettled redeem request and returns shares to the controller.
    /// @dev Only pending requests can be canceled. Settled requests must be claimed.
    /// @param requestId Pending epoch request id.
    /// @return shares Amount returned to the controller.
    function cancelRedeemRequest(uint256 requestId) external returns (uint256 shares) {
        return cancelRedeemRequest(requestId, msg.sender);
    }

    /// @notice Cancels an unsettled redeem request for a controller.
    /// @dev Reverts unless caller is `controller` or operator.
    /// @param requestId Pending epoch request id.
    /// @param controller Account controlling the request.
    /// @return shares Amount returned to `controller`.
    function cancelRedeemRequest(uint256 requestId, address controller) public nonReentrant returns (uint256 shares) {
        _checkOperator(controller);
        if (epochPrice[requestId] != 0) revert ZeroAmount();

        shares = _redeemShares[requestId][controller];
        if (shares == 0) revert ZeroAmount();

        _redeemShares[requestId][controller] = 0;
        epochRedeemShares[requestId] -= shares;
        totalPendingRedeemShares -= shares;
        _advanceFirstRedeemRequest(controller);
        _transfer(address(this), controller, shares);

        emit RedeemRequestCanceled(controller, requestId, shares);
    }

    /// @notice Requests redemption of settled but unclaimed deposit shares.
    /// @dev Lets a controller exit claimable deposit shares without first transferring shares to its wallet.
    /// @param depositRequestId Settled deposit epoch to draw claimable shares from.
    /// @param shares Amount of claimable shares to move into a new redeem request.
    /// @return requestId New redeem request epoch id.
    function requestRedeemClaimableDeposit(uint256 depositRequestId, uint256 shares)
        external
        returns (uint256 requestId)
    {
        return requestRedeemClaimableDeposit(depositRequestId, shares, msg.sender);
    }

    /// @notice Requests redemption of settled but unclaimed deposit shares for a controller.
    /// @dev Reverts unless caller is `controller` or operator. Consumes deposit assets using rounding up
    /// so the remaining unclaimed deposit position cannot be overclaimed.
    /// @param depositRequestId Settled deposit epoch to draw claimable shares from.
    /// @param shares Amount of claimable shares to move into a new redeem request.
    /// @param controller Account controlling the settled deposit request.
    /// @return requestId New redeem request epoch id.
    function requestRedeemClaimableDeposit(uint256 depositRequestId, uint256 shares, address controller)
        public
        nonReentrant
        returns (uint256 requestId)
    {
        _checkOperator(controller);

        uint256 price = epochPrice[depositRequestId];
        if (price == 0) revert ZeroAmount();
        uint256 assets = _depositAssets[depositRequestId][controller];
        uint256 maxShares = Math.mulDiv(assets, PRICE_SCALE, price);
        if (shares == 0 || shares > maxShares) revert ZeroAmount();

        _depositAssets[depositRequestId][controller] =
            assets - Math.mulDiv(shares, price, PRICE_SCALE, Math.Rounding.Ceil);
        totalClaimableDepositShares -= shares;
        _advanceFirstDepositRequest(controller);

        requestId = _nextRequestId();
        _requestRedeem(requestId, controller, controller, shares);
    }

    /// @notice Settles the next epoch at an owner-reported share price.
    /// @dev Converts all pending deposit assets and redeem shares for `currentEpoch + 1`.
    /// Deposit assets become claimable shares. Redeem shares are burned and become claimable assets.
    /// The function nets the vault asset balance against redemption assets and sends/pulls the difference
    /// to/from `liquidityVault`. `newSharePrice` is trusted off-chain NAV and fee accounting.
    /// @param newSharePrice Settled price scaled by `PRICE_SCALE`.
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

    /// @notice Claims all settled redeem shares for a specific epoch into assets for the caller.
    /// @dev Compatibility helper. ERC7540 integrations should normally use `redeem` or `withdraw`.
    /// @param requestId Epoch request id to claim.
    /// @return assets Amount of assets transferred to the caller.
    function claimRedeem(uint256 requestId) external returns (uint256 assets) {
        return claimRedeem(requestId, msg.sender, msg.sender);
    }

    /// @notice Claims all settled redeem shares for a specific epoch into assets.
    /// @dev Compatibility helper with explicit request id. Reverts unless caller is `controller` or operator.
    /// @param requestId Epoch request id to claim.
    /// @param receiver Account receiving assets.
    /// @param controller Account controlling the redeem request.
    /// @return assets Amount of assets transferred to `receiver`.
    function claimRedeem(uint256 requestId, address receiver, address controller)
        public
        nonReentrant
        returns (uint256 assets)
    {
        _checkOperator(controller);
        if (receiver == address(0)) revert ZeroAddress();

        return _claimRedeem(requestId, _redeemShares[requestId][controller], receiver, controller);
    }

    /// @inheritdoc IERC7540Deposit
    /// @dev Passing `requestId == 0` returns the aggregate pending deposit assets for the current next epoch.
    function pendingDepositRequest(uint256 requestId, address controller) public view override returns (uint256) {
        if (requestId == 0) return _pendingDepositAssets(controller);
        return epochPrice[requestId] == 0 ? _depositAssets[requestId][controller] : 0;
    }

    /// @inheritdoc IERC7540Deposit
    /// @dev Passing `requestId == 0` returns aggregate claimable deposit assets across settled epochs.
    function claimableDepositRequest(uint256 requestId, address controller) public view override returns (uint256) {
        if (requestId == 0) return _claimableDepositAssets(controller);
        return epochPrice[requestId] == 0 ? 0 : _depositAssets[requestId][controller];
    }

    /// @notice Returns claimable shares for a settled deposit request.
    /// @dev This is a convenience view not required by ERC7540.
    /// @param requestId Epoch request id.
    /// @param controller Account controlling the deposit request.
    /// @return shares Shares claimable from the request at its settled epoch price.
    function claimableDepositShares(uint256 requestId, address controller) public view returns (uint256) {
        uint256 price = epochPrice[requestId];
        return price == 0 ? 0 : Math.mulDiv(_depositAssets[requestId][controller], PRICE_SCALE, price);
    }

    /// @inheritdoc IERC7540Redeem
    /// @dev Passing `requestId == 0` returns aggregate pending redeem shares for the current next epoch.
    function pendingRedeemRequest(uint256 requestId, address controller) public view override returns (uint256) {
        if (requestId == 0) return _pendingRedeemShares(controller);
        return epochPrice[requestId] == 0 ? _redeemShares[requestId][controller] : 0;
    }

    /// @inheritdoc IERC7540Redeem
    /// @dev Passing `requestId == 0` returns aggregate claimable redeem shares across settled epochs.
    function claimableRedeemRequest(uint256 requestId, address controller) public view override returns (uint256) {
        if (requestId == 0) return _claimableRedeemShares(controller);
        return epochPrice[requestId] == 0 ? 0 : _redeemShares[requestId][controller];
    }

    /// @inheritdoc ERC4626
    /// @dev Returns claimable shares valued at the latest settled price, not the vault's token balance.
    function totalAssets() public view override returns (uint256) {
        return convertToAssets(totalSupply());
    }

    /// @inheritdoc ERC4626
    /// @dev ERC7540 semantics: returns claimable deposit assets, not remaining request capacity.
    function maxDeposit(address controller) public view override returns (uint256) {
        return _claimableDepositAssets(controller);
    }

    /// @notice Returns remaining capacity for new async deposit requests.
    /// @dev This is separate from ERC7540 `maxDeposit`, which reports already claimable deposit assets.
    /// @return maxAssets Remaining deposit request capacity in asset units.
    function maxRequestDeposit(address) public view returns (uint256 maxAssets) {
        uint256 managedAssets = totalAssets() + pendingDepositAssets;
        return managedAssets < depositLimit ? depositLimit - managedAssets : 0;
    }

    /// @inheritdoc ERC4626
    /// @dev ERC7540 semantics: returns claimable shares available through `mint`.
    function maxMint(address receiver) public view override returns (uint256) {
        return _claimableDepositShares(receiver);
    }

    /// @inheritdoc ERC4626
    /// @dev ERC7540 claim function for caller-controlled deposit requests. Does not transfer assets.
    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        return deposit(assets, receiver, msg.sender);
    }

    /// @inheritdoc IERC7540Deposit
    /// @dev Claims settled deposit assets across claimable epochs, oldest epoch first. The `Deposit`
    /// event uses `controller` as its first argument as required by ERC7540.
    function deposit(uint256 assets, address receiver, address controller)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        _checkOperator(controller);
        if (assets == 0) revert ZeroAmount();

        uint256 remaining = assets;
        uint256 epoch = firstDepositRequest[controller];
        while (remaining != 0 && epoch <= currentEpoch) {
            uint256 claimable = _depositAssets[epoch][controller];
            if (claimable != 0 && epochPrice[epoch] != 0) {
                uint256 claimed = remaining < claimable ? remaining : claimable;
                _depositAssets[epoch][controller] = claimable - claimed;
                shares += Math.mulDiv(claimed, PRICE_SCALE, epochPrice[epoch]);
                remaining -= claimed;
            }
            epoch++;
        }

        if (remaining != 0 || shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        totalClaimableDepositShares -= shares;
        _advanceFirstDepositRequest(controller);
        _transfer(address(this), receiver, shares);

        emit Deposit(controller, receiver, assets, shares);
    }

    /// @inheritdoc ERC4626
    /// @dev ERC7540 claim function for caller-controlled deposit requests. Does not transfer assets.
    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        return mint(shares, receiver, msg.sender);
    }

    /// @inheritdoc IERC7540Deposit
    /// @dev Claims exact shares across claimable deposit epochs, oldest epoch first. Asset accounting uses
    /// rounding up on partial epoch claims so the remaining request cannot be overclaimed.
    function mint(uint256 shares, address receiver, address controller)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        _checkOperator(controller);
        if (shares == 0) revert ZeroAmount();

        uint256 remaining = shares;
        uint256 epoch = firstDepositRequest[controller];
        while (remaining != 0 && epoch <= currentEpoch) {
            uint256 price = epochPrice[epoch];
            uint256 claimableAssets = _depositAssets[epoch][controller];
            uint256 claimableShares = price == 0 ? 0 : Math.mulDiv(claimableAssets, PRICE_SCALE, price);
            if (claimableShares != 0) {
                if (remaining < claimableShares) {
                    uint256 claimedAssets = Math.mulDiv(remaining, price, PRICE_SCALE, Math.Rounding.Ceil);
                    _depositAssets[epoch][controller] = claimableAssets - claimedAssets;
                    assets += claimedAssets;
                    remaining = 0;
                    break;
                }
                _depositAssets[epoch][controller] = 0;
                assets += claimableAssets;
                remaining -= claimableShares;
            }
            epoch++;
        }

        if (remaining != 0 || assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        totalClaimableDepositShares -= shares;
        _advanceFirstDepositRequest(controller);
        _transfer(address(this), receiver, shares);

        emit Deposit(controller, receiver, assets, shares);
    }

    /// @inheritdoc ERC4626
    /// @dev ERC7540 claim function. Claims exact assets from settled redeem requests without transferring shares.
    /// Shares were already moved into this vault by `requestRedeem`.
    function withdraw(uint256 assets, address receiver, address controller)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        _checkOperator(controller);
        if (assets == 0) revert ZeroAmount();

        uint256 remaining = assets;
        uint256 accountedAssets;
        uint256 epoch = firstRedeemRequest[controller];
        while (remaining != 0 && epoch <= currentEpoch) {
            uint256 price = epochPrice[epoch];
            uint256 claimableShares = _redeemShares[epoch][controller];
            uint256 claimableAssets = price == 0 ? 0 : Math.mulDiv(claimableShares, price, PRICE_SCALE);
            if (claimableAssets != 0) {
                if (remaining < claimableAssets) {
                    uint256 claimedShares = Math.mulDiv(remaining, PRICE_SCALE, price, Math.Rounding.Ceil);
                    _redeemShares[epoch][controller] = claimableShares - claimedShares;
                    shares += claimedShares;
                    accountedAssets += Math.mulDiv(claimedShares, price, PRICE_SCALE);
                    remaining = 0;
                    break;
                }
                _redeemShares[epoch][controller] = 0;
                shares += claimableShares;
                accountedAssets += claimableAssets;
                remaining -= claimableAssets;
            }
            epoch++;
        }

        if (remaining != 0 || shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        totalClaimableRedeemAssets -= accountedAssets;
        _advanceFirstRedeemRequest(controller);
        IERC20(asset()).safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    /// @inheritdoc ERC4626
    /// @dev ERC7540 claim function. Claims assets for exact settled redeem shares, oldest epoch first.
    function redeem(uint256 shares, address receiver, address controller)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        _checkOperator(controller);
        return _claimRedeem(0, shares, receiver, controller);
    }

    /// @inheritdoc ERC4626
    /// @dev ERC7540 semantics: returns claimable redeem assets.
    function maxWithdraw(address controller) public view override returns (uint256) {
        return _claimableRedeemAssets(controller);
    }

    /// @inheritdoc ERC4626
    /// @dev ERC7540 semantics: returns claimable redeem shares.
    function maxRedeem(address controller) public view override returns (uint256) {
        return _claimableRedeemShares(controller);
    }

    /// @inheritdoc ERC4626
    /// @dev Required by ERC7540 async deposit semantics.
    function previewDeposit(uint256) public view override returns (uint256) {
        _revertAsyncDeposit();
        return 0;
    }

    /// @inheritdoc ERC4626
    /// @dev Required by ERC7540 async deposit semantics.
    function previewMint(uint256) public view override returns (uint256) {
        _revertAsyncDeposit();
        return 0;
    }

    /// @inheritdoc ERC4626
    /// @dev Required by ERC7540 async redeem semantics.
    function previewWithdraw(uint256) public view override returns (uint256) {
        _revertAsyncRedeem();
        return 0;
    }

    /// @inheritdoc ERC4626
    /// @dev Required by ERC7540 async redeem semantics.
    function previewRedeem(uint256) public view override returns (uint256) {
        _revertAsyncRedeem();
        return 0;
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        return Math.mulDiv(assets, PRICE_SCALE, sharePrice, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        return Math.mulDiv(shares, sharePrice, PRICE_SCALE, rounding);
    }

    function _nextRequestId() private view returns (uint256) {
        return currentEpoch + 1;
    }

    function _pendingDepositAssets(address controller) private view returns (uint256) {
        return _depositAssets[currentEpoch + 1][controller];
    }

    function _claimableDepositAssets(address controller) private view returns (uint256 assets) {
        uint256 epoch = firstDepositRequest[controller];
        while (epoch != 0 && epoch <= currentEpoch) {
            if (epochPrice[epoch] != 0) assets += _depositAssets[epoch][controller];
            epoch++;
        }
    }

    function _claimableDepositShares(address controller) private view returns (uint256 shares) {
        uint256 epoch = firstDepositRequest[controller];
        while (epoch != 0 && epoch <= currentEpoch) {
            uint256 price = epochPrice[epoch];
            if (price != 0) shares += Math.mulDiv(_depositAssets[epoch][controller], PRICE_SCALE, price);
            epoch++;
        }
    }

    function _pendingRedeemShares(address controller) private view returns (uint256) {
        return _redeemShares[currentEpoch + 1][controller];
    }

    function _claimableRedeemShares(address controller) private view returns (uint256 shares) {
        uint256 epoch = firstRedeemRequest[controller];
        while (epoch != 0 && epoch <= currentEpoch) {
            if (epochPrice[epoch] != 0) shares += _redeemShares[epoch][controller];
            epoch++;
        }
    }

    function _claimableRedeemAssets(address controller) private view returns (uint256 assets) {
        uint256 epoch = firstRedeemRequest[controller];
        while (epoch != 0 && epoch <= currentEpoch) {
            uint256 price = epochPrice[epoch];
            if (price != 0) assets += Math.mulDiv(_redeemShares[epoch][controller], price, PRICE_SCALE);
            epoch++;
        }
    }

    /// @notice Returns the ERC20 share token address required by ERC7575.
    /// @return shareTokenAddress This contract, because the vault and share token are the same address.
    function share() external view returns (address shareTokenAddress) {
        return address(this);
    }

    /// @notice ERC165 support for the async vault interfaces implemented by this contract.
    /// @param interfaceId Interface id being queried.
    /// @return supported True when `interfaceId` is one of ERC7540Deposit, ERC7540Redeem, ERC7540Operator,
    /// ERC7575, or ERC165.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC7540Deposit).interfaceId || interfaceId == type(IERC7540Redeem).interfaceId
            || interfaceId == type(IERC7540Operator).interfaceId || interfaceId == type(IERC7575).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    function _requestRedeem(uint256 requestId, address controller, address owner_, uint256 shares) private {
        _redeemShares[requestId][controller] += shares;
        _setFirstRedeemRequest(controller, requestId);
        epochRedeemShares[requestId] += shares;
        totalPendingRedeemShares += shares;
        emit RedeemRequest(controller, owner_, requestId, msg.sender, shares);
    }

    function _claimDeposit(uint256 requestId, uint256 assets, address receiver, address controller)
        private
        returns (uint256 shares)
    {
        _checkOperator(controller);
        if (assets == 0 || epochPrice[requestId] == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        _depositAssets[requestId][controller] -= assets;
        shares = Math.mulDiv(assets, PRICE_SCALE, epochPrice[requestId]);
        if (shares == 0) revert ZeroAmount();
        totalClaimableDepositShares -= shares;
        _advanceFirstDepositRequest(controller);
        _transfer(address(this), receiver, shares);

        emit Deposit(controller, receiver, assets, shares);
    }

    function _claimRedeem(uint256 requestId, uint256 shares, address receiver, address controller)
        private
        returns (uint256 assets)
    {
        _checkOperator(controller);
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        uint256 remaining = shares;
        uint256 epoch = requestId == 0 ? firstRedeemRequest[controller] : requestId;
        uint256 lastEpoch = requestId == 0 ? currentEpoch : requestId;
        while (remaining != 0 && epoch != 0 && epoch <= lastEpoch) {
            uint256 price = epochPrice[epoch];
            uint256 claimable = _redeemShares[epoch][controller];
            if (claimable != 0 && price != 0) {
                uint256 claimed = remaining < claimable ? remaining : claimable;
                _redeemShares[epoch][controller] = claimable - claimed;
                assets += Math.mulDiv(claimed, price, PRICE_SCALE);
                remaining -= claimed;
            }
            epoch++;
        }

        if (remaining != 0 || assets == 0) revert ZeroAmount();
        totalClaimableRedeemAssets -= assets;
        _advanceFirstRedeemRequest(controller);
        IERC20(asset()).safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    function _setFirstDepositRequest(address controller, uint256 requestId) private {
        uint256 first = firstDepositRequest[controller];
        if (first == 0 || requestId < first) firstDepositRequest[controller] = requestId;
    }

    function _setFirstRedeemRequest(address controller, uint256 requestId) private {
        uint256 first = firstRedeemRequest[controller];
        if (first == 0 || requestId < first) firstRedeemRequest[controller] = requestId;
    }

    function _advanceFirstDepositRequest(address controller) private {
        uint256 epoch = firstDepositRequest[controller];
        while (epoch != 0 && epoch <= currentEpoch && _depositAssets[epoch][controller] == 0) epoch++;
        firstDepositRequest[controller] = epoch != 0 && _depositAssets[epoch][controller] != 0 ? epoch : 0;
    }

    function _advanceFirstRedeemRequest(address controller) private {
        uint256 epoch = firstRedeemRequest[controller];
        while (epoch != 0 && epoch <= currentEpoch && _redeemShares[epoch][controller] == 0) epoch++;
        firstRedeemRequest[controller] = epoch != 0 && _redeemShares[epoch][controller] != 0 ? epoch : 0;
    }

    function _checkSharePrice(uint256 newSharePrice) private view {
        if (newSharePrice < MIN_SHARE_PRICE) revert InvalidSharePrice();

        uint256 minPrice = Math.mulDiv(sharePrice, BPS - MAX_PRICE_CHANGE_BPS, BPS);
        uint256 maxPrice = Math.mulDiv(sharePrice, BPS + MAX_PRICE_CHANGE_BPS, BPS);
        if (newSharePrice < minPrice || newSharePrice > maxPrice) revert PriceDeviationTooLarge();
    }

    function _settleAssets(uint256 redeemAssets) private {
        IERC20 token = IERC20(asset());
        uint256 balance = token.balanceOf(address(this));
        uint256 available = balance > totalClaimableRedeemAssets ? balance - totalClaimableRedeemAssets : 0;
        address vault = liquidityVault;

        if (available < redeemAssets) {
            token.safeTransferFrom(vault, address(this), redeemAssets - available);
        } else if (available > redeemAssets) {
            token.safeTransfer(vault, available - redeemAssets);
        }

        totalClaimableRedeemAssets += redeemAssets;
    }

    function _checkOperator(address controller) private view {
        if (msg.sender != controller && !isOperator[controller][msg.sender]) revert NotOperator();
    }

    // Keeps async preview reverts without triggering unreachable-code warnings in ERC4626.
    function _revertAsyncDeposit() private view {
        if (address(this) != address(0)) revert AsyncDeposit();
    }

    function _revertAsyncRedeem() private view {
        if (address(this) != address(0)) revert AsyncRedeem();
    }
}
