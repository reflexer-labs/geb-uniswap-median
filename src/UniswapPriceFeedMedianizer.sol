pragma solidity ^0.6.7;

import './utils/uni/IUniswapV2Factory.sol';
import './utils/uni/IUniswapV2Pair.sol';
import './utils/uni/FixedPoint.sol';

import './utils/libs/SafeMath.sol';
import './utils/libs/UniswapV2Library.sol';
import './utils/libs/UniswapV2OracleLibrary.sol';

abstract contract ConverterFeedLike {
    function getResultWithValidity() virtual external view returns (uint256,bool);
    function updateResult() external;
}

contract UniswapPriceFeedMedianizer {
    using FixedPoint for *;
    using SafeMath for uint;

    // --- Auth ---
    mapping (address => uint) public authorizedAccounts;
    /**
     * @notice Add auth to an account
     * @param account Account to add auth to
     */
    function addAuthorization(address account) external emitLog isAuthorized {
        authorizedAccounts[account] = 1;
    }
    /**
     * @notice Remove auth from an account
     * @param account Account to remove auth from
     */
    function removeAuthorization(address account) external emitLog isAuthorized {
        authorizedAccounts[account] = 0;
    }
    /**
    * @notice Checks whether msg.sender can call an authed function
    **/
    modifier isAuthorized {
        require(authorizedAccounts[msg.sender] == 1, "UniswapPriceFeedMedianizer/account-not-authorized");
        _;
    }

    struct UniswapObservation {
        uint timestamp;
        uint price0Cumulative;
        uint price1Cumulative;
    }
    struct ConverterFeedObservation {
        uint timestamp;
        uint price;
    }

    // --- Uniswap Vars ---
    address public immutable uniswapFactory;
    address public immutable targetToken;
    address public immutable denominationToken;
    address public immutable uniswapPair;
    UniswapObservation[] public uniswapObservations;

    // --- Converter Feed Vars ---
    ConverterFeedLike public converterFeed;
    ConverterFeedObservation[] public converterFeedObservations;

    // --- General Vars ---
    bytes32 public symbol = "raiusd"; // You want to change this every deployment
    // The number of observations stored for each pair, i.e. how many price observations are stored for the window.
    // as granularity increases from 1, more frequent updates are needed, but moving averages become more precise.
    // averages are computed over intervals with sizes in the range:
    //   [windowSize - (windowSize / granularity) * 2, windowSize]
    // e.g. if the window size is 24 hours, and the granularity is 24, the oracle will return the average price for
    //   the period:
    //   [now - [22 hours, 24 hours], now]
    uint8   public immutable granularity;
    // When the price feed was last updated
    uint32  public lastUpdateTime;
    // The last computed median price
    uint128 private medianPrice;
    // Delay from the moment the contract is deployed and until it will start to calculate prices
    uint256 public delayFromDeployment;
    // When the contract was deployed
    uint256 public immutable deploymentTime;
    // The desired amount of time over which the moving average should be computed, e.g. 24 hours
    uint256 public immutable windowSize;
    // This is redundant with granularity and windowSize, but stored for gas savings & informational purposes.
    uint256 public immutable periodSize;

    event LogMedianPrice(uint256 medianPrice, uint256 lastUpdateTime);

    /**
    * @notice Log an 'anonymous' event with a constant 6 words of calldata
    * and four indexed topics: the selector and the first three args
    **/
    modifier emitLog {
        //
        //
        _;
        assembly {
            let mark := mload(0x40)                   // end of memory ensures zero
            mstore(0x40, add(mark, 288))              // update free memory pointer
            mstore(mark, 0x20)                        // bytes type data offset
            mstore(add(mark, 0x20), 224)              // bytes size (padded)
            calldatacopy(add(mark, 0x40), 0, 224)     // bytes payload
            log4(mark, 288,                           // calldata
                 shl(224, shr(224, calldataload(0))), // msg.sig
                 calldataload(4),                     // arg1
                 calldataload(36),                    // arg2
                 calldataload(68)                     // arg3
                )
        }
    }

    constructor(
      address converterFeed_,
      address uniswapFactory_,
      address targetToken_,
      address denominationToken_,
      uint256 windowSize_,
      uint256 delayFromDeployment_,
      uint8   granularity_
    ) public {
        require(granularity_ > 1, 'UniswapPriceFeedMedianizer/granularity');
        require(
            (periodSize = windowSize_ / granularity_) * granularity_ == windowSize_,
            'UniswapPriceFeedMedianizer/window-not-evenly-divisible'
        );
        require(converterFeed_ != address(0), "UniswapPriceFeedMedianizer/null-converter-feed");
        authorizedAccounts[msg.sender] = 1;
        converterFeed                  = ConverterFeedLike(converterFeed_);
        deploymentTime                 = now;
        uniswapFactory                 = uniswapFactory_;
        windowSize                     = windowSize_;
        granularity                    = granularity_;
        delayFromDeployment            = delayFromDeployment_;
        targetToken                    = targetToken_;
        denominationToken              = denominationToken_;
        uniswapPair                    = UniswapV2Library.pairFor(uniswapFactory, targetToken, denominationToken);
        // Populate the array with empty observations
        for (uint i = uniswapObservations.length; i < granularity; i++) {
            uniswapObservations.push();
            converterFeedObservations.push();
        }
    }

    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    // --- Administration ---
    function modifyParameters(bytes32 parameter, uint256 data) external emitLog isAuthorized {
        if (parameter == "delayFromDeployment") {
          require(both(converterFeedObservations.length == 0, uniswapObservations.length == 0), "UniswapPriceFeedMedianizer/non-null-observations");
          delayFromDeployment = data;
        }
        else revert("UniswapPriceFeedMedianizer/modify-unrecognized-param");
    }
    function modifyParameters(bytes32 parameter, address data) external emitLog isAuthorized {
        require(data != address(0), "UniswapPriceFeedMedianizer/null-data");
        if (parameter == "converterFeed") {
          converterFeed = ConverterFeedLike(data);
        }
        else revert("UniswapPriceFeedMedianizer/modify-unrecognized-param");
    }

    // --- General Utils ---
    // @notice Returns the index of the observation corresponding to the given timestamp
    // @param timestamp The timestamp for which we want to get the index for
    function observationIndexOf(uint timestamp) public view returns (uint8 index) {
        uint epochPeriod = timestamp / periodSize;
        return uint8(epochPeriod % granularity);
    }
    // @notice Returns the observation from the oldest epoch (at the beginning of the window) relative to the current time
    function getFirstObservationsInWindow()
      private view returns (UniswapObservation storage firstUniswapObservation, ConverterFeedObservation storage firstConverterFeedObservation) {
        uint8 observationIndex = observationIndexOf(block.timestamp);
        // No overflow issue. If observationIndex + 1 overflows, result is still zero
        uint8 firstObservationIndex   = (observationIndex + 1) % granularity;
        firstObservation              = uniswapObservations[firstObservationIndex];
        firstConverterFeedObservation = converterFeedObservations[firstObservationIndex];
    }

    // --- Uniswap Utils ---
    // @notice Given the cumulative prices of the start and end of a period, and the length of the period, compute the average
    //         price in terms of how much amount out is received for the amount in.
    function uniswapComputeAmountOut(
        uint256 priceCumulativeStart, uint256 priceCumulativeEnd,
        uint256 timeElapsed, uint256 amountIn
    ) private pure returns (uint256 amountOut) {
        // Overflow is desired
        FixedPoint.uq112x112 memory priceAverage = FixedPoint.uq112x112(
            uint224((priceCumulativeEnd - priceCumulativeStart) / timeElapsed)
        );
        amountOut = priceAverage.mul(amountIn).decode144();
    }

    // --- Converter Feed Utils ---
    function converterComputeAmountOut(
        uint256 priceCumulativeStart, uint256 priceCumulativeEnd,
        uint256 timeElapsed, uint256 amountIn
    ) private pure returns (uint256 amountOut) {
        FixedPoint.uq112x112 memory priceAverage = FixedPoint.uq112x112(
            uint224((priceCumulativeEnd - priceCumulativeStart) / timeElapsed)
        );
        amountOut = priceAverage.mul(amountIn).decode144();
    }

    // @notice Update the cumulative price for the observation at the current timestamp. each observation is updated at most
    //         once per epoch period
    function updateResult() external {
        // Get the observation for the current period
        uint8 observationIndex                              = observationIndexOf(block.timestamp);
        UniswapObservation storage uniswapObservation       = uniswapObservations[observationIndex];
        UniswapObservation storage converterFeedObservation = converterFeedObservations[observationIndex];

        // We only want to commit updates once per period (i.e. windowSize / granularity)
        uint256 timeElapsed = block.timestamp - observation.timestamp;
        if (timeElapsed > periodSize) {
            // Add Uniswap observation
            (uint uniswapPrice0Cumulative, uint uniswapPrice1Cumulative,) = UniswapV2OracleLibrary.currentCumulativePrices(uniswapPair);
            uniswapObservation.timestamp = block.timestamp;
            uniswapObservation.price0Cumulative = uniswapPrice0Cumulative;
            uniswapObservation.price1Cumulative = uniswapPrice1Cumulative;

            // Add converter feed observation
            (uint256 priceFeedValue, bool hasValidValue) = converterFeed.getResultWithValidity();
            converterFeedObservation.timestamp = block.timestamp;

            if (hasValidValue) {
              converterFeedObservation.price =
            } else {

            }
        }
    }

    // returns the amount out corresponding to the amount in for a given token using the moving average over the time
    // range [now - [windowSize, windowSize - periodSize * 2], now]
    // update must have been called for the bucket corresponding to timestamp `now - windowSize`
    function consult(address tokenIn, uint amountIn, address tokenOut) external view returns (uint amountOut) {
        (
          UniswapObservation storage firstUniswapObservation,
          ConverterFeedObservation storage firstConverterFeedObservation
        ) = getFirstObservationsInWindow();

        uint timeElapsed = block.timestamp - firstUniswapObservation.timestamp;
        require(timeElapsed <= windowSize, 'SlidingWindowOracle: MISSING_HISTORICAL_OBSERVATION');
        // Should never happen
        require(timeElapsed >= windowSize - periodSize * 2, 'SlidingWindowOracle: UNEXPECTED_TIME_ELAPSED');

        (uint price0Cumulative, uint price1Cumulative,) = UniswapV2OracleLibrary.currentCumulativePrices(uniswapPair);
        (address token0,) = UniswapV2Library.sortTokens(tokenIn, tokenOut);

        if (token0 == tokenIn) {
            return uniswapComputeAmountOut(firstObservation.price0Cumulative, price0Cumulative, timeElapsed, amountIn);
        } else {
            return uniswapComputeAmountOut(firstObservation.price1Cumulative, price1Cumulative, timeElapsed, amountIn);
        }
    }

    function read() external view returns (uint256) {
        require(medianPrice > 0, "UniswapPriceFeedMedianizer/invalid-price-feed");
        return medianPrice;
    }

    function getResultWithValidity() external view returns (uint256,bool) {
        return (medianPrice, medianPrice > 0);
    }
}
