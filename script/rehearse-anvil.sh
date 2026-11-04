#!/usr/bin/env bash
# Full deployment and activation rehearsal on a local anvil fork of mainnet. Nothing touches a live network.
#
#   FORK_URL=<archive rpc> script/rehearse-anvil.sh
#
# Steps: start anvil (auto-impersonate) at FORK_BLOCK; broadcast script/deploy.sh anvil with anvil's well-known
# test key 0 (a 160-prize board, about 5 ETH of backing); give the FWA holder FWA the way a wallet can hold it, then
# run its FWA relay and create the pool (script/FwaFee.s.sol); the owner launches the market; a trader trades through a
# public router; trading through Uniswap's Universal Router over the opening curve and after it funds everything (no
# contribution anywhere); sweeps fill the live bid to its threshold at once and then meter ETH in, and a real Checks
# holder accepts it; the keeper bot (keeper/, MODE=primary)
# syncs to a full board (paid from the opening allowance) and activates; players draw through the DrawRouter (running
# the upkeep and paid for it) and through FWA, the VRF coordinator delivers; the owner sets a new board pattern (applied
# to each row as it is next listed); two more Checks are bought from holders at the live bid and listed; the postflight is
# re-run; keeper pay is measured on real transactions; the trading-fee recipient is changed after its 72-hour notice
# (a stand-in for a later buy-and-burn); then the whole migration to a successor: owner proposal, 72 hours, execution by
# anyone (which points trading fees at the successor), settlement of the draws in flight, NFTs and capital handed over.
# Logs to rehearsal.log.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
FORK_URL="${FORK_URL:-https://mainnet.gateway.tenderly.co}"
FORK_BLOCK="${FORK_BLOCK:-26337000}" # after FWA reopened V2 pool creation (D014)
PORT="${PORT:-8546}"
# anvil's own chain id: the deploy refuses chain 1 without the owner's I_AM_THE_OWNER=yes and DEPLOY_ENV=mainnet
# (collection-games D81, D85), so a local fork never passes for mainnet. The fork's contracts and state are mainnet's.
CHAIN_ID="${CHAIN_ID:-31337}"
RPC="http://127.0.0.1:${PORT}"
# anvil's published test keys (not secrets; only valid on local nodes)
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
FWA_OWNER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
TRADER=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
FUNDER=0x90F79bf6EB2c4f870365E785982E1f101E93b906
PLAYER=0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
KEEPER=0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc
ADMIN=0x5afe5AfE5afe5aFe5AfE5aFe5aFE5afE5AFE5aFE # the owner (operator) in script/env/anvil.env
COUNCIL_SAFE=0x000000000000000000000000000000000000c0c1 # the council Safe in script/env/anvil.env (the timelock's proposer)
CHECKS=0x036721e5A769Cc48B3189EFbb9ccE4471E8A48B1
CHECK_FROM="${CHECK_FROM:-1}" # the first token id to look for an 80-Check held by an ordinary account
LOG=rehearsal.log
: > "$LOG"
say() { echo "### $*" | tee -a "$LOG"; }
# funding comes only from trading: traders buy and sell through Uniswap's Universal Router, the opening curve minute
# by minute, then steady hourly trading (keeper/src/local-trading.mjs); never a vault contribution
trade_until() { (cd keeper && RPC_URL="$RPC" DEPLOYMENT=../deployments/anvil.json UNTIL="$1" STEADY_ETH_PER_HOUR="${2:-2}" \
  node src/local-trading.mjs) >>"$LOG" 2>&1; }
fees() { cast call "$VAULT" "tradingFees()(uint256)" --rpc-url "$RPC" | cut -d' ' -f1; }
# the next 80-Check Original at or after $1 held by an ordinary account (Rehearse.floorCheck prints "check <id>")
floor_check() { forge script script/rehearsal/Rehearse.s.sol:Rehearse --sig "floorCheck(uint256)" "$1" --rpc-url "$RPC" 2>/dev/null \
  | grep -o "check [0-9]*" | awk '{print $2}'; }
# a council action through the real timelock (D012): the council Safe schedules, 7 days pass, anyone executes
council_do() {
  local target=$1 data=$2 salt
  salt=$(cast keccak "$(date +%s%N)")
  cast send "$COUNCIL" "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" "$target" 0 "$data" \
    0x0000000000000000000000000000000000000000000000000000000000000000 "$salt" 604800 \
    --from "$COUNCIL_SAFE" --unlocked --rpc-url "$RPC" >>"$LOG" 2>&1
  cast rpc evm_increaseTime 604800 --rpc-url "$RPC" >/dev/null && cast rpc anvil_mine 1 --rpc-url "$RPC" >/dev/null
  cast send "$COUNCIL" "execute(address,uint256,bytes,bytes32,bytes32)" "$target" 0 "$data" \
    0x0000000000000000000000000000000000000000000000000000000000000000 "$salt" \
    --from "$TRADER" --unlocked --rpc-url "$RPC" >>"$LOG" 2>&1
}

