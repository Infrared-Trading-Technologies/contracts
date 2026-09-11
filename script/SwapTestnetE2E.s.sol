// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Router } from "../src/Router.sol";
import { WeirollTestHelper } from "../test/helpers/WeirollTestHelper.sol";
import { RouterAuth } from "../test/helpers/RouterAuth.sol";
import { UniV3SwapHelper } from "./lib/UniV3SwapHelper.sol";
import { SwapE2EAssert } from "./lib/SwapE2EAssert.sol";

/// @title SwapTestnetE2E
/// @notice End-to-end testnet swap broadcaster (Sepolia + Base Sepolia). Exercises the
///         deployed Router bytecode against real Uniswap V3 liquidity for four legs:
///         (1) ERC20→ERC20 via approval (also the positive-slippage capture leg),
///         (2) native→ERC20 via msg.value, (3) Permit2 signature, (4) `nonReentrant` via a
///         callback-style token (skipped on testnet — no reachable callback ERC20 with
///         active liquidity). Each leg decodes the `Swap` event from the receipt and asserts
///         `amountToUser >= outputMin` plus exact `protocolFee`/`partnerFee` match; failures
///         revert so the broadcast errors out.
contract SwapTestnetE2E is Script {
    address internal constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address internal constant PERMIT2_ADDR = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @dev Uniswap V3 SwapRouter02. Operator must verify each address has code via
    ///      `cast code <addr> --rpc-url $RPC` immediately before broadcast, since testnet
    ///      addresses are subject to redeployment by Uniswap Labs.
    address internal constant UNI_V3_ROUTER_SEPOLIA = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;
    address internal constant UNI_V3_ROUTER_BASE_SEPOLIA = 0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4;

    /// @dev Canonical WETH on each testnet (Uniswap docs).
    address internal constant WETH_SEPOLIA = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant WETH_BASE_SEPOLIA = 0x4200000000000000000000000000000000000006;

    /// @dev Circle test USDC on each testnet. Verify pool liquidity before broadcast via
    ///      `cast call <pool> "slot0()" --rpc-url $RPC` — see the Verification block in
    ///      `.workflow/tasks/backlog/INF-T5B-testnet-e2e-swap.md`.
    address internal constant USDC_SEPOLIA = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address internal constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    /// @dev Selector for `UniV3SwapHelper.swap(address,address,address,uint256,uint256)`.
    bytes4 internal constant HELPER_SWAP_SELECTOR = bytes4(keccak256("swap(address,address,address,uint256,uint256)"));

    uint16 internal constant PROTOCOL_FEE_BPS = 30; // 0.30%
    uint16 internal constant PARTNER_FEE_BPS = 25; // 0.25%
    uint256 internal constant LEG_INPUT_AMOUNT = 0.0001 ether;

    struct Ctx {
        uint256 chainId;
        address router;
        address weth;
        address usdc;
        address uniRouter;
        address helper;
        address deployer;
        uint256 signerPk;
    }

    /// @dev Every leg carries the backend authorization the Router now requires (NM-1048).
    ///      Signed with `TESTNET_SIGNER_PRIVATE_KEY`, the testnet-only signer the Router was
    ///      deployed with (`ROUTER_SIGNER_<CHAINID>`); the production signer key never leaves
    ///      Secret Manager and is never used by this script.
    uint256 internal constant AUTH_TTL = 30 minutes;

    /// @notice Sole entry point. Mainnet ids are rejected before any state read.
    /// @dev    Both the broadcast and the Permit2 EIP-712 signature are sourced from the
    ///         `--account` keystore the script is launched with. `vm.broadcast()` (no
    ///         arg) uses that keystore for tx signing; `vm.sign(deployer, digest)`
    ///         uses the same keystore for the EIP-712 digest (`Vm.sol:455`). The only raw
    ///         key read from env is the testnet backend signer (`TESTNET_SIGNER_PRIVATE_KEY`).
    function run(uint256 chainId) external {
        if (chainId == 1 || chainId == 8453) revert("script reverts: mainnet ids rejected; testnet only");
        if (chainId != 11155111 && chainId != 84532) revert("script reverts: chainid unsupported");

        Ctx memory c = _loadCtx(chainId);

        // Deploy the Weiroll-target helper once per chain. Same broadcast wallet covers
        // the deploy and all four legs, so legs run sequentially under the same nonce series.
        vm.startBroadcast();
        c.helper = address(new UniV3SwapHelper());
        // One-time approvals: Router pulls WETH for leg 1; Permit2 pulls WETH for leg 3.
        IERC20(c.weth).approve(c.router, type(uint256).max);
        IERC20(c.weth).approve(PERMIT2_ADDR, type(uint256).max);
        vm.stopBroadcast();
        console2.log("Helper deployed:", c.helper);

        _legErc20Approval(c);
        _legNativeInput(c);
        _legPermit2(c);
        _legCallbackSkip();
    }

    function _loadCtx(uint256 chainId) internal view returns (Ctx memory c) {
        c.chainId = chainId;
        string memory json = vm.readFile(string.concat("deployments/", vm.toString(chainId), ".json"));
        c.router = vm.parseJsonAddress(json, ".contracts.Router.address");

        if (chainId == 11155111) {
            c.weth = WETH_SEPOLIA;
            c.usdc = USDC_SEPOLIA;
            c.uniRouter = UNI_V3_ROUTER_SEPOLIA;
        } else {
            c.weth = WETH_BASE_SEPOLIA;
            c.usdc = USDC_BASE_SEPOLIA;
            c.uniRouter = UNI_V3_ROUTER_BASE_SEPOLIA;
        }

        // Deployer = the `--sender` the script was launched with. Used both as the user
        // address for `vm.sign(deployer, digest)` (Permit2 leg) and as the swap recipient
        // / partner recipient. Sourced from the `DEPLOYER_ADDRESS` env var that the
        // existing deploy harness already exports (see `.env.example` and `deploy.sh`).
        c.deployer = vm.envAddress("DEPLOYER_ADDRESS");
        if (c.deployer == address(0)) revert("script reverts: DEPLOYER_ADDRESS env required");

        c.signerPk = vm.envUint("TESTNET_SIGNER_PRIVATE_KEY");
        if (c.signerPk == 0) revert("script reverts: TESTNET_SIGNER_PRIVATE_KEY env required");
        address signer = vm.addr(c.signerPk);
        if (Router(payable(c.router)).signer() != signer) {
            revert("script reverts: TESTNET_SIGNER_PRIVATE_KEY does not match Router.signer()");
        }
    }

    /// @dev Backend-style authorization for one leg: fresh nonce per leg, `AUTH_TTL` expiry,
    ///      taker = the broadcasting deployer (the Router binds `msg.sender`).
    function _authorize(Ctx memory c, Router.SwapParams memory params, string memory leg)
        internal
        view
        returns (Router.Authorization memory)
    {
        bytes32 nonce = keccak256(abi.encode(leg, block.timestamp, c.deployer));
        return RouterAuth.authorizeSwap(c.router, c.signerPk, params, c.deployer, nonce, block.timestamp + AUTH_TTL);
    }

    // -------------------------------------------------------------------------
    // Leg 1: ERC20 input via approval (also the positive-slippage capture leg)
    // -------------------------------------------------------------------------

    function _legErc20Approval(Ctx memory c) internal {
        // Operator queries Uniswap V3 Quoter off-chain for an expected USDC output and sets
        // LEG1_QUOTE deliberately below it (e.g., 90% of expected) so positive slippage is
        // captured by the Router. outputMin = quote * 95 / 100 keeps the slippage floor
        // under outputQuote per Router validation.
        uint256 outputQuote = vm.envOr("LEG1_QUOTE", uint256(0));
        if (outputQuote == 0) revert("LEG1_QUOTE env required (target USDC output, slippage-leg quote)");
        Router.SwapParams memory params = _buildErc20Params(c, outputQuote, (outputQuote * 95) / 100);

        vm.recordLogs();
        vm.broadcast();
        Router(payable(c.router)).swap(params, _authorize(c, params, "leg1"));

        SwapE2EAssert.SwapEvent memory ev = SwapE2EAssert.findSwap(vm.getRecordedLogs(), c.router);
        SwapE2EAssert.baseAssert(ev, params);
        require(ev.positiveSlippageCaptured > 0, "leg1: expected positive slippage capture");
        SwapE2EAssert.logEvent("LEG1_ERC20_APPROVAL", ev);
    }

    // -------------------------------------------------------------------------
    // Leg 2: Native ETH input via msg.value
    // -------------------------------------------------------------------------

    function _legNativeInput(Ctx memory c) internal {
        uint256 outputQuote = vm.envOr("LEG2_QUOTE", uint256(0));
        if (outputQuote == 0) revert("LEG2_QUOTE env required (target USDC output for native leg)");

        // Router forwards `LEG_INPUT_AMOUNT - protocolFee - inputPartnerFee` to executor;
        // the Weiroll path wraps that exact amount to WETH, then swaps via the helper.
        uint256 forwardAmount = (LEG_INPUT_AMOUNT * (10_000 - PROTOCOL_FEE_BPS - PARTNER_FEE_BPS)) / 10_000;

        bytes[] memory state = new bytes[](6);
        state[0] = abi.encode(forwardAmount); // value for weth.deposit()
        state[1] = abi.encode(c.uniRouter);
        state[2] = abi.encode(c.weth);
        state[3] = abi.encode(c.usdc);
        state[4] = abi.encode(forwardAmount); // amountIn for helper.swap
        state[5] = abi.encode(uint256(1)); // Uniswap-level amountOutMin

        bytes32[] memory commands = new bytes32[](2);
        commands[0] = WeirollTestHelper.buildWethDepositCommand(c.weth, 0);
        commands[1] = WeirollTestHelper.encodeCommand(
            HELPER_SWAP_SELECTOR,
            WeirollTestHelper.FLAG_CT_DELEGATECALL,
            WeirollTestHelper.indices5(1, 2, 3, 4, 5),
            WeirollTestHelper.IDX_END_OF_ARGS,
            c.helper
        );

        Router.SwapParams memory params = Router.SwapParams({
            inputToken: NATIVE_ETH,
            inputAmount: LEG_INPUT_AMOUNT,
            outputToken: c.usdc,
            outputQuote: outputQuote,
            outputMin: (outputQuote * 95) / 100,
            recipient: c.deployer,
            protocolFeeBps: PROTOCOL_FEE_BPS,
            partnerFeeBps: PARTNER_FEE_BPS,
            partnerRecipient: c.deployer,
            partnerFeeOnOutput: false,
            passPositiveSlippageToUser: false,
            weirollCommands: commands,
            weirollState: state
        });

        vm.recordLogs();
        vm.broadcast();
        Router(payable(c.router)).swap{ value: LEG_INPUT_AMOUNT }(params, _authorize(c, params, "leg2"));

        SwapE2EAssert.SwapEvent memory ev = SwapE2EAssert.findSwap(vm.getRecordedLogs(), c.router);
        SwapE2EAssert.baseAssert(ev, params);
        SwapE2EAssert.logEvent("LEG2_NATIVE_INPUT", ev);
    }

    // -------------------------------------------------------------------------
    // Leg 3: Permit2 signature path
    // -------------------------------------------------------------------------

    function _legPermit2(Ctx memory c) internal {
        uint256 outputQuote = vm.envOr("LEG3_QUOTE", uint256(0));
        if (outputQuote == 0) revert("LEG3_QUOTE env required (target USDC output for Permit2 leg)");

        // Use timestamp as nonce — guaranteed unused for any prior tx in the deployer's
        // Permit2 history at this clock value. Deadline ~10 min ahead.
        uint256 nonce = block.timestamp;
        uint256 deadline = block.timestamp + 600;

        Router.SwapParams memory params = _buildErc20Params(c, outputQuote, (outputQuote * 95) / 100);

        bytes32 digest = SwapE2EAssert.permit2SingleDigest(c.weth, LEG_INPUT_AMOUNT, nonce, deadline, c.router);
        // Keystore-backed sign: `vm.sign(signer, digest)` uses the unlocked `--account`
        // keystore matching `signer` (Vm.sol:455). No raw key in env.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(c.deployer, digest);
        Router.Permit2Data memory permit =
            Router.Permit2Data({ nonce: nonce, deadline: deadline, signature: abi.encodePacked(r, s, v) });

        vm.recordLogs();
        vm.broadcast();
        Router(payable(c.router)).swapPermit2(params, permit, _authorize(c, params, "leg3"));

        SwapE2EAssert.SwapEvent memory ev = SwapE2EAssert.findSwap(vm.getRecordedLogs(), c.router);
        SwapE2EAssert.baseAssert(ev, params);
        SwapE2EAssert.logEvent("LEG3_PERMIT2", ev);
        console2.log("LEG3_PERMIT2_NONCE", nonce);
        console2.log("LEG3_PERMIT2_DEADLINE", deadline);
    }

    // -------------------------------------------------------------------------
    // Leg 4: nonReentrant callback-token leg — skipped on testnet
    // -------------------------------------------------------------------------

    function _legCallbackSkip() internal pure {
        // No callback-style ERC20 with V3 liquidity is reachable on either testnet.
        // Inventing a deploy-and-trigger fixture is explicitly out of scope per the task's
        // Non-Goals section. The evidence file records this leg as SKIP.
    }

    // -------------------------------------------------------------------------
    // Param + Weiroll-path builder for ERC20-input legs (1 and 3)
    // -------------------------------------------------------------------------

    function _buildErc20Params(Ctx memory c, uint256 outputQuote, uint256 outputMin)
        internal
        pure
        returns (Router.SwapParams memory)
    {
        uint256 forwardAmount = (LEG_INPUT_AMOUNT * (10_000 - PROTOCOL_FEE_BPS - PARTNER_FEE_BPS)) / 10_000;

        bytes[] memory state = new bytes[](5);
        state[0] = abi.encode(c.uniRouter);
        state[1] = abi.encode(c.weth);
        state[2] = abi.encode(c.usdc);
        state[3] = abi.encode(forwardAmount);
        state[4] = abi.encode(uint256(1));

        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.encodeCommand(
            HELPER_SWAP_SELECTOR,
            WeirollTestHelper.FLAG_CT_DELEGATECALL,
            WeirollTestHelper.indices5(0, 1, 2, 3, 4),
            WeirollTestHelper.IDX_END_OF_ARGS,
            c.helper
        );

        return Router.SwapParams({
            inputToken: c.weth,
            inputAmount: LEG_INPUT_AMOUNT,
            outputToken: c.usdc,
            outputQuote: outputQuote,
            outputMin: outputMin,
            recipient: c.deployer,
            protocolFeeBps: PROTOCOL_FEE_BPS,
            partnerFeeBps: PARTNER_FEE_BPS,
            partnerRecipient: c.deployer,
            partnerFeeOnOutput: false,
            passPositiveSlippageToUser: false,
            weirollCommands: commands,
            weirollState: state
        });
    }
}
