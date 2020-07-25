pragma solidity ^0.6.7;

contract MockMedianizer {
    uint128 private medianPrice;
    uint32  public  lastUpdateTime;
    uint256 public  revertUpdate;

    bytes32 public symbol = "ethusd"; // you want to change this every deployment

    // --- Administration ---
    function modifyParameters(bytes32 parameter, uint data) external {
        if (parameter == "medianPrice") {
          medianPrice    = uint128(data);
          lastUpdateTime = uint32(now);
        }
        else if (parameter == "revertUpdate") {
          revertUpdate = data;
        }
        else revert("MockMedianizer/modify-unrecognized-param");
    }

    function read() external view returns (uint256) {
        require(medianPrice > 0, "MockMedianizer/invalid-price-feed");
        return medianPrice;
    }

    function getResultWithValidity() external view returns (uint256,bool) {
        return (medianPrice, medianPrice > 0);
    }

    function updateResult() external {
        if (revertUpdate > 0) revert();
    }
}
