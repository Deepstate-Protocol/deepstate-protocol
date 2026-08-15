#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_TARGET="script/DeployDeepstate.s.sol:DeployDeepstate"

require_env() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        printf 'Missing required environment variable: %s\n' "$name" >&2
        exit 1
    fi
}

require_command() {
    local name="$1"
    if ! command -v "$name" >/dev/null 2>&1; then
        printf 'Missing required command: %s\n' "$name" >&2
        exit 1
    fi
}

require_command forge
require_command curl

require_env PRIVATE_KEY
require_env RPC_URL
require_env BLOCKSCOUT_VERIFIER_URL
require_env DEEPSTATE_DEPLOYMENT_CONFIG
require_env DEEPSTATE_DEPLOYMENT_OUTPUT

skip_market_token_validation=false
forge_args=()
for arg in "$@"; do
    case "$arg" in
        --skip-market-token-validation)
            skip_market_token_validation=true
            ;;
        *)
            forge_args+=("$arg")
            ;;
    esac
done
if (( ${#forge_args[@]} == 0 )); then
    set --
else
    set -- "${forge_args[@]}"
fi

if [[ "$skip_market_token_validation" == "true" ]]; then
    export DEEPSTATE_SKIP_MARKET_TOKEN_VALIDATION=true
    printf 'WARNING: market-token bytecode and decimals validation is disabled for this testnet deployment.\n' >&2
else
    export DEEPSTATE_SKIP_MARKET_TOKEN_VALIDATION=false
fi

case "$BLOCKSCOUT_VERIFIER_URL" in
    https://*/api | https://*/api/) ;;
    *)
        printf 'BLOCKSCOUT_VERIFIER_URL must be an HTTPS Blockscout API URL ending in /api/: %s\n' \
            "$BLOCKSCOUT_VERIFIER_URL" >&2
        exit 1
        ;;
esac

# Foundry and Blockscout both document the trailing slash form. Normalize it so
# verification and the preflight request always target the same endpoint.
BLOCKSCOUT_VERIFIER_URL="${BLOCKSCOUT_VERIFIER_URL%/}/"

for arg in "$@"; do
    case "$arg" in
        --verifier | --verifier=* | --verifier-url | --verifier-url=* | \
            --verifier-api-key | --verifier-api-key=* | --etherscan-api-key | --etherscan-api-key=*)
            printf 'Verifier arguments are configured through BLOCKSCOUT_VERIFIER_URL and BLOCKSCOUT_API_KEY.\n' >&2
            exit 1
            ;;
    esac
done

cd "$ROOT_DIR"

if [[ ! -f "$DEEPSTATE_DEPLOYMENT_CONFIG" ]]; then
    printf 'Deployment config does not exist: %s\n' "$DEEPSTATE_DEPLOYMENT_CONFIG" >&2
    exit 1
fi

mkdir -p "$(dirname "$DEEPSTATE_DEPLOYMENT_OUTPUT")"

probe_url="${BLOCKSCOUT_VERIFIER_URL}?module=block&action=eth_block_number"
if ! probe_response="$(curl --fail --silent --show-error --max-time 15 "$probe_url")"; then
    printf 'Blockscout verifier is unreachable: %s\n' "$BLOCKSCOUT_VERIFIER_URL" >&2
    exit 1
fi
if [[ "$probe_response" != *'"result"'* ]]; then
    printf 'Blockscout verifier returned an unexpected API response: %s\n' "$BLOCKSCOUT_VERIFIER_URL" >&2
    exit 1
fi

verifier_args=(
    --verifier blockscout
    --verifier-url "$BLOCKSCOUT_VERIFIER_URL"
)
if [[ -n "${BLOCKSCOUT_API_KEY:-}" ]]; then
    verifier_args+=(--verifier-api-key "$BLOCKSCOUT_API_KEY")
fi

forge script "$SCRIPT_TARGET" \
    --sig "run()" \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --verify \
    --slow \
    --gas-estimate-multiplier 200 \
    --non-interactive \
    "${verifier_args[@]}" \
    "$@"

# Re-open the deployment through the live RPC. This catches a successful broadcast
# whose final roles, ownership, funding, hooks, fees, or constructor values are wrong.
forge script "$SCRIPT_TARGET" \
    --sig "verify()" \
    --rpc-url "$RPC_URL" \
    --non-interactive

printf '\nVerified Deepstate address manifest:\n'
sed -n '1,240p' "$DEEPSTATE_DEPLOYMENT_OUTPUT"
