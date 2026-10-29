# Checks Survival Protocol (working title)

Functional specification, draft 0.3  
October 29, 2026  
Status: Design baseline, incorporating technical feasibility decisions and the existing Black Check ($BLKCHK) protocol review. Not audited, deployed, or approved for launch.  
Naming: The project's final name and ticker are unresolved. `BLACK` is only a placeholder identifier in this document. **Do not launch as Black Check Coin:** Jack Butcher and Jalil already operate a distinct Black Check / $BLKCHK protocol.

## Update summary from draft 0.1

1. Existing **Black Check / $BLKCHK** is acknowledged as a separate protocol. Our product name and token ticker are placeholders requiring a distinct public identity.
2. The only optional BLKCHK integration is **buy BLKCHK and redeem an available Check when it is an attractive sourcing route**. No reverse deposit/mint/sell strategy, arbitrage engine, or BLKCHK dependency.
3. Launch survival measurement is **verified successfully fulfilled FWA draws survived per listing episode**, replacing the earlier proposed risk-weighted exposure implementation.
4. Composition execution uses canonical Checks calls, including the separate 64-single `infinity` operation. Black Check creation requires a gas feasibility test.
5. Sensitive contract and FWA-version upgrades require genuinely independent approval plus a public timelock. Owner-only arbitrary upgrades and treasury withdrawals remain prohibited.
6. All other agreed product mechanics stay intact, including FWA play, decaying notionals, ETH and local-token buyouts, manual composition burns, and no enforced minimum Checks inventory.

## 1. Purpose and product definition

This is an autonomous, long duration Ethereum protocol that acquires Checks NFTs, exposes them to a paid random draw, and gradually composes surviving Checks into rarer artworks. The eventual creation of a Black Check is its stated objective. Creation is neither guaranteed nor required for the system to continue operating.

The protocol has four connected participant activities:

1. Trade BLACK. Protocol trading revenue supplies capital for Checks acquisitions.
2. Play for ETH. An FWA standard custom pool distributes Checks, Shapes, and eligible Shape Packs through random draws.
3. Compose with BLACK. A participant burns a small amount of BLACK to direct an eligible composition. The resulting NFT remains protocol inventory.
4. Collect with ETH or BLACK. A collector can purchase a specific Check at an approved price. An ETH sale returns capital to the treasury. A BLACK sale burns the payment and permanently retires that asset from protocol inventory.

Every listed Check remains available to be won at every tier, including singles and Black Checks. There is no guaranteed progression, no minimum Checks count enforced after launch, no protected permanent jackpot reserve, and no promise that the token represents an ownership claim on treasury assets. The game's distinguishing mechanic is the competition between players removing Checks and the engine composing those that survive. The existing BLKCHK protocol has a different deposit, mint, redeem and permissionless composition system. Our protocol remains independent.

### Core experience

The collection is a public, evolving group of Checks rather than a single jackpot. The working launch model includes approximately 20 original 80 Check NFTs plus inexpensive Shapes and some Shape Packs. Twenty Checks is an illustration for planning and simulation, not a contract requirement. The launch may start differently if inventory and capital permit.

Checks that survive draws become eligible for composition. Additional draws can win them before execution. The system periodically converts eligible pairs into rarer Checks. Every new composite is returned to the game. At the final tier, 64 eligible single Checks may form a Black Check using the canonical Checks operation. The Black Check is also made available for draws and eligible direct purchases.

## 2. Canonical external assets and dependencies

1. Ethereum mainnet is the target network.
2. Checks Editions: `0x34eEBEE6942d8Def3c125458D1a86e0A897fd6f9`.
3. Checks Originals: `0x036721e5A769Cc48B3189EFbb9ccE4471E8A48B1`.
4. Shapes: `0x6fe9193276bf7abcbee44ab7afd717d637d6faf0`.
5. FWA standard custom pool factory at the previously examined Ethereum deployment: `0xF5A3A153164791AB579C3d9ba5DBECf7cDfd300c`. Standard implementation examined: `0xEaa4d032908A9734a2c7939c0D211c35ad51eb31`. Before deployment, reconfirm the actual current factory, implementation, service, eligibility, fees and contract bytecode.
6. Existing, separate Black Check ($BLKCHK) protocol by Jack Butcher and Jalil: `0x718477c471b335ee0ca29b9f4b95edd26d2ede54`. An optional external source of Checks through BLKCHK purchase and `exchange(tokenId)`. **Not** our coin, token infrastructure, or a required dependency.

