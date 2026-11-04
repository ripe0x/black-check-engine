// Run: node --experimental-strip-types --test test/format.test.mjs. ETH shows up to three decimals; amounts a user
// pays round up, minimums they receive round down.
import test from "node:test";
import assert from "node:assert/strict";
import { amtDown, amtUp, eth, ethDown, ethUp, fmt, numDown } from "../app/lib/format.ts";

test("ETH amounts show up to three decimals, two significant digits under 0.001", () => {
  assert.equal(eth(19_190_503_107_406_706n), "0.019 ETH");
  assert.equal(eth(1_500_000_000_000_000_000n), "1.5 ETH");
  assert.equal(eth(430_000_000_000_000n), "0.00043 ETH");
  assert.equal(fmt(0.014), "0.01", "USD and other numbers keep two decimals");
});

test("a cost between display steps shows the step above", () => {
  assert.equal(ethUp(14_100_000_000_000_000n), "0.015 ETH");
  assert.equal(amtUp(-14_100_000_000_000_000n), "0.015");
  assert.equal(ethUp(123_400_000_000_000n), "0.00013 ETH");
  assert.equal(ethUp(20_000_000_000_000_000n), "0.02 ETH", "an exact step stays");
  assert.equal(eth(14_100_000_000_000_000n), "0.014 ETH", "plain amounts keep nearest rounding");
});

test("a minimum received shows the step below", () => {
  assert.equal(ethDown(16_900_000_000_000_000n), "0.016 ETH");
  assert.equal(ethDown(129_999_999_999_999n), "0.00012 ETH");
  assert.equal(numDown(1_600_000_000_000_000_000n), "1");
  assert.equal(numDown(2_000_000_000_000_000_000n), "2", "an exact step stays");
});

test("the direction holds without Intl roundingMode (exact integer arithmetic)", () => {
  const real = Intl.NumberFormat;
  // an engine that ignores roundingMode: nearest rounding only
  Intl.NumberFormat = function (locale, opts = {}) { const { roundingMode, ...rest } = opts; return new real(locale, rest); };
  try {
    assert.equal(ethUp(1_001_000_000_000_000_000n), "1.001 ETH");
    assert.equal(ethUp(1_000_100_000_000_000_000n), "1.001 ETH", "a charge just above 1 shows above 1");
    assert.equal(ethDown(1_009_900_000_000_000_000n), "1.009 ETH", "a minimum just below 1.01 never shows 1.01");
    assert.equal(numDown(1_500_000_000_000_000_000n), "1", "1.5 tokens at no decimals shows 1, not 2");
    assert.equal(amtDown(1_009_999_999_999_999_999n), "1.009");
    assert.equal(ethUp(1n), "0.000000000000000001 ETH", "1 wei, never 0");
  } finally {
    Intl.NumberFormat = real;
  }
});

test("grouping and large values", () => {
  assert.equal(ethDown(1_234_567_890_000_000_000_000n), "1,234.567 ETH");
  assert.equal(ethUp(1_234_567_100_000_000_000_000n), "1,234.568 ETH");
  assert.equal(ethDown(0n), "0 ETH");
});
