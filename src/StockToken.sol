// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20 } from "openzeppelin-contracts/token/ERC20/ERC20.sol";

/// @title StockToken
/// @notice Synthetic, USDC-settled price exposure to one stock. NOT a security and not backed by
/// shares: holders can only redeem for USDC at the oracle price through StockMarket.
contract StockToken is ERC20 {
    address public immutable market;
    bytes32 public immutable symbolId;

    error OnlyMarket();

    constructor(string memory name_, string memory symbol_, bytes32 symbolId_) ERC20(name_, symbol_) {
        market = msg.sender;
        symbolId = symbolId_;
    }

    modifier onlyMarket() {
        if (msg.sender != market) revert OnlyMarket();
        _;
    }

    function mint(address to, uint256 amount) external onlyMarket {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyMarket {
        _burn(from, amount);
    }
}
