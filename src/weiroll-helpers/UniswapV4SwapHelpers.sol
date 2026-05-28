// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @dev Minimal Permit2 interface — just the approve entrypoint this helper
 *      calls. Canonical Permit2 deployment is
 *      0x000000000022D473030F116dDEE9F6B43aC78BA3 on every EVM chain.
 */
interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/**
 * @dev Minimal Universal Router interface — just the execute entrypoint
 *      this helper calls. Universal Router addresses differ per chain.
 */
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/**
 * @dev V4 swap-related types reproduced locally to avoid pulling in the
 *      full @uniswap/v4-core + @uniswap/v4-periphery dep trees for one
 *      helper. The byte layout matches the canonical periphery contracts
 *      exactly; the V4Router decoder reads each params element with
 *      abi.decode(bytes, ExactInputSingleParams), so the struct shape and
 *      field ordering here must match periphery byte-for-byte.
 *
 *      `minHopPriceX36` (Q36 fixed-point per-hop price floor) sits between
 *      `amountOutMinimum` and `hookData`. Zero disables the per-hop
 *      sandwich-resistance check.
 *
 *      In V4, `Currency` is `type Currency is address` — a type alias for
 *      address with zero-address sentinel = native ETH. This contract
 *      uses plain `address` throughout; the on-chain ABI encoding is
 *      identical.
 */
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct ExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    uint256 minHopPriceX36;
    bytes hookData;
}

/**
 * @notice Branched-deployed wrapper that executes a Uniswap V4 single-pool
 *         exact-input swap through Universal Router and surfaces the
 *         realized amountOut as a uint256 return value. Designed as a
 *         Weiroll command target: recipes call this once and pipe the
 *         returned amountOut downstream without needing the pre/post
 *         balanceOf bracket the bare Universal Router would require.
 *
 * @dev Pattern adapted from EnsoBuild/shortcuts-client-contracts
 *      UniswapV4SwapHelpers.sol (MIT-licensed reference).
 *
 *      Token flow:
 *
 *        caller --ERC20.approve(this, amountIn)--> this
 *        caller --swapExactInSingle(...)--------> this
 *                                                  │
 *                                                  ├─ pulls tokens via
 *                                                  │  IERC20.safeTransferFrom(
 *                                                  │    caller, this, amountIn)
 *                                                  ├─ ERC20.forceApprove(Permit2)
 *                                                  ├─ Permit2.approve(UR, amount, type(uint48).max)
 *                                                  ├─ UR.execute{value: msg.value}(
 *                                                  │    V4_SWAP commands, [blob], deadline)
 *                                                  ├─ amountOut = IERC20(tokenOut).balanceOf(this)
 *                                                  ├─ revert if amountOut < minAmountOut
 *                                                  └─ IERC20.safeTransfer(receiver, amountOut)
 *
 *      Native ETH input: when poolKey's input currency is the zero
 *      address, msg.value must equal amountIn and the helper forwards
 *      it via UR.execute{value: msg.value}. The Permit2 dance is
 *      skipped on the native-input leg.
 *
 *      This contract holds no persistent state — tokens flow through
 *      the same call frame they entered in. Approvals to Permit2 are
 *      reset every swap via forceApprove, not left dangling at max.
 */