Checks Editions may be converted into 80 Check Originals. Originals follow the tier sequence `80 → 40 → 20 → 10 → 5 → 4 → 1`. Two equal tier tokens compose into one at each normal step; 64 single Check NFTs are required for Black Check. The canonical Checks rules determine the generated artwork, survivor ID, and lineage; each execution path must follow the actual canonical method requirements, including any relevant staging or epoch behavior. No custom artistic algorithm replaces them.

Shapes are ERC721 NFTs redeemable for exact ETH backing, subject to their own contract rules. The treasury can mint, split, compose, and supply Shapes as inventory. Shape Packs require separate contract, custody, redemption, and ERC721 compatibility verification before inclusion. A Pack must be treated as a prize with known economic cost, not as costless filler.

FWA standard pools deliver a single randomly selected ERC721 per successful purchase. Odds use inverse notional value. The current default owner share is the base expected assigned value plus half of the platform edge; the edge and cooldown are factory controlled. FWA retains custody of listed NFTs. A live draw can prevent withdrawal or repricing until settlement. FWA does not natively execute our composition or per draw notional decay.

## 3. BLACK token

1. A separate ERC20 with fixed initial supply and no post launch mint authority. `BLACK` is a development placeholder; select a distinct name and ticker before public launch. Exact initial supply and final ticker are deployment configuration.
2. Trading fee capture must be explicit and tested for the actual liquidity venue. Prefer a concentrated liquidity fee or supported onchain fee collection arrangement over a general transfer tax, unless simulations and integration testing justify otherwise.
3. After covering strictly capped operating costs, net trading fees acquire Checks. The initial recommended policy is to prioritize Checks acquisitions; any direct fee funded BLACK buybacks must be clearly budgeted separately. Fee percentage and allocation are simulation parameters.
4. Actual distributable game surplus purchases and permanently burns BLACK. BLACK paid for manual composition or a BLACK buyout is burned in the same successful execution transaction.
5. Holders do not receive a guaranteed redemption claim, distribution, minimum price, or proportional title to NFTs. The token is separate from BLKCHK and its minting/redemption rights.
6. Manual composition does not require prior holding duration or staking. The user needs BLACK only when executing the action. This deliberately creates spend demand, not a synthetic holding requirement.

Use a restricted swap adapter for BLACK buybacks. Enforce known tokens and routes, maximum input, slippage limits, a valid TWAP or independently checked quote, and confirmation that acquired BLACK reaches an irrecoverable burn destination. Avoid unlimited approvals and arbitrary executor calls.

## 4. Acquisition engine

### Eligible purchases

Acquire Checks Editions, 80 Originals, and existing composites when price and market depth justify doing so. Also allow an **optional** acquisition path that buys existing BLKCHK on a public market, burns the required amount to redeem a **specific available Check** held by its original protocol, and brings that Check into our treasury. Compare the fully landed cost in ETH per equivalent 80 Original, including marketplace fees, token execution slippage, gas, conversion costs, and likely NFT listing depth. Equivalence is accounting only: an existing composite may have distinctive aesthetic and market value that cannot be inferred from the number of base Originals.

The BLKCHK path is a sourcing option only. There must be no requirement to hold BLKCHK, no dedicated BLKCHK trading strategy, and no attempt to turn our system into an arbitrage business between the two markets.

| Asset | Original equivalent units |
| :--- | ---: |
| Edition after conversion | 1 |
| 80 Check | 1 |
| 40 Check | 2 |
| 20 Check | 4 |
| 10 Check | 8 |
| 5 Check | 16 |
| 4 Check | 32 |
| 1 Check | 64 |
| Black Check | 4096 |

### Execution rules

1. A permissionless keeper may propose a market purchase, but the transaction must pass restricted target and spend rules and end with the expected NFT in protocol custody. The owner must not have a generic ETH transfer or marketplace execution ability.
2. Quote age, maximum ETH cost, minimum inventory value, collection allowlist, token ID and marketplace target must be validated. A failed fill reverts without consuming treasury assets.
3. An acquired Edition migrates to an Original before it is placed in the game. Respect the Checks commit and reveal lifecycle as required by the actual contract.
4. An acquired composite enters at its actual canonical tier. A newly acquired Check begins a new protocol survival cycle with no inherited game exposure. Its original Checks lineage is preserved onchain.
5. A BLKCHK redemption may execute only after verifying the target Check is actually redeemable, the exact token burn amount is available, the total execution cost is less than an acceptable alternative purchase or independently approved budget, and the NFT ends in our treasury. The route must fail safely if the NFT is redeemed or composed by another participant first. Use a narrowly permissioned adapter with exact token allowances; no general BLKCHK swap or NFT-transfer authority.
6. **Do not deposit our Checks into the external Black Check contract to mint and sell BLKCHK.** Do not build a spread-capture engine, systematic two-way arbitrage, BLKCHK liquidity provision, or BLKCHK price support. Even if a spread appears profitable, that activity lies outside product scope.
7. No order must be executed merely to maintain 20 Checks. Acquisitions occur when funding and valid opportunities exist.

