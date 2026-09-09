// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import {
    UniswapV4SwapHelpers,
    IUniversalRouter,
    IPermit2,
    PoolKey
} from "../../src/weiroll-helpers/UniswapV4SwapHelpers.sol";
import { MockUniversalRouter, MockPermit2, MintableERC20 } from "../mocks/MockUniversalRouter.sol";

/// @notice Unit tests for UniswapV4SwapHelpers against a mock Universal Router. The mock
///         delivers a fixed output per swap so the helper's own accounting (what it credits,
///         what it pays out, what it leaves behind) can be asserted exactly.
///
///         Nethermind NM-1048 [Info]: the helper must credit only the swap delta, never a
///         balance it already held before the Universal Router call.
contract UniswapV4SwapHelpersTest is Test {
    MintableERC20 internal tokenA;
    MintableERC20 internal tokenB;
    MockPermit2 internal permit2;
    MockUniversalRouter internal router;
    UniswapV4SwapHelpers internal helper;

    address internal taker = makeAddr("taker");
    address internal receiver = makeAddr("receiver");

    uint256 internal constant AMOUNT_IN = 1_000e18;
    uint256 internal constant SWAP_OUT = 1_000e18;
    uint256 internal constant STRAY = 500e18;

    function setUp() public {
        tokenA = new MintableERC20("Token A", "A");
        tokenB = new MintableERC20("Token B", "B");
        permit2 = new MockPermit2();
        router = new MockUniversalRouter(permit2);
        helper = new UniswapV4SwapHelpers(IUniversalRouter(address(router)), IPermit2(address(permit2)));

        tokenA.mint(taker, AMOUNT_IN);
        vm.prank(taker);
        tokenA.approve(address(helper), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _key(address c0, address c1) internal pure returns (PoolKey memory) {
        return PoolKey({ currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: address(0) });
    }

    function _swapAtoB(uint256 minOut) internal returns (uint256) {
        vm.prank(taker);
        return helper.swapExactInSingle(
            _key(address(tokenA), address(tokenB)), true, AMOUNT_IN, minOut, type(uint256).max, receiver, ""
        );
    }

    // -------------------------------------------------------------------------
    // Balance delta accounting (the audit finding)
    // -------------------------------------------------------------------------

    /// @notice A stray ERC20 balance held by the helper before the swap must not be credited
    ///         to the caller or paid to the receiver.
    function test_ERC20Output_StrayBalanceNotCredited() public {
        tokenB.mint(address(helper), STRAY);
        router.configure(address(tokenA), AMOUNT_IN, address(tokenB), SWAP_OUT);

        uint256 amountOut = _swapAtoB(SWAP_OUT);

        assertEq(amountOut, SWAP_OUT, "returned amountOut must equal the swap delta");
        assertEq(tokenB.balanceOf(receiver), SWAP_OUT, "receiver must get only the swap delta");
        assertEq(tokenB.balanceOf(address(helper)), STRAY, "stray balance must stay put");
    }

    /// @notice Same as above for a native ETH output.
    function test_NativeOutput_StrayBalanceNotCredited() public {
        vm.deal(address(helper), STRAY);
        vm.deal(address(router), SWAP_OUT);
        router.configure(address(tokenA), AMOUNT_IN, address(0), SWAP_OUT);

        uint256 receiverBefore = receiver.balance;
        vm.prank(taker);
        uint256 amountOut = helper.swapExactInSingle(
            _key(address(0), address(tokenA)), false, AMOUNT_IN, SWAP_OUT, type(uint256).max, receiver, ""
        );

        assertEq(amountOut, SWAP_OUT, "returned amountOut must equal the swap delta");
        assertEq(receiver.balance - receiverBefore, SWAP_OUT, "receiver must get only the swap delta");
        assertEq(address(helper).balance, STRAY, "stray ETH must stay put");
    }

    /// @notice The slippage floor must be enforced against the delta. A stray balance must not
    ///         be able to mask a short swap.
    function test_MinAmountOut_EnforcedOnDelta() public {
        tokenB.mint(address(helper), STRAY);
        uint256 shortOut = SWAP_OUT - 100e18;
        router.configure(address(tokenA), AMOUNT_IN, address(tokenB), shortOut);

        vm.expectRevert(
            abi.encodeWithSelector(UniswapV4SwapHelpers.InsufficientOutputAmount.selector, shortOut, SWAP_OUT)
        );
        _swapAtoB(SWAP_OUT);
    }

    // -------------------------------------------------------------------------
    // Baseline behaviour
    // -------------------------------------------------------------------------

    function test_ERC20Swap_HappyPath() public {
        router.configure(address(tokenA), AMOUNT_IN, address(tokenB), SWAP_OUT);

        uint256 amountOut = _swapAtoB(SWAP_OUT);

        assertEq(amountOut, SWAP_OUT);
        assertEq(tokenB.balanceOf(receiver), SWAP_OUT);
        assertEq(tokenA.balanceOf(taker), 0, "input must be drained from taker");
        assertEq(tokenA.balanceOf(address(router)), AMOUNT_IN, "input must reach the router");
        assertEq(tokenB.balanceOf(address(helper)), 0, "helper must hold nothing after the swap");
        assertEq(permit2.lastToken(), address(tokenA));
        assertEq(permit2.lastSpender(), address(router));
        assertEq(uint256(permit2.lastAmount()), AMOUNT_IN, "Permit2 allowance must be exact-amount");
        assertEq(router.lastDeadline(), type(uint256).max);
    }

    function test_NativeInput_ForwardsValue() public {
        vm.deal(taker, AMOUNT_IN);
        router.configure(address(0), AMOUNT_IN, address(tokenB), SWAP_OUT);

        vm.prank(taker);
        uint256 amountOut = helper.swapExactInSingle{ value: AMOUNT_IN }(
            _key(address(0), address(tokenB)), true, AMOUNT_IN, SWAP_OUT, type(uint256).max, receiver, ""
        );

        assertEq(amountOut, SWAP_OUT);
        assertEq(router.lastValue(), AMOUNT_IN, "msg.value must be forwarded to the router");
        assertEq(tokenB.balanceOf(receiver), SWAP_OUT);
    }

    function test_NativeInput_ValueMismatchReverts() public {
        vm.deal(taker, AMOUNT_IN);
        router.configure(address(0), AMOUNT_IN, address(tokenB), SWAP_OUT);

        vm.prank(taker);
        vm.expectRevert(UniswapV4SwapHelpers.InvalidValue.selector);
        helper.swapExactInSingle{ value: AMOUNT_IN - 1 }(
            _key(address(0), address(tokenB)), true, AMOUNT_IN, SWAP_OUT, type(uint256).max, receiver, ""
        );
    }

    function test_ERC20Input_NonZeroValueReverts() public {
        vm.deal(taker, 1 ether);
        router.configure(address(tokenA), AMOUNT_IN, address(tokenB), SWAP_OUT);

        vm.prank(taker);
        vm.expectRevert(UniswapV4SwapHelpers.InvalidValue.selector);
        helper.swapExactInSingle{ value: 1 }(
            _key(address(tokenA), address(tokenB)), true, AMOUNT_IN, SWAP_OUT, type(uint256).max, receiver, ""
        );
    }

    function test_AmountOverflowsUint128Reverts() public {
        router.configure(address(tokenA), AMOUNT_IN, address(tokenB), SWAP_OUT);

        vm.prank(taker);
        vm.expectRevert(UniswapV4SwapHelpers.AmountOverflowsUint128.selector);
        helper.swapExactInSingle(
            _key(address(tokenA), address(tokenB)),
            true,
            uint256(type(uint128).max) + 1,
            SWAP_OUT,
            type(uint256).max,
            receiver,
            ""
        );
    }

    function test_Version() public view {
        assertEq(helper.VERSION(), 3, "VERSION must be bumped to 3 with the balance-delta fix");
    }
}
