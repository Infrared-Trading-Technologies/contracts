// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ISignatureTransfer } from "permit2/interfaces/ISignatureTransfer.sol";

import { ExecutionProxy } from "../src/ExecutionProxy.sol";
import { Router, RouterErrors } from "../src/Router.sol";
import { WeirollTestHelper } from "./helpers/WeirollTestHelper.sol";
import { RouterAuth } from "./helpers/RouterAuth.sol";
import { MockDEX } from "./mocks/MockDEX.sol";

/// @title MockPermit2ERC20
/// @notice Minimal ERC20 sufficient to satisfy Permit2's `safeTransferFrom` (Permit2 calls
///         solmate's `SafeTransferLib`, which checks for a nonzero return value or
///         zero-length returndata). Mints freely for tests.
contract MockPermit2ERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _n, string memory _s) {
        name = _n;
        symbol = _s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) public virtual returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @title FeeOnTransferERC20
/// @notice Tiny fee-on-transfer mock: every `transferFrom` burns `feeBps` of the moved amount
///         on receipt. Used to verify Permit2 path balance-diff accounting (FR-15).
contract FeeOnTransferERC20 is MockPermit2ERC20 {
    uint256 public feeBps;

    constructor(string memory n, string memory s, uint256 _feeBps) MockPermit2ERC20(n, s) {
        feeBps = _feeBps;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        uint256 fee = (amount * feeBps) / 10_000;
        uint256 received = amount - fee;
        balanceOf[to] += received;
        balanceOf[address(this)] += fee;
        emit Transfer(from, to, received);
        emit Transfer(from, address(this), fee);
        return true;
    }
}

