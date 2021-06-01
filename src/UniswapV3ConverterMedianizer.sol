pragma solidity 0.6.7;

import "geb-treasury-reimbursement/math/GebMath.sol";

import './univ3/interfaces/IUniswapV3Factory.sol';
import './univ3/interfaces/IUniswapV3Pool.sol';
import './univ3/libraries/TickMath.sol';
import './univ3/libraries/FullMath.sol';

abstract contract ConverterFeedLike {
    function getResultWithValidity() virtual external view returns (uint256,bool);
    function updateResult(address) virtual external;
}

abstract contract IncreasingRewardRelayerLike {
    function reimburseCaller(address) virtual external;
}

contract UniswapV3ConverterMedianizer is GebMath {
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
        require(authorizedAccounts[msg.sender] == 1, "UniswapV3ConverterMedianizer/account-not-authorized");
        _;
    }

    // --- Observations ---
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
    // The pool to read price data from
    IUniswapV3Pool       public uniswapPool;

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
    uint32 public windowSize;
    // Maximum window size used to determine if the median is 'valid' (close to the real one) or not
    uint256 public maxWindowSize;
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

    constructor(
      address converterFeed_,
      address uniswapPool_,
      uint256 defaultAmountIn_,
      uint32 windowSize_,
      uint256 converterFeedScalingFactor_,
      uint256 maxWindowSize_,
      uint8   granularity_
    ) public {
        require(uniswapPool_ != address(0), "UniswapV3ConverterMedianizer/null-uniswap-factory");
        require(granularity_ > 1, 'UniswapV3ConverterMedianizer/null-granularity');
        require(windowSize_ > 0, 'UniswapV3ConverterMedianizer/null-window-size');
        require(maxWindowSize_ > windowSize_, 'UniswapV3ConverterMedianizer/invalid-max-window-size');
        require(defaultAmountIn_ > 0, 'UniswapV3ConverterMedianizer/invalid-default-amount-in');
        require(converterFeedScalingFactor_ > 0, 'UniswapV3ConverterMedianizer/null-feed-scaling-factor');
        require(
            (periodSize = windowSize_ / granularity_) * granularity_ == windowSize_,
            'UniswapConverterBasicAveragePriceFeedMedianizer/window-not-evenly-divisible'
        );

        authorizedAccounts[msg.sender] = 1;

        converterFeed                  = ConverterFeedLike(converterFeed_);
        uniswapPool                    = IUniswapV3Pool(uniswapPool_);
        defaultAmountIn                = defaultAmountIn_;
        windowSize                     = windowSize_;
        maxWindowSize                  = maxWindowSize_;
        converterFeedScalingFactor     = converterFeedScalingFactor_;
        granularity                    = granularity_;
        validityFlag                   = 1;

        // Populate the arrays with empty observations
        for (uint i = converterFeedObservations.length; i < granularity; i++) {
            converterFeedObservations.push();
        }

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
        require(data != address(0), "UniswapV3ConverterMedianizer/null-data");
        if (parameter == "converterFeed") {
          require(data != address(0), "UniswapV3ConverterMedianizer/null-converter-feed");
          converterFeed = ConverterFeedLike(data);
        }
        else if (parameter == "targetToken") {
          require(targetToken == address(0), "UniswapV3ConverterMedianizer/target-already-set");
          
          require(data == uniswapPool.token0() || data == uniswapPool.token1(),"UniswapV3ConverterMedianizer/target-not-from-pool");
          targetToken = data;
          if(targetToken == uniswapPool.token0()) 
            denominationToken = uniswapPool.token1();
          else {
            denominationToken = uniswapPool.token0();
          }
        }
        else if (parameter == "relayer") {
          relayer = IncreasingRewardRelayerLike(data);
        }
        else revert("UniswapV3ConverterMedianizer/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }
    /**
    * @notice Modify uint256 parameters
    * @param parameter Name of the parameter to modify
    * @param data New parameter value
    **/
    function modifyParameters(bytes32 parameter, uint256 data) external isAuthorized {
        if (parameter == "validityFlag") {
          require(either(data == 1, data == 0), "UniswapV3ConverterMedianizer/invalid-data");
          validityFlag = data;
        }
        else if (parameter == "defaultAmountIn") {
          require(data > 0, "UniswapV3ConverterMedianizer/invalid-default-amount-in");
          defaultAmountIn = data;
        }
        else if (parameter == "maxWindowSize") {
          require(data > windowSize, 'UniswapV3ConverterMedianizer/invalid-max-window-size');
          maxWindowSize = data;
        }
        else revert("UniswapV3ConverterMedianizer/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }

    // --- General Utils --
    function either(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := or(x, y)}
    }
    function both(bool x, bool y) private pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    /**
    * @notice Returns the observations from the oldest epoch (at the beginning of the window) relative to the current time
    **/
    function getTimeElapsedSinceFirstObservationInWindow()
      private view returns (uint256 time) {
        uint8 firtObservationIndex = uint8(addition(updates, 1) % granularity);
        time = subtract(now, converterFeedObservations[firtObservationIndex].timestamp);
    }

    // --- Converter Utils ---
    /**
    * @notice Calculate the price of an amount of tokens using the convertor price feed. Used after the contract determines
    *         the amount of Uniswap pair denomination tokens for amountIn target tokens
    * @param amountIn Amount of denomination tokens to calculate the price for
    **/
    function converterComputeAmountOut(
        uint256 timeElapsed,
        uint256 amountIn
    ) public returns (uint256 amountOut) {
        require(timeElapsed > 0, "UniswapConsecutiveSlotsPriceFeedMedianizer/null-time-elapsed");
        if(updates >= granularity) {
          uint256 priceAverage = converterPriceCumulative / timeElapsed;
          amountOut           = multiply(priceAverage,amountIn) / converterFeedScalingFactor;
        } 
    }

    // --- Core Logic ---
    /**
    * @notice Update the internal median price
    **/
    function updateResult(address feeReceiver) external {
        require(address(relayer) != address(0), "UniswapV3ConverterMedianizer/null-relayer");
        require(targetToken != address(0), "UniswapV3ConverterMedianizer/null-target-token");

        // Get final fee receiver
        address finalFeeReceiver = (feeReceiver == address(0)) ? msg.sender : feeReceiver;

        // Update the converter's median price first
        try converterFeed.updateResult(finalFeeReceiver) {}
        catch (bytes memory converterRevertReason) {
          emit FailedConverterFeedUpdate(converterRevertReason);
        }

        // If it's the first reading, we have to set time elapsed manually
        uint256 timeSinceLast = updates == 0 ? periodSize :subtract(now, lastUpdateTime);

        // We only want to commit updates once per period (i.e. windowSize / granularity)
        require(timeSinceLast>= periodSize, "UniswapV3ConverterMedianizer/not-enough-time-elapsed");

        // Increase updates and get the index to write to
        updates = addition(updates, 1);
        uint8 observationIndex = uint8(updates % granularity);
        
        updateObservations(observationIndex, timeSinceLast);

        if (updates >= granularity ) medianPrice = getMedianPrice();
        lastUpdateTime  = now;
        
        emit UpdateResult(medianPrice, lastUpdateTime);

        // Reward caller
        relayer.reimburseCaller(finalFeeReceiver);
}

/**
    * @notice Push new observation data in the observation arrays
    * @param observationIndex Array index of the observations to update
    **/
    function updateObservations(uint8 observationIndex, uint256 timeSinceLastObservation) internal {
        ConverterFeedObservation storage latestConverterFeedObservation = converterFeedObservations[observationIndex];

        // this value will be overwitten, so we need to first decrease the running amount
        if (updates >= granularity) {
            converterPriceCumulative = subtract(converterPriceCumulative, latestConverterFeedObservation.timeAdjustedPrice);
        }

        // Add converter feed observation
        (uint256 priceFeedValue, bool hasValidValue) = converterFeed.getResultWithValidity();
        require(hasValidValue, "UniswapConverterBasicAveragePriceFeedMedianizer/invalid-converter-price-feed");

        // Add converter observation
        latestConverterFeedObservation.timestamp          = now;
        latestConverterFeedObservation.timeAdjustedPrice  = multiply(priceFeedValue, timeSinceLastObservation);

        converterPriceCumulative = addition(converterPriceCumulative, latestConverterFeedObservation.timeAdjustedPrice);
    }

    function getMedianPrice() private returns (uint256 meanPrice) {
        require(targetToken != address(0), "UniswapV3ConverterMedianizer/null-target-token");
        uint256 timeElapsed      = getTimeElapsedSinceFirstObservationInWindow();
        int24 medianTick         = getUniswapMeanTick(windowSize);
        uint256 uniswapAmountOut = getQuoteAtTick(medianTick, uint128(defaultAmountIn),targetToken, denominationToken);
        meanPrice               = converterComputeAmountOut(timeElapsed, uniswapAmountOut);
    }

    /// @notice Fetches time-weighted average tick using Uniswap V3 oracle
    /// @param period Number of seconds in the past to start calculating time-weighted average
    /// @return timeWeightedAverageTick The time-weighted average tick from (block.timestamp - period) to block.timestamp
    function getUniswapMeanTick(uint32 period) internal view returns (int24 timeWeightedAverageTick) {
        require(period != 0, 'UniswapV3ConverterMedianizer/invalid-period');

        uint32[] memory secondAgos = new uint32[](2);
        secondAgos[0] = period;
        secondAgos[1] = 0;

        (int56[] memory tickCumulatives, ) = IUniswapV3Pool(uniswapPool).observe(secondAgos);
        int56 tickCumulativesDelta         = tickCumulatives[1] - tickCumulatives[0];

        timeWeightedAverageTick           = int24(tickCumulativesDelta / period);

        // Always round to negative infinity
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % period != 0)) timeWeightedAverageTick--;
    }

    /// @notice Given a tick and a token amount, calculates the amount of token received in exchange
    /// @param tick Tick value used to calculate the quote
    /// @param baseAmount Amount of token to be converted
    /// @param baseToken Address of an ERC20 token contract used as the baseAmount denomination
    /// @param quoteToken Address of an ERC20 token contract used as the quoteAmount denomination
    /// @return quoteAmount Amount of quoteToken received for baseAmount of baseToken
    function getQuoteAtTick(
        int24 tick,
        uint128 baseAmount,
        address baseToken,
        address quoteToken
    ) internal pure returns (uint256 quoteAmount) {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);

        uint128 maxUint = uint128(0-1);

        // Calculate quoteAmount with better precision if it doesn't overflow when multiplied by itself
        if (sqrtRatioX96 <= maxUint) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }

    // --- Getters ---
    /**
    * @notice Fetch the latest medianPrice or revert if is is null
    **/
    function read() external returns (uint256) {
        uint256 value = getMedianPrice();
        require(
          both(both(both(value > 0, updates >= granularity), validityFlag == 1),getTimeElapsedSinceFirstObservationInWindow()<= maxWindowSize),
          "UniswapV3ConverterMedianizer/invalid-price-feed"
        );
        return value;
    }
    /**
    * @notice Fetch the latest medianPrice and whether it is null or not
    **/
    function getResultWithValidity() external view returns (uint256, bool) {
        return (medianPrice, both(both(medianPrice > 0, updates >= granularity), validityFlag == 1));
    }
}