# one chain per port: an anvil already answering here (same chain id) is reused, and this deployment goes onto it;
# otherwise a fresh fork starts. The local services of an earlier deployment are stopped (their pid files).
for f in .local-vrf.pid .local-keeper.pid .local-seller.pid; do [[ -f $f ]] && { kill "$(cat $f)" 2>/dev/null || true; rm -f $f; }; done
if cast block-number --rpc-url "$RPC" >/dev/null 2>&1; then
  RUNNING=$(cast chain-id --rpc-url "$RPC")
  [[ "$RUNNING" == "$CHAIN_ID" ]] || { echo "port $PORT runs chain $RUNNING, not $CHAIN_ID: stop it or pick another PORT" >&2; exit 1; }
  ANVIL="existing"
  say "reusing the anvil already running on $RPC (chain id $CHAIN_ID)"
else
  anvil --fork-url "$FORK_URL" --fork-block-number "$FORK_BLOCK" --port "$PORT" --chain-id "$CHAIN_ID" --auto-impersonate --silent \
    --no-rate-limit --compute-units-per-second 10000 --timeout 20000 --retries 8 --fork-retry-backoff 1000 </dev/null >/dev/null 2>&1 &
  ANVIL=$!
  trap 'kill $ANVIL 2>/dev/null || true' EXIT
  for _ in $(seq 1 60); do cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
fi
cast rpc anvil_setBalance "$ADMIN" 0x3635C9ADC5DEA00000 --rpc-url "$RPC" >/dev/null
cast rpc anvil_setBalance "$COUNCIL_SAFE" 0x3635C9ADC5DEA00000 --rpc-url "$RPC" >/dev/null
# test wallets get 1000 ETH on the fork (only the fork: anvil_setBalance exists nowhere else). PLAYERS is a
# space-separated list; the default is ripe0x.eth.
for p in ${PLAYERS:-0xCB43078C32423F5348Cab5885911C3B5faE217F9}; do
  cast rpc anvil_setBalance "$p" 0x3635C9ADC5DEA00000 --rpc-url "$RPC" >/dev/null
done

mkdir -p deployments
say "1. deploy and postflight (forge script, broadcast to anvil)"
export RPC_URL="$RPC"
export INITIAL_BOARD_SIZE="${INITIAL_BOARD_SIZE:-160}" # the full rehearsal stresses listing; script/local.sh uses the launch board (50)
FORGE_WALLET_ARGS="--private-key $DEPLOYER_KEY" script/deploy.sh anvil --broadcast >>"$LOG" 2>&1
grep -q "postflight passed" "$LOG" && say "   postflight passed"
dep() { python3 -c "import json;print(json.load(open('deployments/anvil.json'))['$1'])"; }
POOL_OWNER=$(dep poolOwner); GAME=$(dep game); LIQ=$(dep liquidity); VAULT=$(dep vault); COUNCIL=$(dep council)
say "   game $GAME pool owner $POOL_OWNER"

say "2. FWA holder (stand-in for the owner's FWA balance) -> relay to the pool owner -> create the FWA pool"
forge script script/rehearsal/Rehearse.s.sol:Rehearse --sig "seedFwa(address,uint256)" "$FWA_OWNER" 2500000000000000000 \
  --rpc-url "$RPC" --broadcast --unlocked --sender "$FWA_OWNER" >>"$LOG" 2>&1
FWA_BAL=$(cast call 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845 "balanceOf(address)(uint256)" "$FWA_OWNER" --rpc-url "$RPC" | cut -d' ' -f1)
say "   FWA holder balance $FWA_BAL"
POOL_OWNER=$POOL_OWNER ROUTE=relay FWA_IN_WEI=51100000000000000000000 forge script script/FwaFee.s.sol:FwaFee \
  --rpc-url "$RPC" --broadcast --unlocked --sender "$FWA_OWNER" >>"$LOG" 2>&1
POOL=$(cast call "$POOL_OWNER" "pool()(address)" --rpc-url "$RPC")
say "   FWA pool $POOL owner $(cast call "$POOL" "owner()(address)" --rpc-url "$RPC")"

say "3. the owner opens the market (single-sided, ~32.6M coins per ETH: ~30.7 ETH opening FDV)"
cast send "$LIQ" "launch()" --from "$ADMIN" --unlocked --rpc-url "$RPC" >>"$LOG" 2>&1
# the local services a dev chain keeps running: randomness for every draw, the keeper bot (books draws, restocks,
# sweeps the live bid, activates) and a Checks holder who sells a Check whenever the live bid reaches the reference price.
# Blocks are mined every second, so the block-metered sweeps (a step per 300 blocks) advance without traffic.
local_services() {
  cast rpc evm_setIntervalMining 1 --rpc-url "$RPC" >/dev/null
  (cd keeper; RPC_URL="$RPC" DEPLOYMENT=../deployments/anvil.json nohup node src/local-vrf.mjs >>../local-vrf.log 2>&1 & echo $! >../.local-vrf.pid)
  say "   randomness service running (log: local-vrf.log)"
  (cd keeper; RPC_URL="$RPC" KEEPER_ADDRESS="$KEEPER" DEPLOYMENT=../deployments/anvil.json MODE=primary CHAIN_ID="$CHAIN_ID" POLL_SECONDS=15 \
    nohup node src/index.mjs >>../local-keeper.log 2>&1 & echo $! >../.local-keeper.pid)
  say "   keeper running (log: local-keeper.log)"
  (cd keeper; RPC_URL="$RPC" DEPLOYMENT=../deployments/anvil.json nohup node src/local-seller.mjs >>../local-seller.log 2>&1 & echo $! >../.local-seller.pid)
  say "   Check seller running (log: local-seller.log)"
}
# A local dev chain in funding mode stops here: the market is open at minute 0, nothing traded, no Check bought yet
if [[ "${STOP_AFTER:-}" == "launch" ]]; then
  [[ "$CHAIN_ID" == "31337" ]] && local_services
  trap - EXIT
  say "anvil left running on $RPC, chain id $CHAIN_ID, in funding mode (trade on the site, or with keeper/src/local-trading.mjs)"
  exit 0
