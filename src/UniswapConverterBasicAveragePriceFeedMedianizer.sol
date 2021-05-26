pragma solidity 0.6.7;

import "geb-treasury-reimbursement/math/GebMath.sol";

import './uni/interfaces/IUniswapV2Factory.sol';
import './uni/interfaces/IUniswapV2Pair.sol';

import './uni/libs/UniswapV2Library.sol';
import './uni/libs/UniswapV2OracleLibrary.sol';

abstract contract ConverterFeedLike {
    function getResultWithValidity() virtual external view returns (uint256,bool);
    function updateResult(address) virtual external;
}

abstract contract IncreasingRewardRelayerLike {
    function reimburseCaller(address) virtual external;
}

contract UniswapConverterBasicAveragePriceFeedMedianizer is GebMath, UniswapV2Library, UniswapV2OracleLibrary {
    // --- Auth ---
    mapping (address => uint) public authorizedAccounts;
    /**
     * @notice Add auth to an account
     * @param account Account to add auth to
     */
    function addAuthorization(address account) virtual external isAuthorized {
        authorizedAccounts[account] = 1;
        emit AddAuthorization(account);
    }
    /**
     * @notice Remove auth from an account
     * @param account Account to remove auth from
     */
    function removeAuthorization(address account) virtual external isAuthorized {
        authorizedAccounts[account] = 0;
        emit RemoveAuthorization(account);
    }
    /**
    * @notice Checks whether msg.sender can call an authed function
    **/
    modifier isAuthorized {
        require(authorizedAccounts[msg.sender] == 1, "UniswapConverterBasicAveragePriceFeedMedianizer/account-not-authorized");
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
        uint price;
    }

    // --- Uniswap Vars ---
    // Default amount of targetToken used when calculating the denominationToken output
    uint256              public defaultAmountIn;
    // Token for which the contract calculates the medianPrice for
    address              public targetToken;
    // Pair token from the Uniswap pair
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
    uint256 public lastUpdateTime;
    // Total number of updates
    uint256 public updates;
    // The desired amount of time over which the moving average should be computed, e.g. 24 hours
    uint256 public windowSize;
    // This is redundant with granularity and windowSize, but stored for gas savings & informational purposes.
    uint256 public periodSize;
    // This is the denominator for computing
    uint256 public converterFeedScalingFactor;
    // The last computed median price
    uint256 private medianPrice;
    // Manual flag that can be set by governance and indicates if a result is valid or not
    uint256 public validityFlag;

    // Contract relaying the SF reward to addresses that update this oracle
    IncreasingRewardRelayerLike public relayer;

    // --- Events ---
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
    event ModifyParameters(
      bytes32 parameter,
      address addr
    );
    event ModifyParameters(
      bytes32 parameter,
      uint256 val
    );
    event UpdateResult(uint256 medianPrice, uint256 lastUpdateTime);
    event FailedConverterFeedUpdate(bytes reason);
    event FailedUniswapPairSync(bytes reason);
    event FailedReimburseCaller(bytes revertReason);

    constructor(
      address converterFeed_,
      address uniswapFactory_,
      uint256 defaultAmountIn_,
      uint256 windowSize_,
      uint256 converterFeedScalingFactor_,
      uint8   granularity_
    ) public {
        require(uniswapFactory_ != address(0), "UniswapConverterBasicAveragePriceFeedMedianizer/null-uniswap-factory");
        require(granularity_ > 1, 'UniswapConverterBasicAveragePriceFeedMedianizer/null-granularity');
        require(windowSize_ > 0, 'UniswapConverterBasicAveragePriceFeedMedianizer/null-window-size');
        require(defaultAmountIn_ > 0, 'UniswapConverterBasicAveragePriceFeedMedianizer/invalid-default-amount-in');
        require(converterFeedScalingFactor_ > 0, 'UniswapConverterBasicAveragePriceFeedMedianizer/null-feed-scaling-factor');
        require(
            (periodSize = windowSize_ / granularity_) * granularity_ == windowSize_,
            'UniswapConverterBasicAveragePriceFeedMedianizer/window-not-evenly-divisible'
        );

        authorizedAccounts[msg.sender] = 1;

        converterFeed                  = ConverterFeedLike(converterFeed_);
        uniswapFactory                 = IUniswapV2Factory(uniswapFactory_);
        defaultAmountIn                = defaultAmountIn_;
        windowSize                     = windowSize_;
        converterFeedScalingFactor     = converterFeedScalingFactor_;
        granularity                    = granularity_;
        validityFlag                   = 1;

        // Populate the arrays with empty observations
        for (uint i = uniswapObservations.length; i < granularity; i++) {
            uniswapObservations.push();
            converterFeedObservations.push();
        }

        // Emit events
        emit AddAuthorization(msg.sender);
        emit ModifyParameters(bytes32("converterFeed"), converterFeed_);
    }

    // --- Administration ---
    /**
    * @notice Modify address parameters
    * @param parameter Name of the parameter to modify
    * @param data New parameter value
    **/
    function modifyParameters(bytes32 parameter, address data) external isAuthorized {
        require(data != address(0), "UniswapConverterBasicAveragePriceFeedMedianizer/null-data");
        if (parameter == "converterFeed") {
          require(data != address(0), "UniswapConverterBasicAveragePriceFeedMedianizer/null-converter-feed");
          converterFeed = ConverterFeedLike(data);
        }
        else if (parameter == "targetToken") {
          require(uniswapPair == address(0), "UniswapConverterBasicAveragePriceFeedMedianizer/pair-already-set");
          targetToken = data;
          if (denominationToken != address(0)) {
            uniswapPair = uniswapFactory.getPair(targetToken, denominationToken);
            require(uniswapPair != address(0), "UniswapConverterBasicAveragePriceFeedMedianizer/null-uniswap-pair");
          }
        }
        else if (parameter == "denominationToken") {
          require(uniswapPair == address(0), "UniswapConverterBasicAveragePriceFeedMedianizer/pair-already-set");
          denominationToken = data;
          if (targetToken != address(0)) {
            uniswapPair = uniswapFactory.getPair(targetToken, denominationToken);
            require(uniswapPair != address(0), "UniswapConverterBasicAveragePriceFeedMedianizer/null-uniswap-pair");
          }
        }
        else if (parameter == "relayer") {
          relayer = IncreasingRewardRelayerLike(data);
        }
        else revert("UniswapConverterBasicAveragePriceFeedMedianizer/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }
    /**
    * @notice Modify uint256 parameters
    * @param parameter Name of the parameter to modify
    * @param data New parameter value
    **/
    function modifyParameters(bytes32 parameter, uint256 data) external isAuthorized {
        if (parameter == "validityFlag") {
          require(either(data == 1, data == 0), "UniswapConverterBasicAveragePriceFeedMedianizer/invalid-data");
          validityFlag = data;
        }
        else if (parameter == "defaultAmountIn") {
          require(data > 0, "UniswapConsecutiveSlotsPriceFeedMedianizer/invalid-default-amount-in");
          defaultAmountIn = data;
        }
        else revert("UniswapConverterBasicAveragePriceFeedMedianizer/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }

    // --- General Utils ---
    function either(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := or(x, y)}
    }
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

        uint timeElapsedSinceFirstUniObservation = subtract(now, firstUniswapObservation.timestamp);
        // We can only fetch a brand new median price if there's been enough price data gathered
        if (both(timeElapsedSinceFirstUniObservation <= windowSize, timeElapsedSinceFirstUniObservation >= windowSize - periodSize * 2)) {
          (address token0,) = sortTokens(targetToken, denominationToken);
          uint256 uniswapAmountOut;
          if (token0 == targetToken) {
              uniswapAmountOut = uniswapComputeAmountOut(firstUniswapObservation.price0Cumulative, price0Cumulative, timeElapsedSinceFirstUniObservation, defaultAmountIn);
          } else {
              uniswapAmountOut = uniswapComputeAmountOut(firstUniswapObservation.price1Cumulative, price1Cumulative, timeElapsedSinceFirstUniObservation, defaultAmountIn);
          }

          return converterComputeAmountOut(uniswapAmountOut);
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
        require(priceCumulativeEnd >= priceCumulativeStart, "UniswapConverterBasicAveragePriceFeedMedianizer/invalid-end-cumulative");
        require(timeElapsed > 0, "UniswapConverterBasicAveragePriceFeedMedianizer/null-time-elapsed");
        // Overflow is desired
        uq112x112 memory priceAverage = uq112x112(
            uint224((priceCumulativeEnd - priceCumulativeStart) / timeElapsed)
        );
        amountOut = decode144(mul(priceAverage, amountIn));
    }

    // --- Converter Utils ---
    /**
    * @notice Calculate the price of an amount of tokens using the convertor price feed. Used after the contract determines
    *         the amount of Uniswap pair denomination tokens for amountIn target tokens
    * @param amountIn Amount of denomination tokens to calculate the price for
    **/
    function converterComputeAmountOut(
        uint256 amountIn
    ) public view returns (uint256 amountOut) {
        uint256 priceAverage = converterPriceCumulative / uint(granularity);
        amountOut            = multiply(amountIn, priceAverage) / converterFeedScalingFactor;
    }

    // --- Core Logic ---
    /**
    * @notice Update the internal median price
    **/
    function updateResult(address feeReceiver) external {
        require(address(relayer) != address(0), "UniswapConverterBasicAveragePriceFeedMedianizer/null-relayer");
        require(uniswapPair != address(0), "UniswapConverterBasicAveragePriceFeedMedianizer/null-uniswap-pair");

        // Get final fee receiver
        address finalFeeReceiver = (feeReceiver == address(0)) ? msg.sender : feeReceiver;

        // Update the converter's median price first
        try converterFeed.updateResult(finalFeeReceiver) {}
        catch (bytes memory converterRevertReason) {
          emit FailedConverterFeedUpdate(converterRevertReason);
        }

        // Get the observation for the current period
        uint8 observationIndex         = observationIndexOf(now);
        uint256 timeElapsedSinceLatest = subtract(now, uniswapObservations[observationIndex].timestamp);
        // We only want to commit updates once per period (i.e. windowSize / granularity)
        require(timeElapsedSinceLatest > periodSize, "UniswapConverterBasicAveragePriceFeedMedianizer/not-enough-time-elapsed");

        // Update Uniswap pair
        try IUniswapV2Pair(uniswapPair).sync() {}
        catch (bytes memory uniswapRevertReason) {
          emit FailedUniswapPairSync(uniswapRevertReason);
        }

        // Get the last update time used when calculating the reward
        uint256 rewardCalculationLastUpdateTime = (uniswapObservations.length == 0) ? 0 : lastUpdateTime;

        // Get Uniswap cumulative prices
        (uint uniswapPrice0Cumulative, uint uniswapPrice1Cumulative,) = currentCumulativePrices(uniswapPair);

        // Add new observations
        updateObservations(observationIndex, uniswapPrice0Cumulative, uniswapPrice1Cumulative);

        // Calculate latest medianPrice
        medianPrice    = getMedianPrice(uniswapPrice0Cumulative, uniswapPrice1Cumulative);
        lastUpdateTime = now;
        updates        = addition(updates, 1);

        emit UpdateResult(medianPrice, lastUpdateTime);

        // Try to reward the caller
        try relayer.reimburseCaller(finalFeeReceiver) {
        } catch (bytes memory revertReason) {
          emit FailedReimburseCaller(revertReason);
        }
    }
    /**
    * @notice Push new observation data in the observation arrays
    * @param observationIndex Array index of the observations to update
    * @param uniswapPrice0Cumulative Latest cumulative price of the first token in a Uniswap pair
    * @param uniswapPrice1Cumulative Latest cumulative price of the second tokens in a Uniswap pair
    **/
    function updateObservations(uint8 observationIndex, uint256 uniswapPrice0Cumulative, uint256 uniswapPrice1Cumulative) internal {
        UniswapObservation       storage latestUniswapObservation       = uniswapObservations[observationIndex];
        ConverterFeedObservation storage latestConverterFeedObservation = converterFeedObservations[observationIndex];

        // Add converter feed observation
        (uint256 priceFeedValue, bool hasValidValue) = converterFeed.getResultWithValidity();
        require(hasValidValue, "UniswapConverterBasicAveragePriceFeedMedianizer/invalid-converter-price-feed");

        // Add converter observation
        latestConverterFeedObservation.timestamp   = now;
        latestConverterFeedObservation.price       = priceFeedValue;

        // Add Uniswap observation
        latestUniswapObservation.timestamp        = now;
        latestUniswapObservation.price0Cumulative = uniswapPrice0Cumulative;
        latestUniswapObservation.price1Cumulative = uniswapPrice1Cumulative;

        converterPriceCumulative = addition(converterPriceCumulative, latestConverterFeedObservation.price);

        if (updates >= granularity) {
          (
            ,
            ConverterFeedObservation storage firstConverterFeedObservation
          ) = getFirstObservationsInWindow();
          converterPriceCumulative = subtract(converterPriceCumulative, firstConverterFeedObservation.price);
        }
    }

    // --- Getters ---
    /**
    * @notice Fetch the latest medianPrice or revert if is is null
    **/
    function read() external view returns (uint256) {
        require(
          both(both(medianPrice > 0, updates >= granularity), validityFlag == 1),
          "UniswapConverterBasicAveragePriceFeedMedianizer/invalid-price-feed"
        );
        return medianPrice;
    }
    /**
    * @notice Fetch the latest medianPrice and whether it is null or not
    **/
    function getResultWithValidity() external view returns (uint256, bool) {
        return (medianPrice, both(both(medianPrice > 0, updates >= granularity), validityFlag == 1));
    }
}
