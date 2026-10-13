#!/usr/bin/env node
// Pushes US stock prices to PriceOracle on Arc. Neither Pyth nor Chainlink equity feeds are live on
// Arc mainnet yet (and Pyth Hermes now requires an API key), so the keeper reads Yahoo Finance's
// public quote endpoint and relays prices through our own push oracle.
//
//   ORACLE=0x... RPC_URL=https://rpc.mainnet.arc.io CAST_ACCOUNT=arc-deployer node keeper/keeper.mjs [--loop 60]
import { execFileSync } from "node:child_process";

const TICKERS = ["AAPL", "TSLA", "NVDA", "MSFT", "AMZN", "GOOGL"];

const { ORACLE, RPC_URL = "https://rpc.mainnet.arc.io", CAST_ACCOUNT, PRIVATE_KEY } = process.env;
if (!ORACLE) throw new Error("set ORACLE");
if (!CAST_ACCOUNT && !PRIVATE_KEY) throw new Error("set CAST_ACCOUNT (foundry keystore) or PRIVATE_KEY");

const toBytes32 = (s) => "0x" + Buffer.from(s).toString("hex").padEnd(64, "0");

// Price as an 8-decimal integer, without float rounding surprises.
const to8 = (price) => BigInt(Math.round(price * 1e8));

async function quote(ticker) {
  const res = await fetch(`https://query1.finance.yahoo.com/v8/finance/chart/${ticker}?range=1d&interval=1d`, {
    headers: { "User-Agent": "Mozilla/5.0 arcstocks-keeper" },
  });
  if (!res.ok) throw new Error(`yahoo ${ticker} ${res.status}`);
  const { regularMarketPrice, regularMarketTime } = (await res.json()).chart.result[0].meta;
  if (!(regularMarketPrice > 0)) throw new Error(`yahoo ${ticker} bad price`);
  return { price: regularMarketPrice, time: regularMarketTime };
}

async function tick() {
  const syms = [], prices = [], times = [];
  for (const t of TICKERS) {
    const q = await quote(t);
    syms.push(toBytes32(t));
    prices.push(to8(q.price).toString());
    times.push(String(q.time));
    console.log(`${t.padEnd(5)} $${q.price.toFixed(2)}  (last print ${new Date(q.time * 1000).toISOString()})`);
  }

const auth = CAST_ACCOUNT ? ["--account", CAST_ACCOUNT] : ["--private-key", PRIVATE_KEY];
  const out = execFileSync("cast", [
    "send", ORACLE, "push(bytes32[],uint256[],uint256[])",
    `[${syms}]`, `[${prices}]`, `[${times}]`,
    "--rpc-url", RPC_URL, ...auth, "--json",
  ], { encoding: "utf8", stdio: ["inherit", "pipe", "inherit"] });
  console.log("tx", JSON.parse(out).transactionHash);
}

const loopIdx = process.argv.indexOf("--loop");
if (loopIdx === -1) await tick();
else {
  const secs = Number(process.argv[loopIdx + 1] ?? 60);
  for (;;) {
    try { await tick(); } catch (e) { console.error(e.message); }
    await new Promise((r) => setTimeout(r, secs * 1000));
  }
}
