pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-weth/src/weth9.sol";
import "ds-token/token.sol";

import "../univ3/UniswapV3Pool.sol";
import { UniswapV3Medianizer } from  "../UniswapV3Medianizer.sol";

contract UniswapV3MedianizerTest is DSTest {
    UniswapV3Medianizer uniswapRAIDAIMedianizer;
    UniswapV3Medianizer uniswapRAIETHMedianizer;

    address rai = 0x03ab458634910AaD20eF5f1C8ee96F1D6ac54919;
    address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    UniswapV3Pool raiDaiPool;
    UniswapV3Pool raiEthPool;

    function setUp() public {
        raiDaiPool = UniswapV3Pool(0xcB0C5d9D92f4F2F80cce7aa271a1E148c226e19D);
        raiEthPool = UniswapV3Pool(0x14DE8287AdC90f0f95Bf567C0707670de52e3813);
        uniswapRAIDAIMedianizer = new UniswapV3Medianizer(
            address(raiDaiPool),
            rai,
            10 minutes,
            100000 ether
        );
        uniswapRAIETHMedianizer = new UniswapV3Medianizer(
            address(raiEthPool),
            rai,
            12 hours,
            1 ether
        );
    }

    //Uncomment this to run tests agains a mainnet rpc url
    // function test_fork() public {
    //     (uint value, bool valid) = uniswapRAIETHMedianizer.getResultWithValidity();
    //     emit log_named_uint("rai eth", value);
    //     emit log_named_uint("valid", valid ? 1 : 0);
    //     assertTrue(value > 0.001 ether && value < 0.002 ether);

    //     (value, valid) = uniswapRAIDAIMedianizer.getResultWithValidity();
    //     emit log_named_uint("rai dai", value);
    //     emit log_named_uint("valid", valid ? 1 : 0);
    //     assertTrue(value > 2.9 ether && value < 3.1 ether);
    // }
}
