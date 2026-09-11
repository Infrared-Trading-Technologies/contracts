// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Router } from "src/Router.sol";
import { WeirollTestHelper } from "test/helpers/WeirollTestHelper.sol";
import { RouterAuth } from "test/helpers/RouterAuth.sol";

/// @title InvariantMockERC20
/// @notice Minimal mintable ERC20 used by the invariant handler. Exposes the public
///         `mint(address,uint256)` selector that Weiroll programs in this suite call to
///         synthesize output balances on the Router (the executor's `executePath` runs the
///         mint, producing a measurable balance delta on the Router).
contract InvariantMockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
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
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allow");
        require(balanceOf[from] >= amount, "bal");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @title RouterHandler
/// @notice Foundry invariant handler that fuzzes `Router.swap` and `Router.swapMulti` across a
///         bounded universe of 4 `InvariantMockERC20` tokens plus `NATIVE_ETH_SENTINEL`, three
///         rotating users, and all combinations of `protocolFeeBps`, `partnerFeeBps` (both bounded
///         to the `MAX_*_FEE_BPS = 200` cap), `partnerFeeOnOutput`, and `passPositiveSlippageToUser`.
///
///         The handler pre-computes the exact fee and slippage math the Router will apply, invokes
///         the Router under a `vm.prank`, and on success accumulates the components into a set of
///         ghost variables keyed by token. Those ghosts are consumed by the three invariants in
///         `test/Router.Invariant.t.sol` which encode the spec's conservation law from §Non-
///         Functional Requirements.
///
///         Native ETH is exercised as an *input* only. Native ETH as output would require a
///         funded ETH-sink contract in the Weiroll program; omitting that keeps the handler
///         focused on the accounting invariant without losing native-input coverage.
contract RouterHandler is Test {
    // -------------------------------------------------------------------------
    // Wiring
    // -------------------------------------------------------------------------

    Router public immutable router;

    address public constant NATIVE_ETH_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice Token universe. Indices 0..3 are ERC20; index 4 is NATIVE_ETH_SENTINEL.
    address[5] public tokens;
    uint256 public constant TOKEN_COUNT = 5;
    uint256 public constant ERC20_COUNT = 4;

    /// @notice Three rotating test users -- pranked into the Router per call.
    address[3] public users;

    /// @notice Partner address used for every fuzz call that sets `partnerFeeBps > 0`.
    address public constant PARTNER = address(0xBA5E);

    // -------------------------------------------------------------------------
    // Ghost variables -- per-token accumulators consumed by the three invariants.
    // -------------------------------------------------------------------------

    mapping(address => uint256) public ghost_userReceived;
    mapping(address => uint256) public ghost_protocolFees;
    mapping(address => uint256) public ghost_partnerFees;
    mapping(address => uint256) public ghost_positiveSlippage;
    mapping(address => uint256) public ghost_executorInflow;
    mapping(address => uint256) public ghost_executorOutflow;

    /// @notice Helper splits of `ghost_partnerFees` and a `ghost_pulled` accumulator enable the
    ///         invariant to express the spec's conservation law as two independent per-role
    ///         equations whose sum reconstructs the aggregate statement.
    mapping(address => uint256) public ghost_inputPartnerFees;
    mapping(address => uint256) public ghost_outputPartnerFees;
    mapping(address => uint256) public ghost_pulled;

    // -------------------------------------------------------------------------
    // Exercise counters. Not consumed by the invariants; useful for summary diagnostics.
    // -------------------------------------------------------------------------

    uint256 public ghost_swapCalls;
    uint256 public ghost_multiCalls;
    uint256 public ghost_passThroughUsed;
    uint256 public ghost_partnerOnOutputUsed;

    // -------------------------------------------------------------------------
    // Internal per-call parameter bundles. Structs are passed by reference (memory) to keep
    // stack depth below Solidity's 16-slot limit inside the fuzz entry points.
    // -------------------------------------------------------------------------

    struct SingleCtx {
        address inputToken;
        address outputToken;
        address user;
        uint256 inAmount;
        uint16 protoBps;
        uint16 partnerBps;
        bool onOutput;
        bool passThrough;
        uint256 protocolFee;
        uint256 inputPartnerFee;
        uint256 forward;
        uint256 amountOutMint;
        uint256 quote;
    }

    struct MultiCtx {
        address[] inputs;
        address[] outputs;
        uint256[] inAmts;
        uint256[] protocolFees;
        uint256[] inputPartnerFees;
        uint256[] forwards;
        uint256[] quotes;
        uint256 amt0;
        uint256 amt1;
        address user;
        uint16 protoBps;
        uint16 partnerBps;
        bool onOutput;
        bool passThrough;
        uint256 ethValue;
    }

    // -------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------

    /// @dev Backend signer key: every handler swap is authorized like a real build would be.
    uint256 internal immutable authSignerPk;
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

    constructor(Router _router, address[4] memory erc20s, uint256 _authSignerPk) {
        authSignerPk = _authSignerPk;
        router = _router;
        tokens[0] = erc20s[0];
        tokens[1] = erc20s[1];
        tokens[2] = erc20s[2];
        tokens[3] = erc20s[3];
        tokens[4] = NATIVE_ETH_SENTINEL;

        users[0] = address(uint160(uint256(keccak256("RouterHandler.user.0"))));
        users[1] = address(uint160(uint256(keccak256("RouterHandler.user.1"))));
        users[2] = address(uint160(uint256(keccak256("RouterHandler.user.2"))));

        // Give the handler enough native ETH to fund native-input `msg.value` across the full
        // invariant sequence (256 runs * 15 depth * up to ~1e21 per call).
        vm.deal(address(this), 1e30);
    }

    // -------------------------------------------------------------------------
    // Handler entry points -- each is registered via `targetSelector` from the invariant
    // test's setUp. The fuzzer supplies `seed` and fee parameters; we bound everything to
    // a valid range that the Router accepts so that calls don't revert on input validation.
    // -------------------------------------------------------------------------

    /// @notice Fuzzed `Router.swap` call. Picks a distinct (input, output) pair from the token
    ///         universe, bounds fee bps into `[0, 200]`, builds a Weiroll program that mints a
    ///         deterministic `amountOut` of the output token onto the Router, executes the swap,
    ///         and (on success) accumulates per-token ghost deltas mirroring the Router's own
    ///         internal fee math.
    function swapRandom(
        uint256 seed,
        uint256 inAmount,
        uint16 protoBps,
        uint16 partnerBps,
        bool onOutput,
        bool passThrough
    ) external {
        SingleCtx memory c;
        c.inAmount = bound(inAmount, 1e15, 1e21);
        c.protoBps = uint16(bound(uint256(protoBps), 0, 200));
        c.partnerBps = uint16(bound(uint256(partnerBps), 0, 200));
        c.onOutput = onOutput;
        c.passThrough = passThrough;

        c.inputToken = tokens[seed % TOKEN_COUNT];
        c.outputToken = tokens[(seed >> 8) % ERC20_COUNT];
        if (c.inputToken == c.outputToken) return;

        c.user = users[(seed >> 16) % 3];

        c.protocolFee = (c.inAmount * c.protoBps) / 10_000;
        c.inputPartnerFee = c.onOutput ? 0 : (c.inAmount * c.partnerBps) / 10_000;
        c.forward = c.inAmount - c.protocolFee - c.inputPartnerFee;
        c.amountOutMint = c.forward;

        bool surplusMode = ((seed >> 24) & 1) == 1;
        c.quote = surplusMode && c.forward > 4 ? c.forward - (c.forward / 4) : c.forward;
        if (c.quote == 0 || c.amountOutMint == 0) return;

        _fundUserSingle(c);
        _executeSingle(c);
        _recordSingleGhosts(c);

        ghost_swapCalls++;
        if (c.passThrough) ghost_passThroughUsed++;
        if (c.onOutput) ghost_partnerOnOutputUsed++;
    }

    /// @notice Fuzzed `Router.swapMulti` call with two inputs and two outputs. Picks two distinct
    ///         inputs from the full token universe and two distinct ERC20 outputs, rejects any
    ///         input/output intersection, builds a Weiroll program that mints both outputs to the
    ///         Router, executes, and accumulates per-token ghost deltas summed over the two
    ///         inputs and two outputs.
    function swapMultiRandom(
        uint256 seed,
        uint256 inAmt0,
        uint256 inAmt1,
        uint16 protoBps,
        uint16 partnerBps,
        bool onOutput,
        bool passThrough
    ) external {
        MultiCtx memory c;
        if (!_buildMultiInputs(c, seed)) return;

        c.inAmts = new uint256[](2);
        c.inAmts[0] = bound(inAmt0, 1e15, 1e21);
        c.inAmts[1] = bound(inAmt1, 1e15, 1e21);
        c.protoBps = uint16(bound(uint256(protoBps), 0, 200));
        c.partnerBps = uint16(bound(uint256(partnerBps), 0, 200));
        c.onOutput = onOutput;
        c.passThrough = passThrough;
        c.user = users[(seed >> 32) % 3];

        _computeMultiFees(c);
        if (!_computeMultiQuotes(c, ((seed >> 40) & 1) == 1)) return;

        _fundUserMulti(c);
        _executeMulti(c);
        _recordMultiGhosts(c);

        ghost_multiCalls++;
        if (c.passThrough) ghost_passThroughUsed++;
        if (c.onOutput) ghost_partnerOnOutputUsed++;
    }

    // -------------------------------------------------------------------------
    // Single-swap internals
    // -------------------------------------------------------------------------

    function _fundUserSingle(SingleCtx memory c) internal {
        if (c.inputToken == NATIVE_ETH_SENTINEL) return;
        InvariantMockERC20(c.inputToken).mint(c.user, c.inAmount);
        vm.prank(c.user);
        IERC20(c.inputToken).approve(address(router), c.inAmount);
    }

    function _executeSingle(SingleCtx memory c) internal {
        bytes[] memory state = new bytes[](2);
        state[0] = WeirollTestHelper.encodeAddress(address(router));
        state[1] = WeirollTestHelper.encodeUint256(c.amountOutMint);
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = WeirollTestHelper.buildMintCommand(c.outputToken, 0, 1);

        Router.SwapParams memory p = Router.SwapParams({
            inputToken: c.inputToken,
            inputAmount: c.inAmount,
            outputToken: c.outputToken,
            outputQuote: c.quote,
            outputMin: 1,
            recipient: c.user,
            protocolFeeBps: c.protoBps,
            partnerFeeBps: c.partnerBps,
            partnerRecipient: PARTNER,
            partnerFeeOnOutput: c.onOutput,
            passPositiveSlippageToUser: c.passThrough,
            weirollCommands: commands,
            weirollState: state
        });

        uint256 ethValue = c.inputToken == NATIVE_ETH_SENTINEL ? c.inAmount : 0;
        vm.prank(c.user);
        router.swap{ value: ethValue }(p, _auth(p, c.user));
    }

    function _recordSingleGhosts(SingleCtx memory c) internal {
        ghost_pulled[c.inputToken] += c.inAmount;
        ghost_protocolFees[c.inputToken] += c.protocolFee;
        ghost_inputPartnerFees[c.inputToken] += c.inputPartnerFee;
        ghost_partnerFees[c.inputToken] += c.inputPartnerFee;
        ghost_executorInflow[c.inputToken] += c.forward;

        _updateOutputGhosts(c.outputToken, c.amountOutMint, c.quote, c.partnerBps, c.onOutput, c.passThrough);
    }

    // -------------------------------------------------------------------------
    // Multi-swap internals
    // -------------------------------------------------------------------------

    function _buildMultiInputs(MultiCtx memory c, uint256 seed) internal view returns (bool ok) {
        uint256 in0 = seed % TOKEN_COUNT;
        uint256 in1 = (seed >> 8) % TOKEN_COUNT;
        if (in0 == in1) return false;

        uint256 out0 = (seed >> 16) % ERC20_COUNT;
        uint256 out1 = (seed >> 24) % ERC20_COUNT;
        if (out0 == out1) return false;

        c.inputs = new address[](2);
        c.inputs[0] = tokens[in0];
        c.inputs[1] = tokens[in1];
        c.outputs = new address[](2);
        c.outputs[0] = tokens[out0];
        c.outputs[1] = tokens[out1];
        if (
            c.inputs[0] == c.outputs[0] || c.inputs[0] == c.outputs[1] || c.inputs[1] == c.outputs[0]
                || c.inputs[1] == c.outputs[1]
        ) return false;
        return true;
    }

    function _computeMultiFees(MultiCtx memory c) internal pure {
        c.protocolFees = new uint256[](2);
        c.inputPartnerFees = new uint256[](2);
        c.forwards = new uint256[](2);
        for (uint256 i = 0; i < 2; i++) {
            c.protocolFees[i] = (c.inAmts[i] * c.protoBps) / 10_000;
            c.inputPartnerFees[i] = c.onOutput ? 0 : (c.inAmts[i] * c.partnerBps) / 10_000;
            c.forwards[i] = c.inAmts[i] - c.protocolFees[i] - c.inputPartnerFees[i];
        }
    }

    function _computeMultiQuotes(MultiCtx memory c, bool surplusMode) internal pure returns (bool ok) {
        c.amt0 = c.forwards[0];
        c.amt1 = c.forwards[1];
        c.quotes = new uint256[](2);
        c.quotes[0] = surplusMode && c.amt0 > 4 ? c.amt0 - (c.amt0 / 4) : c.amt0;
        c.quotes[1] = surplusMode && c.amt1 > 4 ? c.amt1 - (c.amt1 / 4) : c.amt1;
        if (c.quotes[0] == 0 || c.quotes[1] == 0 || c.amt0 == 0 || c.amt1 == 0) return false;
        return true;
    }

    function _fundUserMulti(MultiCtx memory c) internal {
        for (uint256 i = 0; i < 2; i++) {
            if (c.inputs[i] == NATIVE_ETH_SENTINEL) {
                c.ethValue = c.inAmts[i];
            } else {
                InvariantMockERC20(c.inputs[i]).mint(c.user, c.inAmts[i]);
                vm.prank(c.user);
                IERC20(c.inputs[i]).approve(address(router), c.inAmts[i]);
            }
        }
    }

    function _executeMulti(MultiCtx memory c) internal {
        bytes[] memory state = new bytes[](5);
        state[0] = WeirollTestHelper.encodeAddress(address(router));
        state[1] = WeirollTestHelper.encodeAddress(c.outputs[0]);
        state[2] = WeirollTestHelper.encodeAddress(c.outputs[1]);
        state[3] = WeirollTestHelper.encodeUint256(c.amt0);
        state[4] = WeirollTestHelper.encodeUint256(c.amt1);
        bytes32[] memory commands = new bytes32[](2);
        commands[0] = WeirollTestHelper.buildMintCommand(c.outputs[0], 0, 3);
        commands[1] = WeirollTestHelper.buildMintCommand(c.outputs[1], 0, 4);

        uint256[] memory mins = new uint256[](2);
        mins[0] = 1;
        mins[1] = 1;

        Router.MultiSwapParams memory p = Router.MultiSwapParams({
            inputTokens: c.inputs,
            inputAmounts: c.inAmts,
            outputTokens: c.outputs,
            outputQuotes: c.quotes,
            outputMins: mins,
            recipient: c.user,
            protocolFeeBps: c.protoBps,
            partnerFeeBps: c.partnerBps,
            partnerRecipient: PARTNER,
            partnerFeeOnOutput: c.onOutput,
            passPositiveSlippageToUser: c.passThrough,
            weirollCommands: commands,
            weirollState: state
        });

        vm.prank(c.user);
        router.swapMulti{ value: c.ethValue }(p, _authMulti(p, c.user));
    }

    function _recordMultiGhosts(MultiCtx memory c) internal {
        for (uint256 i = 0; i < 2; i++) {
            ghost_pulled[c.inputs[i]] += c.inAmts[i];
            ghost_protocolFees[c.inputs[i]] += c.protocolFees[i];
            ghost_inputPartnerFees[c.inputs[i]] += c.inputPartnerFees[i];
            ghost_partnerFees[c.inputs[i]] += c.inputPartnerFees[i];
            ghost_executorInflow[c.inputs[i]] += c.forwards[i];
        }
        _updateOutputGhosts(c.outputs[0], c.amt0, c.quotes[0], c.partnerBps, c.onOutput, c.passThrough);
        _updateOutputGhosts(c.outputs[1], c.amt1, c.quotes[1], c.partnerBps, c.onOutput, c.passThrough);
    }

    // -------------------------------------------------------------------------
    // Shared output-side ghost math. Mirrors Router._executeSwap/_settleOutputs exactly.
    // -------------------------------------------------------------------------

    function _updateOutputGhosts(
        address outputToken,
        uint256 raw,
        uint256 quote,
        uint16 partnerBps,
        bool onOutput,
        bool passThrough
    ) internal {
        uint256 capped;
        uint256 slippage;
        if (!passThrough && raw > quote) {
            capped = quote;
            slippage = raw - quote;
        } else {
            capped = raw;
        }
        uint256 outputPartnerFee = (onOutput && partnerBps > 0) ? (capped * partnerBps) / 10_000 : 0;
        uint256 userGets = capped - outputPartnerFee;

        ghost_executorOutflow[outputToken] += raw;
        ghost_userReceived[outputToken] += userGets;
        ghost_positiveSlippage[outputToken] += slippage;
        ghost_outputPartnerFees[outputToken] += outputPartnerFee;
        ghost_partnerFees[outputToken] += outputPartnerFee;
    }

    // Accept ETH back from the Router on rollback paths (and to be funded in constructor).
    receive() external payable { }
}
