// SPDX-License-Identifier: MIT

pragma solidity ^0.8.11;

import "./CommandBuilder.sol";

abstract contract VM {
    using CommandBuilder for bytes[];

    uint256 constant FLAG_CT_DELEGATECALL = 0x00;
    uint256 constant FLAG_CT_CALL = 0x01;
    uint256 constant FLAG_CT_STATICCALL = 0x02;
    uint256 constant FLAG_CT_VALUECALL = 0x03;
    uint256 constant FLAG_CT_MASK = 0x03;
    uint256 constant FLAG_DATA = 0x20;
    uint256 constant FLAG_EXTENDED_COMMAND = 0x40;
    uint256 constant FLAG_TUPLE_RETURN = 0x80;

    uint256 constant SHORT_COMMAND_FILL = 0x000000000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

    /// @dev Selector of the compiler's `Error(string)` revert payload.
    bytes4 constant ERROR_STRING_SELECTOR = 0x08c379a0;

    address immutable self;

    /// @notice A command's sub-call reverted with a well-formed `Error(string)` payload
    ///         (`message` is that string) or with no payload at all (`message` is "Unknown").
    ///         Any other revert payload (custom errors, `Panic(uint256)`, malformed data) is
    ///         bubbled up unchanged instead, so callers can decode it.
    /// @param command_index Position in `commands[]` of the failing command's first word.
    /// @param target        Address the failing command called.
    error ExecutionFailed(uint256 command_index, address target, string message);

    constructor() {
        self = address(this);
    }

    function _execute(bytes32[] calldata commands, bytes[] memory state) internal returns (bytes[] memory) {
        bytes32 command;
        uint256 flags;
        bytes32 indices;

        bool success;
        bytes memory outdata;

        uint256 commandsLength = commands.length;
        for (uint256 i; i < commandsLength;) {
            // Index of this command's first word, reported on failure. `i` itself moves on
            // to the indices word for extended commands.
            uint256 commandIndex = i;
            command = commands[i];
            flags = uint256(uint8(bytes1(command << 32)));

            if (flags & FLAG_EXTENDED_COMMAND != 0) {
                // Pre-increment so we read Word 2 (the 32-byte slot-indices array),
                // not Word 1 again. The trailing `++i` at the bottom of the loop
                // then advances past Word 2 to the next command.
                unchecked {
                    ++i;
                }
                indices = commands[i];
            } else {
                indices = bytes32(uint256(command << 40) | SHORT_COMMAND_FILL);
            }

            if (flags & FLAG_CT_MASK == FLAG_CT_CALL) {
                (success, outdata) = address(uint160(uint256(command)))
                    .call( // target
                        // inputs
                        state.buildInputs(
                            //selector
                            bytes4(command),
                            indices
                        )
                    );
            } else if (flags & FLAG_CT_MASK == FLAG_CT_STATICCALL) {
                (success, outdata) = address(uint160(uint256(command)))
                    .staticcall( // target
                        // inputs
                        state.buildInputs(
                            //selector
                            bytes4(command),
                            indices
                        )
                    );
            } else if (flags & FLAG_CT_MASK == FLAG_CT_VALUECALL) {
                uint256 calleth;
                bytes memory v = state[uint8(bytes1(indices))];
                require(v.length == 32, "_execute: value call has no value indicated.");
                assembly {
                    calleth := mload(add(v, 0x20))
                }
                bytes memory callData;
                if (flags & FLAG_DATA != 0) {
                    // Raw calldata taken verbatim from state slot. Selector in `command`
                    // is ignored. Empty bytes -> zero-byte call (invokes receive()).
                    callData = state[uint8(bytes1(indices << 8)) & CommandBuilder.IDX_VALUE_MASK];
                } else {
                    callData = state.buildInputs(
                        //selector
                        bytes4(command),
                        bytes32(uint256(indices << 8) | CommandBuilder.IDX_END_OF_ARGS)
                    );
                }
                (success, outdata) = address(uint160(uint256(command))).call{ value: calleth }(callData);
            } else {
                revert("Invalid calltype");
            }

            if (!success) {
                _revertFailedCommand(commandIndex, address(uint160(uint256(command))), outdata);
            }

            if (flags & FLAG_TUPLE_RETURN != 0) {
                state.writeTuple(bytes1(command << 88), outdata);
            } else {
                state = state.writeOutputs(bytes1(command << 88), outdata);
            }
            unchecked {
                ++i;
            }
        }
        return state;
    }

    /// @dev Surfaces a failed sub-call. Only a payload that is provably a well-formed
    ///      `Error(string)` (selector, 68-byte header, in-place offset, length within bounds)
    ///      is unwrapped into `ExecutionFailed`; empty revert data maps to "Unknown". Anything
    ///      else is re-raised byte-for-byte: reinterpreting it as a string would read the
    ///      second word of a two-argument custom error as a length and either corrupt the
    ///      message or expand memory until the transaction runs out of gas.
    function _revertFailedCommand(uint256 commandIndex, address target, bytes memory outdata) private pure {
        uint256 len = outdata.length;
        if (len == 0) {
            revert ExecutionFailed({ command_index: commandIndex, target: target, message: "Unknown" });
        }
        if (len >= 68 && bytes4(outdata) == ERROR_STRING_SELECTOR) {
            uint256 offset;
            uint256 strLen;
            assembly {
                offset := mload(add(outdata, 36))
                strLen := mload(add(outdata, 68))
            }
            if (offset == 0x20 && strLen <= len - 68) {
                // Point at the string's own length word; the bytes that follow are the string.
                assembly {
                    outdata := add(outdata, 68)
                }
                revert ExecutionFailed({ command_index: commandIndex, target: target, message: string(outdata) });
            }
        }
        assembly {
            revert(add(outdata, 32), len)
        }
    }
}
