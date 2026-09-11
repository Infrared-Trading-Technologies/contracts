// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, Vm } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ISignatureTransfer } from "permit2/interfaces/ISignatureTransfer.sol";

import { ExecutionProxy } from "../src/ExecutionProxy.sol";
import { Router } from "../src/Router.sol";
import { WeirollTestHelper } from "./helpers/WeirollTestHelper.sol";
import { RouterAuth } from "./helpers/RouterAuth.sol";
import { MockDEX } from "./mocks/MockDEX.sol";

/// @dev Minimal mintable ERC20 for this file (kept self-contained like the other Router suites).
contract AuthMockERC20 {
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
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        require(balanceOf[from] >= amount, "Insufficient balance");
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @title RouterAuthorizationTest
/// @notice Nethermind NM-1048 [High]: "Caller-supplied fee and positive slippage parameters let
///         any user strip protocol fees, partner fees and positive slippage capture from swaps".
///         Every user-facing swap now carries a backend-signed EIP-712 authorization over the
///         complete parameters, the taker, a nonce and an expiry; this suite reproduces each
///         bypass from the finding and proves the Router rejects it.
/// @dev Every bypass test has three legs: (1) the signed params succeed; (2) the same params
///      with exactly one field edited and an authorization over the *signed* params revert with
///      the `InvalidAuthorization` selector; (3) the edited params, freshly signed, succeed. Leg 3
///      proves the revert in leg 2 was signature-driven, not validation-driven. With
///      `_verifyAuthorization` stubbed out (negative control), every leg-2 assertion fails.
contract RouterAuthorizationTest is Test {
    address internal constant PERMIT2_ADDR = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 internal constant PERMIT_TRANSFER_FROM_TYPEHASH = keccak256(
        "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );
    bytes32 internal constant PERMIT_BATCH_TRANSFER_FROM_TYPEHASH = keccak256(
        "PermitBatchTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );

    // Baseline economics: 15 bps protocol fee, 50 bps partner fee on output, capture on.
    uint16 internal constant PROTOCOL_FEE_BPS = 15;
    uint16 internal constant PARTNER_FEE_BPS = 50;
    uint256 internal constant INPUT_A = 1000e18;
    uint256 internal constant INPUT_C = 500e18;
    uint256 internal constant DEX_IN_A = 900e18; // below every post-fee forward amount the tests produce
    uint256 internal constant DEX_IN_C = 450e18;
    uint256 internal constant DEX_OUT_B = 950e18; // above the quote: exercises positive-slippage capture
    uint256 internal constant DEX_OUT_D = 470e18;
    uint256 internal constant QUOTE_B = 900e18;
    uint256 internal constant QUOTE_D = 450e18;
    uint256 internal constant MIN_B = 850e18;
    uint256 internal constant MIN_D = 400e18;
    uint256 internal constant AUTH_TTL = 180;

    ExecutionProxy internal executor;
    Router internal router;
    AuthMockERC20 internal tokenA;
    AuthMockERC20 internal tokenB;
    AuthMockERC20 internal tokenC;
    AuthMockERC20 internal tokenD;
    MockDEX internal dex;

    uint256 internal authSignerPk;
    address internal authSigner;
    uint256 internal authNonce;

    uint256 internal userPk;
    address internal user;
    address internal receiver = makeAddr("receiver");
    address internal partner = makeAddr("partner");
    address internal alice = makeAddr("alice");
    address internal liquidator = makeAddr("liquidator");
    address internal stranger = makeAddr("stranger");

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
    event MultiSwap(
        address indexed sender,
        address[] inputTokens,
        uint256[] inputAmounts,
        uint256[] protocolFees,
        uint256[] inputPartnerFees,
        address[] outputTokens,
        uint256[] amountsOut,
        uint256[] amountsToUser,
        uint256[] outputPartnerFees,
        uint256[] positiveSlippagesCaptured,
        address partnerRecipient
    );
    event AuthorizationUsed(bytes32 indexed digest, address indexed taker, address signer);
    event SignerUpdated(address previousSigner, address newSigner, uint256 previousValidUntil);

    function setUp() public {
        // Canonical Permit2 bytecode at its mainnet address (see Router.Permit2.t.sol for why the
        // artifact is read directly). `DOMAIN_SEPARATOR()` recomputes from chainid + address.
        bytes memory deployed =
            vm.parseJsonBytes(vm.readFile("out/Permit2.sol/Permit2.json"), ".deployedBytecode.object");
        vm.etch(PERMIT2_ADDR, deployed);

        (authSigner, authSignerPk) = makeAddrAndKey("backend-signer");
        (user, userPk) = makeAddrAndKey("user");

        router = new Router(address(this), liquidator, authSigner);
        executor = new ExecutionProxy(address(router));
        router.setPendingExecutor(address(executor));
        router.acceptExecutor();

        tokenA = new AuthMockERC20("Token A", "TKNA");
        tokenB = new AuthMockERC20("Token B", "TKNB");
        tokenC = new AuthMockERC20("Token C", "TKNC");
        tokenD = new AuthMockERC20("Token D", "TKND");
        dex = new MockDEX();

        // Ample funding so every leg of every test can execute without per-leg minting.
        tokenA.mint(user, 1e30);
        tokenC.mint(user, 1e30);
        vm.startPrank(user);
        tokenA.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);
        tokenA.approve(PERMIT2_ADDR, type(uint256).max);
        tokenC.approve(PERMIT2_ADDR, type(uint256).max);
        vm.stopPrank();

        // Keep block.timestamp comfortably above the expiry deltas the tests subtract from it.
        vm.warp(1_700_000_000);
    }

    // ------------------------------------------------------------------
    // Authorization helpers
    // ------------------------------------------------------------------

    function _nonce() internal returns (bytes32) {
        return bytes32(++authNonce);
    }

    function _auth(Router.SwapParams memory p, address taker) internal returns (Router.Authorization memory) {
        return RouterAuth.authorizeSwap(address(router), authSignerPk, p, taker, _nonce(), block.timestamp + AUTH_TTL);
    }

    function _authWith(Router.SwapParams memory p, address taker, uint256 pk, uint256 expiry)
        internal
        returns (Router.Authorization memory)
    {
        return RouterAuth.authorizeSwap(address(router), pk, p, taker, _nonce(), expiry);
    }

    function _authMulti(Router.MultiSwapParams memory p, address taker) internal returns (Router.Authorization memory) {
        return
            RouterAuth.authorizeMultiSwap(address(router), authSignerPk, p, taker, _nonce(), block.timestamp + AUTH_TTL);
    }

    function _authMultiWith(Router.MultiSwapParams memory p, address taker, uint256 pk, uint256 expiry)
        internal
        returns (Router.Authorization memory)
    {
        return RouterAuth.authorizeMultiSwap(address(router), pk, p, taker, _nonce(), expiry);
    }

    function _pair(uint256 x, uint256 y) internal pure returns (uint256[] memory a) {
        a = new uint256[](2);
        a[0] = x;
        a[1] = y;
    }

    function _addrPair(address x, address y) internal pure returns (address[] memory a) {
        a = new address[](2);
        a[0] = x;
        a[1] = y;
    }

    function _digestOf(Router.SwapParams memory p, address taker, Router.Authorization memory a)
        internal
        view
        returns (bytes32)
    {
        return RouterAuth.swapDigest(address(router), block.chainid, p, taker, a.nonce, a.expiry);
    }

    // ------------------------------------------------------------------
    // Program builders
    // ------------------------------------------------------------------

    /// @dev State layout: [0] router, [1] dexOut, [2] dex, [3] tokenA, [4] tokenB, [5] dexIn,
    ///      then three entries of lengths 0, 1 and 33 that no command references. Commands:
    ///      approve, swap, transfer to Router, plus an inert `balanceOf` staticcall whose result
    ///      is discarded (so a command can be edited without changing execution).
    function _singleProgram() internal view returns (bytes32[] memory commands, bytes[] memory state) {
        state = new bytes[](9);
        state[0] = WeirollTestHelper.encodeAddress(address(router));
        state[1] = WeirollTestHelper.encodeUint256(DEX_OUT_B);
        state[2] = WeirollTestHelper.encodeAddress(address(dex));
        state[3] = WeirollTestHelper.encodeAddress(address(tokenA));
        state[4] = WeirollTestHelper.encodeAddress(address(tokenB));
        state[5] = WeirollTestHelper.encodeUint256(DEX_IN_A);
        state[6] = "";
        state[7] = hex"01";
        state[8] = new bytes(33);

        commands = new bytes32[](4);
        commands[0] = WeirollTestHelper.buildApproveCommand(address(tokenA), 2, 5);
        commands[1] = WeirollTestHelper.buildCallFourArgs(
            address(dex), bytes4(keccak256("swap(address,address,uint256,uint256)")), 3, 4, 5, 1
        );
        commands[2] = WeirollTestHelper.buildTransferCommand(address(tokenB), 0, 1);
        commands[3] = _inertCommand(address(tokenA));
    }

    function _inertCommand(address token) internal pure returns (bytes32) {
        return WeirollTestHelper.buildStaticCallOneArg(
            token, IERC20.balanceOf.selector, 0, WeirollTestHelper.IDX_END_OF_ARGS
        );
    }

    function _baseline() internal view returns (Router.SwapParams memory p) {
        (bytes32[] memory commands, bytes[] memory state) = _singleProgram();
        p = Router.SwapParams({
            inputToken: address(tokenA),
            inputAmount: INPUT_A,
            outputToken: address(tokenB),
            outputQuote: QUOTE_B,
            outputMin: MIN_B,
            recipient: receiver,
            protocolFeeBps: PROTOCOL_FEE_BPS,
            partnerFeeBps: PARTNER_FEE_BPS,
            partnerRecipient: partner,
            partnerFeeOnOutput: true,
            passPositiveSlippageToUser: false,
            weirollCommands: commands,
            weirollState: state
        });
    }

    /// @dev Two independent legs A->B and C->D plus the inert command; unused entries at the end.
    function _multiProgram() internal view returns (bytes32[] memory commands, bytes[] memory state) {
        state = new bytes[](13);
        state[0] = WeirollTestHelper.encodeAddress(address(router));
        state[1] = WeirollTestHelper.encodeUint256(DEX_OUT_B);
        state[2] = WeirollTestHelper.encodeAddress(address(dex));
        state[3] = WeirollTestHelper.encodeAddress(address(tokenA));
        state[4] = WeirollTestHelper.encodeAddress(address(tokenB));
        state[5] = WeirollTestHelper.encodeUint256(DEX_IN_A);
        state[6] = WeirollTestHelper.encodeAddress(address(tokenC));
        state[7] = WeirollTestHelper.encodeAddress(address(tokenD));
        state[8] = WeirollTestHelper.encodeUint256(DEX_IN_C);
        state[9] = WeirollTestHelper.encodeUint256(DEX_OUT_D);
        state[10] = "";
        state[11] = hex"01";
        state[12] = new bytes(33);

        bytes4 swapSel = bytes4(keccak256("swap(address,address,uint256,uint256)"));
        commands = new bytes32[](7);
        commands[0] = WeirollTestHelper.buildApproveCommand(address(tokenA), 2, 5);
        commands[1] = WeirollTestHelper.buildCallFourArgs(address(dex), swapSel, 3, 4, 5, 1);
        commands[2] = WeirollTestHelper.buildTransferCommand(address(tokenB), 0, 1);
        commands[3] = WeirollTestHelper.buildApproveCommand(address(tokenC), 2, 8);
        commands[4] = WeirollTestHelper.buildCallFourArgs(address(dex), swapSel, 6, 7, 8, 9);
        commands[5] = WeirollTestHelper.buildTransferCommand(address(tokenD), 0, 9);
        commands[6] = _inertCommand(address(tokenA));
    }

    function _baselineMulti() internal view returns (Router.MultiSwapParams memory p) {
        (bytes32[] memory commands, bytes[] memory state) = _multiProgram();
        address[] memory inputTokens = new address[](2);
        inputTokens[0] = address(tokenA);
        inputTokens[1] = address(tokenC);
        uint256[] memory inputAmounts = new uint256[](2);
        inputAmounts[0] = INPUT_A;
        inputAmounts[1] = INPUT_C;
        address[] memory outputTokens = new address[](2);
        outputTokens[0] = address(tokenB);
        outputTokens[1] = address(tokenD);
        uint256[] memory outputQuotes = new uint256[](2);
        outputQuotes[0] = QUOTE_B;
        outputQuotes[1] = QUOTE_D;
        uint256[] memory outputMins = new uint256[](2);
        outputMins[0] = MIN_B;
        outputMins[1] = MIN_D;
        p = Router.MultiSwapParams({
            inputTokens: inputTokens,
            inputAmounts: inputAmounts,
            outputTokens: outputTokens,
            outputQuotes: outputQuotes,
            outputMins: outputMins,
            recipient: receiver,
            protocolFeeBps: PROTOCOL_FEE_BPS,
            partnerFeeBps: PARTNER_FEE_BPS,
            partnerRecipient: partner,
            partnerFeeOnOutput: true,
            passPositiveSlippageToUser: false,
            weirollCommands: commands,
            weirollState: state
        });
    }

    // ------------------------------------------------------------------
    // Three-leg harness
    // ------------------------------------------------------------------

    function _threeLegs(Router.SwapParams memory signed, Router.SwapParams memory tampered) internal {
        // Leg 1: the signed params execute.
        vm.prank(user);
        router.swap(signed, _auth(signed, user));

        // Leg 2: an authorization over the signed params does not cover the tampered ones.
        Router.Authorization memory overSigned = _auth(signed, user);
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swap(tampered, overSigned);

        // Leg 3: the tampered params are valid once the signer covers them.
        vm.prank(user);
        router.swap(tampered, _auth(tampered, user));
    }

    function _twoLegs(Router.SwapParams memory signed, Router.SwapParams memory tampered) internal {
        vm.prank(user);
        router.swap(signed, _auth(signed, user));
        Router.Authorization memory overSigned = _auth(signed, user);
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swap(tampered, overSigned);
    }

    function _threeLegsMulti(Router.MultiSwapParams memory signed, Router.MultiSwapParams memory tampered) internal {
        vm.prank(user);
        router.swapMulti(signed, _authMulti(signed, user));
        Router.Authorization memory overSigned = _authMulti(signed, user);
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swapMulti(tampered, overSigned);
        vm.prank(user);
        router.swapMulti(tampered, _authMulti(tampered, user));
    }

    function _twoLegsMulti(Router.MultiSwapParams memory signed, Router.MultiSwapParams memory tampered) internal {
        vm.prank(user);
        router.swapMulti(signed, _authMulti(signed, user));
        Router.Authorization memory overSigned = _authMulti(signed, user);
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swapMulti(tampered, overSigned);
    }

    // ------------------------------------------------------------------
    // Baseline: signed economics are the ones applied
    // ------------------------------------------------------------------

    function test_Baseline_SignedFeesApplied_AndAuthorizationUsedEmitted() public {
        Router.SwapParams memory p = _baseline();
        Router.Authorization memory a = _auth(p, user);
        bytes32 digest = _digestOf(p, user, a);
        assertEq(router.hashSwapAuthorization(p, user, a.nonce, a.expiry), digest, "view digest");

        // 1000e18 in: protocol 1.5e18; dex returns 950e18, capped at 900e18 (50e18 captured);
        // output partner fee 50 bps of 900e18 = 4.5e18; user receives 895.5e18.
        vm.expectEmit(true, true, false, true, address(router));
        emit AuthorizationUsed(digest, user, authSigner);
        vm.expectEmit(true, false, false, true, address(router));
        emit Swap(user, address(tokenA), INPUT_A, address(tokenB), 950e18, 895.5e18, 1.5e18, 4.5e18, 50e18, partner);

        vm.prank(user);
        uint256 out = router.swap(p, a);
        assertEq(out, 895.5e18);
        assertEq(tokenB.balanceOf(receiver), 895.5e18);
        assertEq(tokenB.balanceOf(partner), 4.5e18);
        assertEq(tokenB.balanceOf(address(router)), 50e18, "captured slippage stays on the Router");
        assertEq(tokenA.balanceOf(address(router)), 1.5e18, "protocol fee stays on the Router");
        assertTrue(router.consumedAuthorizations(digest));
    }

    // ------------------------------------------------------------------
    // Single-swap bypass reproductions (the finding's exact edits)
    // ------------------------------------------------------------------

    function test_Bypass_UnsignedZeroFees_Reverts() public {
        Router.SwapParams memory p = _baseline();
        vm.prank(user);
        router.swap(p, _auth(p, user));

        Router.SwapParams memory t = _baseline();
        t.protocolFeeBps = 0;
        t.partnerFeeBps = 0;
        t.passPositiveSlippageToUser = true;

        Router.Authorization memory empty =
            Router.Authorization({ nonce: _nonce(), expiry: block.timestamp + AUTH_TTL, signature: "" });
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swap(t, empty);

        Router.Authorization memory garbage =
            Router.Authorization({ nonce: _nonce(), expiry: block.timestamp + AUTH_TTL, signature: new bytes(65) });
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swap(t, garbage);
    }

    function test_Bypass_ProtocolFeeZeroed_Reverts() public {
        Router.SwapParams memory t = _baseline();
        t.protocolFeeBps = 0;
        _threeLegs(_baseline(), t);
    }

    function test_Bypass_PartnerFeeZeroed_Reverts() public {
        Router.SwapParams memory t = _baseline();
        t.partnerFeeBps = 0;
        _threeLegs(_baseline(), t);
    }

    function test_Bypass_PassPositiveSlippageFlipped_Reverts() public {
        Router.SwapParams memory t = _baseline();
        t.passPositiveSlippageToUser = true;
        _threeLegs(_baseline(), t);
    }

    function test_Bypass_OutputQuoteInflated_Reverts() public {
        Router.SwapParams memory t = _baseline();
        t.outputQuote = 2000e18;
        _threeLegs(_baseline(), t);
    }

    function test_Bypass_PartnerRecipientSwapped_Reverts() public {
        Router.SwapParams memory t = _baseline();
        t.partnerRecipient = alice;
        _threeLegs(_baseline(), t);
    }

    function test_Bypass_PartnerFeeOnOutputFlipped_Reverts() public {
        Router.SwapParams memory t = _baseline();
        t.partnerFeeOnOutput = false;
        _threeLegs(_baseline(), t);
    }

    function test_Bypass_InputAmountLowered_Reverts() public {
        Router.SwapParams memory t = _baseline();
        t.inputAmount = 950e18;
        _threeLegs(_baseline(), t);
    }

    function test_Bypass_RecipientChanged_Reverts() public {
        Router.SwapParams memory t = _baseline();
        t.recipient = alice;
        _threeLegs(_baseline(), t);
    }

    function test_Bypass_OutputMinChanged_Reverts() public {
        Router.SwapParams memory t = _baseline();
        t.outputMin = 860e18;
        _threeLegs(_baseline(), t);
    }

    function test_Bypass_CommandChanged_Reverts() public {
        Router.SwapParams memory t = _baseline();
        t.weirollCommands[3] = _inertCommand(address(tokenB));
        _threeLegs(_baseline(), t);
    }

    function test_Bypass_StateEntryChanged_Reverts() public {
        Router.SwapParams memory t = _baseline();
        t.weirollState[7] = hex"02";
        _threeLegs(_baseline(), t);
    }

    /// @dev ["ab","c"] and ["a","bc"] concatenate to the same bytes; only element-wise hashing
    ///      tells them apart.
    function test_Bypass_StateBoundaryShift_Reverts() public {
        Router.SwapParams memory s = _baseline();
        s.weirollState[6] = "ab";
        s.weirollState[7] = "c";
        Router.SwapParams memory t = _baseline();
        t.weirollState[6] = "a";
        t.weirollState[7] = "bc";
        _threeLegs(s, t);
    }

    function test_Bypass_ExpiryExtended_Reverts() public {
        Router.SwapParams memory p = _baseline();
        Router.Authorization memory a = _auth(p, user);
        a.expiry += 30 minutes;
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swap(p, a);
    }

    function test_Bypass_NonceChanged_Reverts() public {
        Router.SwapParams memory p = _baseline();
        Router.Authorization memory a = _auth(p, user);
        a.nonce = bytes32(uint256(a.nonce) + 1);
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swap(p, a);
    }

    /// @dev Any single economic field mutated inside validation bounds: three legs.
    function testFuzz_Bypass_SingleEconomicField_Reverts(uint8 fieldSeed, uint256 valueSeed) public {
        uint256 field = bound(fieldSeed, 0, 8);
        Router.SwapParams memory s = _baseline();
        Router.SwapParams memory t = _baseline();
        if (field == 0) {
            t.inputAmount = bound(valueSeed, 950e18, 1100e18);
            vm.assume(t.inputAmount != s.inputAmount);
        } else if (field == 1) {
            t.outputQuote = bound(valueSeed, 901e18, 5000e18);
        } else if (field == 2) {
            t.outputMin = bound(valueSeed, 1, 895e18);
            vm.assume(t.outputMin != s.outputMin);
        } else if (field == 3) {
            t.recipient = address(uint160(bound(valueSeed, 1, type(uint160).max)));
            vm.assume(t.recipient != s.recipient);
        } else if (field == 4) {
            t.protocolFeeBps = uint16(bound(valueSeed, 0, 200));
            vm.assume(t.protocolFeeBps != s.protocolFeeBps);
        } else if (field == 5) {
            t.partnerFeeBps = uint16(bound(valueSeed, 0, 200));
            vm.assume(t.partnerFeeBps != s.partnerFeeBps);
        } else if (field == 6) {
            t.partnerRecipient = address(uint160(bound(valueSeed, 1, type(uint160).max)));
            vm.assume(t.partnerRecipient != s.partnerRecipient);
        } else if (field == 7) {
            t.partnerFeeOnOutput = !s.partnerFeeOnOutput;
        } else {
            t.passPositiveSlippageToUser = !s.passPositiveSlippageToUser;
        }
        _threeLegs(s, t);
    }

    /// @dev Any single program element mutated (first, middle, last, empty): two legs, plus the
    ///      third leg when the mutated element is one no command reads.
    function testFuzz_Bypass_SingleProgramElement_Reverts(bool mutateState, uint8 indexSeed, bytes32 valueSeed) public {
        Router.SwapParams memory s = _baseline();
        Router.SwapParams memory t = _baseline();
        if (mutateState) {
            uint256 i = bound(indexSeed, 0, s.weirollState.length - 1);
            bytes memory replacement = abi.encodePacked(valueSeed);
            if (uint256(valueSeed) % 3 == 0) replacement = abi.encodePacked(valueSeed, uint8(1)); // 33 bytes
            if (uint256(valueSeed) % 3 == 1) replacement = abi.encodePacked(uint8(valueSeed[0])); // 1 byte
            vm.assume(keccak256(replacement) != keccak256(s.weirollState[i]));
            t.weirollState[i] = replacement;
            if (i >= 6) {
                _threeLegs(s, t);
            } else {
                _twoLegs(s, t);
            }
        } else {
            uint256 i = bound(indexSeed, 0, s.weirollCommands.length - 1);
            vm.assume(valueSeed != s.weirollCommands[i]);
            t.weirollCommands[i] = valueSeed;
            _twoLegs(s, t);
        }
    }

    // ------------------------------------------------------------------
    // Multi-swap bypass reproductions
    // ------------------------------------------------------------------

    function test_Multi_Baseline_SignedFeesApplied() public {
        Router.MultiSwapParams memory p = _baselineMulti();
        Router.Authorization memory a = _authMulti(p, user);
        bytes32 digest = RouterAuth.multiSwapDigest(address(router), block.chainid, p, user, a.nonce, a.expiry);
        assertEq(router.hashMultiSwapAuthorization(p, user, a.nonce, a.expiry), digest, "view digest");
        // Derived by hand from the constants (see the fee rules in Router natspec):
        // protocol fee on each input, capture above the quote, partner fee on the capped output.
        uint256 protocolFeeA = (INPUT_A * PROTOCOL_FEE_BPS) / 10_000; // 1.5e18
        uint256 protocolFeeC = (INPUT_C * PROTOCOL_FEE_BPS) / 10_000; // 0.75e18
        uint256 capturedB = DEX_OUT_B - QUOTE_B; // 50e18
        uint256 capturedD = DEX_OUT_D - QUOTE_D; // 20e18
        uint256 partnerB = (QUOTE_B * PARTNER_FEE_BPS) / 10_000; // 4.5e18
        uint256 partnerD = (QUOTE_D * PARTNER_FEE_BPS) / 10_000; // 2.25e18
        uint256 userB = QUOTE_B - partnerB; // 895.5e18
        uint256 userD = QUOTE_D - partnerD; // 447.75e18
        assertEq(partnerD, 2.25e18);
        assertEq(capturedD, 20e18);
        vm.expectEmit(true, true, false, true, address(router));
        emit AuthorizationUsed(digest, user, authSigner);
        vm.expectEmit(true, false, false, true, address(router));
        emit MultiSwap(
            user,
            _addrPair(address(tokenA), address(tokenC)),
            _pair(INPUT_A, INPUT_C),
            _pair(protocolFeeA, protocolFeeC),
            _pair(0, 0),
            _addrPair(address(tokenB), address(tokenD)),
            _pair(DEX_OUT_B, DEX_OUT_D),
            _pair(userB, userD),
            _pair(partnerB, partnerD),
            _pair(capturedB, capturedD),
            partner
        );
        vm.prank(user);
        uint256[] memory out = router.swapMulti(p, a);
        assertEq(out[0], userB, "return B");
        assertEq(out[1], userD, "return D");
        assertEq(tokenB.balanceOf(receiver), userB, "receiver B");
        assertEq(tokenD.balanceOf(receiver), userD, "receiver D");
        assertEq(tokenB.balanceOf(partner), partnerB, "partner B");
        assertEq(tokenD.balanceOf(partner), partnerD, "partner D");
        assertEq(tokenA.balanceOf(partner), 0, "partner A (input-side fee off)");
        assertEq(tokenC.balanceOf(partner), 0, "partner C (input-side fee off)");
        assertEq(tokenA.balanceOf(address(router)), protocolFeeA, "router A");
        assertEq(tokenC.balanceOf(address(router)), protocolFeeC, "router C");
        assertEq(tokenB.balanceOf(address(router)), capturedB, "router B");
        assertEq(tokenD.balanceOf(address(router)), capturedD, "router D");
        assertEq(tokenA.balanceOf(user), 1e30 - INPUT_A, "user A");
        assertEq(tokenC.balanceOf(user), 1e30 - INPUT_C, "user C");
        assertTrue(router.consumedAuthorizations(digest));
    }

    function test_Multi_Bypass_UnsignedZeroFees_Reverts() public {
        Router.MultiSwapParams memory t = _baselineMulti();
        t.protocolFeeBps = 0;
        t.partnerFeeBps = 0;
        t.passPositiveSlippageToUser = true;
        Router.Authorization memory empty =
            Router.Authorization({ nonce: _nonce(), expiry: block.timestamp + AUTH_TTL, signature: "" });
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swapMulti(t, empty);
    }

    function test_Multi_Bypass_ProtocolFeeZeroed_Reverts() public {
        Router.MultiSwapParams memory t = _baselineMulti();
        t.protocolFeeBps = 0;
        _threeLegsMulti(_baselineMulti(), t);
    }

    function test_Multi_Bypass_PartnerFeeZeroed_Reverts() public {
        Router.MultiSwapParams memory t = _baselineMulti();
        t.partnerFeeBps = 0;
        _threeLegsMulti(_baselineMulti(), t);
    }

    function test_Multi_Bypass_PassPositiveSlippageFlipped_Reverts() public {
        Router.MultiSwapParams memory t = _baselineMulti();
        t.passPositiveSlippageToUser = true;
        _threeLegsMulti(_baselineMulti(), t);
    }

    function test_Multi_Bypass_OutputQuoteInflated_Reverts() public {
        Router.MultiSwapParams memory t = _baselineMulti();
        t.outputQuotes[1] = 2000e18;
        _threeLegsMulti(_baselineMulti(), t);
    }

    function test_Multi_Bypass_PartnerRecipientSwapped_Reverts() public {
        Router.MultiSwapParams memory t = _baselineMulti();
        t.partnerRecipient = alice;
        _threeLegsMulti(_baselineMulti(), t);
    }

    function test_Multi_Bypass_PartnerFeeOnOutputFlipped_Reverts() public {
        Router.MultiSwapParams memory t = _baselineMulti();
        t.partnerFeeOnOutput = false;
        _threeLegsMulti(_baselineMulti(), t);
    }

    function test_Multi_Bypass_InputAmountLowered_Reverts() public {
        Router.MultiSwapParams memory t = _baselineMulti();
        t.inputAmounts[0] = 950e18;
        _threeLegsMulti(_baselineMulti(), t);
    }

    function test_Multi_Bypass_RecipientChanged_Reverts() public {
        Router.MultiSwapParams memory t = _baselineMulti();
        t.recipient = alice;
        _threeLegsMulti(_baselineMulti(), t);
    }

    function test_Multi_Bypass_OutputMinChanged_Reverts() public {
        Router.MultiSwapParams memory t = _baselineMulti();
        t.outputMins[0] = 860e18;
        _threeLegsMulti(_baselineMulti(), t);
    }

    function test_Multi_Bypass_InputsReordered_Reverts() public {
        Router.MultiSwapParams memory t = _baselineMulti();
        (t.inputTokens[0], t.inputTokens[1]) = (t.inputTokens[1], t.inputTokens[0]);
        (t.inputAmounts[0], t.inputAmounts[1]) = (t.inputAmounts[1], t.inputAmounts[0]);
        _threeLegsMulti(_baselineMulti(), t);
    }

    /// @dev `inputTokens` alone: the tampered program cannot be made valid (the Router would pull a
    /// token the program never swaps), so this is a two-leg test like the program-element tests.
    function test_Multi_Bypass_InputTokenChanged_Reverts() public {
        Router.MultiSwapParams memory t = _baselineMulti();
        t.inputTokens[0] = address(new AuthMockERC20("Token X", "TKNX"));
        _twoLegsMulti(_baselineMulti(), t);
    }

    /// @dev `outputTokens` alone: same reasoning as `test_Multi_Bypass_InputTokenChanged_Reverts`.
    function test_Multi_Bypass_OutputTokenChanged_Reverts() public {
        Router.MultiSwapParams memory t = _baselineMulti();
        t.outputTokens[1] = address(new AuthMockERC20("Token X", "TKNX"));
        _twoLegsMulti(_baselineMulti(), t);
    }

    /// @dev Positive control for the output side: a reordered output set is a different digest and
    /// executes once the signer covers it.
    function test_Multi_Bypass_OutputsReordered_Reverts() public {
        Router.MultiSwapParams memory t = _baselineMulti();
        (t.outputTokens[0], t.outputTokens[1]) = (t.outputTokens[1], t.outputTokens[0]);
        (t.outputQuotes[0], t.outputQuotes[1]) = (t.outputQuotes[1], t.outputQuotes[0]);
        (t.outputMins[0], t.outputMins[1]) = (t.outputMins[1], t.outputMins[0]);
        _threeLegsMulti(_baselineMulti(), t);
    }

    function test_Multi_Bypass_CommandChanged_Reverts() public {
        Router.MultiSwapParams memory t = _baselineMulti();
        t.weirollCommands[6] = _inertCommand(address(tokenB));
        _threeLegsMulti(_baselineMulti(), t);
    }

    function test_Multi_Bypass_StateEntryChanged_Reverts() public {
        Router.MultiSwapParams memory t = _baselineMulti();
        t.weirollState[11] = hex"02";
        _threeLegsMulti(_baselineMulti(), t);
    }

    function test_Multi_Bypass_StateBoundaryShift_Reverts() public {
        Router.MultiSwapParams memory s = _baselineMulti();
        s.weirollState[10] = "ab";
        s.weirollState[11] = "c";
        Router.MultiSwapParams memory t = _baselineMulti();
        t.weirollState[10] = "a";
        t.weirollState[11] = "bc";
        _threeLegsMulti(s, t);
    }

    function test_Multi_Bypass_ExpiryExtended_Reverts() public {
        Router.MultiSwapParams memory p = _baselineMulti();
        Router.Authorization memory a = _authMulti(p, user);
        a.expiry += 30 minutes;
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swapMulti(p, a);
    }

    function test_Multi_Bypass_NonceChanged_Reverts() public {
        Router.MultiSwapParams memory p = _baselineMulti();
        Router.Authorization memory a = _authMulti(p, user);
        a.nonce = bytes32(uint256(a.nonce) + 1);
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swapMulti(p, a);
    }

    function test_Multi_WrongTaker_Reverts() public {
        Router.MultiSwapParams memory p = _baselineMulti();
        Router.Authorization memory a = _authMulti(p, alice);
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swapMulti(p, a);
    }

    /// @dev A legitimately signed mismatched array still fails validation: the authorization
    ///      gate does not replace the existing checks.
    function test_Multi_ArrayLengthMismatch_StillCaught() public {
        Router.MultiSwapParams memory p = _baselineMulti();
        uint256[] memory quotes = new uint256[](3);
        quotes[0] = QUOTE_B;
        quotes[1] = QUOTE_D;
        quotes[2] = 1;
        p.outputQuotes = quotes;
        Router.Authorization memory a = _authMulti(p, user);
        vm.prank(user);
        vm.expectRevert(Router.ArrayLengthMismatch.selector);
        router.swapMulti(p, a);
    }

    function testFuzz_Multi_Bypass_SingleEconomicField_Reverts(uint8 fieldSeed, uint256 valueSeed) public {
        uint256 field = bound(fieldSeed, 0, 9);
        Router.MultiSwapParams memory s = _baselineMulti();
        Router.MultiSwapParams memory t = _baselineMulti();
        uint256 slot = valueSeed % 2;
        if (field == 0) {
            t.inputAmounts[slot] = slot == 0 ? bound(valueSeed, 950e18, 1100e18) : bound(valueSeed, 475e18, 550e18);
            vm.assume(t.inputAmounts[slot] != s.inputAmounts[slot]);
        } else if (field == 1) {
            t.outputQuotes[slot] = slot == 0 ? bound(valueSeed, 901e18, 5000e18) : bound(valueSeed, 451e18, 5000e18);
        } else if (field == 2) {
            t.outputMins[slot] = slot == 0 ? bound(valueSeed, 1, 895e18) : bound(valueSeed, 1, 447e18);
            vm.assume(t.outputMins[slot] != s.outputMins[slot]);
        } else if (field == 3) {
            t.recipient = address(uint160(bound(valueSeed, 1, type(uint160).max)));
            vm.assume(t.recipient != s.recipient);
        } else if (field == 4) {
            t.protocolFeeBps = uint16(bound(valueSeed, 0, 200));
            vm.assume(t.protocolFeeBps != s.protocolFeeBps);
        } else if (field == 5) {
            t.partnerFeeBps = uint16(bound(valueSeed, 0, 200));
            vm.assume(t.partnerFeeBps != s.partnerFeeBps);
        } else if (field == 6) {
            t.partnerRecipient = address(uint160(bound(valueSeed, 1, type(uint160).max)));
            vm.assume(t.partnerRecipient != s.partnerRecipient);
        } else if (field == 7) {
            t.partnerFeeOnOutput = !s.partnerFeeOnOutput;
        } else if (field == 8) {
            t.passPositiveSlippageToUser = !s.passPositiveSlippageToUser;
        } else {
            (t.inputTokens[0], t.inputTokens[1]) = (t.inputTokens[1], t.inputTokens[0]);
            (t.inputAmounts[0], t.inputAmounts[1]) = (t.inputAmounts[1], t.inputAmounts[0]);
        }
        _threeLegsMulti(s, t);
    }

    function testFuzz_Multi_Bypass_SingleProgramElement_Reverts(bool mutateState, uint8 indexSeed, bytes32 valueSeed)
        public
    {
        Router.MultiSwapParams memory s = _baselineMulti();
        Router.MultiSwapParams memory t = _baselineMulti();
        if (mutateState) {
            uint256 i = bound(indexSeed, 0, s.weirollState.length - 1);
            bytes memory replacement = abi.encodePacked(valueSeed);
            if (uint256(valueSeed) % 3 == 0) replacement = abi.encodePacked(valueSeed, uint8(1));
            if (uint256(valueSeed) % 3 == 1) replacement = abi.encodePacked(uint8(valueSeed[0]));
            vm.assume(keccak256(replacement) != keccak256(s.weirollState[i]));
            t.weirollState[i] = replacement;
            if (i >= 10) {
                _threeLegsMulti(s, t);
            } else {
                _twoLegsMulti(s, t);
            }
        } else {
            uint256 i = bound(indexSeed, 0, s.weirollCommands.length - 1);
            vm.assume(valueSeed != s.weirollCommands[i]);
            t.weirollCommands[i] = valueSeed;
            _twoLegsMulti(s, t);
        }
    }

    // ------------------------------------------------------------------
    // Permit2 variants: authorization runs before the pull
    // ------------------------------------------------------------------

    function _permit2Domain() internal view returns (bytes32) {
        return ISignatureTransfer(PERMIT2_ADDR).DOMAIN_SEPARATOR();
    }

    function _signSinglePermit(uint256 pk, address token, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TRANSFER_FROM_TYPEHASH,
                keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, token, amount)),
                address(router),
                nonce,
                deadline
            )
        );
        bytes32 d = keccak256(abi.encodePacked("\x19\x01", _permit2Domain(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return abi.encodePacked(r, s, v);
    }

    function _signBatchPermit(
        uint256 pk,
        address[] memory tokens,
        uint256[] memory amounts,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32[] memory hashes = new bytes32[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            hashes[i] = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, tokens[i], amounts[i]));
        }
        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_BATCH_TRANSFER_FROM_TYPEHASH,
                keccak256(abi.encodePacked(hashes)),
                address(router),
                nonce,
                deadline
            )
        );
        bytes32 d = keccak256(abi.encodePacked("\x19\x01", _permit2Domain(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return abi.encodePacked(r, s, v);
    }

    function _permit(uint256 pk, uint256 nonce) internal view returns (Router.Permit2Data memory) {
        uint256 deadline = block.timestamp + 600;
        return Router.Permit2Data({
            nonce: nonce,
            deadline: deadline,
            signature: _signSinglePermit(pk, address(tokenA), INPUT_A, nonce, deadline)
        });
    }

    function _batchPermit(uint256 pk, uint256 nonce, Router.MultiSwapParams memory p)
        internal
        view
        returns (Router.Permit2Data memory)
    {
        uint256 deadline = block.timestamp + 600;
        return Router.Permit2Data({
            nonce: nonce,
            deadline: deadline,
            signature: _signBatchPermit(pk, p.inputTokens, p.inputAmounts, nonce, deadline)
        });
    }

    // Permit data is built before `vm.prank` / `vm.expectRevert`: signing it reads Permit2's
    // DOMAIN_SEPARATOR(), an external call that would otherwise consume the prank.

    function test_Permit2_TamperedAuthorization_RevertsBeforePermit2() public {
        (, uint256 wrongPk) = makeAddrAndKey("not-the-user");
        Router.SwapParams memory t = _baseline();
        t.protocolFeeBps = 0;
        Router.Authorization memory overSigned = _auth(_baseline(), user);
        // Permit2 would reject this permit (`InvalidSigner`); the Router never gets that far.
        Router.Permit2Data memory badPermit = _permit(wrongPk, 1);
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swapPermit2(t, badPermit, overSigned);
    }

    function test_Permit2_ValidAuthorization_InvalidPermit_RevertsInPermit2() public {
        (, uint256 wrongPk) = makeAddrAndKey("not-the-user");
        Router.SwapParams memory p = _baseline();
        Router.Authorization memory a = _auth(p, user);
        Router.Permit2Data memory badPermit = _permit(wrongPk, 2);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("InvalidSigner()"));
        router.swapPermit2(p, badPermit, a);
    }

    function test_Permit2_Valid_Succeeds() public {
        Router.SwapParams memory p = _baseline();
        Router.Permit2Data memory permit = _permit(userPk, 3);
        Router.Authorization memory a = _auth(p, user);
        vm.prank(user);
        uint256 out = router.swapPermit2(p, permit, a);
        assertEq(out, 895.5e18);
    }

    /// @dev `swap` and `swapPermit2` share a digest for the same params; one use consumes both.
    function test_Permit2_AuthorizationConsumedViaSwap_RejectedBySwapPermit2() public {
        Router.SwapParams memory p = _baseline();
        Router.Authorization memory a = _auth(p, user);
        bytes32 digest = _digestOf(p, user, a);
        vm.prank(user);
        router.swap(p, a);
        Router.Permit2Data memory permit = _permit(userPk, 4);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Router.AuthorizationAlreadyUsed.selector, digest));
        router.swapPermit2(p, permit, a);
    }

    function test_MultiPermit2_TamperedAuthorization_RevertsBeforePermit2() public {
        (, uint256 wrongPk) = makeAddrAndKey("not-the-user");
        Router.MultiSwapParams memory t = _baselineMulti();
        t.passPositiveSlippageToUser = true;
        Router.Authorization memory overSigned = _authMulti(_baselineMulti(), user);
        Router.Permit2Data memory badPermit = _batchPermit(wrongPk, 5, t);
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swapMultiPermit2(t, badPermit, overSigned);
    }

    function test_MultiPermit2_ValidAuthorization_InvalidPermit_RevertsInPermit2() public {
        (, uint256 wrongPk) = makeAddrAndKey("not-the-user");
        Router.MultiSwapParams memory p = _baselineMulti();
        Router.Authorization memory a = _authMulti(p, user);
        Router.Permit2Data memory badPermit = _batchPermit(wrongPk, 6, p);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("InvalidSigner()"));
        router.swapMultiPermit2(p, badPermit, a);
    }

    function test_MultiPermit2_Valid_Succeeds() public {
        Router.MultiSwapParams memory p = _baselineMulti();
        Router.Permit2Data memory permit = _batchPermit(userPk, 7, p);
        Router.Authorization memory a = _authMulti(p, user);
        vm.prank(user);
        uint256[] memory out = router.swapMultiPermit2(p, permit, a);
        assertEq(out[0], 895.5e18);
        assertEq(out[1], 447.75e18);
    }

    // ------------------------------------------------------------------
    // Authorization semantics
    // ------------------------------------------------------------------

    function test_Expired_Reverts() public {
        Router.SwapParams memory p = _baseline();
        uint256 expiry = block.timestamp - 1;
        Router.Authorization memory a = _authWith(p, user, authSignerPk, expiry);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Router.AuthorizationExpired.selector, expiry));
        router.swap(p, a);
    }

    function test_ExpiryTooFar_Reverts() public {
        Router.SwapParams memory p = _baseline();
        uint256 expiry = block.timestamp + router.MAX_AUTHORIZATION_TTL() + 1;
        Router.Authorization memory a = _authWith(p, user, authSignerPk, expiry);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Router.AuthorizationExpiryTooFar.selector, expiry));
        router.swap(p, a);
    }

    function test_ExpiryAtBoundaries_Succeeds() public {
        Router.SwapParams memory p = _baseline();
        uint256 maxTtl = router.MAX_AUTHORIZATION_TTL();
        Router.Authorization memory atNow = _authWith(p, user, authSignerPk, block.timestamp);
        vm.prank(user);
        assertEq(router.swap(p, atNow), 895.5e18, "expiry == now applies the signed economics");
        assertTrue(router.consumedAuthorizations(_digestOf(p, user, atNow)));
        Router.Authorization memory atCap = _authWith(p, user, authSignerPk, block.timestamp + maxTtl);
        vm.prank(user);
        assertEq(router.swap(p, atCap), 895.5e18, "expiry == now + MAX_AUTHORIZATION_TTL applies the signed economics");
        assertTrue(router.consumedAuthorizations(_digestOf(p, user, atCap)));
        assertEq(tokenB.balanceOf(receiver), 2 * 895.5e18);
    }

    /// @dev A revert after `_verifyAuthorization` rolls back the one-time-use mark: the identical
    /// (params, authorization) pair succeeds once the external cause is removed.
    function test_RevertedSwap_LeavesAuthorizationUnconsumed_ThenSameAuthSucceeds() public {
        Router.SwapParams memory p = _baseline();
        Router.Authorization memory a = _auth(p, user);
        bytes32 digest = _digestOf(p, user, a);
        vm.prank(user);
        tokenA.approve(address(router), 0);
        vm.prank(user);
        vm.expectRevert(bytes("Insufficient allowance"));
        router.swap(p, a);
        assertFalse(router.consumedAuthorizations(digest), "reverted swap must consume nothing");
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
        vm.prank(user);
        assertEq(router.swap(p, a), 895.5e18);
        assertTrue(router.consumedAuthorizations(digest));
    }

    function test_WrongChainId_Reverts() public {
        Router.SwapParams memory p = _baseline();
        vm.chainId(1);
        Router.Authorization memory signedOnChain1 = _auth(p, user);
        vm.chainId(2);
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swap(p, signedOnChain1);
        // Positive control: signed under chain 2, accepted on chain 2.
        vm.prank(user);
        router.swap(p, _auth(p, user));
    }

    function test_WrongRouter_Reverts() public {
        Router other = new Router(address(this), liquidator, authSigner);
        Router.SwapParams memory p = _baseline();
        Router.Authorization memory forThisRouter = _auth(p, user);
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        other.swap(p, forThisRouter);
    }

    function test_WrongTaker_Reverts() public {
        Router.SwapParams memory p = _baseline();
        Router.Authorization memory forAlice = _auth(p, alice);
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swap(p, forAlice);
    }

    function test_WrongSigner_Reverts() public {
        (, uint256 otherPk) = makeAddrAndKey("not-the-signer");
        Router.SwapParams memory p = _baseline();
        Router.Authorization memory a = _authWith(p, user, otherPk, block.timestamp + AUTH_TTL);
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swap(p, a);
    }

    function test_SignerNotSet_Reverts() public {
        router.setSigner(address(0), 0);
        Router.SwapParams memory p = _baseline();
        Router.Authorization memory a = _auth(p, user);
        vm.prank(user);
        vm.expectRevert(Router.SignerNotSet.selector);
        router.swap(p, a);
    }

    function test_HighSMalleatedSignature_Reverts() public {
        Router.SwapParams memory p = _baseline();
        Router.Authorization memory a = _auth(p, user);
        (bytes32 r, bytes32 s, uint8 v) = _split(a.signature);
        assertTrue(uint256(s) <= RouterAuth.SECP256K1_N / 2, "reference signer produces low-s");
        bytes32 sHigh = bytes32(RouterAuth.SECP256K1_N - uint256(s));
        assertTrue(uint256(sHigh) > RouterAuth.SECP256K1_N / 2, "twin is high-s");
        Router.Authorization memory malleated =
            Router.Authorization({ nonce: a.nonce, expiry: a.expiry, signature: abi.encodePacked(r, sHigh, v ^ 1) });
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swap(p, malleated);
        // The low-s original is still accepted.
        vm.prank(user);
        router.swap(p, a);
    }

    function test_RecoveryIdZeroOrOne_Rejected_27Or28Accepted() public {
        Router.SwapParams memory p = _baseline();
        Router.Authorization memory a = _auth(p, user);
        (bytes32 r, bytes32 s, uint8 v) = _split(a.signature);
        assertTrue(v == 27 || v == 28);
        Router.Authorization memory raw =
            Router.Authorization({ nonce: a.nonce, expiry: a.expiry, signature: abi.encodePacked(r, s, v - 27) });
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swap(p, raw);
        vm.prank(user);
        router.swap(p, a);
    }

    function test_MalformedSignatures_Reverts() public {
        Router.SwapParams memory p = _baseline();
        Router.Authorization memory a = _auth(p, user);
        bytes memory sig = a.signature;

        Router.Authorization memory short64 = Router.Authorization({ nonce: a.nonce, expiry: a.expiry, signature: "" });
        short64.signature = new bytes(64);
        for (uint256 i = 0; i < 64; ++i) {
            short64.signature[i] = sig[i];
        }
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swap(p, short64);

        Router.Authorization memory long66 =
            Router.Authorization({ nonce: a.nonce, expiry: a.expiry, signature: abi.encodePacked(sig, uint8(0)) });
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swap(p, long66);

        bytes memory flipped = abi.encodePacked(sig);
        flipped[5] = bytes1(uint8(flipped[5]) ^ 0x01);
        Router.Authorization memory flippedByte =
            Router.Authorization({ nonce: a.nonce, expiry: a.expiry, signature: flipped });
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swap(p, flippedByte);

        // r = 0 makes ecrecover return address(0).
        Router.Authorization memory zeroRecovery = Router.Authorization({
            nonce: a.nonce, expiry: a.expiry, signature: abi.encodePacked(bytes32(0), bytes32(uint256(1)), uint8(27))
        });
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swap(p, zeroRecovery);
    }

    function test_SameAuthorizationTwice_Reverts_AndEventFiresOnce() public {
        Router.SwapParams memory p = _baseline();
        Router.Authorization memory a = _auth(p, user);
        bytes32 digest = _digestOf(p, user, a);
        vm.recordLogs();
        vm.prank(user);
        router.swap(p, a);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Router.AuthorizationAlreadyUsed.selector, digest));
        router.swap(p, a);
        uint256 used;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == AuthorizationUsed.selector) ++used;
        }
        assertEq(used, 1);
    }

    function test_SingleDigestRejectedBySwapMulti() public {
        Router.SwapParams memory p = _baseline();
        Router.Authorization memory a = _auth(p, user);
        Router.MultiSwapParams memory m = _baselineMulti();
        // One-element arrays carrying the single swap's economics.
        address[] memory inT = new address[](1);
        inT[0] = p.inputToken;
        uint256[] memory inA = new uint256[](1);
        inA[0] = p.inputAmount;
        address[] memory outT = new address[](1);
        outT[0] = p.outputToken;
        uint256[] memory outQ = new uint256[](1);
        outQ[0] = p.outputQuote;
        uint256[] memory outM = new uint256[](1);
        outM[0] = p.outputMin;
        m.inputTokens = inT;
        m.inputAmounts = inA;
        m.outputTokens = outT;
        m.outputQuotes = outQ;
        m.outputMins = outM;
        m.weirollCommands = p.weirollCommands;
        m.weirollState = p.weirollState;
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swapMulti(m, a);
        // And a multi digest is rejected by `swap`.
        Router.Authorization memory am = _authMulti(m, user);
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swap(p, am);
        // Positive control: the same one-element params execute under the multi digest with the
        // single swap's economics, so the rejections above are signature-driven, not validation-driven.
        vm.prank(user);
        uint256[] memory out = router.swapMulti(m, am);
        assertEq(out.length, 1);
        assertEq(out[0], 895.5e18);
        assertEq(tokenB.balanceOf(receiver), 895.5e18);
        assertEq(tokenB.balanceOf(partner), 4.5e18);
        assertEq(tokenB.balanceOf(address(router)), 50e18);
        assertEq(tokenA.balanceOf(address(router)), 1.5e18);
    }

    function test_Typehashes_MatchTypeStrings_AndDiffer() public view {
        assertEq(router.SWAP_AUTHORIZATION_TYPEHASH(), keccak256(bytes(RouterAuth.SWAP_TYPE)));
        assertEq(router.MULTI_SWAP_AUTHORIZATION_TYPEHASH(), keccak256(bytes(RouterAuth.MULTI_SWAP_TYPE)));
        assertTrue(router.SWAP_AUTHORIZATION_TYPEHASH() != router.MULTI_SWAP_AUTHORIZATION_TYPEHASH());
        assertEq(router.DOMAIN_SEPARATOR(), RouterAuth.domainSeparator(address(router), block.chainid));
    }

    // ------------------------------------------------------------------
    // Signer rotation
    // ------------------------------------------------------------------

    function test_SetSigner_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        router.setSigner(alice, 0);
        // The liquidator can stop swaps (revokeSigner) but never install a key, before or after revoking.
        uint256 maxGrace = router.MAX_SIGNER_GRACE();
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, liquidator));
        router.setSigner(alice, 0);
        vm.prank(liquidator);
        router.revokeSigner();
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, liquidator));
        router.setSigner(liquidator, maxGrace);
        assertEq(router.signer(), address(0));
    }

    function test_SetSigner_GraceAboveMax_Reverts() public {
        uint256 tooLong = router.MAX_SIGNER_GRACE() + 1;
        vm.expectRevert(abi.encodeWithSelector(Router.InvalidGrace.selector, tooLong));
        router.setSigner(alice, tooLong);
    }

    function test_Rotation_OldSignerValidInsideGrace_ThenRejected() public {
        (address newSigner, uint256 newPk) = makeAddrAndKey("new-signer");
        uint256 grace = 600;
        vm.expectEmit(false, false, false, true, address(router));
        emit SignerUpdated(authSigner, newSigner, block.timestamp + grace);
        router.setSigner(newSigner, grace);
        assertEq(router.signer(), newSigner);
        assertEq(router.previousSigner(), authSigner);
        assertEq(router.previousSignerValidUntil(), block.timestamp + grace);

        Router.SwapParams memory p = _baseline();
        // Old key inside the grace window; the event reports which key was accepted.
        Router.Authorization memory oldKey = _auth(p, user);
        vm.expectEmit(true, true, false, true, address(router));
        emit AuthorizationUsed(_digestOf(p, user, oldKey), user, authSigner);
        vm.prank(user);
        router.swap(p, oldKey);

        // Exactly at the boundary: still valid.
        vm.warp(router.previousSignerValidUntil());
        vm.prank(user);
        router.swap(p, _auth(p, user));

        // One second later: rejected; the new key works.
        vm.warp(block.timestamp + 1);
        Router.Authorization memory stale = _auth(p, user);
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swap(p, stale);
        vm.prank(user);
        router.swap(p, _authWith(p, user, newPk, block.timestamp + AUTH_TTL));
    }

    function test_Rotation_ZeroGrace_RejectsOldImmediately() public {
        (address newSigner, uint256 newPk) = makeAddrAndKey("new-signer");
        router.setSigner(newSigner, 0);
        assertEq(router.previousSigner(), address(0));
        assertEq(router.previousSignerValidUntil(), 0);
        Router.SwapParams memory p = _baseline();
        Router.Authorization memory oldKey = _auth(p, user);
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swap(p, oldKey);
        vm.prank(user);
        router.swap(p, _authWith(p, user, newPk, block.timestamp + AUTH_TTL));
    }

    function test_Rotation_DrainMode_OldKeyDrains_ThenSignerNotSet() public {
        router.setSigner(address(0), 600);
        Router.SwapParams memory p = _baseline();
        vm.prank(user);
        router.swap(p, _auth(p, user));
        vm.warp(block.timestamp + 601);
        Router.Authorization memory a = _auth(p, user);
        vm.prank(user);
        vm.expectRevert(Router.SignerNotSet.selector);
        router.swap(p, a);
    }

    function test_Rotation_SecondRotationInsideGrace_DropsOldestKey() public {
        (address k2, uint256 k2Pk) = makeAddrAndKey("k2");
        (address k3, uint256 k3Pk) = makeAddrAndKey("k3");
        router.setSigner(k2, 600);
        router.setSigner(k3, 600);
        assertEq(router.previousSigner(), k2);
        Router.SwapParams memory p = _baseline();
        Router.Authorization memory k1Auth = _auth(p, user);
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swap(p, k1Auth);
        vm.prank(user);
        router.swap(p, _authWith(p, user, k2Pk, block.timestamp + AUTH_TTL));
        vm.prank(user);
        router.swap(p, _authWith(p, user, k3Pk, block.timestamp + AUTH_TTL));
    }

    function test_Rotation_SettingNewKeyDuringDrain_KeepsDrain() public {
        (address k3, uint256 k3Pk) = makeAddrAndKey("k3");
        router.setSigner(address(0), 600);
        uint256 drainUntil = router.previousSignerValidUntil();
        router.setSigner(k3, 0);
        assertEq(router.previousSigner(), authSigner, "drain not cut short");
        assertEq(router.previousSignerValidUntil(), drainUntil);
        Router.SwapParams memory p = _baseline();
        vm.prank(user);
        router.swap(p, _auth(p, user));
        vm.prank(user);
        router.swap(p, _authWith(p, user, k3Pk, block.timestamp + AUTH_TTL));
        // Once the drain ends the old key is rejected while the new key keeps working.
        vm.warp(drainUntil + 1);
        Router.Authorization memory drained = _auth(p, user);
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swap(p, drained);
        vm.prank(user);
        router.swap(p, _authWith(p, user, k3Pk, block.timestamp + AUTH_TTL));
    }

    function test_RevokeSigner_ByLiquidator_AndOwner_NotStranger() public {
        vm.prank(stranger);
        vm.expectRevert(Router.Unauthorized.selector);
        router.revokeSigner();

        vm.expectEmit(false, false, false, true, address(router));
        emit SignerUpdated(authSigner, address(0), 0);
        vm.prank(liquidator);
        router.revokeSigner();
        assertEq(router.signer(), address(0));
        assertEq(router.previousSigner(), address(0));
        Router.SwapParams memory p = _baseline();
        Router.Authorization memory a = _auth(p, user);
        vm.prank(user);
        vm.expectRevert(Router.SignerNotSet.selector);
        router.swap(p, a);

        router.setSigner(authSigner, 0);
        vm.prank(user);
        router.swap(p, _auth(p, user));
        router.revokeSigner(); // owner path
        assertEq(router.signer(), address(0));
    }

    function test_RevokeThenSetSigner_DoesNotResurrectRevokedKey() public {
        (address k2, uint256 k2Pk) = makeAddrAndKey("k2");
        vm.prank(liquidator);
        router.revokeSigner();
        router.setSigner(k2, router.MAX_SIGNER_GRACE());
        assertEq(router.previousSigner(), address(0));
        Router.SwapParams memory p = _baseline();
        Router.Authorization memory revoked = _auth(p, user);
        vm.prank(user);
        vm.expectRevert(Router.InvalidAuthorization.selector);
        router.swap(p, revoked);
        vm.prank(user);
        router.swap(p, _authWith(p, user, k2Pk, block.timestamp + AUTH_TTL));
    }

    function test_Constructor_EmitsSignerUpdated_AndAcceptsZero() public {
        vm.expectEmit(false, false, false, true);
        emit SignerUpdated(address(0), alice, 0);
        new Router(address(this), liquidator, alice);
        Router unset = new Router(address(this), liquidator, address(0));
        assertEq(unset.signer(), address(0));
    }

    // ------------------------------------------------------------------
    // Privileged path
    // ------------------------------------------------------------------

    function test_SwapRouterFunds_NoAuthorizationRequired() public {
        Router.SwapParams memory p = _baseline();
        p.recipient = receiver;
        tokenA.mint(address(router), INPUT_A);
        uint256 out = router.swapRouterFunds(p);
        assertEq(out, 895.5e18);
    }

    // ------------------------------------------------------------------
    // Golden vectors (C0): go-ethereum apitypes, forge eip712HashTypedData, RouterAuth, Router
    // ------------------------------------------------------------------

    address internal constant VEC_ROUTER = 0x1111111111111111111111111111111111111111;
    address internal constant VEC_TAKER = 0x2222222222222222222222222222222222222222;
    address internal constant VEC_RECIPIENT = 0x3333333333333333333333333333333333333333;
    address internal constant VEC_PARTNER = 0x4444444444444444444444444444444444444444;
    address internal constant VEC_A1 = 0xA1A1a1a1A1A1A1A1A1a1a1a1a1a1A1A1a1A1a1a1;
    address internal constant VEC_A2 = 0xa2A2a2A2A2A2A2a2a2a2a2A2A2A2A2a2A2A2a2a2;
    address internal constant VEC_B1 = 0xB1B1B1B1b1B1b1b1b1B1B1B1B1b1b1B1b1b1B1B1;
    address internal constant VEC_B2 = 0xb2b2b2b2b2B2b2B2B2b2b2B2B2b2B2B2b2b2b2b2;
    bytes32 internal constant VEC_NONCE = 0x3333333333333333333333333333333333333333333333333333333333333333;
    uint256 internal constant VEC_EXPIRY = 1700000000;

    bytes32 internal constant GOLDEN_TYPEHASH_SINGLE =
        0x86cf743c31e3888041dd1e79eea05f9aba1282c1ad5c99e9af68cbf10bd58863;
    bytes32 internal constant GOLDEN_TYPEHASH_MULTI =
        0xb60cdd00191dda56c7a530c5767c843274c848d592a3144744a6bdf86cb000c2;
    bytes32 internal constant GOLDEN_DOMAIN = 0x3e74df9ffe8b661a29912f1078b0239dd165835b4c5ac7e6fe4e1ce488616e8f;
    bytes32 internal constant GOLDEN_SINGLE = 0xbc1c8f05f70adf5a06bd2a9608723f3fe642c336e37442cd8545e487a0de31d7;
    bytes32 internal constant GOLDEN_SINGLE_EMPTY_STATE =
        0xfb6521ed8a82d9755ffc037d0c7470e989dc7600a67c4ba849bc4c7334ac6c0c;
    bytes32 internal constant GOLDEN_MULTI = 0xd8b4d9112ca054d4ca927bdb6107e4b745cf59d0276f527043f39613d83ef904;

    string internal constant GOLDEN_SINGLE_JSON =
        "{\"types\":{\"EIP712Domain\":[{\"name\":\"name\",\"type\":\"string\"},{\"name\":\"version\",\"type\":\"string\"},{\"name\":\"chainId\",\"type\":\"uint256\"},{\"name\":\"verifyingContract\",\"type\":\"address\"}],\"MultiSwapAuthorization\":[{\"name\":\"taker\",\"type\":\"address\"},{\"name\":\"inputTokens\",\"type\":\"address[]\"},{\"name\":\"inputAmounts\",\"type\":\"uint256[]\"},{\"name\":\"outputTokens\",\"type\":\"address[]\"},{\"name\":\"outputQuotes\",\"type\":\"uint256[]\"},{\"name\":\"outputMins\",\"type\":\"uint256[]\"},{\"name\":\"recipient\",\"type\":\"address\"},{\"name\":\"protocolFeeBps\",\"type\":\"uint16\"},{\"name\":\"partnerFeeBps\",\"type\":\"uint16\"},{\"name\":\"partnerRecipient\",\"type\":\"address\"},{\"name\":\"partnerFeeOnOutput\",\"type\":\"bool\"},{\"name\":\"passPositiveSlippageToUser\",\"type\":\"bool\"},{\"name\":\"weirollCommands\",\"type\":\"bytes32[]\"},{\"name\":\"weirollState\",\"type\":\"bytes[]\"},{\"name\":\"nonce\",\"type\":\"bytes32\"},{\"name\":\"expiry\",\"type\":\"uint256\"}],\"SwapAuthorization\":[{\"name\":\"taker\",\"type\":\"address\"},{\"name\":\"inputToken\",\"type\":\"address\"},{\"name\":\"inputAmount\",\"type\":\"uint256\"},{\"name\":\"outputToken\",\"type\":\"address\"},{\"name\":\"outputQuote\",\"type\":\"uint256\"},{\"name\":\"outputMin\",\"type\":\"uint256\"},{\"name\":\"recipient\",\"type\":\"address\"},{\"name\":\"protocolFeeBps\",\"type\":\"uint16\"},{\"name\":\"partnerFeeBps\",\"type\":\"uint16\"},{\"name\":\"partnerRecipient\",\"type\":\"address\"},{\"name\":\"partnerFeeOnOutput\",\"type\":\"bool\"},{\"name\":\"passPositiveSlippageToUser\",\"type\":\"bool\"},{\"name\":\"weirollCommands\",\"type\":\"bytes32[]\"},{\"name\":\"weirollState\",\"type\":\"bytes[]\"},{\"name\":\"nonce\",\"type\":\"bytes32\"},{\"name\":\"expiry\",\"type\":\"uint256\"}]},\"primaryType\":\"SwapAuthorization\",\"domain\":{\"name\":\"InfraredRouter\",\"version\":\"1\",\"chainId\":\"0x1\",\"verifyingContract\":\"0x1111111111111111111111111111111111111111\"},\"message\":{\"expiry\":\"1700000000\",\"inputAmount\":\"1000000000000000000000\",\"inputToken\":\"0xa1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1\",\"nonce\":\"0x3333333333333333333333333333333333333333333333333333333333333333\",\"outputMin\":\"850000000000000000000\",\"outputQuote\":\"900000000000000000000\",\"outputToken\":\"0xb2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2\",\"partnerFeeBps\":\"50\",\"partnerFeeOnOutput\":true,\"partnerRecipient\":\"0x4444444444444444444444444444444444444444\",\"passPositiveSlippageToUser\":false,\"protocolFeeBps\":\"15\",\"recipient\":\"0x3333333333333333333333333333333333333333\",\"taker\":\"0x2222222222222222222222222222222222222222\",\"weirollCommands\":[\"0x0101010101010101010101010101010101010101010101010101010101010101\",\"0x0202020202020202020202020202020202020202020202020202020202020202\"],\"weirollState\":[\"0x\",\"0x01\",\"0x0505050505050505050505050505050505050505050505050505050505050505\",\"0x060606060606060606060606060606060606060606060606060606060606060606\"]}}";
    string internal constant GOLDEN_SINGLE_EMPTY_STATE_JSON =
        "{\"types\":{\"EIP712Domain\":[{\"name\":\"name\",\"type\":\"string\"},{\"name\":\"version\",\"type\":\"string\"},{\"name\":\"chainId\",\"type\":\"uint256\"},{\"name\":\"verifyingContract\",\"type\":\"address\"}],\"MultiSwapAuthorization\":[{\"name\":\"taker\",\"type\":\"address\"},{\"name\":\"inputTokens\",\"type\":\"address[]\"},{\"name\":\"inputAmounts\",\"type\":\"uint256[]\"},{\"name\":\"outputTokens\",\"type\":\"address[]\"},{\"name\":\"outputQuotes\",\"type\":\"uint256[]\"},{\"name\":\"outputMins\",\"type\":\"uint256[]\"},{\"name\":\"recipient\",\"type\":\"address\"},{\"name\":\"protocolFeeBps\",\"type\":\"uint16\"},{\"name\":\"partnerFeeBps\",\"type\":\"uint16\"},{\"name\":\"partnerRecipient\",\"type\":\"address\"},{\"name\":\"partnerFeeOnOutput\",\"type\":\"bool\"},{\"name\":\"passPositiveSlippageToUser\",\"type\":\"bool\"},{\"name\":\"weirollCommands\",\"type\":\"bytes32[]\"},{\"name\":\"weirollState\",\"type\":\"bytes[]\"},{\"name\":\"nonce\",\"type\":\"bytes32\"},{\"name\":\"expiry\",\"type\":\"uint256\"}],\"SwapAuthorization\":[{\"name\":\"taker\",\"type\":\"address\"},{\"name\":\"inputToken\",\"type\":\"address\"},{\"name\":\"inputAmount\",\"type\":\"uint256\"},{\"name\":\"outputToken\",\"type\":\"address\"},{\"name\":\"outputQuote\",\"type\":\"uint256\"},{\"name\":\"outputMin\",\"type\":\"uint256\"},{\"name\":\"recipient\",\"type\":\"address\"},{\"name\":\"protocolFeeBps\",\"type\":\"uint16\"},{\"name\":\"partnerFeeBps\",\"type\":\"uint16\"},{\"name\":\"partnerRecipient\",\"type\":\"address\"},{\"name\":\"partnerFeeOnOutput\",\"type\":\"bool\"},{\"name\":\"passPositiveSlippageToUser\",\"type\":\"bool\"},{\"name\":\"weirollCommands\",\"type\":\"bytes32[]\"},{\"name\":\"weirollState\",\"type\":\"bytes[]\"},{\"name\":\"nonce\",\"type\":\"bytes32\"},{\"name\":\"expiry\",\"type\":\"uint256\"}]},\"primaryType\":\"SwapAuthorization\",\"domain\":{\"name\":\"InfraredRouter\",\"version\":\"1\",\"chainId\":\"0x1\",\"verifyingContract\":\"0x1111111111111111111111111111111111111111\"},\"message\":{\"expiry\":\"1700000000\",\"inputAmount\":\"1000000000000000000000\",\"inputToken\":\"0xa1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1\",\"nonce\":\"0x3333333333333333333333333333333333333333333333333333333333333333\",\"outputMin\":\"850000000000000000000\",\"outputQuote\":\"900000000000000000000\",\"outputToken\":\"0xb2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2\",\"partnerFeeBps\":\"50\",\"partnerFeeOnOutput\":true,\"partnerRecipient\":\"0x4444444444444444444444444444444444444444\",\"passPositiveSlippageToUser\":false,\"protocolFeeBps\":\"15\",\"recipient\":\"0x3333333333333333333333333333333333333333\",\"taker\":\"0x2222222222222222222222222222222222222222\",\"weirollCommands\":[\"0x0101010101010101010101010101010101010101010101010101010101010101\"],\"weirollState\":[]}}";
    string internal constant GOLDEN_MULTI_JSON =
        "{\"types\":{\"EIP712Domain\":[{\"name\":\"name\",\"type\":\"string\"},{\"name\":\"version\",\"type\":\"string\"},{\"name\":\"chainId\",\"type\":\"uint256\"},{\"name\":\"verifyingContract\",\"type\":\"address\"}],\"MultiSwapAuthorization\":[{\"name\":\"taker\",\"type\":\"address\"},{\"name\":\"inputTokens\",\"type\":\"address[]\"},{\"name\":\"inputAmounts\",\"type\":\"uint256[]\"},{\"name\":\"outputTokens\",\"type\":\"address[]\"},{\"name\":\"outputQuotes\",\"type\":\"uint256[]\"},{\"name\":\"outputMins\",\"type\":\"uint256[]\"},{\"name\":\"recipient\",\"type\":\"address\"},{\"name\":\"protocolFeeBps\",\"type\":\"uint16\"},{\"name\":\"partnerFeeBps\",\"type\":\"uint16\"},{\"name\":\"partnerRecipient\",\"type\":\"address\"},{\"name\":\"partnerFeeOnOutput\",\"type\":\"bool\"},{\"name\":\"passPositiveSlippageToUser\",\"type\":\"bool\"},{\"name\":\"weirollCommands\",\"type\":\"bytes32[]\"},{\"name\":\"weirollState\",\"type\":\"bytes[]\"},{\"name\":\"nonce\",\"type\":\"bytes32\"},{\"name\":\"expiry\",\"type\":\"uint256\"}],\"SwapAuthorization\":[{\"name\":\"taker\",\"type\":\"address\"},{\"name\":\"inputToken\",\"type\":\"address\"},{\"name\":\"inputAmount\",\"type\":\"uint256\"},{\"name\":\"outputToken\",\"type\":\"address\"},{\"name\":\"outputQuote\",\"type\":\"uint256\"},{\"name\":\"outputMin\",\"type\":\"uint256\"},{\"name\":\"recipient\",\"type\":\"address\"},{\"name\":\"protocolFeeBps\",\"type\":\"uint16\"},{\"name\":\"partnerFeeBps\",\"type\":\"uint16\"},{\"name\":\"partnerRecipient\",\"type\":\"address\"},{\"name\":\"partnerFeeOnOutput\",\"type\":\"bool\"},{\"name\":\"passPositiveSlippageToUser\",\"type\":\"bool\"},{\"name\":\"weirollCommands\",\"type\":\"bytes32[]\"},{\"name\":\"weirollState\",\"type\":\"bytes[]\"},{\"name\":\"nonce\",\"type\":\"bytes32\"},{\"name\":\"expiry\",\"type\":\"uint256\"}]},\"primaryType\":\"MultiSwapAuthorization\",\"domain\":{\"name\":\"InfraredRouter\",\"version\":\"1\",\"chainId\":\"0x1\",\"verifyingContract\":\"0x1111111111111111111111111111111111111111\"},\"message\":{\"expiry\":\"1700000000\",\"inputAmounts\":[\"1000000000000000000000\",\"2000000000000000000000\"],\"inputTokens\":[\"0xa1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1\",\"0xa2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2\"],\"nonce\":\"0x3333333333333333333333333333333333333333333333333333333333333333\",\"outputMins\":[\"850000000000000000000\",\"1700000000000000000000\"],\"outputQuotes\":[\"900000000000000000000\",\"1800000000000000000000\"],\"outputTokens\":[\"0xb1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1\",\"0xb2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2\"],\"partnerFeeBps\":\"50\",\"partnerFeeOnOutput\":true,\"partnerRecipient\":\"0x4444444444444444444444444444444444444444\",\"passPositiveSlippageToUser\":false,\"protocolFeeBps\":\"15\",\"recipient\":\"0x3333333333333333333333333333333333333333\",\"taker\":\"0x2222222222222222222222222222222222222222\",\"weirollCommands\":[\"0x0101010101010101010101010101010101010101010101010101010101010101\",\"0x0202020202020202020202020202020202020202020202020202020202020202\"],\"weirollState\":[\"0x\",\"0x01\",\"0x0505050505050505050505050505050505050505050505050505050505050505\",\"0x060606060606060606060606060606060606060606060606060606060606060606\"]}}";

    function _vecCommands() internal pure returns (bytes32[] memory c) {
        c = new bytes32[](2);
        c[0] = bytes32(uint256(0x0101010101010101010101010101010101010101010101010101010101010101));
        c[1] = bytes32(uint256(0x0202020202020202020202020202020202020202020202020202020202020202));
    }

    function _vecState() internal pure returns (bytes[] memory s) {
        s = new bytes[](4);
        s[0] = "";
        s[1] = hex"01";
        s[2] = new bytes(32);
        s[3] = new bytes(33);
        for (uint256 i = 0; i < 32; ++i) {
            s[2][i] = 0x05;
        }
        for (uint256 i = 0; i < 33; ++i) {
            s[3][i] = 0x06;
        }
    }

    function _vecSingle() internal pure returns (Router.SwapParams memory) {
        return Router.SwapParams({
            inputToken: VEC_A1,
            inputAmount: 1000e18,
            outputToken: VEC_B2,
            outputQuote: 900e18,
            outputMin: 850e18,
            recipient: VEC_RECIPIENT,
            protocolFeeBps: 15,
            partnerFeeBps: 50,
            partnerRecipient: VEC_PARTNER,
            partnerFeeOnOutput: true,
            passPositiveSlippageToUser: false,
            weirollCommands: _vecCommands(),
            weirollState: _vecState()
        });
    }

    function _vecMulti() internal pure returns (Router.MultiSwapParams memory) {
        address[] memory inT = new address[](2);
        inT[0] = VEC_A1;
        inT[1] = VEC_A2;
        uint256[] memory inA = new uint256[](2);
        inA[0] = 1000e18;
        inA[1] = 2000e18;
        address[] memory outT = new address[](2);
        outT[0] = VEC_B1;
        outT[1] = VEC_B2;
        uint256[] memory outQ = new uint256[](2);
        outQ[0] = 900e18;
        outQ[1] = 1800e18;
        uint256[] memory outM = new uint256[](2);
        outM[0] = 850e18;
        outM[1] = 1700e18;
        return Router.MultiSwapParams({
            inputTokens: inT,
            inputAmounts: inA,
            outputTokens: outT,
            outputQuotes: outQ,
            outputMins: outM,
            recipient: VEC_RECIPIENT,
            protocolFeeBps: 15,
            partnerFeeBps: 50,
            partnerRecipient: VEC_PARTNER,
            partnerFeeOnOutput: true,
            passPositiveSlippageToUser: false,
            weirollCommands: _vecCommands(),
            weirollState: _vecState()
        });
    }

    /// @dev Router bytecode at the vector address with chain id 1, so `hashSwapAuthorization`
    ///      reproduces the vector domain exactly.
    function _vecRouter() internal returns (Router) {
        vm.chainId(1);
        deployCodeTo("Router.sol:Router", abi.encode(address(this), liquidator, authSigner), VEC_ROUTER);
        return Router(payable(VEC_ROUTER));
    }

    function test_GoldenDigest_Single() public {
        Router r = _vecRouter();
        Router.SwapParams memory p = _vecSingle();
        assertEq(r.DOMAIN_SEPARATOR(), GOLDEN_DOMAIN, "router domain");
        assertEq(r.hashSwapAuthorization(p, VEC_TAKER, VEC_NONCE, VEC_EXPIRY), GOLDEN_SINGLE, "router");
        assertEq(RouterAuth.swapDigest(VEC_ROUTER, 1, p, VEC_TAKER, VEC_NONCE, VEC_EXPIRY), GOLDEN_SINGLE, "library");
        assertEq(vm.eip712HashTypedData(GOLDEN_SINGLE_JSON), GOLDEN_SINGLE, "forge");
    }

    function test_GoldenDigest_SingleEmptyState() public {
        Router r = _vecRouter();
        Router.SwapParams memory p = _vecSingle();
        bytes32[] memory one = new bytes32[](1);
        one[0] = _vecCommands()[0];
        p.weirollCommands = one;
        p.weirollState = new bytes[](0);
        assertEq(r.hashSwapAuthorization(p, VEC_TAKER, VEC_NONCE, VEC_EXPIRY), GOLDEN_SINGLE_EMPTY_STATE, "router");
        assertEq(
            RouterAuth.swapDigest(VEC_ROUTER, 1, p, VEC_TAKER, VEC_NONCE, VEC_EXPIRY),
            GOLDEN_SINGLE_EMPTY_STATE,
            "library"
        );
        assertEq(vm.eip712HashTypedData(GOLDEN_SINGLE_EMPTY_STATE_JSON), GOLDEN_SINGLE_EMPTY_STATE, "forge");
    }

    function test_GoldenDigest_Multi() public {
        Router r = _vecRouter();
        Router.MultiSwapParams memory p = _vecMulti();
        assertEq(r.hashMultiSwapAuthorization(p, VEC_TAKER, VEC_NONCE, VEC_EXPIRY), GOLDEN_MULTI, "router");
        assertEq(
            RouterAuth.multiSwapDigest(VEC_ROUTER, 1, p, VEC_TAKER, VEC_NONCE, VEC_EXPIRY), GOLDEN_MULTI, "library"
        );
        assertEq(vm.eip712HashTypedData(GOLDEN_MULTI_JSON), GOLDEN_MULTI, "forge");
    }

    function test_GoldenTypehashes() public view {
        assertEq(router.SWAP_AUTHORIZATION_TYPEHASH(), GOLDEN_TYPEHASH_SINGLE);
        assertEq(router.MULTI_SWAP_AUTHORIZATION_TYPEHASH(), GOLDEN_TYPEHASH_MULTI);
        assertEq(vm.eip712HashType(RouterAuth.SWAP_TYPE), GOLDEN_TYPEHASH_SINGLE);
        assertEq(vm.eip712HashType(RouterAuth.MULTI_SWAP_TYPE), GOLDEN_TYPEHASH_MULTI);
    }

    // ------------------------------------------------------------------
    // Utilities
    // ------------------------------------------------------------------

    function _split(bytes memory sig) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        require(sig.length == 65, "sig length");
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
    }
}
