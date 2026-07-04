# Nigiri Vault

Foundry project for a Solady-based share vault with an Euler Fee Flow-style
Dutch auction for converting miscellaneous fee assets into a single value token.

## Contracts

- `NigiriVault`: mints ERC-20 vault shares using ERC-4626 deposit/mint math over
  a burnable deposit token. Deposited tokens are transferred in, burned, and
  recorded as `totalBurnedDepositAssets`.
- `redeemValue`: burns shares for the holder's pro-rata amount of the value
  token, such as USDC.
- `FeeFlowController`: imported from Euler Labs' Fee Flow git dependency.
  Buyers pay the value token to the vault and receive the controller's full
  balances of selected ERC-20 fee assets.

## ERC-4626 Note

ERC-4626 assumes one underlying asset for both deposit and withdrawal. This
vault intentionally has two assets: the burnable deposit/accounting token and
the value accrual token. The standard `deposit`, `mint`, preview, and conversion
math are preserved for the deposit token. Value redemption is explicit through
`redeemValue` / `previewRedeemValue` so integrators do not mistake USDC
redemption for returning the burned deposit token.

## Auction Flow

1. Market fees or miscellaneous tokens land in the vault.
2. The owner calls `sweepToAuction` and/or `sweepNativeToAuction`.
   Raw ETH is wrapped to WETH before being sent to Euler Fee Flow because the
   controller auctions ERC-20 balances.
3. A buyer calls `buy` on `FeeFlowController`, paying the current Dutch auction
   price in the value token to the vault.
4. The buyer receives the listed auctioned assets, and the new value token
   balance becomes redeemable pro-rata by vault share holders.

## Commands

```bash
forge build
forge test
```

## Deployment

`script/DeployNigiri.s.sol` deploys the core stack, configures the vault's
Fee Flow auction, and transfers ownership of `NigiriToken`, `NigiriVault`,
`NigiriRewarder`, and `RoutingEngine` to `NigiriGovernor`.

Required environment variables:

```bash
export PRIVATE_KEY=...
export VALUE_TOKEN=0x... # USDC or the value accrual token
```

Optional environment variables include `ROUTER_FEE_BPS`, `NIGIRI_MINTER`,
`REWARD_TOKEN`, `WRAPPED_NATIVE`, the `FEE_FLOW_*` auction parameters, and the
`GOVERNOR_*` governance parameters. Set `WRAPPED_NATIVE` to WETH on networks
where native sweeping should be enabled.

```bash
forge script script/DeployNigiri.s.sol:DeployNigiri \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --verify
```
