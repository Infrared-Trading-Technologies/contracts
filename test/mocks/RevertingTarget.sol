// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title RevertingTarget
/// @notice Weiroll command target whose functions revert in every payload shape a sub-call
///         realistically produces. Only `failString` is an `Error(string)`. The custom-error
///         shapes and the configurable words follow the proof-of-concept suite Nethermind
///         supplied for NM-1048: `minOut` lands at returndata offset 36 (the slot the old VM
///         trusted as a string length) and `leakWord` is the word that followed it.
contract RevertingTarget {
    /// @dev Byte-identical shape to `UniswapV4SwapHelpers.InsufficientOutputAmount`.
    error InsufficientOutputAmount(uint256 amountOut, uint256 minAmountOut);

    /// @dev Three-word custom error: the old VM printed `c` verbatim as the "message".
    error ThreeWordError(uint256 a, uint256 b, uint256 c);

    /// @dev Bare 4-byte custom error (OZ v5 / Permit2 / V4 style).
    error Unauthorized();

    uint256 public minOut;
    uint256 public leakWord;
    uint256 public calls;
    uint256 internal zero;

    function setMinOut(uint256 v) external {
        minOut = v;
    }

    function setLeakWord(uint256 v) external {
        leakWord = v;
    }

    function ok() external {
        calls += 1;
    }

    /// @dev The only shape that is legitimately unwrapped into `ExecutionFailed`.
    function failString() external pure {
        revert("Too little received");
    }

    /// @dev `minOut` sits at returndata offset 36.
    function failCustom2Word() external view {
        revert InsufficientOutputAmount(0, minOut);
    }

    /// @dev `b == 32` sat at the length slot; `leakWord` is the word after it.
    function failCustom3Word() external view {
        revert ThreeWordError(0, 32, leakWord);
    }

    /// @dev 4 bytes of returndata, shorter than an `Error(string)` header.
    function failCustom0Word() external pure {
        revert Unauthorized();
    }

    function failEmpty() external pure {
        assembly {
            revert(0, 0)
        }
    }

    function failPanicDivByZero() external view returns (uint256) {
        return 1 / zero;
    }

    /// @dev `Error(string)` selector, then an offset word of 0x40 (should be 0x20) and a length
    ///      word that exceeds the payload. 68 bytes total, so a length-only check would accept it.
    function failMalformedErrorString() external pure {
        bytes memory payload = abi.encodePacked(bytes4(0x08c379a0), uint256(0x40), uint256(type(uint128).max));
        assembly {
            revert(add(payload, 32), mload(payload))
        }
    }
}
