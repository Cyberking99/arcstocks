// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { StockMarket } from "../src/StockMarket.sol";
import { PriceOracle, IStockOracle } from "../src/PriceOracle.sol";

/// forge script script/Deploy.s.sol --rpc-url arc --account <keystore> --broadcast
contract Deploy is Script {
    /// Arc native USDC, ERC-20 interface (6 decimals). Same address on mainnet and testnet.
    address constant ARC_USDC = 0x3600000000000000000000000000000000000000;

    function run() external {
        address usdc = vm.envOr("USDC", ARC_USDC);
        vm.startBroadcast();
        address deployer = msg.sender;

        PriceOracle oracle = new PriceOracle(deployer);
        StockMarket market = new StockMarket(deployer, IERC20(usdc), IStockOracle(address(oracle)));

        market.list("AAPL", "Arc Synthetic Apple", "aAAPL");
        market.list("TSLA", "Arc Synthetic Tesla", "aTSLA");
        market.list("NVDA", "Arc Synthetic NVIDIA", "aNVDA");
        market.list("MSFT", "Arc Synthetic Microsoft", "aMSFT");
        market.list("AMZN", "Arc Synthetic Amazon", "aAMZN");
        market.list("GOOGL", "Arc Synthetic Alphabet", "aGOOGL");

        // Small caps while live on mainnet: $25 per trade, $200 open interest per stock.
        // Staleness 26h so the last close stays tradeable overnight while the keeper keeps pushing.
        market.setParams(30, 26 hours, 25e6, 200e6);
        vm.stopBroadcast();

        console.log("PriceOracle:", address(oracle));
        console.log("StockMarket:", address(market));
    }
}
