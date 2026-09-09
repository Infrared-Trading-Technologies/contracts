// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, Vm } from "forge-std/Test.sol";
import { ExecutionProxy } from "../src/ExecutionProxy.sol";
import { Router } from "../src/Router.sol";
import { WeirollTestHelper } from "./helpers/WeirollTestHelper.sol";
import { MockDEX } from "./mocks/MockDEX.sol";

/// @title MockERC20
/// @notice Minimal ERC20 for testing. Duplicated from Router.t.sol to keep the Router.Fees
///         test file self-contained (task step 1 explicitly permits either duplicating setUp
///         or factoring into a shared helper).
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

/// @title RouterFeesTest
/// @notice Exercises FR-3/4/5/6/7 of the Router spec:
///         - Protocol fee on input with cap + arithmetic + Router custody.
///         - Partner fee on input (paid pre-executor) and on output (paid post-slippage-cap).
///         - Positive-slippage capture vs. pass-through and the interaction with partner fees.
///         - No silent short payment (fuzz).
contract RouterFeesTest is Test {
    ExecutionProxy public executor;
    Router public router;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockDEX public dex;

    address public user = makeAddr("user");
    address public receiver = makeAddr("receiver");
    address public alice = makeAddr("alice"); // partner recipient
    address public liquidator = makeAddr("liquidator");

    /// @dev Mirror of Router's `Swap` event for decoding in `vm.recordLogs` path.
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

    function setUp() public {
        executor = new ExecutionProxy();
        router = new Router(address(this), liquidator);
        router.setPendingExecutor(address(executor));
        router.acceptExecutor();

        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);
        dex = new MockDEX();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Build a Weiroll program identical in shape to Router.t.sol's `_buildA2BProgram`:
    ///      MockDEX pulls `amountIn` of tokenA from the executor, mints `amountOut` of tokenB
    ///      to the executor, and the program transfers that tokenB to the Router. `amountIn`
    ///      must equal the executor's actual received amount (post-fee forwardAmount); the
    ///      router-side balance delta is what the swap pipeline measures.
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

    /// @dev Default-filled SwapParams builder. All test-only fields are zero/false; callers
    ///      override the specific field under test. Keeps the intent of each test visible at
    ///      the call site per task step 1.
    /// @param inputAmount User-denominated input (what Router pulls from user / what goes on
    ///        `SwapParams.inputAmount`).
    /// @param dexAmountIn What the executor has to transfer to MockDEX during the program,
    ///        i.e. `inputAmount - protocolFee - inputPartnerFee`. Must equal the executor's
    ///        post-forward balance of tokenA.
    /// @param dexAmountOut What MockDEX mints to the executor (Router measures this as
    ///        `amountOut` via balance-diff).
    function _mkParams(uint256 inputAmount, uint256 dexAmountIn, uint256 dexAmountOut, uint256 quote, uint256 min)
        internal
        view
        returns (Router.SwapParams memory p)
    {
        (bytes32[] memory commands, bytes[] memory state) = _buildA2BProgram(dexAmountIn, dexAmountOut);
        p = Router.SwapParams({
            inputToken: address(tokenA),
            inputAmount: inputAmount,
            outputToken: address(tokenB),
            outputQuote: quote,
            outputMin: min,
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

    /// @dev Mint + approve the input token for a caller so the Router can pull it.
    function _fundUser(uint256 amount) internal {
        tokenA.mint(user, amount);
        vm.prank(user);
        tokenA.approve(address(router), amount);
    }

    // ==================================================================
    // Protocol fee (FR-3)
    // ==================================================================

    /// @notice 50 bps applied to 1000e18 input -> 5e18 retained in Router, 995e18 forwarded.
    function test_ProtocolFee_Charged() public {
        uint256 amountIn = 1000e18;
        uint256 forwardAmount = 995e18;
        uint256 producedOut = 900e18;
        _fundUser(amountIn);

        Router.SwapParams memory p = _mkParams(amountIn, forwardAmount, producedOut, 900e18, 800e18);
        p.protocolFeeBps = 50;

        vm.prank(user);
        router.swap(p);

        assertEq(tokenA.balanceOf(address(router)), 5e18, "router retains protocol fee");
        assertEq(tokenB.balanceOf(receiver), producedOut, "receiver gets full quote");
        assertEq(tokenA.balanceOf(address(executor)), 0, "executor consumed forward");
    }

    /// @notice Zero bps -> no fee, full amount forwarded and no fee retained.
    function test_ProtocolFee_ZeroBps() public {
        uint256 amountIn = 1000e18;
        uint256 producedOut = 900e18;
        _fundUser(amountIn);

        Router.SwapParams memory p = _mkParams(amountIn, amountIn, producedOut, 900e18, 800e18);
        p.protocolFeeBps = 0;

        vm.prank(user);
        router.swap(p);

        assertEq(tokenA.balanceOf(address(router)), 0, "no protocol fee retained");
        assertEq(tokenB.balanceOf(receiver), producedOut, "receiver paid in full");
    }

    /// @notice 201 bps exceeds MAX_PROTOCOL_FEE_BPS (200) -> reverts ProtocolFeeExceedsCap(201).
    function test_ProtocolFee_CapExceeds_Reverts() public {
        _fundUser(1000e18);
        Router.SwapParams memory p = _mkParams(1000e18, 1000e18, 900e18, 900e18, 800e18);
        p.protocolFeeBps = 201;

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Router.ProtocolFeeExceedsCap.selector, uint256(201)));
        router.swap(p);
    }

    /// @notice 200 bps (cap) succeeds and retains 2% in the Router.
    function test_ProtocolFee_AtCap() public {
        uint256 amountIn = 1000e18;
        uint256 forwardAmount = 980e18; // 1000 - 2%
        uint256 producedOut = 900e18;
        _fundUser(amountIn);

        Router.SwapParams memory p = _mkParams(amountIn, forwardAmount, producedOut, 900e18, 800e18);
        p.protocolFeeBps = 200;

        vm.prank(user);
        router.swap(p);

        assertEq(tokenA.balanceOf(address(router)), 20e18, "router retains 2% at cap");
        assertEq(tokenB.balanceOf(receiver), producedOut, "receiver paid in full");
    }

    /// @notice Two consecutive swaps at 50 bps accumulate fees additively in Router.
    function test_ProtocolFee_AccumulatesInRouter() public {
        uint256 amountIn = 1000e18;
        uint256 forwardAmount = 995e18;
        uint256 producedOut = 900e18;

        // Swap 1.
        _fundUser(amountIn);
        Router.SwapParams memory p1 = _mkParams(amountIn, forwardAmount, producedOut, 900e18, 800e18);
        p1.protocolFeeBps = 50;
        vm.prank(user);
        router.swap(p1);
        assertEq(tokenA.balanceOf(address(router)), 5e18, "fee after swap 1");

        // Swap 2.
        _fundUser(amountIn);
        Router.SwapParams memory p2 = _mkParams(amountIn, forwardAmount, producedOut, 900e18, 800e18);
        p2.protocolFeeBps = 50;
        vm.prank(user);
        router.swap(p2);
        assertEq(tokenA.balanceOf(address(router)), 10e18, "fees accumulate");
    }

    /// @notice Zero-fee edge case (spec edge-case table row 3): fee fields of the `Swap` event
    ///         must all be zero when both bps are zero and produced == outputQuote.
    function test_NoFees_EmitsZeroFeeFields() public {
        uint256 amountIn = 1000e18;
        uint256 producedOut = 900e18;
        _fundUser(amountIn);

        Router.SwapParams memory p = _mkParams(amountIn, amountIn, producedOut, producedOut, 800e18);

        vm.recordLogs();
        vm.prank(user);
        router.swap(p);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sigSwap =
            keccak256("Swap(address,address,uint256,address,uint256,uint256,uint256,uint256,uint256,address)");
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(router) || logs[i].topics[0] != sigSwap) continue;
            (
                , // inputToken
                , // inputAmount
                , // outputToken
                , // amountOut
                , // amountToUser
                uint256 protocolFee,
                uint256 partnerFee,
                uint256 positiveSlippageCaptured,
                address partnerRecipient
            ) = abi.decode(
                logs[i].data, (address, uint256, address, uint256, uint256, uint256, uint256, uint256, address)
            );
            assertEq(protocolFee, 0, "protocolFee");
            assertEq(partnerFee, 0, "partnerFee");
            assertEq(positiveSlippageCaptured, 0, "positiveSlippage");
            assertEq(partnerRecipient, address(0), "partnerRecipient");
            found = true;
            break;
        }
        assertTrue(found, "Swap event emitted");
    }

    // ==================================================================
    // Partner fee -- input denominated (FR-4)
    // ==================================================================

    /// @notice 100 bps on input, no protocol fee -> partner gets 10e18, executor gets 990e18.
    function test_PartnerFeeInput_Paid() public {
        uint256 amountIn = 1000e18;
        uint256 forwardAmount = 990e18;
        uint256 producedOut = 900e18;
        _fundUser(amountIn);

        Router.SwapParams memory p = _mkParams(amountIn, forwardAmount, producedOut, 900e18, 800e18);
        p.partnerFeeBps = 100;
        p.partnerRecipient = alice;
        p.partnerFeeOnOutput = false;

        vm.prank(user);
        router.swap(p);

        assertEq(tokenA.balanceOf(alice), 10e18, "partner receives input fee");
        assertEq(tokenA.balanceOf(address(router)), 0, "no protocol fee retained");
        assertEq(tokenB.balanceOf(receiver), producedOut, "receiver paid full");
    }

    /// @notice 201 bps partner fee on input -> reverts PartnerFeeExceedsCap(201).
    function test_PartnerFeeInput_CapExceeds_Reverts() public {
        _fundUser(1000e18);
        Router.SwapParams memory p = _mkParams(1000e18, 1000e18, 900e18, 900e18, 800e18);
        p.partnerFeeBps = 201;
        p.partnerRecipient = alice;

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Router.PartnerFeeExceedsCap.selector, uint256(201)));
        router.swap(p);
    }

    /// @notice partnerFeeBps > 0 with zero recipient reverts InvalidPartnerRecipient.
    function test_PartnerFeeInput_ZeroRecipient_Reverts() public {
        _fundUser(1000e18);
        Router.SwapParams memory p = _mkParams(1000e18, 1000e18, 900e18, 900e18, 800e18);
        p.partnerFeeBps = 100;
        p.partnerRecipient = address(0);

        vm.prank(user);
        vm.expectRevert(Router.InvalidPartnerRecipient.selector);
        router.swap(p);
    }

    /// @notice Protocol (50 bps) + partner input (100 bps) stack on input. Executor gets
    ///         pulled - protocolFee - partnerFee; router retains protocolFee only; partner
    ///         receives partnerFee on the input token.
    function test_PartnerFeeInput_StacksWithProtocolFee() public {
        uint256 amountIn = 1000e18;
        uint256 expectedProtocolFee = 5e18; // 50 bps
        uint256 expectedPartnerFee = 10e18; // 100 bps
        uint256 forwardAmount = amountIn - expectedProtocolFee - expectedPartnerFee; // 985e18
        uint256 producedOut = 900e18;
        _fundUser(amountIn);

        Router.SwapParams memory p = _mkParams(amountIn, forwardAmount, producedOut, 900e18, 800e18);
        p.protocolFeeBps = 50;
        p.partnerFeeBps = 100;
        p.partnerRecipient = alice;
        p.partnerFeeOnOutput = false;

        vm.prank(user);
        router.swap(p);

        assertEq(tokenA.balanceOf(address(router)), expectedProtocolFee, "router holds protocol fee only");
        assertEq(tokenA.balanceOf(alice), expectedPartnerFee, "partner holds partner fee");
        assertEq(tokenA.balanceOf(address(executor)), 0, "executor consumed forward");
        assertEq(tokenB.balanceOf(receiver), producedOut, "receiver paid full quote");
    }

    // ==================================================================
    // Partner fee -- output denominated (FR-5)
    // ==================================================================

    /// @notice produced=1000e18, outputQuote=1000e18, partnerFeeBps=100 on output
    ///         -> partner gets 10e18 tokenB, user gets 990e18 tokenB.
    function test_PartnerFeeOutput_Paid() public {
        uint256 amountIn = 1000e18;
        uint256 producedOut = 1000e18;
        _fundUser(amountIn);

        Router.SwapParams memory p = _mkParams(amountIn, amountIn, producedOut, 1000e18, 900e18);
        p.partnerFeeBps = 100;
        p.partnerRecipient = alice;
        p.partnerFeeOnOutput = true;

        vm.prank(user);
        uint256 returned = router.swap(p);

        assertEq(returned, 990e18, "return = user amount");
        assertEq(tokenB.balanceOf(alice), 10e18, "partner output fee");
        assertEq(tokenB.balanceOf(receiver), 990e18, "user output");
        assertEq(tokenA.balanceOf(alice), 0, "no input-token fee paid to partner");
    }

    /// @notice Executor produces 1100, quote is 1000. Slippage cap applies first (router keeps
    ///         100), then 100 bps output partner fee is deducted from the capped 1000 -> partner
    ///         10, user 990. Router ends with 100 of output token retained.
    function test_PartnerFeeOutput_AfterSlippageCap() public {
        uint256 amountIn = 1000e18;
        uint256 producedOut = 1100e18;
        _fundUser(amountIn);

        Router.SwapParams memory p = _mkParams(amountIn, amountIn, producedOut, 1000e18, 900e18);
        p.partnerFeeBps = 100;
        p.partnerRecipient = alice;
        p.partnerFeeOnOutput = true;
        p.passPositiveSlippageToUser = false;

        vm.prank(user);
        uint256 returned = router.swap(p);

        assertEq(returned, 990e18, "user amount post partner + cap");
        assertEq(tokenB.balanceOf(alice), 10e18, "partner fee computed on post-cap amount");
        assertEq(tokenB.balanceOf(receiver), 990e18, "receiver");
        assertEq(tokenB.balanceOf(address(router)), 100e18, "router retains capped surplus only");
    }

    /// @notice Nethermind NM-1048 [Low]: with positive-slippage capture on, the most the user
    ///         can be credited is `outputQuote - fee(outputQuote)`. An `outputMin` above that
    ///         used to pass validation and then revert `SlippageExceeded` after the swap had run
    ///         (this exact case: quote 1000e18, 100 bps output fee, min 995e18 > 990e18). It must
    ///         now be rejected up front, before any input is pulled.
    function test_PartnerFeeOutput_UnreachableOutputMin_RevertsAtValidation() public {
        uint256 amountIn = 1000e18;
        _fundUser(amountIn);

        Router.SwapParams memory p = _mkParams(amountIn, amountIn, 1000e18, 1000e18, 995e18);
        p.partnerFeeBps = 100;
        p.partnerRecipient = alice;
        p.partnerFeeOnOutput = true;
        p.passPositiveSlippageToUser = false;

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Router.OutputMinUnreachable.selector, uint256(995e18), uint256(990e18)));
        router.swap(p);
        assertEq(tokenA.balanceOf(user), amountIn, "nothing pulled: rejected before execution");
    }

    /// @notice The ceiling itself is reachable: min == quote - fee(quote) settles with the user
    ///         credited exactly that amount.
    function test_PartnerFeeOutput_OutputMinAtMaxReachable_Succeeds() public {
        uint256 amountIn = 1000e18;
        _fundUser(amountIn);

        Router.SwapParams memory p = _mkParams(amountIn, amountIn, 1000e18, 1000e18, 990e18);
        p.partnerFeeBps = 100;
        p.partnerRecipient = alice;
        p.partnerFeeOnOutput = true;

        vm.prank(user);
        uint256 returned = router.swap(p);

        assertEq(returned, 990e18, "user credited exactly the ceiling");
        assertEq(tokenB.balanceOf(receiver), 990e18, "receiver");
        assertEq(tokenB.balanceOf(alice), 10e18, "partner fee");
    }

    /// @notice A reachable outputMin that the realized output still misses after the output
    ///         fee keeps failing at settlement with the exact net amount, as before.
    function test_PartnerFeeOutput_ShortSwap_StillSlippageExceeded() public {
        uint256 amountIn = 1000e18;
        _fundUser(amountIn);

        // min 985e18 <= ceiling 990e18, but produced 990e18 nets to 980.1e18.
        Router.SwapParams memory p = _mkParams(amountIn, amountIn, 990e18, 1000e18, 985e18);
        p.partnerFeeBps = 100;
        p.partnerRecipient = alice;
        p.partnerFeeOnOutput = true;

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                Router.SlippageExceeded.selector, address(tokenB), uint256(980.1e18), uint256(985e18)
            )
        );
        router.swap(p);
    }

    /// @notice With pass-through on there is no cap, so an outputMin up to outputQuote stays
    ///         reachable and validation must keep accepting it.
    function test_PartnerFeeOutput_PassThrough_OutputMinUpToQuoteAccepted() public {
        uint256 amountIn = 1000e18;
        _fundUser(amountIn);

        Router.SwapParams memory p = _mkParams(amountIn, amountIn, 1100e18, 1000e18, 995e18);
        p.partnerFeeBps = 100;
        p.partnerRecipient = alice;
        p.partnerFeeOnOutput = true;
        p.passPositiveSlippageToUser = true;

        vm.prank(user);
        uint256 returned = router.swap(p);

        assertEq(returned, 1089e18, "1100 less 1% output fee, no cap");
        assertEq(tokenB.balanceOf(alice), 11e18, "partner fee on the uncapped amount");
    }

    // ==================================================================
    // Positive slippage (FR-6)
    // ==================================================================

    /// @notice Flag off: user receives outputQuote; router retains surplus exactly.
    function test_PositiveSlippage_CapturedWhenFlagOff() public {
        uint256 amountIn = 1000e18;
        uint256 producedOut = 1100e18;
        uint256 quote = 1000e18;
        _fundUser(amountIn);

        Router.SwapParams memory p = _mkParams(amountIn, amountIn, producedOut, quote, 900e18);
        p.passPositiveSlippageToUser = false;

        uint256 receiverBefore = tokenB.balanceOf(receiver);
        uint256 routerBefore = tokenB.balanceOf(address(router));

        vm.prank(user);
        uint256 returned = router.swap(p);

        // Assert BOTH user and router balances per the [manual] acceptance criterion.
        assertEq(returned, quote, "return capped at quote");
        assertEq(tokenB.balanceOf(receiver) - receiverBefore, quote, "user receives exactly quote");
        assertEq(tokenB.balanceOf(address(router)) - routerBefore, 100e18, "router retains surplus");
    }

    /// @notice Flag on: user receives the full produced amount; router retains nothing.
    function test_PositiveSlippage_PassThroughWhenFlagOn() public {
        uint256 amountIn = 1000e18;
        uint256 producedOut = 1100e18;
        uint256 quote = 1000e18;
        _fundUser(amountIn);

        Router.SwapParams memory p = _mkParams(amountIn, amountIn, producedOut, quote, 900e18);
        p.passPositiveSlippageToUser = true;

        uint256 receiverBefore = tokenB.balanceOf(receiver);
        uint256 routerBefore = tokenB.balanceOf(address(router));

        vm.prank(user);
        uint256 returned = router.swap(p);

        assertEq(returned, producedOut, "return is full produced");
        assertEq(tokenB.balanceOf(receiver) - receiverBefore, producedOut, "user gets full");
        assertEq(tokenB.balanceOf(address(router)) - routerBefore, 0, "router retains nothing");
    }

    /// @notice amountOut < outputQuote -> no surplus, no retention, user gets full amountOut.
    function test_PositiveSlippage_NoSurplus_Noop() public {
        uint256 amountIn = 1000e18;
        uint256 producedOut = 900e18;
        uint256 quote = 1000e18;
        _fundUser(amountIn);

        Router.SwapParams memory p = _mkParams(amountIn, amountIn, producedOut, quote, 800e18);

        uint256 receiverBefore = tokenB.balanceOf(receiver);
        uint256 routerBefore = tokenB.balanceOf(address(router));

        vm.prank(user);
        uint256 returned = router.swap(p);

        assertEq(returned, producedOut, "return = produced");
        assertEq(tokenB.balanceOf(receiver) - receiverBefore, producedOut, "user receives produced");
        assertEq(tokenB.balanceOf(address(router)) - routerBefore, 0, "nothing retained");
    }

    /// @notice amountOut == outputQuote: neither capped nor forfeited regardless of flag.
    function test_PositiveSlippage_AtOutputQuoteExactly_NeitherRetainedNorForfeited() public {
        uint256 amountIn = 1000e18;
        uint256 producedOut = 1000e18;
        uint256 quote = 1000e18;

        // Flag off
        _fundUser(amountIn);
        Router.SwapParams memory p1 = _mkParams(amountIn, amountIn, producedOut, quote, 900e18);
        p1.passPositiveSlippageToUser = false;
        uint256 recvBefore1 = tokenB.balanceOf(receiver);
        uint256 routerBefore1 = tokenB.balanceOf(address(router));
        vm.prank(user);
        uint256 ret1 = router.swap(p1);
        assertEq(ret1, producedOut, "return flag-off");
        assertEq(tokenB.balanceOf(receiver) - recvBefore1, producedOut, "user flag-off");
        assertEq(tokenB.balanceOf(address(router)) - routerBefore1, 0, "router flag-off");

        // Flag on
        _fundUser(amountIn);
        Router.SwapParams memory p2 = _mkParams(amountIn, amountIn, producedOut, quote, 900e18);
        p2.passPositiveSlippageToUser = true;
        uint256 recvBefore2 = tokenB.balanceOf(receiver);
        uint256 routerBefore2 = tokenB.balanceOf(address(router));
        vm.prank(user);
        uint256 ret2 = router.swap(p2);
        assertEq(ret2, producedOut, "return flag-on");
        assertEq(tokenB.balanceOf(receiver) - recvBefore2, producedOut, "user flag-on");
        assertEq(tokenB.balanceOf(address(router)) - routerBefore2, 0, "router flag-on");
    }

    // ==================================================================
    // Fuzz (FR-7)
    // ==================================================================

    /// @notice No silent short payment: regardless of produced amount, quote, min, and bps
    ///         settings, if the tx succeeds the user receives >= minOut; if it fails it fails
    ///         with SlippageExceeded computed on the exact final user amount. A minOut above the
    ///         reachable ceiling (quote less the output-side fee, capture on) is rejected up
    ///         front with OutputMinUnreachable instead of failing after execution.
    function testFuzz_NoSilentShortPayment(
        uint256 produced,
        uint256 quote,
        uint256 minOut,
        uint16 protoBps,
        uint16 partnerBps,
        bool onOutput
    ) public {
        // Bound inputs per task step 5.
        produced = bound(produced, 1, 1e30);
        quote = bound(quote, 1, 1e30);
        minOut = bound(minOut, 1, quote);
        protoBps = uint16(bound(protoBps, 0, 200));
        partnerBps = uint16(bound(partnerBps, 0, 200));

        _runNoSilentShortPayment(produced, quote, minOut, protoBps, partnerBps, onOutput);
    }

    /// @dev Extracted to keep the fuzz body under the EVM stack limit.
    function _runNoSilentShortPayment(
        uint256 produced,
        uint256 quote,
        uint256 minOut,
        uint16 protoBps,
        uint16 partnerBps,
        bool onOutput
    ) internal {
        uint256 amountIn = 1000e18;
        uint256 forwardAmount =
            amountIn - (amountIn * protoBps) / 10_000 - (onOutput ? 0 : (amountIn * partnerBps) / 10_000);

        uint256 capped = produced > quote ? quote : produced;
        uint256 expectedToUser = capped - (onOutput ? (capped * partnerBps) / 10_000 : 0);
        uint256 maxReachable = quote - (onOutput ? (quote * partnerBps) / 10_000 : 0);

        _fundUser(amountIn);

        Router.SwapParams memory p = _mkParams(amountIn, forwardAmount, produced, quote, minOut);
        p.protocolFeeBps = protoBps;
        p.partnerFeeBps = partnerBps;
        p.partnerRecipient = partnerBps > 0 ? alice : address(0);
        p.partnerFeeOnOutput = onOutput;

        if (minOut > maxReachable) {
            vm.prank(user);
            vm.expectRevert(abi.encodeWithSelector(Router.OutputMinUnreachable.selector, minOut, maxReachable));
            router.swap(p);
        } else if (expectedToUser < minOut) {
            vm.prank(user);
            vm.expectRevert(
                abi.encodeWithSelector(Router.SlippageExceeded.selector, address(tokenB), expectedToUser, minOut)
            );
            router.swap(p);
        } else {
            uint256 receiverBefore = tokenB.balanceOf(receiver);
            vm.prank(user);
            uint256 returned = router.swap(p);
            assertEq(returned, expectedToUser, "return matches expected");
            assertGe(tokenB.balanceOf(receiver) - receiverBefore, minOut, "user >= minOut");
            assertEq(tokenB.balanceOf(receiver) - receiverBefore, expectedToUser, "user == expected");
        }
    }
}
