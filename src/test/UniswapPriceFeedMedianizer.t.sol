pragma solidity ^0.5.15;

import "ds-test/test.sol";

import "./GebUniswapMedian.sol";

contract GebUniswapMedianTest is DSTest {
    GebUniswapMedian median;

    function setUp() public {
        median = new GebUniswapMedian();
    }

    function testFail_basic_sanity() public {
        assertTrue(false);
    }

    function test_basic_sanity() public {
        assertTrue(true);
    }
}
