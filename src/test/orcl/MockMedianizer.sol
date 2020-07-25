pragma solidity ^0.6.7;

contract MockMedianizer {
    uint128  private medianPrice;
    uint32   public  lastUpdateTime;
    uint256  public  updateThrows;

    bytes32 public symbol = "ethusd"; // you want to change this every deployment

    // --- Math ---
    function multiply(uint x, int y) internal pure returns (int z) {
        z = int(x) * y;
        require(int(x) >= 0);
        require(y == 0 || z / y == int(x));
    }

    // --- Administration ---
    function modifyParameters(bytes32 parameter, uint256 data) public {
        if (parameter == "updateThrows") {
            updateThrows = data;
        }
        else if (parameter == "medianPrice") {
            medianPrice    = data;
            lastUpdateTime = uint32(now);
        }
        else revert();
    }

    function read() external view returns (uint256) {
        require(medianPrice > 0, "MockMedianizer/invalid-price-feed");
        return medianPrice;
    }

    function getResultWithValidity() external view returns (uint256,bool) {
        return (medianPrice, medianPrice > 0);
    }

    function updateResult() external {
        if (updateThrows > 0) revert();
    }
}
