// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    UniswapV4SwapHelpers,
    IUniversalRouter,
    IPermit2,
    PoolKey
} from "../../src/weiroll-helpers/UniswapV4SwapHelpers.sol";

/// @title UniswapV4SwapHelpersForkTest
/// @notice Forks Ethereum mainnet and exercises a real USDC -> USDT swap
///         through the on-chain V4 PoolManager via Universal Router 2.1.1.
///         Validates that the helper's `ExactInputSingleParams` struct
///         layout matches the deployed V4Router decoder. Without the
///         `minHopPriceX36` field the decode shifts the `bytes hookData`
///         offset and the swap reverts inside `unlockCallback`.
///
///         Requires `MAINNET_RPC_URL` (or any env var Foundry's
///         `vm.envOr` accepts via `--fork-url`).
contract UniswapV4SwapHelpersForkTest is Test {
    // Canonical mainnet addresses
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant UNIVERSAL_ROUTER_2_1_1 = 0x4C82D1fBFe28C977cBB58D8C7FF8FCF9F70a2cCA;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    UniswapV4SwapHelpers internal helper;
    address internal taker;

    function setUp() public {
        // Deploy a fresh helper at a non-canonical address against the
        // canonical UR 2.1.1 and Permit2 singletons. The CREATE3 address
        // does not matter for this test -- only the deployed bytecode
        // exercises the struct-layout fix.
        helper = new UniswapV4SwapHelpers(IUniversalRouter(UNIVERSAL_ROUTER_2_1_1), IPermit2(PERMIT2));
        taker = makeAddr("taker");
        // Fund the taker with USDC via storage-write cheat.
        deal(USDC, taker, 100_000_000);
        // Give the taker a small ETH balance for gas accounting (forge auto-funds, but be explicit).
        vm.deal(taker, 1 ether);
    }

    function test_VersionBump() public view {
        assertEq(helper.VERSION(), 2, "VERSION must be bumped to 2 with minHopPriceX36 fix");
    }

    function test_SwapExactInSingle_USDCtoUSDT() public {
        // USDC/USDT 0.001% V4 pool: fee=10, tickSpacing=1, no hooks.
        // PoolId on chain: 0x8aa4e11cbdf30eedc92100f4c8a31ff748e201d44712cc8c90d189edaa8e4e47
        PoolKey memory key = PoolKey({
            currency0: USDC,
            currency1: USDT,
            fee: 10,
            tickSpacing: 1,
            hooks: address(0)
        });

        uint256 amountIn = 10_000_000; // 10 USDC
        uint256 minAmountOut = 9_800_000; // 9.8 USDT (~2% slippage tolerance for the fork test)

        uint256 usdtBefore = IERC20(USDT).balanceOf(taker);
        uint256 usdcBefore = IERC20(USDC).balanceOf(taker);

        vm.startPrank(taker);
        IERC20(USDC).approve(address(helper), amountIn);
        uint256 amountOut = helper.swapExactInSingle(
            key,
            true, // zeroForOne: USDC (currency0) -> USDT (currency1)
            amountIn,
            minAmountOut,
            type(uint256).max, // deadline
            taker, // receiver
            "" // hookData
        );
        vm.stopPrank();

        uint256 usdtAfter = IERC20(USDT).balanceOf(taker);
        uint256 usdcAfter = IERC20(USDC).balanceOf(taker);

        assertEq(usdcBefore - usdcAfter, amountIn, "USDC drain != amountIn");
        assertEq(usdtAfter - usdtBefore, amountOut, "USDT delta != returned amountOut");
        assertGe(amountOut, minAmountOut, "amountOut below floor");
        assertGt(amountOut, 0, "amountOut must be positive");
    }
}
