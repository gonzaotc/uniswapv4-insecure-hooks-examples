// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// OpenZeppelin's Hooks library
import {BaseHook} from "uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "uniswap-hooks/src/utils/CurrencySettler.sol";

// Uniswap V4 Core & Periphery
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

contract HookFeeTaker is BaseHook {
    using CurrencySettler for Currency;

    uint128 private _beforeSwapSpecifiedFee;
    uint128 private _beforeSwapUnspecifiedFee;
    uint128 private _afterSwapUnspecifiedFee;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function setMockHookFee(
        uint128 beforeSwapSpecifiedFee,
        uint128 beforeSwapUnspecifiedFee,
        uint128 afterSwapUnspecifiedFee
    ) external {
        _beforeSwapSpecifiedFee = beforeSwapSpecifiedFee;
        _beforeSwapUnspecifiedFee = beforeSwapUnspecifiedFee;
        _afterSwapUnspecifiedFee = afterSwapUnspecifiedFee;
    }

    function getMockHookFee()
        external
        view
        returns (uint128 beforeSwapSpecifiedFee, uint128 beforeSwapUnspecifiedFee, uint128 afterSwapUnspecifiedFee)
    {
        return (_beforeSwapSpecifiedFee, _beforeSwapUnspecifiedFee, _afterSwapUnspecifiedFee);
    }

    /*
     * @dev Take `specified` and `unspecified` fees before the swap without any validation.
     */
    function _beforeSwap(
        address, /*sender*/
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata /*hookData*/
    ) internal override returns (bytes4 selector, BeforeSwapDelta delta, uint24 lpFeeOverride) {
        (Currency unspecified, Currency specified) = (params.amountSpecified < 0 == params.zeroForOne)
            ? (key.currency1, key.currency0)
            : (key.currency0, key.currency1);

        // Take both `specified` and `unspecified` fees
        if (_beforeSwapSpecifiedFee > 0) specified.take(poolManager, address(this), _beforeSwapSpecifiedFee, false);
        if (_beforeSwapUnspecifiedFee > 0) {
            unspecified.take(poolManager, address(this), _beforeSwapUnspecifiedFee, false);
        }

        return (
            this.beforeSwap.selector,
            toBeforeSwapDelta(int128(_beforeSwapSpecifiedFee), int128(_beforeSwapUnspecifiedFee)),
            0
        );
    }

    /*
     * @dev Take `unspecified` fee after the swap without any validation.
     */
    function _afterSwap(
        address, /*sender*/
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta, /*delta*/
        bytes calldata /*hookData*/
    ) internal override returns (bytes4 selector, int128 unspecifiedDelta) {
        (Currency unspecified) = (params.amountSpecified < 0 == params.zeroForOne) ? key.currency1 : key.currency0;

        if (_afterSwapUnspecifiedFee > 0) {
            unspecified.take(poolManager, address(this), _afterSwapUnspecifiedFee, false);
        }

        return (this.afterSwap.selector, int128(_afterSwapUnspecifiedFee));
    }

    /**
     * @dev Set the hook permissions, specifically `afterInitialize`.
     *
     * @return permissions The hook permissions.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
