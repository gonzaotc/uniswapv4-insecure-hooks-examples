// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// OpenZeppelin's Core
import {SafeCast} from "openzeppelin-contracts/utils/math/SafeCast.sol";

// OpenZeppelin's Hooks library
import {CurrencySettler} from "uniswap-hooks/src/utils/CurrencySettler.sol";

// Uniswap V4 Core & Periphery
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolTestBase} from "v4-core/src/test/PoolTestBase.sol";
import {console} from "forge-std/console.sol";

/*
* Naive and insecure router that allows hooks to take more than it should.
*
* This is part of a proof of concept that shows that the UniswapV4 core is not secure by itself,
* and that a well-implemented router is needed to ensure that a user is not annihilated by a hook.
*
* Disclaimer: This router is insecure and should not be used in production.
*/
contract NaiveRouterNoChecks {
    using SafeCast for *;
    using CurrencySettler for Currency;
    using Hooks for IHooks;

    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    struct CallbackData {
        address sender;
        PoolKey key;
        SwapParams params;
    }

    function swap(PoolKey memory key, SwapParams memory params) external payable {
        manager.unlock(abi.encode(CallbackData(msg.sender, key, params)));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager));

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        BalanceDelta delta = manager.swap(data.key, data.params, new bytes(0));


        // This naive router will just do what UniswapV4 core dictates without any checks.
        // If a delta is positive, it will take the currency from the pool.
        // If a delta is negative, it will settle the currency to the pool.
        if (delta.amount0() >= 0) {
            data.key.currency0.take(manager, data.sender, uint256(int256(delta.amount0())), false);
        } else {
            data.key.currency0.settle(manager, data.sender, uint256(int256(-delta.amount0())), false);
        }
        if (delta.amount1() >= 0) {
            data.key.currency1.take(manager, data.sender, uint256(int256(delta.amount1())), false);
        } else {
            data.key.currency1.settle(manager, data.sender, uint256(int256(-delta.amount1())), false);
        }

        return "";
    }
}
