pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-weth/src/weth9.sol";
import "ds-token/token.sol";
import "geb-treasury-reimbursement/relayer/IncreasingRewardRelayer.sol";

import "./orcl/MockMedianizer.sol";
import "./geb/MockTreasury.sol";

import "../univ2/UniswapV2Factory.sol";
import "../univ2/UniswapV2Pair.sol";
import "../univ2/UniswapV2Router02.sol";

import { UniswapConsecutiveSlotsPriceFeedMedianizer } from  "../UniswapConsecutiveSlotsPriceFeedMedianizer.sol";

abstract contract Hevm {
    function warp(uint256) virtual public;
}

// --- Token Contracts ---
contract USDC is DSToken {
    constructor(string memory symbol) public DSToken(symbol, symbol) {
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

contract UniswapConsecutiveSlotsPriceFeedMedianizerTest is DSTest {
    Hevm hevm;

    MockTreasury treasury;

    ETHMedianizer converterETHPriceFeed;
    USDCMedianizer converterUSDCPriceFeed;

    IncreasingRewardRelayer usdcRelayer;
    IncreasingRewardRelayer ethRelayer;

    UniswapConsecutiveSlotsPriceFeedMedianizer uniswapRAIWETHMedianizer;
    UniswapConsecutiveSlotsPriceFeedMedianizer uniswapRAIUSDCMedianizer;

    UniswapV2Factory uniswapFactory;
    UniswapV2Router02 uniswapRouter;

    UniswapV2Pair raiWETHPair;
    UniswapV2Pair raiUSDCPair;

    DSToken rai;
    USDC usdc;
    WETH9_ weth;

    uint256 startTime = 1577836800;

    uint256 initTokenAmount  = 100000000 ether;
    uint256 initETHUSDPrice  = 250 * 10 ** 18;
    uint256 initUSDCUSDPrice = 10 ** 18;

    uint256 initETHRAIPairLiquidity = 5 ether;               // 1250 USD
    uint256 initRAIETHPairLiquidity = 294.672324375E18;      // 1 RAI = 4.242 USD

    uint256 initUSDCRAIPairLiquidity = 4.242E6;
    uint256 initRAIUSDCPairLiquidity = 1 ether;

    uint8   uniswapMedianizerGranularity            = 24;           // 1 hour
    uint256 maxWindowSize                           = 72 hours;
    uint256 converterScalingFactor                  = 1 ether;
    uint256 uniswapMedianizerWindowSize             = 86400;        // 24 hours
    uint256 uniswapETHRAIMedianizerDefaultAmountIn  = 1 ether;
    uint256 uniswapUSDCRAIMedianizerDefaultAmountIn = 10 ** 12 * 1 ether;

    uint256 simulatedConverterPriceChange = 2; // 2%

    uint256 ethRAISimulationExtraRAI = 100 ether;
    uint256 ethRAISimulationExtraETH = 0.5 ether;

    uint256 usdcRAISimulationExtraRAI = 10 ether;
    uint256 usdcRAISimulationExtraUSDC = 25E6;

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

        // Setup Uniswap
        uniswapFactory = new UniswapV2Factory(address(this));
        createUniswapPairs();
        uniswapRouter = new UniswapV2Router02(address(uniswapFactory), address(weth));

        // Setup converter medians
        converterETHPriceFeed = new ETHMedianizer();
        converterETHPriceFeed.modifyParameters("medianPrice", initETHUSDPrice);

        converterUSDCPriceFeed = new USDCMedianizer();
        converterUSDCPriceFeed.modifyParameters("medianPrice", initUSDCUSDPrice);

        // Create treasury
        treasury = new MockTreasury(address(rai));
        rai.transfer(address(treasury), 5000 * baseCallerReward);

        // Setup Uniswap medians
        uniswapRAIWETHMedianizer = new UniswapConsecutiveSlotsPriceFeedMedianizer(
            address(0x1),
            address(uniswapFactory),
            uniswapETHRAIMedianizerDefaultAmountIn,
            uniswapMedianizerWindowSize,
            converterScalingFactor,
            maxWindowSize,
            uniswapMedianizerGranularity
        );
        uniswapRAIUSDCMedianizer = new UniswapConsecutiveSlotsPriceFeedMedianizer(
            address(0x1),
            address(uniswapFactory),
            uniswapUSDCRAIMedianizerDefaultAmountIn,
            uniswapMedianizerWindowSize,
            converterScalingFactor,
            maxWindowSize,
            uniswapMedianizerGranularity
        );

        // Setup the reward relayers
        ethRelayer = new IncreasingRewardRelayer(
            address(uniswapRAIWETHMedianizer),
            address(treasury),
            baseCallerReward,
            maxCallerReward,
            perSecondCallerRewardIncrease,
            uniswapRAIWETHMedianizer.periodSize()
        );
        usdcRelayer = new IncreasingRewardRelayer(
            address(uniswapRAIUSDCMedianizer),
            address(treasury),
            baseCallerReward,
            maxCallerReward,
            perSecondCallerRewardIncrease,
            uniswapRAIUSDCMedianizer.periodSize()
        );

        // Add reward relayers inside the oracle contracts
        uniswapRAIWETHMedianizer.modifyParameters("relayer", address(ethRelayer));
        uniswapRAIUSDCMedianizer.modifyParameters("relayer", address(usdcRelayer));

        // Set max reward increase delay
        ethRelayer.modifyParameters("maxRewardIncreaseDelay", maxRewardDelay);
        usdcRelayer.modifyParameters("maxRewardIncreaseDelay", maxRewardDelay);

        // Set treasury allowance
        treasury.setTotalAllowance(address(ethRelayer), uint(-1));
        treasury.setPerBlockAllowance(address(ethRelayer), uint(-1));

        treasury.setTotalAllowance(address(usdcRelayer), uint(-1));
        treasury.setPerBlockAllowance(address(usdcRelayer), uint(-1));

        // Set converter addresses
        uniswapRAIWETHMedianizer.modifyParameters("converterFeed", address(converterETHPriceFeed));
        uniswapRAIUSDCMedianizer.modifyParameters("converterFeed", address(converterUSDCPriceFeed));

        // Set target and denomination tokens
        uniswapRAIWETHMedianizer.modifyParameters("targetToken", address(rai));
        uniswapRAIWETHMedianizer.modifyParameters("denominationToken", address(weth));

        uniswapRAIUSDCMedianizer.modifyParameters("targetToken", address(rai));
        uniswapRAIUSDCMedianizer.modifyParameters("denominationToken", address(usdc));

        assertTrue(uniswapRAIWETHMedianizer.uniswapPair() != address(0));
        assertTrue(uniswapRAIUSDCMedianizer.uniswapPair() != address(0));

        // Add pair liquidity
        addPairLiquidityRouter(address(rai), address(weth), initRAIETHPairLiquidity, initETHRAIPairLiquidity);
        addPairLiquidityRouter(address(rai), address(usdc), initRAIUSDCPairLiquidity, initUSDCRAIPairLiquidity);
    }

    // --- Math ---
    function multiply(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x, 'mul-overflow');
    }

    // --- Uniswap utils ---
    function createUniswapPairs() internal {
        // Create Tokens
        weth = new WETH9_();

        rai = new DSToken("RAI", "RAI");
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
    function addPairLiquidityRouter(address token1, address token2, uint256 amount1, uint256 amount2) internal {
        DSToken(token1).approve(address(uniswapRouter), uint(-1));
        DSToken(token2).approve(address(uniswapRouter), uint(-1));
        uniswapRouter.addLiquidity(token1, token2, amount1, amount2, amount1, amount2, address(this), now);
        UniswapV2Pair updatedPair = UniswapV2Pair(uniswapFactory.getPair(token1, token2));
        updatedPair.sync();
    }
    function addPairLiquidityTransfer(UniswapV2Pair pair, address token1, address token2, uint256 amount1, uint256 amount2) internal {
        DSToken(token1).transfer(address(pair), amount1);
        DSToken(token2).transfer(address(pair), amount2);
        pair.sync();
    }

    // --- Simulation Utils ---
    function simulateETHRAISamePrices() internal {
        for (uint i = 0; i < uint(uniswapMedianizerGranularity) + 2; i++) {
          hevm.warp(now + uniswapRAIWETHMedianizer.periodSize());
          uniswapRAIWETHMedianizer.updateResult(address(alice));
          raiWETHPair.sync();
        }
    }
    function simulateUSDCRAISamePrices() internal {
        for (uint i = 0; i < uint(uniswapMedianizerGranularity) + 2; i++) {
          hevm.warp(now + uniswapRAIUSDCMedianizer.periodSize());
          uniswapRAIUSDCMedianizer.updateResult(address(alice));
          raiUSDCPair.sync();
        }
    }
    function simulateBothOraclesSamePrices() internal {
        for (uint i = 0; i < uint(uniswapMedianizerGranularity) * 2; i++) {
          hevm.warp(now + uniswapRAIUSDCMedianizer.periodSize());
          uniswapRAIWETHMedianizer.updateResult(address(alice));
          uniswapRAIUSDCMedianizer.updateResult(address(alice));
          raiWETHPair.sync();
          raiUSDCPair.sync();
        }
    }
    function simulateBothOraclesSamePricesErraticDelays() internal {
        uint chosenDelay;
        for (uint i = 0; i < uint(uniswapMedianizerGranularity) * 2; i++) {
          chosenDelay = (i % 2 == 0) ? erraticDelay : uniswapRAIUSDCMedianizer.periodSize();
          hevm.warp(now + chosenDelay);
          uniswapRAIWETHMedianizer.updateResult(address(alice));
          uniswapRAIUSDCMedianizer.updateResult(address(alice));
          raiWETHPair.sync();
          raiUSDCPair.sync();
        }
    }
    function simulateWETHRAIPrices() internal {
        uint256 i;
        hevm.warp(now + 10);

        for (i = 0; i < uint(uniswapMedianizerGranularity) / 2 + 1; i++) {
          addPairLiquidityTransfer(raiWETHPair, address(rai), address(weth), ethRAISimulationExtraRAI, 0);
          uniswapRAIWETHMedianizer.updateResult(address(alice));
          hevm.warp(now + uniswapRAIWETHMedianizer.periodSize());
        }
        for (i = 0; i < uint(uniswapMedianizerGranularity) / 2 + 1; i++) {
          addPairLiquidityTransfer(raiWETHPair, address(rai), address(weth), 0, ethRAISimulationExtraETH);
          uniswapRAIWETHMedianizer.updateResult(address(alice));
          hevm.warp(now + uniswapRAIWETHMedianizer.periodSize());
        }
    }
    function simulateUSDCRAIPrices() internal {
        uint256 i;
        hevm.warp(now + 10);

        for (i = 0; i < uint(uniswapMedianizerGranularity) / 2 + 1; i++) {
          addPairLiquidityTransfer(raiUSDCPair, address(rai), address(usdc), usdcRAISimulationExtraRAI, 0);
          uniswapRAIUSDCMedianizer.updateResult(address(alice));
          hevm.warp(now + uniswapRAIUSDCMedianizer.periodSize());
        }
        for (i = 0; i < uint(uniswapMedianizerGranularity) / 2 + 1; i++) {
          addPairLiquidityTransfer(raiUSDCPair, address(rai), address(usdc), 0, usdcRAISimulationExtraUSDC);
          uniswapRAIUSDCMedianizer.updateResult(address(alice));
          hevm.warp(now + uniswapRAIUSDCMedianizer.periodSize());
        }
    }
    function simulateBothOraclePrices() public {
        uint256 i;
        hevm.warp(now + 10);

        for (i = 0; i < uint(uniswapMedianizerGranularity) / 2 + 1; i++) {
          addPairLiquidityTransfer(raiWETHPair, address(rai), address(weth), ethRAISimulationExtraRAI, 0);
          uniswapRAIWETHMedianizer.updateResult(address(alice));

          addPairLiquidityTransfer(raiUSDCPair, address(rai), address(usdc), usdcRAISimulationExtraRAI, 0);
          uniswapRAIUSDCMedianizer.updateResult(address(alice));

          hevm.warp(now + uniswapRAIWETHMedianizer.periodSize());
        }
        for (i = 0; i < uint(uniswapMedianizerGranularity) / 2 + 1; i++) {
          addPairLiquidityTransfer(raiWETHPair, address(rai), address(weth), 0, ethRAISimulationExtraETH);
          uniswapRAIWETHMedianizer.updateResult(address(alice));

          addPairLiquidityTransfer(raiUSDCPair, address(rai), address(usdc), 0, usdcRAISimulationExtraUSDC);
          uniswapRAIUSDCMedianizer.updateResult(address(alice));

          hevm.warp(now + uniswapRAIWETHMedianizer.periodSize());
        }
    }
    function simulateBothOraclesPricesErraticDelays() internal {
        uint chosenDelay;
        uint256 i;

        for (i = 0; i < uint(uniswapMedianizerGranularity) / 2 + 1; i++) {
          addPairLiquidityTransfer(raiWETHPair, address(rai), address(weth), ethRAISimulationExtraRAI, 0);
          uniswapRAIWETHMedianizer.updateResult(address(alice));

          addPairLiquidityTransfer(raiUSDCPair, address(rai), address(usdc), usdcRAISimulationExtraRAI, 0);
          uniswapRAIUSDCMedianizer.updateResult(address(alice));

          chosenDelay = (i % 2 == 0) ? erraticDelay : uniswapRAIUSDCMedianizer.periodSize();
          hevm.warp(now + chosenDelay);
        }
        for (i = 0; i < uint(uniswapMedianizerGranularity) / 2 + 1; i++) {
          addPairLiquidityTransfer(raiWETHPair, address(rai), address(weth), 0, ethRAISimulationExtraETH);
          uniswapRAIWETHMedianizer.updateResult(address(alice));

          addPairLiquidityTransfer(raiUSDCPair, address(rai), address(usdc), 0, usdcRAISimulationExtraUSDC);
          uniswapRAIUSDCMedianizer.updateResult(address(alice));

          chosenDelay = (i % 2 == 0) ? erraticDelay : uniswapRAIUSDCMedianizer.periodSize();
          hevm.warp(now + chosenDelay);
        }
    }

    function test_correct_setup() public {
        assertEq(uniswapRAIWETHMedianizer.authorizedAccounts(me), 1);
        assertEq(uniswapRAIUSDCMedianizer.authorizedAccounts(me), 1);

        assertTrue(address(uniswapRAIWETHMedianizer.converterFeed()) == address(converterETHPriceFeed));
        assertTrue(address(uniswapRAIUSDCMedianizer.converterFeed()) == address(converterUSDCPriceFeed));

        assertTrue(address(uniswapRAIWETHMedianizer.uniswapFactory()) == address(uniswapFactory));
        assertTrue(address(uniswapRAIUSDCMedianizer.uniswapFactory()) == address(uniswapFactory));

        assertEq(uniswapRAIWETHMedianizer.defaultAmountIn(), uniswapETHRAIMedianizerDefaultAmountIn);
        assertEq(uniswapRAIUSDCMedianizer.defaultAmountIn(), uniswapUSDCRAIMedianizerDefaultAmountIn);

        assertEq(uniswapRAIWETHMedianizer.windowSize(), uniswapMedianizerWindowSize);
        assertEq(uniswapRAIUSDCMedianizer.windowSize(), uniswapMedianizerWindowSize);

        assertEq(uniswapRAIWETHMedianizer.maxWindowSize(), maxWindowSize);
        assertEq(uniswapRAIUSDCMedianizer.maxWindowSize(), maxWindowSize);

        assertEq(uniswapRAIWETHMedianizer.updates(), 0);
        assertEq(uniswapRAIUSDCMedianizer.updates(), 0);

        assertEq(uniswapRAIWETHMedianizer.periodSize(), 3600);
        assertEq(uniswapRAIUSDCMedianizer.periodSize(), 3600);

        assertEq(ethRelayer.maxRewardIncreaseDelay(), maxRewardDelay);
        assertEq(usdcRelayer.maxRewardIncreaseDelay(), maxRewardDelay);

        assertEq(uniswapRAIWETHMedianizer.converterFeedScalingFactor(), converterScalingFactor);
        assertEq(uniswapRAIUSDCMedianizer.converterFeedScalingFactor(), converterScalingFactor);

        assertEq(uint256(uniswapRAIWETHMedianizer.granularity()), uniswapMedianizerGranularity);
        assertEq(uint256(uniswapRAIUSDCMedianizer.granularity()), uniswapMedianizerGranularity);

        assertTrue(uniswapRAIWETHMedianizer.targetToken() == address(rai));
        assertTrue(uniswapRAIUSDCMedianizer.targetToken() == address(rai));

        assertTrue(uniswapRAIWETHMedianizer.denominationToken() == address(weth));
        assertTrue(uniswapRAIUSDCMedianizer.denominationToken() == address(usdc));

        assertTrue(uniswapRAIWETHMedianizer.uniswapPair() == address(raiWETHPair));
        assertTrue(uniswapRAIUSDCMedianizer.uniswapPair() == address(raiUSDCPair));

        assertTrue(address(ethRelayer.treasury()) == address(treasury));
        assertTrue(address(usdcRelayer.treasury()) == address(treasury));

        assertEq(ethRelayer.baseUpdateCallerReward(), baseCallerReward);
        assertEq(usdcRelayer.baseUpdateCallerReward(), baseCallerReward);

        assertEq(ethRelayer.maxUpdateCallerReward(), maxCallerReward);
        assertEq(usdcRelayer.maxUpdateCallerReward(), maxCallerReward);

        assertEq(ethRelayer.perSecondCallerRewardIncrease(), perSecondCallerRewardIncrease);
        assertEq(usdcRelayer.perSecondCallerRewardIncrease(), perSecondCallerRewardIncrease);

        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertEq(medianPrice, 0);
        assertTrue(!isValid);

        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        assertEq(medianPrice, 0);
        assertTrue(!isValid);

        (uint256 uniObservationsListLength, uint256 converterObservationsListLength) = uniswapRAIWETHMedianizer.getObservationListLength();
        assertEq(uniObservationsListLength, converterObservationsListLength);
        assertTrue(uniObservationsListLength == 0);

        (uniObservationsListLength, converterObservationsListLength) = uniswapRAIUSDCMedianizer.getObservationListLength();
        assertEq(uniObservationsListLength, converterObservationsListLength);
        assertTrue(uniObservationsListLength == 0);

        assertEq(raiWETHPair.balanceOf(address(this)), 38384392946547948802);
        assertEq(raiUSDCPair.balanceOf(address(this)), 2059611612872);

        assertEq(raiWETHPair.totalSupply(), 38384392946547949802);
        assertEq(raiUSDCPair.totalSupply(), 2059611613872);
    }
    function testFail_max_window_size_smaller_than_normal_window() public {
        uniswapRAIWETHMedianizer = new UniswapConsecutiveSlotsPriceFeedMedianizer(
            address(converterETHPriceFeed),
            address(uniswapFactory),
            uniswapETHRAIMedianizerDefaultAmountIn,
            uniswapMedianizerWindowSize,
            converterScalingFactor,
            uniswapMedianizerWindowSize - 1,
            1
        );
    }
    function testFail_small_granularity() public {
        uniswapRAIWETHMedianizer = new UniswapConsecutiveSlotsPriceFeedMedianizer(
            address(converterETHPriceFeed),
            address(uniswapFactory),
            uniswapETHRAIMedianizerDefaultAmountIn,
            uniswapMedianizerWindowSize,
            converterScalingFactor,
            maxWindowSize,
            1
        );
    }
    function testFail_window_not_evenly_divisible() public {
        uniswapRAIWETHMedianizer = new UniswapConsecutiveSlotsPriceFeedMedianizer(
            address(converterETHPriceFeed),
            address(uniswapFactory),
            uniswapETHRAIMedianizerDefaultAmountIn,
            uniswapMedianizerWindowSize,
            converterScalingFactor,
            maxWindowSize,
            23
        );
    }
    function test_change_converter_feed() public {
        uniswapRAIWETHMedianizer.modifyParameters("converterFeed", address(0x123));
        uniswapRAIUSDCMedianizer.modifyParameters("converterFeed", address(0x123));

        assertTrue(address(uniswapRAIWETHMedianizer.converterFeed()) == address(0x123));
        assertTrue(address(uniswapRAIUSDCMedianizer.converterFeed()) == address(0x123));
    }
    function test_update_result_converter_throws() public {
        converterETHPriceFeed.modifyParameters("revertUpdate", 1);
        converterUSDCPriceFeed.modifyParameters("revertUpdate", 1);

        hevm.warp(now + 3599);
        assertEq(rai.balanceOf(alice), 0);

        // RAI/WETH
        uniswapRAIWETHMedianizer.updateResult(alice);
        (uint uniTimestamp, uint price0Cumulative, uint price1Cumulative) =
          uniswapRAIWETHMedianizer.uniswapObservations(0);
        (uint converterTimestamp, uint converterPrice) = uniswapRAIWETHMedianizer.converterFeedObservations(0);
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        uint256 converterPriceCumulative = uniswapRAIWETHMedianizer.converterPriceCumulative();

        assertEq(uint256(uniswapRAIWETHMedianizer.earliestObservationIndex()), 0);
        assertEq(converterPriceCumulative, initETHUSDPrice * 3599);
        assertEq(medianPrice, 0);
        assertTrue(!isValid);
        assertEq(converterTimestamp, now);
        assertEq(converterPrice, initETHUSDPrice * 3599);
        assertEq(uniTimestamp, now);
        assertEq(rai.balanceOf(alice), baseCallerReward);
        assertEq(uniswapRAIWETHMedianizer.updates(), 1);
        if(address(rai) == raiWETHPair.token0()){
            assertEq(price1Cumulative, 1101312847350787220573278491526876720617);
            assertEq(price0Cumulative, 317082312251449702080310206411507700);
        } else {
            assertEq(price0Cumulative, 1101312847350787220573278491526876720617);
            assertEq(price1Cumulative, 317082312251449702080310206411507700);
        }

        // RAI/USDC
        uniswapRAIUSDCMedianizer.updateResult(alice);
        (uniTimestamp, price0Cumulative, price1Cumulative) =
          uniswapRAIUSDCMedianizer.uniswapObservations(0);
        (converterTimestamp, converterPrice) = uniswapRAIUSDCMedianizer.converterFeedObservations(0);
        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        converterPriceCumulative = uniswapRAIUSDCMedianizer.converterPriceCumulative();

        assertEq(uint256(uniswapRAIUSDCMedianizer.earliestObservationIndex()), 0);
        assertEq(converterPriceCumulative, initUSDCUSDPrice * 3599);
        assertEq(medianPrice, 0);
        assertTrue(!isValid);
        assertEq(converterTimestamp, now);
        assertEq(converterPrice, initUSDCUSDPrice * 3599);
        assertEq(uniTimestamp, now);
        assertEq(rai.balanceOf(alice), baseCallerReward * 2);
        assertEq(uniswapRAIUSDCMedianizer.updates(), 1);
        if(address(rai) == raiUSDCPair.token0()){
            assertEq(price1Cumulative, 4405251389407554133682521520241189416313059876349);
            assertEq(price0Cumulative, 79270578062783154942013374);
        } else {
            assertEq(price0Cumulative, 4405251389407554133682521520241189416313059876349);
            assertEq(price1Cumulative, 79270578062783154942013374);
        }
    }
    function testFail_read_raieth_before_passing_granularity() public {
        hevm.warp(now + 3599);
        assertEq(rai.balanceOf(alice), 0);

        // RAI/WETH
        uniswapRAIWETHMedianizer.updateResult(alice);

        uint medianPrice = uniswapRAIWETHMedianizer.read();
    }
    function testFail_read_raiusdc_before_passing_granularity() public {
        hevm.warp(now + 3599);
        assertEq(rai.balanceOf(alice), 0);

        // RAI/USDC
        uniswapRAIUSDCMedianizer.updateResult(alice);

        uint medianPrice = uniswapRAIUSDCMedianizer.read();
    }
    function test_get_result_before_passing_granularity() public {
        hevm.warp(now + 3599);
        assertEq(rai.balanceOf(alice), 0);

        // RAI/WETH
        uniswapRAIWETHMedianizer.updateResult(alice);
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(!isValid);

        // RAI/USDC
        uniswapRAIUSDCMedianizer.updateResult(alice);
        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        assertTrue(!isValid);
    }
    function test_update_treasury_throws() public {
        MockRevertableTreasury revertTreasury = new MockRevertableTreasury();

        // Set treasury allowance
        revertTreasury.setTotalAllowance(address(ethRelayer), uint(-1));
        revertTreasury.setPerBlockAllowance(address(ethRelayer), uint(-1));

        revertTreasury.setTotalAllowance(address(usdcRelayer), uint(-1));
        revertTreasury.setPerBlockAllowance(address(usdcRelayer), uint(-1));

        ethRelayer.modifyParameters("treasury", address(revertTreasury));
        usdcRelayer.modifyParameters("treasury", address(revertTreasury));

        hevm.warp(now + 3599);
        assertEq(rai.balanceOf(alice), 0);

        // RAI/WETH
        uniswapRAIWETHMedianizer.updateResult(alice);
        // RAI/USDC
        uniswapRAIUSDCMedianizer.updateResult(alice);

        assertEq(rai.balanceOf(alice), 0);
    }
    function test_update_treasury_reward_treasury() public {
        hevm.warp(now + 3599);
        assertEq(rai.balanceOf(alice), 0);

        uint treasuryBalance = rai.balanceOf(address(treasury));

        // RAI/WETH
        uniswapRAIWETHMedianizer.updateResult(address(treasury));
        // RAI/USDC
        uniswapRAIUSDCMedianizer.updateResult(address(treasury));

        assertEq(rai.balanceOf(address(treasury)), treasuryBalance);
    }
    function testFail_update_ETHRAI_again_immediately() public {
        converterETHPriceFeed.modifyParameters("revertUpdate", 1);

        hevm.warp(now + 1);
        uniswapRAIWETHMedianizer.updateResult(address(this));

        hevm.warp(now + 1);
        uniswapRAIWETHMedianizer.updateResult(address(this));
    }
    function testFail_update_USDCRAI_again_immediately() public {
        converterUSDCPriceFeed.modifyParameters("revertUpdate", 1);

        hevm.warp(now + 1);
        uniswapRAIUSDCMedianizer.updateResult(address(this));

        hevm.warp(now + 1);
        uniswapRAIUSDCMedianizer.updateResult(address(this));
    }
    function testFail_update_result_ETH_converter_invalid_value() public {
        converterETHPriceFeed.modifyParameters("medianPrice", 0);
        hevm.warp(now + 3599);
        uniswapRAIWETHMedianizer.updateResult(address(this));
    }
    function testFail_update_result_USDC_converter_invalid_value() public {
        converterUSDCPriceFeed.modifyParameters("medianPrice", 0);
        hevm.warp(now + 3599);
        uniswapRAIUSDCMedianizer.updateResult(address(this));
    }
    function test_update_result() public {
        hevm.warp(now + 3599);

        // RAI/WETH
        uniswapRAIWETHMedianizer.updateResult(address(this));
        (uint uniTimestamp, uint price0Cumulative, uint price1Cumulative) =
          uniswapRAIWETHMedianizer.uniswapObservations(0);
        (uint converterTimestamp, uint converterPrice) = uniswapRAIWETHMedianizer.converterFeedObservations(0);
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        uint256 converterPriceCumulative = uniswapRAIWETHMedianizer.converterPriceCumulative();

        assertEq(uint256(uniswapRAIWETHMedianizer.earliestObservationIndex()), 0);
        assertEq(converterPriceCumulative, initETHUSDPrice * 3599);
        assertEq(medianPrice, 0);
        assertTrue(!isValid);
        assertEq(converterTimestamp, now);
        assertEq(converterPrice, initETHUSDPrice * 3599);
        assertEq(uniTimestamp, now);
        if(address(rai) == raiWETHPair.token0()){
            assertEq(price1Cumulative, 1101312847350787220573278491526876720617);
            assertEq(price0Cumulative, 317082312251449702080310206411507700);
        } else {
            assertEq(price0Cumulative, 1101312847350787220573278491526876720617);
            assertEq(price1Cumulative, 317082312251449702080310206411507700);
        }

        // RAI/USDC
        uniswapRAIUSDCMedianizer.updateResult(address(this));
        (uniTimestamp, price0Cumulative, price1Cumulative) =
          uniswapRAIUSDCMedianizer.uniswapObservations(0);
        (converterTimestamp, converterPrice) = uniswapRAIUSDCMedianizer.converterFeedObservations(0);
        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        converterPriceCumulative = uniswapRAIUSDCMedianizer.converterPriceCumulative();

        assertEq(uint256(uniswapRAIUSDCMedianizer.earliestObservationIndex()), 0);
        assertEq(converterPriceCumulative, initUSDCUSDPrice * 3599);
        assertEq(medianPrice, 0);
        assertTrue(!isValid);
        assertEq(converterTimestamp, now);
        assertEq(converterPrice, initUSDCUSDPrice * 3599);
        assertEq(uniTimestamp, now);
        if(address(rai) == raiUSDCPair.token0()){
            assertEq(price1Cumulative, 4405251389407554133682521520241189416313059876349);
            assertEq(price0Cumulative, 79270578062783154942013374);
        } else {
            assertEq(price0Cumulative, 4405251389407554133682521520241189416313059876349);
            assertEq(price1Cumulative, 79270578062783154942013374);
        }
    }
    function test_wait_more_than_maxUpdateCallerReward_since_last_update() public {
        hevm.warp(now + uniswapRAIWETHMedianizer.periodSize());
        uniswapRAIWETHMedianizer.updateResult(address(0x1234));
        assertEq(rai.balanceOf(address(0x1234)), baseCallerReward);

        hevm.warp(now + uniswapRAIWETHMedianizer.periodSize());
        uniswapRAIWETHMedianizer.updateResult(address(0x1234));
        assertEq(rai.balanceOf(address(0x1234)), baseCallerReward * 2);

        hevm.warp(now + uniswapRAIWETHMedianizer.periodSize() + maxRewardDelay + 1);
        uniswapRAIWETHMedianizer.updateResult(address(0x1234));
        assertEq(rai.balanceOf(address(0x1234)), baseCallerReward * 2 + maxCallerReward);

        hevm.warp(now + uniswapRAIWETHMedianizer.periodSize() + maxRewardDelay + 1);
        uniswapRAIWETHMedianizer.updateResult(address(0x1234));
        assertEq(rai.balanceOf(address(0x1234)), baseCallerReward * 2 + maxCallerReward * 2);
    }
    function test_get_result_when_time_elapsed_above_max_window() public {
        uniswapRAIUSDCMedianizer.modifyParameters("maxWindowSize", 25 hours);
        uniswapRAIWETHMedianizer.modifyParameters("maxWindowSize", 25 hours);

        simulateBothOraclesSamePricesErraticDelays();

        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(!isValid);
        assertEq(medianPrice, 4242000000004242000);

        // RAI/USDC
        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        assertTrue(!isValid);
        assertEq(medianPrice, 4241999999999999999);
    }
    function test_simulate_same_prices() public {
        simulateBothOraclesSamePrices();

        assertEq(uniswapRAIWETHMedianizer.converterPriceCumulative(), initETHUSDPrice * uniswapRAIWETHMedianizer.periodSize() * uniswapMedianizerGranularity);
        assertEq(
          uniswapRAIWETHMedianizer.converterComputeAmountOut(
            uniswapRAIUSDCMedianizer.periodSize() * uniswapMedianizerGranularity, 10**18
          ), initETHUSDPrice
        );
        assertEq(uniswapRAIUSDCMedianizer.converterPriceCumulative(), initUSDCUSDPrice * uniswapRAIUSDCMedianizer.periodSize() * uniswapMedianizerGranularity);
        assertEq(
          uniswapRAIUSDCMedianizer.converterComputeAmountOut(
            uniswapRAIUSDCMedianizer.periodSize() * uniswapMedianizerGranularity, 10**18
          ), initUSDCUSDPrice
        );

        // Check interval
        assertEq(uniswapRAIWETHMedianizer.earliestObservationIndex(), 24);
        assertEq(uniswapRAIUSDCMedianizer.earliestObservationIndex(), 24);

        (uint listLength, ) = uniswapRAIWETHMedianizer.getObservationListLength();
        assertEq(listLength, 48);
        (listLength, ) = uniswapRAIUSDCMedianizer.getObservationListLength();
        assertEq(listLength, 48);

        // Check time elapsed
        assertEq(uniswapRAIWETHMedianizer.timeElapsedSinceFirstObservation(), 82800);
        assertEq(uniswapRAIUSDCMedianizer.timeElapsedSinceFirstObservation(), 82800);

        // Check cumulative converter price
        assertEq(uniswapRAIWETHMedianizer.converterPriceCumulative() / uniswapMedianizerGranularity / (uniswapMedianizerWindowSize / uint(uniswapMedianizerGranularity)), initETHUSDPrice);
        assertEq(uniswapRAIUSDCMedianizer.converterPriceCumulative() / uniswapMedianizerGranularity / (uniswapMedianizerWindowSize / uint(uniswapMedianizerGranularity)), initUSDCUSDPrice);

        // RAI/WETH
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 4242000000004242000);

        // RAI/USDC
        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 4241999999999999999);

        uint observedPrice;
        for (uint i = 0; i < uniswapMedianizerGranularity; i++) {
            (, observedPrice) = uniswapRAIWETHMedianizer.converterFeedObservations(i);
            assertEq(observedPrice, initETHUSDPrice * uniswapRAIWETHMedianizer.periodSize());
        }
        for (uint i = 0; i < uniswapMedianizerGranularity; i++) {
            (, observedPrice) = uniswapRAIUSDCMedianizer.converterFeedObservations(i);
            assertEq(observedPrice, initUSDCUSDPrice * uniswapRAIUSDCMedianizer.periodSize());
        }
    }
    function test_simulate_same_prices_erratic_delays() public {
        simulateBothOraclesSamePricesErraticDelays();

        // RAI/WETH
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 4242000000004242000);

        // RAI/USDC
        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 4241999999999999999);

        uint observedPrice;
        uint chosenDelay;
        for (uint i = 0; i < uniswapMedianizerGranularity; i++) {
            chosenDelay = (i % 2 == 0) ? erraticDelay : uniswapRAIWETHMedianizer.periodSize();
            (, observedPrice) = uniswapRAIWETHMedianizer.converterFeedObservations(i);
            assertEq(observedPrice, initETHUSDPrice * chosenDelay);
        }
        for (uint i = 0; i < uniswapMedianizerGranularity; i++) {
            chosenDelay = (i % 2 == 0) ? erraticDelay : uniswapRAIUSDCMedianizer.periodSize();
            (, observedPrice) = uniswapRAIUSDCMedianizer.converterFeedObservations(i);
            assertEq(observedPrice, initUSDCUSDPrice * chosenDelay);
        }
    }
    function test_simulate_same_prices_erratic_delays_first_update_huge_delay() public {
        hevm.warp(now + 7 days);

        simulateBothOraclesSamePricesErraticDelays();

        // RAI/WETH
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 4242000000004242000);

        // RAI/USDC
        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 4241999999999999999);

        assertEq(uniswapRAIUSDCMedianizer.timeElapsedSinceFirstObservation(), 45 hours);
        assertEq(uniswapRAIWETHMedianizer.timeElapsedSinceFirstObservation(), 45 hours);
    }
    function test_simulate_same_prices_erratic_then_normal_delays() public {
        simulateBothOraclesSamePricesErraticDelays();
        simulateBothOraclesSamePrices();

        assertEq(uniswapRAIWETHMedianizer.earliestObservationIndex(), 72);
        assertEq(uniswapRAIUSDCMedianizer.earliestObservationIndex(), 72);

        (uint256 uniObservationsListLength, uint256 converterObservationsListLength) = uniswapRAIWETHMedianizer.getObservationListLength();
        assertEq(uniObservationsListLength, 96);
        assertEq(converterObservationsListLength, 96);

        (uniObservationsListLength, converterObservationsListLength) = uniswapRAIUSDCMedianizer.getObservationListLength();
        assertEq(uniObservationsListLength, 96);
        assertEq(converterObservationsListLength, 96);

        assertEq(uniswapRAIUSDCMedianizer.converterPriceCumulative(), initUSDCUSDPrice * uint(uniswapMedianizerGranularity) * uniswapRAIUSDCMedianizer.periodSize());
        assertEq(uniswapRAIWETHMedianizer.converterPriceCumulative(), initETHUSDPrice * uint(uniswapMedianizerGranularity) * uniswapRAIUSDCMedianizer.periodSize());

        assertEq(uniswapRAIUSDCMedianizer.timeElapsedSinceFirstObservation(), 23 hours);
        assertEq(uniswapRAIWETHMedianizer.timeElapsedSinceFirstObservation(), 23 hours);

        // RAI/WETH
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 4242000000004242000);

        // RAI/USDC
        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 4241999999999999999);
    }
    function test_simulate_denominator_token_positive_price_jump() public {
        simulateBothOraclesSamePrices();

        // Initial checks
        assertEq(uniswapRAIWETHMedianizer.converterPriceCumulative(), initETHUSDPrice * uniswapRAIWETHMedianizer.periodSize() * uniswapMedianizerGranularity);
        assertEq(uniswapRAIUSDCMedianizer.converterPriceCumulative(), initUSDCUSDPrice * uniswapRAIWETHMedianizer.periodSize() * uniswapMedianizerGranularity);

        // Price jumps
        hevm.warp(now + uniswapRAIWETHMedianizer.periodSize());
        uint totalWETHDeviation = 24 * 10 ** 18;
        uint totalUSDCDeviation = 10 ** 18;

        converterETHPriceFeed.modifyParameters("medianPrice", initETHUSDPrice + totalWETHDeviation);
        uniswapRAIWETHMedianizer.updateResult(address(alice));
        raiWETHPair.sync();

        converterUSDCPriceFeed.modifyParameters("medianPrice", initUSDCUSDPrice + 10 ** 18);
        uniswapRAIUSDCMedianizer.updateResult(address(alice));
        raiUSDCPair.sync();

        assertEq(
          uniswapRAIWETHMedianizer.converterPriceCumulative() / (24 * uniswapRAIWETHMedianizer.periodSize()), 251000000000000000000
        );

        uint granularityAdjustedDeviation = uint(totalWETHDeviation) / uniswapMedianizerGranularity;
        assertEq(
          uniswapRAIWETHMedianizer.converterPriceCumulative(), initETHUSDPrice * 23 * uniswapRAIWETHMedianizer.periodSize() + (initETHUSDPrice + totalWETHDeviation) * uniswapRAIWETHMedianizer.periodSize()
        );
        assertEq(uniswapRAIWETHMedianizer.converterComputeAmountOut(uniswapRAIWETHMedianizer.periodSize() * uniswapMedianizerGranularity, 10**18), initETHUSDPrice + granularityAdjustedDeviation);

        granularityAdjustedDeviation = uint(totalUSDCDeviation) / uniswapMedianizerGranularity;
        assertEq(
          uniswapRAIUSDCMedianizer.converterPriceCumulative(), initUSDCUSDPrice * 23 * uniswapRAIWETHMedianizer.periodSize() + (initUSDCUSDPrice + totalUSDCDeviation) * uniswapRAIWETHMedianizer.periodSize()
        );
        assertEq(uniswapRAIUSDCMedianizer.converterComputeAmountOut(uniswapRAIWETHMedianizer.periodSize() * uniswapMedianizerGranularity, 10**18), initUSDCUSDPrice + granularityAdjustedDeviation);

        // RAI/WETH
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 4258968000004258968);

        // RAI/USDC
        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 4418749999999999996);
    }
    function test_get_result_after_passing_granularity() public {
        simulateETHRAISamePrices();
        simulateUSDCRAISamePrices();

        // RAI/WETH
        (, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(isValid);

        // RAI/USDC
        (, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        assertTrue(isValid);
    }
    function test_read_after_passing_granularity() public {
        simulateETHRAISamePrices();
        simulateUSDCRAISamePrices();

        // RAI/WETH
        uint median = uniswapRAIWETHMedianizer.read();
        assertTrue(median > 0);

        // RAI/USDC
        median = uniswapRAIUSDCMedianizer.read();
        assertTrue(median > 0);
    }
    function test_thin_liquidity_one_round_simulate_prices() public {
        simulateBothOraclePrices();

        // RAI/WETH
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 1326905250418311750);

        // RAI/USDC
        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 673978495628683916);
    }
    function test_thin_liquidity_multi_round_simulate_prices() public {
        for (uint i = 0; i < 5; i++) {
          simulateBothOraclePrices();
        }

        // RAI/WETH
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 1252524866559942500);

        // // RAI/USDC
        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 2224385480941195516);
    }
    function test_thin_liquidity_multi_round_simulate_prices_erratic_delays() public {
        for (uint i = 0; i < 5; i++) {
          simulateBothOraclesPricesErraticDelays();
        }

        // RAI/WETH
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 1247718382333789500);

        // // RAI/USDC
        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 2214949576302264945);
    }
    function test_thin_liquidity_multi_round_simulate_prices_erratic_then_normal_delays() public {
        for (uint i = 0; i < 5; i++) {
          simulateBothOraclesPricesErraticDelays();
        }
        for (uint i = 0; i < 5; i++) {
          simulateBothOraclePrices();
        }

        // RAI/WETH
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 1250867823136796250);

        // // RAI/USDC
        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 2364579276364703965);
    }
    function test_bid_initial_delay_thin_liquidity_multi_round_simulate_prices_erratic_then_normal_delays() public {
        hevm.warp(now + 8 hours);

        for (uint i = 0; i < 5; i++) {
          simulateBothOraclesPricesErraticDelays();
        }
        for (uint i = 0; i < 5; i++) {
          simulateBothOraclePrices();
        }

        // RAI/WETH
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 1250867823136796250);

        // // RAI/USDC
        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 2364579276364703965);
    }
    function test_deep_liquidity_one_round_simulate_prices() public {
        // Add WETH/RAI liquidity
        addPairLiquidityRouter(address(rai), address(weth), initRAIETHPairLiquidity * 80000, initETHRAIPairLiquidity * 80000);
        // Add USDC/RAI liquidity
        addPairLiquidityRouter(address(rai), address(usdc), initRAIUSDCPairLiquidity * 80000, initUSDCRAIPairLiquidity * 80000);

        // Simulate market making
        simulateBothOraclePrices();

        // RAI/WETH
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 4241832799039214000);

        // RAI/USDC
        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 4237586817784852325);
    }
    function test_deep_liquidity_one_round_simulate_prices_erratic_delays() public {
        // Add WETH/RAI liquidity
        addPairLiquidityRouter(address(rai), address(weth), initRAIETHPairLiquidity * 80000, initETHRAIPairLiquidity * 80000);
        // Add USDC/RAI liquidity
        addPairLiquidityRouter(address(rai), address(usdc), initRAIUSDCPairLiquidity * 80000, initUSDCRAIPairLiquidity * 80000);

        // Simulate market making
        simulateBothOraclesPricesErraticDelays();

        // RAI/WETH
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 4241829887122276000);

        // RAI/USDC
        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 4237481662786958203);
    }
    function test_deep_liquidity_one_round_simulate_prices_erratic_then_normal_delays() public {
        // Add WETH/RAI liquidity
        addPairLiquidityRouter(address(rai), address(weth), initRAIETHPairLiquidity * 80000, initETHRAIPairLiquidity * 80000);
        // Add USDC/RAI liquidity
        addPairLiquidityRouter(address(rai), address(usdc), initRAIUSDCPairLiquidity * 80000, initUSDCRAIPairLiquidity * 80000);

        // Simulate market making
        simulateBothOraclesPricesErraticDelays();
        simulateBothOraclePrices();

        assertEq(uniswapRAIUSDCMedianizer.converterPriceCumulative(), initUSDCUSDPrice * uint(uniswapMedianizerGranularity) * uniswapRAIUSDCMedianizer.periodSize());
        assertEq(uniswapRAIWETHMedianizer.converterPriceCumulative(), initETHUSDPrice * uint(uniswapMedianizerGranularity) * uniswapRAIWETHMedianizer.periodSize());

        // RAI/WETH
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 4241667829760050750);

        // RAI/USDC
        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 4234771455067826728);
    }
    function test_two_hour_twap() public {
        // Setup
        UniswapConsecutiveSlotsPriceFeedMedianizer twoHourMedianizer = new UniswapConsecutiveSlotsPriceFeedMedianizer(
            address(0x1),
            address(uniswapFactory),
            uniswapETHRAIMedianizerDefaultAmountIn,
            2 hours,
            converterScalingFactor,
            4 hours,
            2
        );
        IncreasingRewardRelayer newRelayer = new IncreasingRewardRelayer(
            address(twoHourMedianizer),
            address(treasury),
            baseCallerReward,
            maxCallerReward,
            perSecondCallerRewardIncrease,
            twoHourMedianizer.periodSize()
        );
        twoHourMedianizer.modifyParameters("relayer", address(newRelayer));

        // Set max reward increase delay
        newRelayer.modifyParameters("maxRewardIncreaseDelay", maxRewardDelay);

        // Set treasury allowance
        treasury.setTotalAllowance(address(newRelayer), uint(-1));
        treasury.setPerBlockAllowance(address(newRelayer), uint(-1));

        // Set converter addresses
        twoHourMedianizer.modifyParameters("converterFeed", address(converterETHPriceFeed));

        // Set target and denomination tokens
        twoHourMedianizer.modifyParameters("targetToken", address(rai));
        twoHourMedianizer.modifyParameters("denominationToken", address(weth));

        // Add extra liquidity
        addPairLiquidityRouter(address(rai), address(weth), initRAIETHPairLiquidity, initETHRAIPairLiquidity);

        // Update median
        hevm.warp(now + 10);
        twoHourMedianizer.updateResult(address(this));
        (, bool isValid) = twoHourMedianizer.getResultWithValidity();
        assertTrue(!isValid);

        hevm.warp(now + 1 hours);
        twoHourMedianizer.updateResult(address(this));
        (, isValid) = twoHourMedianizer.getResultWithValidity();
        assertTrue(!isValid);

        hevm.warp(now + 1 hours);
        twoHourMedianizer.updateResult(address(this));
        (, isValid) = twoHourMedianizer.getResultWithValidity();
        assertTrue(isValid);

        // Checks
        (uint256 medianPrice,) = twoHourMedianizer.getResultWithValidity();
        assertEq(medianPrice, 4242000000004242000);

        assertEq(twoHourMedianizer.updates(), 3);
        assertEq(twoHourMedianizer.timeElapsedSinceFirstObservation(), 1 hours);
    }
    function test_two_hour_twap_massive_update_delay() public {
        // Setup
        UniswapConsecutiveSlotsPriceFeedMedianizer twoHourMedianizer = new UniswapConsecutiveSlotsPriceFeedMedianizer(
            address(0x1),
            address(uniswapFactory),
            uniswapETHRAIMedianizerDefaultAmountIn,
            2 hours,
            converterScalingFactor,
            4 hours,
            2
        );
        IncreasingRewardRelayer newRelayer = new IncreasingRewardRelayer(
            address(twoHourMedianizer),
            address(treasury),
            baseCallerReward,
            maxCallerReward,
            perSecondCallerRewardIncrease,
            twoHourMedianizer.periodSize()
        );
        twoHourMedianizer.modifyParameters("relayer", address(newRelayer));

        // Set max reward increase delay
        newRelayer.modifyParameters("maxRewardIncreaseDelay", maxRewardDelay);

        // Set treasury allowance
        treasury.setTotalAllowance(address(newRelayer), uint(-1));
        treasury.setPerBlockAllowance(address(newRelayer), uint(-1));

        // Set converter addresses
        twoHourMedianizer.modifyParameters("converterFeed", address(converterETHPriceFeed));

        // Set target and denomination tokens
        twoHourMedianizer.modifyParameters("targetToken", address(rai));
        twoHourMedianizer.modifyParameters("denominationToken", address(weth));

        // Add extra liquidity
        addPairLiquidityRouter(address(rai), address(weth), initRAIETHPairLiquidity, initETHRAIPairLiquidity);

        // Update median
        hevm.warp(now + 10);
        twoHourMedianizer.updateResult(address(this));
        hevm.warp(now + 1 hours);
        twoHourMedianizer.updateResult(address(this));
        hevm.warp(now + 3650 days);
        twoHourMedianizer.updateResult(address(this));

        // Checks
        (uint256 medianPrice, bool isValid) = twoHourMedianizer.getResultWithValidity();
        assertEq(medianPrice, 4242000000004242000);
        assertTrue(!isValid);

        assertEq(twoHourMedianizer.updates(), 3);
        assertEq(twoHourMedianizer.timeElapsedSinceFirstObservation(), 3650 days);

        // Another update
        hevm.warp(now + 1 hours);
        twoHourMedianizer.updateResult(address(this));

        // Checks
        (medianPrice, isValid) = twoHourMedianizer.getResultWithValidity();
        assertEq(medianPrice, 4242000000004242000);
        assertTrue(isValid);
    }
}
