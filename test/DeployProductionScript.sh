#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin"

cat > "$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${FAKE_CURL_FAIL:-0}" == "1" ]]; then
    exit 22
fi
if [[ "${FAKE_CURL_INVALID_RESPONSE:-0}" == "1" ]]; then
    printf '{"status":"0"}\n'
    exit 0
fi
printf '{"jsonrpc":"2.0","result":"0x1","id":1}\n'
EOF

cat > "$TMP_DIR/bin/forge" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
{
    printf 'CALL\n'
    printf 'ENV_SKIP_MARKET_TOKEN_VALIDATION=%s\n' "${DEEPSTATE_SKIP_MARKET_TOKEN_VALIDATION:-}"
    for arg in "$@"; do
        printf 'ARG=%s\n' "$arg"
    done
} >> "$FAKE_FORGE_LOG"
EOF

chmod +x "$TMP_DIR/bin/curl" "$TMP_DIR/bin/forge"

export PATH="$TMP_DIR/bin:$PATH"
export FAKE_FORGE_LOG="$TMP_DIR/forge.log"
export PRIVATE_KEY=1
export RPC_URL="https://rpc.testnet.chain.robinhood.com/"
export BLOCKSCOUT_VERIFIER_URL="https://explorer.testnet.chain.robinhood.com/api"
export BLOCKSCOUT_API_KEY="optional-test-key"
export DEEPSTATE_DEPLOYMENT_CONFIG="$ROOT_DIR/script/config/production.example.json"
export DEEPSTATE_DEPLOYMENT_OUTPUT="$TMP_DIR/addresses.json"

printf '{}\n' > "$DEEPSTATE_DEPLOYMENT_OUTPUT"

"$ROOT_DIR/script/deploy-production.sh" --skip-market-token-validation >/dev/null 2>&1
[[ "$(grep -c '^CALL$' "$FAKE_FORGE_LOG")" == "2" ]]
grep -Fxq 'ENV_SKIP_MARKET_TOKEN_VALIDATION=true' "$FAKE_FORGE_LOG"

: > "$FAKE_FORGE_LOG"
"$ROOT_DIR/script/deploy-production.sh" --skip-market-token-validation --legacy >/dev/null 2>&1

[[ "$(grep -c '^CALL$' "$FAKE_FORGE_LOG")" == "2" ]]
grep -Fxq 'ARG=--verify' "$FAKE_FORGE_LOG"
grep -Fxq 'ARG=--verifier' "$FAKE_FORGE_LOG"
grep -Fxq 'ARG=blockscout' "$FAKE_FORGE_LOG"
grep -Fxq 'ARG=--verifier-url' "$FAKE_FORGE_LOG"
grep -Fxq 'ARG=https://explorer.testnet.chain.robinhood.com/api/' "$FAKE_FORGE_LOG"
grep -Fxq 'ARG=--verifier-api-key' "$FAKE_FORGE_LOG"
grep -Fxq 'ARG=optional-test-key' "$FAKE_FORGE_LOG"
grep -Fxq 'ARG=--legacy' "$FAKE_FORGE_LOG"
grep -Fxq 'ENV_SKIP_MARKET_TOKEN_VALIDATION=true' "$FAKE_FORGE_LOG"
if grep -Fxq 'ARG=--skip-market-token-validation' "$FAKE_FORGE_LOG"; then
    printf 'Test-only wrapper flag leaked into Forge arguments\n' >&2
    exit 1
fi

calls_before="$(grep -c '^CALL$' "$FAKE_FORGE_LOG")"

if "$ROOT_DIR/script/deploy-production.sh" --verifier sourcify >/dev/null 2>&1; then
    printf 'Expected direct verifier override to fail\n' >&2
    exit 1
fi

BLOCKSCOUT_VERIFIER_URL="https://explorer.testnet.chain.robinhood.com/api/v2"
export BLOCKSCOUT_VERIFIER_URL
if "$ROOT_DIR/script/deploy-production.sh" >/dev/null 2>&1; then
    printf 'Expected malformed Blockscout URL to fail\n' >&2
    exit 1
fi

BLOCKSCOUT_VERIFIER_URL="https://explorer.testnet.chain.robinhood.com/api/"
FAKE_CURL_FAIL=1
export BLOCKSCOUT_VERIFIER_URL FAKE_CURL_FAIL
if "$ROOT_DIR/script/deploy-production.sh" >/dev/null 2>&1; then
    printf 'Expected unreachable Blockscout API to fail\n' >&2
    exit 1
fi
unset FAKE_CURL_FAIL

FAKE_CURL_INVALID_RESPONSE=1
export FAKE_CURL_INVALID_RESPONSE
if "$ROOT_DIR/script/deploy-production.sh" >/dev/null 2>&1; then
    printf 'Expected invalid Blockscout API response to fail\n' >&2
    exit 1
fi

[[ "$(grep -c '^CALL$' "$FAKE_FORGE_LOG")" == "$calls_before" ]]

printf 'DeployProductionScript: all checks passed\n'
