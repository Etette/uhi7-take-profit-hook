// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ERC1155} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
import {IERC20} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "forge-std/console.sol";

// A take-profit limit order hook for Uniswap v4 Users deposit tokenIn at a chosen tick.  
// When price crosses that tick, the hook swaps their tokens and credits them ERC1155 "claim receipts".
contract TakeProfitHook is BaseHook, ERC1155 {
    using PoolIdLibrary for PoolKey;

    struct Order {
        uint256 amountIn;      
        uint256 amountOut;
        bool zeroForOne;
        bool exists;
    }

    // pool → tick → direction → order
    mapping(PoolId => mapping(int24 => mapping(bool => Order))) public orders;

    constructor(IPoolManager _pm)
        BaseHook(_pm)
        ERC1155("https://someurl.com/takeprofit/{id}.json")
    {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function placeOrder(
        PoolKey calldata key,
        int24 tick,
        uint256 amountIn,
        bool zeroForOne
    ) external {
        require(amountIn > 0, "Invalid");

        PoolId pid = key.toId();
        Order storage o = orders[pid][tick][zeroForOne];

        if (!o.exists) {
            o.exists = true;
            o.zeroForOne = zeroForOne;
        }

        o.amountIn += amountIn;

        // pull tokens
        address tokenIn = zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);

        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        // mint claim receipt
        uint256 tokenId = _orderId(pid, tick, zeroForOne);
        _mint(msg.sender, tokenId, amountIn, "");
    }

    function cancelOrder(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne
    ) external {
        PoolId pid = key.toId();
        uint256 tokenId = _orderId(pid, tick, zeroForOne);

        uint256 userAmount = balanceOf(msg.sender, tokenId);
        require(userAmount > 0, "No tokens");

        _burn(msg.sender, tokenId, userAmount);

        Order storage o = orders[pid][tick][zeroForOne];
        require(o.amountIn >= userAmount, "Bad state");
        o.amountIn -= userAmount;

        address tokenIn = zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);

        IERC20(tokenIn).transfer(msg.sender, userAmount);
    }


    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    )
        external
        override
        onlyPoolManager()
        returns (bytes4, int128)
    {
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, key.toId());

        // execute orders that are crossed
        _executeTakeProfits(key, params, currentTick);

        return (TakeProfitHook.afterSwap.selector, 0);
    }

    function _executeTakeProfits(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        int24 currentTick
    ) internal {

        PoolId pid = key.toId();

        // using tickSpacing to traverse tick boundaries
        int24 ts = key.tickSpacing;
        int24 tickLower = _tickLower(currentTick, ts);

        // zeroForOne & oneForZero
        _maybeFill(key, pid, tickLower, true, params);
        _maybeFill(key, pid, tickLower, false, params);
    }

    function _maybeFill(
        PoolKey calldata key,
        PoolId pid,
        int24 tick,
        bool zeroForOne,
        IPoolManager.SwapParams calldata params
    ) internal {
        Order storage o = orders[pid][tick][zeroForOne];
        if (!o.exists || o.amountIn == 0) return;

        console.log("Filling take-profit at tick", tick);

        // swap in direction of order
        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(o.amountIn),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_RATIO + 1
                : TickMath.MAX_SQRT_RATIO - 1
        });

        BalanceDelta delta = poolManager.swap(key, sp, "");

        // settlement 
        if (zeroForOne) {
            // pay token0, receive token1
            if (delta.amount0() > 0) {
                IERC20(Currency.unwrap(key.currency0)).transfer(
                    address(poolManager),
                    uint128(delta.amount0())
                );
                poolManager.settle();
            }
            if (delta.amount1() < 0) {
                poolManager.take(
                    key.currency1,
                    address(this),
                    uint128(-delta.amount1())
                );
            }
        } else {
            // pay token1, receive token0
            if (delta.amount1() > 0) {
                IERC20(Currency.unwrap(key.currency1)).transfer(
                    address(poolManager),
                    uint128(delta.amount1())
                );
                poolManager.settle();
            }
            if (delta.amount0() < 0) {
                poolManager.take(
                    key.currency0,
                    address(this),
                    uint128(-delta.amount0())
                );
            }
        }

        // record output for redemption
        uint256 received = zeroForOne
            ? uint256(int256(-delta.amount1()))
            : uint256(int256(-delta.amount0()));

        o.amountOut += received;
        o.amountIn = 0; // fully used
    }

    function redeem(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne,
        uint256 amountIn,
        address to
    ) external {
        require(amountIn > 0, "Bad");

        PoolId pid = key.toId();
        uint256 tokenId = _orderId(pid, tick, zeroForOne);

        uint256 userBal = balanceOf(msg.sender, tokenId);
        require(userBal >= amountIn, "Not enough");

        Order storage o = orders[pid][tick][zeroForOne];
        require(o.amountOut > 0, "Nothing to redeem");

        // proportional share
        uint256 share = (o.amountOut * amountIn) /
                        (userBal + _totalOtherHolders(tokenId));

        o.amountOut -= share;

        _burn(msg.sender, tokenId, amountIn);

        address tokenOut = zeroForOne
            ? Currency.unwrap(key.currency1)
            : Currency.unwrap(key.currency0);

        IERC20(tokenOut).transfer(to, share);
    }

    function _totalOtherHolders(uint256) internal pure returns (uint256) {
        // TODO-extend to track supply
        return 0;
    }

    function _orderId(PoolId pid, int24 tick, bool zf1)
        internal
        pure
        returns (uint256)
    {
        return uint256(keccak256(abi.encodePacked(pid, tick, zf1)));
    }

    function _tickLower(int24 tick, int24 spacing)
        internal
        pure
        returns (int24)
    {
        int24 intervals = tick / spacing;
        if (tick < 0 && tick % spacing != 0) intervals--;
        return intervals * spacing;
    }
}