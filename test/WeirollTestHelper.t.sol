// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ExecutionProxy } from "../src/ExecutionProxy.sol";
import { WeirollTestHelper } from "./helpers/WeirollTestHelper.sol";
import { MockDEX } from "./mocks/MockDEX.sol";

/// @title MockERC20ForHelper
/// @notice Minimal ERC20 for helper tests
contract MockERC20ForHelper {
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

/// @title MockWETHForHelper
/// @notice Minimal WETH for helper tests
contract MockWETHForHelper is MockERC20ForHelper {
    constructor() MockERC20ForHelper("Wrapped Ether", "WETH", 18) { }

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

/// @title WeirollTestHelperTest
/// @notice Tests that WeirollTestHelper builds valid commands. Drives the command
///         sequences through the pure-VM `ExecutionProxy.executePath` and asserts
///         against balance / allowance side-effects.
contract WeirollTestHelperTest is Test {
    ExecutionProxy public proxy;
    MockWETHForHelper public weth;
    MockERC20ForHelper public tokenA;
    MockERC20ForHelper public tokenB;
    MockDEX public dex;

    address public recipient = makeAddr("recipient");

    function setUp() public {
        weth = new MockWETHForHelper();
        tokenA = new MockERC20ForHelper("Token A", "TKNA", 18);
        tokenB = new MockERC20ForHelper("Token B", "TKNB", 18);
        dex = new MockDEX();

        proxy = new ExecutionProxy(address(this));

        vm.deal(address(this), 100 ether);
    }

    /// @notice Test buildApproveCommand generates valid command
    function test_BuildApproveCommand() public {
        uint256 amount = 1000e18;

        // Build: mint to proxy + approve dex
        bytes[] memory state = WeirollTestHelper.createState3(
            WeirollTestHelper.encodeAddress(address(proxy)),
            WeirollTestHelper.encodeUint256(amount),
            WeirollTestHelper.encodeAddress(address(dex))
        );

        bytes32[] memory commands = new bytes32[](2);
        commands[0] = WeirollTestHelper.buildMintCommand(address(tokenA), 0, 1);
        commands[1] = WeirollTestHelper.buildApproveCommand(address(tokenA), 2, 1);

        proxy.executePath(commands, state);

        assertEq(tokenA.balanceOf(address(proxy)), amount);
        assertEq(tokenA.allowance(address(proxy), address(dex)), amount);
    }

    /// @notice Test buildTransferCommand generates valid command
    function test_BuildTransferCommand() public {
        uint256 amount = 1000e18;

        // Build: mint 2x to proxy, then transfer 1x to recipient via Weiroll
        bytes[] memory state = new bytes[](4);
        state[0] = WeirollTestHelper.encodeAddress(address(proxy));
        state[1] = WeirollTestHelper.encodeUint256(amount * 2);
        state[2] = WeirollTestHelper.encodeAddress(recipient);
        state[3] = WeirollTestHelper.encodeUint256(amount);

        bytes32[] memory commands = new bytes32[](2);
        commands[0] = WeirollTestHelper.buildMintCommand(address(tokenA), 0, 1);
        commands[1] = WeirollTestHelper.buildTransferCommand(address(tokenA), 2, 3);

        proxy.executePath(commands, state);

        assertEq(tokenA.balanceOf(recipient), amount);
        assertEq(tokenA.balanceOf(address(proxy)), amount);
    }

    /// @notice Test buildWETHDepositCommand with value call
    function test_BuildWETHDepositCommand() public {
        uint256 amount = 1 ether;

        bytes[] memory state = WeirollTestHelper.createState1(WeirollTestHelper.encodeUint256(amount));

        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildWethDepositCommand(address(weth), 0);

        proxy.executePath{ value: amount }(commands, state);

        assertEq(weth.balanceOf(address(proxy)), amount);
    }

    /// @notice Test buildWETHWithdrawCommand
    function test_BuildWETHWithdrawCommand() public {
        uint256 amount = 1 ether;

        // Mint WETH to proxy
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

    /// @notice Test MockDEX swap via Weiroll
    function test_MockDEXSwapViaWeiroll() public {
        uint256 amountIn = 1000e18;
        uint256 amountOut = 500e18;

        // Mint tokenA to proxy (pre-existing, consumed by swap)
        tokenA.mint(address(proxy), amountIn);

        bytes[] memory state = WeirollTestHelper.createState5(
            WeirollTestHelper.encodeAddress(address(dex)),
            WeirollTestHelper.encodeUint256(amountIn),
            WeirollTestHelper.encodeAddress(address(tokenA)),
            WeirollTestHelper.encodeAddress(address(tokenB)),
            WeirollTestHelper.encodeUint256(amountOut)
        );

        bytes32[] memory commands = new bytes32[](2);
        commands[0] = WeirollTestHelper.buildApproveCommand(address(tokenA), 0, 1);
        commands[1] = WeirollTestHelper.buildCallFourArgs(
            address(dex), bytes4(keccak256("swap(address,address,uint256,uint256)")), 2, 3, 1, 4
        );

        proxy.executePath(commands, state);

        assertEq(tokenB.balanceOf(address(proxy)), amountOut);
        assertEq(tokenA.balanceOf(address(dex)), amountIn);
    }
}