fi
say "   the opening hour: traders through the Universal Router while the fee falls from 69% to 5% (50 ETH, rising toward the end)"
trade_until minutes:64
say "   trading fees in vault after the opening curve: $(fees)"

say "4. funding mode: trading fees fill the live bid to its threshold at a sweep, then meter ETH in; a Checks holder accepts it"
cast rpc evm_increaseTime 1814400 --rpc-url "$RPC" >/dev/null && cast rpc anvil_mine 1 --rpc-url "$RPC" >/dev/null
# if the opening hour did not bring the first Check's threshold, trading continues at the ordinary fee until it does
trade_until first-ape
bid() { cast call "$VAULT" "liveBid()(uint256)" --rpc-url "$RPC" | cut -d' ' -f1; }
say "   live bid after 21 days with nobody sweeping (nothing rises with time): $(bid); threshold $(cast call "$VAULT" "activationThreshold()(uint256)" --rpc-url "$RPC")"
# sweeps (a waiting seller, keepers, players' draws; each rewarded): one fill to the threshold, then a metered step per
# 300 blocks, until the bid reaches the target or nothing more can enter
sweep_to() {
  local target=$1
  for _ in $(seq 1 200); do
    python3 -c "import sys; sys.exit(0 if int('$(bid)') >= $target else 1)" && break
    cast send "$VAULT" "sweep()" --from "$FUNDER" --unlocked --rpc-url "$RPC" >/dev/null 2>&1 \
      || { [[ "$(cast call "$VAULT" "nextSweepBlock()(uint256)" --rpc-url "$RPC" | cut -d' ' -f1)" -le "$(cast block-number --rpc-url "$RPC")" ]] && break; }
    cast rpc anvil_mine 300 --rpc-url "$RPC" >/dev/null
  done
}
cast send "$VAULT" "sweep()" --from "$FUNDER" --unlocked --rpc-url "$RPC" >/dev/null 2>&1
say "   after one sweep (fast fill): $(bid)"
sweep_to 250000000000000000
say "   after metered sweeps (1 ETH per 300 blocks): $(bid); sweep rewards paid $(cast call "$VAULT" "sweepRewards()(uint256)" --rpc-url "$RPC")"
CHECK_ID=$(floor_check "$CHECK_FROM")
HOLDER=$(cast call "$CHECKS" "ownerOf(uint256)(address)" "$CHECK_ID" --rpc-url "$RPC")
cast rpc anvil_setBalance "$HOLDER" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
forge script script/rehearsal/Rehearse.s.sol:Rehearse --sig "sellCheck(uint256)" "$CHECK_ID" \
  --rpc-url "$RPC" --broadcast --unlocked --sender "$HOLDER" >>"$LOG" 2>&1
NEED=$(cast call "$GAME" "capitalNeed()(uint256)" --rpc-url "$RPC" | cut -d' ' -f1)
# the board and reserve, plus the opening allowance the keepers listing the board are paid from (game cash, refilled
# from the vault at activation)
ALLOW=$(cast call "$GAME" "keeperAvailable()(uint256)" --rpc-url "$RPC" | cut -d' ' -f1)
NEED=$(python3 -c "print($NEED + $ALLOW)")
say "   Check #$CHECK_ID held by pool owner: $(cast call "$CHECKS" "ownerOf(uint256)(address)" "$CHECK_ID" --rpc-url "$RPC"); game capital need + opening allowance $NEED"
# the board, reserve and opening keeper pay, from trading fees as well
trade_until board
say "   trading fees in vault: $(fees)"

say "5. keeper (primary) fills the board and activates"
cast rpc anvil_setBalance "$KEEPER" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
# 160 prizes at 8 per call (the board's maxPerCall, sized for EIP-7825's gas cap): about 20 keeper passes
for _ in $(seq 1 40); do
  [[ "$(cast call "$GAME" "activated()(bool)" --rpc-url "$RPC")" == "true" ]] && break
  (cd keeper && RPC_URL="$RPC" KEEPER_ADDRESS="$KEEPER" DEPLOYMENT=../deployments/anvil.json MODE=primary CHAIN_ID="$CHAIN_ID" \
    node src/index.mjs --once) >>"$LOG" 2>&1
done
say "   activated $(cast call "$GAME" "activated()(bool)" --rpc-url "$RPC"), keepers paid $(cast call "$GAME" "keeperPaid()(uint256)" --rpc-url "$RPC") of the opening allowance, Shapes live $(cast call "$GAME" "liveCount()(uint256)" --rpc-url "$RPC"), FWA purchases $(cast call "$POOL" "localPurchasesEnabled()(bool)" --rpc-url "$RPC")"

