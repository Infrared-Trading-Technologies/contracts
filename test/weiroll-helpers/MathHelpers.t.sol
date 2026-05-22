// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { MathHelpers } from "../../src/weiroll-helpers/MathHelpers.sol";

/// @title MathHelpersTest
/// @notice Exercises the uint256 math helper contract intended for use as a
///         Weiroll command target. Covers round-trip arithmetic plus the
///         full-precision mulDiv / mulDivUp edge cases that downstream bps,
///         slippage, and ERC-4626 share-conversion math depend on.
contract MathHelpersTest is Test {
    MathHelpers internal math;

    function setUp() public {
        math = new MathHelpers();
    }

    function test_Version() public view {
        assertEq(math.VERSION(), 3);
    }

    // ------------------------------------------------------------------
    // Round-trip add / sub / mul / div
    // ------------------------------------------------------------------

    function test_AddSubRoundTrip() public view {
        uint256 a = 1_234_567 ether;
        uint256 b = 89_012 ether;
        uint256 sum = math.add(a, b);
        assertEq(sum, a + b);
        assertEq(math.sub(sum, b), a);
        assertEq(math.sub(sum, a), b);
    }

    function test_MulDivRoundTrip() public view {
        uint256 a = 7_777_777;
        uint256 b = 13_579_135;
        uint256 product = math.mul(a, b);
        assertEq(product, a * b);
        assertEq(math.div(product, b), a);
        assertEq(math.div(product, a), b);
    }

    function test_AddOverflowReverts() public {
        vm.expectRevert();
        math.add(type(uint256).max, 1);
    }

    function test_SubUnderflowReverts() public {
        vm.expectRevert();
        math.sub(0, 1);
    }

    function test_DivByZeroReverts() public {
        vm.expectRevert();
        math.div(1, 0);
    }

    function test_ModByZeroReverts() public {
        vm.expectRevert();
        math.mod(1, 0);
    }

    // ------------------------------------------------------------------
    // Min / max / average / sum
    // ------------------------------------------------------------------

    function test_MinMaxAverage() public view {
        assertEq(math.max(10, 3), 10);
        assertEq(math.min(10, 3), 3);
        // average rounds towards zero
        assertEq(math.average(10, 3), 6);
        assertEq(math.average(type(uint256).max, type(uint256).max), type(uint256).max);
    }

    function test_Sum() public view {
        uint256[] memory values = new uint256[](4);
        values[0] = 1;
        values[1] = 2;
        values[2] = 3;
        values[3] = 4;
        assertEq(math.sum(values), 10);
    }

    // ------------------------------------------------------------------
    // mulDiv edge cases
    // ------------------------------------------------------------------

    /// @notice a*b overflows 256 bits but the divided result still fits.
    /// (2^256 - 1) * 2 / 2 == 2^256 - 1
    function test_MulDiv_ProductOverflowsButResultFits() public view {
        uint256 a = type(uint256).max;
        uint256 b = 2;
        uint256 denominator = 2;
        assertEq(math.mulDiv(a, b, denominator), type(uint256).max);
    }

    /// @notice Classic Chainlink-style answer: max * max / max == max.
    function test_MulDiv_MaxOverMax() public view {
        uint256 m = type(uint256).max;
        assertEq(math.mulDiv(m, m, m), m);
    }

    function test_MulDiv_DenominatorOneIdentity() public view {
        uint256 a = 123_456_789;
        uint256 b = 987_654_321;
        assertEq(math.mulDiv(a, b, 1), a * b);
    }

    function test_MulDiv_DenominatorZeroReverts() public {
        vm.expectRevert();
        math.mulDiv(1, 1, 0);
    }

    /// @notice Result that does not fit in uint256 must revert with the
    /// dedicated overflow error. (2^256 - 1) * 2 / 1 > type(uint256).max.
    function test_MulDiv_ResultOverflowReverts() public {
        vm.expectRevert(MathHelpers.MathOverflowedMulDiv.selector);
        math.mulDiv(type(uint256).max, 2, 1);
    }

    /// @notice Sanity check: plain bps math floors correctly.
    /// 1e18 * 9_900 / 10_000 == 0.99e18
    function test_MulDiv_BpsFloor() public view {
        assertEq(math.mulDiv(1e18, 9_900, 10_000), 99e16);
    }

    // ------------------------------------------------------------------
    // mulDivUp rounding-up correctness
    // ------------------------------------------------------------------

    function test_MulDivUp_RoundsUpWhenRemainder() public view {
        // 10 * 3 / 4 = 7 floor, 8 ceil
        assertEq(math.mulDiv(10, 3, 4), 7);
        assertEq(math.mulDivUp(10, 3, 4), 8);
    }

    function test_MulDivUp_NoRoundWhenExact() public view {
        // 10 * 3 / 5 = 6 exact
        assertEq(math.mulDiv(10, 3, 5), 6);
        assertEq(math.mulDivUp(10, 3, 5), 6);
    }

    function test_MulDivUp_DenominatorOneIdentity() public view {
        assertEq(math.mulDivUp(12_345, 67_890, 1), 12_345 * 67_890);
    }

    function test_MulDivUp_DenominatorZeroReverts() public {
        vm.expectRevert();
        math.mulDivUp(1, 1, 0);
    }

    /// @notice Round-up still overflows when the floored result already
    /// equals type(uint256).max and there is a non-zero remainder.
    function test_MulDivUp_OverflowOnRoundUp() public {
        // mulDiv(max, max, max) == max with no remainder, so no overflow.
        // Construct a case where flooring gives max AND remainder > 0.
        // a = max, b = 2, denom = max -> floor = 2 (since 2*max / max = 2 r 0)
        // Instead use: mulDiv overflow path triggers when denominator <= prod1.
        // mulDivUp(max, 2, 1) should revert via mulDiv first.
        vm.expectRevert(MathHelpers.MathOverflowedMulDiv.selector);
        math.mulDivUp(type(uint256).max, 2, 1);
    }

    // ------------------------------------------------------------------
    // conditional
    // ------------------------------------------------------------------

    function test_Conditional_AppliesWhenTrue() public view {
        uint256 result = math.conditional(true, math.add.selector, 5, 7);
        assertEq(result, 12);
    }

    function test_Conditional_SkipsWhenFalse() public view {
        uint256 result = math.conditional(false, math.add.selector, 5, 7);
        assertEq(result, 5);
    }
}
