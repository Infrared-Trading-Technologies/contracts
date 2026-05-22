// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { SignedMathHelpers } from "../../src/weiroll-helpers/SignedMathHelpers.sol";

/// @title SignedMathHelpersTest
/// @notice Exercises the int256 math helper contract intended for Weiroll
///         programs that consume signed feeds (e.g. Chainlink answers).
contract SignedMathHelpersTest is Test {
    SignedMathHelpers internal math;

    function setUp() public {
        math = new SignedMathHelpers();
    }

    function test_Version() public view {
        assertEq(math.VERSION(), 1);
    }

    // ------------------------------------------------------------------
    // Round-trip add / sub / mul / div with sign handling
    // ------------------------------------------------------------------

    function test_AddSubRoundTripCrossingZero() public view {
        int256 a = -50;
        int256 b = 200;
        int256 sum = math.add(a, b);
        assertEq(sum, 150);
        assertEq(math.sub(sum, b), a);
        assertEq(math.sub(sum, a), b);
    }

    function test_MulDivWithNegative() public view {
        int256 a = -7;
        int256 b = 13;
        int256 product = math.mul(a, b);
        assertEq(product, -91);
        // Solidity int division truncates towards zero
        assertEq(math.div(product, b), a);
        assertEq(math.div(product, a), b);
    }

    function test_AddOverflowReverts() public {
        vm.expectRevert();
        math.add(type(int256).max, 1);
    }

    function test_SubUnderflowReverts() public {
        vm.expectRevert();
        math.sub(type(int256).min, 1);
    }

    function test_DivByZeroReverts() public {
        vm.expectRevert();
        math.div(1, 0);
    }

    // ------------------------------------------------------------------
    // min / max / average sign handling
    // ------------------------------------------------------------------

    function test_MaxMin_AcrossSign() public view {
        assertEq(math.max(-5, 3), 3);
        assertEq(math.min(-5, 3), -5);
        assertEq(math.max(-10, -3), -3);
        assertEq(math.min(-10, -3), -10);
    }

    /// @notice Sign-handling: average of mixed-sign rounds towards zero.
    function test_Average_RoundsTowardsZero() public view {
        assertEq(math.average(-3, 3), 0);
        // (-5 + 3) / 2 = -1 (rounded toward zero, not -infinity)
        assertEq(math.average(-5, 3), -1);
        // (-5 + -3) / 2 = -4
        assertEq(math.average(-5, -3), -4);
    }

    // ------------------------------------------------------------------
    // abs sign-handling — the single int256 sign-handling case required
    // ------------------------------------------------------------------

    function test_Abs_PositiveAndNegative() public view {
        assertEq(math.abs(42), 42);
        assertEq(math.abs(-42), 42);
        assertEq(math.abs(0), 0);
    }

    /// @notice abs(type(int256).min) cannot be represented as an int256
    /// (-(-2^255) would overflow), but the unchecked block lets the bit
    /// pattern survive the cast back to uint256.
    function test_Abs_Int256MinHandledViaUnchecked() public view {
        assertEq(math.abs(type(int256).min), uint256(1) << 255);
    }

    // ------------------------------------------------------------------
    // conditional
    // ------------------------------------------------------------------

    function test_Conditional_AppliesWhenTrue() public view {
        int256 result = math.conditional(true, math.add.selector, -10, 25);
        assertEq(result, 15);
    }

    function test_Conditional_SkipsWhenFalse() public view {
        int256 result = math.conditional(false, math.add.selector, -10, 25);
        assertEq(result, -10);
    }
}