# A local dev chain stops here, live: anvil keeps running, and on anvil's chain id the randomness service
# (keeper/src/local-vrf.mjs) delivers a word for every draw, as Chainlink VRF would on mainnet.
if [[ "${STOP_AFTER:-}" == "activation" ]]; then
  [[ "$CHAIN_ID" == "31337" ]] && local_services
  trap - EXIT
  say "anvil left running on $RPC ($ANVIL), chain id $CHAIN_ID"
  exit 0
fi

say "6. players draw (through the DrawRouter, which runs the upkeep the site measured within its budget and pays the player, and through FWA)"
for i in 1 2 3; do
  # the gas limit must cover the upkeep budget (the router checks it): a wallet's eth_estimateGas includes it; forge
  # sizes the limit from its own simulation, hence the multiplier
  forge script script/rehearsal/Rehearse.s.sol:Rehearse --sig "routerDraw(address,uint256)" "$PLAYER" 10 \
    --rpc-url "$RPC" --broadcast --unlocked --sender "$PLAYER" --gas-price 1000000000 --gas-estimate-multiplier 250 >>"$LOG" 2>&1
  grep "upkeep measured" "$LOG" | tail -1 | sed 's/^ */###    /' | tee -a "$LOG" >/dev/null
  cast rpc anvil_mine 3 --rpc-url "$RPC" >/dev/null
  forge script script/rehearsal/Rehearse.s.sol:Rehearse --sig "fulfillLatest(uint256)" "$((i * 104729))" \
    --rpc-url "$RPC" --broadcast --unlocked --gas-estimate-multiplier 600 \
    --sender "$(cast call 0xA4adFC35dB18326eFB3b5D9bf66A8103Ec2D5EE2 "s_vrfCoordinator()(address)" --rpc-url "$RPC")" >>"$LOG" 2>&1
done
for i in 1 2 3; do
  forge script script/rehearsal/Rehearse.s.sol:Rehearse --sig "pull(address)" "$PLAYER" \
    --rpc-url "$RPC" --broadcast --unlocked --sender "$PLAYER" --gas-price 1000000000 >>"$LOG" 2>&1
  cast rpc anvil_mine 3 --rpc-url "$RPC" >/dev/null
  forge script script/rehearsal/Rehearse.s.sol:Rehearse --sig "fulfillLatest(uint256)" "$((i * 7919))" \
    --rpc-url "$RPC" --broadcast --unlocked --gas-estimate-multiplier 600 \
    --sender "$(cast call 0xA4adFC35dB18326eFB3b5D9bf66A8103Ec2D5EE2 "s_vrfCoordinator()(address)" --rpc-url "$RPC")" >>"$LOG" 2>&1
done
(cd keeper && RPC_URL="$RPC" KEEPER_ADDRESS="$KEEPER" DEPLOYMENT=../deployments/anvil.json MODE=primary CHAIN_ID="$CHAIN_ID" \
  node src/index.mjs --once) >>"$LOG" 2>&1
say "   pulls fulfilled $(cast call "$GAME" "pullsFulfilled()(uint256)" --rpc-url "$RPC"), revenue $(cast call "$GAME" "revenue()(uint256)" --rpc-url "$RPC"), keeper pay $(cast call "$GAME" "keeperPaid()(uint256)" --rpc-url "$RPC") (players' upkeep and the keeper), allowance left $(cast call "$GAME" "keeperAvailable()(uint256)" --rpc-url "$RPC")"

say "7. board change after deployment: the owner sets the launch pattern reversed; each row takes it when next listed"
PATTERN=$(python3 -c "import sys; sys.path.insert(0, 'sim'); from economics import PATTERNS; print('[' + ','.join(str(round(b * 10**18)) for b in reversed(PATTERNS['B50'])) + ']')")
ROW0=$(cast call "$GAME" "rowAt(uint256)(uint256)" 0 --rpc-url "$RPC" | cut -d' ' -f1)
cast rpc anvil_setBalance "$ADMIN" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
cast send "$GAME" "setPattern(uint256[])" "$PATTERN" --from "$ADMIN" --unlocked --rpc-url "$RPC" >>"$LOG" 2>&1
cast send "$GAME" "setPattern(uint256[])" "$PATTERN" --from "$TRADER" --unlocked --rpc-url "$RPC" >>"$LOG" 2>&1 \
  && say "   ERROR: a stranger set the pattern" || say "   pattern by anyone but the owner: refused"
for i in 1 2 3; do
  forge script script/rehearsal/Rehearse.s.sol:Rehearse --sig "pull(address)" "$PLAYER" \
    --rpc-url "$RPC" --broadcast --unlocked --sender "$PLAYER" --gas-price 1000000000 >>"$LOG" 2>&1
  cast rpc anvil_mine 3 --rpc-url "$RPC" >/dev/null
  forge script script/rehearsal/Rehearse.s.sol:Rehearse --sig "fulfillLatest(uint256)" "$((i * 31337))" \
    --rpc-url "$RPC" --broadcast --unlocked --gas-estimate-multiplier 600 \
    --sender "$(cast call 0xA4adFC35dB18326eFB3b5D9bf66A8103Ec2D5EE2 "s_vrfCoordinator()(address)" --rpc-url "$RPC")" >>"$LOG" 2>&1
