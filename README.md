# Deepstate Vault

Foundry project for an OpenZeppelin ERC-4626/ERC20Votes share vault with a
permissionless fixed-price path for converting miscellaneous fee assets into
USDG.

## Contracts

- `DeepstateVault`: mints ERC-20 vault shares using ERC-4626 deposit/mint math over
  a burnable deposit token. Deposited tokens are transferred in, burned, and
  recorded as `totalBurnedDepositAssets`.
- `redeemValue`: burns shares for the holder's pro-rata amount of the value
  token, USDG.
- `redeemAssets`: burns shares for the holder's pro-rata amount of each
  explicitly listed ERC-20 balance and raw ETH balance. Raw ETH is represented
  by `address(0)`; DEEP, STATE, and duplicate entries are rejected.
- `buyFees`: lets anyone pay exactly 10,000 USDG directly to the vault for its
  complete balances of explicitly listed fee assets. Raw ETH is represented by
  `address(0)`; DEEP, STATE, USDG, and duplicate entries are rejected.

## ERC-4626 Note

ERC-4626 assumes one underlying asset for both deposit and withdrawal. This
vault intentionally has two assets: the burnable deposit/accounting token and
the value accrual token. The standard `deposit`, `mint`, preview, and conversion
math are preserved for the deposit token. Value redemption is explicit through
`redeemValue` / `previewRedeemValue`, while `redeemAssets` supports a
caller-supplied list of ERC-20 fee assets and raw ETH. Assets omitted from that
list stay in the vault even though the shares are burned. Integrators should
therefore enumerate every balance the holder intends to claim. `maxWithdraw`
and `maxRedeem` return zero; `maxRedeemValue` reports the separate value-token
redemption capacity.

When the final STATE share is burned, the vault resets
`totalBurnedDepositAssets` to zero and the next deposit begins a fresh 1:1
DEEP-to-STATE accounting epoch. This reset never restores DEEP; every deposited
DEEP remains permanently burned. Any fee asset omitted by the final redeemer
stays in the vault and becomes available to STATE holders in the next epoch.

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

## Fee Purchase Flow

1. Market fees or miscellaneous tokens land in the vault.
2. A buyer submits the fee-token addresses, minimum acceptable vault balances,
   and a receiver to `buyFees`. The caller-supplied list is necessary because
   ERC-20 balances are not enumerable on-chain.
3. The vault snapshots each listed balance, rejects protected or duplicate
   entries, and collects exactly 10,000 USDG from the buyer. Fee-on-transfer
   USDG payments are rejected.
4. The receiver gets each listed asset's complete snapshotted balance. Unlisted
   assets remain in the vault, and the USDG payment becomes redeemable pro-rata
   by STATE holders.

The minimum amounts protect a buyer from a prior purchase or STATE redemption
reducing the quoted balances before execution. Native ETH uses `address(0)`.
There is no auction timer, privileged sweep, wrapped-native conversion, or
separate custody contract.

## Commands

```bash
forge build
forge test
```

## Deployment

`script/DeployDeepstate.s.sol` deploys the core stack and both rewarders,
enables both pool hooks, grants the Governor `DeepstateToken`'s default admin
role, and transfers ownership of the vault, both rewarders, and `DeepstateV1`
to `DeepstateGovernor`. Both rewarders receive `MINTER_ROLE`; an optional
additional minter may be configured for a separate emissions path.

Required environment variables:

```bash
export PRIVATE_KEY=...
export VALUE_TOKEN=0x... # USDG, required to report 6 decimals
export NVDA_TOKEN=0x...  # NVDA, required to report 18 decimals
```

Optional environment variables include `ROUTER_FEE_BPS` (10 bps by default),
`DEEP_MINTER`, and the `GOVERNOR_*` governance parameters. The launch parameters are
`GOVERNOR_START_DELAY`, `GOVERNOR_VOTING_DELAY`,
`GOVERNOR_VOTING_PERIOD`, `GOVERNOR_PROPOSAL_THRESHOLD_NUMERATOR`,
`GOVERNOR_QUORUM_NUMERATOR`, and `GOVERNOR_VOTE_EXTENSION`.

```bash
forge script script/DeployDeepstate.s.sol:DeployDeepstate \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --verify
```
