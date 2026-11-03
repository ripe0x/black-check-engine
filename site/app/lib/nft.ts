"use client";

import { useEffect, useState } from "react";
import { usePublicClient, useReadContract } from "wagmi";
import { encodePacked, keccak256, parseAbi, toHex, zeroAddress, type Address, type Hex } from "viem";
import { deployment } from "./deployment";

const erc721 = parseAbi(["function tokenURI(uint256) view returns (string)"]);
// Public gateways rate-limit hard (ipfs.io answers 429 without CORS headers, so the browser sees a CORS failure).
// Production sets a dedicated gateway; the public one is a fallback.
const GATEWAY = process.env.NEXT_PUBLIC_IPFS_GATEWAY?.trim() || "https://ipfs.io/ipfs/";
const gateway = (u: string) => (u.startsWith("ipfs://") ? `${GATEWAY}${u.slice(7)}` : u);

/** One metadata fetch per tokenURI, shared by every ball showing that token. A failure is retried on the next use. */
const images = new Map<string, Promise<string>>();
function imageOf(uri: string) {
  let p = images.get(uri);
  if (!p) {
    p = fetch(gateway(uri)).then((r) => r.json()).then((j) => gateway(j.image ?? ""));
    p.catch(() => images.delete(uri));
    images.set(uri, p);
  }
  return p;
}

/**
 * Image URL of a token, read from its own tokenURI (any ERC-721; the collection by default, or a Shape or Pack).
 * Empty while loading or on failure.
 */
export function useTokenImage(tokenId?: bigint, nft: Address = deployment.collection) {
  const { data: uri } = useReadContract({
    address: nft,
    abi: erc721,
    functionName: "tokenURI",
    args: tokenId === undefined ? undefined : [tokenId],
    query: { enabled: tokenId !== undefined && deployment.deployed },
  });
  const [img, setImg] = useState("");
  useEffect(() => {
    if (!uri) return;
    let live = true;
    imageOf(uri)
      .then((u) => live && setImg(u))
      .catch(() => {});
    return () => {
      live = false;
    };
  }, [uri]);
  return img;
}

/**
 * The art's background colour: the average of its top two rows of pixels (collection art like BAYC has a flat
 * background there). Needs the gateway to serve the image with CORS; without it the canvas is tainted and this fails.
 */
const colours = new Map<string, Promise<string>>();
function colourOf(src: string) {
  let p = colours.get(src);
  if (!p) {
    p = new Promise<string>((ok, no) => {
      const im = new Image();
      im.crossOrigin = "anonymous";
      im.onload = () => {
        try {
          const c = document.createElement("canvas");
          c.width = c.height = 32;
          const x = c.getContext("2d")!;
          x.drawImage(im, 0, 0, 32, 32);
          const d = x.getImageData(0, 0, 32, 2).data, n = d.length / 4, sum = [0, 0, 0];
          for (let k = 0; k < d.length; k += 4) { sum[0] += d[k]; sum[1] += d[k + 1]; sum[2] += d[k + 2]; }
          ok("#" + sum.map((v) => Math.round(v / n).toString(16).padStart(2, "0")).join(""));
        } catch (e) {
          no(e);
        }
      };
      im.onerror = no;
      im.src = src;
    });
    p.catch(() => colours.delete(src));
    colours.set(src, p);
  }
  return p;
}

/** Background colour of a token's art; empty while loading or on failure. */
export function useTokenColour(tokenId?: bigint, nft?: Address) {
  const img = useTokenImage(tokenId, nft);
  const [colour, setColour] = useState("");
  useEffect(() => {
    if (!img) return;
    let live = true;
    colourOf(img)
      .then((c) => live && setColour(c))
      .catch(() => {});
    return () => {
      live = false;
    };
  }, [img]);
  return colour;
}

// Sample art for a prize tier before any prize exists (the board while funding): a freshly minted Shape of that
// value, drawn by Shapes' own renderer from a random seed, or for a Pack the Pack renderer's fan of the Shapes it
// would hold. Both renderers are views, so nothing is minted. The ink gene follows Shapes' InkGenes.geneAtMint.
const LADDER = [10n ** 16n, 5n * 10n ** 16n, 10n ** 17n, 5n * 10n ** 17n, 10n ** 18n, 5n * 10n ** 18n, 10n ** 19n, 5n * 10n ** 19n, 10n ** 20n];
const shapeArtAbi = parseAbi([
  "function renderer() view returns (address)",
  "function renderSVG(bytes32 seed, uint256 amountWei, bool inverted, uint8 inkGene) pure returns (string)",
  "struct ShapeState { bytes32 seed; uint8 denominationIndex; uint32 originCount; uint8 inkGene; bool isBlack; uint8 formation; uint256 faceValueWei; uint256 redeemableValueWei; bytes modules; }",
  "struct PackRenderInput { uint256 packId; uint256 shapeCount; uint256 valueWei; uint256 unitWei; uint32[] counts; uint256[] denominations; uint256 mintedCount; address creator; ShapeState[] topCards; string tokenNamePrefix; string description; }",
  "function image(PackRenderInput input) view returns (string)",
]);
const geneAtMint = (seed: Hex, index: number) => {
  const r = Number(BigInt(keccak256(encodePacked(["string", "bytes32"], ["ink:mint", seed]))) % 100n);
  if (index === 0) return r < 3 ? 0 : r < 10 ? 1 : r < 25 ? 2 : r < 75 ? 3 : r < 90 ? 4 : r < 97 ? 5 : 6;
  return r < 20 ? 2 : r < 80 ? 3 : 4;
};
/** The Shapes a value is made of, largest first: the fewest (greedy on Shapes' ladder). */
const cardsOf = (value: bigint) => {
  const out: number[] = [];
  for (let i = LADDER.length - 1; i >= 0 && value > 0n; ) {
    if (LADDER[i] <= value) { out.push(i); value -= LADDER[i]; } else i--;
  }
  return out;
};
const svgUri = (svg: string) => `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;

export function useSampleArt(value: bigint, shapes?: Address, packs?: Address) {
  const client = usePublicClient();
  const [img, setImg] = useState("");
  useEffect(() => {
    if (!client || !shapes || !packs) return;
    let live = true;
    (async () => {
      const cards = cardsOf(value).map((index) => {
        const seed = toHex(crypto.getRandomValues(new Uint8Array(32)));
        return { seed, index, gene: geneAtMint(seed, index) };
      });
      if (cards.length === 1) {
        const { seed, index, gene } = cards[0];
        const renderer = await client.readContract({ address: shapes, abi: shapeArtAbi, functionName: "renderer" });
        return client.readContract({ address: renderer, abi: shapeArtAbi, functionName: "renderSVG", args: [seed, LADDER[index], false, gene] });
      }
      const renderer = await client.readContract({ address: packs, abi: shapeArtAbi, functionName: "renderer" });
      return client.readContract({ address: renderer, abi: shapeArtAbi, functionName: "image", args: [{
        packId: 0n, shapeCount: BigInt(cards.length), valueWei: value, unitWei: LADDER[0], counts: [], denominations: [], mintedCount: BigInt(cards.length),
        creator: zeroAddress, tokenNamePrefix: "", description: "",
        topCards: cards.map(({ seed, index, gene }) => ({ seed, denominationIndex: index, originCount: 1, inkGene: gene, isBlack: false, formation: 1,
          faceValueWei: LADDER[index], redeemableValueWei: LADDER[index], modules: "0x" as Hex })),
      }] });
    })().then((svg) => live && setImg(svgUri(svg))).catch(() => {});
    return () => { live = false; };
  }, [client, value, shapes, packs]);
  return img;
}
