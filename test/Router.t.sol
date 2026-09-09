// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionProxy } from "../src/ExecutionProxy.sol";
import { IExecutor } from "../src/interfaces/IExecutor.sol";
import { Router, RouterErrors } from "../src/Router.sol";
import { WeirollTestHelper } from "./helpers/WeirollTestHelper.sol";
import { MockDEX } from "./mocks/MockDEX.sol";

/// @title MockERC20
/// @notice Minimal ERC20 for testing. Duplicated from ExecutionProxy.t.sol per the task's
///         "duplicate minimally at the top of this test" option to keep the Router test file
///         self-contained without altering the existing ExecutionProxy test scope.
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

/// @title MockWETH
/// @notice Minimal WETH for testing.
contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) { }

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
        emit Transfer(address(0), msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        payable(msg.sender).transfer(amount);
        emit Transfer(msg.sender, address(0), amount);
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
    }
}

/// @title MockETHSender
/// @notice Test-only sink used inside Weiroll programs that must produce native ETH on the
///         Router as "executor output". Accepts `tokenIn` from the caller (executor) and
///         forwards a fixed `amountOut` of ETH to `recipient` (Router). Pre-funded via
///         `vm.deal` so the swap path can measure Router's native balance delta.
contract MockETHSender {
    function swapToETH(address tokenIn, uint256 amountIn, uint256 amountOut, address recipient) external {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        (bool ok,) = recipient.call{ value: amountOut }("");
        require(ok, "MockETHSender: eth send failed");
    }

    receive() external payable { }
}

/// @title RevertingExecutor
/// @notice Test-only `IExecutor` whose `executePath` always reverts with `Boom()`. Used to
///         prove that Router bubbles executor reverts verbatim and that atomic rollback
///         preserves the user's approval and balances on failure.
contract RevertingExecutor is IExecutor {
    error Boom();

    function executePath(bytes32[] calldata, bytes[] calldata) external payable override {
        revert Boom();
    }

    receive() external payable { }
    fallback() external payable { }
}

