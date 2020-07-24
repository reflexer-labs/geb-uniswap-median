pragma solidity ^0.6.7;

import "ds-test/test.sol";

import "../UniswapPriceFeedMedianizer.sol";

contract UniswapPriceFeedMedianizerTest is DSTest {
    UniswapPriceFeedMedianizer uniswapMedianizer;

    function setUp() public {
        // median = new GebUniswapMedian();
    }

    function testFail_basic_sanity() public {
        assertTrue(false);
    }

    function test_basic_sanity() public {
        assertTrue(true);
    }
}
