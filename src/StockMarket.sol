// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable2Step, Ownable } from "openzeppelin-contracts/access/Ownable2Step.sol";
import { Pausable } from "openzeppelin-contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "openzeppelin-contracts/utils/ReentrancyGuard.sol";
import { Math } from "openzeppelin-contracts/utils/math/Math.sol";
import { IStockOracle } from "./PriceOracle.sol";
import { StockToken } from "./StockToken.sol";

/// @title StockMarket
/// @notice Buy and sell synthetic stock exposure with USDC on Arc. The market is the counterparty:
/// buys mint StockTokens at the oracle price, sells burn them and pay USDC from the reserve.
/// Owner-seeded reserve backs redemptions; the owner can only withdraw surplus above liabilities.
contract StockMarket is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev USDC has 6 decimals, StockTokens 18, prices 8: tokens = usdc * 1e20 / price.
    uint256 private constant SCALE = 1e20;
    uint256 private constant BPS = 10_000;
    uint256 public constant MAX_FEE_BPS = 100;

    IERC20 public immutable usdc;
    IStockOracle public oracle;

    uint256 public feeBps = 30;
    uint256 public maxStaleness = 1 hours;
    uint256 public maxTradeUsdc = 100e6;
    /// @notice cap on each symbol's open interest (supply x price), in USDC
    uint256 public maxOpenInterestUsdc = 1_000e6;

    bytes32[] public symbols;
    mapping(bytes32 => StockToken) public tokenOf;

    event Listed(bytes32 indexed symbol, address token);
    event Bought(address indexed user, bytes32 indexed symbol, uint256 usdcIn, uint256 tokensOut, uint256 price, uint256 fee);
    event Sold(address indexed user, bytes32 indexed symbol, uint256 tokensIn, uint256 usdcOut, uint256 price, uint256 fee);
    event ParamsSet(uint256 feeBps, uint256 maxStaleness, uint256 maxTradeUsdc, uint256 maxOpenInterestUsdc);
    event OracleSet(address oracle);
    event SurplusWithdrawn(address to, uint256 amount);

    error AlreadyListed();
    error NotListed();
    error ZeroAmount();
    error TradeTooLarge();
    error OpenInterestCap();
    error StalePrice();
    error Slippage();
    error InsufficientReserve();
    error FeeTooHigh();

    constructor(address owner_, IERC20 usdc_, IStockOracle oracle_) Ownable(owner_) {
        usdc = usdc_;
        oracle = oracle_;
    }

    // ---------------------------------------------------------------- trading

    function buy(bytes32 symbol, uint256 usdcIn, uint256 minTokensOut)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 tokensOut)
    {
        StockToken token = _token(symbol);
        if (usdcIn == 0) revert ZeroAmount();
        if (usdcIn > maxTradeUsdc) revert TradeTooLarge();
        uint256 price = _freshPrice(symbol);

        uint256 fee = Math.mulDiv(usdcIn, feeBps, BPS, Math.Rounding.Ceil);
        tokensOut = Math.mulDiv(usdcIn - fee, SCALE, price);
        if (tokensOut == 0) revert ZeroAmount();
        if (tokensOut < minTokensOut) revert Slippage();
        if (Math.mulDiv(token.totalSupply() + tokensOut, price, SCALE) > maxOpenInterestUsdc) revert OpenInterestCap();

        usdc.safeTransferFrom(msg.sender, address(this), usdcIn);
        token.mint(msg.sender, tokensOut);
        emit Bought(msg.sender, symbol, usdcIn, tokensOut, price, fee);
    }

    function sell(bytes32 symbol, uint256 tokensIn, uint256 minUsdcOut)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 usdcOut)
    {
        StockToken token = _token(symbol);
        if (tokensIn == 0) revert ZeroAmount();
        uint256 price = _freshPrice(symbol);

        // No trade cap on exits: caps limit new exposure, never trap holders in a winning position.
        uint256 gross = Math.mulDiv(tokensIn, price, SCALE);
        uint256 fee = Math.mulDiv(gross, feeBps, BPS, Math.Rounding.Ceil);
        usdcOut = gross - fee;
        if (usdcOut == 0) revert ZeroAmount();
        if (usdcOut < minUsdcOut) revert Slippage();
        if (usdcOut > usdc.balanceOf(address(this))) revert InsufficientReserve();

        token.burn(msg.sender, tokensIn);
        usdc.safeTransfer(msg.sender, usdcOut);
        emit Sold(msg.sender, symbol, tokensIn, usdcOut, price, fee);
    }

    // ---------------------------------------------------------------- views

    function quoteBuy(bytes32 symbol, uint256 usdcIn) external view returns (uint256 tokensOut, uint256 fee) {
        (uint256 price,) = oracle.getPrice(symbol);
        fee = Math.mulDiv(usdcIn, feeBps, BPS, Math.Rounding.Ceil);
        tokensOut = Math.mulDiv(usdcIn - fee, SCALE, price);
    }

    function quoteSell(bytes32 symbol, uint256 tokensIn) external view returns (uint256 usdcOut, uint256 fee) {
        (uint256 price,) = oracle.getPrice(symbol);
        uint256 gross = Math.mulDiv(tokensIn, price, SCALE);
        fee = Math.mulDiv(gross, feeBps, BPS, Math.Rounding.Ceil);
        usdcOut = gross - fee;
    }

    /// @notice USDC needed to redeem every outstanding token at current prices (before fees).
    function liabilities() public view returns (uint256 total) {
        for (uint256 i; i < symbols.length; ++i) {
            bytes32 s = symbols[i];
            uint256 supply = tokenOf[s].totalSupply();
            if (supply == 0) continue;
            (uint256 price,) = oracle.getPrice(s);
            total += Math.mulDiv(supply, price, SCALE, Math.Rounding.Ceil);
        }
    }

    /// @notice Reserve / liabilities, in bps. type(uint256).max when nothing is outstanding.
    function collateralRatioBps() external view returns (uint256) {
        uint256 l = liabilities();
        if (l == 0) return type(uint256).max;
        return Math.mulDiv(usdc.balanceOf(address(this)), BPS, l);
    }

    function allSymbols() external view returns (bytes32[] memory) {
        return symbols;
    }

    // ---------------------------------------------------------------- admin

    function list(bytes32 symbol, string calldata name, string calldata ticker) external onlyOwner returns (address) {
        if (address(tokenOf[symbol]) != address(0)) revert AlreadyListed();
        StockToken token = new StockToken(name, ticker, symbol);
        tokenOf[symbol] = token;
        symbols.push(symbol);
        emit Listed(symbol, address(token));
        return address(token);
    }

    function setParams(uint256 feeBps_, uint256 maxStaleness_, uint256 maxTradeUsdc_, uint256 maxOpenInterestUsdc_)
        external
        onlyOwner
    {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = feeBps_;
        maxStaleness = maxStaleness_;
        maxTradeUsdc = maxTradeUsdc_;
        maxOpenInterestUsdc = maxOpenInterestUsdc_;
        emit ParamsSet(feeBps_, maxStaleness_, maxTradeUsdc_, maxOpenInterestUsdc_);
    }

    function setOracle(IStockOracle oracle_) external onlyOwner {
        oracle = oracle_;
        emit OracleSet(address(oracle_));
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Withdraw reserve above outstanding liabilities. Users' redemptions can never be drained.
    function withdrawSurplus(address to, uint256 amount) external onlyOwner nonReentrant {
        uint256 bal = usdc.balanceOf(address(this));
        uint256 l = liabilities();
        if (bal < l || amount > bal - l) revert InsufficientReserve();
        usdc.safeTransfer(to, amount);
        emit SurplusWithdrawn(to, amount);
    }

    // ---------------------------------------------------------------- internal

    function _token(bytes32 symbol) private view returns (StockToken t) {
        t = tokenOf[symbol];
        if (address(t) == address(0)) revert NotListed();
    }

    function _freshPrice(bytes32 symbol) private view returns (uint256 price) {
        uint256 updatedAt;
        (price, updatedAt) = oracle.getPrice(symbol);
        if (block.timestamp - updatedAt > maxStaleness) revert StalePrice();
    }
}