/// @title RouterTest
/// @notice Covers Router.swap() happy paths and all quote/integrity validation reverts from
///         the Error Handling table. Fee math (protocol/partner/positive-slippage) is
///         intentionally zero here so the core pull -> forward -> measure -> transfer pipeline
///         is exercised in isolation. Fee-specific assertions live in INF-0008.
contract RouterTest is Test {
    ExecutionProxy public executor;
    Router public router;
    MockWETH public weth;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;
    MockDEX public dex;
    MockETHSender public ethSender;

    address public user = makeAddr("user");
    address public receiver = makeAddr("receiver");
    address public liquidator = makeAddr("liquidator");

    address public constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @dev Mirror of Router's `Swap` event used with `vm.expectEmit`. Keeping a local copy
    ///      here lets us `emit Swap(...)` at the assertion site without importing an interface
    ///      we don't otherwise need.
    event Swap(
        address indexed sender,
        address inputToken,
        uint256 inputAmount,
        address outputToken,
        uint256 amountOut,
        uint256 amountToUser,
        uint256 protocolFee,
        uint256 partnerFee,
        uint256 positiveSlippageCaptured,
        address partnerRecipient
    );

    event PendingExecutorSet(address pendingExecutor);
    event ExecutorUpdated(address previousExecutor, address newExecutor);

    function setUp() public {
        router = new Router(address(this), liquidator);
        executor = new ExecutionProxy(address(router));
        router.setPendingExecutor(address(executor));
        router.acceptExecutor();

        weth = new MockWETH();
        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);
        tokenC = new MockERC20("Token C", "TKNC", 6);
        dex = new MockDEX();
        ethSender = new MockETHSender();

        vm.deal(user, 100 ether);
        vm.deal(address(ethSender), 100 ether);
    }

    // ------------------------------------------------------------------
    // Weiroll program builders
    // ------------------------------------------------------------------

    /// @dev Build a Weiroll program that (executed by the executor after Router has forwarded
    ///      `amountIn` of `tokenA`): approves MockDEX, swaps A->B minting `amountOut` of tokenB
    ///      to the executor, then transfers the full `amountOut` of tokenB to the Router so
    ///      balance-diff accounting picks it up.
    function _buildA2BProgram(uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (bytes32[] memory commands, bytes[] memory state)
    {
        state = new bytes[](6);
        state[0] = WeirollTestHelper.encodeAddress(address(router)); // transfer destination
        state[1] = WeirollTestHelper.encodeUint256(amountOut);
        state[2] = WeirollTestHelper.encodeAddress(address(dex));
        state[3] = WeirollTestHelper.encodeAddress(address(tokenA));
        state[4] = WeirollTestHelper.encodeAddress(address(tokenB));
        state[5] = WeirollTestHelper.encodeUint256(amountIn);

        commands = new bytes32[](3);
        commands[0] = WeirollTestHelper.buildApproveCommand(address(tokenA), 2, 5);
        commands[1] = WeirollTestHelper.buildCallFourArgs(
            address(dex), bytes4(keccak256("swap(address,address,uint256,uint256)")), 3, 4, 5, 1
        );
        commands[2] = WeirollTestHelper.buildTransferCommand(address(tokenB), 0, 1);
    }

    /// @dev Build a Weiroll program that mints `amount` of `token` directly to the Router.
    ///      Used for native-ETH-in cases where the executor already received ETH via
    ///      `msg.value` and the only side effect needed for the Router's balance-diff is
    ///      a positive delta on the output token.
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

    /// @dev Build a Weiroll program that (executed by the executor after Router has forwarded
    ///      `amountIn` of `tokenA`): approves MockETHSender, which pulls tokenA from the
    ///      executor and sends `amountOut` of native ETH to the Router. Router's native
    ///      balance delta is what the swap pipeline measures.
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

    /// @dev Compose default zero-fee SwapParams around a prebuilt Weiroll program. Keeps tests
    ///      short and centralizes the "boring" fields so the intent of each test (which field
    ///      is being varied to trigger which revert) stays visible at the call site.
    function _buildParams(
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

    // ------------------------------------------------------------------
    // Happy paths
    // ------------------------------------------------------------------

    function test_SwapERC20ToERC20() public {
        uint256 amountIn = 1000e18;
        uint256 amountOut = 900e18;
        uint256 quote = 900e18;
        uint256 min = 800e18;

        tokenA.mint(user, amountIn);
        vm.prank(user);
        tokenA.approve(address(router), amountIn);

        (bytes32[] memory commands, bytes[] memory state) = _buildA2BProgram(amountIn, amountOut);
        Router.SwapParams memory params =
            _buildParams(address(tokenA), amountIn, address(tokenB), quote, min, receiver, commands, state);

        // Indexed sender + all nine non-indexed data fields compared for exact match.
        vm.expectEmit(true, false, false, true, address(router));
        emit Swap(user, address(tokenA), amountIn, address(tokenB), amountOut, amountOut, 0, 0, 0, address(0));

        vm.prank(user);
        uint256 returned = router.swap(params);

        assertEq(returned, amountOut, "return value");
        assertEq(tokenB.balanceOf(receiver), amountOut, "receiver balance");
        assertGe(tokenB.balanceOf(receiver), min, "receiver >= outputMin");
        assertLe(tokenB.balanceOf(receiver), quote, "receiver <= outputQuote");
        assertEq(tokenA.balanceOf(address(router)), 0, "router holds no inputToken");
        assertEq(tokenB.balanceOf(address(router)), 0, "router holds no outputToken when amountOut == quote");
    }

    function test_SwapNativeETHIn() public {
        uint256 amountIn = 1 ether;
        uint256 amountOut = 900e18;
        uint256 quote = 900e18;
        uint256 min = 800e18;

        (bytes32[] memory commands, bytes[] memory state) = _buildMintToRouterProgram(address(tokenB), amountOut);
        Router.SwapParams memory params =
            _buildParams(NATIVE_ETH, amountIn, address(tokenB), quote, min, receiver, commands, state);

        vm.expectEmit(true, false, false, true, address(router));
        emit Swap(user, NATIVE_ETH, amountIn, address(tokenB), amountOut, amountOut, 0, 0, 0, address(0));

        vm.prank(user);
        uint256 returned = router.swap{ value: amountIn }(params);

        assertEq(returned, amountOut, "return value");
        assertEq(tokenB.balanceOf(receiver), amountOut, "receiver tokenB");
        assertEq(address(router).balance, 0, "router ETH balance");
    }

    function test_SwapNativeETHOut() public {
        uint256 amountIn = 1000e18;
        uint256 amountOut = 1 ether;
        uint256 quote = 1 ether;
        uint256 min = 0.8 ether;

        tokenA.mint(user, amountIn);
        vm.prank(user);
        tokenA.approve(address(router), amountIn);

        uint256 receiverBalanceBefore = receiver.balance;

        (bytes32[] memory commands, bytes[] memory state) = _buildA2ETHProgram(amountIn, amountOut);
        Router.SwapParams memory params =
            _buildParams(address(tokenA), amountIn, NATIVE_ETH, quote, min, receiver, commands, state);

        vm.expectEmit(true, false, false, true, address(router));
        emit Swap(user, address(tokenA), amountIn, NATIVE_ETH, amountOut, amountOut, 0, 0, 0, address(0));

        vm.prank(user);
        uint256 returned = router.swap(params);

        assertEq(returned, amountOut, "return value");
        assertEq(receiver.balance - receiverBalanceBefore, amountOut, "receiver ETH delta");
        assertEq(address(router).balance, 0, "router ETH balance");
    }

    // ------------------------------------------------------------------
    // Integrity / quote-validity reverts (Error Handling table)
    // ------------------------------------------------------------------

    function test_Revert_ZeroInputAmount() public {
        (bytes32[] memory commands, bytes[] memory state) = _buildA2BProgram(1, 1);
        Router.SwapParams memory params =
            _buildParams(address(tokenA), 0, address(tokenB), 900e18, 800e18, receiver, commands, state);

        vm.prank(user);
        vm.expectRevert(Router.ZeroInputAmount.selector);
        router.swap(params);
    }

    function test_Revert_ZeroOutputQuote() public {
        (bytes32[] memory commands, bytes[] memory state) = _buildA2BProgram(1000e18, 900e18);
        Router.SwapParams memory params =
            _buildParams(address(tokenA), 1000e18, address(tokenB), 0, 800e18, receiver, commands, state);

        vm.prank(user);
        vm.expectRevert(Router.ZeroOutputQuote.selector);
        router.swap(params);
    }

    function test_Revert_ZeroOutputMin() public {
        (bytes32[] memory commands, bytes[] memory state) = _buildA2BProgram(1000e18, 900e18);
        Router.SwapParams memory params =
            _buildParams(address(tokenA), 1000e18, address(tokenB), 900e18, 0, receiver, commands, state);

        vm.prank(user);
        vm.expectRevert(Router.ZeroOutputMin.selector);
        router.swap(params);
    }

    function test_Revert_InvalidSlippageBounds() public {
        (bytes32[] memory commands, bytes[] memory state) = _buildA2BProgram(1000e18, 900e18);
        // outputMin > outputQuote
        Router.SwapParams memory params =
            _buildParams(address(tokenA), 1000e18, address(tokenB), 900e18, 1000e18, receiver, commands, state);

        vm.prank(user);
        vm.expectRevert(Router.InvalidSlippageBounds.selector);
        router.swap(params);
    }

    function test_Revert_SelfSwap() public {
        (bytes32[] memory commands, bytes[] memory state) = _buildA2BProgram(1000e18, 900e18);
        Router.SwapParams memory params =
            _buildParams(address(tokenA), 1000e18, address(tokenA), 900e18, 800e18, receiver, commands, state);

        vm.prank(user);
        vm.expectRevert(Router.SelfSwap.selector);
        router.swap(params);
    }

    function test_Revert_ETHValueMismatch_NativeIn() public {
        (bytes32[] memory commands, bytes[] memory state) = _buildMintToRouterProgram(address(tokenB), 900e18);
        Router.SwapParams memory params =
            _buildParams(NATIVE_ETH, 1 ether, address(tokenB), 900e18, 800e18, receiver, commands, state);

        // msg.value (0.5 ether) != inputAmount (1 ether)
        vm.prank(user);
        vm.expectRevert(Router.ETHValueMismatch.selector);
        router.swap{ value: 0.5 ether }(params);
    }

    function test_Revert_ETHValueMismatch_ERC20In() public {
        tokenA.mint(user, 1000e18);
        vm.prank(user);
        tokenA.approve(address(router), 1000e18);

        (bytes32[] memory commands, bytes[] memory state) = _buildA2BProgram(1000e18, 900e18);
        Router.SwapParams memory params =
            _buildParams(address(tokenA), 1000e18, address(tokenB), 900e18, 800e18, receiver, commands, state);

        // msg.value != 0 with ERC20 input
        vm.prank(user);
        vm.expectRevert(Router.ETHValueMismatch.selector);
        router.swap{ value: 1 ether }(params);
    }

    function test_Revert_ExecutorNotSet() public {
        // Fresh Router with no executor wired up.
        Router freshRouter = new Router(address(this), liquidator);

        (bytes32[] memory commands, bytes[] memory state) = _buildA2BProgram(1000e18, 900e18);
        Router.SwapParams memory params =
            _buildParams(address(tokenA), 1000e18, address(tokenB), 900e18, 800e18, receiver, commands, state);

        tokenA.mint(user, 1000e18);
        vm.prank(user);
        tokenA.approve(address(freshRouter), 1000e18);

        vm.prank(user);
        vm.expectRevert(Router.ExecutorNotSet.selector);
        freshRouter.swap(params);
    }

    function test_Revert_Paused() public {
        router.pause();

        (bytes32[] memory commands, bytes[] memory state) = _buildA2BProgram(1000e18, 900e18);
        Router.SwapParams memory params =
            _buildParams(address(tokenA), 1000e18, address(tokenB), 900e18, 800e18, receiver, commands, state);

        vm.prank(user);
        vm.expectRevert(RouterErrors.Paused.selector);
        router.swap(params);
    }

    // ------------------------------------------------------------------
    // Executor revert bubbling and atomic rollback
    // ------------------------------------------------------------------

    function test_Revert_ExecutorBubblesUp_PreservesApproval() public {
        RevertingExecutor badExec = new RevertingExecutor();
        router.setPendingExecutor(address(badExec));
        router.acceptExecutor();

        uint256 amountIn = 1000e18;
        tokenA.mint(user, amountIn);

        // Infinite approval -- verify it is untouched after the revert.
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);

        uint256 userBalanceBefore = tokenA.balanceOf(user);
        uint256 allowanceBefore = tokenA.allowance(user, address(router));

        (bytes32[] memory commands, bytes[] memory state) = _buildA2BProgram(amountIn, 900e18);
        Router.SwapParams memory params =
            _buildParams(address(tokenA), amountIn, address(tokenB), 900e18, 800e18, receiver, commands, state);

        vm.prank(user);
        vm.expectRevert(RevertingExecutor.Boom.selector);
        router.swap(params);

        // Atomic rollback invariants.
        assertEq(tokenA.balanceOf(user), userBalanceBefore, "user keeps input");
        assertEq(tokenA.allowance(user, address(router)), allowanceBefore, "allowance untouched");
        assertEq(tokenA.balanceOf(address(router)), 0, "router holds no inputToken");
        assertEq(tokenB.balanceOf(address(router)), 0, "router holds no outputToken");
        assertEq(tokenA.balanceOf(address(badExec)), 0, "executor holds no inputToken");
        assertEq(tokenB.balanceOf(address(badExec)), 0, "executor holds no outputToken");
    }

    // ------------------------------------------------------------------
    // Two-step executor registry
    // ------------------------------------------------------------------

    function test_ExecutorRegistry_TwoStep() public {
        // Transition 1: initial state (post-setUp). Active executor is the one wired in setUp,
        // pendingExecutor is zero.
        assertEq(router.executor(), address(executor), "initial executor");
        assertEq(router.pendingExecutor(), address(0), "initial pending");

        // Non-owner cannot propose a new executor.
        ExecutionProxy newExec = new ExecutionProxy(address(router));
        vm.prank(user);
        vm.expectRevert();
        router.setPendingExecutor(address(newExec));

        // Transition 2: owner proposes -- pending is set, active is unchanged.
        vm.expectEmit(false, false, false, true, address(router));
        emit PendingExecutorSet(address(newExec));
        router.setPendingExecutor(address(newExec));
        assertEq(router.pendingExecutor(), address(newExec), "pending set");
        assertEq(router.executor(), address(executor), "active unchanged by propose");

        // Transition 3: owner accepts -- active becomes newExec, pending cleared.
        vm.expectEmit(false, false, false, true, address(router));
        emit ExecutorUpdated(address(executor), address(newExec));
        router.acceptExecutor();
        assertEq(router.executor(), address(newExec), "active promoted");
        assertEq(router.pendingExecutor(), address(0), "pending cleared");

        // acceptExecutor reverts when pending is zero.
        vm.expectRevert(Router.ExecutorNotSet.selector);
        router.acceptExecutor();

        // Transition 4: subsequent swap executes against the newly-promoted executor.
        uint256 amountIn = 1000e18;
        uint256 amountOut = 900e18;
        tokenA.mint(user, amountIn);
        vm.prank(user);
        tokenA.approve(address(router), amountIn);

        (bytes32[] memory commands, bytes[] memory state) = _buildA2BProgram(amountIn, amountOut);
        Router.SwapParams memory params =
            _buildParams(address(tokenA), amountIn, address(tokenB), amountOut, 800e18, receiver, commands, state);

        vm.prank(user);
        uint256 returned = router.swap(params);
        assertEq(returned, amountOut, "swap against newExec succeeded");
        assertEq(tokenB.balanceOf(receiver), amountOut, "receiver paid by newExec path");
        // tokenA forwarded by Router has been consumed by the MockDEX invoked from newExec.
        assertEq(tokenA.balanceOf(address(newExec)), 0, "newExec holds no inputToken after swap");
    }
}
