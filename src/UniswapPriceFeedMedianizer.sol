pragma solidity ^0.6.7;

import './uni/interfaces/IUniswapV2Factory.sol';
import './uni/interfaces/IUniswapV2Pair.sol';

import './uni/libs/UniswapV2Library.sol';
import './uni/libs/UniswapV2OracleLibrary.sol';

abstract contract ConverterFeedLike {
    function getResultWithValidity() virtual external view returns (uint256,bool);
    function updateResult() virtual external;
}
abstract contract StabilityFeeTreasuryLike {
    function systemCoin() virtual external view returns (address);
    function pullFunds(address, address, uint) virtual external;
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

    // --- Observations ---
    struct UniswapObservation {
        uint timestamp;
        uint price0Cumulative;
        uint price1Cumulative;
    }
    struct ConverterFeedObservation {
        uint timestamp;
        uint updateDelay;
        int  price;
    }

    // --- Uniswap Vars ---
    // Default amount of targetToken used when calculating the denominationToken output
    uint256              public defaultAmountIn;
    // Token for which the contract calculates the medianPrice for
    address              public targetToken;
    // Pair token from the Unisap pair
    address              public denominationToken;
    address              public uniswapPair;

    IUniswapV2Factory    public uniswapFactory;

    UniswapObservation[] public uniswapObservations;

    // --- Converter Feed Vars ---
    // Latest converter price accumulator snapshot
    uint256                    public converterPriceCumulative;

    ConverterFeedLike          public converterFeed;
    ConverterFeedObservation[] public converterFeedObservations;

    // --- General Vars ---
    // Symbol - you want to change this every deployment
    bytes32 public symbol = "raiusd";
    /**
        The number of observations stored for the pair, i.e. how many price observations are stored for the window.
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
    // Amount of GEB system coins paid to the caller of 'updateResult'
    uint256 public updateCallerReward;
    // SF treasury contract
    StabilityFeeTreasuryLike  public treasury;

    // --- Events ---
    event LogMedianPrice(uint256 medianPrice, uint256 lastUpdateTime);
    event FailedConverterFeedUpdate(bytes reason);
    event FailedUniswapPairSync(bytes reason);

    // --- Modifiers ---
    /**
    * @notice Log an 'anonymous' event with a constant 6 words of calldata
    *         and four indexed topics: the selector and the first three args
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
      address treasury_,
      uint256 defaultAmountIn_,
      uint256 windowSize_,
      uint256 converterFeedScalingFactor_,
      uint256 updateCallerReward_
      uint8   granularity_
    ) public {
        require(granularity_ > 1, 'UniswapPriceFeedMedianizer/null-granularity');
        require(
            (periodSize = windowSize_ / granularity_) * granularity_ == windowSize_,
            'UniswapPriceFeedMedianizer/window-not-evenly-divisible'
        );
        if (address(treasury_) != address(0)) {
          require(StabilityFeeTreasuryLike(treasury_).systemCoin() != address(0), "UniswapPriceFeedMedianizer/treasury-coin-not-set");
        }
        authorizedAccounts[msg.sender] = 1;
        converterFeed                  = ConverterFeedLike(converterFeed_);
        treasury                       = StabilityFeeTreasuryLike(treasury_);
        uniswapFactory                 = IUniswapV2Factory(uniswapFactory_);
        defaultAmountIn                = defaultAmountIn_;
        windowSize                     = windowSize_;
        converterFeedScalingFactor     = converterFeedScalingFactor_;
        updateCallerReward             = updateCallerReward_;
        granularity                    = granularity_;
        // Populate the arrays with empty observations
        for (uint i = uniswapObservations.length; i < granularity; i++) {
            uniswapObservations.push();
            converterFeedObservations.push();
        }
    }

    // --- Administration ---
    /**
    * @notice Modify the converter feed address
    * @param parameter Name of the parameter to modify
    * @param data New parameter value
    **/
    function modifyParameters(bytes32 parameter, address data) external emitLog isAuthorized {
        require(data != address(0), "UniswapPriceFeedMedianizer/null-data");
        if (parameter == "converterFeed") {
          converterFeed = ConverterFeedLike(data);
        }
        else if (parameter == "treasury") {
      	  require(StabilityFeeTreasuryLike(data).systemCoin() != address(0), "UniswapPriceFeedMedianizer/treasury-coin-not-set");
      	  treasury = StabilityFeeTreasuryLike(data);
      	}
        else if (parameter == "targetToken") {
          targetToken = data;
          if (both(denominationToken != address(0), uniswapPair == address(0))) {
            uniswapPair = uniswapFactory.getPair(targetToken, denominationToken);
            require(uniswapPair != address(0), "UniswapPriceFeedMedianizer/null-uniswap-pair");
          }
        }
        else if (parameter == "denominationToken") {
          denominationToken = data;
          if (both(targetToken != address(0), uniswapPair == address(0))) {
            uniswapPair = uniswapFactory.getPair(targetToken, denominationToken);
            require(uniswapPair != address(0), "UniswapPriceFeedMedianizer/null-uniswap-pair");
          }
        }
        else revert("UniswapPriceFeedMedianizer/modify-unrecognized-param");
    }
    function modifyParameters(bytes32 parameter, uint256 data) external emitLog isAuthorized {
        if (parameter == "updateCallerReward") updateCallerReward = data;
        else revert("UniswapPriceFeedMedianizer/modify-unrecognized-param");
    }

    // --- General Utils ---
    function both(bool x, bool y) private pure returns (bool z) {
        assembly{ z := and(x, y)}
    }
    /**
    * @notice Returns the observations from the oldest epoch (at the beginning of the window) relative to the current time
    **/
    function getFirstObservationsInWindow()
      private view returns (UniswapObservation storage firstUniswapObservation, ConverterFeedObservation storage firstConverterFeedObservation) {
        uint8 observationIndex = observationIndexOf(now);
        // No overflow issue. If observationIndex + 1 overflows, result is still zero
        uint8 firstObservationIndex   = (observationIndex + 1) % granularity;
        firstUniswapObservation       = uniswapObservations[firstObservationIndex];
        firstConverterFeedObservation = converterFeedObservations[firstObservationIndex];
    }
    /**
    * @notice Calculate the median price using the latest observations and the latest Uniswap pair prices
    * @param price0Cumulative Cumulative price for the first token in the pair
    * @param price1Cumulative Cumulative price for the second token in the pair
    **/
    function getMedianPrice(uint256 price0Cumulative, uint256 price1Cumulative) private view returns (uint256) {
        (
          UniswapObservation storage firstUniswapObservation,
        ) = getFirstObservationsInWindow();

        uint timeElapsedSinceFirst = now - firstUniswapObservation.timestamp;
        // We can only fetch a brand new median price if there's been enough price data gathered
        if (both(timeElapsedSinceFirst <= windowSize, timeElapsedSinceFirst >= windowSize - periodSize * 2)) {
          (address token0,) = sortTokens(targetToken, denominationToken);
          uint256 uniswapAmountOut;
          if (token0 == targetToken) {
              uniswapAmountOut = uniswapComputeAmountOut(firstUniswapObservation.price0Cumulative, price0Cumulative, timeElapsedSinceFirst, defaultAmountIn);
          } else {
              uniswapAmountOut = uniswapComputeAmountOut(firstUniswapObservation.price1Cumulative, price1Cumulative, timeElapsedSinceFirst, defaultAmountIn);
          }

          return converterComputeAmountOut(uniswapAmountOut, timeElapsedSinceFirst);
        }

        return medianPrice;
    }
    /**
    * @notice Returns the index of the observation corresponding to the given timestamp
    * @param timestamp The timestamp for which we want to get the index for
    **/
    function observationIndexOf(uint timestamp) public view returns (uint8 index) {
        uint epochPeriod = timestamp / periodSize;
        return uint8(epochPeriod % granularity);
    }
    /**
    * @notice Get the observation list length
    **/
    function getObservationListLength() public view returns (uint256, uint256) {
        return (uniswapObservations.length, converterFeedObservations.length);
    }

    // --- Treasury Utils ---
    function rewardCaller(address feeReceiver) internal {
        if (either(address(treasury) == feeReceiver, feeReceiver == address(0))) return;
        if (either(address(treasury) == address(0), updateCallerReward == 0)) return;
        try treasury.pullFunds(feeReceiver, treasury.systemCoin(), updateCallerReward) {}
        catch(bytes memory revertReason) {}
    }

    // --- Uniswap Utils ---
    /**
    * @notice Given the Uniswap cumulative prices of the start and end of a period, and the length of the period, compute the average
    *         price in terms of how much amount out is received for the amount in.
    * @param priceCumulativeStart Old snapshot of the cumulative price of a token
    * @param priceCumulativeEnd New snapshot of the cumulative price of a token
    * @param timeElapsed Total time elapsed
    * @param amountIn Amount of target tokens we want to find the price for
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
    /**
    * @notice Calculate the price of an amount of tokens using the convertor price feed. Used after the contract determines
    *         the amount of Uniswap pair denomination tokens for defaultAmountIn target tokens
    * @param amountIn Amount of denomination tokens to calculate the price for
    **/
    function converterComputeAmountOut(
        uint256 amountIn,
        uint256 timeElapsedSinceFirst
    ) public view returns (uint256 amountOut) {
        uint256 priceAverage = converterPriceCumulative / timeElapsedSinceFirst;
        amountOut            = multiply(amountIn, priceAverage) / converterFeedScalingFactor;
    }

    // --- Core Logic ---
    /**
    * @notice Update the internal median price
    **/
    function updateResult(address feeReceiver) external {
        require(uniswapPair != address(0), "UniswapPriceFeedMedianizer/null-uniswap-pair");

        // Update the converter's median price first
        try converterFeed.updateResult() {}
        catch (bytes memory converterRevertReason) {
          emit FailedConverterFeedUpdate(converterRevertReason);
        }

        // Get the observation for the current period
        uint8 observationIndex         = observationIndexOf(now);
        uint256 timeElapsedSinceLatest = (now - uniswapObservations[observationIndex].timestamp);
        // We only want to commit updates once per period (i.e. windowSize / granularity)
        require(timeElapsedSinceLatest > periodSize, "UniswapPriceFeedMedianizer/not-enough-time-elapsed");

        // Update Uniswap pair
        try IUniswapV2Pair(uniswapPair).sync() {}
        catch (bytes memory uniswapRevertReason) {
          emit FailedUniswapPairSync(uniswapRevertReason);
        }
        // Get Uniswap cumulative prices
        (uint uniswapPrice0Cumulative, uint uniswapPrice1Cumulative,) = currentCumulativePrices(uniswapPair);

        // Add new observations
        updateObservations(observationIndex, uniswapPrice0Cumulative, uniswapPrice1Cumulative);

        // Calculate latest medianPrice
        medianPrice    = getMedianPrice(uniswapPrice0Cumulative, uniswapPrice1Cumulative);
        lastUpdateTime = uint32(now);

        // Reward caller
        rewardCaller(feeReceiver);
    }
    /**
    * @notice Push new observation data in the observation arrays
    * @param observationIndex Array index of the observations to update
    * @param uniswapPrice0Cumulative Latest cumulative price of the first token in a Uniswap pair
    * @param uniswapPrice1Cumulative Latest cumulative price of the second tokens in a Uniswap pair
    **/
    function updateObservations(uint8 observationIndex, uint256 timeElapsedSinceLatest, uint256 uniswapPrice0Cumulative, uint256 uniswapPrice1Cumulative) internal {
        UniswapObservation       storage latestUniswapObservation       = uniswapObservations[observationIndex];
        ConverterFeedObservation storage latestConverterFeedObservation = converterFeedObservations[observationIndex];

        // Add converter feed observation
        (uint256 priceFeedValue, bool hasValidValue) = converterFeed.getResultWithValidity();
        require(hasValidValue, "UniswapPriceFeedMedianizer/invalid-converter-price-feed");

        latestConverterFeedObservation.timestamp   = now;
        latestConverterFeedObservation.updateDelay = timeElapsedSinceLatest;
        latestConverterFeedObservation.price       = multiply(priceFeedValue, timeElapsedSinceLatest);

        // Add Uniswap observation
        latestUniswapObservation.timestamp        = now;
        latestUniswapObservation.price0Cumulative = uniswapPrice0Cumulative;
        latestUniswapObservation.price1Cumulative = uniswapPrice1Cumulative;

        (
          ,
          ConverterFeedObservation storage firstConverterFeedObservation
        ) = getFirstObservationsInWindow();
        converterPriceCumulative = addition(converterPriceCumulative, latestConverterFeedObservation.price);
        converterPriceCumulative = subtract(converterPriceCumulative, firstConverterFeedObservation.price);
    }

    // --- Getters ---
    /**
    * @notice Fetch the latest medianPrice or revert if is is null
    **/
    function read() external view returns (uint256) {
        require(medianPrice > 0, "UniswapPriceFeedMedianizer/invalid-price-feed");
        return medianPrice;
    }
    /**
    * @notice Fetch the latest medianPrice and whether it is null or not
    **/
    function getResultWithValidity() external view returns (uint256, bool) {
        return (medianPrice, medianPrice > 0);
    }
}