done
cast rpc evm_increaseTime 600 --rpc-url "$RPC" >/dev/null && cast rpc anvil_mine 1 --rpc-url "$RPC" >/dev/null
(cd keeper && RPC_URL="$RPC" KEEPER_ADDRESS="$KEEPER" DEPLOYMENT=../deployments/anvil.json MODE=primary CHAIN_ID="$CHAIN_ID" \
  node src/index.mjs --once) >>"$LOG" 2>&1
say "   row 0 backing $ROW0 -> $(cast call "$GAME" "rowAt(uint256)(uint256)" 0 --rpc-url "$RPC" | cut -d' ' -f1) (pattern of $(cast call "$GAME" "patternLength()(uint256)" --rpc-url "$RPC")); prizes live $(cast call "$GAME" "liveCount()(uint256)" --rpc-url "$RPC") of $(cast call "$GAME" "boardSize()(uint256)" --rpc-url "$RPC"); replacements owed $(cast call "$GAME" "replacementsOwed()(uint256)" --rpc-url "$RPC")"

say "8. two more Checks bought from holders at the live bid and listed; the owner turns the fee overflow on; a buyback (D64, D65, D72)"
# the next Checks' budget from trading too: steady trading (20 ETH an hour) until the vault holds 30 ETH more
trade_until "vault:$(python3 -c "print($(cast balance "$VAULT" --rpc-url "$RPC") + 30 * 10**18)")" 20
BOUGHT=0
NEXT=$((CHECK_ID + 1))
for _ in $(seq 1 10); do
  [[ $BOUGHT -ge 2 ]] && break
  ID=$(floor_check "$NEXT"); NEXT=$((ID + 1))
  OWNER_ID=$(cast call "$CHECKS" "ownerOf(uint256)(address)" "$ID" --rpc-url "$RPC")
  sweep_to 250000000000000000
  cast rpc anvil_setBalance "$OWNER_ID" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
  forge script script/rehearsal/Rehearse.s.sol:Rehearse --sig "sellCheck(uint256)" "$ID" \
    --rpc-url "$RPC" --broadcast --unlocked --sender "$OWNER_ID" >>"$LOG" 2>&1 && BOUGHT=$((BOUGHT + 1))
done
# fee overflow (D64; trigger D65): the bid is refilled and the vault holds more than the bid and one more Check at the
# last price, so the trading fees since the last sweep are split at the next one: half to the burner's ongoing
# buybacks, never the bid's ETH or the next Check
sweep_to 250000000000000000
# the overflow is off at launch (D72): the owner turns it on at 50% to exercise it
cast send "$VAULT" "setOverflowBps(uint256)" 5000 --from "$ADMIN" --unlocked --rpc-url "$RPC" >>"$LOG" 2>&1
forge script script/rehearsal/Rehearse.s.sol:Rehearse --sig "trade(address,uint256)" "$TRADER" 4 \
  --rpc-url "$RPC" --broadcast --unlocked --sender "$TRADER" >>"$LOG" 2>&1
UNSPLIT=$(cast call "$VAULT" "unsplitFees()(uint256)" --rpc-url "$RPC" | cut -d' ' -f1)
PENDING=$(cast call "$VAULT" "pendingOverflow()(uint256)" --rpc-url "$RPC" | cut -d' ' -f1)
cast rpc anvil_mine 300 --rpc-url "$RPC" >/dev/null
cast send "$VAULT" "sweep()" --from "$FUNDER" --unlocked --rpc-url "$RPC" >>"$LOG" 2>&1
say "   fee overflow: vault budget $(cast call "$VAULT" "acquisitionBudget()(uint256)" --rpc-url "$RPC") against the bid $(cast call "$VAULT" "bidBalance()(uint256)" --rpc-url "$RPC") + the next Check $(cast call "$VAULT" "lastPrice()(uint256)" --rpc-url "$RPC"); fees since the last sweep $UNSPLIT, pending overflow $PENDING; sent to buybacks $(cast call "$VAULT" "overflowOut()(uint256)" --rpc-url "$RPC")"
for _ in 1 2 3; do
  cast rpc evm_increaseTime 600 --rpc-url "$RPC" >/dev/null && cast rpc anvil_mine 1 --rpc-url "$RPC" >/dev/null
  (cd keeper && RPC_URL="$RPC" KEEPER_ADDRESS="$KEEPER" DEPLOYMENT=../deployments/anvil.json MODE=primary CHAIN_ID="$CHAIN_ID" \
    node src/index.mjs --once) >>"$LOG" 2>&1
