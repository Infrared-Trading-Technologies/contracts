// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ExecutionProxy } from "../src/ExecutionProxy.sol";
import { WeirollTestHelper } from "./helpers/WeirollTestHelper.sol";
import { MockDEX } from "./mocks/MockDEX.sol";
import { ReceiveOnlyTarget } from "./mocks/ReceiveOnlyTarget.sol";

/// @title MockERC20
/// @notice Minimal ERC20 for testing
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

/// @title MockSevenArg
/// @notice Minimal target with a 7-argument function. Exercises the Weiroll VM's
///         extended-command path (>6 args).
contract MockSevenArg {
    uint256[7] public values;

    function record(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e, uint256 f, uint256 g) external {
        values[0] = a;
        values[1] = b;
        values[2] = c;
        values[3] = d;
        values[4] = e;
        values[5] = f;
        values[6] = g;
    }
}

/// @title MockWETH
/// @notice Minimal WETH for testing
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

/// @title PayloadEchoTarget
/// @notice Captures the raw calldata it receives. Used by the FLAG_DATA suite to prove
///         that the dispatcher forwards arbitrary bytes verbatim. fallback() fires for
///         any payload whose first 4 bytes do not match a defined selector (which is
///         the case for our synthetic FLAG_DATA payloads).
contract PayloadEchoTarget {
    bytes public lastPayload;
    uint256 public callCount;
    uint256 public totalReceived;

    fallback() external payable {
        lastPayload = msg.data;
        unchecked {
            callCount += 1;
            totalReceived += msg.value;
        }
    }

    receive() external payable {
        lastPayload = "";
        unchecked {
            callCount += 1;
            totalReceived += msg.value;
        }
    }
}

