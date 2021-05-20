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
}

contract USDC is DSToken {
    constructor(string memory symbol) public DSToken(symbol, symbol) {
        decimals = 6;
        mint(100 ether);
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
    USDC usdc;
    WETH9_ weth;

    DSToken token0;
    DSToken token1;

    uint256 startTime               = 1577836800;
    uint256 initTokenAmount         = 100000000 ether;
    uint256 initETHRAIPairLiquidity = 5 ether; 
    uint256 initRAIETHPairLiquidity = 294.672324375E18;

    uint8   uniswapMedianizerGranularity            = 24;           // 1 hour
    uint256 converterScalingFactor                  = 1 ether;
    uint32  uniswapMedianizerWindowSize             = 86400;        // 24 hours
    uint256 uniswapETHRAIMedianizerDefaultAmountIn  = 1 ether;
    uint256 uniswapUSDCRAIMedianizerDefaultAmountIn = 10 ** 12 * 1 ether;
    address me;

    function setUp() public {
        me = address(this);

        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(startTime);

        // Deploy Tokens
        weth = new WETH9_();

        rai = new DSToken("RAI", "RAI");
        rai.mint(initTokenAmount);

        usdc = new USDC("USDC");

        // Create WETH
        weth.deposit{value: initTokenAmount}();

        address p = helper_deployV3Pool(address(rai), address(weth), 3000);
        raiWETHPool = UniswapV3Pool(p);
        uint160 initialPrice = helper_getInitialPoolPrice();
        raiWETHPool.initialize(initialPrice);

        //Increase the number of oracle observations
        raiWETHPool.increaseObservationCardinalityNext(8000);

        uniswapRAIWETHMedianizer = new UniswapV3ConverterBasicMeanPriceFeedMedianizer(
            address(0x1),
            address(uniswapFactory),
            uniswapETHRAIMedianizerDefaultAmountIn,
            uniswapMedianizerWindowSize,
            converterScalingFactor
        );

        // Set converter addresses
        uniswapRAIWETHMedianizer.modifyParameters("converterFeed", address(converterETHPriceFeed));

        // Set target and denomination tokens
        uniswapRAIWETHMedianizer.modifyParameters("targetToken", address(rai));
        uniswapRAIWETHMedianizer.modifyParameters("denominationToken", address(weth));

        // Add liquidity to the pool
        helper_addLiquidity();
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

    function helper_deployV3Pool(
        address _token0,
        address _token1,
        uint256 _fee
    ) internal returns (address _pool) {
        UniswapV3Factory fac = new UniswapV3Factory();
        _pool = fac.createPool(_token0, _token1, uint24(_fee));
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


    // --- Uniswap Callbacks ---
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external {
        token0.transfer(msg.sender, amount0Owed);
        token1.transfer(msg.sender, amount1Owed);
    }
}