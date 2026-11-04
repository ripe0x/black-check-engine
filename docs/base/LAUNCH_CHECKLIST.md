# Launch checklist

Short and ordered. Details: DEPLOY.md. Nothing below has been done. **The coin does not launch until the complete
system is ready, the independent security review has been completed satisfactorily and the legal review has cleared
launch.**

**Decide (owner)**
1. Coin identity: **ApeBall (APEBALL)**, an Ape-specific coin (D56, D69), subject to final naming and legal clearance; repeat
   the conflict check (Etherscan, CoinGecko) on the day. It is immutable once deployed.
2. The live bid (D59): `REF_PRICE_WEI` = **the live BAYC floor on the day** (6 ETH placeholder; the first activation
   threshold is 100% of it, so the opening fees can buy the first Ape at once, D64; the first relative ceiling 120% of
   it; after each purchase the threshold is 75% of the price paid); `MAX_PRICE_WEI` = 0 (no absolute cap; an optional
   emergency brake). Changeable later (`FundingVault.setActivationThreshold`, `setBidParams`).
3. Opening tick 173,000 (≈ 32.6M coins per ETH, ≈ 30.7 ETH FDV, about $69k at $2,242 ETH; D70), fixed in `LaunchConfig`. No ETH is needed or accepted. The valuation is in ETH: its dollar
   value moves with the ETH price until launch.
4. Remaining items in IMPLEMENTOR_DECISIONS "Needs owner review": D57 (one owner), D59/D60's flagged tradeoffs (the
   live bid's falling-floor exposure, the relative ceiling's slow climb, `maxPrice`), D53 (DrawRouter, open without an
   Ape), D49 (the ≈ 1.1 gwei maintenance ceiling), D8, D15, D24, D27, D28, D31; and confirm D63's launch values (keeper
   pay: gas plus a 0.0002 ETH flat fee within the 1 ETH opening allowance (D79) and what captures earn; 72-hour notices, code
   pinned, for a migration and for a new fee recipient; the instant, final sunset into buy-and-burn) and D64's,
   approved (DEPLOY.md "Launch values"): fees 5% / 5% under the fixed 69% opening curve; the 50-row board; markup 10%;
   target 20%; K 3 (D65; raise it with `setMaxInFlight` when demand produces a queue); 70% fill; reserve 1 ETH; 35%
   of each distribution to the vault while it is short of an Ape, the rest to the burner, all of it locked as a milestone reserve (D74) released entirely by an Ape pull (D74; a big Shape or Pack releases nothing); the buyback cadence; half the fees to buybacks while the bid is at its fill
   target, only from what the vault holds beyond the bid and one more Ape at the last price (D65).
   Check the recent average basefee against the ceiling and against `maxGasPrice` (3 gwei in
   `script/LaunchConfig.sol`; `eth_feeHistory` over a few thousand blocks).
5. Independent security audit (docs/AUDIT_SCOPE.md) and legal review of the paid chance-based game, Terms, coin and
   name: both before any paid gameplay.
6. **Token-scanner plan for the opening curve.** Decided (owner, 2026-10-30): keep 69% on both buys and sells at launch, one
   point less a minute to the 5% fees in about 64 minutes (`CollectionHook.openingFee()`).
   - [ ] Before launch: publish the curve, with the exact schedule, on the site and in the announcement.
   - [ ] Before launch: pre-notify the common token checkers and scanners and the wallet security vendors that the high
     sell fee is a fixed, time-limited launch curve in the hook: its address, the schedule, and the `openingFee()` view
     to verify it.
   - [ ] Minute ~70: re-check the coin on those scanners and request a re-scan of any cached honeypot or high-tax label;
     on chain, `openingFee()` shows 5% / 5%.
   - The alternative, a lower sell-side peak (30-40%, some early dumping for less scanner risk), was considered and
     not taken.
