pragma solidity ^0.6.7;

import './utils/uni/IUniswapV2Factory.sol';
import './utils/uni/IUniswapV2Pair.sol';

import './utils/libs/UniswapV2Library.sol';
import './utils/libs/UniswapV2OracleLibrary.sol';

abstract contract ConverterFeedLike {
    function getResultWithValidity() virtual external view returns (uint256,bool);
    function updateResult() virtual external;
}

contract UniswapPriceFeedMedianizer is UniswapV2Library, UniswapV2OracleLibrary {
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
    uint256              public defaultAmountIn;

    address              public uniswapFactory;
    address              public targetToken;
    address              public denominationToken;
    address              public uniswapPair;

    UniswapObservation[] public uniswapObservations;

    // --- Converter Feed Vars ---
    uint256                    public converterPriceCumulative;
    uint256                    public converterPriceTag;

    ConverterFeedLike          public converterFeed;
    ConverterFeedObservation[] public converterFeedObservations;

    // --- General Vars ---
    // Symbol - you want to change this every deployment
    bytes32 public symbol = "raiusd";
    /**
        The number of observations stored for each pair, i.e. how many price observations are stored for the window.
        as granularity increases from 1, more frequent updates are needed, but moving averages become more precise.
        averages are computed over intervals with sizes in the range:
          [windowSize - (windowSize / granularity) * 2, windowSize]
        e.g. if the window size is 24 hours, and the granularity is 24, the oracle will return the average price for
          the period:
          [now - [22 hours, 24 hours], now]
    **/
    uint8   public granularity;
    // When the price feed was last updated
    uint32  public lastUpdateTime;
    // The desired amount of time over which the moving average should be computed, e.g. 24 hours
    uint256 public windowSize;
    // This is redundant with granularity and windowSize, but stored for gas savings & informational purposes.
    uint256 public periodSize;
    // This is the denominator for computing
    uint256 public converterFeedScalingFactor;
    // The last computed median price
    uint256 private medianPrice;

    // --- Events ---
    event LogMedianPrice(uint256 medianPrice, uint256 lastUpdateTime);
    event FailedConverterFeedUpdate(bytes reason);

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
      uint256 defaultAmountIn_,
      uint256 windowSize_,
      uint256 converterFeedScalingFactor_,
      uint8   granularity_
    ) public {
        require(granularity_ > 1, 'UniswapPriceFeedMedianizer/null-granularity');
        require(
            (periodSize = windowSize_ / granularity_) * granularity_ == windowSize_,
            'UniswapPriceFeedMedianizer/window-not-evenly-divisible'
        );
        require(converterFeed_ != address(0), "UniswapPriceFeedMedianizer/null-converter-feed");
        authorizedAccounts[msg.sender] = 1;
        converterFeed                  = ConverterFeedLike(converterFeed_);
        uniswapFactory                 = uniswapFactory_;
        defaultAmountIn                = defaultAmountIn_;
        windowSize                     = windowSize_;
        converterFeedScalingFactor     = converterFeedScalingFactor_;
        granularity                    = granularity_;
        targetToken                    = targetToken_;
        denominationToken              = denominationToken_;
        uniswapPair                    = pairFor(uniswapFactory, targetToken, denominationToken);
        // Populate the arrays with empty observations
        for (uint i = uniswapObservations.length; i < granularity; i++) {
            uniswapObservations.push();
            converterFeedObservations.push();
        }
    }

    // --- Administration ---
    function modifyParameters(bytes32 parameter, uint256 data) external emitLog isAuthorized {
        require(data > 0, "UniswapPriceFeedMedianizer/null-data");
        if (parameter == "defaultAmountIn") {
          defaultAmountIn = data;
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
    function both(bool x, bool y) private pure returns (bool z) {
        assembly{ z := and(x, y)}
    }
    /**
    *   @notice Returns the index of the observation corresponding to the given timestamp
    *   @param timestamp The timestamp for which we want to get the index for
    **/
    function observationIndexOf(uint timestamp) private view returns (uint8 index) {
        uint epochPeriod = timestamp / periodSize;
        return uint8(epochPeriod % granularity);
    }
    // @notice Returns the observations from the oldest epoch (at the beginning of the window) relative to the current time
    function getFirstObservationsInWindow()
      private view returns (UniswapObservation storage firstUniswapObservation, ConverterFeedObservation storage firstConverterFeedObservation) {
        uint8 observationIndex = observationIndexOf(block.timestamp);
        // No overflow issue. If observationIndex + 1 overflows, result is still zero
        uint8 firstObservationIndex   = (observationIndex + 1) % granularity;
        firstUniswapObservation       = uniswapObservations[firstObservationIndex];
        firstConverterFeedObservation = converterFeedObservations[firstObservationIndex];
    }
    function getMedianPrice(uint256 price0Cumulative, uint256 price1Cumulative) private returns (uint256) {
        (
          UniswapObservation storage firstUniswapObservation,
          ConverterFeedObservation storage firstConverterFeedObservation
        ) = getFirstObservationsInWindow();

        uint timeElapsedSinceFirst = block.timestamp - firstUniswapObservation.timestamp;
        // We can only fetch a brand new median price if there's been enough price data gathered
        if (both(timeElapsedSinceFirst <= windowSize, timeElapsedSinceFirst >= windowSize - periodSize * 2)) {
          converterPriceTag = subtract(firstConverterFeedObservation.price, firstConverterFeedObservation.price);

          (address token0,) = sortTokens(targetToken, denominationToken);
          uint256 uniswapAmountOut;
          if (token0 == targetToken) {
              uniswapAmountOut = uniswapComputeAmountOut(firstUniswapObservation.price0Cumulative, price0Cumulative, timeElapsedSinceFirst, defaultAmountIn);
          } else {
              uniswapAmountOut = uniswapComputeAmountOut(firstUniswapObservation.price1Cumulative, price1Cumulative, timeElapsedSinceFirst, defaultAmountIn);
          }

          return converterComputeAmountOut(uniswapAmountOut);
        }

        return medianPrice;
    }

    // --- Uniswap Utils ---
    /**
    *   @notice Given the Uniswap cumulative prices of the start and end of a period, and the length of the period, compute the average
    *           price in terms of how much amount out is received for the amount in.
    **/
    function uniswapComputeAmountOut(
        uint256 priceCumulativeStart,
        uint256 priceCumulativeEnd,
        uint256 timeElapsed,
        uint256 amountIn
    ) public pure returns (uint256 amountOut) {
        // Overflow is desired
        uq112x112 memory priceAverage = uq112x112(
            uint224((priceCumulativeEnd - priceCumulativeStart) / timeElapsed)
        );
        amountOut = decode144(multiply(priceAverage, amountIn));
    }

    // --- Converter Utils ---
    function converterComputeAmountOut(
        uint256 amountIn
    ) public view returns (uint256 amountOut) {
        uint256 priceAverage = converterPriceTag / granularity;
        amountOut            = multiply(amountIn, priceAverage) / converterFeedScalingFactor;
    }

    // --- Core Logic ---
    // @notice Update the internal median price
    function updateResult() external {
        // Update the converter's median price first
        try converterFeed.updateResult() {}
        catch (bytes memory revertReason) {
          emit FailedConverterFeedUpdate(revertReason);
          return;
        }

        // Get the observation for the current period
        uint8 observationIndex         = observationIndexOf(block.timestamp);
        uint256 timeElapsedSinceLatest = (block.timestamp - uniswapObservations[observationIndex].timestamp);
        // We only want to commit updates once per period (i.e. windowSize / granularity)
        if (timeElapsedSinceLatest > periodSize) {
            // Get Uniswap cumulative prices
            (uint uniswapPrice0Cumulative, uint uniswapPrice1Cumulative,) = currentCumulativePrices(uniswapPair);

            // Add new observations
            updateObservations(observationIndex, uniswapPrice0Cumulative, uniswapPrice1Cumulative);

            // Calculate latest medianPrice
            medianPrice    = getMedianPrice(uniswapPrice0Cumulative, uniswapPrice1Cumulative);
            lastUpdateTime = uint32(now);
        }
    }
    function updateObservations(uint8 observationIndex, uint256 uniswapPrice0Cumulative, uint256 uniswapPrice1Cumulative) internal {
        UniswapObservation       storage latestUniswapObservation       = uniswapObservations[observationIndex];
        ConverterFeedObservation storage latestConverterFeedObservation = converterFeedObservations[observationIndex];

        // Add Uniswap observation
        latestUniswapObservation.timestamp        = block.timestamp;
        latestUniswapObservation.price0Cumulative = uniswapPrice0Cumulative;
        latestUniswapObservation.price1Cumulative = uniswapPrice1Cumulative;

        // Add converter feed observation
        (uint256 priceFeedValue, bool hasValidValue) = converterFeed.getResultWithValidity();
        latestConverterFeedObservation.timestamp     = block.timestamp;
        if (hasValidValue) {
          latestConverterFeedObservation.price = priceFeedValue;
        } else {
          latestConverterFeedObservation.price = converterFeedObservations[observationIndex - 1].price;
        }

        converterPriceTag = addition(converterPriceTag, latestConverterFeedObservation.price);
    }

    // --- Getters ---
    function read() external view returns (uint256) {
        require(medianPrice > 0, "UniswapPriceFeedMedianizer/invalid-price-feed");
        return medianPrice;
    }
    function getResultWithValidity() external view returns (uint256, bool) {
        return (medianPrice, medianPrice > 0);
    }
}