done
say "   Checks listed $(cast call "$POOL_OWNER" "listedCount()(uint256)" --rpc-url "$RPC") (waiting $(cast call "$POOL_OWNER" "custodyCount()(uint256)" --rpc-url "$RPC")), exposure bps $(cast call "$POOL_OWNER" "exposureBps()(uint256)" --rpc-url "$RPC"), board $(cast call "$GAME" "boardSize()(uint256)" --rpc-url "$RPC")"
BURNER=$(dep burner)
cast rpc evm_increaseTime 3600 --rpc-url "$RPC" >/dev/null && cast rpc anvil_mine 1 --rpc-url "$RPC" >/dev/null
cast send "$BURNER" "process(uint256)" 0 --from "$KEEPER" --unlocked --gas-limit 2000000 --rpc-url "$RPC" >>"$LOG" 2>&1 || true
say "   buybacks (the keeper bot's buyback job, 0.05 ETH + 0.005 a draw + 1% of the bucket a slice): spent $(cast call "$BURNER" "ongoingSpent()(uint256)" --rpc-url "$RPC"), coins burned $(cast call "$BURNER" "totalBurned()(uint256)" --rpc-url "$RPC"), bucket left $(cast call "$BURNER" "ongoingBalance()(uint256)" --rpc-url "$RPC")"
say "   Checks held $(cast call "$POOL_OWNER" "heldCount()(uint256)" --rpc-url "$RPC"), prize backing $(cast call "$GAME" "inventoryBacking()(uint256)" --rpc-url "$RPC"), vault $(cast balance "$VAULT" --rpc-url "$RPC"), burner $(cast balance "$BURNER" --rpc-url "$RPC") (milestone reserve $(cast call "$BURNER" "reserve()(uint256)" --rpc-url "$RPC"))"

say "9. postflight against the rehearsal deployment (before the migration)"
set -a; source script/env/anvil.env; set +a
DEPLOYER=$DEPLOYER forge script script/Postflight.s.sol:Postflight --sig "check()" --rpc-url "$RPC" >>"$LOG" 2>&1 \
  && say "   postflight passed (after launch and play)"
say "10. keeper pay on real transactions: the game pays each sync its gas (capped at 3 gwei) plus a flat fee, within the allowance captures earn"
OVERHEAD=70000
(cd keeper && RPC_URL="$RPC" KEEPER_ADDRESS="$KEEPER" DEPLOYMENT=../deployments/anvil.json MODE=primary CHAIN_ID="$CHAIN_ID" \
  node src/index.mjs --once) >>"$LOG" 2>&1
for n in 1 3 10; do
  for i in $(seq 1 "$n"); do
    forge script script/rehearsal/Rehearse.s.sol:Rehearse --sig "routerDraw(address,uint256)" "$PLAYER" 0 \
      --rpc-url "$RPC" --broadcast --unlocked --sender "$PLAYER" --gas-price 1000000000 >>"$LOG" 2>&1
    cast rpc anvil_mine 3 --rpc-url "$RPC" >/dev/null
    forge script script/rehearsal/Rehearse.s.sol:Rehearse --sig "fulfillLatest(uint256)" "$((n * 1000 + i))" \
      --rpc-url "$RPC" --broadcast --unlocked --gas-estimate-multiplier 600 \
      --sender "$(cast call 0xA4adFC35dB18326eFB3b5D9bf66A8103Ec2D5EE2 "s_vrfCoordinator()(address)" --rpc-url "$RPC")" >>"$LOG" 2>&1
  done
  cast rpc evm_increaseTime 3600 --rpc-url "$RPC" >/dev/null
  cast rpc anvil_setNextBlockBaseFeePerGas 1000000000 --rpc-url "$RPC" >/dev/null
  AVAIL=$(cast call "$GAME" "keeperAvailable()(uint256)" --rpc-url "$RPC" | cut -d' ' -f1)
  RCPT=$(cast send "$GAME" "sync()" --from "$KEEPER" --unlocked --priority-gas-price 20000000 \
    --gas-price 2000000000 --gas-limit 25000000 --rpc-url "$RPC" --json)
  python3 - "$RCPT" "$GAME" "$OVERHEAD" "$n" "$AVAIL" "$(cast sig-event "KeeperPaid(address,uint256)")" <<'PY' | tee -a "$LOG"
import json, sys
r, game, overhead, n, avail, topic = json.loads(sys.argv[1]), sys.argv[2].lower(), int(sys.argv[3]), sys.argv[4], int(sys.argv[5]), sys.argv[6].lower()
gas, price = int(r["gasUsed"], 16), int(r["effectiveGasPrice"], 16)
tips = [int(l["data"][2:66], 16) for l in r["logs"] if l["address"].lower() == game and l["topics"][0].lower() == topic]
tip = tips[-1] if tips else 0
cost = gas * price
print(f"###    {n} draw(s) booked: receipt gas {gas:,} at {price / 1e9:.3f} gwei = {cost / 1e18:.7f} ETH; paid {tip / 1e18:.7f} ETH "
      f"(paid / cost {tip / cost:.3f}; allowance before {avail / 1e18:.5f} ETH; gasOverhead {overhead:,}; plus the flat fee)")
PY
done

MIG=$(dep migration); HOOK=$(dep hook); BURNER=$(dep burner)
cast rpc anvil_setBalance "$TRADER" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
say "11. trading-fee recipient changed alone (no migration): council proposal (7-day timelock), 72 hours, execution by anyone"
# a stand-in for a later recipient (e.g. a buy-and-burn of another coin): any contract; its code is pinned at proposal
forge script script/rehearsal/Rehearse.s.sol:Rehearse --sig "deploySuccessor(address)" "$DEPLOYER" \
  --rpc-url "$RPC" --broadcast --unlocked --sender "$DEPLOYER" >>"$LOG" 2>&1
