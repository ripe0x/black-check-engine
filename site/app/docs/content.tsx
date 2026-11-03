"use client";

import Link from "next/link";
import { collectionMeta } from "../lib/deployment";
import { ApesLive, BidLive, BoardLive, BooksLive, BurnsLive, ChangesLive, ContractsLive, MigrationLive, SweepLive } from "./live";

// The docs' pages by slug (see nav.ts for their order and titles). Reference detail lives here so the player pages
// can stay short. Each page uses h2 headings, which the shell lists under "On this page".

const ape = collectionMeta.short, apes = `${ape}s`, coin = collectionMeta.ticker, game = collectionMeta.game;

export const DOCS: Record<string, () => React.JSX.Element> = {
  "": () => (
    <>
      <p>{game} is an on-chain prize draw for {collectionMeta.name}. Pay ETH to draw, and win one prize from the pool at
        random: an {ape}, or an ETH-backed Shape or Pack. The {coin} coin funds the {apes}: every trade pays a fee into
        the protocol, which buys {apes} for the pool, and what the game earns buys {coin} back and burns it.</p>
      <h2>The loop</h2>
      <ol>
        <li><b>Trade {coin}.</b> Each buy and sell pays a fee in ETH to the funding vault.</li>
        <li><b>The vault buys {apes}.</b> Fees fill a live bid any holder can sell into; every {ape} it holds joins the draw.</li>
        <li><b>Players draw.</b> Each draw takes one prize from the pool by verifiable randomness.</li>
        <li><b>Game revenue buys back {coin}.</b> The game&apos;s earnings buy and burn the coin.</li>
      </ol>
      <h2>What runs it</h2>
      <p>Draws use FWA&apos;s V2 pool contracts with Chainlink VRF randomness. The coin trades on Uniswap v4. Shapes are
        NFTs from the Shapes contract that hold exact ETH. Everything is autonomous smart contracts; the site holds no
        funds.</p>
      <h2>Not yet audited</h2>
      <p>No independent audit has been done. Read <Link href="/docs/risks/">Risks and audit status</Link> before you play.</p>
    </>
  ),

  draws: () => (
    <>
      <h2>One draw</h2>
      <p>You pay the ticket and a randomness fee in one transaction. FWA asks Chainlink VRF for a random word; when it
        arrives, usually within a minute, the word picks one prize and it is sent to your wallet.</p>
      <h2>Several at once</h2>
      <p>A batch is several draws in one transaction. Each draw is decided separately, by its own random word.</p>
      <h2>Upkeep with your draw</h2>
      <p>When there is light upkeep to do (booking settled draws, sweeping the bid), the draw does it and the game pays you
        back for the gas within its keeper allowance. Earlier draws that are ready are settled first, at your gas.</p>
      <h2>If something goes wrong</h2>
      <p>If the pool changes by more than 10% before your draw settles, or the randomness is late, FWA refunds the ticket
        and you withdraw it. If a prize cannot be delivered to your wallet, you can retry the delivery or take a refund.
        Both appear under the draw button when they apply.</p>
    </>
  ),

  odds: () => (
    <>
      <h2>Inverse to value</h2>
      <p>Every prize&apos;s chance is inverse to its listed value: a prize listed at half the value is twice as likely.
        The chances shown are read from the pool when you look.</p>
      <h2>Why they move</h2>
      <p>Odds change whenever prizes are won, replaced, added or repriced, including between your quote and your draw
        settling. Each {ape}&apos;s listed price falls with gameplay, so its odds improve while it stays in the draw (see{" "}
        <Link href="/docs/apes/">{apes}</Link>).</p>
      <h2>Expected value</h2>
      <p>A draw costs more than the average prize is worth. Most draws win a small Shape and return less than they cost.</p>
    </>
  ),

  costs: () => (
    <>
      <h2>What you pay</h2>
      <ul>
        <li><b>Ticket:</b> FWA&apos;s acquisition fee, the pool&apos;s average listed value plus FWA&apos;s edge.</li>
        <li><b>Randomness fee:</b> FWA&apos;s VRF fee, which rises with gas prices. It is not refunded.</li>
        <li><b>Gas:</b> about 0.64M for one draw, more for upkeep or settling earlier draws.</li>
      </ul>
      <h2>Refunds</h2>
      <p>A ticket is refunded if the pool moves more than 10% before settlement or the randomness is late. The randomness
        fee is not. Refunds are withdrawn from FWA; the play page shows a Withdraw button when you have one.</p>
      <h2>Redeeming prizes</h2>
      <p>Burning a Shape for its ETH, or opening a Pack, costs its own gas (about 0.1-0.2M). A prize listed above the ticket
        price is not a profit once these are counted.</p>
    </>
  ),

  apes: () => (
    <>
      <p>Every {ape} the protocol holds is in the draw. It opens at a share of the price the protocol paid, and its listed
        price falls with gameplay, not time: settled gameplay is credited evenly to the {apes} in the draw, and each ETH
        credited lowers its listed price by a fixed amount, down to a floor. A lower price means better odds. A listed price
        never goes up.</p>
      <ApesLive />
      <h2>The exposure target</h2>
      <p>The {apes}&apos; share of a draw&apos;s expected value is held at or below a target. When the falling prices or a
        new {ape} would pass it, the protocol adds Shapes and Packs to the board instead, and the price falls wait until
        they are listed. With many {apes}, the target is usually what binds, so the chance of winning some {ape} stays
        near its level rather than rising. No win date is promised.</p>
    </>
  ),

  shapes: () => (
    <>
      <h2>Shapes</h2>
      <p>A Shape is an NFT from the Shapes contract that holds an exact amount of ETH. Whoever owns it can burn it at any
        time and the Shapes contract pays out that ETH. Nobody can stop or change that.</p>
      <h2>Packs</h2>
      <p>A Draw Pack is an NFT from this game&apos;s own Packs contract holding the fewest Shapes that add up to its value:
        a 0.02 Pack is two 0.01 Shapes, a 0.15 Pack a 0.1 and a 0.05. Its owner can open it to take the Shapes, or redeem
        it for their ETH.</p>
      <h2>Listed value and redeemable value</h2>
      <p>The game lists each Shape at its full replacement cost (the backing plus the Shapes mint fee for each Shape) plus
        a markup. What you redeem is the backing. Odds follow the listed value.</p>
    </>
  ),

  board: () => (
    <>
      <p>The board is the set of ordinary prize rows. Each row holds a Shape or Pack from the board&apos;s pattern, set by
        the owner and applied the next time the row is listed. It is replaced after each win.</p>
      <BoardLive />
      <h2>Growth</h2>
      <p>The board grows as the {apes} need it: when the {apes}&apos; share of expected value would pass the exposure
        target, the game lists more rows, paid from trading fees, before any {ape} reprices further. It can also be sized
        by the owner.</p>
    </>
  ),

  fees: () => (
    <>
      <h2>The ordinary fee</h2>
      <p>Every buy and sell of {coin} pays a fee in ETH, set by the owner and capped by the hook at 10%. It is 5% at
        launch.</p>
      <h2>The opening curve</h2>
      <p>From the pool&apos;s one initialisation, swaps pay the higher of the ordinary fee and an opening fee that starts at
        69% and falls one percentage point a minute. At a 5% fee it reaches the ordinary fee in about 64 minutes and never
        returns.</p>
      <h2>How it is charged</h2>
      <p>Always in ETH: out of the ETH paid on a buy, out of the ETH received on a sell. Buys can be for an exact ETH input
        or an exact coin output; sells only for an exact coin input. The burner&apos;s own buybacks pay no fee.</p>
      <h2>One pool only</h2>
      <p>{coin} trades only in its own Uniswap pool, so every trade pays the fee that funds the game. It cannot be sent
        from one wallet to another, deposited on an exchange or traded in another pool: those transfers fail. Buy and
        sell here or through Uniswap. The owner can lift this once, for good, and it cannot be turned back on.</p>
    </>
  ),

  "fee-flow": () => (
    <>
      <h2>Into the vault</h2>
      <p>Every trading fee goes to the funding vault. Its first use is the game&apos;s capital and the board growth the
        {apes} wait for; then the live bid for the next {ape}.</p>
      <h2>The overflow</h2>
      <p>Off at launch: every fee stays in the vault for {apes}. The owner can turn it on: then, while the live bid is full
        and the vault already holds the next {ape} beyond it, a share of the fees received since the last sweep goes to
        buybacks instead, never the game&apos;s capital, the bid&apos;s ETH or the next {ape}.</p>
      <h2>Changing the recipient</h2>
      <p>Where fees go can change only after 72 hours&apos; public notice, to code that was proposed (see{" "}
        <Link href="/docs/governance/">Owner powers</Link>).</p>
    </>
  ),

  buybacks: () => (
    <>
      <h2>Where the ETH comes from</h2>
      <p>The game&apos;s realised surplus: up to 35% goes to the vault while it cannot yet afford the next {ape} at the last
        price, and the rest to the burner, plus the vault&apos;s fee overflow.</p>
      <h2>Milestones</h2>
      <p>All of the game&apos;s surplus waits in a pot until someone pulls an {ape}: that pull releases the whole pot to
        buy and burn {coin}. Gameplay&apos;s buy-and-burn builds up for that moment instead of dripping out. Shapes and
        Packs, however big, release nothing.</p>
      <h2>Cadence</h2>
      <p>Released ETH is spent in slices of at most 1 ETH, ten minutes apart, each with a price limit, so a big release
        burns over the next hour or so rather than in one buy bots could front-run. Other ETH the burner receives is spent
        in smaller slices that follow play. Everything bought is burned.</p>
      <p><Link href="/docs/burns/">See every burn</Link>.</p>
    </>
  ),

  "live-bid": () => (
    <>
      <p>The protocol keeps one live bid for {collectionMeta.name}, made of real ETH from trading fees. Any holder can sell an
        {" "}{ape} into it at a price up to the bid, in one transaction: the NFT moves to the protocol and the ETH to you, or
        nothing happens. No royalties apply.</p>
      <BidLive />
      <h2>How it fills</h2>
      <p>Below the fill threshold, available ETH enters the bid at once. Above it, ETH is metered in a fixed amount per
        cooldown, and more slowly again above the ceiling. Nothing rises with time alone. A sale takes its price out of the
        bid; whatever is left stays in it.</p>
      <h2>Contributions</h2>
      <p>{apes} can also be contributed (<code>contributeNFT</code>). Contributions are irrevocable and give the contributor
        nothing.</p>
    </>
  ),

  sweeps: () => (
    <>
      <p>A sweep moves the vault&apos;s available ETH into the live bid. Anyone can run it, and the vault rewards it (its gas
        plus a flat fee, at most 0.01 ETH). Players&apos; draws and the keeper sweep too, so it rarely needs doing by hand.</p>
      <SweepLive />
    </>
  ),

  books: () => (
    <>
      <p>Every figure is read from the contracts. Revenue is FWA&apos;s owner proceeds; a Shape won costs its carried cost
        once; an {ape} was paid for by the vault and is not charged again; losses carry forward; trading fees are capital,
        never profit.</p>
      <BooksLive />
    </>
  ),

  burns: () => <BurnsLive />,

  contracts: () => (
    <>
      <p>Every contract of this deployment. Source: verified on the explorer.</p>
      <ContractsLive />
    </>
  ),

  governance: () => (
    <>
      <h2>One owner</h2>
      <p>One owner administers every contract, directly and at once. Ownership moves in two steps and can be renounced,
        which ends all administration for good.</p>
      <h2>What the owner can change</h2>
      <p>Within fixed limits: the trading fee (up to 10%), prize markup, the board&apos;s pattern and size, reserve and
        admission settings, how {apes} open and fall and the exposure target, the live bid&apos;s settings, keeper pay,
        buyback pace and the milestone share, and pausing new draws. Every change is in the{" "}
        <Link href="/docs/changes/">change log</Link>.</p>
      <h2>What nobody can do</h2>
      <p>Withdraw prizes, game cash or vault funds to an address; mint coins; take bought coins; change the FWA pool owner;
        or raise a listed {ape}&apos;s price. Game surplus has two destinations only: the vault and buybacks.</p>
      <h2>Migration</h2>
      <p>Moving the game to a future pool system runs only 72 hours after the owner proposes it, and only with the proposed
        code. New draws then stop for good, draws in flight settle, and the {apes} and capital move to the successor.</p>
      <MigrationLive />
      <h2>Sunset</h2>
      <p>The owner can end the game at once into the built-in sunset: every {ape} is auctioned, and every wei (the auction,
        the vault&apos;s capital, later fees) goes to buying and burning {coin}. Nothing can go to the owner or anyone
        else.</p>
    </>
  ),

  changes: () => (
    <>
      <p>Every change the owner made, newest first, decoded from the contracts&apos; own events. Changes take effect at
        once.</p>
      <ChangesLive />
    </>
  ),

  risks: () => (
    <>
      <h2>Audit status</h2>
      <p>No independent audit has been done.</p>
      <h2>Outside dependencies</h2>
      <p>The game relies on FWA, Chainlink, Uniswap, the Shapes contract and the NFT collection. Any of them can fail.</p>
      <h2>The coin</h2>
      <p>Holding {coin} gives no claim on any ETH, NFT or revenue, and you do not need it to play. Buybacks may be zero; its
        price can fall to zero.</p>
      <h2>Draws</h2>
      <p>Draws are random and most return less than they cost. Odds change as prizes change.</p>
    </>
  ),


  keeper: () => (
    <>
      <p>The keeper runs the jobs the protocol needs: booking settled draws and replacing prizes, listing and repricing
        {" "}{apes}, growing the board, buybacks, milestone releases and bid sweeps. Anyone can run one; the game pays a
        keeper&apos;s useful calls (gas up to a cap, plus a flat fee, within the allowance draws earn).</p>
      <h2>Run it</h2>
      <pre><code>{`cd keeper && npm install && npm run check
RPC_URL=... KEEPER_PRIVATE_KEY=... DEPLOYMENT=../deployments/mainnet.json MODE=primary npm start`}</code></pre>
      <h2>Modes</h2>
      <p><code>MODE=primary</code> acts whenever there is work and gas is under the cap; <code>MODE=backup</code> acts only
        after work has waited six hours or gas is very low. Run one primary and a backup on separate infrastructure.</p>
    </>
  ),

  local: () => (
    <>
      <p>A local chain for development: a mainnet fork on anvil&apos;s default port with anvil&apos;s chain id, the full
        deployment through activation, and a randomness service so draws settle as they would on mainnet.</p>
      <h2>Start it</h2>
      <pre><code>{`script/local.sh
NEXT_PUBLIC_DEPLOYMENT=anvil npm --prefix site run dev`}</code></pre>
      <h2>Your wallet</h2>
      <p>Add the network: RPC <code>http://127.0.0.1:8545</code>, chain id <code>31337</code>. The site signs only on that
        chain.</p>
    </>
  ),
};
