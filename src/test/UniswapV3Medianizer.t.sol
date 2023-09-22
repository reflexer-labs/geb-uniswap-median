pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-token/token.sol";

import "../univ3/UniswapV3Pool.sol";
import "../univ3/UniswapV3Factory.sol";
import "../univ3/libraries/LiquidityAmounts.sol";

import "../UniswapV3Medianizer.sol";

abstract contract Hevm {
    function warp(uint256) public virtual;

    function roll(uint256) public virtual;
}

contract Caller {
    UniswapV3Medianizer median;

    constructor(UniswapV3Medianizer add) public {
        median = add;
    }

    function doModifyParameters(bytes32 param, uint256 data) public {
        median.modifyParameters(param, data);
    }

    function doAddAuthorization(address data) public {
        median.addAuthorization(data);
    }

    function doRemoveAuthorization(address data) public {
        median.removeAuthorization(data);
    }
}

contract UniswapV3MedianizerTest is DSTest {
    Hevm hevm;

    UniswapV3Medianizer median;
    Caller unauth;

    UniswapV3Pool uniswapPool;
    uint256 initETHLiquidity = 5000 ether; // 1250 USD
    uint256 initRaiLiquidity = 294672.324375E18; // 1 RAI = 4.242 USD

    DSToken coin;
    DSToken weth;

    uint32 windowSize = 12 hours;
    uint256 minLiquidity = 1000 ether;

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

        // Deploy Tokens
        weth = new DSToken("WETH", "WETH");
        coin = new DSToken("COIN", "COIN");

        // Setup Uniswap
        uint160 priceCoinToken0 = 103203672169272457649230733;
        uint160 priceCoinToken1 = 6082246497092770728082823737800;

        uniswapPool = UniswapV3Pool(
            _deployV3Pool(address(coin), address(weth), 3000)
        );
        uniswapPool.initialize(
            address(coin) == uniswapPool.token0()
                ? priceCoinToken0
                : priceCoinToken1
        );

        // Add pair liquidity
        coin.mint(1000000 ether);
        weth.mint(5000 ether);
        _addLiquidity();

        // zeroing balances
        coin.transfer(address(1), coin.balanceOf(address(this)));
        weth.transfer(address(1), weth.balanceOf(address(this)));

        //Increase the number of oracle observations
        uniswapPool.increaseObservationCardinalityNext(3000);

        median = new UniswapV3Medianizer(
            address(uniswapPool),
            address(coin),
            windowSize,
            minLiquidity
        );

        unauth = new Caller(median);
        hevm.warp(now + windowSize);
    }

    // --- Helpers ---
    function _deployV3Pool(
        address _token0,
        address _token1,
        uint256 _fee
    ) internal returns (address _pool) {
        UniswapV3Factory fac = new UniswapV3Factory();
        _pool = fac.createPool(_token0, _token1, uint24(_fee));
    }

    function _addLiquidity() internal {
        int24 low = -887220;
        int24 upp = 887220;
        (uint160 sqrtRatioX96, , , , , , ) = uniswapPool.slot0();
        uint128 liq;
        if (address(coin) == uniswapPool.token0())
            liq = _getLiquidityAmountsForTicks(
                sqrtRatioX96,
                low,
                upp,
                initRaiLiquidity,
                initETHLiquidity
            );
        else
            liq = _getLiquidityAmountsForTicks(
                sqrtRatioX96,
                low,
                upp,
                initETHLiquidity,
                initRaiLiquidity
            );
        uniswapPool.mint(address(this), low, upp, liq, bytes(""));
    }

    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes memory data
    ) public {
        uint coinAmount = address(coin) == uniswapPool.token0()
            ? amount0Owed
            : amount1Owed;
        uint collateralAmount = address(coin) == uniswapPool.token0()
            ? amount1Owed
            : amount0Owed;

        weth.mint(msg.sender, collateralAmount);
        coin.mint(address(msg.sender), coinAmount);
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        uniswapV3MintCallback(
            (amount0Delta > 0) ? uint(amount0Delta) : 0,
            (amount1Delta > 0) ? uint(amount1Delta) : 0,
            data
        );
    }

    function _getLiquidityAmountsForTicks(
        uint160 sqrtRatioX96,
        int24 _lowerTick,
        int24 upperTick,
        uint256 t0am,
        uint256 t1am
    ) public returns (uint128 liquidity) {
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtRatioX96,
            TickMath.getSqrtRatioAtTick(_lowerTick),
            TickMath.getSqrtRatioAtTick(upperTick),
            t0am,
            t1am
        );
    }

    function _swap(bool zeroForOne, uint256 size) public {
        (uint160 currentPrice, , , , , , ) = uniswapPool.slot0();
        if (zeroForOne) {
            uint160 sqrtLimitPrice = currentPrice - uint160(size);
            uniswapPool.swap(
                address(this),
                true,
                int56(size),
                sqrtLimitPrice,
                bytes("")
            );
        } else {
            uint160 sqrtLimitPrice = currentPrice + uint160(size);
            uniswapPool.swap(
                address(this),
                false,
                int56(size),
                sqrtLimitPrice,
                bytes("")
            );
        }
    }

    function _getSpotPrice() internal returns (uint) {
        uint32[] memory secondAgos = new uint32[](2);
        secondAgos[0] = 1;
        secondAgos[1] = 0;

        (int56[] memory ticks, ) = uniswapPool.observe(secondAgos);
        return
            OracleLibrary.getQuoteAtTick(
                int24(ticks[1] - ticks[0]),
                1 ether,
                address(coin),
                address(weth)
            );
    }

    // --- Tests ---
    function test_setup() public {
        assertEq(median.uniswapPool(), address(uniswapPool));
        assertEq(median.targetToken(), address(coin));
        assertEq(median.denominationToken(), address(weth));
        assertEq(uint(median.windowSize()), uint(windowSize));
        assertEq(median.minimumLiquidity(), minLiquidity);
    }

    function testFail_setup_null_pool() public {
        median = new UniswapV3Medianizer(
            address(0),
            address(coin),
            windowSize,
            minLiquidity
        );
    }

    function testFail_setup_null_window() public {
        median = new UniswapV3Medianizer(
            address(uniswapPool),
            address(coin),
            0,
            minLiquidity
        );
    }

    function testFail_setup_invalid_target_token() public {
        median = new UniswapV3Medianizer(
            address(uniswapPool),
            address(this),
            windowSize,
            minLiquidity
        );
    }

    function test_add_authorization() public {
        median.addAuthorization(address(0xfab));
        assertEq(median.authorizedAccounts(address(0xfab)), 1);
    }

    function test_remove_authorization() public {
        median.removeAuthorization(address(this));
        assertEq(median.authorizedAccounts(address(this)), 0);
    }

    function testFail_add_authorization_unauthorized() public {
        unauth.doAddAuthorization(address(0xfab));
    }

    function testFail_remove_authorization_unauthorized() public {
        unauth.doRemoveAuthorization(address(this));
    }

    function test_modify_parameters() public {
        median.modifyParameters("validityFlag", 0);
        assertEq(median.validityFlag(), 0);

        median.modifyParameters("defaultAmountIn", 2 ether);
        assertEq(uint(median.defaultAmountIn()), 2 ether);

        median.modifyParameters("windowSize", 3 hours);
        assertEq(uint(median.windowSize()), 3 hours);

        median.modifyParameters("minimumLiquidity", 0);
        assertEq(uint(median.minimumLiquidity()), 0);
    }

    function testFail_modify_parameters_invalid_amount_in() public {
        median.modifyParameters("defaultAmountIn", 0);
    }

    function testFail_modify_parameters_invalid_validityFlag() public {
        median.modifyParameters("validityFlag", 2);
    }

    function testFail_modify_parameters_invalid_window_size() public {
        median.modifyParameters("windowSize", 0);
    }

    function test_is_valid() public {
        assertTrue(median.isValid());

        // validityFlag
        median.modifyParameters("validityFlag", 0);
        assertTrue(!median.isValid());

        // liquidity
        median.modifyParameters(
            "minimumLiquidity",
            coin.balanceOf(address(uniswapPool)) + 1
        );
        assertTrue(!median.isValid());
        median.modifyParameters("validityFlag", 1);
        assertTrue(!median.isValid());
    }

    function assertSimilar(uint a, uint b, uint p) internal {
        uint v = (b / 100000) * p;
        assertTrue(a <= b + v && a >= b - v);
    }

    function test_get_twap_price() public {
        uint initialPrice = _getSpotPrice();
        assertEq(median.getTwapPrice(), initialPrice);

        hevm.warp(now + windowSize);

        assertEq(median.getTwapPrice(), initialPrice);

        _swap(true, 100000000 ether);
        assertEq(median.getTwapPrice(), initialPrice);

        hevm.warp(now + (windowSize / 2));
        emit log_named_uint("spot", _getSpotPrice());
        emit log_named_uint("medi", median.getTwapPrice());
        emit log_named_uint("calc", (initialPrice + _getSpotPrice()) / 2);

        assertSimilar(
            median.getTwapPrice(),
            (initialPrice + _getSpotPrice()) / 2,
            100000
        ); // .01% deviation allowed

        hevm.warp(now + (windowSize / 2));
        assertEq(median.getTwapPrice(), _getSpotPrice());
    }

    function test_get_twap_price_with_end() public {
        uint initialPrice = _getSpotPrice();
        assertEq(median.getTwapPrice(), initialPrice);

        hevm.warp(now + windowSize);

        assertEq(median.getTwapPrice(), initialPrice);

        _swap(true, 100000000 ether);
        assertEq(median.getTwapPrice(), initialPrice);

        hevm.warp(now + (windowSize));

        // twap tested up to now, now we push the price and test
        uint end = now;
        uint lastSpotPrice = _getSpotPrice();
        hevm.warp(now + 1);
        _swap(true, 10000000 ether);
        hevm.warp(now + 55 days);

        // move price and
        assertSimilar(
            median.getTwapPrice(
                uint32(now - end + windowSize),
                uint32(now - end)
            ),
            (initialPrice + lastSpotPrice) / 2,
            100000
        ); // .01% deviation allowed
    }

    function test_read() public {
        assertEq(median.read(), _getSpotPrice());
    }

    function testFail_read_invalid() public {
        median.modifyParameters("validityFlag", 0);
        median.read();
    }

    function test_get_result_with_validity() public {
        (uint value, bool valid) = median.getResultWithValidity();
        assertEq(value, _getSpotPrice());
        assertTrue(valid);

        median.modifyParameters("validityFlag", 0);
        (value, valid) = median.getResultWithValidity();
        assertEq(value, _getSpotPrice());
        assertTrue(!valid);
    }
}