7. **Day-one fallback.** Decided (owner, 2026-10-30): no commitment to fund the first Ape; the owner plays it by ear.
   The game opens on day one only if the first hour trades about 50 ETH through the curve (sim/results/launch.md,
   pool.md); otherwise it stays in funding mode, with the site's funding bar showing progress, until fees or
   contributions fund the first Ape and the opening capital.
   - [ ] Keep the contributions path (`FundingVault.contribute`, the site's acquire page) visible from minute one.
   - The owner may still at any point sell an Ape to the vault at the bid (`sellToProtocol`) or contribute one
     (`contributeNFT`); neither is planned.

**Prepare**
8. Owner address chosen (`OWNER`: a hardware wallet or multisig). It holds every administrative power (docs/ADMIN.md),
   including the sunset, which ends the game at once into buy-and-burn; no other signer is appointed.
9. Deploying wallet (hardware or keystore) with ≥ 0.25 ETH at ≤ 5 gwei (≈ 0.18-0.23 ETH gas; more if gas is higher).
   Nothing else is funded at deployment: keepers are paid by the game.
10. FWA wallet with ≥ 51,100 FWA (or ≈ 0.17 ETH for the buy route) and ≈ 0.05 ETH for gas.
11. Two keeper hosts with funded keys (≈ 0.1 ETH each) and separate archive RPCs.
12. Fill `script/env/mainnet.env` (`OWNER`, `REF_PRICE_WEI`, `MAX_PRICE_WEI`, coin name and symbol); check the
    external addresses (DEPLOY.md step 1).

**Execute** (each is one signature or broadcast)
13. `script/deploy.sh mainnet` (simulation) → passes the postflight.
14. `I_AM_THE_OWNER=yes … script/deploy.sh mainnet --broadcast` → `deployments/mainnet.json`.
15. Verify source on Etherscan; re-run `Postflight.s.sol` (Admin owner = `OWNER`, no deployer power, MigrationAuthority
    wired with its 72-hour delay, the Sunset and nothing pending, fee recipient = vault, the opening curve 6,900 / 100,
    fees 500 / 500, the cadence and tiers, the fee overflow share, the first threshold = `REF_PRICE_WEI`).
16. FWA wallet: `script/FwaFee.s.sol` (relay route) → FWA pool created and owned by the pool owner.
17. Start the primary and backup keepers.
18. Owner: if the floor has moved since deployment, first `FundingVault.setActivationThreshold` (100% of the new
    floor). Then `ProtocolLiquidity.launch()` (one transaction, no argument, no ETH; it opens at the deployed
    `startTick()`, 173,000 ≈ 30.7 ETH FDV, which the postflight checks): the opening curve starts.
19. Launch hour (docs/RUNBOOK.md "Launch hour"):
    - minute 0-64: anyone may trade; buys and sells pay 69% at once, one point less a minute (≈ 49% at minute 20,
      19% at 50), all to the vault. Early buying is a descending auction (a 1 ETH buy at minute 0 needs about 28 ETH of later
      buying to break even at FDV 30.7, sim/launch.py); expect volume to gather toward minutes 50-64;
    - **accepted risk**: while the sell fee is above about 49% (the first ~20 minutes) wallet scanners may label the
      coin a honeypot, and cached labels can outlive the curve; the transfer restriction (D71) may be flagged for as
      long as it stays on;
    - from minute 64: the ordinary 5% / 5% (`openingFee()` shows 0 seconds to base);
    - minute ~70: the scanner re-check and re-scan requests (item 6);
    - the burner is exempt but holds no ETH until the game distributes; players draw only after activation; no owner
      action is needed in the hour.
20. Wait for funding (first BAYC at the bid, which fills to the floor as fees arrive, then 2.166 ETH for the board and
    reserve plus the opening keeper pay (about 0.05-0.14 ETH, within the 1 ETH allowance), from fees or contributions; the first hour's fees average 39% if
    volume comes evenly: 19.5 ETH on 50 ETH traded, sim/results/launch.md) (no deadline). Activation happens on chain
    when ready; no owner action, unless the first hour traded well short of about 50 ETH: then the day-one fallback
    the owner chose (item 7).

**Optional**
21. Build the site locally with `NEXT_PUBLIC_DEPLOYMENT=mainnet`; publishing is a separate decision. The site shows
    "awaiting the first Ape", "awaiting capital", "technically ready" and "live" as distinct states; technically ready
    is not launched.
22. Later: hand over or renounce administration if wanted (`Admin.transferOwnership` / `renounceOwnership`,
    docs/ADMIN.md). A migration or a new trading-fee recipient only with 72 hours' public notice, and the sunset, by
    docs/MIGRATION.md.
