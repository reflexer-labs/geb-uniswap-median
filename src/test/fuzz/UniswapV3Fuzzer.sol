pragma solidity 0.6.7;

import "./FlatenedImports.sol";

contract UniswapV3Fuzzer {

    constructor() public {
        setUp();
    }

    //Tested Properties
    function echidna_return_valid_result_if_granularity_has_passed() public view returns(bool){
        if(uniswapRAIWETHMedianizer.updates() >= uniswapRAIWETHMedianizer.granularity() && uniswapRAIWETHMedianizer.getTimeElapsedSinceFirstObservationInWindow()<= maxWindowSize){
            (, bool valid) = uniswapRAIWETHMedianizer.getResultWithValidity(); 
            return valid;
        } else {
            return true;
        }
    }

    // function echidna_no_update_twice_on_window() public view returns(bool) {
    //     uint256 startingIndex = uniswapRAIWETHMedianizer.updates() % uniswapMedianizerGranularity;
    //     bool invalid = false;
    //     for(uint256 i = startingIndex; i < uniswapMedianizerGranularity; i++) {
    //         uint256 pos1 = i % uniswapMedianizerGranularity;
    //         uint256 pos2 = (i + 1) % uniswapMedianizerGranularity;
    //         (uint256 firstTime, ) = uniswapRAIWETHMedianizer.converterFeedObservations(pos1);
    //         (uint256 secondTime, ) = uniswapRAIWETHMedianizer.converterFeedObservations(pos2);
    //         if (secondTime - firstTime < uniswapMedianizerWindowSize / uniswapMedianizerGranularity) invalid = true;
    //     }
    // }

    //Actions for fuzzing
    function updateResult(address relayer) public {
        uniswapRAIWETHMedianizer.updateResult(relayer);
    }

    function changeETHValue(uint256 val) public {
        converterETHPriceFeed.modifyParameters("medianPrice", val);
    }

    function addLiquidityToUniswap(uint8 amt, int24 boundary) public {
        if (boundary > 600000 || boundary < -600000) boundary = 600000;
        if(boundary < 0) {
            boundary = boundary * -1;
        }
        int24 low = boundary * -1;
        int24 upp = boundary;
        (uint160 sqrtRatioX96, , , , , , ) = raiWETHPool.slot0();
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(sqrtRatioX96, TickMath.getSqrtRatioAtTick(low), TickMath.getSqrtRatioAtTick(upp), amt * 1 ether, amt * 1 ether);
        raiWETHPool.mint(address(this), low, upp, liq, bytes(""));
    }

    function swapOnUniswap(bool zeroForOne, uint256 size) public {
        (uint160 currentPrice, , , , , , ) = raiWETHPool.slot0();
        if(zeroForOne) {
            uint160 sqrtLimitPrice = currentPrice - uint160(size);
            raiWETHPool.swap(address(this), true, int56(size), sqrtLimitPrice, bytes(""));
        } else {
            uint160 sqrtLimitPrice = currentPrice + uint160(size);
            raiWETHPool.swap(address(this), false, int56(size), sqrtLimitPrice, bytes(""));
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

    // Copied from test file

    UniswapV3ConverterMedianizer uniswapRAIWETHMedianizer;

    MockTreasury treasury;

    ETHMedianizer_3 converterETHPriceFeed;

    IncreasingRewardRelayer usdcRelayer;
    IncreasingRewardRelayer ethRelayer;

    UniswapV3Factory uniswapFactory;

    UniswapV3Pool raiWETHPool;

    DSToken rai;
    _WETH9_1 weth;

    DSToken token0;
    DSToken token1;

    uint256 startTime               = 1577836800;
    uint256 initTokenAmount         = 100000000 ether;
    uint256 initETHUSDPrice         = 2700 * 10 ** 18;
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

    function setUp() internal {
        me = address(this);

        // hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        // hevm.warp(startTime);

        // Deploy Tokens
        weth = new _WETH9_1("WETH", initTokenAmount);
        rai = new DSToken("RAI", "RAI");
        rai.mint(initTokenAmount);

        (token0, token1) = address(rai) < address(weth) ? (DSToken(rai), DSToken(weth)) : (DSToken(weth), DSToken(rai));

        // Create treasury
        treasury = new MockTreasury(address(rai));
        rai.transfer(address(treasury), 5000 * baseCallerReward);

        // Setup converter medians
        converterETHPriceFeed = new ETHMedianizer_3();
        converterETHPriceFeed.modifyParameters("medianPrice", initETHUSDPrice);

        // Setup Uniswap
        uniswapFactory = new UniswapV3Factory();

        address pool = uniswapFactory.createPool(address(token0), address(token1), 3000);
        raiWETHPool = UniswapV3Pool(pool);
        uint160 initialPrice;
        if(raiWETHPool.token1() == address(rai)){
            initialPrice = 2376844875427930127806318510080; //close to U$3.00
            // initialPoolPrice = initETHUSDPrice *  helper_get_price_from_ratio(initialPrice, address(weth), address(rai)) / 1 ether;
        } else {
            initialPrice = 2640938750475477919784798344;
            // initialPoolPrice = initETHUSDPrice / 1 ether * helper_get_price_from_ratio(initialPrice,address(rai), address(weth));
        }
        raiWETHPool.initialize(initialPrice);
        (uint160 price,int24 tick,,,,,) = raiWETHPool.slot0();


        //Increase the number of oracle observations
        raiWETHPool.increaseObservationCardinalityNext(3000);

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

        // // set relayer inside oracle contract
        uniswapRAIWETHMedianizer.modifyParameters("relayer", address(ethRelayer));

        // Set treasury allowance
        treasury.setTotalAllowance(address(ethRelayer), uint(-1));
        treasury.setPerBlockAllowance(address(ethRelayer), uint(-1));

        ethRelayer.modifyParameters("maxRewardIncreaseDelay", maxRewardDelay);

        // Set converter addresses
        uniswapRAIWETHMedianizer.modifyParameters("converterFeed", address(converterETHPriceFeed));

        // Set target and denomination tokens
        uniswapRAIWETHMedianizer.modifyParameters("targetToken", address(rai));
    }

     function helper_addLiquidity() public {
        uint256 token0Am = 100 ether;
        uint256 token1Am = 100 ether;
        int24 low = -120000;
        int24 upp = 120000;
        (uint160 sqrtRatioX96, , , , , , ) = raiWETHPool.slot0();
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(sqrtRatioX96, TickMath.getSqrtRatioAtTick(low), TickMath.getSqrtRatioAtTick(upp), token0Am, token1Am);
        raiWETHPool.mint(address(this), low, upp, liq, bytes(""));

        low = -60000;
        upp = 60000;
        ( sqrtRatioX96, , , , , , ) = raiWETHPool.slot0();
         liq = LiquidityAmounts.getLiquidityForAmounts(sqrtRatioX96, TickMath.getSqrtRatioAtTick(low), TickMath.getSqrtRatioAtTick(upp), token0Am, token1Am);
        raiWETHPool.mint(address(this), low, upp, liq, bytes(""));
    }

}