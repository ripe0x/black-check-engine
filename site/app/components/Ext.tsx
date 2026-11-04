import type { ReactNode } from "react";

/** An outside link (an explorer page) when there is a URL; plain text when there is none, as on a local chain. */
export function Ext({ href, className, children }: { href?: string; className?: string; children: ReactNode }) {
  return href ? <a className={className} href={href} target="_blank" rel="noreferrer">{children}</a> : <span className={className}>{children}</span>;
}
