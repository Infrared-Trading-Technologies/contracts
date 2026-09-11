// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ExecutionProxy } from "src/ExecutionProxy.sol";
import { Router } from "src/Router.sol";
import { InvariantMockERC20, RouterHandler } from "test/helpers/RouterHandler.sol";

/// @title RouterInvariantTest
/// @notice Property-based suite for the Router's accounting invariant from the spec's §Non-
///         Functional Requirements line:
///           sumUserReceived + protocolFeesAccrued + partnerFeesPaid + positiveSlippageRetained
///             == aggregateBalanceDiffOfExecutor
///
///         The `RouterHandler` handler fuzzes `swap()` and `swapMulti()` across a bounded token
///         universe (4 ERC20s + NATIVE_ETH_SENTINEL), three rotating users, fee bps in `[0, 200]`,
///         and both values of `partnerFeeOnOutput` and `passPositiveSlippageToUser`. Per-call, the
///         handler records the exact components (pulled, forwarded, produced, userReceived, each
///         partner-fee side, protocolFee, positiveSlippage) into token-keyed ghost accumulators.
///         This file then asserts three invariants derived from the spec line above.
///
///         Runs under `foundry.toml`'s `invariant = { runs = 256, depth = 15 }` with
///         `fail_on_revert = false` (default) so that handler calls whose randomly-drawn inputs
///         would revert on the Router's own validation paths are discarded from the sequence
///         rather than failing the run.
contract RouterInvariantTest is Test {
    Router public router;
    ExecutionProxy public executor;
    RouterHandler public handler;

    address public constant NATIVE_ETH_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function setUp() public {
        // Owner and liquidator are this test contract -- neither is exercised by the handler, and
        // the admin surface is covered separately in test/Router.Access.t.sol.
        (address authSigner, uint256 authSignerPk) = makeAddrAndKey("backend-signer");
        router = new Router(address(this), address(this), authSigner);
        executor = new ExecutionProxy(address(router));
        router.setPendingExecutor(address(executor));
        router.acceptExecutor();

        address[4] memory erc20s;
        erc20s[0] = address(new InvariantMockERC20("Token A", "TKNA"));
        erc20s[1] = address(new InvariantMockERC20("Token B", "TKNB"));
        erc20s[2] = address(new InvariantMockERC20("Token C", "TKNC"));
        erc20s[3] = address(new InvariantMockERC20("Token D", "TKND"));

        handler = new RouterHandler(router, erc20s, authSignerPk);

        // Wire the fuzzer to only call the handler's `swapRandom` and `swapMultiRandom` entry
        // points. All other handler-internal helpers (`_computeInputFees`, `_updateOutputGhosts`,
        // etc.) are internal, but `targetSelector` gives a belt-and-suspenders whitelist so the
        // fuzzer cannot pick up inherited `Test` functions by accident.
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = handler.swapRandom.selector;
        selectors[1] = handler.swapMultiRandom.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    // -------------------------------------------------------------------------
    // Invariants
    // -------------------------------------------------------------------------

    /// @notice Spec §Non-Functional Requirements conservation law, unrolled per-token:
    ///           sumUserReceived + protocolFeesAccrued + partnerFeesPaid + positiveSlippageRetained
    ///             == aggregateBalanceDiffOfExecutor
    ///         Because `partnerFees` and the executor's balance diff operate on different sides
    ///         of the Router (input vs. output), the aggregate statement only closes when split
    ///         into two independently-checkable per-role equations that we assert below:
    ///
    ///           Output role:  userReceived[T] + outputPartnerFees[T] + positiveSlippage[T]
    ///                           == executorOutflow[T]             (= amount produced by executor)
    ///
    ///           Input  role:  executorInflow[T] + protocolFees[T] + inputPartnerFees[T]
    ///                           == pulled[T]                      (= amount taken from the user)
    ///
    ///         Summing these two over every token and substituting
    ///           produced + pulled - forwarded = executorOutflow + (pulled - executorInflow),
    ///         we recover the spec's aggregate: the left-hand side of the spec line equals the
    ///         executor's net throughput across all inputs and outputs. Any Router code change
    ///         that shifts value into or out of one of these buckets without a matching update
    ///         elsewhere fails one (or both) halves of this invariant.
    function invariant_AccountingConservation() public view {
        for (uint256 i = 0; i < handler.TOKEN_COUNT(); i++) {
            address t = handler.tokens(i);

            assertEq(
                handler.ghost_userReceived(t) + handler.ghost_positiveSlippage(t) + handler.ghost_outputPartnerFees(t),
                handler.ghost_executorOutflow(t),
                "output-role conservation failed"
            );

            assertEq(
                handler.ghost_executorInflow(t) + handler.ghost_protocolFees(t) + handler.ghost_inputPartnerFees(t),
                handler.ghost_pulled(t),
                "input-role conservation failed"
            );
        }
    }

    /// @notice Spec FR-13 ("fee custody and sweep") + FR-15 ("balance-diff tolerates weird
    ///         tokens"): the Router is never supposed to hold user funds beyond the intentionally
    ///         retained portion (protocol fees + captured positive slippage). Any excess would be
    ///         "residual user input" from a broken balance-diff path. This invariant pins the
    ///         Router's live balance of every token in the universe to exactly
    ///         `ghost_protocolFees[T] + ghost_positiveSlippage[T]`.
    function invariant_NoResidualUserInput() public view {
        for (uint256 i = 0; i < handler.TOKEN_COUNT(); i++) {
            address t = handler.tokens(i);
            uint256 routerBal = _routerBalance(t);
            assertEq(
                routerBal,
                handler.ghost_protocolFees(t) + handler.ghost_positiveSlippage(t),
                "router holds residual user input beyond intentional retention"
            );
        }
    }

    /// @notice Dust-accounting closure per token: every unit pulled from users or produced by the
    ///         executor is either paid to the recipient, paid to the partner, forwarded to the
    ///         executor, or retained in the Router. No unit is lost in transit. Concretely:
    ///
    ///           ghost_pulled[T] + ghost_executorOutflow[T]
    ///             == ghost_executorInflow[T]            // forwarded to executor on input side
    ///              + ghost_partnerFees[T]               // input- and output-side partner flows
    ///              + ghost_userReceived[T]              // paid to recipient on output side
    ///              + routerBalance[T]                   // retained (protocol fee + slippage)
    ///
    ///         This is the same conservation as `invariant_AccountingConservation` viewed from the
    ///         opposite direction (total in == total out + retained), but rests on the live
    ///         Router balance instead of the retention ghosts, so a bug that silently diverts
    ///         retention into outflow (or vice versa) will surface as a failure here even if the
    ///         two-role split above still balances.
    function invariant_NoDustLost() public view {
        for (uint256 i = 0; i < handler.TOKEN_COUNT(); i++) {
            address t = handler.tokens(i);
            uint256 routerBal = _routerBalance(t);
            uint256 inflow = handler.ghost_pulled(t) + handler.ghost_executorOutflow(t);
            uint256 outflowPlusHeld = handler.ghost_executorInflow(t) + handler.ghost_partnerFees(t)
                + handler.ghost_userReceived(t) + routerBal;
            assertEq(inflow, outflowPlusHeld, "token flow conservation broken -- dust lost or created");
        }
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _routerBalance(address token) internal view returns (uint256) {
        if (token == NATIVE_ETH_SENTINEL) return address(router).balance;
        return IERC20(token).balanceOf(address(router));
    }

    // Accept ETH that may arrive via the Router's owner role (e.g. sweep to owner == this test).
    receive() external payable { }
}
