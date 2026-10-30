// Minimal hand-kept ABIs for the keeper's jobs and reads. No build step; the fork rehearsal checks them against the
// deployed contracts. Only the functions, events and errors the keeper touches are here.
import {parseAbi} from "viem";

export const engineAbi = parseAbi([
  // reads
  "function controller() view returns (address)",
  "function halted() view returns (bool)",
  "function burner() view returns (address)",
  "function checks() view returns (address)",
  "function shapes() view returns (address)",
  "function acquisitionBudget() view returns (uint256)",
  "function tierNotional(uint256) view returns (uint256)",
  "function drawsToCompose(uint256) view returns (uint32)",
  "function survivedDraws(uint256) view returns (uint256)",
  "function eligible(uint256) view returns (bool)",
  "function checkListing(uint256) view returns (address controller, uint64 listingId, uint128 price)",
  "function shapeListing(uint256) view returns (address controller, uint64 listingId, uint128 price)",
  "function params() view returns (uint16 shapeMarkupBps, uint16 decayBpsPerDraw, uint16 floorBps, uint16 repriceStepBps, uint32 graceDraws, uint16 buyoutMarkupBps, uint16 bidBps, uint128 bidWeeklyCap)",
  // writes the keeper may call (every one is permissionless on the engine)
  "function listChecks(uint256[] tokenIds)",
  "function listShapes(uint256[] shapeIds)",
  "function reprice(uint256[] tokenIds)",
  "function restockShapes(uint256[] wonShapeIds)",
  "function compose(uint256 keep, uint256 burn, bool swap)",
  "function formBlack(uint256[] tokenIds)",
  "function collect(address c) returns (uint256)",
  "function releaseSurplus() returns (uint256)",
  // events used to discover token ids
  "event Listed(address indexed collection, uint256 indexed tokenId, address indexed controller, uint256 listingId, uint256 price)",
  "event Unlisted(address indexed collection, uint256 indexed tokenId, address indexed controller, uint256 listingId)",
  "event Composed(address indexed by, uint256 indexed survivor, uint256 indexed burned, uint8 tier, uint256 coinBurned)",
  "event BlackCheck(address indexed by, uint256 indexed survivor, uint256[] burned, uint256 coinBurned)",
  "event Bought(address indexed buyer, uint256 indexed tokenId, uint8 tier, uint256 ethPaid, uint256 coinBurned)",
  "event Acquired(address indexed seller, uint256 indexed tokenId, bool fromEdition, uint8 tier, uint256 ethPaid)",
  "event Restocked(uint256 indexed wonShapeId, uint256 indexed newShapeId, uint256 backing)",
  // errors, for readable skip reasons
  "error NotRevealed()",
  "error TierNotListed()",
  "error NotListed()",
  "error AlreadyListed()",
  "error NotEligible()",
  "error QueueBusy()",
  "error BudgetExceeded()",
  "error NotAllowed()",
  "error BadInput()",
  "error Halt()",
]);

export const checksAbi = parseAbi([
  "function ownerOf(uint256) view returns (address)",
  "function getCheck(uint256) view returns (((uint16[6] composites, uint8[5] colorBands, uint8[5] gradients, uint8 divisorIndex, uint32 epoch, uint16 seed, uint24 day) stored, bool isRevealed, uint256 seed, uint8 checksCount, bool hasManyChecks, uint16 composite, bool isRoot, uint8 colorBand, uint8 gradient, uint8 direction, uint8 speed) check)",
]);

export const controllerAbi = parseAbi([
  "function pool() view returns (address)",
  "function unsettled() view returns (uint256)",
  "function isListed(uint256 listingId) view returns (bool)",
]);

export const poolAbi = parseAbi([
  "function unsettledAcquisitionCount() view returns (uint256)",
  "function ownerProceeds() view returns (uint256)",
  "function nextSequenceToProcess() view returns (uint64)",
  "function requestIdAtSequence(uint64) view returns (uint256)",
  "function acquisitionMeta(uint256) view returns (uint64 sequence, uint64 wordDeadlineBlock, uint64 rewardEpoch, uint16 maxPositiveSlippageBps, uint16 maxNegativeSlippageBps, uint256 randomWord)",
  "function processAcquisitions(uint256 maxCount) returns (uint256 processed)",
]);

export const hookAbi = parseAbi([
  "function forward()",
  "error NothingToForward()",
]);

export const burnerAbi = parseAbi([
  "function burn() returns (uint256 ethIn, uint256 burned)",
  "error TooSoon()",
  "error Nothing()",
]);