## 5. Inventory and play

### Inventory classes

1. Checks Originals at any canonical tier, including single and Black Checks.
2. Shapes at permitted denominations, with actual ETH backing.
3. Verified Shape Packs as additional ERC721 prizes, if their compatibility and collateral mechanics pass testing.

Every prize has a unique identity and one authoritative lifecycle state. The protocol must distinguish treasury custody, listing in FWA, pending draw reservation, claimant entitlement, composition withdrawal, completed sale, and migration. An NFT cannot simultaneously be sold, composed, or delivered to two recipients.

### Draw behavior

1. ETH purchases use FWA's standard custom pool acquisition interface and real time quote, including VRF service cost shown separately and in the total.
2. FWA decides the selected NFT with its verifiable randomness and existing ordered processing, refunds, and delivery semantics.
3. A selected Check leaves the engine permanently and its survival progress ends. A selected Shape or Pack leaves in the normal way.
4. The UI always shows current active inventory, assigned notionals, per item odds, probability of any Check, and estimated total draw cost. It must distinguish a live quote from an illustration.
5. An available Checks count may fall to zero. Never mint fictitious Checks or block composition to enforce a minimum. If there are no eligible prizes or the purchase gate is closed, purchases are unavailable.

### FWA constraints

Only the controller may act as pool owner and depositor. Active listing changes require a clear unresolved request queue. A new inventory or price change starts the current FWA cooldown. Deposits during pending draws may stage. A retired pool cannot accept new inventory or reprice, so routine composition must not use permanent retirement.

FWA refund and failed delivery recovery must respect the named purchaser's entitlement. Owner recovery of a refunded NFT must route it back to treasury through the controller. No custom intervention may reroll or redirect an already committed draw.

## 6. Composition and survival

### Principle

A Check earns eligibility by surviving meaningful gameplay. Composition is gradual, public, and interruptible by normal FWA draws until execution. No two Checks are automatically merged merely because they coexist in the pool.

### Verified successful draws survived (V1 decision)

Use **completed, successfully fulfilled FWA draws survived** as the V1 composition eligibility metric. This supersedes the original proposal to calculate historical cumulative per-NFT selection probabilities. FWA's per-request historical odds are harder to reconstruct and validate trustlessly than completed draw state. Risk-weighted exposure can be reconsidered in a future audited upgrade.

For each Check, maintain a distinct active listing episode and its `enteredAfterSequence` (or equivalent verified start cursor). Count only subsequent, canonical, successfully fulfilled FWA draw sequences for which this exact listing remained active and eligible for selection. The Check must still be under protocol control when composition begins. Refunded, expired, failed, duplicate, or pre-entry requests yield no survival credit. A draw that selects the Check ends that Check's listing episode and it cannot qualify for composition.

A permissionless checkpoint processes FWA's ordered public records, including request sequence to request ID mappings and acquisition final statuses. The checkpoint must verify those data from the deployed FWA pool, proceed monotonically, and remain gas bounded. An indexer may present a speculative display meter but cannot grant composition eligibility. Do not count offchain button clicks, raw VRF requests, or merely issued but unresolved draws.

At each new listing episode, establish an unambiguous active start state after any staged inventory is activated, and reject claims if the listing was removed, changed in a way that invalidates the episode, or is subject to outstanding draw commitments. The current FWA interfaces appear to expose the needed data; exact ABI compatibility, ordering assumptions and fork execution tests are required before mainnet use. New FWA versions must pass the same adapter-level validation.

Each tier has a configurable required draw count and an upper bound on composition frequency. This makes progression dependent on active play without obligating the system to merge all available Checks as soon as possible. Decay likewise uses the verified draw counter, applied at bounded repricing checkpoints.

### Eligibility and execution

