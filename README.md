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
timestamp clock. Proposal creation is disabled for the first 15 days after
deployment. After launch, the defaults are a three-day voting delay, one-week
voting period, one-day late-quorum extension, 10% quorum, and a proposal
threshold equal to 1% of the prior timestamp's STATE supply, rounded up. The
earliest launch proposal can therefore finish at day 25.

The deployment deliberately does not install a timelock. The Governor remains
the direct owner and executor for the vault, rewarder, and router. Successful
proposals can therefore execute immediately after voting ends.

## Reward Schedule

The deployment creates one immutable rewarder for NVDA/USDG and one for
DEEP/USDG. Each side starts its own finite clock when its first top order is
reported. Empty books do not pause a clock, and unearned emissions expire.

Maximum cumulative emissions use a 30-day logarithmic time constant:

```text
C(t) = cap * ln(1 + t / 30 days) / ln(1 + duration / 30 days)
```

`t` is capped at the side's duration. The immutable allocations are:

| Pool | Per-side cap | Duration | Pool cap |
| --- | ---: | ---: | ---: |
| NVDA/USDG | 500,000,000 DEEP | 395 days | 1,000,000,000 DEEP |
| DEEP/USDG | 250,000,000 DEEP | 60 days | 500,000,000 DEEP |

The amount required for the full side budget grows geometrically for 30 days:

```text
Q(t) = Qstart * (Qmax / Qstart)^(min(t, 30 days) / 30 days)
```

| Sold token | Start | Day 30 and later | Raw units |
| --- | ---: | ---: | ---: |
| USDG | 1 | 1,000,000 | `1e6` to `1_000_000e6` |
| NVDA | 1 | 5,000 | `1e18` to `5_000e18` |
| DEEP | 1 | 1,000,000 | `1e18` to `1_000_000e18` |

Displayed quantity below `Q(t)` earns linearly; quantity at or above it earns
100%. The contract integrates the moving target across the full reward interval
rather than sampling only entry or exit. Per-side cumulative accounting also
enforces the immutable cap independently of the token's role system.

Rewarders mint DEEP directly to order owners at claim time and each holds a
revocable `DeepstateToken.MINTER_ROLE`. Governance may revoke either role.
Anyone can call `registerClaimant` for an active order to cache its engine-verified
reward recipient before `cancel` permanently deletes engine ownership. Registration
is permissionless, but the claimant always comes from Deepstate. `distributeRewards`
registers active orders lazily when necessary, and registered orders can claim
their final accrual after cancellation without wallet-level transaction batching.
An order deleted before either registration path permanently loses its claim.

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

`script/DeployDeepstate.s.sol` deploys the core stack and both rewarders,
configures the vault's Fee Flow auction, enables both pool hooks, grants the
Governor `DeepstateToken`'s default admin role, and transfers ownership of the
vault, both rewarders, and `DeepstateV1` to `DeepstateGovernor`. Both rewarders
receive `MINTER_ROLE`; an optional additional minter may be configured for a
separate emissions path.

Required environment variables:

```bash
export PRIVATE_KEY=...
export VALUE_TOKEN=0x... # USDG, required to report 6 decimals
export NVDA_TOKEN=0x...  # NVDA, required to report 18 decimals
```

Optional environment variables include `ROUTER_FEE_BPS` (10 bps by default), `DEEP_MINTER`,
`WRAPPED_NATIVE`, the `FEE_FLOW_*` auction parameters, and the `GOVERNOR_*`
governance parameters. The launch parameters are
`GOVERNOR_START_DELAY`, `GOVERNOR_VOTING_DELAY`,
`GOVERNOR_VOTING_PERIOD`, `GOVERNOR_PROPOSAL_THRESHOLD_NUMERATOR`,
`GOVERNOR_QUORUM_NUMERATOR`, and `GOVERNOR_VOTE_EXTENSION`. Set
`WRAPPED_NATIVE` to WETH on networks where native sweeping should be enabled.

```bash
forge script script/DeployDeepstate.s.sol:DeployDeepstate \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --verify
```
