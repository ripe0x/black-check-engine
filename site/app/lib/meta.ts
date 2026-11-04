import type { Metadata } from "next";
import { collectionMeta } from "./deployment";

// The share card image: the promo dome, captured at 1200x630 (public/og.png).
const IMAGE = { url: "/og.png", width: 1200, height: 630, alt: "A glass dome full of Check and Shape balls" };

/** One page's title, description and canonical path, repeated into its share card: Next replaces a parent's openGraph
 *  and twitter objects whole (image included), so a page that sets only `title` would share under the site's title. */
export function pageMeta(title: string | undefined, description: string | undefined, path: string): Metadata {
  const t = title ? `${title} · ${collectionMeta.game}` : collectionMeta.game;
  return {
    ...(title ? { title } : {}),
    description,
    alternates: { canonical: path },
    openGraph: { type: "website", siteName: collectionMeta.game, title: t, description, url: path, images: [IMAGE] },
    twitter: { card: "summary_large_image", creator: "@ripe0x", title: t, description, images: [IMAGE] },
  };
}
