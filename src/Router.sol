// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { ISignatureTransfer } from "permit2/interfaces/ISignatureTransfer.sol";

import { IExecutor } from "src/interfaces/IExecutor.sol";

/// @notice Library carrying errors that would collide with identifiers inherited by Router.
/// @dev `Paused` shares its name with the `Paused(address)` event inherited from OpenZeppelin's
///      `Pausable`. Solidity rejects reusing an identifier across kinds (event vs. error) within
///      the same contract scope and resolves an unqualified `Paused()` to the inherited event,
///      so the error is defined here and referenced as `RouterErrors.Paused()` at the revert site.
library RouterErrors {
    error Paused();
}

/**
 * @title Router
 * @notice User-facing entry point for the Infrared execution layer. The Router holds user ERC20
 *         approvals and native ETH, applies the protocol fee (on input), the partner fee
 *         (input- or output-denominated), and captures positive slippage between the backend-
 *         supplied `outputQuote` and the executor-produced amount. All economic logic lives
 *         here; the executor is a pure Weiroll VM invoked via `IExecutor.executePath`.
 * @dev This file freezes the Router ABI (events, errors, entry-point signatures, admin surface,
 *      sweep surface) so downstream tasks can land in parallel. Real implementations for
 *      `swap`, `swapMulti`, and `swapRouterFunds` land in INF-0005 and INF-0006 without
 *      changing any signature declared here.
 */
