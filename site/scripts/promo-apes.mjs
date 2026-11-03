// Bakes the promo dome's balls into the site, so the promo page needs no IPFS gateway or chain read:
// - Apes: every BAYC the ApeStrategy contract holds (effectively burned), each image downloaded once and shrunk to
//   320px (public/promo/<id>.jpg);
// - Shapes: every live Shape, its onchain SVG saved as is (public/promo/shape-<id>.svg).
// Re-run to refresh: node scripts/promo-apes.mjs. Writes app/lib/promo-apes.json. Needs macOS `sips` for the resize.
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, http, parseAbi } from "viem";
import { mainnet } from "viem/chains";

const RPC = "https://mainnet.gateway.tenderly.co";
const BAYC = "0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D";
const HOLDER = "0x9ebf91b8d6ff68aa05545301a3d0984eaee54a03"; // ApeStrategy
const SHAPES = "0x6fE9193276bF7aBCbEE44AB7aFd717d637D6FAf0";
const SHAPES_FROM = 20_000_000n; // before the Shapes deployment
const GATEWAY = process.env.IPFS_GATEWAY || "https://gateway.pinata.cloud/ipfs/"; // ipfs.io and dweb.link answer 429
const abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function tokenOfOwnerByIndex(address, uint256) view returns (uint256)",
  "function tokenURI(uint256) view returns (string)",
  "event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)",
]);
const gw = (u) => (u.startsWith("ipfs://") ? GATEWAY + u.slice(7) : u);
const site = fileURLToPath(new URL("..", import.meta.url));
const out = join(site, "public/promo");
mkdirSync(out, { recursive: true });
const tmp = mkdtempSync(join(tmpdir(), "promo-apes-"));

const client = createPublicClient({ chain: mainnet, transport: http(RPC) });
const n = await client.readContract({ address: BAYC, abi, functionName: "balanceOf", args: [HOLDER] });
const ids = [];
for (let i = 0n; i < n; i++) ids.push(await client.readContract({ address: BAYC, abi, functionName: "tokenOfOwnerByIndex", args: [HOLDER, i] }));
for (const id of ids) {
  const uri = await client.readContract({ address: BAYC, abi, functionName: "tokenURI", args: [id] });
  const meta = await (await fetch(gw(uri))).json();
  const img = await fetch(gw(meta.image));
  if (!img.ok) throw new Error(`Ape #${id}: image ${img.status}`);
  const raw = join(tmp, `${id}.png`);
  writeFileSync(raw, Buffer.from(await img.arrayBuffer()));
  execFileSync("sips", ["-Z", "320", "-s", "format", "jpeg", "-s", "formatOptions", "82", raw, "--out", join(out, `${id}.jpg`)], { stdio: "ignore" });
  console.log(`Ape #${id}`);
}
rmSync(tmp, { recursive: true });
ids.sort((a, b) => (a < b ? -1 : 1));

// Shapes is not enumerable: every id ever minted, less the burned (a burned id's tokenURI reverts)
const mints = await client.getContractEvents({ address: SHAPES, abi, eventName: "Transfer", args: { from: "0x0000000000000000000000000000000000000000" }, fromBlock: SHAPES_FROM });
const shapes = [];
for (const id of [...new Set(mints.map((l) => l.args.tokenId))].sort((a, b) => (a < b ? -1 : 1))) {
  const uri = await client.readContract({ address: SHAPES, abi, functionName: "tokenURI", args: [id] }).catch(() => null);
  if (!uri) continue;
  const meta = JSON.parse(Buffer.from(uri.split(",")[1], "base64").toString());
  writeFileSync(join(out, `shape-${id}.svg`), Buffer.from(meta.image.split(",")[1], "base64"));
  shapes.push(Number(id));
}
writeFileSync(join(site, "app/lib/promo-apes.json"), JSON.stringify({ apes: ids.map(Number), shapes }) + "\n");
console.log(`${ids.length} Apes, ${shapes.length} Shapes`);
