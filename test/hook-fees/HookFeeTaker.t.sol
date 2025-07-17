// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Forge Std
import {Test} from "forge-std/Test.sol";

// OpenZeppelin's Hooks library
import {IPoolManagerEvents} from "uniswap-hooks/test/utils/interfaces/IPoolManagerEvents.sol";
import {HookFeeTaker} from "src/hook-fees/HookFeeTaker.sol";

// Uniswap V4 Core & Periphery
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

// Local
import {NaiveRouterNoChecks} from "src/routers/NaiveRouterNoChecks.sol";

contract HookFeeTakerTest is Test, Deployers, IPoolManagerEvents {
    // A simple hook that takes hook fees both during `beforeSwap` and `afterSwap`.
    HookFeeTaker public hookFeeTaker;

    // A naive router that does not perform any checks.
    NaiveRouterNoChecks public naiveRouterNoChecks;

    PoolSwapTest.TestSettings public testSettings =
        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        hookFeeTaker = HookFeeTaker(
            address(
                uint160(
                    Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_SWAP_FLAG
                        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                )
            )
        );
        deployCodeTo("src/hook-fees/HookFeeTaker.sol:HookFeeTaker", abi.encode(manager), address(hookFeeTaker));

        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hookFeeTaker)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );

        naiveRouterNoChecks = new NaiveRouterNoChecks(manager);
        
        // Approve the naive router to spend currencies
        MockERC20(Currency.unwrap(currency0)).approve(address(naiveRouterNoChecks), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(naiveRouterNoChecks), type(uint256).max);
    }

    function test_setMockHookFee() public {
        hookFeeTaker.setMockHookFee(100, 100, 100);

        (uint128 beforeSwapSpecifiedFee, uint128 beforeSwapUnspecifiedFee, uint128 afterSwapUnspecifiedFee) =
            hookFeeTaker.getMockHookFee();

        assertEq(beforeSwapSpecifiedFee, 100);
        assertEq(beforeSwapUnspecifiedFee, 100);
        assertEq(afterSwapUnspecifiedFee, 100);
    }

    function test_swap_no_fee() public {
        hookFeeTaker.setMockHookFee(0, 0, 0);

        vm.expectEmit(true, true, true, true, address(manager));
        emit Swap(key.toId(), address(swapRouter), -100, 99, 79228162514264329670727698910, 1e18, -1, 0);

        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: SQRT_PRICE_1_2}),
            testSettings,
            ZERO_BYTES
        );
    }

    // Proof that during `beforeSwap`, 100% of the `specifiedAmount` can be taken as a hook fee.
    function test_beforeSwapHookFee_specifiedFee_100percent_succeeds() public {
        int128 amountToSwap = -100;

        hookFeeTaker.setMockHookFee(100, 0, 0);

        vm.expectEmit(true, true, true, true, address(manager));
        emit Swap(key.toId(), address(swapRouter), 0, 0, SQRT_PRICE_1_1, 1e18, 0, 0);

        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: amountToSwap, sqrtPriceLimitX96: SQRT_PRICE_1_2}),
            testSettings,
            ZERO_BYTES
        );

        // check that the hook fee was taken
        assertEq(currency0.balanceOf(address(hookFeeTaker)), 100);
    }

    // Proof that during `beforeSwap`, no more than the `specifiedAmount` can be taken as a hook fee.
    function test_beforeSwapHookFee_specifiedFee_100percent_plus1_reverts() public {
        int128 amountToSwap = -100;

        hookFeeTaker.setMockHookFee(100 + 1, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(Hooks.HookDeltaExceedsSwapAmount.selector));

        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: amountToSwap, sqrtPriceLimitX96: SQRT_PRICE_1_2}),
            testSettings,
            ZERO_BYTES
        );
    }

    // Proof that during `beforeSwap`, 100% of the `unspecifiedAmount` can be taken as a hook fee.
    function test_beforeSwapHookFee_unspecifiedFee_100percent_succeeds() public {
        int128 amountToSwap = -100;

        hookFeeTaker.setMockHookFee(0, 99, 0);

        // Note that when the hook fee is taken from the `unspecifiedAmount`, it is taken during `afterSwap` implicitly,
        // therefore the `Swap` event will look like the user is not paying any hook fee!, while he is.
        vm.expectEmit(true, true, true, true, address(manager));
        emit Swap(key.toId(), address(swapRouter), -100, 99, 79228162514264329670727698910, 1e18, -1, 0);

        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: amountToSwap, sqrtPriceLimitX96: SQRT_PRICE_1_2}),
            testSettings,
            ZERO_BYTES
        );

        // check that the hook fee was taken
        assertEq(currency1.balanceOf(address(hookFeeTaker)), 99);
    }

    // Proof that during `afterSwap`, no more than the `unspecifiedAmount` can be taken as a hook fee.
    //
    // IMPORTANT NOTE: this is not enforced by the UniswapV4 core, it is instead enforced at the router level!!!
    //
    // This means that we may have a router that does not perform the check, and therefore allows hooks to take more, 
    // effectively being able to take money from both currency0 and currency1, with no limit on currency1!
    //
    function test_afterSwapHookFee_unspecifiedFee_100percent_plus1_swapRouter_checks_reverts() public {
        int128 amountToSwap = -100;

        hookFeeTaker.setMockHookFee(0, 99 + 1, 0);

        // Again, as `unspecifiedAmount` is taken during `afterSwap`, the `Swap` event will look like the user is not paying any hook fee.
        vm.expectEmit(true, true, true, true, address(manager));
        emit Swap(key.toId(), address(swapRouter), -100, 99, 79228162514264329670727698910, 1e18, -1, 0);

        // the swapRouter should revert because the hook took more than the user received.
        vm.expectRevert("deltaAfter1 is not greater than or equal to 0");

        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: amountToSwap, sqrtPriceLimitX96: SQRT_PRICE_1_2}),
            testSettings,
            ZERO_BYTES
        );
    }

    // Proof that during `beforeSwap`, more than the `unspecifiedAmount` can be taken as a hook fee on a router that performs no checks.
    function test_beforeSwapHookFee_unspecifiedFee_100percent_plus1_swapRouter_noChecks_succeeds() public {
        int128 amountToSwap = -100;

        hookFeeTaker.setMockHookFee(0, 99 + 1, 0);

        // Again, as `unspecifiedAmount` is taken during `beforeSwap`, the `Swap` event will look like the user is not paying any hook fee.
        vm.expectEmit(true, true, true, true, address(manager));
        emit Swap(key.toId(), address(naiveRouterNoChecks), -100, 99, 79228162514264329670727698910, 1e18, -1, 0);

        // We intentionally use the `naiveRouterNoChecks` which will allow our hook to take more than the user should receive.
        naiveRouterNoChecks.swap(
            key, SwapParams({zeroForOne: true, amountSpecified: amountToSwap, sqrtPriceLimitX96: SQRT_PRICE_1_2})
        );

        // here comes the tricky part; the hook received even more than what the user received.
        assertEq(currency1.balanceOf(address(hookFeeTaker)), 99 + 1);
    }

    // Proof that also during `afterSwap`, more than the `unspecifiedAmount` can be taken as a hook fee on a router that performs no checks.
    function test_afterSwapHookFee_unspecifiedFee_100percent_plus1_swapRouter_noChecks_succeeds() public {
        int128 amountToSwap = -100;

        hookFeeTaker.setMockHookFee(0, 0, 99 + 1);

        // Again, as `unspecifiedAmount` is taken during `beforeSwap`, the `Swap` event will look like the user is not paying any hook fee.
        vm.expectEmit(true, true, true, true, address(manager));
        emit Swap(key.toId(), address(naiveRouterNoChecks), -100, 99, 79228162514264329670727698910, 1e18, -1, 0);

        // We intentionally use the `naiveRouterNoChecks` which will allow our hook to take more than the user should receive.
        naiveRouterNoChecks.swap(
            key, SwapParams({zeroForOne: true, amountSpecified: amountToSwap, sqrtPriceLimitX96: SQRT_PRICE_1_2})
        );

        // here comes the tricky part; the hook received even more than what the user received.
        assertEq(currency1.balanceOf(address(hookFeeTaker)), 99 + 1);
    }

    // Proof that even a larger amount than the swap can be taken as a hook fee on a router that performs no checks.
    function test_beforeSwapHookFee_unspecifiedFee_largeFee_swapRouter_noChecks_succeeds() public {
        int128 amountToSwap = -100;
        uint256 largeFee = 99999999999;

        hookFeeTaker.setMockHookFee(0, 0, uint128(largeFee));

        // Again, as `unspecifiedAmount` is taken during `beforeSwap`, the `Swap` event will look like the user is not paying any hook fee.
        vm.expectEmit(true, true, true, true, address(manager));
        emit Swap(key.toId(), address(naiveRouterNoChecks), -100, 99, 79228162514264329670727698910, 1e18, -1, 0);

        // We intentionally use the `naiveRouterNoChecks` which will allow our hook to take more than the user should receive.
        naiveRouterNoChecks.swap(
            key, SwapParams({zeroForOne: true, amountSpecified: amountToSwap, sqrtPriceLimitX96: SQRT_PRICE_1_2})
        );

        // here comes the tricky part; the hook received even more than what the user received.
        assertEq(currency1.balanceOf(address(hookFeeTaker)), largeFee);
    }

}
