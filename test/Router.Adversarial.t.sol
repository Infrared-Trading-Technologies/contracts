// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ExecutionProxy } from "../src/ExecutionProxy.sol";
import { Router } from "../src/Router.sol";
import {
    FeeOnTransferToken,
    RebasingToken,
    CallbackToken,
    FalseReturningToken,
    NoReturnToken
} from "./mocks/AdversarialTokens.sol";
import { MockDEX } from "./mocks/MockDEX.sol";
import { RouterReentrantReceiver } from "./mocks/RouterReentrantReceiver.sol";
import { WeirollTestHelper } from "./helpers/WeirollTestHelper.sol";

/// @title MockERC20
/// @notice Minimal mintable ERC20 with boolean returns. Duplicated from the sibling Router
///         test files so this suite stays self-contained.
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
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

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        require(balanceOf[from] >= amount, "Insufficient balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @title MockETHSender
/// @notice Weiroll-callable sink that takes ERC20 input and forwards a fixed ETH output to a
///         named recipient. Used to produce native-ETH output from an ERC20 input swap so the
///         Router can measure its native-balance delta.
contract MockETHSender {
    function swapToETH(address tokenIn, uint256 amountIn, uint256 amountOut, address recipient) external {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        (bool ok,) = recipient.call{ value: amountOut }("");
        require(ok, "MockETHSender: eth send failed");
    }

    receive() external payable { }
}

/// @title RouterAdversarialTest
/// @notice FR-15 (balance-diff accounting vs weird ERC20s) and FR-16 (nonReentrant on swap entry)
///         coverage for Router. Uses the existing adversarial token mocks (fee-on-transfer,
///         rebasing, no-return / USDT-style, false-returning, callback) and a Router-targeted
///         re-entrancy receiver to prove that the Router's balance-diff pipeline and OpenZeppelin's
///         ReentrancyGuard produce the behavior required by the spec's Edge Cases table.
contract RouterAdversarialTest is Test {
    ExecutionProxy public executor;
    Router public router;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockDEX public dex;
    MockETHSender public ethSender;

    address public user = makeAddr("user");
    address public receiver = makeAddr("receiver");
    address public liquidator = makeAddr("liquidator");

    address public constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // ReentrancyGuardReentrantCall() selector from OpenZeppelin's ReentrancyGuard (v5.5.0).
    bytes4 internal constant REENTRANT_GUARD_SELECTOR = bytes4(keccak256("ReentrancyGuardReentrantCall()"));

    function setUp() public {
        executor = new ExecutionProxy();
        router = new Router(address(this), liquidator);
        router.setPendingExecutor(address(executor));
        router.acceptExecutor();

        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);
        dex = new MockDEX();
        ethSender = new MockETHSender();

        vm.deal(user, 100 ether);
        vm.deal(address(ethSender), 100 ether);
    }

    // ------------------------------------------------------------------
    // Weiroll program builders
    // ------------------------------------------------------------------

    /// @dev approve(inputToken,dex,amountIn) + dex.swap(inputToken,outputToken,amountIn,amountOut)
    ///      + outputToken.transfer(router, amountOut). Works for any (input, output) ERC20 pair.
    function _buildSwapProgram(address inputToken, address outputToken, uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (bytes32[] memory commands, bytes[] memory state)
    {
        state = new bytes[](6);
        state[0] = WeirollTestHelper.encodeAddress(address(router));
        state[1] = WeirollTestHelper.encodeUint256(amountOut);
        state[2] = WeirollTestHelper.encodeAddress(address(dex));
        state[3] = WeirollTestHelper.encodeAddress(inputToken);
        state[4] = WeirollTestHelper.encodeAddress(outputToken);
        state[5] = WeirollTestHelper.encodeUint256(amountIn);

        commands = new bytes32[](3);
        commands[0] = WeirollTestHelper.buildApproveCommand(inputToken, 2, 5);
        commands[1] = WeirollTestHelper.buildCallFourArgs(
            address(dex), bytes4(keccak256("swap(address,address,uint256,uint256)")), 3, 4, 5, 1
        );
        commands[2] = WeirollTestHelper.buildTransferCommand(outputToken, 0, 1);
    }

    /// @dev approve + swap + transfer (as above) + rebase.rebaseUp/Down(rebaseAmount). The
    ///      rebase command fires between the transfer-to-Router and the Router's post-snapshot,
    ///      so Router measures the post-rebase balance per FR-15.
    function _buildRebaseSwapProgram(
        address rebase,
        uint256 amountIn,
        uint256 dexMint,
        bytes4 rebaseSelector,
        uint256 rebaseAmount
    ) internal view returns (bytes32[] memory commands, bytes[] memory state) {
        state = new bytes[](7);
        state[0] = WeirollTestHelper.encodeAddress(address(router));
        state[1] = WeirollTestHelper.encodeUint256(dexMint);
        state[2] = WeirollTestHelper.encodeAddress(address(dex));
        state[3] = WeirollTestHelper.encodeAddress(address(tokenA));
        state[4] = WeirollTestHelper.encodeAddress(rebase);
        state[5] = WeirollTestHelper.encodeUint256(amountIn);
        state[6] = WeirollTestHelper.encodeUint256(rebaseAmount);

        commands = new bytes32[](4);
        commands[0] = WeirollTestHelper.buildApproveCommand(address(tokenA), 2, 5);
        commands[1] = WeirollTestHelper.buildCallFourArgs(
            address(dex), bytes4(keccak256("swap(address,address,uint256,uint256)")), 3, 4, 5, 1
        );
        commands[2] = WeirollTestHelper.buildTransferCommand(rebase, 0, 1);
        commands[3] = WeirollTestHelper.buildCallOneArg(rebase, rebaseSelector, 6);
    }

    /// @dev Weiroll program that mints `amount` of `token` directly to the Router. Bypasses the
    ///      DEX entirely: useful for tests that need the Router's outputDiff to include tokens
    ///      that were never pushed through a transfer (e.g., tokens whose `transfer` is
    ///      deliberately broken for the purpose of the test).
    function _buildMintToRouterProgram(address token, uint256 amount)
        internal
        view
        returns (bytes32[] memory commands, bytes[] memory state)
    {
        state = WeirollTestHelper.createState2(
            WeirollTestHelper.encodeAddress(address(router)), WeirollTestHelper.encodeUint256(amount)
        );
        commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildMintCommand(token, 0, 1);
    }

    /// @dev approve(tokenA, ethSender, amountIn) + ethSender.swapToETH(tokenA, amountIn, amountOut, router).
    function _buildA2ETHProgram(uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (bytes32[] memory commands, bytes[] memory state)
    {
        state = new bytes[](5);
        state[0] = WeirollTestHelper.encodeAddress(address(ethSender));
        state[1] = WeirollTestHelper.encodeUint256(amountIn);
        state[2] = WeirollTestHelper.encodeAddress(address(tokenA));
        state[3] = WeirollTestHelper.encodeUint256(amountOut);
        state[4] = WeirollTestHelper.encodeAddress(address(router));

        commands = new bytes32[](2);
        commands[0] = WeirollTestHelper.buildApproveCommand(address(tokenA), 0, 1);
        commands[1] = WeirollTestHelper.buildCallFourArgs(
            address(ethSender), bytes4(keccak256("swapToETH(address,uint256,uint256,address)")), 2, 1, 3, 4
        );
    }

    /// @dev Default-filled SwapParams builder. Fees zero, recipient is the local `receiver`.
    function _params(
        address inputToken,
        uint256 inputAmount,
        address outputToken,
        uint256 outputQuote,
        uint256 outputMin,
        address recipient_,
        bytes32[] memory commands,
        bytes[] memory state
    ) internal pure returns (Router.SwapParams memory p) {
        p = Router.SwapParams({
            inputToken: inputToken,
            inputAmount: inputAmount,
            outputToken: outputToken,
            outputQuote: outputQuote,
            outputMin: outputMin,
            recipient: recipient_,
            protocolFeeBps: 0,
            partnerFeeBps: 0,
            partnerRecipient: address(0),
            partnerFeeOnOutput: false,
            passPositiveSlippageToUser: false,
            weirollCommands: commands,
            weirollState: state
        });
    }

    // ==================================================================
    // FR-15: fee-on-transfer on input
    // ==================================================================

    /// @notice FeeOnTransferToken as input. Fee-on-transfer tokens are unsupported; this test
    ///         documents the Router's accounting behavior when one is pulled, not a support
    ///         guarantee. Router's balance-diff must reflect the post-burn amount; fees are
    ///         computed off the measured `pulled`, not the caller-declared `inputAmount`. Protocol fee retained by Router equals `pulled * bps / 10000`,
    ///         proving the off-`pulled` computation (an `inputAmount`-based computation would
    ///         yield a larger retained balance). The executor receives the forwarded amount
    ///         minus the second 1% burn incurred on the Router -> executor transfer.
    function test_FOT_InputToken() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        uint256 inputAmount = 1000e18;
        uint256 pulled = (inputAmount * 9900) / 10_000; // 990e18 — Router balance after pull
        uint16 protocolBps = 100; // 1% on input side
        uint256 protocolFee = (pulled * protocolBps) / 10_000; // 9.9e18, retained by Router
        uint256 forwardAmount = pulled - protocolFee; // 980.1e18, transferred to executor
        uint256 execReceives = (forwardAmount * 9900) / 10_000; // 970.299e18 after 1% burn
        uint256 producedOut = 900e18;

        fot.mint(user, inputAmount);
        vm.prank(user);
        fot.approve(address(router), inputAmount);

        (bytes32[] memory commands, bytes[] memory state) =
            _buildSwapProgram(address(fot), address(tokenB), execReceives, producedOut);
        Router.SwapParams memory p =
            _params(address(fot), inputAmount, address(tokenB), producedOut, 800e18, receiver, commands, state);
        p.protocolFeeBps = protocolBps;

        vm.prank(user);
        uint256 returned = router.swap(p);

        // Router.balanceOf(input) == pulled - forwardAmount == protocolFee (computed off pulled).
        assertEq(fot.balanceOf(address(router)), protocolFee, "router retains fee off pulled");
        // 10e18-based fee would be wrong; the off-pulled 9.9e18 answer pins down that behavior.
        assertTrue(protocolFee != (inputAmount * protocolBps) / 10_000, "fee differs from input-side");
        // Executor received the forwarded amount minus the additional 1% burn (balance-diff over
        // the Router->executor transfer). The DEX pulled it all during the program.
        assertEq(fot.balanceOf(address(executor)), 0, "executor consumed forward");
        // Recipient receives amountOut >= outputMin.
        assertEq(returned, producedOut, "return == measured amountOut");
        assertEq(tokenB.balanceOf(receiver), producedOut, "receiver paid");
        assertGe(tokenB.balanceOf(receiver), 800e18, "amountOut >= outputMin");
        // Records executor's input was correctly derived from pulled-fees (minus the second burn).
        assertEq(execReceives, 970_299_000_000_000_000_000, "exec input = (pulled - fee) * 99/100");
    }

    // ==================================================================
    // FR-15: fee-on-transfer on output
    // ==================================================================

    /// @notice FeeOnTransferToken as output. Router's balance-diff equals `dexMint * 99/100`
    ///         because of the 1% burn on executor -> Router. A loose `outputMin` under that
    ///         threshold succeeds; a tight `outputMin` above it reverts `SlippageExceeded`
    ///         with the Router-measured `got` value.
    function test_FOT_OutputToken() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        uint256 inputAmount = 1000e18;
        uint256 dexMint = 1000e18; // minted to executor by DEX
        uint256 routerMeasures = (dexMint * 9900) / 10_000; // 990e18 after 1% burn to Router

        // ---- Scenario A: loose outputMin succeeds
        tokenA.mint(user, inputAmount);
        vm.prank(user);
        tokenA.approve(address(router), inputAmount);
        (bytes32[] memory commands, bytes[] memory state) =
            _buildSwapProgram(address(tokenA), address(fot), inputAmount, dexMint);
        Router.SwapParams memory pOk =
            _params(address(tokenA), inputAmount, address(fot), dexMint, 950e18, receiver, commands, state);

        vm.prank(user);
        uint256 returned = router.swap(pOk);
        assertEq(returned, routerMeasures, "router measures post-burn delta");
        // Receiver gets a further 1% burn on the Router -> receiver transfer.
        assertEq(fot.balanceOf(receiver), (routerMeasures * 9900) / 10_000, "receiver post second burn");
        assertEq(fot.balanceOf(address(router)), 0, "router paid out full measured amount");

        // ---- Scenario B: tight outputMin above post-burn level reverts
        tokenA.mint(user, inputAmount);
        vm.prank(user);
        tokenA.approve(address(router), inputAmount);
        (bytes32[] memory commands2, bytes[] memory state2) =
            _buildSwapProgram(address(tokenA), address(fot), inputAmount, dexMint);
        Router.SwapParams memory pTight =
            _params(address(tokenA), inputAmount, address(fot), dexMint, 995e18, receiver, commands2, state2);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(Router.SlippageExceeded.selector, address(fot), routerMeasures, uint256(995e18))
        );
        router.swap(pTight);
    }

    // ==================================================================
    // FR-15: rebasing tokens
    // ==================================================================

    /// @notice RebasingToken as output. The Weiroll program mints `dexMint` tokens to the
    ///         executor, transfers them to the Router, then calls `rebaseUp(500)` — all between
    ///         Router's pre- and post-executor snapshots. Router measures `dexMint * 1.05`,
    ///         positive-slippage capping clips at `outputQuote == dexMint`, and the 5% surplus
    ///         is retained in the Router.
    function test_Rebasing_OutputPositiveRebase() public {
        RebasingToken rebase = new RebasingToken();
        uint256 inputAmount = 1000e18;
        uint256 dexMint = 1000e18;
        uint256 rebasedBalance = (dexMint * 10500) / 10_000; // 1050e18 after +5%
        uint256 expectedSlippage = rebasedBalance - dexMint; // 50e18

        tokenA.mint(user, inputAmount);
        vm.prank(user);
        tokenA.approve(address(router), inputAmount);

        (bytes32[] memory commands, bytes[] memory state) = _buildRebaseSwapProgram(
            address(rebase), inputAmount, dexMint, bytes4(keccak256("rebaseUp(uint256)")), 500
        );
        Router.SwapParams memory p =
            _params(address(tokenA), inputAmount, address(rebase), dexMint, 900e18, receiver, commands, state);
        p.passPositiveSlippageToUser = false; // cap at outputQuote

        vm.prank(user);
        uint256 returned = router.swap(p);

        assertEq(returned, dexMint, "user receives capped quote, not the rebased surplus");
        // Rebase share-math rounds down on transfer; allow 1 wei of dust per leg.
        assertApproxEqAbs(rebase.balanceOf(receiver), dexMint, 1, "receiver ~ outputQuote");
        assertApproxEqAbs(rebase.balanceOf(address(router)), expectedSlippage, 1, "router retains +5% surplus");
    }

    /// @notice RebasingToken as output, `rebaseDown(500)` during execution shrinks the Router's
    ///         measured delta below `outputMin`. The Router reverts `SlippageExceeded` with the
    ///         post-rebase amount as `got`.
    function test_Rebasing_OutputNegativeRebase() public {
        RebasingToken rebase = new RebasingToken();
        uint256 inputAmount = 1000e18;
        uint256 dexMint = 1000e18;
        uint256 postRebaseBalance = (dexMint * 9500) / 10_000; // 950e18 after -5%

        tokenA.mint(user, inputAmount);
        vm.prank(user);
        tokenA.approve(address(router), inputAmount);

        (bytes32[] memory commands, bytes[] memory state) = _buildRebaseSwapProgram(
            address(rebase), inputAmount, dexMint, bytes4(keccak256("rebaseDown(uint256)")), 500
        );
        Router.SwapParams memory p = _params(
            address(tokenA),
            inputAmount,
            address(rebase),
            dexMint,
            960e18, // outputMin above the post-rebase balance
            receiver,
            commands,
            state
        );

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                Router.SlippageExceeded.selector, address(rebase), postRebaseBalance, uint256(960e18)
            )
        );
        router.swap(p);
    }

    // ==================================================================
    // FR-15: weird-ERC20 return conventions
    // ==================================================================

    /// @notice USDT-style no-return-value token on input. SafeERC20's `_safeTransferFrom`
    ///         (low-level call + returndata size check) treats an empty return as success, so
    ///         the Router can pull and forward the input. The executor ends up with the full
    ///         forwarded amount; the output side is a clean MockERC20 minted directly to the
    ///         Router so the test isolates the input-side SafeERC20 behavior.
    function test_NoReturnToken_Input() public {
        NoReturnToken nrt = new NoReturnToken();
        uint256 inputAmount = 1000e18;
        uint256 producedOut = 900e18;

        nrt.mint(user, inputAmount);
        vm.prank(user);
        nrt.approve(address(router), inputAmount);

        // Output is produced by minting tokenB directly to the Router: no SafeERC20 interaction
        // with the output side here, keeping the assertion targeted at the input-side handler.
        (bytes32[] memory commands, bytes[] memory state) = _buildMintToRouterProgram(address(tokenB), producedOut);
        Router.SwapParams memory p =
            _params(address(nrt), inputAmount, address(tokenB), producedOut, 800e18, receiver, commands, state);

        vm.prank(user);
        uint256 returned = router.swap(p);

        assertEq(returned, producedOut, "return == outputDelta");
        // No-return token transferred cleanly on both legs (user -> Router -> executor).
        assertEq(nrt.balanceOf(user), 0, "user spent full input");
        assertEq(nrt.balanceOf(address(router)), 0, "router forwarded full pulled");
        assertEq(nrt.balanceOf(address(executor)), inputAmount, "executor holds forwarded input");
        assertEq(tokenB.balanceOf(receiver), producedOut, "receiver paid");
    }

    /// @notice FalseReturningToken that returns `false` from transferFrom. SafeERC20 flips the
    ///         false return into `SafeERC20FailedOperation(token)` and the Router bubbles it.
    function test_FalseReturningToken_Input_Reverts() public {
        FalseReturningToken frt = new FalseReturningToken();
        uint256 inputAmount = 1000e18;
        uint256 producedOut = 900e18;

        frt.mint(user, inputAmount);
        vm.prank(user);
        frt.approve(address(router), inputAmount);
        // Force transferFrom to return false on the next call.
        frt.setShouldFail(true);

        (bytes32[] memory commands, bytes[] memory state) = _buildMintToRouterProgram(address(tokenB), producedOut);
        Router.SwapParams memory p =
            _params(address(frt), inputAmount, address(tokenB), producedOut, 800e18, receiver, commands, state);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(frt)));
        router.swap(p);
    }

    /// @notice FalseReturningToken as output. The Weiroll program mints FRT directly to the
    ///         Router so the executor -> Router leg cannot fail. After Router measures its
    ///         delta and validates `outputMin`, the final `_transferOut(recipient)` uses
    ///         SafeERC20.safeTransfer, which reverts on the false return from FRT.transfer.
    function test_FalseReturningToken_Output() public {
        FalseReturningToken frt = new FalseReturningToken();
        uint256 inputAmount = 1000e18;
        uint256 producedOut = 900e18;

        tokenA.mint(user, inputAmount);
        vm.prank(user);
        tokenA.approve(address(router), inputAmount);

        // FRT minted directly to the Router bypasses the in-Weiroll transfer, so the outputDiff
        // picks up `producedOut` without involving FRT.transfer. The false-return surface is the
        // Router's final SafeERC20.safeTransfer to the recipient.
        (bytes32[] memory commands, bytes[] memory state) = _buildMintToRouterProgram(address(frt), producedOut);
        // Arm the failure *after* mint so the mint path (which doesn't consult shouldFail) runs clean.
        frt.setShouldFail(true);

        Router.SwapParams memory p =
            _params(address(tokenA), inputAmount, address(frt), producedOut, 800e18, receiver, commands, state);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(frt)));
        router.swap(p);
    }

    // ==================================================================
    // FR-16: reentrancy
    // ==================================================================

    /// @notice Re-entry via an ERC20 callback. Recipient is a RouterReentrantReceiver with the
    ///         CallbackToken's callback enabled. When Router pays the recipient, CBT fires
    ///         `onTokenTransfer`, the receiver attempts `router.swap()` inside a try/catch, and
    ///         the Router's `nonReentrant` modifier reverts the inner call with
    ///         `ReentrancyGuardReentrantCall()`. The outer swap completes with no token inflation.
    function test_Reentrancy_ViaCallbackToken() public {
        CallbackToken cbt = new CallbackToken();
        RouterReentrantReceiver reenter = new RouterReentrantReceiver(router);
        cbt.enableCallback(address(reenter));

        uint256 inputAmount = 1000e18;
        uint256 producedOut = 900e18;

        tokenA.mint(user, inputAmount);
        vm.prank(user);
        tokenA.approve(address(router), inputAmount);

        (bytes32[] memory commands, bytes[] memory state) = _buildMintToRouterProgram(address(cbt), producedOut);
        Router.SwapParams memory p = _params(
            address(tokenA), inputAmount, address(cbt), producedOut, 800e18, address(reenter), commands, state
        );

        reenter.setAttackEnabled(true);

        vm.prank(user);
        uint256 returned = router.swap(p);

        // Inner try/catch recorded the reentrancy-guard selector.
        assertTrue(reenter.attackAttempted(), "reentry was attempted");
        assertFalse(reenter.attackSucceeded(), "reentry blocked");
        assertEq(reenter.lastRevertSelector(), REENTRANT_GUARD_SELECTOR, "ReentrancyGuardReentrantCall captured");

        // Outer swap completed and balances match non-reentrant accounting (no inflation).
        assertEq(returned, producedOut, "outer swap returned measured amountOut");
        assertEq(tokenA.balanceOf(address(router)), 0, "router holds no inputToken");
        assertEq(cbt.balanceOf(address(router)), 0, "router holds no outputToken");
        assertEq(cbt.balanceOf(address(reenter)), producedOut, "recipient paid exactly producedOut");
    }

    /// @notice Re-entry via native-ETH `receive`. Recipient is a RouterReentrantReceiver whose
    ///         `receive()` attempts `router.swap()` inside try/catch. Router's ETH payout uses
    ///         `.call{value}` which forwards enough gas for the re-entry attempt; the
    ///         `nonReentrant` modifier reverts the inner call with `ReentrancyGuardReentrantCall()`,
    ///         the catch records the selector, and the outer swap completes.
    function test_Reentrancy_ViaETHReceive() public {
        RouterReentrantReceiver reenter = new RouterReentrantReceiver(router);

        uint256 inputAmount = 1000e18;
        uint256 amountOut = 1 ether;

        tokenA.mint(user, inputAmount);
        vm.prank(user);
        tokenA.approve(address(router), inputAmount);

        (bytes32[] memory commands, bytes[] memory state) = _buildA2ETHProgram(inputAmount, amountOut);
        Router.SwapParams memory p = _params(
            address(tokenA), inputAmount, NATIVE_ETH, amountOut, 0.8 ether, address(reenter), commands, state
        );

        reenter.setAttackEnabled(true);

        uint256 routerEthBefore = address(router).balance;
        uint256 reenterEthBefore = address(reenter).balance;

        vm.prank(user);
        uint256 returned = router.swap(p);

        // Inner try/catch recorded the reentrancy-guard selector.
        assertTrue(reenter.attackAttempted(), "reentry was attempted");
        assertFalse(reenter.attackSucceeded(), "reentry blocked");
        assertEq(reenter.lastRevertSelector(), REENTRANT_GUARD_SELECTOR, "ReentrancyGuardReentrantCall captured");

        // Outer swap completed and balances match non-reentrant accounting.
        assertEq(returned, amountOut, "outer swap returned measured amountOut");
        assertEq(tokenA.balanceOf(address(router)), 0, "router holds no inputToken");
        assertEq(address(router).balance, routerEthBefore, "router ETH unchanged");
        assertEq(address(reenter).balance - reenterEthBefore, amountOut, "recipient paid exactly amountOut");
    }
}
