#!/usr/bin/env bash
# A local dev chain for the site: a mainnet fork on anvil's default port (8545) with anvil's chain id (31337), the
# deployment through activation (script/rehearse-anvil.sh steps 1-5), and the local randomness service
# (keeper/src/local-vrf.mjs) so draws settle as Chainlink VRF would settle them on mainnet, and the keeper bot
# (keeper/src/index.mjs, primary) to book draws, restock the board and sweep. Anvil and both services stay
# running. Then serve the site against it:
#
#   script/local.sh
#   NEXT_PUBLIC_DEPLOYMENT=anvil npm --prefix site run dev
set -euo pipefail
cd "$(dirname "$0")/.."
# the launch board (50 rows, LaunchConfig), so a local launch costs what mainnet's does
# STOP_AFTER=launch leaves it in funding mode instead (market open at minute 0, no Ape yet), for testing the whole path
FORK_URL="${FORK_URL:-https://mainnet.gateway.tenderly.co}" PORT=8545 CHAIN_ID=31337 STOP_AFTER="${STOP_AFTER:-activation}" INITIAL_BOARD_SIZE=50 \
  exec script/rehearse-anvil.sh