FEE_TO=$(grep "successor 0x" "$LOG" | tail -1 | awk '{print $NF}')
cast send "$HOOK" "setFeeRecipient(address)" "$FEE_TO" --from "$ADMIN" --unlocked --rpc-url "$RPC" >>"$LOG" 2>&1 \
  && say "   ERROR: the owner set the fee recipient directly" || say "   direct change at the hook, even by the owner: refused"
cast send "$MIG" "proposeFeeRecipient(address)" "$FEE_TO" --from "$TRADER" --unlocked --rpc-url "$RPC" >>"$LOG" 2>&1 \
  && say "   ERROR: a stranger proposed a fee recipient" || say "   proposal by a stranger: refused"
cast send "$MIG" "proposeFeeRecipient(address)" "$FEE_TO" --from "$ADMIN" --unlocked --rpc-url "$RPC" >>"$LOG" 2>&1 \
  && say "   ERROR: the owner proposed a fee recipient" || say "   proposal by the owner: refused (the council's power, D012)"
council_do "$MIG" "$(cast calldata "proposeFeeRecipient(address)" "$FEE_TO")"
say "   proposed by the council after its 7-day timelock: pending $(cast call "$MIG" "pendingFeeRecipient()(address)" --rpc-url "$RPC")"
cast send "$MIG" "executeFeeRecipient()" --from "$TRADER" --unlocked --rpc-url "$RPC" >>"$LOG" 2>&1 \
  && say "   ERROR: executed before 72 hours" || say "   execution before 72 hours: refused"
cast rpc evm_increaseTime 259200 --rpc-url "$RPC" >/dev/null && cast rpc anvil_mine 1 --rpc-url "$RPC" >/dev/null
cast send "$MIG" "executeFeeRecipient()" --from "$TRADER" --unlocked --rpc-url "$RPC" >>"$LOG" 2>&1
FT0=$(cast call "$FEE_TO" "feesReceived()(uint256)" --rpc-url "$RPC")
forge script script/rehearsal/Rehearse.s.sol:Rehearse --sig "trade(address,uint256)" "$TRADER" 1 \
  --rpc-url "$RPC" --broadcast --unlocked --sender "$TRADER" >>"$LOG" 2>&1
say "   executed by a third party: fee recipient $(cast call "$HOOK" "feeRecipient()(address)" --rpc-url "$RPC"); fees to it $FT0 -> $(cast call "$FEE_TO" "feesReceived()(uint256)" --rpc-url "$RPC"); the game plays on: retiring $(cast call "$GAME" "retiring()(bool)" --rpc-url "$RPC"), FWA purchases $(cast call "$POOL" "localPurchasesEnabled()(bool)" --rpc-url "$RPC")"

say "12. migration to a successor: council proposal (7-day timelock), 72 hours, execution by anyone, settlement, hand-over"
# two draws in flight when V1 stops
for i in 1 2; do
  forge script script/rehearsal/Rehearse.s.sol:Rehearse --sig "pull(address)" "$PLAYER" \
    --rpc-url "$RPC" --broadcast --unlocked --sender "$PLAYER" --gas-price 1000000000 >>"$LOG" 2>&1
done
SEQ=$(cast call "$POOL" "lastIssuedSequence()(uint64)" --rpc-url "$RPC" | cut -d' ' -f1)
B0=$(cast balance "$BURNER" --rpc-url "$RPC")
V0=$(cast balance "$VAULT" --rpc-url "$RPC"); RET0=$(cast call "$VAULT" "returnedFromGame()(uint256)" --rpc-url "$RPC" | cut -d' ' -f1)
forge script script/rehearsal/Rehearse.s.sol:Rehearse --sig "deploySuccessor(address)" "$DEPLOYER" \
  --rpc-url "$RPC" --broadcast --unlocked --sender "$DEPLOYER" >>"$LOG" 2>&1
SUCC=$(grep "successor 0x" "$LOG" | tail -1 | awk '{print $NF}')
cast send "$MIG" "propose(address)" "$SUCC" --from "$TRADER" --unlocked --rpc-url "$RPC" >>"$LOG" 2>&1 \
  && say "   ERROR: a stranger proposed" || say "   proposal by a stranger: refused"
cast send "$MIG" "propose(address)" "$SUCC" --from "$ADMIN" --unlocked --rpc-url "$RPC" >>"$LOG" 2>&1 \
  && say "   ERROR: the owner proposed a migration" || say "   proposal by the owner: refused (the council's power, D012)"
council_do "$MIG" "$(cast calldata "propose(address)" "$SUCC")"
cast send "$MIG" "execute()" --from "$TRADER" --unlocked --rpc-url "$RPC" >>"$LOG" 2>&1 \
  && say "   ERROR: executed before 72 hours" || say "   execution before 72 hours: refused"
cast rpc evm_increaseTime 259200 --rpc-url "$RPC" >/dev/null && cast rpc anvil_mine 1 --rpc-url "$RPC" >/dev/null
cast send "$MIG" "execute()" --from "$TRADER" --unlocked --rpc-url "$RPC" >>"$LOG" 2>&1
say "   executed by a third party: V1 retiring $(cast call "$GAME" "retiring()(bool)" --rpc-url "$RPC"), FWA purchases $(cast call "$POOL" "localPurchasesEnabled()(bool)" --rpc-url "$RPC"), fee recipient $(cast call "$HOOK" "feeRecipient()(address)" --rpc-url "$RPC") (the successor)"
cast send "$MIG" "migrateChecks(uint256)" 10 --from "$TRADER" --unlocked --rpc-url "$RPC" >>"$LOG" 2>&1 \
  && say "   ERROR: NFTs moved before V1 settled" || say "   NFTs before V1 has settled: refused"