contract UniswapV4SwapHelpers {
    using SafeERC20 for IERC20;

    /// @dev Bumps when the contract's external surface changes. Mirror
    ///      of MathHelpers.VERSION — gives operators a one-call way to
    ///      assert they're talking to the expected revision.
    uint256 public constant VERSION = 2;

    /// @dev Universal Router command byte for a V4 swap (per Uniswap
    ///      Commands library).
    uint8 internal constant V4_SWAP = 0x10;

    /// @dev V4Router action bytes for the
    ///      SWAP_EXACT_IN_SINGLE / SETTLE_ALL / TAKE_ALL sequence (per
    ///      Uniswap v4-periphery Actions library).
    uint8 internal constant ACTION_SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant ACTION_SETTLE_ALL = 0x0c;
    uint8 internal constant ACTION_TAKE_ALL = 0x0f;

    IUniversalRouter public immutable UNIVERSAL_ROUTER;
    IPermit2 public immutable PERMIT2;

    /// @dev Reverts when msg.value doesn't match the input-currency mode
    ///      (zero for ERC-20 input, non-zero for native input).
    error InvalidValue();

    /// @dev Reverts when the realized output falls below the caller's
    ///      slippage floor. Carries both observed and required values
    ///      to make off-chain diagnosis trivial.
    error InsufficientOutputAmount(uint256 amountOut, uint256 minAmountOut);

    /// @dev Reverts when amountIn / minAmountOut exceed uint128, the
    ///      width V4Router stores them at. Surfaces the typo before
    ///      the call hits Universal Router with a silently-truncated
    ///      value.
    error AmountOverflowsUint128();

    constructor(IUniversalRouter universalRouter, IPermit2 permit2) {
        UNIVERSAL_ROUTER = universalRouter;
        PERMIT2 = permit2;
    }

    /**
     * @notice Executes a V4 exact-input single-pool swap and returns the
     *         realized output amount in `tokenOut` (the non-zeroForOne
     *         currency of poolKey). The realized output is observed by
     *         this contract's own post-swap balanceOf, so the caller does
     *         not need to bracket the call with pre/post reads.
     *
     * @param poolKey         V4 pool identity (currency0, currency1, fee,
     *                        tickSpacing, hooks).
     * @param zeroForOne      true ⇒ swap currency0 for currency1.
     * @param amountIn        Input amount as uint256; narrowed to uint128
     *                        before encoding into V4 params. Reverts if
     *                        > type(uint128).max.
     * @param minAmountOut    Slippage floor as uint256; narrowed to
     *                        uint128 for V4 params and enforced again at
     *                        the end as a uint256 balance check (defense
     *                        in depth — V4Router enforces a uint128
     *                        floor itself).
     * @param deadline        Absolute Unix-second timestamp the outer
     *                        Universal Router check uses.
     * @param receiver        Address credited the realized output. May
     *                        equal `msg.sender` or differ (e.g. a Safe
     *                        owner forwarding to a vault).
     * @param hookData        Opaque bytes passed through to V4 hooks.
     *                        Empty for hook-free pools.
     *
     * @return amountOut      Realized output, observable on-chain via
     *                        the return value (no bracketing needed by
     *                        the caller).
     */
    function swapExactInSingle(
        PoolKey calldata poolKey,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        address receiver,
        bytes calldata hookData
    ) public payable returns (uint256 amountOut) {
        if (amountIn > type(uint128).max) revert AmountOverflowsUint128();
        if (minAmountOut > type(uint128).max) revert AmountOverflowsUint128();

        address currencyIn = zeroForOne ? poolKey.currency0 : poolKey.currency1;
        address currencyOut = zeroForOne ? poolKey.currency1 : poolKey.currency0;

        // Native input must arrive with msg.value == amountIn; ERC-20
        // input must arrive with msg.value == 0. Mismatches are a
        // caller bug — fail fast instead of silently leaking ETH or
        // burning a UR.execute call against the wrong currency leg.
        if (currencyIn == address(0)) {
            if (msg.value != amountIn) revert InvalidValue();
        } else {
            if (msg.value != 0) revert InvalidValue();
            IERC20(currencyIn).safeTransferFrom(msg.sender, address(this), amountIn);
            // amountIn <= type(uint128).max checked above; uint160 fits.
            // forge-lint: disable-next-line(unsafe-typecast)
            _approveToken(currencyIn, uint160(amountIn));
        }

        bytes memory commands = abi.encodePacked(V4_SWAP);
        bytes memory actions = abi.encodePacked(ACTION_SWAP_EXACT_IN_SINGLE, ACTION_SETTLE_ALL, ACTION_TAKE_ALL);

        bytes[] memory params = new bytes[](3);
        // amountIn / minAmountOut bounded above by the uint128 guard at
        // function entry; narrowing is safe by construction.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 amountIn128 = uint128(amountIn);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 minAmountOut128 = uint128(minAmountOut);
        params[0] = abi.encode(
            ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountIn: amountIn128,
                amountOutMinimum: minAmountOut128,
                minHopPriceX36: 0,
                hookData: hookData
            })
        );
        params[1] = abi.encode(currencyIn, amountIn);
        params[2] = abi.encode(currencyOut, minAmountOut);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        UNIVERSAL_ROUTER.execute{ value: msg.value }(commands, inputs, deadline);

        // Observe realized output on the helper's own balance. This
        // works for both native and ERC-20 outputs: V4's TAKE_ALL
        // delivers to this contract (which is msg.sender from UR's
        // perspective), then we forward to `receiver`.
        if (currencyOut == address(0)) {
            amountOut = address(this).balance;
        } else {
            amountOut = IERC20(currencyOut).balanceOf(address(this));
        }
        if (amountOut < minAmountOut) {
            revert InsufficientOutputAmount(amountOut, minAmountOut);
        }

        if (currencyOut == address(0)) {
            (bool ok,) = receiver.call{ value: amountOut }("");
            if (!ok) revert InvalidValue();
        } else {
            IERC20(currencyOut).safeTransfer(receiver, amountOut);
        }
    }

    /// @dev Resets the Permit2 path for `token`: helper grants Permit2
    ///      a fresh ERC-20 allowance, then Permit2 grants Universal
    ///      Router a fresh per-spender allowance with no expiration
    ///      (type(uint48).max). Both are exact-`amount` not max, so a
    ///      compromised UR cannot drain more than the current swap.
    function _approveToken(address token, uint160 amount) private {
        IERC20(token).forceApprove(address(PERMIT2), amount);
        PERMIT2.approve(token, address(UNIVERSAL_ROUTER), amount, type(uint48).max);
    }

    /// @notice Accepts native ETH refunds from Universal Router on the
    ///         native-output leg. Without a receive(), TAKE_ALL of
    ///         currencyOut == address(0) would revert when UR forwards
    ///         the proceeds to this contract.
    receive() external payable {}
}