/// @title ExecutionProxyTest
/// @notice Tests the pure-VM `ExecutionProxy.executePath` entry point. Router-specific
///         concerns (fees, slippage, balance-diff accounting, adversarial-token handling,
///         reentrancy) are covered in Router test suites -- this file only proves the
///         Weiroll VM still runs programs end-to-end.
contract ExecutionProxyTest is Test {
    ExecutionProxy public proxy;
    MockWETH public weth;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;
    MockDEX public dex;

    address public user = makeAddr("user");
    address public recipient = makeAddr("recipient");

    address public constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function setUp() public {
        weth = new MockWETH();
        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);
        tokenC = new MockERC20("Token C", "TKNC", 6);
        dex = new MockDEX();

        proxy = new ExecutionProxy();

        vm.deal(user, 100 ether);
    }

    // ============================================================
    // Deployment
    // ============================================================

    function test_Deploy() public view {
        // Pure-VM executor: no owner, no fee state, no storage.
        assertEq(address(proxy).code.length > 0, true);
    }

    // ============================================================
    // executePath: Weiroll execution mechanics
    // ============================================================

    /// @notice Weiroll program mints ERC20 directly to an arbitrary recipient.
    function test_ExecutePath_MintsTokensToRecipient() public {
        uint256 amount = 1000e18;

        bytes[] memory state = WeirollTestHelper.createState2(
            WeirollTestHelper.encodeAddress(recipient), WeirollTestHelper.encodeUint256(amount)
        );
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildMintCommand(address(tokenA), 0, 1);

        proxy.executePath(commands, state);

        assertEq(tokenA.balanceOf(recipient), amount);
        assertEq(tokenA.balanceOf(address(proxy)), 0);
    }

    /// @notice Weiroll program mints to proxy, approves a spender, then transfers out.
    function test_ExecutePath_WithApproveAndTransfer() public {
        uint256 mintAmount = 2000e18;
        uint256 transferAmount = 1000e18;

        bytes[] memory state = new bytes[](4);
        state[0] = WeirollTestHelper.encodeAddress(address(proxy));
        state[1] = WeirollTestHelper.encodeUint256(mintAmount);
        state[2] = WeirollTestHelper.encodeAddress(recipient);
        state[3] = WeirollTestHelper.encodeUint256(transferAmount);

        bytes32[] memory commands = new bytes32[](3);
        commands[0] = WeirollTestHelper.buildMintCommand(address(tokenA), 0, 1);
        commands[1] = WeirollTestHelper.buildApproveCommand(address(tokenA), 2, 3);
        commands[2] = WeirollTestHelper.buildTransferCommand(address(tokenA), 2, 3);

        proxy.executePath(commands, state);

        assertEq(tokenA.balanceOf(recipient), transferAmount);
        assertEq(tokenA.balanceOf(address(proxy)), mintAmount - transferAmount);
        assertEq(tokenA.allowance(address(proxy), recipient), transferAmount);
    }

    /// @notice Realistic Weiroll program: mint input, approve MockDEX, swap to output.
    ///         Proves the VM still executes an end-to-end DEX interaction.
    function test_ExecutePath_WithMockDEXSwap() public {
        uint256 amountIn = 1000e18;
        uint256 amountOut = 500e18;

        // Mint input tokens to proxy via Weiroll (step 1), then approve DEX (step 2) and swap (step 3).
        bytes[] memory state = new bytes[](6);
        state[0] = WeirollTestHelper.encodeAddress(address(proxy));
        state[1] = WeirollTestHelper.encodeUint256(amountIn);
        state[2] = WeirollTestHelper.encodeAddress(address(dex));
        state[3] = WeirollTestHelper.encodeAddress(address(tokenA));
        state[4] = WeirollTestHelper.encodeAddress(address(tokenB));
        state[5] = WeirollTestHelper.encodeUint256(amountOut);

        bytes32[] memory commands = new bytes32[](3);
        commands[0] = WeirollTestHelper.buildMintCommand(address(tokenA), 0, 1);
        commands[1] = WeirollTestHelper.buildApproveCommand(address(tokenA), 2, 1);
        commands[2] = WeirollTestHelper.buildCallFourArgs(
            address(dex), bytes4(keccak256("swap(address,address,uint256,uint256)")), 3, 4, 1, 5
        );

        proxy.executePath(commands, state);

        // Swap called by proxy (msg.sender in MockDEX.swap), so tokenB is minted to proxy.
        assertEq(tokenB.balanceOf(address(proxy)), amountOut);
        assertEq(tokenA.balanceOf(address(dex)), amountIn);
    }

    /// @notice Weiroll wraps native ETH (forwarded via msg.value) into WETH on the proxy.
    function test_ExecutePath_WithWETHWrap() public {
        uint256 amount = 1 ether;

        bytes[] memory state = WeirollTestHelper.createState1(WeirollTestHelper.encodeUint256(amount));
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildWethDepositCommand(address(weth), 0);

        proxy.executePath{ value: amount }(commands, state);

        assertEq(weth.balanceOf(address(proxy)), amount);
        assertEq(address(proxy).balance, 0);
    }

    /// @notice Weiroll unwraps WETH held by the proxy back into native ETH.
    function test_ExecutePath_WithWETHUnwrap() public {
        uint256 amount = 1 ether;

        vm.deal(address(proxy), amount);
        vm.prank(address(proxy));
        weth.deposit{ value: amount }();

        bytes[] memory state = WeirollTestHelper.createState1(WeirollTestHelper.encodeUint256(amount));
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildWethWithdrawCommand(address(weth), 0);

        proxy.executePath(commands, state);

        assertEq(address(proxy).balance, amount);
        assertEq(weth.balanceOf(address(proxy)), 0);
    }

    /// @notice Multi-hop A -> B -> C via MockDEX encoded as a single Weiroll program.
    function test_ExecutePath_MultiHopSwap() public {
        uint256 amountA = 1000e18;
        uint256 amountB = 500e18;
        uint256 amountC = 250e6;

        tokenA.mint(address(proxy), amountA);

        bytes[] memory state = new bytes[](7);
        state[0] = WeirollTestHelper.encodeAddress(address(dex));
        state[1] = WeirollTestHelper.encodeUint256(amountA);
        state[2] = WeirollTestHelper.encodeAddress(address(tokenA));
        state[3] = WeirollTestHelper.encodeAddress(address(tokenB));
        state[4] = WeirollTestHelper.encodeUint256(amountB);
        state[5] = WeirollTestHelper.encodeAddress(address(tokenC));
        state[6] = WeirollTestHelper.encodeUint256(amountC);

        bytes4 swapSelector = bytes4(keccak256("swap(address,address,uint256,uint256)"));

        bytes32[] memory commands = new bytes32[](4);
        commands[0] = WeirollTestHelper.buildApproveCommand(address(tokenA), 0, 1);
        commands[1] = WeirollTestHelper.buildCallFourArgs(address(dex), swapSelector, 2, 3, 1, 4);
        commands[2] = WeirollTestHelper.buildApproveCommand(address(tokenB), 0, 4);
        commands[3] = WeirollTestHelper.buildCallFourArgs(address(dex), swapSelector, 3, 5, 4, 6);

        proxy.executePath(commands, state);

        assertEq(tokenC.balanceOf(address(proxy)), amountC);
        assertEq(tokenA.balanceOf(address(dex)), amountA);
        assertEq(tokenB.balanceOf(address(dex)), amountB);
    }

    /// @notice Fuzz: mint any amount to any recipient via Weiroll and check balance.
    function testFuzz_ExecutePath_MintToRecipient(uint256 amount, address fuzzRecipient) public {
        amount = bound(amount, 1, type(uint128).max);
        vm.assume(fuzzRecipient != address(0));

        bytes[] memory state = WeirollTestHelper.createState2(
            WeirollTestHelper.encodeAddress(fuzzRecipient), WeirollTestHelper.encodeUint256(amount)
        );
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildMintCommand(address(tokenA), 0, 1);

        uint256 balBefore = tokenA.balanceOf(fuzzRecipient);

        proxy.executePath(commands, state);

        assertEq(tokenA.balanceOf(fuzzRecipient), balBefore + amount);
    }

    // ============================================================
    // Extended commands (>6 args) and dispatcher contract
    // ============================================================

    /// @notice Calls a 7-argument function via the extended-command path. The pre-
    ///         remediation VM panicked here with `Panic(0x32)` because the decoder
    ///         used a post-increment that re-read Word 1 instead of Word 2.
    function test_ExecutePath_SevenArgs_Succeeds() public {
        MockSevenArg target = new MockSevenArg();

        bytes[] memory state = new bytes[](7);
        for (uint256 i = 0; i < 7; i++) {
            state[i] = abi.encode((i + 1) * 100);
        }

        uint8[] memory argSlots = new uint8[](7);
        for (uint8 i = 0; i < 7; i++) {
            argSlots[i] = i;
        }

        bytes4 selector = bytes4(keccak256("record(uint256,uint256,uint256,uint256,uint256,uint256,uint256)"));
        (bytes32 word1, bytes32 word2) = WeirollTestHelper.encodeExtendedCommand(
            selector, WeirollTestHelper.FLAG_CT_CALL, argSlots, WeirollTestHelper.IDX_END_OF_ARGS, address(target)
        );
        bytes32[] memory commands = new bytes32[](2);
        commands[0] = word1;
        commands[1] = word2;

        proxy.executePath(commands, state);

        for (uint256 i = 0; i < 7; i++) {
            assertEq(target.values(i), (i + 1) * 100);
        }
    }

    /// @notice Same extended-command path as above, but the outer tx carries
    ///         msg.value. Proves the decoder is unaffected by parent call value
    ///         and msg.value does not leak into the inner CALL (target is nonpayable).
    function test_ExecutePath_SevenArgs_WithOuterValue() public {
        MockSevenArg target = new MockSevenArg();

        bytes[] memory state = new bytes[](7);
        for (uint256 i = 0; i < 7; i++) {
            state[i] = abi.encode((i + 1) * 100);
        }

        uint8[] memory argSlots = new uint8[](7);
        for (uint8 i = 0; i < 7; i++) {
            argSlots[i] = i;
        }

        bytes4 selector = bytes4(keccak256("record(uint256,uint256,uint256,uint256,uint256,uint256,uint256)"));
        (bytes32 word1, bytes32 word2) = WeirollTestHelper.encodeExtendedCommand(
            selector, WeirollTestHelper.FLAG_CT_CALL, argSlots, WeirollTestHelper.IDX_END_OF_ARGS, address(target)
        );
        bytes32[] memory commands = new bytes32[](2);
        commands[0] = word1;
        commands[1] = word2;

        proxy.executePath{ value: 1 ether }(commands, state);

        for (uint256 i = 0; i < 7; i++) {
            assertEq(target.values(i), (i + 1) * 100);
        }
        assertEq(address(proxy).balance, 1 ether);
    }

    /// @notice The VM dispatcher has no DELEGATECALL branch. Any command emitting
    ///         FLAG_CT_DELEGATECALL (0x00) falls through to `revert("Invalid calltype")`.
    function test_ExecutePath_DelegateCall_Reverts() public {
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.encodeCommand(
            bytes4(0xdeadbeef),
            WeirollTestHelper.FLAG_CT_DELEGATECALL,
            WeirollTestHelper.indices0(),
            WeirollTestHelper.IDX_END_OF_ARGS,
            address(tokenA)
        );
        bytes[] memory state = new bytes[](0);

        vm.expectRevert(abi.encodeWithSignature("Error(string)", "Invalid calltype"));
        proxy.executePath(commands, state);
    }

    // ============================================================
    // FLAG_DATA: raw-calldata VALUECALL
    // ============================================================

    /// @notice Empty bytes in the calldata slot -> zero-byte call -> invokes receive().
    ///         This is the path that unblocks helpers like descry's SendNativeEth, which
    ///         needs to forward ETH to targets that have receive() but no payable
    ///         fallback().
    function test_FlagData_EmptyCalldata_TriggersReceive() public {
        ReceiveOnlyTarget target = new ReceiveOnlyTarget();
        uint256 value = 0.1 ether;

        bytes[] memory state = WeirollTestHelper.createState2(WeirollTestHelper.encodeUint256(value), bytes(""));
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildValueCallWithRawData(address(target), 0, 1);

        proxy.executePath{ value: value }(commands, state);

        assertEq(target.calls(), 1);
        assertEq(target.totalReceived(), value);
        assertEq(address(target).balance, value);
    }

    /// @notice Non-empty calldata slot passes through to the target verbatim. The
    ///         dispatcher does not prepend a selector, splice in args, or otherwise
    ///         transform the bytes.
    function test_FlagData_ArbitraryCalldata_PassesVerbatim() public {
        PayloadEchoTarget target = new PayloadEchoTarget();
        bytes memory payload = hex"deadbeefcafebabe";

        bytes[] memory state = WeirollTestHelper.createState2(WeirollTestHelper.encodeUint256(0), payload);
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildValueCallWithRawData(address(target), 0, 1);

        proxy.executePath(commands, state);

        assertEq(target.callCount(), 1);
        assertEq(target.totalReceived(), 0);
        assertEq(target.lastPayload(), payload);
    }

    /// @notice Zero ETH value with empty calldata is a valid combination: receive()
    ///         runs with msg.value == 0. Useful as a "no-op ping" or as a building
    ///         block where the value happens to be zero at runtime.
    function test_FlagData_ZeroValue_Succeeds() public {
        ReceiveOnlyTarget target = new ReceiveOnlyTarget();
        uint256 balanceBefore = address(target).balance;

        bytes[] memory state = WeirollTestHelper.createState2(WeirollTestHelper.encodeUint256(0), bytes(""));
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildValueCallWithRawData(address(target), 0, 1);

        proxy.executePath(commands, state);

        assertEq(target.calls(), 1);
        assertEq(target.totalReceived(), 0);
        assertEq(address(target).balance, balanceBefore);
    }

    /// @notice Prove that a VALUECALL's value can be sourced from a state slot written
    ///         by a prior command's return -- not just a pre-allocated literal slot.
    ///         This is the on-chain prerequisite for descry's SendNativeEth.Amount
    ///         accepting a ref.Uint256 sourced from helpers.EthBalance (or any
    ///         uint256-returning producer): command[0] STATICCALL writes the balance
    ///         into state[2]; command[1] VALUECALL+FLAG_DATA reads state[2] as the
    ///         value, sending exactly that amount to a receive()-only target.
    function test_FlagData_ValueFromPriorCommandReturn() public {
        uint256 amount = 0.42 ether;
        tokenA.mint(address(proxy), amount); // balanceOf(proxy) will return `amount`

        ReceiveOnlyTarget target = new ReceiveOnlyTarget();

        // state[0] = address(proxy)  -- arg to balanceOf
        // state[1] = empty bytes     -- FLAG_DATA empty calldata
        // state[2] = placeholder     -- will be overwritten by command[0]'s return
        bytes[] memory state = WeirollTestHelper.createState3(
            WeirollTestHelper.encodeAddress(address(proxy)), bytes(""), bytes("")
        );

        // commands[0]: STATICCALL tokenA.balanceOf(state[0]) -> state[2]
        // commands[1]: VALUECALL+FLAG_DATA target, value=state[2], data=state[1]
        bytes32[] memory commands = new bytes32[](2);
        commands[0] =
            WeirollTestHelper.buildStaticCallOneArg(address(tokenA), bytes4(0x70a08231), 0, 2);
        commands[1] = WeirollTestHelper.buildValueCallWithRawData(address(target), 2, 1);

        proxy.executePath{ value: amount }(commands, state);

        assertEq(target.calls(), 1);
        assertEq(target.totalReceived(), amount, "value must equal prior command's return");
        assertEq(address(target).balance, amount);
    }

    /// @notice Plain VALUECALL (no FLAG_DATA) still goes through buildInputs and lands
    ///         exactly as before. Sanity check that the dispatcher split did not
    ///         regress the legacy path.
    function test_FlagData_BackwardsCompat_VALUECALL_Unchanged() public {
        uint256 amount = 1 ether;

        bytes[] memory state = WeirollTestHelper.createState1(WeirollTestHelper.encodeUint256(amount));
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildWethDepositCommand(address(weth), 0);

        proxy.executePath{ value: amount }(commands, state);

        assertEq(weth.balanceOf(address(proxy)), amount);
        assertEq(address(proxy).balance, 0);
    }

    /// @notice FLAG_DATA on a non-VALUECALL call type is ignored. The dispatcher
    ///         checks FLAG_CT_MASK first; FLAG_CT_CALL never reaches the FLAG_DATA
    ///         branch. A mint command with FLAG_DATA spuriously set still mints.
    function test_FlagData_NonVALUECALL_FlagIgnored() public {
        uint256 amount = 1000e18;

        bytes[] memory state = WeirollTestHelper.createState2(
            WeirollTestHelper.encodeAddress(recipient), WeirollTestHelper.encodeUint256(amount)
        );
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.encodeCommand(
            bytes4(0x40c10f19), // mint(address,uint256)
            WeirollTestHelper.FLAG_CT_CALL | WeirollTestHelper.FLAG_DATA,
            WeirollTestHelper.indices2(0, 1),
            WeirollTestHelper.IDX_END_OF_ARGS,
            address(tokenA)
        );

        proxy.executePath(commands, state);

        assertEq(tokenA.balanceOf(recipient), amount);
    }

    // ============================================================
    // Native ETH fallthrough
    // ============================================================

    /// @notice receive() accepts plain-value ETH transfers so the Router can forward value.
    function test_ReceiveETH() public {
        uint256 amount = 1 ether;

        vm.prank(user);
        (bool success,) = address(proxy).call{ value: amount }("");

        assertTrue(success);
        assertEq(address(proxy).balance, amount);
    }

    /// @notice fallback() accepts ETH with arbitrary calldata that does not match executePath.
    function test_Fallback_AcceptsETH() public {
        uint256 amount = 1 ether;

        vm.prank(user);
        (bool success,) = address(proxy).call{ value: amount }("0x1234");

        assertTrue(success);
        assertEq(address(proxy).balance, amount);
    }
}
