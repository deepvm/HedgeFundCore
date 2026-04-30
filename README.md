# HedgeFundCore

`HedgeFund` is a small async vault for USDT-like assets.

Users do not get shares immediately after sending USDT. They create a deposit request, wait until the owner settles the next epoch price, and then claim shares. Exits work the same way: users lock shares with a redeem request, wait for the next settled price, and then claim USDT.

The contract is built around the ERC-7540 request flow, but it stays much smaller than full products like Lagoon or Centrifuge. There are no external managers, whitelist modules, upgradeable proxy stack, or NFT positions.

## Roles

`owner` is expected to be the Safe multisig. It sets the epoch price and can update the deposit limit and liquidity vault.

`liquidityVault` is the address that receives extra USDT after settlement and funds redemption deficits. It defaults to `owner`, but can be changed with `setLiquidityVault`.

Surplus USDT is pull-based: settlement records it in `pendingLiquidityAssets`, and `liquidityVault` claims it with `claimLiquidityAssets()`. This keeps settlement from failing just because the surplus receiver cannot accept a transfer at that moment.

Users control their own requests. They can also approve an ERC-7540 operator with `setOperator`.

Operators can claim and redeem on behalf of a user, but they cannot initiate a deposit that pulls the user's USDT. Deposits must be started by the token owner.

## How Deposits Work

A user calls:

```solidity
requestDeposit(assets)
```

The USDT moves into the contract, but no shares are minted yet. The request goes into `currentEpoch + 1`.

When the owner later calls:

```solidity
settleEpoch(newSharePrice)
```

the contract converts all deposit requests from that epoch into claimable shares using the new price. The user can then claim shares with:

```solidity
deposit(assets, receiver)
mint(shares, receiver)
```

Claiming is optional. If a user does not need the ERC20 shares in their wallet, the shares can stay claimable inside the vault.

Before settlement, a pending deposit can be canceled:

```solidity
cancelDepositRequest(requestId)
```

For new deposit capacity, use:

```solidity
maxRequestDeposit(account)
```

In ERC-7540 style, `maxDeposit` and `maxMint` mean "already claimable after settlement", not "how much can I request now".

## How Redeems Work

A user with shares calls:

```solidity
requestRedeem(shares)
```

The shares move into the vault and wait for the next epoch price. After settlement, the user claims USDT with:

```solidity
redeem(shares, receiver, controller)
withdraw(assets, receiver, controller)
```

There is also a shortcut for users who deposited, waited for settlement, but never claimed their shares:

```solidity
requestRedeemClaimableDeposit(depositRequestId, shares)
```

This lets them request a redeem from claimable shares without first moving those shares to their wallet.

Before settlement, a pending redeem can be canceled:

```solidity
cancelRedeemRequest(requestId)
```

## Settlement

Epochs have no fixed on-chain duration. The owner settles whenever off-chain NAV is ready.

Empty epochs cannot be settled. There must be at least one pending deposit or redeem request.

During settlement the contract:

1. records the new share price;
2. turns pending deposits into claimable shares;
3. turns pending redeems into claimable USDT;
4. burns shares that were locked for redeem;
5. keeps enough USDT in the contract for claims;
6. records surplus USDT for `liquidityVault`;
7. pulls missing USDT from `liquidityVault` if redemptions are larger than the contract balance.

If the vault needs to pull USDT, `liquidityVault` must approve the HedgeFund contract before settlement.

If settlement leaves surplus USDT, `liquidityVault` later calls:

```solidity
claimLiquidityAssets()
```

## Price

The owner reports one price per settled epoch:

```solidity
settleEpoch(newSharePrice)
```

`newSharePrice` is scaled by `1e18`.

The price is not fixed when a user makes a request. It is fixed when the owner settles that request's epoch.

All requests in the same epoch use the same price.

There is a simple on-chain sanity check around the reported price:

- price must be at least `MIN_SHARE_PRICE`;
- price cannot move by more than `MAX_PRICE_CHANGE_BPS` from the last settled price.

These checks catch bad inputs such as `1` instead of `1e18` and keep each epoch price close to the previous settled price.

## Standards

The contract inherits OpenZeppelin `ERC4626` and implements the ERC-7540 deposit/redeem request interfaces from `forge-std`.

The normal ERC-4626 preview functions revert because this is an async vault:

```solidity
previewDeposit
previewMint
previewWithdraw
previewRedeem
```

`share()` returns the vault address itself, which is the ERC20 share token.

## Asset Assumptions

The asset should be a plain ERC20 like USDT:

- no transfer fee;
- no rebasing;
- no unexpected balance changes.

## Implementation Details

The contract uses OpenZeppelin `ReentrancyGuard` on request, settlement, and claim paths.

Rounding is intentionally conservative:

- deposit claims round shares down;
- mint claims consume assets rounded up;
- redeem claims round assets down;
- withdraw claims burn shares rounded up.

Tiny rounding dust stays in the vault and can later be sent as surplus to `liquidityVault` during settlement.

The contract tracks each controller's active request epochs directly, so claims do not scan through unrelated epochs created by other users.

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
