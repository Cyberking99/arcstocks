// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { Pausable } from "openzeppelin-contracts/utils/Pausable.sol";
import { StockMarket } from "../src/StockMarket.sol";
import { PriceOracle, IStockOracle } from "../src/PriceOracle.sol";
import { StockToken } from "../src/StockToken.sol";

contract MockUSDC is ERC20("USD Coin", "USDC") {
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract StockMarketTest is Test {
    bytes32 constant AAPL = "AAPL";
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");

    MockUSDC usdc;
    PriceOracle oracle;
    StockMarket market;
    StockToken aapl;

    function setUp() public {
        vm.warp(1_760_000_000);
        usdc = new MockUSDC();
        oracle = new PriceOracle(owner);
        market = new StockMarket(owner, IERC20(address(usdc)), IStockOracle(address(oracle)));
        vm.prank(owner);
        aapl = StockToken(market.list(AAPL, "Arc Synthetic Apple", "aAAPL"));
        _push(AAPL, 200e8); // $200

        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(market), type(uint256).max);
    }

    function _push(bytes32 s, uint256 price) internal {
        bytes32[] memory ss = new bytes32[](1);
        uint256[] memory ps = new uint256[](1);
        uint256[] memory ts = new uint256[](1);
        (ss[0], ps[0], ts[0]) = (s, price, block.timestamp);
        vm.prank(owner);
        oracle.push(ss, ps, ts);
    }

    function test_buyMintsAtOraclePriceMinusFee() public {
        vm.prank(alice);
        uint256 out = market.buy(AAPL, 100e6, 0);
        // 100 USDC - 0.30 fee = 99.70 USDC / $200 = 0.4985 shares
        assertEq(out, 0.4985e18);
        assertEq(aapl.balanceOf(alice), out);
        assertEq(usdc.balanceOf(address(market)), 100e6);
    }

    function test_roundTripAtSamePriceLosesOnlyFees() public {
        vm.startPrank(alice);
        uint256 out = market.buy(AAPL, 100e6, 0);
        uint256 back = market.sell(AAPL, out, 0);
        vm.stopPrank();
        assertLt(back, 100e6);
        assertGt(back, 99.3e6);
        assertEq(aapl.totalSupply(), 0);
    }

    function test_sellAfterPriceRisePaysProfitFromReserve() public {
        usdc.mint(owner, 500e6);
        vm.prank(owner);
        usdc.transfer(address(market), 500e6); // seed reserve

        vm.prank(alice);
        uint256 out = market.buy(AAPL, 100e6, 0);
        _push(AAPL, 220e8); // +10%
        vm.prank(alice);
        uint256 back = market.sell(AAPL, out, 0);
        assertGt(back, 109e6);
    }

    function test_sellRevertsWhenReserveShort() public {
        vm.prank(alice);
        uint256 out = market.buy(AAPL, 100e6, 0);
        vm.prank(owner);
        market.setParams(30, 1 hours, 1_000e6, 10_000e6);
        _push(AAPL, 400e8); // doubles, unseeded reserve can't pay
        vm.prank(alice);
        vm.expectRevert(StockMarket.InsufficientReserve.selector);
        market.sell(AAPL, out, 0);
    }

    function test_stalePriceReverts() public {
        skip(1 hours + 1);
        vm.prank(alice);
        vm.expectRevert(StockMarket.StalePrice.selector);
        market.buy(AAPL, 10e6, 0);
    }

    function test_slippageReverts() public {
        vm.prank(alice);
        vm.expectRevert(StockMarket.Slippage.selector);
        market.buy(AAPL, 100e6, 0.5e18);
    }

    function test_tradeCapAndOpenInterestCap() public {
        vm.prank(alice);
        vm.expectRevert(StockMarket.TradeTooLarge.selector);
        market.buy(AAPL, 101e6, 0);

        vm.prank(owner);
        market.setParams(30, 1 hours, 1_000e6, 150e6);
        vm.prank(alice);
        vm.expectRevert(StockMarket.OpenInterestCap.selector);
        market.buy(AAPL, 200e6, 0);
    }

    function test_pauseBlocksTrading() public {
        vm.prank(owner);
        market.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.buy(AAPL, 10e6, 0);
    }

    function test_unlistedAndOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(StockMarket.NotListed.selector);
        market.buy("TSLA", 10e6, 0);

        vm.prank(alice);
        vm.expectRevert();
        market.list("TSLA", "x", "x");

        vm.prank(alice);
        vm.expectRevert(PriceOracle.NotUpdater.selector);
        oracle.push(new bytes32[](0), new uint256[](0), new uint256[](0));

        vm.prank(alice);
        vm.expectRevert(StockToken.OnlyMarket.selector);
        aapl.mint(alice, 1);
    }

    function test_ownerCannotWithdrawUserBacking() public {
        vm.prank(alice);
        market.buy(AAPL, 100e6, 0);
        uint256 l = market.liabilities();
        uint256 surplus = usdc.balanceOf(address(market)) - l;
        vm.startPrank(owner);
        vm.expectRevert(StockMarket.InsufficientReserve.selector);
        market.withdrawSurplus(owner, surplus + 1);
        market.withdrawSurplus(owner, surplus);
        vm.stopPrank();
        assertGe(usdc.balanceOf(address(market)), market.liabilities());
    }

    /// At a constant price, any sequence of buy-then-sell can never pay out more than was paid in.
    function testFuzz_noValueLeakAtConstantPrice(uint256 usdcIn, uint256 price, uint256 sellFrac) public {
        usdcIn = bound(usdcIn, 1e4, 100e6);
        price = bound(price, 1e8, 5_000e8);
        sellFrac = bound(sellFrac, 1, 100);
        _push(AAPL, price);

        vm.startPrank(alice);
        uint256 before = usdc.balanceOf(alice);
        uint256 out = market.buy(AAPL, usdcIn, 0);
        uint256 toSell = out * sellFrac / 100;
        (uint256 q,) = market.quoteSell(AAPL, toSell);
        if (q > 0) market.sell(AAPL, toSell, 0);
        vm.stopPrank();

        assertLe(usdc.balanceOf(alice), before);
        assertGe(usdc.balanceOf(address(market)), market.liabilities());
    }
}
