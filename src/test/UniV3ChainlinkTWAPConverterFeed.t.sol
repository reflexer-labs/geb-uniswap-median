pragma solidity 0.6.7;

import "ds-test/test.sol";
import "../UniV3ChainlinkTWAPConverterFeed.sol";
import "ds-value/value.sol";

abstract contract Hevm {
    function warp(uint) public virtual;

    function roll(uint) public virtual;
}

contract Feed is DSValue {
    uint public updates;
    bool public forceRevert;

    function updateResult(address feeReceiver) public {
        require(!forceRevert, "feed reverted on update");
        updates++;
    }

    function setForceRevert(bool val) public {
        forceRevert = val;
    }

    function setValid(bool valid) public {
        isValid = valid;
    }
}

contract ChainlinkTWAPMock is Feed {
    function chainlinkObservations(uint) external view returns (uint, uint) {
        return (block.timestamp - 7 days, 0); // timestamp, price (not by the converter)
    }

    function earliestObservationIndex() external view returns (uint) {
        return 1;
    }

    function lastUpdateTime() external view returns (uint) {
        return now - 25 minutes;
    }
}

contract UniswapV3TWAPMock is Feed {
    function getTwapPrice(uint256, uint256) external view returns (uint) {
        return read();
    }
}

contract ConverterFeedTest is DSTest {
    Hevm hevm;
    UniswapV3TWAPMock taiEth;
    ChainlinkTWAPMock ethUsd;
    ConverterFeed converter;
    uint scalingFactor = 1 ether;

    uint taiEthInitialPrice = .0015 ether;
    uint ethUsdInitialPrice = 2000 ether;

    function setUp() public {
        // Deploy Feeds
        taiEth = new UniswapV3TWAPMock();
        ethUsd = new ChainlinkTWAPMock();
        converter = new ConverterFeed(
            address(taiEth),
            address(ethUsd),
            scalingFactor
        );

        // Default prices
        taiEth.updateResult(taiEthInitialPrice);
        ethUsd.updateResult(ethUsdInitialPrice);

        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(15000000);
    }

    // --- Tests ---
    function test_setup() public {
        assertEq(address(converter.uniV3TWAP()), address(taiEth));
        assertEq(address(converter.chainlinkTWAP()), address(ethUsd));
        assertEq(converter.converterFeedScalingFactor(), scalingFactor);
    }

    function test_get_result_with_validity2() public {
        (uint value, bool valid) = converter.getResultWithValidity();
        assertEq(value, (taiEth.read() * ethUsd.read()) / 1 ether);
        assertEq(value, 3 ether);
        assertTrue(valid);

        taiEth.updateResult(.00075 ether);
        ethUsd.updateResult(4000 ether);

        (value, valid) = converter.getResultWithValidity();
        assertEq(value, (taiEth.read() * ethUsd.read()) / 1 ether);
        assertEq(value, 3 ether);
        assertTrue(valid);

        ethUsd.setValid(false);
        (value, valid) = converter.getResultWithValidity();
        assertTrue(!valid);

        taiEth.setValid(false);
        (value, valid) = converter.getResultWithValidity();
        assertTrue(!valid);

        ethUsd.setValid(true);
        (value, valid) = converter.getResultWithValidity();
        assertTrue(!valid);
    }

    function test_read() public {
        uint value = converter.read();
        assertEq(value, (taiEth.read() * ethUsd.read()) / 1 ether);
        assertEq(value, 3 ether);
    }

    function testFail_read_invalid() public {
        ethUsd.setValid(false);
        converter.read();
    }
}