1. Two living Checks at the same nonfinal tier must both meet their current tier successful-draw survival thresholds. Neither may be reserved for a buyer, already sold, or mid composition.
2. Only a bounded number of compositions can execute per maintenance interval. Candidate priority is highest qualified tier first, with deterministic selection if nobody exercises manual artistic control.
3. A manual participant chooses an eligible pair and which token ID survives, then burns a small tier configured amount of BLACK as part of successful execution. A failed or stale execution burns no BLACK.
4. The participant's address, selected input IDs, resulting ID, tier, and transaction hash are recorded in an event and public history.
5. If no participant acts during a short configurable decision window, a permissionless keeper executes the deterministic fallback without a token burn.
6. The controller pauses new purchases if needed and waits for all FWA draws to become terminal. Inputs are withdrawn to treasury; composition is executed using the canonical Checks contract and its actual required steps. The resulting NFT is listed again with fresh initial notional and a new zero-count survival episode. The BLACK burn and final canonical composition are atomic; an interrupted or failed attempt burns nothing.
7. A Check stays at risk of being won up to the point its withdrawal succeeds. Where the external Checks operation needs multiple transactions or blocks, the withdrawn inputs are temporarily unavailable for FWA draws; the keeper must finish or follow a bounded, public recovery path.
8. Single Checks do not pair into Black. The canonical `Checks.infinity(uint256[] tokenIds)` requires exactly 64 eligible single Checks in one call; the first selected token survives. Its gas cost, authorizations and ordering assumptions require mainnet fork tests. Do not promise a Black Check can be created until the full 64-token transaction's feasibility is established.
9. Sacrifice, the separate Checks artwork operation that changes aesthetics without progressing tier, is excluded from the initial version. It may be added through reviewed governance later.

## 7. Assigned value and per draw decay

Each Check has three separate financial measurements:

1. `acquisitionCost`: historical actual ETH capital used to acquire the constituent inventory, for accounting.
2. `replacementEstimate`: conservative current ETH cost to acquire an economically comparable Check or the necessary constituents, used for treasury risk and direct buyout pricing.
3. `assignedNotional`: FWA selection value. It determines prize odds and contribution to the draw quote, and can intentionally be below market replacement value as part of the game's prize subsidy.

### Decay policy

1. On listing a new Check, set its notional using a published tier and market aware pricing rule, with independent review of externally sourced market quotes.
2. After verified successful FWA draws survived within the current listing episode, accrue deterministic decay credit. Repricing applies decay in bounded batches to limit FWA cooldown interruptions. Counting and repricing must reference the same canonical draw cursor, avoiding skipped or double-applied increments.
3. Composition resets decay for the resulting Check, assigning a new initial value and a new survival episode. A migration to a new FWA pool does **not** erase accrued protocol history or draw credit unless the public migration rules explicitly require a justified reset.
4. Every tier, including Black, has a positive minimum assigned notional. The curve must allow the probability of a long surviving Black Check to rise meaningfully if draws continue, without promising a finite guaranteed draw count.
5. No owner function may freely set an arbitrary low initial price or instantaneously accelerate a rare Check's decay. Price setting and curve changes require the defined governance and safety controls.
6. Live market appreciation may cause replacement estimates to increase and expose losses if notional lags. The protocol must have bounded stale quote handling and a safety pause. The published decay rules must specify when upward revaluation is allowed and how prior decay credit is treated, so administrators cannot indefinitely reset the race.

The economic shortfall when an NFT is won below its present replacement value is an intentional prize subsidy funded by accumulated protocol activity. A decreasing assigned value increases winning probability, but it does not guarantee recovery of the NFT's replacement value before award, nor a guaranteed finite draw count for a Black Check. The strategy needs explicit accounting for potential subsidy and an independent stale-market purchase gate. Do not count historical appreciation as realized profit or promise automatic replacement. Simulations must include early wins, sudden price appreciation, multiple prize wins, empty inventories, and prolonged inactivity.

## 8. Direct purchases and BLACK burns

### ETH purchase

An interested collector may request an atomic ETH purchase of a specific Check at an approved quote that covers conservative current replacement cost plus the policy markup, fees and slippage. On success, the Check leaves the game. Net ETH is credited to treasury. Realized available surplus may fund acquisitions or BLACK buybacks according to the treasury waterfall.

### BLACK purchase

An interested collector may request a purchase of the same eligible Check, priced in BLACK using an approved, manipulation resistant conversion rule and a materially higher premium than an ETH purchase. All BLACK paid is destroyed as part of the successful purchase. No ETH is received, and the NFT is permanently removed from engine inventory. This is a deliberate conversion of previously acquired inventory into supply reduction. It must be recorded as depletion of inventory capital, not revenue.

### Execution and fairness

