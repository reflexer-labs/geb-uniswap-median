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
    uint256 initETHUSDPrice  = 2500 * 10 ** 18;
    uint256 initialPoolPrice;

    uint256 initETHRAIPairLiquidity = 5 ether; 
    uint256 initRAIETHPairLiquidity = 294.672324375E18;

    uint8   uniswapMedianizerGranularity            = 24;           // 1 hour
    uint256 converterScalingFactor                  = 1 ether;
    uint32  uniswapMedianizerWindowSize             = 86400;        // 24 hours
    uint256 maxWindowSize                           = 72 hours;
    uint256 uniswapETHRAIMedianizerDefaultAmountIn  = 1 ether;

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
        // hevm.warp(startTime);

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
        uint160 initialPrice = 2744777325701582248892809798; //close to U$3.00
        initialPoolPrice = helper_get_price_from_ratio(initialPrice) * 1 ether / initETHUSDPrice ;
        raiWETHPool.initialize(initialPrice);

        //Increase the number of oracle observations
        raiWETHPool.increaseObservationCardinalityNext(8000);

        uniswapRAIWETHMedianizer = new UniswapV3ConverterMedianizer(
            address(0x1),
            pool,
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
        uniswapRAIWETHMedianizer.modifyParameters("targetToken", address(rai));

        assertTrue(uniswapRAIWETHMedianizer.targetToken() != address(0));
        assertTrue(uniswapRAIWETHMedianizer.denominationToken() != address(0));

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

    function helper_addLiquidity() public {
        uint256 token0Am = 10000 ether;
        uint256 token1Am = 10000 ether;
        int24 low = -120000;
        int24 upp = 120000;
        (uint160 sqrtRatioX96, , , , , , ) = raiWETHPool.slot0();
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(sqrtRatioX96, TickMath.getSqrtRatioAtTick(low), TickMath.getSqrtRatioAtTick(upp), token0Am, token1Am);
        raiWETHPool.mint(address(this), low, upp, liq, bytes(""));
    }

    function helper_do_swap(bool zeroForOne, uint256 size) public {
        (uint160 currentPrice, , , , , , ) = raiWETHPool.slot0();
        if(zeroForOne) {
            uint160 sqrtLimitPrice = currentPrice - uint160(size);
            raiWETHPool.swap(address(this), true, int56(size), sqrtLimitPrice, bytes(""));
        } else {
            uint160 sqrtLimitPrice = currentPrice + uint160(size);
            raiWETHPool.swap(address(this), false, int56(size), sqrtLimitPrice, bytes(""));
        }
    }

    function helper_get_price_from_ratio(uint160 sqrtRatioX96) public view returns(uint256 quoteAmount){
        uint128 maxUint = uint128(0-1);
        uint256 baseAmount = 1 ether;

        // Calculate quoteAmount with better precision if it doesn't overflow when multiplied by itself
        if (sqrtRatioX96 <= maxUint) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = address(weth) < address(rai)
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = address(weth) < address(rai)
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }

    function simulateUniv3Swaps() public {
        helper_do_swap(true, 1000);
        hevm.warp(now + uniswapMedianizerWindowSize);
        converterETHPriceFeed.modifyParameters("medianPrice", initETHUSDPrice);
    }

    function simulateMedianizerAndConverter() public {    
        hevm.warp(now + 3600);
        converterETHPriceFeed.modifyParameters("medianPrice", initETHUSDPrice);
        for (uint i = 0; i < uint(uniswapMedianizerGranularity) + 2; i++) {
          helper_do_swap(i % 2== 0, 1000);
          uniswapRAIWETHMedianizer.updateResult(alice);
          hevm.roll(block.number + 1);
          hevm.warp(now + uniswapRAIWETHMedianizer.periodSize());
        }
    }

    function simulateOraclesSimilarPricesErraticDelays() internal {
        hevm.warp(now + 3600);
        uint chosenDelay;
        for (uint i = 0; i < uint(uniswapMedianizerGranularity) * 2; i++) {
          chosenDelay = (i % 2 == 0) ? erraticDelay : uniswapRAIWETHMedianizer.periodSize();
          hevm.warp(now + chosenDelay);
          hevm.roll(block.number + 1);
          uniswapRAIWETHMedianizer.updateResult(address(alice));
          helper_do_swap(i % 2== 0, 1000);
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

    function test_v3_correct_setup() public {
        assertEq(uniswapRAIWETHMedianizer.authorizedAccounts(me), 1);

        assertTrue(address(uniswapRAIWETHMedianizer.converterFeed()) == address(converterETHPriceFeed));

        assertTrue(address(uniswapRAIWETHMedianizer.uniswapPool()) == address(raiWETHPool));

        assertEq(uniswapRAIWETHMedianizer.defaultAmountIn(), uniswapETHRAIMedianizerDefaultAmountIn);

        assertEq(uint256(uniswapRAIWETHMedianizer.windowSize()), uint256(uniswapMedianizerWindowSize));

        assertEq(uniswapRAIWETHMedianizer.updates(), 0);

        assertEq(uniswapRAIWETHMedianizer.periodSize(), 3600);

        assertEq(ethRelayer.maxRewardIncreaseDelay(), maxRewardDelay);

        assertEq(uniswapRAIWETHMedianizer.converterFeedScalingFactor(), converterScalingFactor);

        assertEq(uint256(uniswapRAIWETHMedianizer.granularity()), uniswapMedianizerGranularity);

        assertTrue(uniswapRAIWETHMedianizer.targetToken() == address(rai));

        assertTrue(uniswapRAIWETHMedianizer.denominationToken() == address(weth));

        assertTrue(address(ethRelayer.treasury()) == address(treasury));

        assertEq(ethRelayer.baseUpdateCallerReward(), baseCallerReward);

        assertEq(ethRelayer.maxUpdateCallerReward(), maxCallerReward);

        assertEq(ethRelayer.perSecondCallerRewardIncrease(), perSecondCallerRewardIncrease);

        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertEq(medianPrice, 0);
        assertTrue(!isValid);
    }
    function testFail_v3_small_granularity() public {
        uniswapRAIWETHMedianizer = new UniswapV3ConverterMedianizer(
            address(converterETHPriceFeed),
            address(uniswapFactory),
            uniswapETHRAIMedianizerDefaultAmountIn,
            uniswapMedianizerWindowSize,
            converterScalingFactor,
            maxWindowSize,
            1
        );
    }
    function testFail_v3_window_not_evenly_divisible() public {
        uniswapRAIWETHMedianizer = new UniswapV3ConverterMedianizer(
            address(converterETHPriceFeed),
            address(uniswapFactory),
            uniswapETHRAIMedianizerDefaultAmountIn,
            uniswapMedianizerWindowSize,
            converterScalingFactor,
            maxWindowSize,
            23
        );
    }
    function test_v3_change_converter_feed() public {
        uniswapRAIWETHMedianizer.modifyParameters("converterFeed", address(0x123));

        assertTrue(address(uniswapRAIWETHMedianizer.converterFeed()) == address(0x123));
    }

    function testFail_v3_read_raieth_before_passing_granularity() public {
        hevm.warp(now + 3599);
        assertEq(rai.balanceOf(alice), 0);

        // RAI/WETH
        uniswapRAIWETHMedianizer.updateResult(alice);

        uint medianPrice = uniswapRAIWETHMedianizer.read();
    }

    function test_v3_result_is_inavlid_witout_converter_feed_update() public {
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
            // emit log_named_uint("medianPrice", medianPrice);
        assertTrue(!isValid);
    }

    function testFail_v3_update_result() public {
        uint256 val= uniswapRAIWETHMedianizer.read();
    }

    function test_v3_return_valid_when_usd_price_is_medianized() public {
        simulateMedianizerAndConverter();
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(isValid);
    }

    function test_v3_read_with_valid_converter_observations() public {
        simulateMedianizerAndConverter();
        uint256 value = uniswapRAIWETHMedianizer.read();
        assertTrue(value > 0);
    }

    function testFail_v3_read_raiusdc_before_passing_granularity() public {
        hevm.warp(now + 3599);
        assertEq(rai.balanceOf(alice), 0);

        // RAI/USDC
        uniswapRAIWETHMedianizer.updateResult(alice);

        uint medianPrice = uniswapRAIWETHMedianizer.read();
    }

    function test_v3_get_result_before_passing_granularity() public {
        hevm.warp(now + 3599);
        assertEq(rai.balanceOf(alice), 0);

        // RAI/WETH
        uniswapRAIWETHMedianizer.updateResult(alice);
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(!isValid);
    }

    function test_v3_update_treasury_throws() public {
        MockRevertableTreasury revertTreasury = new MockRevertableTreasury();

        // Set treasury allowance
        revertTreasury.setTotalAllowance(address(ethRelayer), uint(-1));
        revertTreasury.setTotalAllowance(address(ethRelayer), uint(-1));

        ethRelayer.modifyParameters("treasury", address(revertTreasury));

        hevm.warp(now + 3599);
        assertEq(rai.balanceOf(alice), 0);

        // RAI/WETH
        uniswapRAIWETHMedianizer.updateResult(alice);
        assertEq(rai.balanceOf(alice), 0);
    }
    function test_v3_update_treasury_reward_treasury() public {
        hevm.warp(now + 3599);
        assertEq(rai.balanceOf(alice), 0);

        uint treasuryBalance = rai.balanceOf(address(treasury));

        // RAI/WETH
        uniswapRAIWETHMedianizer.updateResult(address(treasury));
        assertEq(rai.balanceOf(address(treasury)), treasuryBalance);
    }

    function testFail_v3_update_ETHRAI_again_immediately() public {
        converterETHPriceFeed.modifyParameters("revertUpdate", 1);

        hevm.warp(now + 1);
        uniswapRAIWETHMedianizer.updateResult(address(this));

        hevm.warp(now + 1);
        uniswapRAIWETHMedianizer.updateResult(address(this));
    }

    function testFail_v3_update_result_ETH_converter_invalid_value() public {
        converterETHPriceFeed.modifyParameters("medianPrice", 0);
        hevm.warp(now + 3599);
        uniswapRAIWETHMedianizer.updateResult(address(this));
    }

    function test_v3_update_result() public {
        hevm.warp(now + 3599);

        // RAI/WETH
        uniswapRAIWETHMedianizer.updateResult(address(this));
        (uint converterTimestamp, uint converterPrice) = uniswapRAIWETHMedianizer.converterFeedObservations(1);
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        uint256 converterPriceCumulative = uniswapRAIWETHMedianizer.converterPriceCumulative();

        assertEq(converterPriceCumulative, initETHUSDPrice * uniswapRAIWETHMedianizer.periodSize());
        assertEq(medianPrice, 0);
        assertTrue(!isValid);
        assertEq(converterTimestamp, now);
        assertEq(converterPrice, initETHUSDPrice * uniswapRAIWETHMedianizer.periodSize());
    }

    function test_v3_simulate_close_prices() public {
        simulateMedianizerAndConverter();

        // RAI/WETH
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(isValid);
        // Won't be equal because univ3 there's no sync function. We need to do an actual trade to store an observatio, which moves the price.
        assertEq(medianPrice / initialPoolPrice, 1);

        assertTrue(
          rai.balanceOf(address(alice)) > baseCallerReward * uint(uniswapMedianizerGranularity)
        );

        uint observedPrice;
        for (uint i = 0; i < uniswapMedianizerGranularity; i++) {
            (, observedPrice) = uniswapRAIWETHMedianizer.converterFeedObservations(i);
            assertEq(observedPrice, initETHUSDPrice * uniswapRAIWETHMedianizer.periodSize());
        }
        assertEq(uniswapRAIWETHMedianizer.converterPriceCumulative(), initETHUSDPrice * 24 * uniswapRAIWETHMedianizer.periodSize());
    }

    function test_v3_simulate_same_prices_erratic_delays() public {
        simulateOraclesSimilarPricesErraticDelays();

        // RAI/WETH
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 4524935194591833599);
    }

    function test_v3_get_result_after_passing_granularity() public {
        simulateMedianizerAndConverter();

        // RAI/WETH
        (, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(isValid);
    }
    function test_v3_read_after_passing_granularity() public {
        simulateMedianizerAndConverter();

        // RAI/WETH
        uint median = uniswapRAIWETHMedianizer.read();
        assertTrue(median > 0);
    }

    function test_v3_tracks_downward_price_movement() public {
        simulateMedianizerAndConverter();
        // Increase 
        hevm.warp(now + 3600);
        for (uint i = 0; i < uint(uniswapMedianizerGranularity) + 2; i++) {
          helper_do_swap(false, 100 ether);
          uniswapRAIWETHMedianizer.updateResult(alice);
          hevm.roll(block.number + 1);
          hevm.warp(now + uniswapRAIWETHMedianizer.periodSize());
        }


        uint256 medianPrice = uniswapRAIWETHMedianizer.read();
        emit log_named_uint("medianPrice", medianPrice);
        assertTrue(medianPrice < initialPoolPrice);
    }
}
