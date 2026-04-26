# HedgeFundCore

- `HedgeFund`: a compact ERC4626 vault share token.

The owner, expected to be the Safe multisig, reports a target share price that already includes all off-chain accounting and fees.

Key mechanics:

- **Immediate entry**: `deposit` and `mint` mint shares at the current effective `sharePrice()`, then forward assets to the owner Safe.
- **Configurable price vesting**: positive price updates vest linearly over the seconds passed to `setSharePrice`. Price decreases apply immediately.
- **Async-only exit**: `withdraw` and `redeem` are disabled. Users exit with `requestRedeem`, which burns shares and fixes the assets owed.
- **Off-chain accounting**: owner updates the target price with `setSharePrice(newSharePrice, vestingSeconds)`, scaled by `1e18`.
- **Redeem**: pending redemptions are tracked by `pendingRedeemAssets[account]`.
- **Claim funding**: the owner Safe funds the vault before users call `claimRedeem`.

## User Flows

### Deposit

Users enter through the standard ERC4626 `deposit(assets, receiver)` or `mint(shares, receiver)` functions.

The vault uses the current effective `sharePrice()` to calculate the share amount. Assets are transferred directly from the user to the owner Safe, and shares are minted to `receiver` in the same transaction.

Example:

```text
user -> deposit(assets, receiver)
vault -> calculates shares at sharePrice()
asset -> moves user to owner Safe
shares -> mint to receiver
```

### Redeem Request

Synchronous ERC4626 exits are disabled: `maxWithdraw()` and `maxRedeem()` return `0`, so `withdraw()` and `redeem()` revert.

Users exit with `requestRedeem(shares)`. The vault converts shares to assets at the current effective `sharePrice()`, burns the shares immediately, and stores the fixed asset amount in `pendingRedeemAssets[user]`.

After `requestRedeem`, the user no longer holds those shares and does not receive future price increases on them.

Example:

```text
user -> requestRedeem(shares)
vault -> assets = previewRedeem(shares)
shares -> burn from user
pendingRedeemAssets[user] += assets
totalPendingRedeemAssets += assets
```

### Claim Redeem

`requestRedeem` only records the amount owed. It does not transfer assets immediately.

The owner Safe should monitor `totalPendingRedeemAssets` and send enough asset tokens to the vault. Once funded, users call `claimRedeem()` to receive their fixed pending amount.

Example:

```text
owner Safe -> transfers totalPendingRedeemAssets to vault
user -> claimRedeem()
vault -> transfers pendingRedeemAssets[user] to user
pendingRedeemAssets[user] = 0
```

## Development

```bash
forge test
```

## Deployment

```bash
export HEDGE_FUND_OWNER=0xSafeMultisig
export HEDGE_FUND_ASSET=0xTokenAsset
export HEDGE_FUND_SHARE_NAME="Altitude Hedge Fund Share"
export HEDGE_FUND_SHARE_SYMBOL="AHFS"

forge script script/DeployHedgeFund.s.sol:DeployHedgeFund \
  --rpc-url $RPC_URL \
  --private-key $DEPLOYER_KEY \
  --broadcast
```