1. Neither route guarantees the buyer a future claim at a fixed price. Quotes expire and can be disabled when price or market integrity is uncertain.
2. A buyer submits an intent and an execution transaction. A Check remains eligible for ordinary draws until withdrawal succeeds. If it is won before execution or a draw remains unresolved, execution waits or reverts without collecting payment.
3. Stop new draws, settle existing requests, and withdraw the exact Check to treasury before effecting a valid sale; combine withdrawal and payment in one transaction where FWA and gas permit. Do not allow a buyout to cancel already outstanding player entitlements.
4. Use the same publicly disclosed policy for all collectors. Owner and council members do not receive special sale prices or privileged execution paths.
5. Price cannot be set to zero, overridden by the owner, or calculated solely from a manipulable BLACK spot pool. Allow a disabled buyout state when the quoted BLACK amount is impossible or unsafe given supply and liquidity.
6. All tiers, including single and Black, may be offered via these routes when valid pricing is possible. They always retain the FWA prize route. No compelled cheap redemption of a Black Check.

## 9. Revenue, treasury, and inventory economics

Track four separate balances or ledger categories:

1. Checks acquisition budget from token fees and any explicitly allocated external capital.
2. Shapes and Packs backing and working inventory cost.
3. Actual FWA owner proceeds and realized ETH direct sale proceeds.
4. Operating reserve and distributable buyback budget.

On each successful draw FWA accrues owner proceeds according to the assigned expected value and current fee parameters. Those proceeds are pooled revenue, not automatically item specific profit. The engine must account for all prize depletion, backing replacement, payouts and liabilities before declaring distributable profit.

Recommended waterfall:

1. Honor outstanding player credits and protocol obligations.
2. Cover safe operation, servicing, keeper and randomness related protocol costs that are not already paid directly by players.
3. Replenish Shape and Pack working capital and maintain a bounded reserve for volatility, refunds and early prize wins.
4. Fund ongoing Checks purchases or future game inventory at the approved policy allocation.
5. Spend genuinely distributable ETH on BLACK market purchases and permanent burns.

Do not require replenishing every Check immediately. An awarded Check is a valid inventory outflow; inventory may contract. Do not spend the same proceeds twice by treating full prize revenue as profit while simultaneously promising replacement at new market prices.

For simulation, test effective token fees, draw frequency, Checks acquisition costs, successful draw thresholds, composition frequencies, prize probabilities, cumulative BLACK burns, liquidity impact, keeper gas and all FWA platform parameter changes. Include optional BLKCHK redemption only as a choice of input acquisition cost, never as a source of assumed trading or arbitrage profits. The objective is a system that still offers a compelling game and some future acquisition capacity when BLACK speculative trading slows; it cannot promise those outcomes without sufficient outside activity.

## 10. Custody, upgradeability, permissions, and migration

### Chosen trust model

The protocol must remain improvable, including changes to its economics, composition logic, and future FWA integrations. Use upgradeable protocol modules and a review process for sensitive upgrades, while making it impossible for the project owner alone to upgrade into an asset draining implementation.

A fully upgradeable treasury necessarily carries governance risk: an independently authorized malicious implementation could misappropriate assets. Disclose that plainly. A multisig and timelock distribute and delay that authority; they do not mathematically eliminate it.

### Components

1. `BLACK`: fixed supply ERC20 and explicitly bounded fee integration.
2. `TreasuryVault`: upgradeable custody and fund accounting with restricted approved trading, NFT acquisition, game inventory, burn and buyout pathways. No arbitrary ETH transfer, NFT approval, external call or operator withdrawal route.
3. `ChecksEngine`: upgradeable acquisition, migration from Editions, composition eligibility and lifecycle coordination.
4. `GameAccounting`: verifies FWA draw progress, decay credits, price updates and withdrawal requests.
5. `FwaPoolControllerVn`: separate dedicated controller for each FWA pool, preferably immutable during that pool's lifetime. The controller creates the pool, owns it, deposits every NFT as original depositor, routes all ordinary withdrawals back to the vault and pays FWA owner proceeds into the vault. The controller has no arbitrary execution or ETH transfer method.
6. `PricingGuard`: independent market quote attestations, enforced expiry, tier verification, bounded decay parameters and emergency halt. The draft security PoC uses two independent signers for initial price approval. A production design must additionally secure live repricing and buyouts.
7. `ProtocolTimelock` and `SecurityCouncil`: govern all proxy upgrades, new implementation approvals, new pool controllers, treasury permissions, pricing policy changes and council changes.
8. Permissionless keepers and indexers: propose routine operations, record the artwork's public history, and submit state changes subject to onchain validation.
9. **Optional `BlkchkRedeemAdapter`:** only purchase the required BLKCHK for one specified existing Check and redeem it into the treasury when this is an attractive acquisition route. It has no mint/deposit/sell interface for external BLKCHK, no automatic speculation, and no user authority over its transfer destination. The core engine must run with this adapter disabled.