# the first draw in flight gets its randomness; the second never does and expires into a refund
cast rpc anvil_mine 3 --rpc-url "$RPC" >/dev/null
forge script script/rehearsal/Rehearse.s.sol:Rehearse --sig "fulfillSeq(uint64,uint256)" "$((SEQ - 1))" 99991 \
  --rpc-url "$RPC" --broadcast --unlocked --gas-estimate-multiplier 600 \
  --sender "$(cast call 0xA4adFC35dB18326eFB3b5D9bf66A8103Ec2D5EE2 "s_vrfCoordinator()(address)" --rpc-url "$RPC")" >>"$LOG" 2>&1
cast rpc anvil_mine 300 --rpc-url "$RPC" >/dev/null
# retirement withdraws ten prizes per call (D61): a 160-prize board takes about 16 keeper passes
for _ in $(seq 1 40); do
  [[ "$(cast call "$GAME" "retired()(bool)" --rpc-url "$RPC")" == "true" ]] && break
  (cd keeper && RPC_URL="$RPC" KEEPER_ADDRESS="$KEEPER" DEPLOYMENT=../deployments/anvil.json MODE=primary CHAIN_ID="$CHAIN_ID" \
    node src/index.mjs --once) >>"$LOG" 2>&1
done
say "   V1 settled and unwound: retired $(cast call "$GAME" "retired()(bool)" --rpc-url "$RPC"), unsettled $(cast call "$POOL" "unsettledAcquisitionCount()(uint256)" --rpc-url "$RPC"), prizes live $(cast call "$GAME" "liveCount()(uint256)" --rpc-url "$RPC"), player refund credit $(cast call "$POOL" "acquisitionRefundCredit(address)(uint256)" "$PLAYER" --rpc-url "$RPC")"
# the keeper bot's retired jobs migrate the Checks and capital on its own; these calls finish whatever is left
cast send "$MIG" "migrateChecks(uint256)" 10 --from "$TRADER" --unlocked --rpc-url "$RPC" >>"$LOG" 2>&1 || true
cast send "$MIG" "migrateCapital()" --from "$TRADER" --unlocked --rpc-url "$RPC" >>"$LOG" 2>&1 || true
RET1=$(cast call "$VAULT" "returnedFromGame()(uint256)" --rpc-url "$RPC" | cut -d' ' -f1)
CAP=$(cast call "$SUCC" "capitalReceived()(uint256)" --rpc-url "$RPC" | cut -d' ' -f1)
# wei amounts exceed bash's 64-bit arithmetic: compare in python
CONS=$(python3 -c "import sys; c,v,r1,r0=map(int,sys.argv[1:]); print(f'{c} = vault before {v} + returned by the game {r1-r0}: ' + ('exact' if c==v+r1-r0 else 'MISMATCH'))" "$CAP" "$V0" "$RET1" "$RET0")
say "   successor $SUCC: Checks $(cast call "$SUCC" "apeCount()(uint256)" --rpc-url "$RPC"), capital $CONS; V1 vault left $(cast balance "$VAULT" --rpc-url "$RPC")"
say "   committed buyback ETH stays in the burner: $B0 -> $(cast balance "$BURNER" --rpc-url "$RPC") (a migration never moves it)"
F0=$(cast call "$SUCC" "feesReceived()(uint256)" --rpc-url "$RPC")
forge script script/rehearsal/Rehearse.s.sol:Rehearse --sig "trade(address,uint256)" "$TRADER" 1 \
  --rpc-url "$RPC" --broadcast --unlocked --sender "$TRADER" >>"$LOG" 2>&1
# no win can come after retirement: the milestone reserve is released to buybacks, and the burner keeps buying and burning
cast send "$BURNER" "releaseRetired()" --from "$KEEPER" --unlocked --rpc-url "$RPC" >>"$LOG" 2>&1 || true
cast rpc evm_increaseTime 3600 --rpc-url "$RPC" >/dev/null && cast rpc anvil_mine 1 --rpc-url "$RPC" >/dev/null
BURNED0=$(cast call "$BURNER" "totalBurned()(uint256)" --rpc-url "$RPC" | cut -d' ' -f1)
cast send "$BURNER" "process(uint256)" 0 --from "$KEEPER" --unlocked --gas-limit 2000000 --rpc-url "$RPC" >>"$LOG" 2>&1 || true
say "   same coin and market, fees at the successor: $F0 -> $(cast call "$SUCC" "feesReceived()(uint256)" --rpc-url "$RPC"); milestone reserve $(cast call "$BURNER" "reserve()(uint256)" --rpc-url "$RPC") after releaseRetired; buy-and-burn continues: coins burned $BURNED0 -> $(cast call "$BURNER" "totalBurned()(uint256)" --rpc-url "$RPC" | cut -d' ' -f1)"

if [[ "${KEEP_ANVIL:-}" == "1" ]]; then trap - EXIT; say "anvil left running on $RPC (pid $ANVIL)"; fi
say "done"
