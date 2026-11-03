// Minimal ABIs for the keeper jobs. Kept by hand (no build step); checked against the contracts by the fork rehearsal.
import { parseAbi } from "viem";

export const gameAbi = parseAbi([
  "function sync() returns (uint256)",
  "function retireStep() returns (uint256)",
  "function keeperAvailable() view returns (uint256)",
  "function lastUpkeepAt() view returns (uint64)",
  "function PLAYER_UPKEEP_GAS() view returns (uint256)",
  "function keeperParams() view returns ((uint256 maxGasPrice, uint256 gasOverhead, uint256 flatFee, uint256 payDelay))",
  "function activate()",
  "function ready() view returns (bool)",
  "function activated() view returns (bool)",
  "function retiring() view returns (bool)",
  "function retired() view returns (bool)",
  "function capitalNeed() view returns (uint256)",
  "function pool() view returns (address)",
  "event Captured(uint256 indexed listingId, bool collection, uint256 proceeds, uint256 cost, uint256 ops)",
  "error NoWork()",
  "error NotReady()",
  "error Retiring()",
  "error NotRetiring()",
]);
export const vaultAbi = parseAbi([
  "function fundGame() returns (uint256)",
  "function generalBalance() view returns (uint256)",
  "function sweep() returns (uint256)",
  "function liveBid() view returns (uint256)",
  "function activationThreshold() view returns (uint256)",
  "function nextSweepBlock() view returns (uint256)",
  "error SweepTooEarly(uint256 nextBlock)",
  "error NothingToSend()",
]);
export const burnerAbi = parseAbi([
  "function process(uint256 minOut) returns (uint256)",
  "function nextSlice() view returns (uint256 amount, bool milestone, uint256 runAt)",
  "function priceOk() view returns (bool)",
  "function reserve() view returns (uint256)",
  "function release(uint256 listingId) returns (uint256)",
  "function releaseRetired() returns (uint256)",
  "function qualifies(uint256 listingId) view returns (bool)",
]);
export const migrationAbi = parseAbi([
  "function started() view returns (bool)",
  "function successor() view returns (address)",
  "function migrateApes(uint256 max) returns (uint256)",
  "function migrateCapital() returns (uint256)",
]);
export const sunsetAbi = parseAbi(["function flush() returns (uint256)", "function startedAt() view returns (uint256)"]);
export const poolOwnerAbi = parseAbi([
  "event CollectionWon(uint256 indexed listingId, uint256 indexed tokenId, uint256 refCost, uint256 cashCost)",
]);
export const fwaPoolAbi = parseAbi([
  "function processAcquisitions(uint256 maxCount) returns (uint256)",
  "function nextSequenceToProcess() view returns (uint64)",
  "function lastIssuedSequence() view returns (uint64)",
]);
