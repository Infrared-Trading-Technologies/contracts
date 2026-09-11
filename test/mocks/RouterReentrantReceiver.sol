// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITransferCallback } from "./AdversarialTokens.sol";
import { Router } from "../../src/Router.sol";

/// @title RouterReentrantReceiver
/// @notice Re-entrancy attacker targeting `Router.swap`. On receiving native ETH (via `receive`)
///         or an ERC20 callback (via `onTokenTransfer`), attempts to re-enter `router.swap(...)`
///         inside a `try/catch`. The outer swap is expected to complete because the Router's
///         `nonReentrant` modifier reverts the inner call; the recorded selector lets the test
///         assert that the revert came from OpenZeppelin's `ReentrancyGuardReentrantCall()`
///         rather than any downstream validation.
/// @dev Used by `test/Router.Adversarial.t.sol` (INF-0011) for the FR-16 coverage. The reentry
///      params are intentionally minimal -- real calldata is not needed because `nonReentrant`
///      runs before any validation in the Router, so the inner call reverts with the guard's
///      selector regardless of the `SwapParams` contents.
contract RouterReentrantReceiver is ITransferCallback {
    Router public immutable router;

    bool public attackEnabled;
    bool public attackAttempted;
    bool public attackSucceeded;
    bytes4 public lastRevertSelector;

    constructor(Router _router) {
        router = _router;
    }

    /// @notice Toggle the reentry attempt. Off by default so accidental transfers during setup
    ///         do not count as attacks.
    function setAttackEnabled(bool enabled) external {
        attackEnabled = enabled;
    }

    /// @notice Reset the attack ledger between test cases.
    function resetAttackState() external {
        attackAttempted = false;
        attackSucceeded = false;
        lastRevertSelector = bytes4(0);
    }

    /// @inheritdoc ITransferCallback
    function onTokenTransfer(address, address, uint256) external override {
        _tryReenter();
    }

    receive() external payable {
        _tryReenter();
    }

    function _tryReenter() internal {
        if (!attackEnabled) return;
        attackAttempted = true;

        Router.SwapParams memory p = Router.SwapParams({
            inputToken: address(0x1111111111111111111111111111111111111111),
            inputAmount: 1,
            outputToken: address(0x2222222222222222222222222222222222222222),
            outputQuote: 1,
            outputMin: 1,
            recipient: address(this),
            protocolFeeBps: 0,
            partnerFeeBps: 0,
            partnerRecipient: address(0),
            partnerFeeOnOutput: false,
            passPositiveSlippageToUser: false,
            weirollCommands: new bytes32[](0),
            weirollState: new bytes[](0)
        });

        // Any Authorization works here: `nonReentrant` reverts before it is inspected.
        Router.Authorization memory auth = Router.Authorization({ nonce: bytes32(0), expiry: 0, signature: "" });
        try router.swap(p, auth) returns (uint256) {
            attackSucceeded = true;
        } catch (bytes memory reason) {
            attackSucceeded = false;
            if (reason.length >= 4) {
                lastRevertSelector = bytes4(reason);
            }
        }
    }
}
