pragma solidity 0.6.7;

import "ds-test/test.sol";
import "../ConverterFeed.sol";
import "ds-value/value.sol";

contract Caller {
    ConverterFeed converter;

    constructor (ConverterFeed add) public {
        converter = add;
    }

    function doModifyParameters(bytes32 param, uint256 data) public {
        converter.modifyParameters(param, data);
    }

    function doAddAuthorization(address data) public {
        converter.addAuthorization(data);
    }

    function doRemoveAuthorization(address data) public {
        converter.removeAuthorization(data);
    }
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

contract ConverterFeedTest is DSTest {
    Feed raiEth;
    Feed ethUsd;
    ConverterFeed converter;
    uint scalingFactor = 1 ether;

    uint raiEthInitialPrice = .0015 ether;
    uint ethUsdInitialPrice = 2000  ether;

    Caller unauth;

    function setUp() public {
        // Deploy Feeds
        raiEth = new Feed();
        ethUsd = new Feed();
        converter = new ConverterFeed(
            address(raiEth),
            address(ethUsd),
            scalingFactor
        );

        // Default prices
        raiEth.updateResult(raiEthInitialPrice);
        ethUsd.updateResult(ethUsdInitialPrice);

        unauth = new Caller(converter);
    }

    // --- Tests ---
    function test_setup() public {
        assertEq(address(converter.targetFeed()), address(raiEth));
        assertEq(address(converter.denominationFeed()), address(ethUsd));
        assertEq(converter.authorizedAccounts(address(this)), 1);
        assertEq(converter.converterFeedScalingFactor(), scalingFactor);
        assertEq(converter.validityFlag(), 1);
    }

    function test_add_authorization() public {
        converter.addAuthorization(address(0xfab));
        assertEq(converter.authorizedAccounts(address(0xfab)), 1);
    }

    function test_remove_authorization() public {
        converter.removeAuthorization(address(this));
        assertEq(converter.authorizedAccounts(address(this)), 0);
    }

    function testFail_add_authorization_unauthorized() public {
        unauth.doAddAuthorization(address(0xfab));
    }

    function testFail_remove_authorization_unauthorized() public {
        unauth.doRemoveAuthorization(address(this));
    }

    function test_modify_parameters() public {
        converter.modifyParameters("validityFlag", 0);
        assertEq(converter.validityFlag(), 0);

        converter.modifyParameters("scalingFactor", 2 ether);
        assertEq(uint(converter.converterFeedScalingFactor()), 2 ether);

        converter.modifyParameters("targetFeed", address(1));
        assertEq(address(converter.targetFeed()), address(1));

        converter.modifyParameters("denominationFeed", address(2));
        assertEq(address(converter.denominationFeed()), address(2));
    }

    function testFail_modify_parameters_invalid_validityFlag() public {
        converter.modifyParameters("validityFlag", 2);
    }

    function testFail_modify_parameters_invalid_scaling_factor() public {
        converter.modifyParameters("scalingFactor", 0);
    }

    function testFail_modify_parameters_invalid_address() public {
        converter.modifyParameters("targetFeed", address(0));
    }    

    function test_update_result() public {
        converter.updateResult(address(0));
        assertEq(raiEth.updates(), 1);
        assertEq(ethUsd.updates(), 1);

        converter.updateResult(address(0));
        assertEq(raiEth.updates(), 2);
        assertEq(ethUsd.updates(), 2);        

        raiEth.setForceRevert(true);
        converter.updateResult(address(0));
        assertEq(raiEth.updates(), 2);
        assertEq(ethUsd.updates(), 3);    

        raiEth.setForceRevert(false);
        ethUsd.setForceRevert(true);
        converter.updateResult(address(0));
        assertEq(raiEth.updates(), 3);
        assertEq(ethUsd.updates(), 3);              
    }

    function test_get_result_with_validity() public {
        (uint value, bool valid) = converter.getResultWithValidity();
        assertEq(value, (raiEth.read() * ethUsd.read()) / 1 ether); 
        assertEq(value, 3 ether);
        assertTrue(valid);

        raiEth.updateResult(.00075 ether);
        ethUsd.updateResult(4000 ether);

        (value, valid) = converter.getResultWithValidity();
        assertEq(value, (raiEth.read() * ethUsd.read()) / 1 ether); 
        assertEq(value, 3 ether);
        assertTrue(valid);

        ethUsd.setValid(false);
        (value, valid) = converter.getResultWithValidity();
        assertTrue(!valid);         

        raiEth.setValid(false);
        (value, valid) = converter.getResultWithValidity();
        assertTrue(!valid);   

        ethUsd.setValid(true);
        (value, valid) = converter.getResultWithValidity();
        assertTrue(!valid);                          
    }    

    function test_read() public {
        uint value = converter.read();
        assertEq(value, (raiEth.read() * ethUsd.read()) / 1 ether); 
        assertEq(value, 3 ether);
    }

    function testFail_read_invalid() public {
        ethUsd.setValid(false);
        converter.read();
    }

}
