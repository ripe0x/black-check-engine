#!/usr/bin/env bash
# Usage: script/deploy.sh <env> [--broadcast]
# Simulates the full deployment against <env>'s RPC (no transaction is sent) unless --broadcast is given.
# Signing: pass forge wallet flags through FORGE_WALLET_ARGS, e.g. FORGE_WALLET_ARGS="--ledger --sender 0x..".
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
ENV_NAME="${1:?env name (mainnet|anvil)}"
BROADCAST="${2:-}"
ENV_FILE="$(dirname "$0")/env/${ENV_NAME}.env"
PRESET_RPC="${RPC_URL:-}"
set -a; source "$ENV_FILE"; set +a
if [[ -n "$PRESET_RPC" ]]; then RPC_URL="$PRESET_RPC"; fi
# guard on the chain actually connected, not the env name (Deploy.run also requires the two to agree)
CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL")"
if [[ "$CHAIN_ID" == "1" && "$BROADCAST" == "--broadcast" && "${I_AM_THE_OWNER:-}" != "yes" ]]; then
  echo "Refusing to broadcast to mainnet without I_AM_THE_OWNER=yes (see docs/DEPLOY.md)." >&2; exit 1
fi
ARGS=(script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --slow -vvv)
if [[ "$BROADCAST" == "--broadcast" ]]; then ARGS+=(--broadcast); fi
# shellcheck disable=SC2086
forge script "${ARGS[@]}" ${FORGE_WALLET_ARGS:-}
