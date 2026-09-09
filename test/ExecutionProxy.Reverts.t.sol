// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, stdError } from "forge-std/Test.sol";
import { ExecutionProxy } from "../src/ExecutionProxy.sol";
import { VM } from "../src/weiroll/VM.sol";
import { WeirollTestHelper } from "./helpers/WeirollTestHelper.sol";
import { RevertingTarget } from "./mocks/RevertingTarget.sol";

/// @title ExecutionProxyRevertsTest
/// @notice Nethermind NM-1048 [Low]: the Weiroll VM must classify a failed sub-call's revert
///         data before reinterpreting it. A well-formed `Error(string)` is unwrapped into
///         `ExecutionFailed(index, target, message)`, empty revert data becomes the documented
///         `"Unknown"` message, and every other payload (custom errors, `Panic(uint256)`,
///         malformed `Error(string)`) is bubbled up unchanged so callers can decode it. The
///         reported index is the position in `commands[]` of the failing command, never a
///         hardcoded zero.
///
///         The scenarios and the gas-measurement harness mirror the proof-of-concept suite
///         Nethermind supplied with the finding, with every assertion inverted to the fixed
///         behaviour. Each program runs through a raw `call` under a fixed gas cap so the test
///         sees the exact returndata bytes and the gas the frame consumed, not just "reverted".
contract ExecutionProxyRevertsTest is Test {
    ExecutionProxy internal proxy;
    RevertingTarget internal target;

    /// @dev Gas handed to each `executePath` frame. Identical across cases so consumption
    ///      figures are directly comparable.
    uint256 internal constant GAS_CAP = 10_000_000;

    /// @dev A frame that classifies and re-raises revert data must cost about what a clean
    ///      `Error(string)` frame costs. The old VM burned the whole allowance on a large
    ///      second word, so the bound is deliberately tight relative to the cap.
    uint256 internal constant MAX_GAS_MULTIPLE_OF_BASELINE = 2;

    function setUp() public {
        proxy = new ExecutionProxy(address(this));
        target = new RevertingTarget();
    }

    // -------------------------------------------------------------------------
    // Harness
    // -------------------------------------------------------------------------

    /// @dev Single-command program: CALL `sel` on `target`, no args, discard return.
    function _program(bytes4 sel) internal view returns (bytes32[] memory commands, bytes[] memory state) {
        commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildCallNoArgs(address(target), sel);
        state = new bytes[](0);
    }

    /// @dev Three-command program: [ok, ok, `sel`] so the failing index is 2.
    function _programAtIndex2(bytes4 sel) internal view returns (bytes32[] memory commands, bytes[] memory state) {
        commands = new bytes32[](3);
        commands[0] = WeirollTestHelper.buildCallNoArgs(address(target), RevertingTarget.ok.selector);
        commands[1] = commands[0];
        commands[2] = WeirollTestHelper.buildCallNoArgs(address(target), sel);
        state = new bytes[](0);
    }

    /// @dev Runs a program under `GAS_CAP` and returns the raw revert data plus the gas the
    ///      frame consumed. Asserts the program reverted.
    function _run(bytes32[] memory commands, bytes[] memory state)
        internal
        returns (bytes memory ret, uint256 gasUsed)
    {
        return _runWithCap(commands, state, GAS_CAP);
    }

    function _runWithCap(bytes32[] memory commands, bytes[] memory state, uint256 cap)
        internal
        returns (bytes memory ret, uint256 gasUsed)
    {
        bytes memory payload = abi.encodeCall(ExecutionProxy.executePath, (commands, state));
        uint256 before = gasleft();
        (bool ok, bytes memory data) = address(proxy).call{ gas: cap }(payload);
        gasUsed = before - gasleft();
        assertFalse(ok, "program was expected to revert");
        ret = data;
    }

    function _isExecutionFailed(bytes memory ret) internal pure returns (bool) {
        if (ret.length < 4) return false;
        return bytes4(ret) == VM.ExecutionFailed.selector;
    }

    function _decodeExecutionFailed(bytes memory ret)
        internal
        pure
        returns (uint256 commandIndex, address tgt, string memory message)
    {
        bytes memory body = new bytes(ret.length - 4);
        for (uint256 i = 0; i < body.length; ++i) {
            body[i] = ret[i + 4];
        }
        return abi.decode(body, (uint256, address, string));
    }

    /// @dev Gas a clean `Error(string)` revert costs through the same frame.
    function _baselineGas() internal returns (uint256 gasBaseline) {
        (bytes32[] memory c, bytes[] memory s) = _program(RevertingTarget.failString.selector);
        (, gasBaseline) = _run(c, s);
    }

    /// @dev Asserts `ret` is exactly `expected` and that the frame did not burn gas
    ///      reinterpreting it.
    function _assertBubbledRaw(bytes memory ret, bytes memory expected, uint256 gasUsed, uint256 gasBaseline)
        internal
        pure
    {
        assertFalse(_isExecutionFailed(ret), "payload must not be wrapped in ExecutionFailed");
        assertEq(ret.length, expected.length, "returndata length must equal the sub-call's");
        assertEq(ret, expected, "returndata must be bubbled byte-for-byte");
        assertLt(gasUsed, gasBaseline * MAX_GAS_MULTIPLE_OF_BASELINE, "frame must not burn gas on the payload");
    }

    // -------------------------------------------------------------------------
    // 1. Baseline: a well-formed Error(string) is unwrapped
    // -------------------------------------------------------------------------

    function test_Baseline_StringRevert_Unwrapped() public {
        (bytes32[] memory c, bytes[] memory s) = _program(RevertingTarget.failString.selector);
        (bytes memory ret,) = _run(c, s);

        assertTrue(_isExecutionFailed(ret), "expected ExecutionFailed");
        (uint256 commandIndex, address tgt, string memory message) = _decodeExecutionFailed(ret);
        assertEq(commandIndex, 0);
        assertEq(tgt, address(target));
        assertEq(message, "Too little received");
    }

    // -------------------------------------------------------------------------
    // 2. Two-word custom error: the second word must not become a string length
    // -------------------------------------------------------------------------

    function test_CustomError2Word_SmallSecondWord_BubbledRaw() public {
        uint256 gasBaseline = _baselineGas();
        target.setMinOut(0);
        (bytes32[] memory c, bytes[] memory s) = _program(RevertingTarget.failCustom2Word.selector);

        (bytes memory ret, uint256 gasUsed) = _run(c, s);

        _assertBubbledRaw(
            ret, abi.encodeWithSelector(RevertingTarget.InsufficientOutputAmount.selector, 0, 0), gasUsed, gasBaseline
        );
    }

    /// @notice A realistic wei-denominated floor in the second word used to burn the whole
    ///         allowance as memory expansion. It must now cost about what a string revert costs.
    function test_CustomError2Word_LargeSecondWord_NoGasBurn() public {
        uint256 gasBaseline = _baselineGas();
        target.setMinOut(1e18);
        (bytes32[] memory c, bytes[] memory s) = _program(RevertingTarget.failCustom2Word.selector);

        (bytes memory ret, uint256 gasUsed) = _run(c, s);

        _assertBubbledRaw(
            ret,
            abi.encodeWithSelector(RevertingTarget.InsufficientOutputAmount.selector, 0, 1e18),
            gasUsed,
            gasBaseline
        );
        assertLt(gasUsed, GAS_CAP / 20, "frame must consume a small fraction of its allowance");
    }

    // -------------------------------------------------------------------------
    // 3. Three-word custom error: the adjacent word must not leak as the message
    // -------------------------------------------------------------------------

    function test_CustomError3Word_AdjacentWordNotLeaked() public {
        uint256 gasBaseline = _baselineGas();
        uint256 leak = uint256(bytes32("LEAKED-THIRD-ARGUMENT"));
        target.setLeakWord(leak);
        (bytes32[] memory c, bytes[] memory s) = _program(RevertingTarget.failCustom3Word.selector);

        (bytes memory ret, uint256 gasUsed) = _run(c, s);

        _assertBubbledRaw(
            ret, abi.encodeWithSelector(RevertingTarget.ThreeWordError.selector, 0, 32, leak), gasUsed, gasBaseline
        );
    }

    // -------------------------------------------------------------------------
    // 4. Four-byte custom error: shorter than an Error(string) header
    // -------------------------------------------------------------------------

    function test_CustomError0Word_BubbledRaw() public {
        uint256 gasBaseline = _baselineGas();
        (bytes32[] memory c, bytes[] memory s) = _program(RevertingTarget.failCustom0Word.selector);

        (bytes memory ret, uint256 gasUsed) = _run(c, s);

        _assertBubbledRaw(ret, abi.encodeWithSelector(RevertingTarget.Unauthorized.selector), gasUsed, gasBaseline);
    }

    // -------------------------------------------------------------------------
    // 5. Empty revert data keeps the documented "Unknown" fallback
    // -------------------------------------------------------------------------

    function test_EmptyRevert_ReportsUnknown() public {
        (bytes32[] memory c, bytes[] memory s) = _programAtIndex2(RevertingTarget.failEmpty.selector);
        (bytes memory ret,) = _run(c, s);

        assertTrue(_isExecutionFailed(ret), "expected ExecutionFailed");
        (uint256 commandIndex, address tgt, string memory message) = _decodeExecutionFailed(ret);
        assertEq(commandIndex, 2);
        assertEq(tgt, address(target));
        assertEq(message, "Unknown");
    }

    // -------------------------------------------------------------------------
    // 6. Panic(uint256) is not an Error(string)
    // -------------------------------------------------------------------------

    function test_Panic_BubbledRaw() public {
        uint256 gasBaseline = _baselineGas();
        (bytes32[] memory c, bytes[] memory s) = _program(RevertingTarget.failPanicDivByZero.selector);

        (bytes memory ret, uint256 gasUsed) = _run(c, s);

        _assertBubbledRaw(ret, stdError.divisionError, gasUsed, gasBaseline);
    }

    // -------------------------------------------------------------------------
    // 7. Right selector and length, malformed body: must not be unwrapped
    // -------------------------------------------------------------------------

    function test_MalformedErrorString_BubbledRaw() public {
        uint256 gasBaseline = _baselineGas();
        (bytes32[] memory c, bytes[] memory s) = _program(RevertingTarget.failMalformedErrorString.selector);

        (bytes memory ret, uint256 gasUsed) = _run(c, s);

        _assertBubbledRaw(
            ret, abi.encodePacked(bytes4(0x08c379a0), uint256(0x40), uint256(type(uint128).max)), gasUsed, gasBaseline
        );
    }

    // -------------------------------------------------------------------------
    // 8. The reported command index is the failing command's position
    // -------------------------------------------------------------------------

    function test_CommandIndex_IsFailingCommandPosition() public {
        (bytes32[] memory c, bytes[] memory s) = _programAtIndex2(RevertingTarget.failString.selector);
        (bytes memory ret,) = _run(c, s);

        assertTrue(_isExecutionFailed(ret), "expected ExecutionFailed");
        (uint256 commandIndex, address tgt, string memory message) = _decodeExecutionFailed(ret);
        assertEq(commandIndex, 2, "index must be the failing command's position");
        assertEq(tgt, address(target));
        assertEq(message, "Too little received");
    }

    /// @notice For an extended (two-word) command the index is that of its first word, not
    ///         the indices word the VM advanced to.
    function test_CommandIndex_ExtendedCommandIsFirstWord() public {
        bytes32[] memory commands = new bytes32[](4);
        commands[0] = WeirollTestHelper.buildCallNoArgs(address(target), RevertingTarget.ok.selector);
        uint8[] memory noArgs = new uint8[](0);
        (commands[1], commands[2]) = WeirollTestHelper.encodeExtendedCommand(
            RevertingTarget.failString.selector,
            WeirollTestHelper.FLAG_CT_CALL,
            noArgs,
            WeirollTestHelper.IDX_END_OF_ARGS,
            address(target)
        );
        commands[3] = commands[0];
        bytes[] memory state = new bytes[](0);

        (bytes memory ret,) = _run(commands, state);

        assertTrue(_isExecutionFailed(ret), "expected ExecutionFailed");
        (uint256 commandIndex,,) = _decodeExecutionFailed(ret);
        assertEq(commandIndex, 1, "index must be the extended command's first word");
    }

    // -------------------------------------------------------------------------
    // 9. Gas consumption must not track the allowance
    // -------------------------------------------------------------------------

    /// @notice The old VM drained whatever allowance the frame was given. Consumption must now
    ///         be flat across allowances and stay near the clean string-revert baseline.
    function test_GasConsumption_IndependentOfAllowance() public {
        uint256 gasBaseline = _baselineGas();
        target.setMinOut(1e18);
        (bytes32[] memory c, bytes[] memory s) = _program(RevertingTarget.failCustom2Word.selector);
        bytes memory expected = abi.encodeWithSelector(RevertingTarget.InsufficientOutputAmount.selector, 0, 1e18);

        uint256[4] memory caps = [uint256(300_000), 1_000_000, 5_000_000, 20_000_000];
        for (uint256 i = 0; i < caps.length; ++i) {
            (bytes memory ret, uint256 used) = _runWithCap(c, s, caps[i]);
            assertEq(ret, expected, "returndata must be bubbled under every allowance");
            assertLt(used, gasBaseline * MAX_GAS_MULTIPLE_OF_BASELINE, "consumption must not scale with allowance");
            assertLt(used, caps[i] / 10, "frame must leave the bulk of its allowance unused");
        }
    }
}