/// @title RouterPermit2Test
/// @notice Exercises `swapPermit2` and `swapMultiPermit2` end-to-end against the canonical
///         Permit2 contract etched at its mainnet address. Signatures are produced with
///         `vm.sign` against the same EIP-712 domain Permit2 uses on mainnet, so the path
///         verified here is the real signature-verification path.
contract RouterPermit2Test is Test {
    address constant PERMIT2_ADDR = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    bytes32 constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 constant PERMIT_TRANSFER_FROM_TYPEHASH = keccak256(
        "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );
    bytes32 constant PERMIT_BATCH_TRANSFER_FROM_TYPEHASH = keccak256(
        "PermitBatchTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );

    ExecutionProxy public executor;
    Router public router;
    MockPermit2ERC20 public tokenA;
    MockPermit2ERC20 public tokenB;
    MockPermit2ERC20 public tokenC;
    MockPermit2ERC20 public tokenD;
    MockDEX public dex;

    uint256 public userPk;
    address public user;
    address public receiver = makeAddr("receiver");
    address public liquidator = makeAddr("liquidator");

    // ------------------------------------------------------------------
    // Backend authorization (NM-1048): every user-facing swap carries a signature by
    // `authSigner` over the exact params, the taker, a fresh nonce and a 3-minute expiry.
    // ------------------------------------------------------------------

    uint256 internal authSignerPk;
    address internal authSigner;
    uint256 internal authNonce;

    function _auth(Router.SwapParams memory p, address taker) internal returns (Router.Authorization memory) {
        return RouterAuth.authorizeSwap(
            address(router), authSignerPk, p, taker, bytes32(++authNonce), block.timestamp + 180
        );
    }

    function _authMulti(Router.MultiSwapParams memory p, address taker) internal returns (Router.Authorization memory) {
        return RouterAuth.authorizeMultiSwap(
            address(router), authSignerPk, p, taker, bytes32(++authNonce), block.timestamp + 180
        );
    }

    function setUp() public {
        // `vm.getCode` / `deployCodeTo` can't resolve artifacts from a different solc
        // version than the project's main one (Permit2 pins 0.8.17, ours is 0.8.24).
        // Read the deployed bytecode straight from the artifact JSON and etch it at the
        // canonical Permit2 address. Permit2's `_CACHED_CHAIN_ID` ends up zero in this
        // bytecode (immutables aren't substituted without constructor execution), but
        // its `DOMAIN_SEPARATOR()` falls back to recomputing from `block.chainid` and
        // `address(this)` whenever the cached chainid doesn't match — so signature
        // verification uses the canonical domain (chainid + Permit2 address) correctly.
        bytes memory deployed =
            vm.parseJsonBytes(vm.readFile("out/Permit2.sol/Permit2.json"), ".deployedBytecode.object");
        vm.etch(PERMIT2_ADDR, deployed);

        (authSigner, authSignerPk) = makeAddrAndKey("backend-signer");

        router = new Router(address(this), liquidator, authSigner);
        executor = new ExecutionProxy(address(router));
        router.setPendingExecutor(address(executor));
        router.acceptExecutor();

        tokenA = new MockPermit2ERC20("Token A", "TKNA");
        tokenB = new MockPermit2ERC20("Token B", "TKNB");
        tokenC = new MockPermit2ERC20("Token C", "TKNC");
        tokenD = new MockPermit2ERC20("Token D", "TKND");
        dex = new MockDEX();

        (user, userPk) = makeAddrAndKey("permit2-user");
    }

    // ---------------------------------------------------------------
    // Signature helpers
    // ---------------------------------------------------------------

    function _domainSeparator() internal view returns (bytes32) {
        return ISignatureTransfer(PERMIT2_ADDR).DOMAIN_SEPARATOR();
    }

    function _hashTokenPermissions(address token, uint256 amount) internal pure returns (bytes32) {
        return keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, token, amount));
    }

    /// @dev Build the EIP-712 digest for a single-token Permit2 transfer signed by `user`.
    ///      `spender` must equal the caller of `permitTransferFrom` — for our tests that is
    ///      the Router. Returns a 65-byte (r,s,v) signature compatible with
    ///      `SignatureVerification.verify`.
    function _signSinglePermit(address token, uint256 amount, uint256 nonce, uint256 deadline, address spender)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TRANSFER_FROM_TYPEHASH, _hashTokenPermissions(token, amount), spender, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Build the EIP-712 digest for a batched Permit2 transfer signed by `user`.
    function _signBatchPermit(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256 nonce,
        uint256 deadline,
        address spender
    ) internal view returns (bytes memory) {
        require(tokens.length == amounts.length, "len");
        bytes32[] memory hashes = new bytes32[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            hashes[i] = _hashTokenPermissions(tokens[i], amounts[i]);
        }
        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_BATCH_TRANSFER_FROM_TYPEHASH, keccak256(abi.encodePacked(hashes)), spender, nonce, deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ---------------------------------------------------------------
    // Weiroll program builders (mirror those in Router.t.sol)
    // ---------------------------------------------------------------

    /// @dev A weiroll program that swaps `amountIn` of `tokenIn` for `amountOut` of `tokenOut`
    ///      via MockDEX, with the executor pulling the input from itself and pushing output
    ///      to the Router (so balance-diff accounting fires).
    function _buildA2BProgram(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (bytes32[] memory commands, bytes[] memory state)
    {
        state = new bytes[](6);
        state[0] = WeirollTestHelper.encodeAddress(address(router));
        state[1] = WeirollTestHelper.encodeUint256(amountOut);
        state[2] = WeirollTestHelper.encodeAddress(address(dex));
        state[3] = WeirollTestHelper.encodeAddress(tokenIn);
        state[4] = WeirollTestHelper.encodeAddress(tokenOut);
        state[5] = WeirollTestHelper.encodeUint256(amountIn);

        commands = new bytes32[](3);
        commands[0] = WeirollTestHelper.buildApproveCommand(tokenIn, 2, 5);
        commands[1] = WeirollTestHelper.buildCallFourArgs(
            address(dex), bytes4(keccak256("swap(address,address,uint256,uint256)")), 3, 4, 5, 1
        );
        commands[2] = WeirollTestHelper.buildTransferCommand(tokenOut, 0, 1);
    }

    function _buildParams(
        address inputToken,
        uint256 inputAmount,
        address outputToken,
        uint256 outputQuote,
        uint256 outputMin,
        bytes32[] memory commands,
        bytes[] memory state
    ) internal view returns (Router.SwapParams memory p) {
        p = Router.SwapParams({
            inputToken: inputToken,
            inputAmount: inputAmount,
            outputToken: outputToken,
            outputQuote: outputQuote,
            outputMin: outputMin,
            recipient: receiver,
            protocolFeeBps: 0,
            partnerFeeBps: 0,
            partnerRecipient: address(0),
            partnerFeeOnOutput: false,
            passPositiveSlippageToUser: false,
            weirollCommands: commands,
            weirollState: state
        });
    }

    // ---------------------------------------------------------------
    // 1. Single-token happy path
    // ---------------------------------------------------------------

    function test_SwapPermit2_HappyPath_ERC20toERC20() public {
        uint256 amountIn = 1000e18;
        uint256 amountOut = 900e18;
        uint256 deadline = block.timestamp + 1 hours;

        tokenA.mint(user, amountIn);
        vm.prank(user);
        tokenA.approve(PERMIT2_ADDR, type(uint256).max);

        (bytes32[] memory cmds, bytes[] memory state) =
            _buildA2BProgram(address(tokenA), address(tokenB), amountIn, amountOut);
        Router.SwapParams memory params =
            _buildParams(address(tokenA), amountIn, address(tokenB), amountOut, amountOut * 9 / 10, cmds, state);

        bytes memory sig = _signSinglePermit(address(tokenA), amountIn, 0, deadline, address(router));
        Router.Permit2Data memory permit = Router.Permit2Data({ nonce: 0, deadline: deadline, signature: sig });

        vm.prank(user);
        uint256 returned = router.swapPermit2(params, permit, _auth(params, user));

        assertEq(returned, amountOut, "amountOut");
        assertEq(tokenB.balanceOf(receiver), amountOut, "receiver gets B");
        assertEq(tokenA.balanceOf(user), 0, "user input fully pulled");
    }

    // ---------------------------------------------------------------
    // 2. Multi-token happy path
    // ---------------------------------------------------------------

    function test_SwapMultiPermit2_HappyPath_TwoInTwoOut() public {
        uint256 inA = 600e18;
        uint256 inC = 400e18;
        uint256 outB = 500e18;
        uint256 outD = 350e18;
        uint256 deadline = block.timestamp + 1 hours;

        tokenA.mint(user, inA);
        tokenC.mint(user, inC);
        vm.startPrank(user);
        tokenA.approve(PERMIT2_ADDR, type(uint256).max);
        tokenC.approve(PERMIT2_ADDR, type(uint256).max);
        vm.stopPrank();

        // Build a weiroll program that runs A->B and C->D in sequence (executor holds both
        // inputs after Router forwards them, then pushes both outputs back to the Router).
        bytes32[] memory cmds = new bytes32[](6);
        bytes[] memory state = new bytes[](10);
        state[0] = WeirollTestHelper.encodeAddress(address(router));
        state[1] = WeirollTestHelper.encodeUint256(outB);
        state[2] = WeirollTestHelper.encodeAddress(address(dex));
        state[3] = WeirollTestHelper.encodeAddress(address(tokenA));
        state[4] = WeirollTestHelper.encodeAddress(address(tokenB));
        state[5] = WeirollTestHelper.encodeUint256(inA);
        state[6] = WeirollTestHelper.encodeAddress(address(tokenC));
        state[7] = WeirollTestHelper.encodeAddress(address(tokenD));
        state[8] = WeirollTestHelper.encodeUint256(inC);
        state[9] = WeirollTestHelper.encodeUint256(outD);
        cmds[0] = WeirollTestHelper.buildApproveCommand(address(tokenA), 2, 5);
        cmds[1] = WeirollTestHelper.buildCallFourArgs(
            address(dex), bytes4(keccak256("swap(address,address,uint256,uint256)")), 3, 4, 5, 1
        );
        cmds[2] = WeirollTestHelper.buildTransferCommand(address(tokenB), 0, 1);
        cmds[3] = WeirollTestHelper.buildApproveCommand(address(tokenC), 2, 8);
        cmds[4] = WeirollTestHelper.buildCallFourArgs(
            address(dex), bytes4(keccak256("swap(address,address,uint256,uint256)")), 6, 7, 8, 9
        );
        cmds[5] = WeirollTestHelper.buildTransferCommand(address(tokenD), 0, 9);

        Router.MultiSwapParams memory mp;
        mp.inputTokens = new address[](2);
        mp.inputTokens[0] = address(tokenA);
        mp.inputTokens[1] = address(tokenC);
        mp.inputAmounts = new uint256[](2);
        mp.inputAmounts[0] = inA;
        mp.inputAmounts[1] = inC;
        mp.outputTokens = new address[](2);
        mp.outputTokens[0] = address(tokenB);
        mp.outputTokens[1] = address(tokenD);
        mp.outputQuotes = new uint256[](2);
        mp.outputQuotes[0] = outB;
        mp.outputQuotes[1] = outD;
        mp.outputMins = new uint256[](2);
        mp.outputMins[0] = outB * 9 / 10;
        mp.outputMins[1] = outD * 9 / 10;
        mp.recipient = receiver;
        mp.weirollCommands = cmds;
        mp.weirollState = state;

        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenC);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = inA;
        amounts[1] = inC;
        bytes memory sig = _signBatchPermit(tokens, amounts, 0, deadline, address(router));
        Router.Permit2Data memory permit = Router.Permit2Data({ nonce: 0, deadline: deadline, signature: sig });

        vm.prank(user);
        uint256[] memory amountsOut = router.swapMultiPermit2(mp, permit, _authMulti(mp, user));

        assertEq(amountsOut.length, 2, "len");
        assertEq(amountsOut[0], outB, "B out");
        assertEq(amountsOut[1], outD, "D out");
        assertEq(tokenB.balanceOf(receiver), outB, "receiver B");
        assertEq(tokenD.balanceOf(receiver), outD, "receiver D");
    }

    // ---------------------------------------------------------------
    // 3-4. Native ETH inputs are rejected
    // ---------------------------------------------------------------

    function test_SwapPermit2_RevertsOnNativeInput() public {
        Router.SwapParams memory params;
        params.inputToken = NATIVE_ETH;
        params.inputAmount = 1 ether;
        params.outputToken = address(tokenB);
        params.outputQuote = 1;
        params.outputMin = 1;
        params.recipient = receiver;

        Router.Permit2Data memory permit;

        vm.expectRevert(Router.NativeInputNotPermit2Compatible.selector);
        vm.prank(user);
        router.swapPermit2(params, permit, _auth(params, user));
    }

    function test_SwapMultiPermit2_RevertsOnNativeInputSlot() public {
        Router.MultiSwapParams memory mp;
        mp.inputTokens = new address[](2);
        mp.inputTokens[0] = address(tokenA);
        mp.inputTokens[1] = NATIVE_ETH;
        mp.inputAmounts = new uint256[](2);
        mp.inputAmounts[0] = 1e18;
        mp.inputAmounts[1] = 1 ether;
        mp.outputTokens = new address[](1);
        mp.outputTokens[0] = address(tokenB);
        mp.outputQuotes = new uint256[](1);
        mp.outputQuotes[0] = 1;
        mp.outputMins = new uint256[](1);
        mp.outputMins[0] = 1;
        mp.recipient = receiver;

        Router.Permit2Data memory permit;

        vm.expectRevert(Router.NativeInputNotPermit2Compatible.selector);
        vm.prank(user);
        router.swapMultiPermit2(mp, permit, _authMulti(mp, user));
    }

    // ---------------------------------------------------------------
    // 5. Expired deadline bubbles up
    // ---------------------------------------------------------------

    function test_SwapPermit2_RevertsOnExpiredDeadline() public {
        uint256 amountIn = 100e18;
        uint256 deadline = block.timestamp - 1; // expired

        tokenA.mint(user, amountIn);
        vm.prank(user);
        tokenA.approve(PERMIT2_ADDR, type(uint256).max);

        (bytes32[] memory cmds, bytes[] memory state) =
            _buildA2BProgram(address(tokenA), address(tokenB), amountIn, amountIn);
        Router.SwapParams memory params =
            _buildParams(address(tokenA), amountIn, address(tokenB), amountIn, amountIn / 2, cmds, state);

        bytes memory sig = _signSinglePermit(address(tokenA), amountIn, 1, deadline, address(router));
        Router.Permit2Data memory permit = Router.Permit2Data({ nonce: 1, deadline: deadline, signature: sig });

        vm.expectRevert(abi.encodeWithSignature("SignatureExpired(uint256)", deadline));
        vm.prank(user);
        router.swapPermit2(params, permit, _auth(params, user));
    }

    // ---------------------------------------------------------------
    // 6. Reused nonce reverts
    // ---------------------------------------------------------------

    function test_SwapPermit2_RevertsOnReusedNonce() public {
        uint256 amountIn = 100e18;
        uint256 amountOut = 90e18;
        uint256 deadline = block.timestamp + 1 hours;

        tokenA.mint(user, amountIn * 2);
        vm.prank(user);
        tokenA.approve(PERMIT2_ADDR, type(uint256).max);

        (bytes32[] memory cmds, bytes[] memory state) =
            _buildA2BProgram(address(tokenA), address(tokenB), amountIn, amountOut);
        Router.SwapParams memory params =
            _buildParams(address(tokenA), amountIn, address(tokenB), amountOut, amountOut / 2, cmds, state);

        // First swap consumes nonce 7.
        bytes memory sig = _signSinglePermit(address(tokenA), amountIn, 7, deadline, address(router));
        Router.Permit2Data memory permit = Router.Permit2Data({ nonce: 7, deadline: deadline, signature: sig });
        vm.prank(user);
        router.swapPermit2(params, permit, _auth(params, user));

        // Second swap with the same signature/nonce must revert.
        vm.expectRevert(abi.encodeWithSignature("InvalidNonce()"));
        vm.prank(user);
        router.swapPermit2(params, permit, _auth(params, user));
    }

    // ---------------------------------------------------------------
    // 7. Tampered amount: signature signed for X, calldata says Y -> Permit2 rejects
    // ---------------------------------------------------------------

    function test_SwapPermit2_RevertsOnTamperedAmount() public {
        uint256 signedAmount = 100e18;
        uint256 callAmount = 200e18; // user signed only 100, but calldata claims 200
        uint256 deadline = block.timestamp + 1 hours;

        tokenA.mint(user, callAmount);
        vm.prank(user);
        tokenA.approve(PERMIT2_ADDR, type(uint256).max);

        (bytes32[] memory cmds, bytes[] memory state) =
            _buildA2BProgram(address(tokenA), address(tokenB), callAmount, callAmount);
        Router.SwapParams memory params =
            _buildParams(address(tokenA), callAmount, address(tokenB), callAmount, callAmount / 2, cmds, state);

        bytes memory sig = _signSinglePermit(address(tokenA), signedAmount, 0, deadline, address(router));
        Router.Permit2Data memory permit = Router.Permit2Data({ nonce: 0, deadline: deadline, signature: sig });

        // Permit2's signature verification reverts on the bad recovered signer; the helper
        // selector is `InvalidSigner()` from Permit2's `SignatureVerification` library.
        vm.expectRevert(abi.encodeWithSignature("InvalidSigner()"));
        vm.prank(user);
        router.swapPermit2(params, permit, _auth(params, user));
    }

    // ---------------------------------------------------------------
    // 8. Fee-on-transfer token: pulled < signed; fee math uses pulled.
    //    FoT tokens are unsupported; this documents accounting behavior only.
    // ---------------------------------------------------------------

    function test_SwapPermit2_FeeOnTransferToken() public {
        FeeOnTransferERC20 fotIn = new FeeOnTransferERC20("FOT", "FOT", 100); // 1% fee
        uint256 amountIn = 1000e18;
        uint256 deadline = block.timestamp + 1 hours;

        // After Permit2 transfer, Router will receive 99% of amountIn. The Weiroll program
        // forwards only that reduced amount to MockDEX, so amountOut is sized accordingly.
        uint256 effectiveIn = amountIn - (amountIn * 100 / 10_000);
        uint256 amountOut = effectiveIn; // 1:1 swap on MockDEX

        fotIn.mint(user, amountIn);
        vm.prank(user);
        fotIn.approve(PERMIT2_ADDR, type(uint256).max);

        (bytes32[] memory cmds, bytes[] memory state) =
            _buildA2BProgram(address(fotIn), address(tokenB), effectiveIn, amountOut);
        Router.SwapParams memory params =
            _buildParams(address(fotIn), amountIn, address(tokenB), amountOut, amountOut / 2, cmds, state);

        bytes memory sig = _signSinglePermit(address(fotIn), amountIn, 42, deadline, address(router));
        Router.Permit2Data memory permit = Router.Permit2Data({ nonce: 42, deadline: deadline, signature: sig });

        vm.prank(user);
        uint256 returned = router.swapPermit2(params, permit, _auth(params, user));

        assertEq(returned, amountOut, "amountOut uses pulled");
        assertEq(tokenB.balanceOf(receiver), amountOut, "receiver gets reduced amount");
    }

    // ---------------------------------------------------------------
    // 9. Fees + slippage capture still work via Permit2 path
    // ---------------------------------------------------------------

    function test_SwapPermit2_RespectsAllSlippageAndFeeRules() public {
        uint256 amountIn = 1000e18;
        // Executor produces 1100 (positive slippage); quote is 1000, min 900.
        uint256 dexOut = 1100e18;
        uint256 quote = 1000e18;
        uint256 min = 900e18;
        uint256 deadline = block.timestamp + 1 hours;

        // 1% protocol fee + 1% input partner fee. Forwarded = pulled * 0.98.
        uint16 protoBps = 100;
        uint16 partnerBps = 100;
        address partner = makeAddr("partner");
        uint256 forwarded = amountIn - (amountIn * protoBps / 10_000) - (amountIn * partnerBps / 10_000);

        tokenA.mint(user, amountIn);
        vm.prank(user);
        tokenA.approve(PERMIT2_ADDR, type(uint256).max);

        (bytes32[] memory cmds, bytes[] memory state) =
            _buildA2BProgram(address(tokenA), address(tokenB), forwarded, dexOut);
        Router.SwapParams memory params = Router.SwapParams({
            inputToken: address(tokenA),
            inputAmount: amountIn,
            outputToken: address(tokenB),
            outputQuote: quote,
            outputMin: min,
            recipient: receiver,
            protocolFeeBps: protoBps,
            partnerFeeBps: partnerBps,
            partnerRecipient: partner,
            partnerFeeOnOutput: false,
            passPositiveSlippageToUser: false,
            weirollCommands: cmds,
            weirollState: state
        });

        bytes memory sig = _signSinglePermit(address(tokenA), amountIn, 99, deadline, address(router));
        Router.Permit2Data memory permit = Router.Permit2Data({ nonce: 99, deadline: deadline, signature: sig });

        vm.prank(user);
        uint256 returned = router.swapPermit2(params, permit, _auth(params, user));

        assertEq(returned, quote, "amountOut capped at quote");
        assertEq(tokenB.balanceOf(receiver), quote, "receiver gets quote");
        assertEq(tokenA.balanceOf(partner), amountIn * partnerBps / 10_000, "partner fee paid in input");
        // Router retains positive slippage = dexOut - quote.
        assertEq(tokenB.balanceOf(address(router)), dexOut - quote, "router retains slippage");
        // Router also retains the protocol fee in inputToken.
        assertEq(tokenA.balanceOf(address(router)), amountIn * protoBps / 10_000, "router retains protocol fee");
    }

    // ---------------------------------------------------------------
    // 10. Pausable still gates Permit2 entry points
    // ---------------------------------------------------------------

    function test_SwapPermit2_PausedReverts() public {
        router.pause();

        uint256 amountIn = 100e18;
        uint256 deadline = block.timestamp + 1 hours;
        tokenA.mint(user, amountIn);
        vm.prank(user);
        tokenA.approve(PERMIT2_ADDR, type(uint256).max);

        (bytes32[] memory cmds, bytes[] memory state) =
            _buildA2BProgram(address(tokenA), address(tokenB), amountIn, amountIn);
        Router.SwapParams memory params =
            _buildParams(address(tokenA), amountIn, address(tokenB), amountIn, amountIn / 2, cmds, state);

        bytes memory sig = _signSinglePermit(address(tokenA), amountIn, 0, deadline, address(router));
        Router.Permit2Data memory permit = Router.Permit2Data({ nonce: 0, deadline: deadline, signature: sig });

        vm.expectRevert(RouterErrors.Paused.selector);
        vm.prank(user);
        router.swapPermit2(params, permit, _auth(params, user));
    }
}
