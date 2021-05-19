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

contract UniswapV3ConverterBasicMeanPriceFeedMedianizer is GebMath {
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
        require(authorizedAccounts[msg.sender] == 1, "UniswapV3ConverterBasicMeanPriceFeedMedianizer/account-not-authorized");
        _;
    }

    // --- Observations ---
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
    address              public uniswapPool;

    IUniswapV3Factory    public uniswapV3Factory;

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
      address uniswapFactory_,
      uint256 defaultAmountIn_,
      uint32 windowSize_,
      uint256 converterFeedScalingFactor_,
      uint8   granularity_
    ) public {
        require(uniswapFactory_ != address(0), "UniswapV3ConverterBasicMeanPriceFeedMedianizer/null-uniswap-factory");
        require(granularity_ > 1, 'UniswapV3ConverterBasicMeanPriceFeedMedianizer/null-granularity');
        require(windowSize_ > 0, 'UniswapV3ConverterBasicMeanPriceFeedMedianizer/null-window-size');
        require(defaultAmountIn_ > 0, 'UniswapV3ConverterBasicMeanPriceFeedMedianizer/invalid-default-amount-in');
        require(converterFeedScalingFactor_ > 0, 'UniswapV3ConverterBasicMeanPriceFeedMedianizer/null-feed-scaling-factor');
        require(
            (periodSize = windowSize_ / granularity_) * granularity_ == windowSize_,
            'UniswapV3ConverterBasicMeanPriceFeedMedianizer/window-not-evenly-divisible'
        );

        authorizedAccounts[msg.sender] = 1;

        converterFeed                  = ConverterFeedLike(converterFeed_);
        uniswapV3Factory               = IUniswapV3Factory(uniswapFactory_);
        defaultAmountIn                = defaultAmountIn_;
        windowSize                     = windowSize_;
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
    }

    // --- General Utils ---
    function either(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := or(x, y)}
    }
    function both(bool x, bool y) private pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    // --- Core Logic ---
    /**
    * @notice Update the internal median price
    **/
    function updateResult(address feeReceiver) external {
        require(address(relayer) != address(0), "UniswapV3ConverterBasicMeanPriceFeedMedianizer/null-relayer");
        require(uniswapPool != address(0), "UniswapV3ConverterBasicMeanPriceFeedMedianizer/null-uniswap-pair");

        // Get final fee receiver
        address finalFeeReceiver = (feeReceiver == address(0)) ? msg.sender : feeReceiver;

        // Update the converter's median price first
        try converterFeed.updateResult(finalFeeReceiver) {}
        catch (bytes memory converterRevertReason) {
          emit FailedConverterFeedUpdate(converterRevertReason);
        }

        int24 medianTick = consult(windowSize);
        medianPrice = getQuoteAtTick(medianTick, uint128(defaultAmountIn), denominationToken, targetToken);
        lastUpdateTime = now;
        updates        = addition(updates, 1);

        emit UpdateResult(medianPrice, lastUpdateTime);

        // Reward caller
        relayer.reimburseCaller(finalFeeReceiver);
    }

    /// @notice Fetches time-weighted average tick using Uniswap V3 oracle
    /// @param period Number of seconds in the past to start calculating time-weighted average
    /// @return timeWeightedAverageTick The time-weighted average tick from (block.timestamp - period) to block.timestamp
    function consult(uint32 period) internal view returns (int24 timeWeightedAverageTick) {
        require(period != 0, 'BP');

        uint32[] memory secondAgos = new uint32[](2);
        secondAgos[0] = period;
        secondAgos[1] = 0;

        (int56[] memory tickCumulatives, ) = IUniswapV3Pool(uniswapPool).observe(secondAgos);
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];

        timeWeightedAverageTick = int24(tickCumulativesDelta / period);

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
    function read() external view returns (uint256) {
        require(
          both(both(medianPrice > 0, updates >= granularity), validityFlag == 1),
          "UniswapV3ConverterBasicMeanPriceFeedMedianizer/invalid-price-feed"
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
