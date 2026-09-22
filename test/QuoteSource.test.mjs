import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

function generate(updatedAt) {
  const dir = mkdtempSync(join(tmpdir(), "hydropump-quotes-test-"));
  const address = "0x4200000000000000000000000000000000000006";
  try {
    mkdirSync(join(dir, "script/quotes"), { recursive: true });
    writeFileSync(join(dir, "list.json"), JSON.stringify([{ address, symbol: "WETH", decimals: 18, isHydropumpPair: true }]));
    const result = spawnSync(process.execPath, ["--import", resolve("test/fixtures/mock-assets.mjs"), resolve("script/quotes/build-quote-tokens.mjs")], {
      cwd: dir, encoding: "utf8", env: { ...process.env, QUOTE_LIST: join(dir, "list.json"),
        AUDIT_ASSETS: JSON.stringify([{ address, price: 3000, decimals: 18, updatedAt }]) },
    });
    const data = result.status === 0 ? JSON.parse(readFileSync(join(dir, "script/quotes/quote-tokens.json"), "utf8")) : null;
    return { ...result, data };
  } finally { rmSync(dir, { recursive: true, force: true }); }
}

test("stale source cannot be published with a fresh generation time", () => {
  assert.notEqual(generate(new Date(Date.now() - 3 * 86400_000).toISOString()).status, 0);
});
test("missing source timestamp is rejected", () => {
  assert.notEqual(generate(undefined).status, 0);
});
test("future source timestamp is rejected", () => {
  assert.notEqual(generate(new Date(Date.now() + 86400_000).toISOString()).status, 0);
});
test("fresh source preserves observation time separately from generation", () => {
  const observed = Math.floor(Date.now() / 1000) - 60;
  const { status, data } = generate(new Date(observed * 1000).toISOString());
  assert.equal(status, 0);
  assert.equal(data.priceObservedAt, observed);
});
