// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MintableERC20
/// @notice Minimal OZ ERC20 with open mint, for UniswapV4SwapHelpers unit tests.
contract MintableERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title MockPermit2
/// @notice Records the helper's `approve` call and lets the mock Universal Router pull the
///         input token from the helper, mirroring the real Permit2 -> PoolManager settlement
///         path closely enough to exercise the helper's own accounting.
contract MockPermit2 {
    address public lastToken;
    address public lastSpender;
    uint160 public lastAmount;
    uint48 public lastExpiration;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        lastToken = token;
        lastSpender = spender;
        lastAmount = amount;
        lastExpiration = expiration;
    }

    /// @dev Pull `amount` of `token` from `from` to `to` using the ERC20 allowance `from`
    ///      granted this contract (the helper's forceApprove).
    function pull(address token, address from, address to, uint256 amount) external {
        require(IERC20(token).transferFrom(from, to, amount), "MockPermit2: transferFrom failed");
    }
}

/// @title MockUniversalRouter
/// @notice Stand-in for Uniswap's Universal Router. `execute` drains the configured input from
///         `msg.sender` (via MockPermit2 for ERC20, via msg.value for native) and delivers the
///         configured output to `msg.sender` (mint for ERC20, `call{value}` for native). The
///         output amount is fixed per test so the helper's pre/post accounting can be asserted
///         exactly.
contract MockUniversalRouter {
    MockPermit2 public immutable PERMIT2;

    address public tokenIn;
    uint256 public amountIn;
    address public tokenOut;
    uint256 public amountOut;

    uint256 public lastDeadline;
    uint256 public lastValue;
    uint256 public executeCalls;

    constructor(MockPermit2 permit2) {
        PERMIT2 = permit2;
    }

    /// @dev Configure the next swap. `tokenIn == address(0)` means native input (paid via
    ///      msg.value); `tokenOut == address(0)` means native output (paid from this contract's
    ///      ETH balance, which the test funds with `vm.deal`).
    function configure(address tokenIn_, uint256 amountIn_, address tokenOut_, uint256 amountOut_) external {
        tokenIn = tokenIn_;
        amountIn = amountIn_;
        tokenOut = tokenOut_;
        amountOut = amountOut_;
    }

    function execute(bytes calldata, bytes[] calldata, uint256 deadline) external payable {
        executeCalls += 1;
        lastDeadline = deadline;
        lastValue = msg.value;

        if (tokenIn == address(0)) {
            require(msg.value == amountIn, "MockUR: bad msg.value");
        } else {
            require(msg.value == 0, "MockUR: unexpected msg.value");
            PERMIT2.pull(tokenIn, msg.sender, address(this), amountIn);
        }

        if (tokenOut == address(0)) {
            (bool ok,) = msg.sender.call{ value: amountOut }("");
            require(ok, "MockUR: native payout failed");
        } else {
            MintableERC20(tokenOut).mint(msg.sender, amountOut);
        }
    }

    receive() external payable { }
}
