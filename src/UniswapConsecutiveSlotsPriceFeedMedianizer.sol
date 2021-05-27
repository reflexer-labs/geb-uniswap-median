pragma solidity 0.6.7;

import "geb-treasury-reimbursement/math/GebMath.sol";

import './univ2/interfaces/IUniswapV2Factory.sol';
import './univ2/interfaces/IUniswapV2Pair.sol';

import './univ2/libs/UniswapV2Library.sol';
import './univ2/libs/UniswapV2OracleLibrary.sol';

abstract contract ConverterFeedLike {
    function getResultWithValidity() virtual external view returns (uint256,bool);
    function updateResult(address) virtual external;
}

abstract contract IncreasingRewardRelayerLike {
    function reimburseCaller(address) virtual external;
}

contract UniswapConsecutiveSlotsPriceFeedMedianizer is GebMath, UniswapV2Library, UniswapV2OracleLibrary {
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
        require(authorizedAccounts[msg.sender] == 1, "UniswapConsecutiveSlotsPriceFeedMedianizer/account-not-authorized");
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
        uint timeAdjustedPrice;
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

    uint8   public granularity;
    // When the price feed was last updated
    uint256 public lastUpdateTime;
    // Total number of updates
    uint256 public updates;
    /**
      The ideal amount of time over which the moving average should be computed, e.g. 24 hours.
      In practice it can and most probably will be different than the actual window over which the contract medianizes.
    **/
    uint256 public windowSize;
    // Maximum window size used to determine if the median is 'valid' (close to the real one) or not
    uint256 public maxWindowSize;
    // Stored for gas savings. Equals windowSize / granularity
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

    constructor(
      address converterFeed_,
      address uniswapFactory_,
      uint256 defaultAmountIn_,
      uint256 windowSize_,
      uint256 converterFeedScalingFactor_,
      uint256 maxWindowSize_,
      uint8   granularity_
    ) public {
        require(uniswapFactory_ != address(0), "UniswapConsecutiveSlotsPriceFeedMedianizer/null-uniswap-factory");
        require(granularity_ > 1, 'UniswapConsecutiveSlotsPriceFeedMedianizer/null-granularity');
        require(windowSize_ > 0, 'UniswapConsecutiveSlotsPriceFeedMedianizer/null-window-size');
        require(maxWindowSize_ > windowSize_, 'UniswapConsecutiveSlotsPriceFeedMedianizer/invalid-max-window-size');
        require(defaultAmountIn_ > 0, 'UniswapConsecutiveSlotsPriceFeedMedianizer/invalid-default-amount-in');
        require(converterFeedScalingFactor_ > 0, 'UniswapConsecutiveSlotsPriceFeedMedianizer/null-feed-scaling-factor');
        require(
            (periodSize = windowSize_ / granularity_) * granularity_ == windowSize_,
            'UniswapConsecutiveSlotsPriceFeedMedianizer/window-not-evenly-divisible'
        );

        authorizedAccounts[msg.sender] = 1;

        converterFeed                  = ConverterFeedLike(converterFeed_);
        uniswapFactory                 = IUniswapV2Factory(uniswapFactory_);
        defaultAmountIn                = defaultAmountIn_;
        windowSize                     = windowSize_;
        maxWindowSize                  = maxWindowSize_;
        converterFeedScalingFactor     = converterFeedScalingFactor_;
        granularity                    = granularity_;
        lastUpdateTime                 = now;
        validityFlag                   = 1;

        // Emit events
        emit AddAuthorization(msg.sender);
        emit ModifyParameters(bytes32("converterFeed"), converterFeed_);
        emit ModifyParameters(bytes32("maxWindowSize"), maxWindowSize_);
    }

    // --- Administration ---
    /**
    * @notice Modify address parameters
    * @param parameter Name of the parameter to modify
    * @param data New parameter value
    **/
    function modifyParameters(bytes32 parameter, address data) external isAuthorized {
        require(data != address(0), "UniswapConsecutiveSlotsPriceFeedMedianizer/null-data");
        if (parameter == "converterFeed") {
          require(data != address(0), "UniswapConsecutiveSlotsPriceFeedMedianizer/null-converter-feed");
          converterFeed = ConverterFeedLike(data);
        }
        else if (parameter == "targetToken") {
          require(uniswapPair == address(0), "UniswapConsecutiveSlotsPriceFeedMedianizer/pair-already-set");
          targetToken = data;
          if (denominationToken != address(0)) {
            uniswapPair = uniswapFactory.getPair(targetToken, denominationToken);
            require(uniswapPair != address(0), "UniswapConsecutiveSlotsPriceFeedMedianizer/null-uniswap-pair");
          }
        }
        else if (parameter == "denominationToken") {
          require(uniswapPair == address(0), "UniswapConsecutiveSlotsPriceFeedMedianizer/pair-already-set");
          denominationToken = data;
          if (targetToken != address(0)) {
            uniswapPair = uniswapFactory.getPair(targetToken, denominationToken);
            require(uniswapPair != address(0), "UniswapConsecutiveSlotsPriceFeedMedianizer/null-uniswap-pair");
          }
        }
        else if (parameter == "relayer") {
          relayer = IncreasingRewardRelayerLike(data);
        }
        else revert("UniswapConsecutiveSlotsPriceFeedMedianizer/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }
    /**
    * @notice Modify uint256 parameters
    * @param parameter Name of the parameter to modify
    * @param data New parameter value
    **/
    function modifyParameters(bytes32 parameter, uint256 data) external isAuthorized {
        if (parameter == "validityFlag") {
          require(either(data == 1, data == 0), "UniswapConsecutiveSlotsPriceFeedMedianizer/invalid-data");
          validityFlag = data;
        }
        else if (parameter == "defaultAmountIn") {
          require(data > 0, "UniswapConsecutiveSlotsPriceFeedMedianizer/invalid-default-amount-in");
          defaultAmountIn = data;
        }
        else if (parameter == "maxWindowSize") {
          require(data > windowSize, 'UniswapConsecutiveSlotsPriceFeedMedianizer/invalid-max-window-size');
          maxWindowSize = data;
        }
        else revert("UniswapConsecutiveSlotsPriceFeedMedianizer/modify-unrecognized-param");
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
    * @notice Returns the oldest observations (relative to the current index in the Uniswap/Converter lists)
    **/
    function getFirstObservationsInWindow()
      private view returns (UniswapObservation storage firstUniswapObservation, ConverterFeedObservation storage firstConverterFeedObservation) {
        uint256 earliestObservationIndex = earliestObservationIndex();
        firstUniswapObservation          = uniswapObservations[earliestObservationIndex];
        firstConverterFeedObservation    = converterFeedObservations[earliestObservationIndex];
    }
    /**
      @notice It returns the time passed since the first observation in the window
    **/
    function timeElapsedSinceFirstObservation() public view returns (uint256) {
        if (updates > 1) {
          (
            UniswapObservation storage firstUniswapObservation,
          ) = getFirstObservationsInWindow();
          return subtract(now, firstUniswapObservation.timestamp);
        }
        return 0;
    }
    /**
    * @notice Calculate the median price using the latest observations and the latest Uniswap pair prices
    * @param price0Cumulative Cumulative price for the first token in the pair
    * @param price1Cumulative Cumulative price for the second token in the pair
    **/
    function getMedianPrice(uint256 price0Cumulative, uint256 price1Cumulative) private view returns (uint256) {
        if (updates > 1) {
          (
            UniswapObservation storage firstUniswapObservation,
          ) = getFirstObservationsInWindow();

          uint timeSinceFirst = subtract(now, firstUniswapObservation.timestamp);
          (address token0,)   = sortTokens(targetToken, denominationToken);
          uint256 uniswapAmountOut;

          if (token0 == targetToken) {
              uniswapAmountOut = uniswapComputeAmountOut(
                firstUniswapObservation.price0Cumulative, price0Cumulative, timeSinceFirst, defaultAmountIn
              );
          } else {
              uniswapAmountOut = uniswapComputeAmountOut(
                firstUniswapObservation.price1Cumulative, price1Cumulative, timeSinceFirst, defaultAmountIn
              );
          }

          return converterComputeAmountOut(timeSinceFirst, uniswapAmountOut);
        }

        return medianPrice;
    }
    /**
    * @notice Returns the index of the earliest observation in the window
    **/
    function earliestObservationIndex() public view returns (uint256) {
        if (updates <= granularity) {
          return 0;
        }
        return subtract(updates, uint(granularity));
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
        require(timeElapsed > 0, "UniswapConsecutiveSlotsPriceFeedMedianizer/null-time-elapsed");
        // Overflow is desired
        uq112x112 memory priceAverage = uq112x112(
            uint224((priceCumulativeEnd - priceCumulativeStart) / timeElapsed)
        );
        amountOut = decode144(mul(priceAverage, amountIn));
    }

    // --- Converter Utils ---
    /**
    * @notice Calculate the price of an amount of tokens using the converter price feed as well as the time elapsed between
    *         the latest timestamp and the timestamp of the earliest observation in the window.
    *         Used after the contract determines the amount of Uniswap pair denomination tokens for amountIn target tokens
    * @param timeElapsed Time elapsed between now and the earliest observation in the window.
    * @param amountIn Amount of denomination tokens to calculate the price for
    **/
    function converterComputeAmountOut(
        uint256 timeElapsed,
        uint256 amountIn
    ) public view returns (uint256 amountOut) {
        require(timeElapsed > 0, "UniswapConsecutiveSlotsPriceFeedMedianizer/null-time-elapsed");
        uint256 priceAverage = converterPriceCumulative / timeElapsed;
        amountOut            = multiply(amountIn, priceAverage) / converterFeedScalingFactor;
    }

    // --- Core Logic ---
    /**
    * @notice Update the internal median price
    **/
    function updateResult(address feeReceiver) external {
        require(address(relayer) != address(0), "UniswapConsecutiveSlotsPriceFeedMedianizer/null-relayer");
        require(uniswapPair != address(0), "UniswapConsecutiveSlotsPriceFeedMedianizer/null-uniswap-pair");

        // Get final fee receiver
        address finalFeeReceiver = (feeReceiver == address(0)) ? msg.sender : feeReceiver;

        // Update the converter's median price first
        try converterFeed.updateResult(finalFeeReceiver) {}
        catch (bytes memory converterRevertReason) {
          emit FailedConverterFeedUpdate(converterRevertReason);
        }

        // Get the observation for the current period
        uint256 timeElapsedSinceLatest = (uniswapObservations.length == 0) ?
          subtract(now, lastUpdateTime) : subtract(now, uniswapObservations[uniswapObservations.length - 1].timestamp);
        // We only want to commit updates once per period (i.e. windowSize / granularity)
        if (uniswapObservations.length > 0) {
          require(timeElapsedSinceLatest >= periodSize, "UniswapConsecutiveSlotsPriceFeedMedianizer/not-enough-time-elapsed");
        }

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
        updateObservations(timeElapsedSinceLatest, uniswapPrice0Cumulative, uniswapPrice1Cumulative);

        // Calculate latest medianPrice
        medianPrice    = getMedianPrice(uniswapPrice0Cumulative, uniswapPrice1Cumulative);
        lastUpdateTime = now;
        updates        = addition(updates, 1);

        emit UpdateResult(medianPrice, lastUpdateTime);

        // Reward caller
        relayer.reimburseCaller(finalFeeReceiver);
    }
    /**
    * @notice Push new observation data in the observation arrays
    * @param timeElapsedSinceLatest Time elapsed between now and the earliest observation in the window
    * @param uniswapPrice0Cumulative Latest cumulative price of the first token in a Uniswap pair
    * @param uniswapPrice1Cumulative Latest cumulative price of the second tokens in a Uniswap pair
    **/
    function updateObservations(
      uint256 timeElapsedSinceLatest,
      uint256 uniswapPrice0Cumulative,
      uint256 uniswapPrice1Cumulative
    ) internal {
        // Add converter feed observation
        (uint256 priceFeedValue, bool hasValidValue) = converterFeed.getResultWithValidity();
        require(hasValidValue, "UniswapConsecutiveSlotsPriceFeedMedianizer/invalid-converter-price-feed");
        uint256 newTimeAdjustedPrice = multiply(priceFeedValue, timeElapsedSinceLatest);

        // Add converter observation
        converterFeedObservations.push(ConverterFeedObservation(now, newTimeAdjustedPrice));
        // Add Uniswap observation
        uniswapObservations.push(UniswapObservation(now, uniswapPrice0Cumulative, uniswapPrice1Cumulative));

        // Add the new update
        converterPriceCumulative = addition(converterPriceCumulative, newTimeAdjustedPrice);

        // Subtract the earliest update
        if (updates >= granularity) {
          (
            ,
            ConverterFeedObservation storage firstConverterFeedObservation
          ) = getFirstObservationsInWindow();
          converterPriceCumulative = subtract(converterPriceCumulative, firstConverterFeedObservation.timeAdjustedPrice);
        }
    }

    // --- Getters ---
    /**
    * @notice Fetch the latest medianPrice or revert if is is null
    **/
    function read() external view returns (uint256) {
        require(
          both(both(both(medianPrice > 0, updates > granularity), timeElapsedSinceFirstObservation() <= maxWindowSize), validityFlag == 1),
          "UniswapConsecutiveSlotsPriceFeedMedianizer/invalid-price-feed"
        );
        return medianPrice;
    }
    /**
    * @notice Fetch the latest medianPrice and whether it is null or not
    **/
    function getResultWithValidity() external view returns (uint256, bool) {
        return (
          medianPrice,
          both(both(both(medianPrice > 0, updates > granularity), timeElapsedSinceFirstObservation() <= maxWindowSize), validityFlag == 1)
        );
    }
}