### Authority model

1. Project operator may propose changes, run keepers, trigger restricted maintenance and emergency pause. They have no unilateral proxy upgrade authority and no general treasury withdrawal function.
2. Sensitive actions require an independent council, tentatively three of five signers including a majority independent of the project owner, followed by a seven day public timelock. Exact membership and thresholds must be established before deployment.
3. Guardian role may cancel or halt a dangerous upgrade or stop new purchases without blocking existing FWA entitlements.
4. Routine parameter changes are restricted to audited bounds and cooling periods. Any change that can redirect custody, broaden ETH spends, alter admission of new code, or reprice valuable inventory outside approved bounds is sensitive governance.
5. Council membership replacement and upgrades to the governance contracts themselves require the same or stricter process. Project owner must not be able to replace independent signers unilaterally.

### FWA pool migration procedure

1. Publish exact proposed new FWA factory, implementation, controller, addresses, code hashes, and changes. Obtain independent security approvals and finish the timelock.
2. Pause purchases in the old pool. Stop new commitments, settle or expire all outstanding draw requests, preserve buyer claims and wait for any pending delivery recovery.
3. Withdraw available listings and owner proceeds through the original controller directly into the treasury. Inventory in refund or delivery escrow must follow FWA's valid recovery path.
4. Reconcile every token ID, ETH balance, FWA status, and preservation of survival and lineage records. Any unresolved item stays associated with the old pool until properly recovered; never write it off as migrated.
5. Create a new approved FWA pool through a new compatible controller. Deposit vault assets and activate listings only after ownership and safety checks pass.
6. Resume draws. Historical progress remains linked to the original token IDs and original protocol accounting. Retire the old pool only when its allowed recovery and closeout functions are understood.
7. A migration may be delayed by unavailable FWA services or pending deliveries. No timeout grants owner custody or bypasses player entitlements.

A new FWA implementation is inherently new code that will hold deposited NFTs. Its approval cannot be fully automated by a fixed compatibility signature. Security council review, bounded initial exposure, a public delay and independent audits mitigate this residual risk.

## 11. Keeper operations and failure recovery

Keepers are untrusted convenience operators. Anyone can execute an eligible deterministic maintenance transaction. The keeper must never be able to make a trusted claim about draw count, choose arbitrary transfer destinations, invent prices, or exceed treasury spend limits.

Routine tasks include purchasing Checks, converting Editions, splitting Shapes, monitoring FWA settlement, applying decay, coordinating compositions, collecting FWA proceeds, executing approved BLACK buys, processing ETH or BLACK buyouts, and performing authorized migrations.

If the keeper stops, existing draws, refunds and valid claims remain available through FWA. New acquisitions and compositions may stop, but an independent keeper can resume them. If external market price information becomes stale, new purchases or repricing sensitive actions fail closed, with a public safety mechanism to disable new pool draws. An onchain gate should enforce emergency pause without depending on the stopped keeper wherever FWA allows it.

Treat unexpected NFT transfers or ETH sent to the protocol as quarantined surplus until a reviewed recovery policy is defined. They must not create a generic owner sweep path.

## 12. Frontend requirements for version one

### Home

Explain the survival game in simple terms, using the final distinct project name. Show the protocol token supply and cumulative burns, Checks acquisition count, current tier distribution, total Checks won, total compositions, and progress toward Black. Avoid an invented treasury backing value for BLACK.

### Play

Show active FWA inventory, odds of winning any Check, high tier odds, live cost per pull inclusive of the separate randomness fee and player gas estimate, purchase action and status of pending draws, refunds and delivered NFTs. Make the actual prize odds and current notionals accessible before purchase.

### Checks collection

Show every currently held or listed Check with token ID, canonical tier, image, lineage link, current market estimate, assigned notional, cumulative game survival progress, decay progression, acquisition date, whether it is eligible to compose, and whether it is available to be won or bought. Show winners, removed tokens and composites in a permanent historical view.

### Compose

Show eligible input choices, survivor selection, canonical artwork preview when possible, cost in BLACK, irreversible nature of the burn, and execution status. If another draw wins the selected NFT first, the user's attempted composition must fail cleanly without burning BLACK.

### Collect

Show ETH or BLACK buyout quotes for eligible NFTs, clear distinction between acquiring via payment and winning via chance, expiry, success or failure, and permanent token burn effects. Buyout quotes only appear when the contract can actually execute the relevant safe path.

