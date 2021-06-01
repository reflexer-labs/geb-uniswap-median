pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-weth/weth9.sol";
import "ds-token/token.sol";
import "geb-treasury-reimbursement/relayer/IncreasingRewardRelayer.sol";

import "./orcl/MockMedianizer.sol";
import "./geb/MockTreasury.sol";

import "../univ3/UniswapV3Factory.sol";
import "../univ3/UniswapV3Pool.sol";
import "../univ3/libraries/LiquidityAmounts.sol";


import { UniswapV3ConverterMedianizer } from  "../UniswapV3ConverterMedianizer.sol";

abstract contract Hevm {
    function warp(uint256) virtual public;
    function roll(uint256) virtual public;
}

contract _WETH9 is DSToken {
    constructor(string memory symbol, uint256 mintAmount) public DSToken(symbol, symbol) {
        decimals = 6;
        mint(mintAmount);
    }
}

contract ETHMedianizer is MockMedianizer {
    constructor() public {
        symbol = "ETHUSD";
    }
}
contract UniswapV3ConverterMedianizerTest is DSTest {
    Hevm hevm;

    UniswapV3ConverterMedianizer uniswapRAIWETHMedianizer;

    MockTreasury treasury;

    ETHMedianizer converterETHPriceFeed;

    IncreasingRewardRelayer ethRelayer;

    UniswapV3Pool uniswapPool;

    address raiAddress = 0x03ab458634910AaD20eF5f1C8ee96F1D6ac54919;
    address wethAddress = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    uint256 medianETHUSDPrice       = 2700 * 10 ** 18; //24h median

    uint8   uniswapMedianizerGranularity            = 24;           // 1 hour
    uint256 converterScalingFactor                  = 1 ether;
    uint32  uniswapMedianizerWindowSize             = 86400;        // 24 hours
    uint256 maxWindowSize                           = 72 hours;
    uint256 uniswapETHRAIMedianizerDefaultAmountIn  = 1 ether;

    uint256 initTokenAmount         = 100000000 ether;
    uint256 baseCallerReward = 15 ether;
    uint256 maxCallerReward  = 20 ether;
    uint256 maxRewardDelay   = 42 days;
    uint256 perSecondCallerRewardIncrease = 1000192559420674483977255848; // 100% over 1 hour

    uint erraticDelay = 3 hours;
    address alice     = address(0x4567);
    address me;

    uint256 internal constant RAY = 10 ** 27;

    function setUp() public {
        me = address(this);
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

        DSToken mockRai = new DSToken("RAI", "RAI");
        mockRai.mint(initTokenAmount);

        // Create treasury
        treasury = new MockTreasury(address(mockRai));
        mockRai.transfer(address(treasury), 5000 * baseCallerReward);

        uniswapPool = UniswapV3Pool(0x14DE8287AdC90f0f95Bf567C0707670de52e3813);
        converterETHPriceFeed = new ETHMedianizer();
        

        uniswapRAIWETHMedianizer = new UniswapV3ConverterMedianizer(
            address(0x1),
            address(uniswapPool),
            uniswapETHRAIMedianizerDefaultAmountIn,
            uniswapMedianizerWindowSize,
            converterScalingFactor,
            maxWindowSize,
            uniswapMedianizerGranularity
        );

        ethRelayer = new IncreasingRewardRelayer(
            address(uniswapRAIWETHMedianizer),
            address(treasury),
            baseCallerReward,
            maxCallerReward,
            perSecondCallerRewardIncrease,
            uniswapRAIWETHMedianizer.periodSize()
        );

        // set relayer inside oracle contract
        uniswapRAIWETHMedianizer.modifyParameters("relayer", address(ethRelayer));

        // Set treasury allowance
        treasury.setTotalAllowance(address(ethRelayer), uint(-1));
        treasury.setPerBlockAllowance(address(ethRelayer), uint(-1));

        ethRelayer.modifyParameters("maxRewardIncreaseDelay", maxRewardDelay);

        // Set converter addresses
        uniswapRAIWETHMedianizer.modifyParameters("converterFeed", address(converterETHPriceFeed));

        // Set target and denomination tokens
        uniswapRAIWETHMedianizer.modifyParameters("targetToken", raiAddress);
    }

    function populateETHData() public {
        // Get back 25h in the past
        hevm.warp(now - 90000);
        for (uint i = 0; i < 25; i++){
            converterETHPriceFeed.modifyParameters("medianPrice", medianETHUSDPrice);
            // Update Result
            uniswapRAIWETHMedianizer.updateResult(me);
            //Advance 1 hour
            hevm.warp(now + 3600);
        }
    }

    //Uncomment this to run tests agains a mainnet rpc url

    function test_m_invalid_without_converter_data() public {
        (, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(!isValid);
    }

    function testFail_m_invalid_read() public {
        uniswapRAIWETHMedianizer.read();
    }

    function test_m_read_from_mainnetData() public {
        populateETHData();

        uint256 ethusd = converterETHPriceFeed.read();
        log_named_uint("ethusd", ethusd);

        uint256 medianPrice = uniswapRAIWETHMedianizer.read();
        log_named_uint("medianPrice", medianPrice);

        //Hard to test a precise value because we're using real mainnet data and thus the median changes at every call
        // Cheking that the value is between U$2.95 and U$3.05
        assertTrue(medianPrice > 2950000000000000000 && medianPrice < 3090000000000000000);
    }


}
