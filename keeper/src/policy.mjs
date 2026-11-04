// When a keeper acts. Two modes:
// - primary: act whenever a job has work (its simulation succeeds) and the basefee is at most MAX_GAS_PRICE_GWEI
//   (the game reimburses the gas at the transaction's gas price up to its `maxGasPrice`, 3 gwei at launch, plus a flat
//   fee, within the allowance captures earn; above the cap it still reimburses, at the cap);
// - backup: act only when the job's work has waited longer than BACKUP_AFTER_SECONDS (measured by this keeper from
//   when it first saw the work), or the basefee is below BACKUP_BASEFEE_GATE_GWEI. Other keepers are welcome to do
//   the work first.
// Neither mode ever acts above GAS_PRICE_LIMIT_GWEI (10), however old the work: the game reimburses at most its
// `maxGasPrice`, so above that every call is paid for by the keeper (final audit round 2: a backup at 100 gwei spent
// about 0.57 ETH on a sync that paid 0.02 ETH). The limit also caps the transaction's maxFeePerGas.
// Settlement is not a keeper job (D53): FWA settles requests itself (the randomness callback), and anyone may settle
// the rest (FWA `processAcquisitions`, which the site's DrawRouter calls before each draw; `sync` also tries it).
// Players' draws through the DrawRouter also run the game's `upkeep` (`sync` unpaid, D77), so keepers are a backstop:
// within five minutes of a draw's upkeep the game does light work in a paid sync but pays nothing for it (D82), so this
// keeper leaves it to the next draw unless `UNPAID=1`.
// Keepers do what only the protocol may do: book results, replace prizes (owner-only on FWA), list the next Ape,
// pay surplus, and run buybacks. `sweep` meters the vault's ETH into its live bid (rewarded by the vault; sellers and
// the DrawRouter do it too). After the game has retired (a migration, or the sunset) anyone hands its Apes and capital
// to the successor; the sunset's ETH goes to the burner, and the burner's milestone reserve is released.

/** @returns {boolean} */
export function shouldAct({ mode, ageSeconds, basefeeWei, maxBasefeeWei, backupAfterSeconds, gateWei, limitWei }) {
  if (basefeeWei > limitWei) return false;
  if (mode === "primary") return basefeeWei <= maxBasefeeWei || ageSeconds > backupAfterSeconds;
  return ageSeconds > backupAfterSeconds || basefeeWei < gateWei;
}

/**
 * The free deterministic composition the keeper may run now (D008: once nobody has chosen within the grace, the
 * deterministic outcome is free and anyone may run it), or null. One per tick. `listings`: [{ listingId, tokenId,
 * tier, draws }] of open Check listings; `drawsToCompose` per tier below Black; `grace` in draws.
 * - two Checks of a tier at most 5 (80 to 4), both past threshold + grace: keep the one with more survived draws (the
 *   lower token id on a tie), as the desk's free rule requires;
 * - 64 singles all past threshold + grace: the 64 lowest token ids, ascending (the first survives as the Black Check).
 */
export function freeComposition(listings, drawsToCompose, grace) {
  const ready = (l) => l.tier < 7 && l.draws > 0n && l.draws >= BigInt(drawsToCompose[l.tier]) + BigInt(grace);
  const singles = listings.filter((l) => l.tier === 6 && ready(l)).sort((a, b) => (a.tokenId < b.tokenId ? -1 : 1));
  if (singles.length >= 64) return { name: "formBlack", args: [singles.slice(0, 64).map((l) => l.listingId)] };
  for (let tier = 0; tier <= 5; ++tier) {
    const c = listings
      .filter((l) => l.tier === tier && ready(l))
      .sort((a, b) => (a.draws !== b.draws ? (a.draws > b.draws ? -1 : 1) : a.tokenId < b.tokenId ? -1 : 1));
    if (c.length >= 2) return { name: "compose", args: [c[0].listingId, c[1].listingId, false] };
  }
  return null;
}

/**
 * The jobs to try this tick, in order. `state` is read on chain; every job is still simulated before sending.
 * @param {object} s
 */
export function jobs(s) {
  const out = [];
  if (s.retired) {
    out.push({ name: "retireStep" }); // sweeps late settlements
    out.push({ name: "migrateApes" });
    out.push({ name: "migrateCapital" });
    if (s.sunsetDue) out.push({ name: "flushSunset" }); // its ETH to the burner; starts the auction clock
    if (s.reserve > 0n) out.push({ name: "releaseRetired" });
    if (s.burnerReady) out.push({ name: "buyback" });
    return out;
  }
  if (s.retiring) {
    out.push({ name: "processAcquisitions" }); // retirement waits for every request to settle
    out.push({ name: "retireStep" });
    return out;
  }
  if (s.poolExists) out.push({ name: "sync" });
  if (!s.activated && s.ready) out.push({ name: "activate" });
  for (const id of s.unreleasedWins) out.push({ name: "release", args: [id] });
  if (s.composition) out.push(s.composition); // the free deterministic outcome only (D008)
  if (s.burnerReady) out.push({ name: "buyback" });
  if (s.sweepReady) out.push({ name: "sweep" });
  return out;
}
