// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { VM } from "./weiroll/VM.sol";
import { IExecutor } from "src/interfaces/IExecutor.sol";

/**
 * @title ExecutionProxy
 * @notice Weiroll VM executor invoked by the Router. Holds no user approvals, no fee
 *         state, and no economic logic: the Router owns pulls, fees, slippage, and
 *         recipient transfers and calls `executePath` to run a Weiroll program.
 * @dev Callable only by the Router bound at construction. The Router stages user funds
 *      on this contract before and during `executePath`, so an open entry point would
 *      let anyone (including a partner-fee recipient reentering mid-swap, or any address
 *      once funds sit here between transactions) run an arbitrary program against that
 *      balance. Restricting the caller to the Router puts every execution behind the
 *      Router's `nonReentrant` boundary and its balance-diff accounting.
 *
 *      Otherwise deliberately minimal: no owner, no storage beyond the immutable Router
 *      address, no reentrancy guard of its own, no typed-data signatures, no admin
 *      functions. Minimizes the audit surface of the arbitrary-execution piece per FR-11.
 *
 *      `receive()` and `fallback()` remain payable so the Router can forward native ETH
 *      via `executor.call{value: ...}(...)` and Weiroll sub-calls (e.g. WETH unwraps)
 *      can return it. Native ETH that lands here outside a swap is not recoverable by
 *      third parties; only a Router-driven program can move it.
 */
contract ExecutionProxy is VM, IExecutor {
    /// @notice Native ETH sentinel address shared with the Router and Weiroll helper
    ///         programs that branch on native vs. ERC20 tokens.
    /// @dev Declared without an explicit visibility modifier so it is a pure
    ///      compile-time constant with no storage slot.
    address constant NATIVE_ETH_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice The only address allowed to call `executePath`.
    address public immutable ROUTER;

    /// @dev `executePath` was called by an address other than `ROUTER`.
    error NotRouter(address caller);
    /// @dev Constructor received the zero address.
    error ZeroRouter();

    /// @param router The Router that will drive this executor. Fixed for the life of the
    ///        contract; rotating the Router means deploying a new executor and wiring it
    ///        through `Router.setPendingExecutor` / `acceptExecutor`.
    constructor(address router) {
        if (router == address(0)) revert ZeroRouter();
        ROUTER = router;
    }

    /// @inheritdoc IExecutor
    function executePath(bytes32[] calldata commands, bytes[] calldata state) external payable override {
        if (msg.sender != ROUTER) revert NotRouter(msg.sender);
        _execute(commands, state);
    }

    /// @notice Accept native ETH forwarded by the Router or returned by Weiroll sub-calls.
    receive() external payable { }

    /// @notice Accept native ETH via fallback for callers that do not target `receive()`.
    fallback() external payable { }
}
