# ArcStocks

**Invest in US stocks with USDC on Arc.** Buy and sell synthetic, USDC-settled price exposure to
AAPL, TSLA, NVDA, MSFT, AMZN and GOOGL. Trades settle on Arc in one block, gas is paid in USDC, and
no bank account or brokerage is needed. Built for people in markets like Nigeria where buying US
stocks is slow, expensive or blocked.

> **Status: beta on Arc Mainnet.** Tokens are synthetic price exposure, **not shares or securities**.
> Trade size and open interest are capped while in beta.

| | |
|---|---|
| Live app | https://arcstocks.vercel.app |
| StockMarket | `TODO` |
| PriceOracle | `TODO` |
| Network | Arc Mainnet (chain 5042) |

## How it works

```
 Yahoo Finance quotes ──► keeper ──push()──► PriceOracle ◄──getPrice()── StockMarket ◄── users (USDC)
                                                                      │
                                                         mint / burn aAAPL, aTSLA, …
```

- **`StockMarket`**: `buy(symbol, usdcIn, minOut)` takes USDC and mints `aTICKER` at the oracle
  price minus a 0.30% fee. `sell(symbol, amount, minUsdcOut)` burns the tokens and pays USDC from the reserve.
  Protections include slippage limits, a staleness check, a per-trade cap on buys (sells are never
  capped, so holders can't get stuck), a per-stock open-interest cap, a pause switch and reentrancy guards.
- **Solvency is on-chain.** `liabilities()` values every outstanding token at the current price and
  `collateralRatioBps()` exposes the reserve ratio. `withdrawSurplus()` lets the owner withdraw only
  what sits above liabilities, so the owner can never pull user backing.
- **`PriceOracle`**: keeper-pushed prices (USD, 8 decimals, Chainlink-style). The `IStockOracle`
  interface lets a Chainlink or Pyth equity adapter replace it once those feeds go live on Arc mainnet.
- **`StockToken`**: a plain ERC-20 per stock. Only the market can mint or burn it.

### Why Arc
USDC is both the gas token and the settlement asset. Users hold one asset, pay predictable fees of
fractions of a cent, and get deterministic sub-second finality, which matters for trading at an
oracle price.

## Development

```bash
forge test            # 11 tests incl. 1,000-run fuzz: no value leak at constant price
```

## Deploy (Arc Mainnet)

```bash
cast wallet import arc-deployer --interactive          # once; key stays in Foundry's encrypted keystore
forge script script/Deploy.s.sol --rpc-url arc --account arc-deployer --broadcast
# fund the reserve (USDC ERC-20 interface, 6 decimals), e.g. 20 USDC:
cast send 0x3600000000000000000000000000000000000000 "transfer(address,uint256)" <MARKET> 20000000 \
  --rpc-url arc --account arc-deployer
# push prices (run with --loop 300 to keep them fresh):
ORACLE=<ORACLE> CAST_ACCOUNT=arc-deployer node keeper/keeper.mjs
```

Then set `market` (and `repo`) in `web/config.js` and deploy `web/` as a static site
(e.g. `vercel web --prod`).

## Roadmap
1. Swap the push oracle for Chainlink or Pyth equity feeds as they launch on Arc.
2. Partner with a licensed tokenized-equity issuer for fully backed stock tokens, keeping ArcStocks as
   the USDC on-ramp and UX layer.
3. Recurring buys (dollar-cost averaging) paid by USDC streams, and a mobile-first PWA.
4. LP vault so the reserve is community-funded and earns the trading fees.

## Limitations (honest)
- The market is the counterparty, so if prices rally hard the reserve can fall short. Open-interest
  caps and the on-chain collateral ratio bound this risk during beta.
- When the US market is closed, trades execute at the last close (`maxStaleness` = 26h).
- The keeper is a single trusted updater for now.

License: MIT
