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
import { DeployCreate3 } from "../../script/DeployCreate3.s.sol";

/// @title UniswapV4SwapHelpersForkTest
/// @notice Fork tests for the V4 helper against real Universal Router and PoolManager
///         deployments.
///
///         Layout guard (Nethermind NM-1048 [Info]): the helper reproduces the periphery's
///         `ExactInputSingleParams` struct locally, so its field layout must match the
///         V4Router decoder behind whichever Universal Router revision the deploy script pins
///         for a chain. Some chains host two Universal Router deployments with different
///         struct shapes (5 fields on the legacy router, 6 with `minHopPriceX36` on 2.1.1),
///         and a mismatch shifts the trailing `hookData` offset and reverts inside
///         `unlockCallback`. `test_Layout_*` deploys the helper with the address returned by
///         `DeployCreate3.getUniversalRouter()` on a fork of each supported chain and runs a
///         real USDC -> USDT swap, so a wrong pin fails here before it fails on-chain.
///         `./deploy.sh deploy|dry-run <chain>` runs the matching test as a pre-deploy gate.
///
///         The guard deliberately uses an ERC20/ERC20 pool. A 5-field decoder reads the
///         `hookData` offset from the word the helper fills with `minHopPriceX36 == 0`, so it
///         lands on word 0 of the struct, `poolKey.currency0`. For a native ETH pool that word
///         is address(0), which decodes as empty `hookData` and lets the swap succeed by
///         accident; for an ERC20 currency0 it is a 160-bit "length" and the decode reverts.
///         Verified: pointing `UNIVERSAL_ROUTER` at the legacy mainnet router
///         (0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af) fails `test_Layout_Ethereum`.
///
///         Every test forks from the chain's `<CHAIN>_RPC_URL` (the `rpcEnv` names in
///         chains.json, mirrored by deploy.sh). When the variable is unset the test is skipped
///         rather than failed, so CI without RPC secrets stays green. `UNIVERSAL_ROUTER`, if
///         set, overrides the pin exactly as it does for the deploy script.
contract UniswapV4SwapHelpersForkTest is Test {
    // Ethereum mainnet. USDC/USDT hook-free pool: fee 10, tick spacing 1.
    address internal constant ETH_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant ETH_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    // Base. USDC/USDT hook-free pool: fee 100, tick spacing 1.
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant BASE_USDT = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;
    // Arbitrum One (native USDC). USDC/USDT hook-free pool: fee 100, tick spacing 1.
    address internal constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant ARB_USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;

    address internal taker;

    function setUp() public {
        taker = makeAddr("taker");
    }

    // -------------------------------------------------------------------------
    // Fork + deploy helpers
    // -------------------------------------------------------------------------

    /// @dev Select a fork from `rpcEnv`, or skip the calling test when it is unset.
    function _forkOrSkip(string memory rpcEnv) internal {
        string memory rpcUrl = vm.envOr(rpcEnv, string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl);
    }

    /// @dev Deploy a fresh helper wired to the Universal Router and Permit2 the deploy script
    ///      would use on the forked chain. The CREATE3 address does not matter here; only the
    ///      bytecode and the pinned router address are under test.
    function _deployHelperWithScriptPins() internal returns (UniswapV4SwapHelpers helper, address universalRouter) {
        DeployCreate3 script = new DeployCreate3();
        universalRouter = script.getUniversalRouter();
        assertTrue(universalRouter != address(0), "deploy script has no Universal Router pin for this chain");
        assertGt(universalRouter.code.length, 0, "pinned Universal Router has no code on this chain");
        helper = new UniswapV4SwapHelpers(IUniversalRouter(universalRouter), IPermit2(script.getPermit2()));
    }

    /// @dev Swap 10 USDC for USDT through the chain's hook-free USDC/USDT pool. USDC sorts
    ///      below USDT on every supported chain, so currency0 is a non-zero ERC20 and the
    ///      decode of a mismatched struct layout cannot succeed by accident (see contract
    ///      natspec). Succeeds only if the helper's params encoding matches the router's decoder.
    function _swapUsdcForUsdt(UniswapV4SwapHelpers helper, address usdc, address usdt, uint24 fee, int24 tickSpacing)
        internal
        returns (uint256 amountOut)
    {
        assertTrue(usdc < usdt, "USDC must be currency0");
        PoolKey memory key =
            PoolKey({ currency0: usdc, currency1: usdt, fee: fee, tickSpacing: tickSpacing, hooks: address(0) });
        uint256 amountIn = 10_000_000; // 10 USDC
        uint256 minAmountOut = 9_800_000; // 9.8 USDT, generous floor for a stable pair
        deal(usdc, taker, amountIn);
        uint256 usdtBefore = IERC20(usdt).balanceOf(taker);

        vm.startPrank(taker);
        IERC20(usdc).approve(address(helper), amountIn);
        amountOut = helper.swapExactInSingle(key, true, amountIn, minAmountOut, type(uint256).max, taker, "");
        vm.stopPrank();

        assertGe(amountOut, minAmountOut, "amountOut below floor");
        assertEq(IERC20(usdt).balanceOf(taker) - usdtBefore, amountOut, "USDT delta != returned amountOut");
        assertEq(IERC20(usdc).balanceOf(taker), 0, "USDC input must be fully consumed");
    }

    // -------------------------------------------------------------------------
    // Struct-layout guard, one test per chain the deploy script pins a router for
    // -------------------------------------------------------------------------

    function test_Layout_Ethereum() public {
        _forkOrSkip("ETH_RPC_URL");
        assertEq(block.chainid, 1, "ETH_RPC_URL must point at Ethereum mainnet");
        (UniswapV4SwapHelpers helper,) = _deployHelperWithScriptPins();
        _swapUsdcForUsdt(helper, ETH_USDC, ETH_USDT, 10, 1);
    }

    function test_Layout_Base() public {
        _forkOrSkip("BASE_RPC_URL");
        assertEq(block.chainid, 8453, "BASE_RPC_URL must point at Base");
        (UniswapV4SwapHelpers helper,) = _deployHelperWithScriptPins();
        _swapUsdcForUsdt(helper, BASE_USDC, BASE_USDT, 100, 1);
    }

    function test_Layout_ArbitrumOne() public {
        _forkOrSkip("ARBITRUM_RPC_URL");
        assertEq(block.chainid, 42161, "ARBITRUM_RPC_URL must point at Arbitrum One");
        (UniswapV4SwapHelpers helper,) = _deployHelperWithScriptPins();
        _swapUsdcForUsdt(helper, ARB_USDC, ARB_USDT, 100, 1);
    }

    // -------------------------------------------------------------------------
    // Mainnet behaviour tests
    // -------------------------------------------------------------------------

    function test_VersionBump() public {
        _forkOrSkip("ETH_RPC_URL");
        (UniswapV4SwapHelpers helper,) = _deployHelperWithScriptPins();
        assertEq(helper.VERSION(), 3, "VERSION must be bumped to 3 with the balance-delta fix");
    }

    function test_SwapExactInSingle_USDCtoUSDT() public {
        _forkOrSkip("ETH_RPC_URL");
        (UniswapV4SwapHelpers helper,) = _deployHelperWithScriptPins();
        deal(ETH_USDC, taker, 100_000_000);

        // USDC/USDT 0.001% V4 pool: fee=10, tickSpacing=1, no hooks.
        // PoolId on chain: 0x8aa4e11cbdf30eedc92100f4c8a31ff748e201d44712cc8c90d189edaa8e4e47
        PoolKey memory key =
            PoolKey({ currency0: ETH_USDC, currency1: ETH_USDT, fee: 10, tickSpacing: 1, hooks: address(0) });

        uint256 amountIn = 10_000_000; // 10 USDC
        uint256 minAmountOut = 9_800_000; // 9.8 USDT (~2% slippage tolerance for the fork test)

        uint256 usdtBefore = IERC20(ETH_USDT).balanceOf(taker);
        uint256 usdcBefore = IERC20(ETH_USDC).balanceOf(taker);

        vm.startPrank(taker);
        IERC20(ETH_USDC).approve(address(helper), amountIn);
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

        uint256 usdtAfter = IERC20(ETH_USDT).balanceOf(taker);
        uint256 usdcAfter = IERC20(ETH_USDC).balanceOf(taker);

        assertEq(usdcBefore - usdcAfter, amountIn, "USDC drain != amountIn");
        assertEq(usdtAfter - usdtBefore, amountOut, "USDT delta != returned amountOut");
        assertGe(amountOut, minAmountOut, "amountOut below floor");
        assertGt(amountOut, 0, "amountOut must be positive");
    }

    /// @notice Nethermind NM-1048 [Info]: a balance the helper already holds must not be
    ///         credited as swap output or paid to the receiver. Pre-fund the helper with USDT
    ///         and confirm the receiver only gets the swap delta against the real Universal
    ///         Router and PoolManager.
    function test_SwapExactInSingle_StrayBalanceNotCredited() public {
        _forkOrSkip("ETH_RPC_URL");
        (UniswapV4SwapHelpers helper,) = _deployHelperWithScriptPins();
        deal(ETH_USDC, taker, 100_000_000);

        PoolKey memory key =
            PoolKey({ currency0: ETH_USDC, currency1: ETH_USDT, fee: 10, tickSpacing: 1, hooks: address(0) });
        uint256 stray = 50_000_000; // 50 USDT parked in the helper by a third party
        deal(ETH_USDT, address(helper), stray);

        uint256 amountIn = 10_000_000; // 10 USDC
        uint256 minAmountOut = 9_800_000;
        uint256 usdtBefore = IERC20(ETH_USDT).balanceOf(taker);

        vm.startPrank(taker);
        IERC20(ETH_USDC).approve(address(helper), amountIn);
        uint256 amountOut = helper.swapExactInSingle(key, true, amountIn, minAmountOut, type(uint256).max, taker, "");
        vm.stopPrank();

        assertEq(IERC20(ETH_USDT).balanceOf(taker) - usdtBefore, amountOut, "receiver delta != returned amountOut");
        assertLt(amountOut, stray, "sanity: swap output must be smaller than the stray balance");
        assertEq(IERC20(ETH_USDT).balanceOf(address(helper)), stray, "stray balance must remain in the helper");
    }
}
