pragma solidity ^0.6.7;

import './uni/interfaces/IUniswapV2Factory.sol';
import './uni/interfaces/IUniswapV2Pair.sol';

import './uni/libs/UniswapV2Library.sol';
import './uni/libs/UniswapV2OracleLibrary.sol';

abstract contract ConverterFeedLike {
    function getResultWithValidity() virtual external view returns (uint256,bool);
    function updateResult(address) virtual external;
}
abstract contract StabilityFeeTreasuryLike {
    function getAllowance(address) virtual external view returns (uint, uint);
    function systemCoin() virtual external view returns (address);
    function pullFunds(address, address, uint) virtual external;
}

contract UniswapConsecutiveSlotsPriceFeedMedianizer is UniswapV2Library, UniswapV2OracleLibrary {
    // --- Auth ---
    mapping (address => uint) public authorizedAccounts;
    /**
     * @notice Add auth to an account
     * @param account Account to add auth to
     */
    function addAuthorization(address account) external isAuthorized {
        authorizedAccounts[account] = 1;
        emit AddAuthorization(account);
    }
    /**
     * @notice Remove auth from an account
     * @param account Account to remove auth from
     */
    function removeAuthorization(address account) external isAuthorized {
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
    // The desired amount of time over which the moving average should be computed, e.g. 24 hours
    uint256 public windowSize;
    // This is redundant with granularity and windowSize, but stored for gas savings & informational purposes.
    uint256 public periodSize;
    // This is the denominator for computing
    uint256 public converterFeedScalingFactor;
    // The last computed median price
    uint256 private medianPrice;
    // Starting reward for the feeReceiver
    uint256 public baseUpdateCallerReward;          // [wad]
    // Max possible reward for the feeReceiver
    uint256 public maxUpdateCallerReward;           // [wad]
    // Max delay taken into consideration when calculating the adjusted reward
    uint256 public maxRewardIncreaseDelay;
    // Rate applied to baseUpdateCallerReward every extra second passed beyond periodSize seconds since the last update call
    uint256 public perSecondCallerRewardIncrease;   // [ray]
    // SF treasury contract
    StabilityFeeTreasuryLike  public treasury;

    // --- Events ---
    event ModifyParameters(bytes32 parameter, address data);
    event ModifyParameters(bytes32 parameter, uint256 data);
    event UpdateResult(uint256 medianPrice, uint256 lastUpdateTime);
    event FailedConverterFeedUpdate(bytes reason);
    event FailedUniswapPairSync(bytes reason);
    event FailRewardCaller(bytes revertReason, address feeReceiver, uint256 amount);
    event RewardCaller(address feeReceiver, uint256 amount);
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);

    constructor(
      address converterFeed_,
      address uniswapFactory_,
      address treasury_,
      uint256 defaultAmountIn_,
      uint256 windowSize_,
      uint256 converterFeedScalingFactor_,
      uint256 baseUpdateCallerReward_,
      uint256 maxUpdateCallerReward_,
      uint256 perSecondCallerRewardIncrease_,
      uint8   granularity_
    ) public {
        require(uniswapFactory_ != address(0), "UniswapConsecutiveSlotsPriceFeedMedianizer/null-uniswap-factory");
        require(granularity_ > 1, 'UniswapConsecutiveSlotsPriceFeedMedianizer/null-granularity');
        require(windowSize_ > 0, 'UniswapConsecutiveSlotsPriceFeedMedianizer/null-window-size');
        require(defaultAmountIn_ > 0, 'UniswapConsecutiveSlotsPriceFeedMedianizer/invalid-default-amount-in');
        require(converterFeedScalingFactor_ > 0, 'UniswapConsecutiveSlotsPriceFeedMedianizer/null-feed-scaling-factor');
        require(
            (periodSize = windowSize_ / granularity_) * granularity_ == windowSize_,
            'UniswapConsecutiveSlotsPriceFeedMedianizer/window-not-evenly-divisible'
        );
        require(maxUpdateCallerReward_ > baseUpdateCallerReward_, "UniswapConsecutiveSlotsPriceFeedMedianizer/invalid-max-reward");
        require(perSecondCallerRewardIncrease_ >= RAY, "UniswapConsecutiveSlotsPriceFeedMedianizer/invalid-reward-increase");
        if (address(treasury_) != address(0)) {
          require(StabilityFeeTreasuryLike(treasury_).systemCoin() != address(0), "UniswapConsecutiveSlotsPriceFeedMedianizer/treasury-coin-not-set");
        }
        authorizedAccounts[msg.sender] = 1;
        converterFeed                  = ConverterFeedLike(converterFeed_);
        treasury                       = StabilityFeeTreasuryLike(treasury_);
        uniswapFactory                 = IUniswapV2Factory(uniswapFactory_);
        defaultAmountIn                = defaultAmountIn_;
        windowSize                     = windowSize_;
        converterFeedScalingFactor     = converterFeedScalingFactor_;
        baseUpdateCallerReward         = baseUpdateCallerReward_;
        maxUpdateCallerReward          = maxUpdateCallerReward_;
        perSecondCallerRewardIncrease  = perSecondCallerRewardIncrease_;
        granularity                    = granularity_;
        maxRewardIncreaseDelay         = uint(-1);
        lastUpdateTime                 = now;
        // Emit events
        emit AddAuthorization(msg.sender);
        emit ModifyParameters(bytes32("treasury"), treasury_);
        emit ModifyParameters(bytes32("converterFeed"), converterFeed_);
        emit ModifyParameters(bytes32("baseUpdateCallerReward"), baseUpdateCallerReward);
        emit ModifyParameters(bytes32("maxUpdateCallerReward"), maxUpdateCallerReward);
        emit ModifyParameters(bytes32("perSecondCallerRewardIncrease"), perSecondCallerRewardIncrease);
    }

    // --- Math ---
    uint256 internal constant WAD = 10 ** 18;
    uint256 internal constant RAY = 10 ** 27;
    function minimum(uint x, uint y) internal pure returns (uint z) {
        z = (x <= y) ? x : y;
    }
    function wmultiply(uint x, uint y) internal pure returns (uint z) {
        z = multiply(x, y) / WAD;
    }
    function rmultiply(uint x, uint y) internal pure returns (uint z) {
        z = multiply(x, y) / RAY;
    }
    function rpower(uint x, uint n, uint base) internal pure returns (uint z) {
        assembly {
            switch x case 0 {switch n case 0 {z := base} default {z := 0}}
            default {
                switch mod(n, 2) case 0 { z := base } default { z := x }
                let half := div(base, 2)  // for rounding.
                for { n := div(n, 2) } n { n := div(n,2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0,0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0,0) }
                    x := div(xxRound, base)
                    if mod(n,2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0,0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0,0) }
                        z := div(zxRound, base)
                    }
                }
            }
        }
    }

    // --- Administration ---
    /**
    * @notice Modify the converter feed address
    * @param parameter Name of the parameter to modify
    * @param data New parameter value
    **/
    function modifyParameters(bytes32 parameter, address data) external isAuthorized {
        require(data != address(0), "UniswapConsecutiveSlotsPriceFeedMedianizer/null-data");
        if (parameter == "converterFeed") {
          require(data != address(0), "UniswapConsecutiveSlotsPriceFeedMedianizer/null-converter-feed");
          converterFeed = ConverterFeedLike(data);
        }
        else if (parameter == "treasury") {
      	  require(StabilityFeeTreasuryLike(data).systemCoin() != address(0), "UniswapConsecutiveSlotsPriceFeedMedianizer/treasury-coin-not-set");
      	  treasury = StabilityFeeTreasuryLike(data);
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
        else revert("UniswapConsecutiveSlotsPriceFeedMedianizer/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }
    function modifyParameters(bytes32 parameter, uint256 data) external isAuthorized {
        if (parameter == "baseUpdateCallerReward") baseUpdateCallerReward = data;
        else if (parameter == "maxUpdateCallerReward") {
          require(data > baseUpdateCallerReward, "UniswapConsecutiveSlotsPriceFeedMedianizer/invalid-max-reward");
          maxUpdateCallerReward = data;
        }
        else if (parameter == "perSecondCallerRewardIncrease") {
          require(data >= RAY, "UniswapConsecutiveSlotsPriceFeedMedianizer/invalid-reward-increase");
          perSecondCallerRewardIncrease = data;
        }
        else if (parameter == "maxRewardIncreaseDelay") {
          require(data > 0, "UniswapConsecutiveSlotsPriceFeedMedianizer/invalid-max-increase-delay");
          maxRewardIncreaseDelay = data;
        }
        else if (parameter == "defaultAmountIn") {
          require(data > 0, "UniswapConsecutiveSlotsPriceFeedMedianizer/invalid-default-amount-in");
          defaultAmountIn = data;
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
        firstUniswapObservation       = uniswapObservations[earliestObservationIndex];
        firstConverterFeedObservation = converterFeedObservations[earliestObservationIndex];
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

        uint timeElapsedSinceFirstObservation = subtract(now, firstUniswapObservation.timestamp);
        // We can only fetch a brand new median price if there's been enough price data gathered
        if (both(timeElapsedSinceFirstObservation <= windowSize, timeElapsedSinceFirstObservation >= windowSize - periodSize * 2)) {
          (address token0,) = sortTokens(targetToken, denominationToken);
          uint256 uniswapAmountOut;
          if (token0 == targetToken) {
              uniswapAmountOut = uniswapComputeAmountOut(
                firstUniswapObservation.price0Cumulative, price0Cumulative, timeElapsedSinceFirstObservation, defaultAmountIn
              );
          } else {
              uniswapAmountOut = uniswapComputeAmountOut(
                firstUniswapObservation.price1Cumulative, price1Cumulative, timeElapsedSinceFirstObservation, defaultAmountIn
              );
          }

          return converterComputeAmountOut(timeElapsedSinceFirstObservation, uniswapAmountOut);
        }

        return medianPrice;
    }
    /**
    * @notice Returns the index of the earliest observation in the window
    **/
    function earliestObservationIndex() public view returns (uint256) {
        if (uniswapObservations.length <= granularity) {
          return 0;
        }
        return subtract(subtract(uniswapObservations.length, 1), uint(granularity));
    }
    /**
    * @notice Get the observation list length
    **/
    function getObservationListLength() public view returns (uint256, uint256) {
        return (uniswapObservations.length, converterFeedObservations.length);
    }

    // --- Treasury Utils ---
    function treasuryAllowance() public view returns (uint256) {
        (uint total, uint perBlock) = treasury.getAllowance(address(this));
        return minimum(total, perBlock);
    }
    function getCallerReward() public view returns (uint256) {
        if (lastUpdateTime == 0) return baseUpdateCallerReward;
        uint256 timeElapsed = subtract(now, lastUpdateTime);
        if (timeElapsed < periodSize) {
            return 0;
        }
        uint256 baseReward   = baseUpdateCallerReward;
        uint256 adjustedTime = subtract(timeElapsed, periodSize);
        if (adjustedTime > 0) {
            adjustedTime = (adjustedTime > maxRewardIncreaseDelay) ? maxRewardIncreaseDelay : adjustedTime;
            baseReward = rmultiply(rpower(perSecondCallerRewardIncrease, adjustedTime, RAY), baseReward);
        }
        uint256 maxReward = minimum(maxUpdateCallerReward, treasuryAllowance());
        if (baseReward > maxReward) {
            baseReward = maxReward;
        }
        return baseReward;
    }
    function rewardCaller(address proposedFeeReceiver, uint256 reward) internal {
        if (address(treasury) == proposedFeeReceiver) return;
        if (either(address(treasury) == address(0), reward == 0)) return;
        address finalFeeReceiver = (proposedFeeReceiver == address(0)) ? msg.sender : proposedFeeReceiver;
        try treasury.pullFunds(finalFeeReceiver, treasury.systemCoin(), reward) {
            emit RewardCaller(finalFeeReceiver, reward);
        }
        catch(bytes memory revertReason) {
            emit FailRewardCaller(revertReason, finalFeeReceiver, reward);
        }
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
        require(timeElapsed > 0, "UniswapConsecutiveSlotsPriceFeedMedianizer/null-time-elapsed");
        // Overflow is desired
        uq112x112 memory priceAverage = uq112x112(
            uint224((priceCumulativeEnd - priceCumulativeStart) / timeElapsed)
        );
        amountOut = decode144(multiply(priceAverage, amountIn));
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

        // Get caller's reward
        uint256 callerReward = getCallerReward();

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
        rewardCaller(feeReceiver, callerReward);
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

        converterPriceCumulative = addition(converterPriceCumulative, newTimeAdjustedPrice);

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
        require(both(medianPrice > 0, updates > granularity), "UniswapConsecutiveSlotsPriceFeedMedianizer/invalid-price-feed");
        return medianPrice;
    }
    /**
    * @notice Fetch the latest medianPrice and whether it is null or not
    **/
    function getResultWithValidity() external view returns (uint256, bool) {
        return (medianPrice, both(medianPrice > 0, updates > granularity));
    }
}
