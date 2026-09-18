#!/usr/bin/env node
// Derives a start tick per quote token and writes script/quotes/quote-tokens.json.
//
// Membership and classification come from hydrex-lists: every token flagged `isHydropumpPair` is a
// quote candidate, and its `hydropumpClassification` is carried through verbatim. Prices and decimals
// come from the live Hydrex asset list. Curating the set in hydrex-lists keeps one source of truth —
// this script no longer guesses from symbol shape.
//
// Start tick encodes the price of one launch token in raw quote units:
//   targetPrice = TARGET_START_MCAP_USD / LAUNCH_SUPPLY        (USD per launch token)
//   rawRatio    = targetPrice / quoteUsd * 10**quoteDecimals / 1e18
//   startTick   = floor(ln(rawRatio) / ln(1.0001))
// Absolute ticks are quote-specific: decimals and USD price both shift them, which is why the curve
// itself is stored as offsets and only this number is per-quote.
//
// One number per quote covers both orientations. This is the reading for a launch token that sorts below
// its quote and so lands on the token0 side; a launch that sorts above it gets the reciprocal price, which
// is the same tick negated, and the launcher does that itself. Nothing here has to know which side a given
// launch will land on — the CREATE2 address decides, at launch time.

import { readFileSync, writeFileSync, existsSync } from "node:fs";

const ASSETS_URL = "https://api.hydrex.fi/assets";
const OUT_PATH = "script/quotes/quote-tokens.json";
const LAUNCH_SUPPLY = 10_000_000_000;
const TARGET_START_MCAP_USD = 5_000;
const MIN_TICK = -887272;
const MAX_TICK = 887272;
const TAIL_WIDTH = 887_200;

// hydrex-lists checkout, or a raw URL to its generated token list.
const LIST_SOURCE = process.env.QUOTE_LIST ?? "../hydrex-lists/tokens/8453.json";

const loadJson = async (source) =>
  source.startsWith("http")
    ? await fetch(source).then((r) => {
        if (!r.ok) throw new Error(`${source} -> ${r.status}`);
        return r.json();
      })
    : JSON.parse(readFileSync(source, "utf8"));

const startTick = (priceUsd, decimals) => {
  const target = TARGET_START_MCAP_USD / LAUNCH_SUPPLY;
  const rawRatio = ((target / priceUsd) * 10 ** decimals) / 1e18;
  return Math.floor(Math.log(rawRatio) / Math.log(1.0001));
};

const list = await loadJson(LIST_SOURCE);
const listed = (Array.isArray(list) ? list : list.tokens).filter((t) => t.isHydropumpPair);
if (!listed.length) throw new Error(`no isHydropumpPair tokens in ${LIST_SOURCE}`);

const assets = await loadJson(ASSETS_URL);
const priced = new Map(assets.map((a) => [a.address.toLowerCase(), a]));

const skipped = [];
const seen = new Set();
const entries = [];

for (const t of listed) {
  const address = t.address.toLowerCase();
  const reject = (why) => skipped.push({ symbol: t.symbol, why });

  if (seen.has(address)) {
    reject("duplicate address");
    continue;
  }

  const asset = priced.get(address);
  if (!asset) {
    reject("not in the Hydrex asset list");
    continue;
  }
  if (!asset.price || asset.price <= 0) {
    reject("no price");
    continue;
  }
  if (asset.decimals !== t.decimals) {
    reject(`decimals disagree: list ${t.decimals}, api ${asset.decimals}`);
    continue;
  }

  // The same bound covers both orientations. A token0-side launch needs `tick + TAIL_WIDTH <= MAX_TICK`
  // and a token1-side one needs `-tick - TAIL_WIDTH >= MIN_TICK`; MIN_TICK is -MAX_TICK, so those are the
  // same inequality. The lower bound is symmetric for the same reason.
  const tick = startTick(asset.price, t.decimals);
  if (tick <= MIN_TICK || tick + TAIL_WIDTH >= MAX_TICK) {
    reject(`tick ${tick} out of range`);
    continue;
  }

  seen.add(address);
  entries.push({
    symbol: t.symbol,
    address: t.address,
    decimals: t.decimals,
    category: t.hydropumpClassification ?? "unclassified",
    priceUsd: asset.price,
    startTick: tick,
    priceUsdE8: Math.round(asset.price * 1e8),
  });
}

entries.sort((x, y) => x.category.localeCompare(y.category) || x.symbol.localeCompare(y.symbol));

// Anything registered by an earlier generation but no longer listed has to be explicitly disabled:
// configureQuoteTokens upserts per address, so dropping a token from the arrays leaves it live
// on-chain. Prior retirements stay in the list so regenerating never forgets a disable.
const previous = existsSync(OUT_PATH) ? JSON.parse(readFileSync(OUT_PATH, "utf8")) : null;
const retired = [];
if (previous) {
  const carried = [
    ...(previous.tokens ?? []).map((e) => ({ symbol: e.symbol, address: e.address, startTick: e.startTick })),
    ...(previous.retired?.tokens ?? []),
  ];
  for (const old of carried) {
    const address = old.address.toLowerCase();
    if (seen.has(address) || retired.some((r) => r.address.toLowerCase() === address)) continue;
    retired.push(old);
  }
}

const out = {
  generatedAt: new Date().toISOString(),
  source: ASSETS_URL,
  listSource: LIST_SOURCE,
  launchSupply: LAUNCH_SUPPLY,
  targetStartMcapUsd: TARGET_START_MCAP_USD,
  // Flat arrays so the Solidity script can hand them straight to configureQuoteTokens.
  addresses: entries.map((e) => e.address),
  enabled: entries.map(() => true),
  startTicks: entries.map((e) => e.startTick),
  // Parallel arrays the fork tests read to check the curve against real prices.
  symbols: entries.map((e) => e.symbol),
  decimals: entries.map((e) => e.decimals),
  priceUsdE8: entries.map((e) => e.priceUsdE8),
  tokens: entries,
  // Registered once, delisted since. Registered again with enabled = false.
  retired: {
    addresses: retired.map((e) => e.address),
    enabled: retired.map(() => false),
    startTicks: retired.map((e) => e.startTick),
    symbols: retired.map((e) => e.symbol),
    tokens: retired,
  },
};

writeFileSync(OUT_PATH, JSON.stringify(out, null, 2) + "\n");

const byCategory = entries.reduce((m, e) => ((m[e.category] = (m[e.category] ?? 0) + 1), m), {});
console.log(`${entries.length} quote tokens ->`, byCategory);
if (retired.length) {
  console.log(`\nretired ${retired.length} (registered with enabled = false):`);
  for (const r of retired) console.log(`  ${r.symbol}`);
}
if (skipped.length) {
  console.log(`\nskipped ${skipped.length}:`);
  for (const s of skipped) console.log(`  ${s.symbol.padEnd(10)} ${s.why}`);
}