### Activity and trust

Provide a readable ledger of acquisitions, Editions conversions, compositions, wins, ETH sales, BLACK buyout burns, manual composition burns, game earnings and buybacks. Surface protocol upgrade proposals, approval parties, execution delays, active FWA pool address, and administrative permissions.

Mobile first. Avoid an additional social network, staking dashboard, gamification currency, or complicated token governance UI at launch.

## 13. Simulation and security acceptance criteria

### Economic simulations

Model at minimum 0, low, moderate and high BLACK organic trading; low, moderate and high player draw volume; rising, falling and discontinuous Checks markets; thin listing depth; high Shape replenishment costs; multiple early rare wins; no keepers for an extended period; and a Black Check entering with high assigned notional. Report treasury ETH, count of each Check tier, composition progression, eventual survival odds, expected prize value, realized game profit, BLACK purchases and burns, total gas and failure probability. Do not equate expected value with guaranteed realized proceeds.

### Smart contract acceptance tests

1. Actual Checks Edition migration, pair composition, single Check and Black Check batch or multi transaction composition on a mainnet fork.
2. Actual FWA factory pool creation by controller, permanent owner identity, inventory listing, repricing, acquisition, VRF fulfillment, refunds, failed delivery recovery, proceeds payout and withdrawal.
3. No owner extraction through ordinary calls, marketplace routes, malicious tokens, arbitrary approvals, false prices, composition, buyout, optional BLKCHK adapter misuse, guardian misuse, or upgrade proposal alone.
4. Pending draw cannot be canceled or redirected by an NFT sale, composition or migration.
5. Every successful BLACK composition or buyout burns the exact amount once. Every failed or stale transaction burns zero.
6. Successful draw survival and decay cannot be inflated by owner, keeper, indexer, duplicate reports, pending or refunded draws, staged inventory, or withdrawal/relisting episodes. Verify the correct sequence window on the actual FWA implementation.
7. A future FWA implementation can be approved and migrated to under the full independent governance path. The owner alone cannot approve it.
8. Countermeasure to compromised council, governance timelock failure, stale or malicious pricing input and malicious new pool code is documented and exercised in simulations.
9. All critical live value paths are protected against reentrancy, bad ERC721 receivers, gas exhaustion, stale prices, slippage and asset accounting errors.
10. Optional BLKCHK redemption verifies an actual available NFT, burn amount, executable price and treasury receipt; competing redemptions revert safely. No route allows the protocol to deposit Checks into BLKCHK to mint or sell BLKCHK.
11. Independent security review is completed before launching with meaningful funds or valuable Checks.

Separate from contract testing, obtain a legal review of paid random draws for transferable NFTs and token buyback or redemption mechanisms in relevant jurisdictions.

## 14. Decisions and parameter register

The following are recommendations or calibration inputs, not settled economic promises.

| Parameter or question | Recommended starting direction | Decision status |
| :--- | :--- | :--- |
| Launch pool | FWA standard custom pool | Agreed direction |
| Initial Checks inventory | Approximately 20 80 Checks for modeling | Assumption only, no minimum |
| Shapes and Shape Packs mix | Primarily redeemable low denomination prizes | Simulate; verify Packs |
| Trading fee | Evaluate sustainable effective rates and liquidity impact | Open |
| Trading fee allocation | Favor Checks acquisition after bounded costs | Draft default |
| Game surplus allocation | Reserve and inventory first, then BLACK buy and burn | Agreed principle; thresholds open |
| Survival | Verifiable successful FWA draws survived per listing episode | Source-level direction agreed; EVM verification pending |
| Composition cadence | Tier dependent threshold and one bounded action per maintenance window | Calibrate |
| Manual composition fee | Small tier specific amount of BLACK, 100% burned | Agreed principle; amount open |
| Decay | Verified successful draws, tier specific decay curve, bounded batching | Agreed principle; rates open |
| Direct ETH buyout | Above conservative replacement estimate | Supported direction; markup open |
| Direct BLACK buyout | Premium quote, full burn, no ETH recovery | Supported direction; safeguards open |
| Highest tier policy | Black stays winnable and optionally purchasable if safely quoted | Agreed direction |
| Keeper | Permissionless and incapable of inventing privileged state | Required |
| Upgradeable protocol | Independently approved sensitive upgrades | Agreed direction |
| Upgrade council | Tentative 3 of 5 independent signers, seven day delay | Membership and thresholds open |
| BLKCHK integration | Optional buy + burn + redeem of a specific available Check only | Direction agreed; quote and adapter testing pending |
| BLKCHK arbitrage/minting | Excluded. No deposit of our Checks to mint/sell external BLKCHK | Explicitly out of scope |
| Public project name/ticker | Must differ clearly from Jack and Jalil's Black Check / BLKCHK | Open, prelaunch |

