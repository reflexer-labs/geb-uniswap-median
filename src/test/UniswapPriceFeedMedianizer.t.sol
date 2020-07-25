pragma solidity ^0.6.7;

import "ds-test/test.sol";
import "ds-weth/weth9.sol";
import "ds-token/token.sol";
import "geb-chainlink-median/ChainlinkPriceFeedMedianizer.sol";

import "./uni/UniswapV2ERC20.sol";
import "./uni/UniswapV2Factory.sol";
import "./uni/UniswapV2Pair.sol";
import "./uni/UniswapV2Router02.sol";

import { UniswapPriceFeedMedianizer } from  "../UniswapPriceFeedMedianizer.sol";

// --- Token Contracts ---
contract USDC is DSToken {
    constructor(bytes32 symbol) public DSToken(symbol) {
        decimals = 6;
        mint(100 ether);
    }
}

// --- Chainlink Contracts ---
contract ChainlinkAggregator {
  int256 public latestAnswer;
  uint256 public latestTimestamp;

  function modifyParameters(bytes32 parameter, int256 data) public {
      latestAnswer    = data;
      latestTimestamp = now;
  }
}
contract ChainlinkETHMedianizer is ChainlinkPriceFeedMedianizer {
    constructor(address aggregator) public ChainlinkPriceFeedMedianizer(aggregator) {
        symbol = "ETHUSD";
    }
}
contract ChainlinkUSDCMedianizer is ChainlinkPriceFeedMedianizer {
    constructor(address aggregator) public ChainlinkPriceFeedMedianizer(aggregator) {
        symbol = "USDCUSD";
    }
}

contract UniswapPriceFeedMedianizerTest is DSTest {
    ChainlinkETHMedianizer chainlinkETHPriceFeed;
    ChainlinkUSDCMedianizer chainlinkUSDCPriceFeed;
    ChainlinkAggregator ethUSDAggregator;
    ChainlinkAggregator usdcUSDAggregator;

    UniswapPriceFeedMedianizer uniswapRAIWETHMedianizer;
    UniswapPriceFeedMedianizer uniswapRAIUSDCMedianizer;

    UniswapV2Factory uniswapFactory;
    UniswapV2Router02 uniswapRouter;

    UniswapV2Pair raiWETHPair;
    UniswapV2Pair raiUSDCPair;
    UniswapV2Pair wethWETHCompanionPair;

    DSToken rai;
    USDC usdc;
    WETH9_ weth;
    WETH9_ wethCompanion;

    uint256 initTokenAmount  = 1000 ether;
    uint256 initETHUSDPrice  = 250 * 10 ** 8;
    uint256 initUSDCUSDPrice = 10 ** 8;

    uint256 initETHRAIPairLiquidity = 5 ether;                // 1250 USD
    uint256 initRAIETHPairLiquidity = 294672324375000000000;  // 1 RAI = 4.242 USD

    uint256 initETHETHPairLiquidity = 5 ether;

    uint256 initUSDCRAIPairLiquidity = 4242000;
    uint256 initRAIUSDCPairLiquidity = 1 ether;

    uint8   uniswapMedianizerGranularity     = 24;           // 1 hour
    uint256 converterScalingFactor           = 1 ether;
    uint256 uniswapMedianizerWindowSize      = 86400;        // 24 hours
    uint256 uniswapMedianizerDefaultAmountIn = 1 ether;

    function setUp() public {
        // Setup Uniswap
        uniswapFactory = new UniswapV2Factory(address(this));
        createUniswapPairs();
        uniswapRouter  = new UniswapV2Router02(address(uniswapFactory), address(weth));

        // Setup Chainlink medians
        ethUSDAggregator = new ChainlinkAggregator();
        ethUSDAggregator.modifyParameters("latestAnswer", int(initETHUSDPrice));

        usdcUSDAggregator = new ChainlinkAggregator();
        usdcUSDAggregator.modifyParameters("latestAnswer", int(initUSDCUSDPrice));

        chainlinkETHPriceFeed = new ChainlinkETHMedianizer(address(ethUSDAggregator));
        chainlinkUSDCPriceFeed = new ChainlinkUSDCMedianizer(address(usdcUSDAggregator));

        // Setup Uniswap medians
        uniswapRAIWETHMedianizer = new UniswapPriceFeedMedianizer(
            address(chainlinkETHPriceFeed),
            address(uniswapFactory),
            address(rai),
            address(weth),
            uniswapMedianizerDefaultAmountIn,
            uniswapMedianizerWindowSize,
            converterScalingFactor,
            uniswapMedianizerGranularity
        );
        uniswapRAIUSDCMedianizer = new UniswapPriceFeedMedianizer(
            address(chainlinkUSDCPriceFeed),
            address(uniswapFactory),
            address(rai),
            address(usdc),
            uniswapMedianizerDefaultAmountIn,
            uniswapMedianizerWindowSize,
            converterScalingFactor,
            uniswapMedianizerGranularity
        );

        // Add pair liquidity
        addPairLiquidity(wethWETHCompanionPair, address(weth), address(wethCompanion), initETHETHPairLiquidity, initETHETHPairLiquidity);
        addPairLiquidity(raiWETHPair, address(rai), address(weth), initRAIETHPairLiquidity, initETHRAIPairLiquidity);
        addPairLiquidity(raiUSDCPair, address(rai), address(usdc), initRAIUSDCPairLiquidity, initUSDCRAIPairLiquidity);
    }

    // --- Uniswap utils ---
    function createUniswapPairs() internal {
        // Create Tokens
        weth = new WETH9_();
        wethCompanion = new WETH9_();

        rai = new DSToken("RAI");
        rai.mint(initTokenAmount);

        usdc = new USDC("USDC");

        // Create WETH
        weth.deposit{value: initTokenAmount}();
        wethCompanion.deposit{value: initTokenAmount}();

        // Setup WETH/WETH pair
        uniswapFactory.createPair(address(weth), address(wethCompanion));
        wethWETHCompanionPair = UniswapV2Pair(uniswapFactory.getPair(address(weth), address(wethCompanion)));

        // Setup WETH/RAI pair
        uniswapFactory.createPair(address(weth), address(rai));
        raiWETHPair = UniswapV2Pair(uniswapFactory.getPair(address(weth), address(rai)));

        // Setup USDC/RAI pair
        uniswapFactory.createPair(address(usdc), address(rai));
        raiUSDCPair = UniswapV2Pair(uniswapFactory.getPair(address(usdc), address(rai)));
    }
    function addPairLiquidity(UniswapV2Pair pair, address token1, address token2, uint256 amount1, uint256 amount2) internal {
        DSToken(token1).transfer(address(pair), amount1);
        DSToken(token2).transfer(address(pair), amount2);
        pair.sync();
    }

    function testFail_basic_sanity() public {
        assertTrue(false);
    }

    function test_basic_sanity() public {
        assertTrue(true);
    }
}
