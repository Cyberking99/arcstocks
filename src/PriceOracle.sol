// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable2Step, Ownable } from "openzeppelin-contracts/access/Ownable2Step.sol";

/// @notice Price source consumed by StockMarket. Prices are USD per share, 8 decimals (Chainlink-style),
/// so a Chainlink/Pyth adapter can be swapped in later without touching the market.
interface IStockOracle {
    /// @return price USD per share, 8 decimals
    /// @return updatedAt timestamp the keeper last refreshed this symbol on-chain
    function getPrice(bytes32 symbol) external view returns (uint256 price, uint256 updatedAt);
}

/// @title PriceOracle
/// @notice Keeper-pushed stock price oracle. No equity feed is live on Arc mainnet yet, so an off-chain
/// keeper reads market quotes and pushes them here. `sourceTime` records the upstream quote time
/// (e.g. last US market print) for display; `updatedAt` tracks keeper liveness.
contract PriceOracle is IStockOracle, Ownable2Step {
    struct Quote {
        uint128 price; // USD, 8 decimals
        uint64 updatedAt; // block time of the push
        uint64 sourceTime; // upstream quote time
    }

    mapping(bytes32 => Quote) public quotes;
    mapping(address => bool) public isUpdater;

    event PriceUpdated(bytes32 indexed symbol, uint256 price, uint256 sourceTime);
    event UpdaterSet(address indexed updater, bool allowed);

    error NotUpdater();
    error LengthMismatch();
    error ZeroPrice();
    error UnknownSymbol(bytes32 symbol);

    constructor(address owner_) Ownable(owner_) {
        isUpdater[owner_] = true;
        emit UpdaterSet(owner_, true);
    }

    function setUpdater(address updater, bool allowed) external onlyOwner {
        isUpdater[updater] = allowed;
        emit UpdaterSet(updater, allowed);
    }

    function push(bytes32[] calldata symbols, uint256[] calldata prices, uint256[] calldata sourceTimes) external {
        if (!isUpdater[msg.sender]) revert NotUpdater();
        if (symbols.length != prices.length || symbols.length != sourceTimes.length) revert LengthMismatch();
        for (uint256 i; i < symbols.length; ++i) {
            if (prices[i] == 0) revert ZeroPrice();
            quotes[symbols[i]] = Quote(uint128(prices[i]), uint64(block.timestamp), uint64(sourceTimes[i]));
            emit PriceUpdated(symbols[i], prices[i], sourceTimes[i]);
        }
    }

    /// @inheritdoc IStockOracle
    function getPrice(bytes32 symbol) external view returns (uint256, uint256) {
        Quote memory q = quotes[symbol];
        if (q.price == 0) revert UnknownSymbol(symbol);
        return (q.price, q.updatedAt);
    }
}
