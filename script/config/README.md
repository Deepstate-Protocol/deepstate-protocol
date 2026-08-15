# Production Deployment Configuration

`production.example.json` contains every constructor argument and mutable launch
setting exposed by the current contract set. There are no deployment defaults.
Copy it into `deployments/`, replace every placeholder, and commit or archive the
reviewed configuration separately from the private key.

## Deployment Identity

- `deployment.expectedChainId` must equal the RPC chain id.
- `deployment.expectedDeployer` must be the address derived from `PRIVATE_KEY`.
- The deployer is temporary. It finishes with no DEEP admin or minter role and
  no ownership over the vault, rewarder, or router.

## External Tokens

- `externalTokens.valueToken` is the USDG-compatible vault payout and router-fee
  token. Its configured and onchain decimals must both be 6 because the vault's
  fixed fee-purchase price is denominated in 6-decimal units.
- `externalTokens.marketToken` is the other token in the incentivized pool.
- `marketTokenDecimals` is verified onchain. Reward quantities remain raw token
  units, so the quantity schedule must be scaled for these decimals.
- For a deployment-only Robinhood testnet rehearsal, pass
  `--skip-market-token-validation` to permit a stand-in market-token address with
  no testnet bytecode. The bypass skips only market-token code and decimals
  validation, is rejected outside chain `46630`, and is recorded in the output
  manifest. The value token must still be a deployed 6-decimal contract because
  the vault constructor calls `decimals()`; use Paxos testnet USDG at
  `0x7E955252E15c84f5768B83c41a71F9eba181802F`.

## DEEP And STATE

- `deepToken.name` and `deepToken.symbol` configure the 18-decimal deposit token.
- `deepToken.initialMinters` is the complete set of non-governance minters granted
  at launch. Zero addresses, duplicates, and the deployer are rejected. An empty
  array launches without an active emissions authority; Governor can grant one.
- `vault.name` and `vault.symbol` configure the 18-decimal ERC-4626 and ERC20Votes
  share token. The deposit asset is the newly deployed DEEP token and the value
  asset is `externalTokens.valueToken`.

## Router

- `router.feeBps` is capped at 100 basis points by `DeepstateV1`.
- Set `useVaultAsFeeRecipient` to `true` and `feeRecipient` to the zero address to
  route protocol fees to STATE holders.
- Set `useVaultAsFeeRecipient` to `false` to use the exact `feeRecipient` address.
  A zero recipient is valid only when `feeBps` is also zero.

## Governance

All time values are seconds and use STATE's timestamp clock.

- `startDelay` is the bootstrap period before proposals can be created.
- `votingDelay` must be from 1 through 30 days.
- `votingPeriod` must be from 1 through 30 days.
- `proposalThresholdNumerator` and `quorumNumerator` are percentages over 100;
  each must be from 1 through 100.
- `voteExtension` may be zero and cannot exceed 7 days.

The current Governor executes successful proposals directly and has no timelock.

## Rewarder

- `sideEmissionCap` is the maximum DEEP owed to each side of the book.
- `initialFunding` must equal exactly twice `sideEmissionCap`. The rewarder is
  prefunded and is never granted `MINTER_ROLE`; exact funding avoids insolvency
  and permanently stranded excess tokens.
- `emissionDuration` is in seconds and must be at least the 30-day quantity ramp.
- `marketStartQuantity` and `marketMaxQuantity` define the full-reward schedule
  for the market token in raw units.
- `valueStartQuantity` and `valueMaxQuantity` define the same schedule for the
  value token in raw units.
- Each maximum must be at least 1,000 times its nonzero starting quantity.
- `marketBuySideActive` rewards top orders buying the market token.
- `valueBuySideActive` rewards top orders buying the value token. The script maps
  these economic sides to the router's address-sorted token flags.

## Verification And Output

Run `script/deploy-production.sh` with `PRIVATE_KEY`, `RPC_URL`,
`BLOCKSCOUT_VERIFIER_URL`, `DEEPSTATE_DEPLOYMENT_CONFIG`, and
`DEEPSTATE_DEPLOYMENT_OUTPUT` set. Verification is explicitly submitted through
Foundry's `blockscout` provider. Robinhood's official network values are:

| Network | Chain ID | RPC URL | `BLOCKSCOUT_VERIFIER_URL` |
| --- | ---: | --- | --- |
| Robinhood Chain | `4663` | `https://rpc.mainnet.chain.robinhood.com/` | `https://robinhoodchain.blockscout.com/api/` |
| Robinhood Chain Testnet | `46630` | `https://rpc.testnet.chain.robinhood.com/` | `https://explorer.testnet.chain.robinhood.com/api/` |

Blockscout does not require an API key. If Robinhood enables authenticated API
access later, set the optional `BLOCKSCOUT_API_KEY`; the wrapper forwards it as
Foundry's `--verifier-api-key`. Do not pass verifier flags directly because the
wrapper rejects them to prevent an accidental non-Blockscout deployment.

For testnet:

```bash
read -rsp "Deployer private key: " PRIVATE_KEY
echo
export PRIVATE_KEY
export RPC_URL="https://rpc.testnet.chain.robinhood.com/"
export BLOCKSCOUT_VERIFIER_URL="https://explorer.testnet.chain.robinhood.com/api/"
export DEEPSTATE_DEPLOYMENT_CONFIG="$PWD/deployments/production.json"
export DEEPSTATE_DEPLOYMENT_OUTPUT="$PWD/deployments/production-addresses.json"

./script/deploy-production.sh --skip-market-token-validation
unset PRIVATE_KEY
```

The output JSON binds the deployed addresses to the exact configuration-file
hash and chain id. It includes DEEP, STATE, Governor, router, rewarder, external
tokens, sorted pool tokens, pool id, fee recipient, governance start, verification
block, verification timestamp, and whether market-token validation was skipped.
The shell command prints this address list
only after Blockscout source verification and live state verification succeed.
Before broadcasting, the wrapper also probes the configured Blockscout API and
fails if the endpoint is malformed, unavailable, or does not return an API result.