## 15. Build order and launch gates

### Phase A. Technical verification

Run the existing V2 immutable controller PoC Solidity tests and FWA mainnet fork, recognizing that its identical-code upgrade restriction is superseded by independently approved upgrades. Check all FWA interfaces used in this spec. Test real Checks composition and 64 single Black creation feasibility. Verify successful draw counting against real FWA ordered state, admission/start sequence and refund paths. Confirm Shape Pack compatibility and FWA public launch access. If using BLKCHK, test a bounded redeem of one actual Check with a mocked market quote before authorizing the adapter. Do not deploy or spend mainnet funds.

### Phase B. Economic simulation

Implement a deterministic state machine and Monte Carlo model for a collection of Checks at multiple tiers, actual FWA odds, successful-draw survival, price decay, composition, direct buyouts, and token fee funded acquisitions. Calibrate thresholds using realistic marketplace depth and keeper costs. Explicitly choose acceptable inventory depletion and effective BLACK burn policy.

### Phase C. Protocol implementation

Implement upgrade governance, custody, restricted acquisition and burn adapters, controller, accounting, decay, manual composition, and buyouts. Use supported existing OpenZeppelin building blocks and pin dependencies. Run unit, invariant, fuzz, integration and fork tests.

### Phase D. Test deployment and audit

Run long duration lifecycle tests, adversarial governance and migration tests, and actual game transactions on test infrastructure. Obtain independent audits and legal review. Publish roles, contract addresses, financial policies, known risks and migration procedures.

### Phase E. Mainnet launch

Launch the final, distinctly named token with verified fixed supply and disclosed fee routing. Start the standard FWA pool with actual funded inventory, clear outstanding operational and legal gates, open purchases when eligible, and publish live transparency metrics. Permit future feature activation only through governed, audited releases.

## 16. Boundary with the existing Black Check / BLKCHK project

The existing BLKCHK protocol predates our design. Its published mechanism is to mint BLKCHK when a person deposits Checks, burn BLKCHK to redeem specific Checks, and allow permissionless composition. BLKCHK's maximum supply is one whole token, with tier-based accounting. It is an independent creative work and economic system, not a protocol-controlled treasury for our game.

Our distinctive system is the **play-driven survival and composition race**, with decaying notional values, Shapes inventory, selective direct ETH or local-token buyouts, and local-token burns for manual artistic choices. It must not imply endorsement by or affiliation with Jack Butcher, Jalil, or the existing BLKCHK protocol unless permission is actually obtained.

The only planned optional integration is **one-way sourcing of a specific Check via BLKCHK redemption when it is the best sound acquisition path**. No two-way BLKCHK spread trading, no deposits to mint BLKCHK, no active market making, no fee diversion into BLKCHK, and no cross-protocol dependency. The adapter is permissioned narrowly enough to leave the protocol fully functional without it.

The final project name and token ticker must be distinct from Black Check and BLKCHK. The placeholder BLACK in this functional spec identifies our own hypothetical token, not the existing BLKCHK token. Public product, branding and legal review are separate prelaunch gates.

## Source references

1. Checks canonical contracts and tier mechanics: https://github.com/visualizevalue/checks-contracts
2. Checks project history and Edition conversion: https://www.jack.art/checks-originals
3. FWA standard pool and inverse odds: https://v1.fwa.fun/docs/custom-standard and https://v1.fwa.fun/docs/custom-pools
4. FWA creator controls and migration constraints: https://v1.fwa.fun/docs/custom-manage
5. FWA settings, fees and pending draw semantics: https://v1.fwa.fun/docs/custom-settings
6. FWA purchase eligibility gate interface: https://www.fwa.fun/docs/custom-gating
7. Shapes interfaces, backing and custody integration: https://shapes.ripe.wtf/docs and https://shapes.ripe.wtf/docs/integrating
8. Controller PoC V2 from this conversation: `black-check-controller-poc-v2.zip`. Its Solidity and fork tests are written but have not been compiled or executed.
9. Black Check / BLKCHK official whitepaper, issued by Jack Butcher and Jalil: https://github.com/visualizevalue/vvhitepapers/blob/main/projects/black-check.md
10. Canonical BLKCHK on Ethereum: https://etherscan.io/address/0x718477c471b335ee0ca29b9f4b95edd26d2ede54