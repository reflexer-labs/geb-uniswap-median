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


import { UniswapV3ConverterBasicMeanPriceFeedMedianizer } from  "../UniswapV3ConverterBasicMeanPriceFeedMedianizer.sol";

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
contract USDCMedianizer is MockMedianizer {
    constructor() public {
        symbol = "USDCUSD";
    }
}

contract UniswapV3ConverterBasicMeanPriceFeedMedianizerTest is DSTest {
    Hevm hevm;

    UniswapV3ConverterBasicMeanPriceFeedMedianizer uniswapRAIWETHMedianizer;

    MockTreasury treasury;

    ETHMedianizer converterETHPriceFeed;
    USDCMedianizer converterUSDCPriceFeed;

    IncreasingRewardRelayer usdcRelayer;
    IncreasingRewardRelayer ethRelayer;

    UniswapV3Factory uniswapFactory;

    UniswapV3Pool raiWETHPool;
    UniswapV3Pool raiUSDCPool;

    DSToken rai;
    _WETH9 weth;

    DSToken token0;
    DSToken token1;

    uint256 startTime               = 1577836800;
    uint256 initTokenAmount         = 100000000 ether;
    uint256 initETHUSDPrice  = 250 * 10 ** 18;
    uint256 initUSDCUSDPrice = 10 ** 18;

    uint256 initETHRAIPairLiquidity = 5 ether; 
    uint256 initRAIETHPairLiquidity = 294.672324375E18;

    uint8   uniswapMedianizerGranularity            = 24;           // 1 hour
    uint256 converterScalingFactor                  = 1 ether;
    uint32  uniswapMedianizerWindowSize             = 86400;        // 24 hours
    uint256 uniswapETHRAIMedianizerDefaultAmountIn  = 1 ether;
    uint256 uniswapUSDCRAIMedianizerDefaultAmountIn = 10 ** 12 * 1 ether;

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
        hevm.warp(startTime);

        // Deploy Tokens
        weth = new _WETH9("WETH", initTokenAmount);

        rai = new DSToken("RAI", "RAI");
        rai.mint(initTokenAmount);

        (token0, token1) = address(rai) < address(weth) ? (DSToken(rai), DSToken(weth)) : (DSToken(weth), DSToken(rai));

        // Create treasury
        treasury = new MockTreasury(address(rai));
        rai.transfer(address(treasury), 5000 * baseCallerReward);

        // Setup converter medians
        converterETHPriceFeed = new ETHMedianizer();
        converterETHPriceFeed.modifyParameters("medianPrice", initETHUSDPrice);

        // Setup Uniswap
        uniswapFactory = new UniswapV3Factory();

        address pool = uniswapFactory.createPool(address(token0), address(token1), 3000);
        raiWETHPool = UniswapV3Pool(pool);
        uint160 initialPrice = helper_getInitialPoolPrice();
        raiWETHPool.initialize(initialPrice);

        //Increase the number of oracle observations
        raiWETHPool.increaseObservationCardinalityNext(8000);

        uniswapRAIWETHMedianizer = new UniswapV3ConverterBasicMeanPriceFeedMedianizer(
            address(0x1),
            address(uniswapFactory),
            uniswapETHRAIMedianizerDefaultAmountIn,
            uniswapMedianizerWindowSize,
            converterScalingFactor,
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
        uniswapRAIWETHMedianizer.modifyParameters("targetToken", address(rai));
        uniswapRAIWETHMedianizer.modifyParameters("denominationToken", address(weth));

        assertTrue(uniswapRAIWETHMedianizer.uniswapPool() != address(0));

        // Add liquidity to the pool
        helper_addLiquidity();

        // The pool needs some retroactive data
        simulateUniv3Swaps();
    }

    // --- Math ---
    function multiply(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x, 'mul-overflow');
    }

    function divide(uint x, uint y) internal pure returns (uint z) {
        z = x / y;
    }
    function sqrt(uint256 y) public pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function helper_getInitialPoolPrice() internal view returns(uint160) {
        uint160 sqrtPriceX96;
        uint256 scale = 1000000000;
        if (address(token0) == address(rai)) {
            sqrtPriceX96 = uint160(sqrt((divide(multiply(initETHRAIPairLiquidity,scale),initRAIETHPairLiquidity) << 192) / scale));
        } else {
            sqrtPriceX96 = uint160(sqrt((divide(multiply(initRAIETHPairLiquidity,scale),initETHRAIPairLiquidity) << 192) / scale));
        }
        return sqrtPriceX96;
    }

    function helper_addLiquidity() public {
        uint256 token0Am = 10 ether;
        uint256 token1Am = 10 ether;
        int24 low = -887220;
        int24 upp = 887220;
        (uint160 sqrtRatioX96, , , , , , ) = raiWETHPool.slot0();
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(sqrtRatioX96, TickMath.getSqrtRatioAtTick(low), TickMath.getSqrtRatioAtTick(upp), token0Am, token1Am);
        raiWETHPool.mint(address(this), low, upp, 1000000000, bytes(""));
    }

    function helper_do_swap() public {
        (uint160 currentPrice, , , , , , ) = raiWETHPool.slot0();
        uint160 sqrtLimitPrice = currentPrice + 1 ether ;
        raiWETHPool.swap(address(this), false, 1 ether, sqrtLimitPrice, bytes(""));
    }

    function simulateUniv3Swaps() public {
        for (uint i = 0; i < 30; i++) {
          helper_do_swap();
          hevm.roll(1);
          hevm.warp(150);
        }
    }

    function simulateMedianizerAndConverter() public {    
        hevm.warp(now + 10);
        for (uint i = 0; i < uint(uniswapMedianizerGranularity) + 2; i++) {
          helper_do_swap();
          uniswapRAIWETHMedianizer.updateResult(me);
          hevm.roll(1);
          hevm.warp(now + uniswapRAIWETHMedianizer.periodSize());
        }
    }


    // --- Uniswap Callbacks ---
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external {
        token0.transfer(msg.sender, amount0Owed);
        token1.transfer(msg.sender, amount1Owed);
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        if (amount1Delta > 0) token1.transfer(msg.sender, uint256(amount1Delta));
        if (amount0Delta > 0) token0.transfer(msg.sender, uint256(amount0Delta));
    }


    // --- Test Functions --- 

    function test_correct_setup_m() public {
        assertEq(uniswapRAIWETHMedianizer.authorizedAccounts(me), 1);

        assertTrue(address(uniswapRAIWETHMedianizer.converterFeed()) == address(converterETHPriceFeed));

        assertTrue(address(uniswapRAIWETHMedianizer.uniswapV3Factory()) == address(uniswapFactory));

        assertEq(uniswapRAIWETHMedianizer.defaultAmountIn(), uniswapETHRAIMedianizerDefaultAmountIn);

        // assertEq(uniswapRAIWETHMedianizer.windowSize(), uniswapMedianizerWindowSize);

        assertEq(uniswapRAIWETHMedianizer.updates(), 0);

        assertEq(uniswapRAIWETHMedianizer.periodSize(), 3600);

        assertEq(ethRelayer.maxRewardIncreaseDelay(), maxRewardDelay);

        assertEq(uniswapRAIWETHMedianizer.converterFeedScalingFactor(), converterScalingFactor);

        assertEq(uint256(uniswapRAIWETHMedianizer.granularity()), uniswapMedianizerGranularity);

        assertTrue(uniswapRAIWETHMedianizer.targetToken() == address(rai));

        assertTrue(uniswapRAIWETHMedianizer.denominationToken() == address(weth));

        assertTrue(uniswapRAIWETHMedianizer.uniswapPool() == address(raiWETHPool));

        assertTrue(address(ethRelayer.treasury()) == address(treasury));

        assertEq(ethRelayer.baseUpdateCallerReward(), baseCallerReward);

        assertEq(ethRelayer.maxUpdateCallerReward(), maxCallerReward);

        assertEq(ethRelayer.perSecondCallerRewardIncrease(), perSecondCallerRewardIncrease);

        // (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        // assertEq(medianPrice, 0);
        // assertTrue(!isValid);

        // uint256 converterObservationsListLength = uniswapRAIWETHMedianizer.getObservationListLength();
        // assertTrue(converterObservationsListLength > 0);
    }
    function testFail_small_granularity() public {
        uniswapRAIWETHMedianizer = new UniswapV3ConverterBasicMeanPriceFeedMedianizer(
            address(converterETHPriceFeed),
            address(uniswapFactory),
            uniswapETHRAIMedianizerDefaultAmountIn,
            uniswapMedianizerWindowSize,
            converterScalingFactor,
            1
        );
    }
    function testFail_window_not_evenly_divisible() public {
        uniswapRAIWETHMedianizer = new UniswapV3ConverterBasicMeanPriceFeedMedianizer(
            address(converterETHPriceFeed),
            address(uniswapFactory),
            uniswapETHRAIMedianizerDefaultAmountIn,
            uniswapMedianizerWindowSize,
            converterScalingFactor,
            23
        );
    }
    function test_change_converter_feed() public {
        uniswapRAIWETHMedianizer.modifyParameters("converterFeed", address(0x123));

        assertTrue(address(uniswapRAIWETHMedianizer.converterFeed()) == address(0x123));
    }

    function testFail_read_raieth_before_passing_granularity() public {
        hevm.warp(now + 3599);
        assertEq(rai.balanceOf(alice), 0);

        // RAI/WETH
        uniswapRAIWETHMedianizer.updateResult(alice);

        uint medianPrice = uniswapRAIWETHMedianizer.read();
    }

    function test_get_result_before_passing_granularity() public {
        hevm.warp(now + 3599);
        assertEq(rai.balanceOf(alice), 0);

        // RAI/WETH
        uniswapRAIWETHMedianizer.updateResult(alice);
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(!isValid);
    }

    function test_update_resultP() public {
        // simulateMedianizerAndConverter();
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        emit log_named_uint("medianPrice", medianPrice);
        assertTrue(false);
        
    }


}