// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { Router } from "src/Router.sol";

/// @title RouterAuth
/// @notice Reference implementation of the Router's EIP-712 swap authorization for tests and
///         scripts. Written from the type strings, independently of `Router`'s own hashing, so a
///         Router hashing bug shows up as a digest mismatch in the golden-vector tests rather than
///         being reproduced here.
/// @dev Hashing rules (EIP-712): `bytes32[]`, `address[]` and `uint256[]` members hash as the
///      keccak of their 32-byte-padded concatenation; `bytes[]` hashes as the keccak of the
///      concatenated per-element keccaks; the struct hash is `keccak256(abi.encode(TYPEHASH,
///      fields...))`; the digest is `keccak256("\x19\x01" || domainSeparator || structHash)`.
library RouterAuth {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string internal constant EIP712_DOMAIN_TYPE =
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)";
    string internal constant SWAP_TYPE =
        "SwapAuthorization(address taker,address inputToken,uint256 inputAmount,address outputToken,uint256 outputQuote,uint256 outputMin,address recipient,uint16 protocolFeeBps,uint16 partnerFeeBps,address partnerRecipient,bool partnerFeeOnOutput,bool passPositiveSlippageToUser,bytes32[] weirollCommands,bytes[] weirollState,bytes32 nonce,uint256 expiry)";
    string internal constant MULTI_SWAP_TYPE =
        "MultiSwapAuthorization(address taker,address[] inputTokens,uint256[] inputAmounts,address[] outputTokens,uint256[] outputQuotes,uint256[] outputMins,address recipient,uint16 protocolFeeBps,uint16 partnerFeeBps,address partnerRecipient,bool partnerFeeOnOutput,bool passPositiveSlippageToUser,bytes32[] weirollCommands,bytes[] weirollState,bytes32 nonce,uint256 expiry)";

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH = keccak256(bytes(EIP712_DOMAIN_TYPE));
    bytes32 internal constant SWAP_TYPEHASH = keccak256(bytes(SWAP_TYPE));
    bytes32 internal constant MULTI_SWAP_TYPEHASH = keccak256(bytes(MULTI_SWAP_TYPE));
    bytes32 internal constant NAME_HASH = keccak256("InfraredRouter");
    bytes32 internal constant VERSION_HASH = keccak256("1");

    /// @dev secp256k1 group order; `s` above `N / 2` is the malleable twin OZ's ECDSA rejects.
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function domainSeparator(address router, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, chainId, router));
    }

    function hashState(bytes[] memory state) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](state.length);
        for (uint256 i = 0; i < state.length; ++i) {
            hashes[i] = keccak256(state[i]);
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function swapStructHash(Router.SwapParams memory p, address taker, bytes32 nonce, uint256 expiry)
        internal
        pure
        returns (bytes32)
    {
        // Two static-only encodes concatenated are byte-identical to one 17-word abi.encode;
        // split to stay under the stack limit.
        bytes memory head = abi.encode(
            SWAP_TYPEHASH, taker, p.inputToken, p.inputAmount, p.outputToken, p.outputQuote, p.outputMin, p.recipient
        );
        bytes memory tail = abi.encode(
            p.protocolFeeBps,
            p.partnerFeeBps,
            p.partnerRecipient,
            p.partnerFeeOnOutput,
            p.passPositiveSlippageToUser,
            keccak256(abi.encodePacked(p.weirollCommands)),
            hashState(p.weirollState),
            nonce,
            expiry
        );
        return keccak256(bytes.concat(head, tail));
    }

    function multiSwapStructHash(Router.MultiSwapParams memory p, address taker, bytes32 nonce, uint256 expiry)
        internal
        pure
        returns (bytes32)
    {
        bytes memory head = abi.encode(
            MULTI_SWAP_TYPEHASH,
            taker,
            keccak256(abi.encodePacked(p.inputTokens)),
            keccak256(abi.encodePacked(p.inputAmounts)),
            keccak256(abi.encodePacked(p.outputTokens)),
            keccak256(abi.encodePacked(p.outputQuotes)),
            keccak256(abi.encodePacked(p.outputMins)),
            p.recipient
        );
        bytes memory tail = abi.encode(
            p.protocolFeeBps,
            p.partnerFeeBps,
            p.partnerRecipient,
            p.partnerFeeOnOutput,
            p.passPositiveSlippageToUser,
            keccak256(abi.encodePacked(p.weirollCommands)),
            hashState(p.weirollState),
            nonce,
            expiry
        );
        return keccak256(bytes.concat(head, tail));
    }

    function digest(address router, uint256 chainId, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(router, chainId), structHash));
    }

    function swapDigest(
        address router,
        uint256 chainId,
        Router.SwapParams memory p,
        address taker,
        bytes32 nonce,
        uint256 expiry
    ) internal pure returns (bytes32) {
        return digest(router, chainId, swapStructHash(p, taker, nonce, expiry));
    }

    function multiSwapDigest(
        address router,
        uint256 chainId,
        Router.MultiSwapParams memory p,
        address taker,
        bytes32 nonce,
        uint256 expiry
    ) internal pure returns (bytes32) {
        return digest(router, chainId, multiSwapStructHash(p, taker, nonce, expiry));
    }

    /// @dev 65-byte `r || s || v` with `v` in {27, 28}, as OZ `ECDSA.tryRecover` expects.
    function sign(uint256 pk, bytes32 d) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return abi.encodePacked(r, s, v);
    }

    function authorizeSwap(
        address router,
        uint256 pk,
        Router.SwapParams memory p,
        address taker,
        bytes32 nonce,
        uint256 expiry
    ) internal view returns (Router.Authorization memory) {
        bytes32 d = swapDigest(router, block.chainid, p, taker, nonce, expiry);
        return Router.Authorization({ nonce: nonce, expiry: expiry, signature: sign(pk, d) });
    }

    function authorizeMultiSwap(
        address router,
        uint256 pk,
        Router.MultiSwapParams memory p,
        address taker,
        bytes32 nonce,
        uint256 expiry
    ) internal view returns (Router.Authorization memory) {
        bytes32 d = multiSwapDigest(router, block.chainid, p, taker, nonce, expiry);
        return Router.Authorization({ nonce: nonce, expiry: expiry, signature: sign(pk, d) });
    }
}
