// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/**
 * @title IExecutor
 * @notice Minimal interface for the Weiroll VM executor that the Router delegates path execution to.
 * @dev The Router pulls user input tokens, transfers them to the executor, and then invokes
 *      `executePath` to run the supplied Weiroll program. The executor returns nothing: the
 *      Router measures produced output via pre/post balance deltas on itself, so any amount
 *      produced by the program must be transferred back to the Router as part of the program.
 *
 *      The function is `payable` so the Router can forward native ETH (wrapped via `.call{value}`)
 *      to the executor in the same call when the input token is the native ETH sentinel.
 *
 *      Implementations must restrict `executePath` to the Router that drives them: the Router
 *      stages user funds on the executor before calling it, so an open entry point would let
 *      any address run a program against those funds.
 *
 *      Reverts inside the executor (including out-of-gas, explicit `revert`, or failed sub-calls)
 *      propagate up to the Router. No `try/catch` is used, preserving atomic failure: a partial
 *      execution never leaves user funds stranded because the entire transaction is rolled back.
 */
interface IExecutor {
    /**
     * @notice Execute a Weiroll program.
     * @param commands Weiroll command array encoding the sequence of calls to perform.
     * @param state Weiroll state array holding inputs to and outputs from the commands.
     */
    function executePath(bytes32[] calldata commands, bytes[] calldata state) external payable;
}
