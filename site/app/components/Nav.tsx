"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { formatEther } from "viem";
import { useAccount, useBalance } from "wagmi";
import { fmtEth, short } from "../lib/format";
import { useHeldValue } from "../lib/held";
import { collectionMeta, deployment } from "../lib/deployment";
import { addressUrl } from "../lib/chain";
import { Ext } from "./Ext";

const e3 = (wei: bigint) => fmtEth(Number(formatEther(wei)));
const trim = e3;

/** The header of every page but the home page (which lays out its own): the game's name (home), the coin's page as
 *  the ticker pill, and the wallet button. */
export function Nav() {
  const path = usePathname();
  if (path === "/" && deployment.deployed) return null;
  return (
    <header className="nav">
      <Link href="/" className="brand">{collectionMeta.game}</Link>
      <Link href="/coin/" className="nav-ticker">{collectionMeta.ticker}</Link>
      <Wallet />
    </header>
  );
}

/** The wallet button with what the player can draw with: the wallet's ETH plus what its Shapes and Packs redeem for
 *  ("Pay with my winnings" spends both), the Shapes' part named under it. The ETH balance is the query the draw reads,
 *  so a redeem or draw refreshes both. */
export function Wallet() {
  const { address } = useAccount();
  const { data: bal } = useBalance({ address, query: { enabled: !!address, refetchInterval: 12_000 } });
  const held = useHeldValue(address, bal?.value);
  const split = bal && held ? `${e3(bal.value)} ETH in your wallet + ${trim(held)} ETH in Shapes you can redeem` : undefined;
  return (
      <ConnectButton.Custom>
        {({ account, chain, mounted, openConnectModal, openChainModal, openAccountModal }) => {
          // RainbowKit's modals behind the site's own pill buttons; nothing shows until it has read the wallet
          if (!mounted) return <span className="nav-wallet" aria-hidden />;
          if (!account) return <button type="button" className="nav-wallet filled" onClick={openConnectModal}>CONNECT</button>;
          if (chain?.unsupported) return <button type="button" className="nav-wallet warn" onClick={openChainModal}>SWITCH NETWORK</button>;
          return (
            <button type="button" className="nav-wallet split" onClick={openAccountModal} title={split}
              aria-label={split ? `${split}. Account ${account.address}` : undefined}>
              {bal ? (
                <span className="nav-bal">
                  {e3(bal.value + (held ?? 0n))} ETH
                  {held ? <small>incl. {trim(held)} in Shapes</small> : null}
                </span>
              ) : null}
              <span className="nav-addr">{short(account.address)}</span>
            </button>
          );
        }}
      </ConnectButton.Custom>
  );
}

/** The footer's link to the coin's contract on the chain's explorer (plain text where there is none, as on a local chain). */
export function CoinContract() {
  if (!deployment.deployed) return null;
  return <> · <Ext href={addressUrl(deployment.token)}>{collectionMeta.ticker} contract</Ext></>;
}
