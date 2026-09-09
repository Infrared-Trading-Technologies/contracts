// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ExecutionProxy } from "../src/ExecutionProxy.sol";
import { Router, RouterErrors } from "../src/Router.sol";
import { WeirollTestHelper } from "./helpers/WeirollTestHelper.sol";
import { MockDEX } from "./mocks/MockDEX.sol";

/// @title MockERC20
/// @notice Minimal ERC20 for testing. Duplicated from Router.t.sol to keep the Router.Access
///         test file self-contained (consistent with sibling Router test files).
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

/// @title RouterAccessTest
/// @notice Covers FR-13 (fee custody + sweep permissions) and FR-14 (access control: Ownable2Step
///         owner, separate liquidator, pause behavior). Deploys Router with a dedicated owner EOA
///         and a dedicated liquidator EOA so the two roles can be pranked independently without
///         collision with `address(this)` ownership of the test contract itself. setUp seeds the
///         Router with protocol-fee dust by running one successful 1%-protocol-fee swap so that
///         sweep assertions have real balances to move.
contract RouterAccessTest is Test {
    ExecutionProxy public executor;
    Router public router;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockDEX public dex;

    address public owner = makeAddr("owner");
    address public liquidator = makeAddr("liquidator");
    address public user = makeAddr("user");
    address public seedRecipient = makeAddr("seedRecipient");
    address public stranger = makeAddr("stranger");
    address public dest = makeAddr("dest");

    address public constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @dev Protocol-fee dust seeded into the Router by setUp's warm-up swap. One percent of
    ///      `SEED_INPUT` stays in the Router (balance-diff retention) and is the starting
    ///      point for all sweep tests.
    uint256 internal constant SEED_INPUT = 1000e18;
    uint256 internal constant SEED_FORWARD = 990e18;
    uint256 internal constant SEED_OUTPUT = 900e18;
    uint256 internal constant SEED_DUST = 10e18; // SEED_INPUT - SEED_FORWARD

    event LiquidatorUpdated(address previousLiquidator, address newLiquidator);
    event FundsTransferred(address[] tokens, uint256[] amounts, address dest);

    function setUp() public {
        router = new Router(owner, liquidator);
        executor = new ExecutionProxy(address(router));

        vm.startPrank(owner);
        router.setPendingExecutor(address(executor));
        router.acceptExecutor();
        vm.stopPrank();

        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);
        dex = new MockDEX();

        // Warm-up swap to leave 1% protocol-fee dust in the Router. User pulls 1000e18 of
        // tokenA; 10e18 stays on the Router as protocol fee; the remaining 990e18 is forwarded
        // to the executor and swapped for 900e18 tokenB that is paid out to `seedRecipient`.
        tokenA.mint(user, SEED_INPUT);
        vm.prank(user);
        tokenA.approve(address(router), SEED_INPUT);

        (bytes32[] memory commands, bytes[] memory state) = _buildA2BProgram(SEED_FORWARD, SEED_OUTPUT);
        Router.SwapParams memory p = Router.SwapParams({
            inputToken: address(tokenA),
            inputAmount: SEED_INPUT,
            outputToken: address(tokenB),
            outputQuote: SEED_OUTPUT,
            outputMin: SEED_OUTPUT - 1,
            recipient: seedRecipient,
            protocolFeeBps: 100, // 1% -> 10e18 stays in Router
            partnerFeeBps: 0,
            partnerRecipient: address(0),
            partnerFeeOnOutput: false,
            passPositiveSlippageToUser: false,
            weirollCommands: commands,
            weirollState: state
        });
        vm.prank(user);
        router.swap(p);

        assertEq(tokenA.balanceOf(address(router)), SEED_DUST, "router dust seeded");
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Standard tokenA -> tokenB Weiroll program (approve DEX, swap, transfer output to
    ///      Router). Identical in shape to `Router.t.sol::_buildA2BProgram`.
    function _buildA2BProgram(uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (bytes32[] memory commands, bytes[] memory state)
    {
        state = new bytes[](6);
        state[0] = WeirollTestHelper.encodeAddress(address(router));
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

    /// @dev Zero-fee SwapParams for a fresh user-initiated swap. Feeds a Weiroll program sized to
    ///      the full input (no protocol/partner skim), so the executor pulls the entire pulled
    ///      amount from the Router and produces `SEED_OUTPUT` of tokenB.
    function _mkUserSwapParams() internal view returns (Router.SwapParams memory p) {
        (bytes32[] memory commands, bytes[] memory state) = _buildA2BProgram(SEED_INPUT, SEED_OUTPUT);
        p = Router.SwapParams({
            inputToken: address(tokenA),
            inputAmount: SEED_INPUT,
            outputToken: address(tokenB),
            outputQuote: SEED_OUTPUT,
            outputMin: SEED_OUTPUT - 1,
            recipient: seedRecipient,
            protocolFeeBps: 0,
            partnerFeeBps: 0,
            partnerRecipient: address(0),
            partnerFeeOnOutput: false,
            passPositiveSlippageToUser: false,
            weirollCommands: commands,
            weirollState: state
        });
    }

    /// @dev Single-input / single-output MultiSwapParams, used only for the paused-blocks-multi
    ///      test: the modifier chain reverts before any pull / dex interaction so the payload
    ///      never has to be economically viable.
    function _mkMultiSwapParams() internal view returns (Router.MultiSwapParams memory mp) {
        address[] memory inputTokens = new address[](1);
        inputTokens[0] = address(tokenA);
        uint256[] memory inputAmounts = new uint256[](1);
        inputAmounts[0] = SEED_INPUT;
        address[] memory outputTokens = new address[](1);
        outputTokens[0] = address(tokenB);
        uint256[] memory outputQuotes = new uint256[](1);
        outputQuotes[0] = SEED_OUTPUT;
        uint256[] memory outputMins = new uint256[](1);
        outputMins[0] = SEED_OUTPUT - 1;

        (bytes32[] memory commands, bytes[] memory state) = _buildA2BProgram(SEED_INPUT, SEED_OUTPUT);
        mp = Router.MultiSwapParams({
            inputTokens: inputTokens,
            inputAmounts: inputAmounts,
            outputTokens: outputTokens,
            outputQuotes: outputQuotes,
            outputMins: outputMins,
            recipient: seedRecipient,
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
    // Ownable2Step
    // ------------------------------------------------------------------

    function test_Ownable_InitialOwner() public view {
        assertEq(router.owner(), owner, "initial owner");
        assertEq(router.pendingOwner(), address(0), "initial pendingOwner");
    }

    function test_Ownable_TransferTwoStep() public {
        address newOwner = makeAddr("newOwner");

        // Step 1: current owner proposes. Active owner unchanged until step 2.
        vm.prank(owner);
        router.transferOwnership(newOwner);
        assertEq(router.pendingOwner(), newOwner, "pendingOwner set");
        assertEq(router.owner(), owner, "owner unchanged by propose");

        // A stranger trying to accept reverts with OwnableUnauthorizedAccount.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        router.acceptOwnership();

        // Old owner still holds owner privileges until transfer completes.
        assertEq(router.owner(), owner, "owner still old");

        // Step 2: new owner accepts. Only now does ownership rotate.
        vm.prank(newOwner);
        router.acceptOwnership();
        assertEq(router.owner(), newOwner, "owner rotated");
        assertEq(router.pendingOwner(), address(0), "pendingOwner cleared");

        // And new owner can exercise owner-only functions.
        vm.prank(newOwner);
        router.pause();
        assertTrue(router.paused(), "new owner can pause");
    }

    function test_Ownable_NonOwner_CannotSetPendingExecutor() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        router.setPendingExecutor(address(0xdead));
    }

    function test_Ownable_NonOwner_CannotSetLiquidator() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        router.setLiquidator(address(0xdead));
    }

    function test_Ownable_NonOwner_CannotPause() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        router.pause();
    }

    // ------------------------------------------------------------------
    // Liquidator
    // ------------------------------------------------------------------

    function test_Liquidator_Initial() public view {
        assertEq(router.liquidator(), liquidator, "initial liquidator");
    }

    function test_Liquidator_OwnerCanUpdate() public {
        address newLiq = makeAddr("newLiquidator");

        vm.expectEmit(false, false, false, true, address(router));
        emit LiquidatorUpdated(liquidator, newLiq);

        vm.prank(owner);
        router.setLiquidator(newLiq);
        assertEq(router.liquidator(), newLiq, "liquidator rotated");
    }

    function test_Liquidator_CannotSelfUpdate() public {
        // The liquidator role is strictly narrower than owner: it cannot rotate itself.
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, liquidator));
        router.setLiquidator(address(0xdead));
    }

    function test_Liquidator_CannotCallConfig() public {
        // Each of the four owner-only config surfaces must reject the liquidator. This proves
        // the role is sweep-only (FR-14): no governance capabilities whatsoever.
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, liquidator));
        router.setPendingExecutor(address(0xdead));

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, liquidator));
        router.setLiquidator(address(0xdead));

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, liquidator));
        router.pause();

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, liquidator));
        router.transferOwnership(liquidator);
    }

    // ------------------------------------------------------------------
    // Pause
    // ------------------------------------------------------------------

    function test_Pause_BlocksSwap() public {
        vm.prank(owner);
        router.pause();

        Router.SwapParams memory p = _mkUserSwapParams();

        tokenA.mint(user, SEED_INPUT);
        vm.prank(user);
        tokenA.approve(address(router), SEED_INPUT);

        vm.prank(user);
        vm.expectRevert(RouterErrors.Paused.selector);
        router.swap(p);
    }

    function test_Pause_BlocksSwapMulti() public {
        vm.prank(owner);
        router.pause();

        Router.MultiSwapParams memory mp = _mkMultiSwapParams();

        vm.prank(user);
        vm.expectRevert(RouterErrors.Paused.selector);
        router.swapMulti(mp);
    }

    function test_Pause_DoesNotBlockSweep() public {
        // Sweep functions are deliberately not gated by `whenNotPaused` (FR-13): pause is an
        // emergency swap halt, not a capital freeze. Owner must still be able to extract funds.
        vm.prank(owner);
        router.pause();

        address[] memory tokens = new address[](1);
        tokens[0] = address(tokenA);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SEED_DUST;

        uint256 destBefore = tokenA.balanceOf(dest);
        vm.prank(owner);
        router.transferRouterFunds(tokens, amounts, dest);
        assertEq(tokenA.balanceOf(dest) - destBefore, SEED_DUST, "sweep works while paused");
    }

    function test_Pause_Unpause_Restores() public {
        vm.prank(owner);
        router.pause();

        Router.SwapParams memory p = _mkUserSwapParams();

        tokenA.mint(user, SEED_INPUT);
        vm.prank(user);
        tokenA.approve(address(router), SEED_INPUT);

        // While paused: swap reverts.
        vm.prank(user);
        vm.expectRevert(RouterErrors.Paused.selector);
        router.swap(p);

        // After unpause: same params succeed.
        vm.prank(owner);
        router.unpause();

        vm.prank(user);
        uint256 amountOut = router.swap(p);
        assertEq(amountOut, SEED_OUTPUT, "swap restored after unpause");
    }

    function test_Pause_NonOwner_CannotPause() public {
        // Neither a random stranger nor the liquidator can pause.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        router.pause();

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, liquidator));
        router.pause();

        assertFalse(router.paused(), "router still unpaused");
    }

    // ------------------------------------------------------------------
    // Sweep: transferRouterFunds
    // ------------------------------------------------------------------

    function test_TransferRouterFunds_ByOwner() public {
        // Seed the Router with native ETH in addition to the ERC20 dust already present.
        vm.deal(address(router), 2 ether);

        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = NATIVE_ETH;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = SEED_DUST;
        amounts[1] = 1 ether;

        uint256 destTokenABefore = tokenA.balanceOf(dest);
        uint256 destETHBefore = dest.balance;

        vm.expectEmit(false, false, false, true, address(router));
        emit FundsTransferred(tokens, amounts, dest);

        vm.prank(owner);
        router.transferRouterFunds(tokens, amounts, dest);

        // Manual criterion: both deltas are strictly positive and exactly match the requested
        // per-entry amounts. Asserting strict `>` makes the native-ETH leg of the sweep
        // observable, not just the aggregate.
        assertGt(IERC20(address(tokenA)).balanceOf(dest) - destTokenABefore, 0, "dest ERC20 delta > 0");
        assertGt(dest.balance - destETHBefore, 0, "dest ETH delta > 0");
        assertEq(tokenA.balanceOf(dest) - destTokenABefore, SEED_DUST, "dest tokenA exact");
        assertEq(dest.balance - destETHBefore, 1 ether, "dest ETH exact");
    }

    function test_TransferRouterFunds_ByLiquidator() public {
        vm.deal(address(router), 2 ether);

        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = NATIVE_ETH;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = SEED_DUST;
        amounts[1] = 1 ether;

        uint256 destTokenABefore = tokenA.balanceOf(dest);
        uint256 destETHBefore = dest.balance;

        vm.prank(liquidator);
        router.transferRouterFunds(tokens, amounts, dest);

        assertEq(tokenA.balanceOf(dest) - destTokenABefore, SEED_DUST, "dest tokenA after liq sweep");
        assertEq(dest.balance - destETHBefore, 1 ether, "dest ETH after liq sweep");
    }

    function test_TransferRouterFunds_ByStranger_Reverts() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(tokenA);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SEED_DUST;

        vm.prank(stranger);
        vm.expectRevert(Router.Unauthorized.selector);
        router.transferRouterFunds(tokens, amounts, dest);
    }

    function test_TransferRouterFunds_ArrayLengthMismatch_Reverts() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = NATIVE_ETH;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SEED_DUST;

        vm.prank(owner);
        vm.expectRevert(Router.ArrayLengthMismatch.selector);
        router.transferRouterFunds(tokens, amounts, dest);
    }

    function test_TransferRouterFunds_ZeroDest_Reverts() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(tokenA);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SEED_DUST;

        vm.prank(owner);
        vm.expectRevert(Router.ZeroAddress.selector);
        router.transferRouterFunds(tokens, amounts, address(0));
    }

    function test_TransferRouterFunds_EmptyArrays_NoOp() public {
        address[] memory tokens = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        uint256 destTokenABefore = tokenA.balanceOf(dest);
        uint256 routerTokenABefore = tokenA.balanceOf(address(router));
        uint256 destETHBefore = dest.balance;
        uint256 routerETHBefore = address(router).balance;

        vm.prank(owner);
        router.transferRouterFunds(tokens, amounts, dest);

        assertEq(tokenA.balanceOf(dest), destTokenABefore, "dest ERC20 unchanged");
        assertEq(tokenA.balanceOf(address(router)), routerTokenABefore, "router ERC20 unchanged");
        assertEq(dest.balance, destETHBefore, "dest ETH unchanged");
        assertEq(address(router).balance, routerETHBefore, "router ETH unchanged");
    }

    // ------------------------------------------------------------------
    // Sweep: swapRouterFunds
    // ------------------------------------------------------------------

    function test_SwapRouterFunds_ByOwner() public {
        // Router already holds SEED_DUST of tokenA from setUp. Convert it to tokenB via the
        // executor: input is Router-held (no transferFrom, no msg.value), output lands at `dest`.
        uint256 swapIn = SEED_DUST;
        uint256 swapOut = 9e18;

        (bytes32[] memory commands, bytes[] memory state) = _buildA2BProgram(swapIn, swapOut);
        Router.SwapParams memory p = Router.SwapParams({
            inputToken: address(tokenA),
            inputAmount: swapIn,
            outputToken: address(tokenB),
            outputQuote: swapOut,
            outputMin: swapOut - 1,
            recipient: dest,
            protocolFeeBps: 0,
            partnerFeeBps: 0,
            partnerRecipient: address(0),
            partnerFeeOnOutput: false,
            passPositiveSlippageToUser: false,
            weirollCommands: commands,
            weirollState: state
        });

        uint256 destTokenBBefore = tokenB.balanceOf(dest);
        uint256 strangerTokenABefore = tokenA.balanceOf(stranger);

        vm.prank(owner);
        uint256 amountOut = router.swapRouterFunds(p);

        assertEq(amountOut, swapOut, "amountOut");
        assertEq(tokenB.balanceOf(dest) - destTokenBBefore, swapOut, "recipient paid");
        // Critical: the input came from the Router's own balance, not from any msg.sender funds.
        assertEq(tokenA.balanceOf(address(router)), 0, "router input dust consumed");
        assertEq(tokenA.balanceOf(stranger), strangerTokenABefore, "no funds pulled from third parties");
    }

    function test_SwapRouterFunds_ByStranger_Reverts() public {
        Router.SwapParams memory p = _mkUserSwapParams();

        vm.prank(stranger);
        vm.expectRevert(Router.Unauthorized.selector);
        router.swapRouterFunds(p);
    }
}
