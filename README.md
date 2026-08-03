# Deepstate Vault

Foundry project for an OpenZeppelin ERC-4626/ERC20Votes share vault with an
Euler Fee Flow-style Dutch auction for converting miscellaneous fee assets into
a single value token.

## Contracts

- `DeepstateVault`: mints ERC-20 vault shares using ERC-4626 deposit/mint math over
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
redemption for returning the burned deposit token. `maxWithdraw` and
`maxRedeem` therefore return zero; `maxRedeemValue` reports the separate value
redemption capacity.

## Governance Clock

STATE and `DeepstateGovernor` use ERC-6372 timestamp checkpoints. Governor
delay, period, and late-quorum extension settings are denominated in seconds.
The Governor constructor rejects voting tokens that do not expose the expected
timestamp clock. Proposal creation is disabled for the first 25 days after
deployment. After launch, the defaults are a three-day voting delay, one-week
voting period, one-day late-quorum extension, 10% quorum, and a proposal
threshold equal to 1% of the prior timestamp's STATE supply, rounded up.

The deployment deliberately does not install a timelock. The Governor remains
the direct owner and executor for the vault, rewarder, and router. Successful
proposals can therefore execute immediately after voting ends.

## Reward Schedule

One immutable `DeepstateRewarder` is deployed per pool. The first 30 days emit
an amount equal to the configured initial supply on a smooth curve, followed by
100% year-over-year inflation. Accounting stops after 100 annual periods to
bound exponential arithmetic. Each rewarder receives an immutable fraction of
the global schedule and divides that pool budget equally between both sides of
the book.

The first observed quantity receives 100% of its side's scheduled budget. Later
amounts are compared with a seven-day, time-weighted EMA: matching the reference
receives 50%, 2x receives 80%, and 3x receives 90%. Same-block transitions do
not move the reference. The multiplier is unitless and never exceeds 100%, so
different token decimal scales require no execute-time normalization. Pool
allocation fractions across all deployed rewarders must sum to at most `1e18`.
Rewarders mint accrued DEEP directly to order owners at claim time. Each
rewarder must hold `DeepstateToken.MINTER_ROLE`; governance administers that
role and can freeze future claims from a rewarder by revoking it. The token does
not enforce the aggregate rewarder allocation, so deployment review must still
verify that all active rewarder shares sum to no more than the global schedule.

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

`script/DeployDeepstate.s.sol` deploys the core stack, configures the vault's
Fee Flow auction, grants the Governor `DeepstateToken`'s default admin role, and
transfers ownership of `DeepstateVault`, `DeepstateRewarder`, and `DeepstateV1`
to `DeepstateGovernor`. The deployed rewarder receives `MINTER_ROLE`; an
optional additional minter may be configured for a separate emissions path.

Required environment variables:

```bash
export PRIVATE_KEY=...
export VALUE_TOKEN=0x... # USDC or the value accrual token
export REWARD_INITIAL_SUPPLY=... # DEEP supply baseline in token base units
```

Optional environment variables include `ROUTER_FEE_BPS`, `DEEP_MINTER`,
`WRAPPED_NATIVE`, the `FEE_FLOW_*` auction parameters, and the `GOVERNOR_*`
governance parameters. The launch parameters are
`GOVERNOR_START_DELAY`, `GOVERNOR_VOTING_DELAY`,
`GOVERNOR_VOTING_PERIOD`, `GOVERNOR_PROPOSAL_THRESHOLD_NUMERATOR`,
`GOVERNOR_QUORUM_NUMERATOR`, and `GOVERNOR_VOTE_EXTENSION`.
`REWARD_EMISSION_START` defaults to the deployment timestamp and
`REWARD_POOL_SHARE_WAD` defaults to `1e18`. Set `WRAPPED_NATIVE` to WETH on
networks where native sweeping should be enabled.

```bash
forge script script/DeployDeepstate.s.sol:DeployDeepstate \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --verify
```
