"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useAccount, useConnect, useDisconnect } from "wagmi";
import { config } from "../lib/config";
import { short } from "../lib/format";

const links = [
  ["/", "Play"],
  ["/checks/", "Checks"],
  ["/compose/", "Compose"],
  ["/collect/", "Collect"],
  ["/trust/", "Trust"],
] as const;

export function Nav() {
  const path = usePathname();
  const { address } = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  return (
    <header className="nav">
      <Link href="/" className="brand">{config.projectName}</Link>
      <nav aria-label="Primary">
        {links.map(([href, label]) => (
          <Link key={href} href={href} aria-current={path === href ? "page" : undefined} className={path === href ? "on" : ""}>
            {label}
          </Link>
        ))}
      </nav>
      {address ? (
        <button className="btn-outline" onClick={() => disconnect()}>{short(address)}</button>
      ) : (
        <button className="btn-filled" onClick={() => connectors[0] && connect({ connector: connectors[0] })}>
          Connect wallet
        </button>
      )}
    </header>
  );
}
