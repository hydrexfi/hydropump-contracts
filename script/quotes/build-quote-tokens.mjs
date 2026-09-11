#!/usr/bin/env node
// Pulls the Hydrex asset list and derives a start tick per quote token, so a fresh deployment can
// register a broad set of quotes immediately. Writes script/quotes/quote-tokens.json.
//
// Start tick encodes the price of one launch token in raw quote units:
//   targetPrice = TARGET_START_MCAP_USD / LAUNCH_SUPPLY        (USD per launch token)
//   rawRatio    = targetPrice / quoteUsd * 10**quoteDecimals / 1e18
//   startTick   = floor(ln(rawRatio) / ln(1.0001))
// Absolute ticks are quote-specific: decimals and USD price both shift them, which is why the curve
// itself is stored as offsets and only this number is per-quote.

import { writeFileSync } from "node:fs";

const ASSETS_URL = "https://api.hydrex.fi/assets";
const LAUNCH_SUPPLY = 10_000_000_000;
const TARGET_START_MCAP_USD = 5_000;
const MIN_TICK = -887272;
const MAX_TICK = 887272;
const TAIL_WIDTH = 887_200;

// Expected keccak attempts to mine a launch token address below the quote. Cheap in a Web Worker,
// but a quote token with a very low address is effectively unlaunchable.
const MAX_MINING_ATTEMPTS = 1_000_000;

const MAJORS = ["WETH", "cbBTC", "USDC", "USDT", "cbETH", "wstETH", "EURC"];

const classify = (a) => {
  if (MAJORS.includes(a.symbol)) return "major";
  if (!a.isEquity) return null;
  if (a.symbol.startsWith("wt")) return "st0x";
  if (a.symbol.endsWith("c")) return "coinbase";
  return null;
};

const startTick = (priceUsd, decimals) => {
  const target = TARGET_START_MCAP_USD / LAUNCH_SUPPLY;
  const rawRatio = ((target / priceUsd) * 10 ** decimals) / 1e18;
  return Math.floor(Math.log(rawRatio) / Math.log(1.0001));
};

const miningAttempts = (address) => 2 ** 160 / Number(BigInt(address));

const assets = await fetch(ASSETS_URL).then((r) => {
  if (!r.ok) throw new Error(`${ASSETS_URL} -> ${r.status}`);
  return r.json();
});

const skipped = [];
const seen = new Set();
const entries = [];

for (const a of assets) {
  const category = classify(a);
  if (!category) continue;

  const reject = (why) => skipped.push({ symbol: a.symbol, why });

  if (!a.price || a.price <= 0) {
    reject("no price");
    continue;
  }
  if (seen.has(a.address.toLowerCase())) {
    reject("duplicate address");
    continue;
  }

  const tick = startTick(a.price, a.decimals);
  if (tick <= MIN_TICK || tick + TAIL_WIDTH >= MAX_TICK) {
    reject(`tick ${tick} out of range`);
    continue;
  }

  const attempts = miningAttempts(a.address);
  if (attempts > MAX_MINING_ATTEMPTS) {
    reject(`address too low, ~${attempts.toExponential(1)} mining attempts`);
    continue;
  }

  seen.add(a.address.toLowerCase());
  entries.push({
    symbol: a.symbol,
    address: a.address,
    decimals: a.decimals,
    category,
    priceUsd: a.price,
    startTick: tick,
    priceUsdE8: Math.round(a.price * 1e8),
    miningAttempts: Math.ceil(attempts),
  });
}

entries.sort((x, y) => x.category.localeCompare(y.category) || x.symbol.localeCompare(y.symbol));

const out = {
  generatedAt: new Date().toISOString(),
  source: ASSETS_URL,
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
};

writeFileSync("script/quotes/quote-tokens.json", JSON.stringify(out, null, 2) + "\n");

const byCategory = entries.reduce((m, e) => ((m[e.category] = (m[e.category] ?? 0) + 1), m), {});
console.log(`${entries.length} quote tokens ->`, byCategory);
console.log(
  `worst mining cost: ${Math.max(...entries.map((e) => e.miningAttempts)).toLocaleString()} attempts`,
);
if (skipped.length) {
  console.log(`\nskipped ${skipped.length}:`);
  for (const s of skipped) console.log(`  ${s.symbol.padEnd(10)} ${s.why}`);
}
