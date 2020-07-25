pragma solidity ^0.6.7;

import "ds-test/test.sol";
import "ds-weth/weth9.sol";
import "ds-token/token.sol";

import "./orcl/MockMedianizer.sol";

import "./uni/UniswapV2ERC20.sol";
import "./uni/UniswapV2Factory.sol";
import "./uni/UniswapV2Pair.sol";
import "./uni/UniswapV2Router02.sol";

import { UniswapPriceFeedMedianizer } from  "../UniswapPriceFeedMedianizer.sol";

abstract contract Hevm {
    function warp(uint256) virtual public;
}

// --- Token Contracts ---
contract USDC is DSToken {
    constructor(bytes32 symbol) public DSToken(symbol) {
        decimals = 6;
        mint(100 ether);
    }
}

// --- Median Contracts ---
contract ETHMedianizer is MockMedianizer {
    constructor() public {
        symbol = "ETHUSD";
    }
}
contract USDCMedianizer is MockMedianizer {
    constructor() public {
        symbol = "USDCUSD";
    }
}

contract UniswapPriceFeedMedianizerTest is DSTest {
    Hevm hevm;

    ETHMedianizer converterETHPriceFeed;
    USDCMedianizer converterUSDCPriceFeed;

    UniswapPriceFeedMedianizer uniswapRAIWETHMedianizer;
    UniswapPriceFeedMedianizer uniswapRAIUSDCMedianizer;

    UniswapV2Factory uniswapFactory;
    UniswapV2Router02 uniswapRouter;

    UniswapV2Pair raiWETHPair;
    UniswapV2Pair raiUSDCPair;

    DSToken rai;
    USDC usdc;
    WETH9_ weth;

    uint256 startTime = 1577836800;

    uint256 initTokenAmount  = 1000 ether;
    uint256 initETHUSDPrice  = 250 * 10 ** 8;
    uint256 initUSDCUSDPrice = 10 ** 8;

    uint256 initETHRAIPairLiquidity = 5 ether;                // 1250 USD
    uint256 initRAIETHPairLiquidity = 294672324375000000000;  // 1 RAI = 4.242 USD and so we need 294.672324375 of them

    uint256 initUSDCRAIPairLiquidity = 4242000;
    uint256 initRAIUSDCPairLiquidity = 1 ether;

    uint8   uniswapMedianizerGranularity     = 24;           // 1 hour
    uint256 converterScalingFactor           = 1 ether;
    uint256 uniswapMedianizerWindowSize      = 86400;        // 24 hours
    uint256 uniswapMedianizerDefaultAmountIn = 1 ether;

    address me;

    function setUp() public {
        me = address(this);

        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(startTime);

        // Setup Uniswap
        uniswapFactory = new UniswapV2Factory(address(this));
        createUniswapPairs();
        uniswapRouter  = new UniswapV2Router02(address(uniswapFactory), address(weth));

        // Setup converter medians
        ethUSDAggregator = new Aggregator();
        ethUSDAggregator.modifyParameters("latestAnswer", int(initETHUSDPrice));

        usdcUSDAggregator = new Aggregator();
        usdcUSDAggregator.modifyParameters("latestAnswer", int(initUSDCUSDPrice));

        converterETHPriceFeed = new ETHMedianizer(address(ethUSDAggregator));
        converterUSDCPriceFeed = new USDCMedianizer(address(usdcUSDAggregator));

        // Setup Uniswap medians
        uniswapRAIWETHMedianizer = new UniswapPriceFeedMedianizer(
            address(converterETHPriceFeed),
            address(uniswapFactory),
            address(rai),
            address(weth),
            uniswapMedianizerDefaultAmountIn,
            uniswapMedianizerWindowSize,
            converterScalingFactor,
            uniswapMedianizerGranularity
        );
        uniswapRAIUSDCMedianizer = new UniswapPriceFeedMedianizer(
            address(converterUSDCPriceFeed),
            address(uniswapFactory),
            address(rai),
            address(usdc),
            uniswapMedianizerDefaultAmountIn,
            uniswapMedianizerWindowSize,
            converterScalingFactor,
            uniswapMedianizerGranularity
        );

        // Add pair liquidity
        addPairLiquidity(raiWETHPair, address(rai), address(weth), initRAIETHPairLiquidity, initETHRAIPairLiquidity);
        addPairLiquidity(raiUSDCPair, address(rai), address(usdc), initRAIUSDCPairLiquidity, initUSDCRAIPairLiquidity);
    }

    // --- Uniswap utils ---
    function createUniswapPairs() internal {
        // Create Tokens
        weth = new WETH9_();

        rai = new DSToken("RAI");
        rai.mint(initTokenAmount);

        usdc = new USDC("USDC");

        // Create WETH
        weth.deposit{value: initTokenAmount}();

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

    function test_correct_setup() public {
        assertEq(uniswapRAIWETHMedianizer.authorizedAccounts(me), 1);
        assertEq(uniswapRAIUSDCMedianizer.authorizedAccounts(me), 1);

        assertTrue(uniswapRAIWETHMedianizer.converterFeed() == address(converterETHPriceFeed));
        assertTrue(uniswapRAIUSDCMedianizer.converterFeed() == address(converterUSDCPriceFeed));

        assertTrue(uniswapRAIWETHMedianizer.uniswapFactory() == address(uniswapFactory));
        assertTrue(uniswapRAIUSDCMedianizer.uniswapFactory() == address(uniswapFactory));

        assertEq(uniswapRAIWETHMedianizer.defaultAmountIn(), uniswapMedianizerDefaultAmountIn);
        assertRq(uniswapRAIUSDCMedianizer.defaultAmountIn(), uniswapMedianizerDefaultAmountIn);

        assertEq(uniswapRAIWETHMedianizer.windowSize(), uniswapMedianizerWindowSize);
        assertRq(uniswapRAIUSDCMedianizer.windowSize(), uniswapMedianizerWindowSize);

        assertEq(uniswapRAIWETHMedianizer.converterFeedScalingFactor(), converterScalingFactor);
        assertRq(uniswapRAIUSDCMedianizer.converterFeedScalingFactor(), converterScalingFactor);

        assertEq(uniswapRAIWETHMedianizer.granularity(), uniswapMedianizerGranularity);
        assertRq(uniswapRAIUSDCMedianizer.granularity(), uniswapMedianizerGranularity);

        assertTrue(uniswapRAIWETHMedianizer.targetToken() == address(rai));
        assertTrue(uniswapRAIUSDCMedianizer.targetToken() == address(rai));

        assertTrue(uniswapRAIWETHMedianizer.denominationToken() == address(weth));
        assertTrue(uniswapRAIUSDCMedianizer.denominationToken() == address(usdc));

        assertTrue(uniswapRAIWETHMedianizer.uniswapPair() == address(raiWETHPair));
        assertTrue(uniswapRAIUSDCMedianizer.uniswapPair() == address(raiUSDCPair));
    }
    function testFail_small_granularity() public {

    }
    function testFail_window_not_evenly_divisible() public {

    }
    function testFail_null_converter() public {

    }
    function testFail_inexistent_pair() public {

    }
}
