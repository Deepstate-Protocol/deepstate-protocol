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

The canonical deployment permanently locks 1 STATE at `address(0xdead)`, so its
total supply can never reach zero. The seed is created by depositing 1 DEEP,
which is literally burned; the resulting dead share is undelegated and carries
no voting power. It prevents dust-sized fresh accounting epochs and retains a
diminishing, permanently unclaimable pro-rata interest in vault assets.

The vault contract still resets `totalBurnedDepositAssets` when its supply
reaches zero so direct or noncanonical deployments can recover from an empty
epoch. That reset never restores DEEP; every deposited DEEP remains permanently
burned. Any fee asset omitted by a final redeemer stays in the vault and becomes
available to STATE holders in the next epoch.

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

## Controlled Minting

`DeepstateMinterController` is the operational DEEP minter. Governance grants
its `MINTER_ROLE` only to approved issuance contracts, such as
`DeepstateRewarderFactory`. For every requested mint `M`, the controller mints
`M` to the requested address and an additional `floor(30% * M)` to Sablier
Lockup v4.0.1. Each recipient allocation gets its own linear one-year stream.
The vesting recipient and Sablier contract are immutable constructor settings;
streams are non-cancelable and their NFTs are non-transferable.

The controller also has an immutable deployment-time live-supply cap. The
intended production value is 20,000,000,000 DEEP. Before every mint, the
controller checks the existing DEEP `totalSupply()` plus both the requested
amount and its additional 30% allocation. Burns reduce total supply and reopen
capacity below the cap. This is a controller-level soft cap: governance can
bypass it only by authorizing a different token-level minter after token
administration returns.

The 30% is additional issuance, not a split of `M`. A factory market therefore
receives its complete 100,000,000 DEEP initial funding while a separate
30,000,000 DEEP stream is created, for 130,000,000 DEEP total issuance. If a
market is retired, its unspent rewarder balance is burned, but the independent
recipient stream continues vesting.

This policy is enforceable only while `DeepstateMinterController` is the sole
operational holder of `DeepstateToken.MINTER_ROLE`. Governance must not grant
the token-level role directly to the factory or another minter that can bypass
the controller.

For the initial two-year issuance term, the controller temporarily holds
`DeepstateToken.DEFAULT_ADMIN_ROLE` while governance remains the controller's
owner. Governance calls `lockTokenAdministration()` only after granting the
token admin role to the controller. Locking also ensures the controller has the
token minter role. The controller owner may rotate during the term, but
administration cannot be unlocked early. At or after the exact two-year
deadline, anyone may call `unlockTokenAdministration()`. Unlocking grants the
token admin role to the controller's current owner before the controller
renounces it, preserving the token's final-admin invariant throughout the
transition. The controller owner receives
`DeepstateMinterController.MINTER_ROLE`; ownership transfers grant that role to
the new owner and revoke it from the previous owner. Every mint is therefore
authorized through the same role check, including owner mints.
The controller retains its ordinary token minter role until governance revokes
it after regaining token administration.

## Reward Schedule

The deployment creates one immutable rewarder for NVDA/USDG. Each side starts
its own finite clock when its first top order is reported. Empty books do not
pause a clock, and unearned emissions expire. DEEP/USDG receives no rewards.

Maximum cumulative emissions use a 30-day logarithmic time constant:

```text
C(t) = cap * ln(1 + t / 30 days) / ln(1 + duration / 30 days)
```

`t` is capped at the side's duration. The immutable allocations are:

| Pool | Per-side cap | Duration | Pool cap |
| --- | ---: | ---: | ---: |
| NVDA/USDG | 500,000,000 DEEP | 395 days | 1,000,000,000 DEEP |

The amount required for the full side budget grows geometrically for 30 days:

```text
Q(t) = Qstart * (Qmax / Qstart)^(min(t, 30 days) / 30 days)
```

| Sold token | Start | Day 30 and later | Raw units |
| --- | ---: | ---: | ---: |
| USDG | 1 | 1,000,000 | `1e6` to `1_000_000e6` |
| NVDA | 1 | 5,000 | `1e18` to `5_000e18` |

Displayed quantity below `Q(t)` earns linearly; quantity at or above it earns
100%. The contract integrates the moving target across the full reward interval
rather than sampling only entry or exit. Per-side cumulative accounting also
enforces the immutable cap independently of the token's role system.

The deployment pre-mints the complete 1,000,000,000 DEEP allocation into the
rewarder. Claims transfer from that fixed balance; the rewarder never receives
`DeepstateToken.MINTER_ROLE`. Unearned emissions remain locked in the rewarder.
Anyone can call `registerClaimant` for an active order to cache its engine-verified
reward recipient before `cancel` permanently deletes engine ownership. Registration
is permissionless, but the claimant always comes from Deepstate. `distributeRewards`
registers active orders lazily when necessary, and registered orders can claim
their final accrual after cancellation without wallet-level transaction batching.
An order deleted before either registration path permanently loses its claim.

`registerClaimants` caches one engine-verified claimant across multiple live
orders, while `distributeRewardsBatch` accrues multiple orders and aggregates
their payout into one DEEP transfer. Both batch paths revert atomically if a
resolved order belongs to a different claimant, so callers cannot redirect or
combine rewards belonging to different owners.

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

Production deployments use a required, versioned JSON configuration with no
fallback values. Start from `script/config/production.example.json` and review
every field. The example is configured for a Robinhood testnet rehearsal with
Paxos testnet USDG and a no-code NVDA stand-in; update the expected deployer and
use `--skip-market-token-validation` only for that rehearsal.

```bash
cp script/config/production.example.json deployments/production.json

export PRIVATE_KEY=...
export RPC_URL=https://rpc.testnet.chain.robinhood.com/
export BLOCKSCOUT_VERIFIER_URL=https://explorer.testnet.chain.robinhood.com/api/
export DEEPSTATE_DEPLOYMENT_CONFIG=deployments/production.json
export DEEPSTATE_DEPLOYMENT_OUTPUT=deployments/production-addresses.json

./script/deploy-production.sh
```

The entrypoint validates the chain, signer, token code and decimals, and all
configuration ranges and the Blockscout API before broadcasting. It then deploys
and configures the stack sequentially, requests Blockscout source verification,
reopens the final contracts through the live RPC, and writes a machine-readable
address manifest.
It fails unless Governor is the sole DEEP admin and final owner of the vault,
rewarder, and router, with no residual deployer authority.

See [`script/config/README.md`](script/config/README.md) for Robinhood mainnet and
testnet endpoints, the testnet-only `--skip-market-token-validation` rehearsal
flag, every parameter, validation rule, and manifest field. The flag bypasses
only the external market-token bytecode and decimals preflight; Blockscout
source verification of every newly deployed protocol contract still runs.