contract Router is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Errors
    //
    // The eighteen errors below are contract-scoped so external callers (tests,
    // off-chain consumers) can reference them as `Router.ErrorName.selector`.
    // `Paused` lives in the `RouterErrors` library above to avoid the event/error
    // identifier collision documented on that library.
    // -------------------------------------------------------------------------

    error ZeroInputAmount();
    error ZeroOutputQuote();
    error ZeroOutputMin();
    error InvalidSlippageBounds();
    error SelfSwap();
    error ProtocolFeeExceedsCap(uint256 bps);
    error PartnerFeeExceedsCap(uint256 bps);
    error InvalidPartnerRecipient();
    error ETHValueMismatch();
    error SlippageExceeded(address token, uint256 got, uint256 min);
    error ETHTransferFailed();
    error DuplicateToken(address token);
    error InputOutputIntersection(address token);
    error Unauthorized();
    error ExecutorNotSet();
    error ZeroAddress();
    error ArrayLengthMismatch();
    error NativeInputNotPermit2Compatible();
    error InsufficientRouterBalance();

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Sentinel address used to represent native ETH in input/output positions.
    ///         Shared with the executor and Weiroll helper programs.
    address public constant NATIVE_ETH_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice Hard cap on the caller-supplied `protocolFeeBps`. Immutable guarantee that
    ///         the protocol fee taken from user input never exceeds 2.00%.
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 200;

    /// @notice Hard cap on the caller-supplied `partnerFeeBps`. Immutable guarantee that
    ///         the partner fee never exceeds 2.00%. Caps are applied independently of the
    ///         protocol fee; the theoretical combined worst case on input is 4.00%.
    uint256 public constant MAX_PARTNER_FEE_BPS = 200;

    /// @notice Canonical Permit2 deployment. Same address on every chain Permit2 is deployed
    ///         to (Ethereum, Base, Sepolia, Base Sepolia, and beyond). Hardcoded rather than
    ///         caller-supplied so calldata cannot point at a contract that returns success
    ///         without transferring tokens.
    ISignatureTransfer public constant PERMIT2 = ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    /// @notice Parameters for a single-input, single-output swap. Assembled by the backend
    ///         quoting engine and passed verbatim to `swap`.
    struct SwapParams {
        address inputToken;
        uint256 inputAmount;
        address outputToken;
        uint256 outputQuote;
        uint256 outputMin;
        address recipient;
        uint16 protocolFeeBps;
        uint16 partnerFeeBps;
        address partnerRecipient;
        bool partnerFeeOnOutput;
        bool passPositiveSlippageToUser;
        bytes32[] weirollCommands;
        bytes[] weirollState;
    }

    /// @notice Caller-supplied Permit2 authorization for `swapPermit2` / `swapMultiPermit2`.
    /// @dev Router builds the `TokenPermissions` (single) or `TokenPermissions[]` (batch) from
    ///      the swap params at the call site, so the user's signature commits to the exact
    ///      `inputAmount` (or `inputAmounts[i]`) being requested. Replay protection (nonce
    ///      uniqueness, deadline expiry) is enforced by Permit2 itself; Router does no nonce
    ///      bookkeeping of its own.
    struct Permit2Data {
        uint256 nonce;
        uint256 deadline;
        bytes signature;
    }

    /// @notice Parameters for an atomic multi-input, multi-output swap.
    struct MultiSwapParams {
        address[] inputTokens;
        uint256[] inputAmounts;
        address[] outputTokens;
        uint256[] outputQuotes;
        uint256[] outputMins;
        address recipient;
        uint16 protocolFeeBps;
        uint16 partnerFeeBps;
        address partnerRecipient;
        bool partnerFeeOnOutput;
        bool passPositiveSlippageToUser;
        bytes32[] weirollCommands;
        bytes[] weirollState;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted once per single-input, single-output swap (`swap` / `swapPermit2`). The
    ///         ten fields are sufficient to reconstruct full fee attribution off-chain per FR-17.
    ///         Multi-swaps emit `MultiSwap` instead.
    event Swap(
        address indexed sender,
        address inputToken,
        uint256 inputAmount,
        address outputToken,
        uint256 amountOut,
        uint256 amountToUser,
        uint256 protocolFee,
        uint256 partnerFee,
        uint256 positiveSlippageCaptured,
        address partnerRecipient
    );

    /// @notice Emitted once per multi-input, multi-output swap (`swapMulti` / `swapMultiPermit2`).
    ///         Every amount is denominated in the token at the same index of its parallel
    ///         token array, so values are never summed across tokens with different decimals.
    /// @param sender            `msg.sender` of the swap.
    /// @param inputTokens       Input tokens, as supplied in `MultiSwapParams.inputTokens`.
    /// @param inputAmounts      Caller-declared input amounts (parallel to `inputTokens`).
    /// @param protocolFees      Protocol fee retained per input token (parallel to `inputTokens`).
    /// @param inputPartnerFees  Input-side partner fee paid per input token (parallel to
    ///                          `inputTokens`); all zero when `partnerFeeOnOutput` is true.
    /// @param outputTokens      Output tokens, as supplied in `MultiSwapParams.outputTokens`.
    /// @param amountsOut        Gross realized output per output token, i.e.
    ///                          `amountsToUser + outputPartnerFees + positiveSlippagesCaptured`.
    /// @param amountsToUser     Net amount delivered to `recipient` per output token.
    /// @param outputPartnerFees Output-side partner fee paid per output token; all zero when
    ///                          `partnerFeeOnOutput` is false.
    /// @param positiveSlippagesCaptured Surplus above `outputQuotes[j]` retained by the Router
    ///                          per output token; all zero when `passPositiveSlippageToUser`.
    /// @param partnerRecipient  Partner fee recipient (zero address when no partner fee).
    event MultiSwap(
        address indexed sender,
        address[] inputTokens,
        uint256[] inputAmounts,
        uint256[] protocolFees,
        uint256[] inputPartnerFees,
        address[] outputTokens,
        uint256[] amountsOut,
        uint256[] amountsToUser,
        uint256[] outputPartnerFees,
        uint256[] positiveSlippagesCaptured,
        address partnerRecipient
    );

    /// @notice Emitted when the owner updates the liquidator address.
    event LiquidatorUpdated(address previousLiquidator, address newLiquidator);

    /// @notice Emitted when the owner proposes a new executor. Completion requires
    ///         a subsequent `acceptExecutor` call.
    event PendingExecutorSet(address pendingExecutor);

    /// @notice Emitted when the pending executor is promoted to the active executor.
    event ExecutorUpdated(address previousExecutor, address newExecutor);

    /// @notice Emitted when accrued fees or retained slippage are swept via `transferRouterFunds`.
    event FundsTransferred(address[] tokens, uint256[] amounts, address dest);

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @notice Active executor. Router forwards remaining input tokens here and invokes
    ///         `IExecutor.executePath` on this address.
    address public executor;

    /// @notice Executor proposed by the owner but not yet accepted. Cleared on accept.
    address public pendingExecutor;

    /// @notice Hot-wallet address authorized alongside the owner to call sweep functions.
    ///         Separated from the owner so routine sweeps do not require multisig signatures.
    address public liquidator;

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    /// @dev Gates the sweep functions. Reverts with the spec-named `Unauthorized` error
    ///      rather than the OZ `OwnableUnauthorizedAccount` since a non-owner liquidator
    ///      is also allowed.
    modifier onlyOwnerOrLiquidator() {
        if (msg.sender != owner() && msg.sender != liquidator) {
            revert Unauthorized();
        }
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /**
     * @param _owner Initial owner (expected to be a multisig). Must be non-zero.
     * @param _liquidator Initial liquidator. Must be non-zero at construction; may later be
     *        set to `address(0)` via `setLiquidator` to disable the role.
     */
    constructor(address _owner, address _liquidator) Ownable(_owner) {
        if (_owner == address(0)) revert ZeroAddress();
        if (_liquidator == address(0)) revert ZeroAddress();
        liquidator = _liquidator;
        emit LiquidatorUpdated(address(0), _liquidator);
    }

    // -------------------------------------------------------------------------
    // Pausable override
    // -------------------------------------------------------------------------

    /// @dev Override OZ's default so the `whenNotPaused` modifier reverts with the
    ///      spec-named `Paused` error rather than `EnforcedPause`. The error lives in
    ///      `RouterErrors` to avoid a name collision with OZ's `Paused(address)` event.
    function _requireNotPaused() internal view virtual override {
        if (paused()) revert RouterErrors.Paused();
    }

    // -------------------------------------------------------------------------
    // Admin surface
    // -------------------------------------------------------------------------

    /// @notice Propose a new executor. Effect is deferred until `acceptExecutor` is called.
    function setPendingExecutor(address newPendingExecutor) external onlyOwner {
        pendingExecutor = newPendingExecutor;
        emit PendingExecutorSet(newPendingExecutor);
    }

    /// @notice Promote the pending executor to the active executor. Owner-driven per the spec.
    function acceptExecutor() external onlyOwner {
        address newExecutor = pendingExecutor;
        if (newExecutor == address(0)) revert ExecutorNotSet();
        address previousExecutor = executor;
        executor = newExecutor;
        pendingExecutor = address(0);
        emit ExecutorUpdated(previousExecutor, newExecutor);
    }

    /// @notice Update the liquidator address. Zero address is permitted and disables the role.
    function setLiquidator(address newLiquidator) external onlyOwner {
        address previousLiquidator = liquidator;
        liquidator = newLiquidator;
        emit LiquidatorUpdated(previousLiquidator, newLiquidator);
    }

    /// @notice Emergency stop. All swap entry points revert with `Paused` while active.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Lift the emergency stop.
    function unpause() external onlyOwner {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // Internal swap helpers
    // -------------------------------------------------------------------------

    /// @dev Validation common to both user-initiated `swap` and liquidator-initiated
    ///      `swapRouterFunds`. Mirrors the Error Handling table in the spec; the only
    ///      check left out is the msg.value / native-input reconciliation, which is
    ///      applied in `_validateSwap` for the user-facing path but skipped for the
    ///      Router-funded path (Router already holds the input balance).
    function _validateSwapCommon(SwapParams calldata p) internal view {
        if (executor == address(0)) revert ExecutorNotSet();
        if (p.inputAmount == 0) revert ZeroInputAmount();
        if (p.outputQuote == 0) revert ZeroOutputQuote();
        if (p.outputMin == 0) revert ZeroOutputMin();
        if (p.outputMin > p.outputQuote) revert InvalidSlippageBounds();
        if (p.inputToken == p.outputToken) revert SelfSwap();
        if (p.protocolFeeBps > MAX_PROTOCOL_FEE_BPS) revert ProtocolFeeExceedsCap(p.protocolFeeBps);
        if (p.partnerFeeBps > MAX_PARTNER_FEE_BPS) revert PartnerFeeExceedsCap(p.partnerFeeBps);
        if (p.partnerFeeBps > 0 && p.partnerRecipient == address(0)) revert InvalidPartnerRecipient();
    }

    /// @dev Full validation for the user-facing `swap` entry point: common checks plus the
    ///      msg.value reconciliation (exactly `inputAmount` for native input, exactly 0 for ERC20).
    function _validateSwap(SwapParams calldata p) internal view {
        _validateSwapCommon(p);
        if (p.inputToken == NATIVE_ETH_SENTINEL) {
            if (msg.value != p.inputAmount) revert ETHValueMismatch();
        } else if (msg.value != 0) {
            revert ETHValueMismatch();
        }
    }

    /// @dev Router-balance accessor that handles the native ETH sentinel uniformly with ERC20s.
    function _balanceOf(address token) internal view returns (uint256) {
        if (token == NATIVE_ETH_SENTINEL) return address(this).balance;
        return IERC20(token).balanceOf(address(this));
    }

    /// @dev Pull `amount` of `token` from the caller into the Router and return the balance delta
    ///      actually received. For native ETH the caller has already forwarded the amount via
    ///      `msg.value` (validated in `_validateSwap`), so `amount` is returned unchanged. For
    ///      ERC20s the before/after measurement ensures fees are computed on what the Router
    ///      actually holds, never on the caller-declared amount. Fee-on-transfer tokens are NOT
    ///      supported: recipes encode exact amounts, so a transfer that delivers less than
    ///      `amount` reverts at the venue rather than settling incorrectly.
    function _pullInput(address token, uint256 amount) internal returns (uint256 pulled) {
        if (token == NATIVE_ETH_SENTINEL) {
            return amount;
        }
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        return IERC20(token).balanceOf(address(this)) - balanceBefore;
    }

    /// @dev Pay `amount` of `token` out to `to`. No-ops on zero amount (useful when partner or
    ///      positive-slippage paths are inactive). Native ETH uses `.call{value}` with full gas
    ///      forwarding so multisig receivers work; failure reverts `ETHTransferFailed`.
    function _transferOut(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token == NATIVE_ETH_SENTINEL) {
            (bool ok,) = to.call{ value: amount }("");
            if (!ok) revert ETHTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @dev Forward the remaining input to the executor and invoke `executePath`. ERC20 paths use
    ///      a standard `safeTransfer` followed by a direct interface call (natural revert bubble).
    ///      Native ETH paths encode the call via `abi.encodeCall` and pass `value` through the
    ///      low-level call; a revert inside the executor is rethrown with its original returndata.
    function _forwardToExecutor(address token, uint256 amount, bytes32[] calldata commands, bytes[] calldata state)
        internal
    {
        address exec = executor;
        if (token == NATIVE_ETH_SENTINEL) {
            (bool ok,) = exec.call{ value: amount }(abi.encodeCall(IExecutor.executePath, (commands, state)));
            if (!ok) {
                assembly {
                    returndatacopy(0, 0, returndatasize())
                    revert(0, returndatasize())
                }
            }
        } else {
            IERC20(token).safeTransfer(exec, amount);
            IExecutor(exec).executePath(commands, state);
        }
    }

    /// @dev Core swap sequence shared by `swap` and `swapRouterFunds`. Implements steps (c)..(m)
    ///      of the Behavior Specification verbatim: fee accounting, balance-diff measurement,
    ///      positive-slippage cap, output-denominated partner fee, slippage floor, payout, event.
    function _executeSwap(SwapParams calldata params, uint256 pulled) internal returns (uint256 amountOut) {
        uint256 protocolFee = (pulled * params.protocolFeeBps) / 10_000;
        uint256 inputPartnerFee = params.partnerFeeOnOutput ? 0 : (pulled * params.partnerFeeBps) / 10_000;
        if (inputPartnerFee > 0) {
            _transferOut(params.inputToken, params.partnerRecipient, inputPartnerFee);
        }

        uint256 outputBefore = _balanceOf(params.outputToken);
        _forwardToExecutor(
            params.inputToken, pulled - protocolFee - inputPartnerFee, params.weirollCommands, params.weirollState
        );
        amountOut = _balanceOf(params.outputToken) - outputBefore;

        uint256 positiveSlippage;
        if (!params.passPositiveSlippageToUser && amountOut > params.outputQuote) {
            positiveSlippage = amountOut - params.outputQuote;
            amountOut = params.outputQuote;
        }

        uint256 outputPartnerFee;
        if (params.partnerFeeOnOutput && params.partnerFeeBps > 0) {
            outputPartnerFee = (amountOut * params.partnerFeeBps) / 10_000;
            amountOut -= outputPartnerFee;
            _transferOut(params.outputToken, params.partnerRecipient, outputPartnerFee);
        }

        if (amountOut < params.outputMin) {
            revert SlippageExceeded(params.outputToken, amountOut, params.outputMin);
        }

        _transferOut(params.outputToken, params.recipient, amountOut);

        _emitSwap(
            params, amountOut, outputPartnerFee, protocolFee, inputPartnerFee + outputPartnerFee, positiveSlippage
        );
    }

    /// @dev Extracted to keep `_executeSwap`'s stack under the EVM's 16-slot limit. The event's
    ///      `amountOut` field is the raw executor-produced amount, reconstructed here as
    ///      `amountToUser + outputPartnerFee + positiveSlippage` so off-chain consumers can
    ///      tie fee attribution back to the pulled input (invariant used by INF-0012).
    function _emitSwap(
        SwapParams calldata params,
        uint256 amountToUser,
        uint256 outputPartnerFee,
        uint256 protocolFee,
        uint256 partnerFee,
        uint256 positiveSlippage
    ) internal {
        emit Swap(
            msg.sender,
            params.inputToken,
            params.inputAmount,
            params.outputToken,
            amountToUser + outputPartnerFee + positiveSlippage,
            amountToUser,
            protocolFee,
            partnerFee,
            positiveSlippage,
            params.partnerRecipient
        );
    }

    // -------------------------------------------------------------------------
    // Internal multi-swap helpers
    // -------------------------------------------------------------------------

    /// @dev O(n^2) pairwise scan that reverts `DuplicateToken(t)` on the first collision. Used
    ///      to enforce FR-8 for both the inputs array and the outputs array of a multi-swap and
    ///      also doubles as the guard that prevents more than one NATIVE_ETH_SENTINEL input
    ///      slot from appearing in `swapMulti`.
    function _requireNoDuplicates(address[] memory tokens) internal pure {
        uint256 n = tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            for (uint256 j = i + 1; j < n; ++j) {
                if (tokens[i] == tokens[j]) revert DuplicateToken(tokens[i]);
            }
        }
    }

    /// @dev O(n*m) scan that reverts `InputOutputIntersection(t)` on the first overlap. Together
    ///      with `_requireNoDuplicates` this closes the FR-8 loop: every token in a multi-swap
    ///      sits in exactly one slot, so balance-diff accounting is unambiguous.
    function _requireNoIntersection(address[] memory inputs, address[] memory outputs) internal pure {
        uint256 nIn = inputs.length;
        uint256 nOut = outputs.length;
        for (uint256 i = 0; i < nIn; ++i) {
            for (uint256 j = 0; j < nOut; ++j) {
                if (inputs[i] == outputs[j]) revert InputOutputIntersection(inputs[i]);
            }
        }
    }

    /// @dev Validation for `swapMulti`. Mirrors `_validateSwap` checks field-by-field (executor
    ///      set, fee caps, partner recipient, slippage bounds) but expanded over the input and
    ///      output arrays. Performs array-length parity, per-element zero checks, duplicate /
    ///      intersection rejection, and msg.value reconciliation against the (at most one)
    ///      NATIVE_ETH_SENTINEL input slot. Errors are identical to the single-swap validator
    ///      so off-chain consumers can share one decoder.
    function _validateMultiSwap(MultiSwapParams calldata p) internal view {
        if (executor == address(0)) revert ExecutorNotSet();

        uint256 nIn = p.inputTokens.length;
        uint256 nOut = p.outputTokens.length;

        if (nIn == 0) revert ZeroInputAmount();
        if (nOut == 0) revert ZeroOutputQuote();
        if (nIn != p.inputAmounts.length) revert ArrayLengthMismatch();
        if (nOut != p.outputQuotes.length) revert ArrayLengthMismatch();
        if (nOut != p.outputMins.length) revert ArrayLengthMismatch();

        if (p.protocolFeeBps > MAX_PROTOCOL_FEE_BPS) revert ProtocolFeeExceedsCap(p.protocolFeeBps);
        if (p.partnerFeeBps > MAX_PARTNER_FEE_BPS) revert PartnerFeeExceedsCap(p.partnerFeeBps);
        if (p.partnerFeeBps > 0 && p.partnerRecipient == address(0)) revert InvalidPartnerRecipient();

        for (uint256 i = 0; i < nIn; ++i) {
            if (p.inputAmounts[i] == 0) revert ZeroInputAmount();
        }
        for (uint256 j = 0; j < nOut; ++j) {
            if (p.outputQuotes[j] == 0) revert ZeroOutputQuote();
            if (p.outputMins[j] == 0) revert ZeroOutputMin();
            if (p.outputMins[j] > p.outputQuotes[j]) revert InvalidSlippageBounds();
        }

        _requireNoDuplicates(p.inputTokens);
        _requireNoDuplicates(p.outputTokens);
        _requireNoIntersection(p.inputTokens, p.outputTokens);

        // msg.value reconciliation. After the duplicate check there is at most one native input
        // slot; if it exists, msg.value must equal its amount. Otherwise msg.value must be zero.
        bool hasNative;
        uint256 nativeAmount;
        for (uint256 i = 0; i < nIn; ++i) {
            if (p.inputTokens[i] == NATIVE_ETH_SENTINEL) {
                hasNative = true;
                nativeAmount = p.inputAmounts[i];
                break;
            }
        }
        if (hasNative) {
            if (msg.value != nativeAmount) revert ETHValueMismatch();
        } else if (msg.value != 0) {
            revert ETHValueMismatch();
        }
    }

    /// @dev Post-pull logic shared by both the approve path (`swapMulti`) and the Permit2
    ///      path (`swapMultiPermit2`). Given the per-token amount actually received by the
    ///      Router, computes protocol + input-side partner fees, transfers any partner fee
    ///      to the partner recipient, and stages the remainder: ERC20 inputs are
    ///      `safeTransfer`red to the executor; native ETH stays on the Router and its
    ///      forwarded amount is accumulated in `nativeForwardAmount` for a single
    ///      `.call{value: ...}` to the executor by the caller.
    function _processPulledInputs(MultiSwapParams calldata params, uint256[] memory pulledArr)
        internal
        returns (uint256 nativeForwardAmount, uint256[] memory protocolFees, uint256[] memory inputPartnerFees)
    {
        uint256 n = pulledArr.length;
        protocolFees = new uint256[](n);
        inputPartnerFees = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 nativeForward;
            (protocolFees[i], inputPartnerFees[i], nativeForward) = _processOneInput(params, i, pulledArr[i]);
            nativeForwardAmount += nativeForward;
        }
    }

    /// @dev Fee computation and staging for input slot `i` of a multi-swap. Computes the
    ///      protocol fee and (when input-side) partner fee on `pulled`, pays the partner fee,
    ///      and stages the remainder: ERC20s are transferred to the executor; native ETH is
    ///      returned as `nativeForward` for the caller to attach to the `executePath` call.
    ///      Split out of `_processPulledInputs` to keep the loop body within the EVM stack limit.
    function _processOneInput(MultiSwapParams calldata params, uint256 i, uint256 pulled)
        internal
        returns (uint256 protocolFee, uint256 inputPartnerFee, uint256 nativeForward)
    {
        address token = params.inputTokens[i];
        protocolFee = (pulled * params.protocolFeeBps) / 10_000;
        inputPartnerFee = params.partnerFeeOnOutput ? 0 : (pulled * params.partnerFeeBps) / 10_000;
        if (inputPartnerFee > 0) {
            _transferOut(token, params.partnerRecipient, inputPartnerFee);
        }

        uint256 forward = pulled - protocolFee - inputPartnerFee;
        if (token == NATIVE_ETH_SENTINEL) {
            nativeForward = forward;
        } else {
            IERC20(token).safeTransfer(executor, forward);
        }
    }

    /// @dev Pull `amount` of `token` from `msg.sender` into the Router via Permit2 and return
    ///      the balance delta actually received. Mirrors `_pullInput` semantics; fee-on-transfer
    ///      tokens are NOT supported. Reverts `NativeInputNotPermit2Compatible` if `token` is
    ///      the native ETH sentinel. The user's signature must commit to `(token, amount,
    ///      permit.nonce, permit.deadline)`; a tampered amount triggers `InvalidSigner` from
    ///      Permit2.
    function _pullInputViaPermit2(address token, uint256 amount, Permit2Data calldata permit)
        internal
        returns (uint256 pulled)
    {
        if (token == NATIVE_ETH_SENTINEL) revert NativeInputNotPermit2Compatible();
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        PERMIT2.permitTransferFrom(
            ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({ token: token, amount: amount }),
                nonce: permit.nonce,
                deadline: permit.deadline
            }),
            ISignatureTransfer.SignatureTransferDetails({ to: address(this), requestedAmount: amount }),
            msg.sender,
            permit.signature
        );
        return IERC20(token).balanceOf(address(this)) - balanceBefore;
    }

    /// @dev Batch variant: pulls every `(inputTokens[i], inputAmounts[i])` into the Router via
    ///      a single `permitTransferFrom` call. Returns the per-index balance deltas. Reverts
    ///      `NativeInputNotPermit2Compatible` on any native-ETH input slot. The signed batch
    ///      `TokenPermissions[]` is constructed at the call site, so the user's single
    ///      signature commits to the full multi-token authorization.
    function _pullInputsViaPermit2(MultiSwapParams calldata params, Permit2Data calldata permit)
        internal
        returns (uint256[] memory pulledArr)
    {
        uint256 n = params.inputTokens.length;
        ISignatureTransfer.TokenPermissions[] memory permitted = new ISignatureTransfer.TokenPermissions[](n);
        ISignatureTransfer.SignatureTransferDetails[] memory details =
            new ISignatureTransfer.SignatureTransferDetails[](n);
        uint256[] memory balancesBefore = new uint256[](n);

        for (uint256 i = 0; i < n; ++i) {
            address token = params.inputTokens[i];
            if (token == NATIVE_ETH_SENTINEL) revert NativeInputNotPermit2Compatible();
            uint256 amount = params.inputAmounts[i];
            permitted[i] = ISignatureTransfer.TokenPermissions({ token: token, amount: amount });
            details[i] = ISignatureTransfer.SignatureTransferDetails({ to: address(this), requestedAmount: amount });
            balancesBefore[i] = IERC20(token).balanceOf(address(this));
        }

        PERMIT2.permitTransferFrom(
            ISignatureTransfer.PermitBatchTransferFrom({
                permitted: permitted, nonce: permit.nonce, deadline: permit.deadline
            }),
            details,
            msg.sender,
            permit.signature
        );

        pulledArr = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            pulledArr[i] = IERC20(params.inputTokens[i]).balanceOf(address(this)) - balancesBefore[i];
        }
    }

    /// @dev For each output token, measures balance delta against the pre-executor snapshot,
    ///      applies positive-slippage capping at `outputQuotes[j]` when pass-through is off,
    ///      applies the output-side partner fee, enforces `outputMins[j]`, and pays the
    ///      recipient. Mirrors step ordering from `_executeSwap` so single- and multi-swap
    ///      share the same Behavior-Spec sequence.
    function _settleOutputs(MultiSwapParams calldata params, uint256[] memory outputBefore)
        internal
        returns (uint256[] memory amountsOut, uint256[] memory positiveSlippages, uint256[] memory outputPartnerFees)
    {
        uint256 nOut = params.outputTokens.length;
        amountsOut = new uint256[](nOut);
        positiveSlippages = new uint256[](nOut);
        outputPartnerFees = new uint256[](nOut);

        for (uint256 j = 0; j < nOut; ++j) {
            address token = params.outputTokens[j];
            uint256 amt = _balanceOf(token) - outputBefore[j];

            if (!params.passPositiveSlippageToUser && amt > params.outputQuotes[j]) {
                positiveSlippages[j] = amt - params.outputQuotes[j];
                amt = params.outputQuotes[j];
            }

            if (params.partnerFeeOnOutput && params.partnerFeeBps > 0) {
                uint256 fee = (amt * params.partnerFeeBps) / 10_000;
                outputPartnerFees[j] = fee;
                amt -= fee;
                _transferOut(token, params.partnerRecipient, fee);
            }

            if (amt < params.outputMins[j]) {
                revert SlippageExceeded(token, amt, params.outputMins[j]);
            }

            _transferOut(token, params.recipient, amt);
            amountsOut[j] = amt;
        }
    }

    /// @dev Emits the single `MultiSwap` event for a multi-swap. Every per-token amount is
    ///      reported in its own token; nothing is summed or split across tokens. `amountsOut`
    ///      is reconstructed as the gross realized output so it mirrors `Swap.amountOut`.
    function _emitMultiSwap(
        MultiSwapParams calldata params,
        uint256[] memory protocolFees,
        uint256[] memory inputPartnerFees,
        uint256[] memory amountsToUser,
        uint256[] memory positiveSlippages,
        uint256[] memory outputPartnerFees
    ) internal {
        uint256 nOut = amountsToUser.length;
        uint256[] memory grossOut = new uint256[](nOut);
        for (uint256 j = 0; j < nOut; ++j) {
            grossOut[j] = amountsToUser[j] + outputPartnerFees[j] + positiveSlippages[j];
        }
        emit MultiSwap(
            msg.sender,
            params.inputTokens,
            params.inputAmounts,
            protocolFees,
            inputPartnerFees,
            params.outputTokens,
            grossOut,
            amountsToUser,
            outputPartnerFees,
            positiveSlippages,
            params.partnerRecipient
        );
    }

    // -------------------------------------------------------------------------
    // Swap entry points
    // -------------------------------------------------------------------------

    /// @notice Single-input, single-output swap. Pulls input from `msg.sender` (or accepts it as
    ///         native ETH via `msg.value`), deducts protocol and optional partner fees, forwards
    ///         the remainder to the executor, measures output via balance-diff, optionally caps
    ///         positive slippage, applies output-denominated partner fee, and pays the user.
    function swap(SwapParams calldata params) external payable nonReentrant whenNotPaused returns (uint256 amountOut) {
        _validateSwap(params);
        uint256 pulled = _pullInput(params.inputToken, params.inputAmount);
        amountOut = _executeSwap(params, pulled);
    }

    /**
     * @notice Multi-input, multi-output atomic swap. Pulls every input, deducts protocol and
     *         (optionally input-side) partner fees on each, forwards the remainder to the
     *         executor in a single `executePath` call, snapshots every output before/after,
     *         applies per-output positive-slippage capping and (optionally output-side) partner
     *         fees, enforces each `outputMins[j]`, and pays every output to `recipient`. Emits
     *         one `MultiSwap` event carrying per-token arrays.
     * @dev Fee attribution is reported per token: input-side protocol and partner fees are
     *      emitted per input token in that token's units, output-side partner fees and
     *      captured positive slippage per output token in that token's units. Amounts are
     *      never summed across tokens.
     */
    // forgefmt: disable-next-item
    function swapMulti(MultiSwapParams calldata params) external payable nonReentrant whenNotPaused returns (uint256[] memory amountsOut) {
        _validateMultiSwap(params);
        uint256 n = params.inputTokens.length;
        uint256[] memory pulledArr = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            pulledArr[i] = _pullInput(params.inputTokens[i], params.inputAmounts[i]);
        }
        amountsOut = _executeMultiSwap(params, pulledArr);
    }

    /// @notice Permit2 variant of `swap`. Pulls a single ERC20 input via
    ///         `ISignatureTransfer.permitTransferFrom` instead of relying on a prior
    ///         `approve`. The user's off-chain EIP-712 signature commits to `(inputToken,
    ///         inputAmount, permit.nonce, permit.deadline)`; replay protection is enforced
    ///         by Permit2. Native ETH inputs are rejected — use `swap` for ETH.
    function swapPermit2(SwapParams calldata params, Permit2Data calldata permit)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amountOut)
    {
        if (params.inputToken == NATIVE_ETH_SENTINEL) revert NativeInputNotPermit2Compatible();
        _validateSwapCommon(params);
        uint256 pulled = _pullInputViaPermit2(params.inputToken, params.inputAmount, permit);
        amountOut = _executeSwap(params, pulled);
    }

    /// @notice Permit2 variant of `swapMulti`. Pulls every ERC20 input via a single batched
    ///         `ISignatureTransfer.permitTransferFrom` call instead of per-token `approve`s.
    ///         The user's single signature commits to the full `(inputTokens[], inputAmounts[],
    ///         permit.nonce, permit.deadline)` set. Native ETH inputs are rejected on any
    ///         slot — use `swapMulti` for ETH.
    // forgefmt: disable-next-item
    function swapMultiPermit2(MultiSwapParams calldata params, Permit2Data calldata permit) external nonReentrant whenNotPaused returns (uint256[] memory amountsOut) {
        uint256 nIn = params.inputTokens.length;
        for (uint256 i = 0; i < nIn; ++i) {
            if (params.inputTokens[i] == NATIVE_ETH_SENTINEL) revert NativeInputNotPermit2Compatible();
        }
        _validateMultiSwap(params);
        uint256[] memory pulledArr = _pullInputsViaPermit2(params, permit);
        amountsOut = _executeMultiSwap(params, pulledArr);
    }

    /// @dev Shared post-pull body for `swapMulti` and `swapMultiPermit2`. Takes the per-token
    ///      amounts already received by the Router, processes input-side fees, forwards the
    ///      remainder to the executor, snapshots and settles outputs, and emits one `MultiSwap`
    ///      event. Behavior is identical regardless of which pull mechanism populated
    ///      `pulledArr`.
    function _executeMultiSwap(MultiSwapParams calldata params, uint256[] memory pulledArr)
        internal
        returns (uint256[] memory amountsOut)
    {
        (uint256 nativeForwardAmount, uint256[] memory protocolFees, uint256[] memory inputPartnerFees) =
            _processPulledInputs(params, pulledArr);

        uint256 nOut = params.outputTokens.length;
        uint256[] memory outputBefore = new uint256[](nOut);
        for (uint256 j = 0; j < nOut; ++j) {
            outputBefore[j] = _balanceOf(params.outputTokens[j]);
        }

        if (nativeForwardAmount > 0) {
            (bool ok,) = executor.call{ value: nativeForwardAmount }(
                abi.encodeCall(IExecutor.executePath, (params.weirollCommands, params.weirollState))
            );
            if (!ok) {
                assembly {
                    returndatacopy(0, 0, returndatasize())
                    revert(0, returndatasize())
                }
            }
        } else {
            IExecutor(executor).executePath(params.weirollCommands, params.weirollState);
        }

        uint256[] memory positiveSlippages;
        uint256[] memory outputPartnerFees;
        (amountsOut, positiveSlippages, outputPartnerFees) = _settleOutputs(params, outputBefore);

        _emitMultiSwap(params, protocolFees, inputPartnerFees, amountsOut, positiveSlippages, outputPartnerFees);
    }

    // -------------------------------------------------------------------------
    // Sweep surface
    // -------------------------------------------------------------------------

    /**
     * @notice Sweep accrued ERC20 and/or native ETH balances to `dest`. Callable only by
     *         the owner or the liquidator. Zero-length arrays are accepted as a no-op
     *         (still emits `FundsTransferred`).
     * @dev Intentionally omits `whenNotPaused`: the liquidator must be able to recover
     *      Router-held funds while the swap surface is paused.
     * @param tokens Token addresses to sweep; use `NATIVE_ETH_SENTINEL` for native ETH.
     * @param amounts Amounts to sweep (parallel to `tokens`).
     * @param dest Recipient of the swept funds.
     */
    function transferRouterFunds(address[] calldata tokens, uint256[] calldata amounts, address dest)
        external
        onlyOwnerOrLiquidator
    {
        if (tokens.length != amounts.length) revert ArrayLengthMismatch();
        if (dest == address(0)) revert ZeroAddress();

        uint256 n = tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            address token = tokens[i];
            uint256 amount = amounts[i];
            if (token == NATIVE_ETH_SENTINEL) {
                (bool ok,) = dest.call{ value: amount }("");
                if (!ok) revert ETHTransferFailed();
            } else {
                IERC20(token).safeTransfer(dest, amount);
            }
        }

        emit FundsTransferred(tokens, amounts, dest);
    }

    /**
     * @notice Sweep accrued balances by routing them through a Weiroll path rather than paying
     *         them out directly. Runs the same fee/slippage pipeline as `swap` but starts from
     *         Router-held funds: no `transferFrom`, no `msg.value`. Used to convert accumulated
     *         fee dust into a canonical token. Owner- or liquidator-gated.
     * @dev Intentionally omits `whenNotPaused`: paired with `transferRouterFunds` so the
     *      liquidator can drain or convert Router-held funds while the swap surface is paused.
     */
    function swapRouterFunds(SwapParams calldata params) external onlyOwnerOrLiquidator returns (uint256 amountOut) {
        _validateSwapCommon(params);
        if (params.recipient == address(0)) revert ZeroAddress();
        uint256 pulled = params.inputAmount;
        if (_balanceOf(params.inputToken) < pulled) revert InsufficientRouterBalance();
        amountOut = _executeSwap(params, pulled);
    }

    // -------------------------------------------------------------------------
    // Native ETH receive
    // -------------------------------------------------------------------------

    /// @notice Allow the Router to hold native ETH (protocol fees, retained positive slippage,
    ///         or direct sends from the executor during a swap).
    receive() external payable { }
}
