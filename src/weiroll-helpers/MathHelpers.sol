// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @dev Stateless uint256 math helpers intended as Weiroll command targets.
 *
 * Based on OpenZeppelin Contracts v4.7.3:
 * - utils/math/Math.sol
 * (https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/math/Math.sol)
 * - utils/math/SafeMath.sol
 * (https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/math/SafeMath.sol)
 */
contract MathHelpers {
    uint256 public constant VERSION = 3;

    error MathOverflowedMulDiv();

    /**
     * @dev Returns the largest of two numbers.
     */
    function max(uint256 a, uint256 b) external pure returns (uint256) {
        return a >= b ? a : b;
    }

    /**
     * @dev Returns the smallest of two numbers.
     */
    function min(uint256 a, uint256 b) external pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @dev Returns the average of two numbers. The result is rounded towards
     * zero.
     */
    function average(uint256 a, uint256 b) external pure returns (uint256) {
        return (a & b) + (a ^ b) / 2;
    }

    /**
     * @dev Returns the addition of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `+` operator.
     *
     * Requirements:
     *
     * - Addition cannot overflow.
     */
    function add(uint256 a, uint256 b) external pure returns (uint256) {
        return a + b;
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting on
     * overflow (when the result is negative).
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     *
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b) external pure returns (uint256) {
        return a - b;
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `*` operator.
     *
     * Requirements:
     *
     * - Multiplication cannot overflow.
     */
    function mul(uint256 a, uint256 b) external pure returns (uint256) {
        return a * b;
    }

    /**
     * @dev Returns the integer division of two unsigned integers, reverting on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator.
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b) external pure returns (uint256) {
        return a / b;
    }

    /**
     * @dev Returns the sum of an array of unsigned integers.
     *
     * Requirements:
     *
     * - Addition cannot overflow.
     */
    function sum(uint256[] memory values) external pure returns (uint256 total) {
        uint256 length = values.length;
        for (uint256 i = 0; i < length; ++i) {
            total += values[i];
        }
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * reverting when dividing by zero.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b) external pure returns (uint256) {
        return a % b;
    }

    /**
     * @notice Calculates floor(a * b / denominator) with full precision. Reverts if result
     * overflows a uint256 or denominator == 0.
     * @dev Original credit to Remco Bloemen under MIT license (https://xn--2-umb.com/21/muldiv)
     * with further edits by Uniswap Labs and OpenZeppelin, also under MIT license.
     */
    function mulDiv(uint256 a, uint256 b, uint256 denominator) public pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = a * b. Compute the product mod 2^256 and mod 2^256 - 1, then use
            // the Chinese Remainder Theorem to reconstruct the 512 bit result. The result is stored in two 256
            // variables such that product = prod1 * 2^256 + prod0.
            uint256 prod0 = a * b; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly {
                let mm := mulmod(a, b, not(0))
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases, 256 by 256 division.
            if (prod1 == 0) {
                // Solidity will revert if denominator == 0, unlike the div opcode on its own.
                // The surrounding unchecked block does not change this fact.
                // See https://docs.soliditylang.org/en/latest/control-structures.html#checked-or-unchecked-arithmetic.
                return prod0 / denominator;
            }

            // Make sure the result is less than 2^256. Also prevents denominator == 0.
            if (denominator <= prod1) {
                revert MathOverflowedMulDiv();
            }

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [prod1 prod0].
            uint256 remainder;
            assembly {
                // Compute remainder using mulmod.
                remainder := mulmod(a, b, denominator)

                // Subtract 256 bit number from 512 bit number.
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator and compute largest power of two divisor of denominator.
            // Always >= 1. See https://cs.stackexchange.com/q/138556/92363.

            uint256 twos = denominator & (0 - denominator);
            assembly {
                // Divide denominator by twos.
                denominator := div(denominator, twos)

                // Divide [prod1 prod0] by twos.
                prod0 := div(prod0, twos)

                // Flip twos such that it is 2^256 / twos. If twos is zero, then it becomes one.
                twos := add(div(sub(0, twos), twos), 1)
            }

            // Shift in bits from prod1 into prod0.
            prod0 |= prod1 * twos;

            // Invert denominator mod 2^256. Now that denominator is an odd number, it has an inverse modulo 2^256
            // such that denominator * inv = 1 mod 2^256. Compute the inverse by starting with a seed that is
            // correct for four bits. That is, denominator * inv = 1 mod 2^4.
            uint256 inverse = (3 * denominator) ^ 2;

            // Use the Newton-Raphson iteration to improve the precision. Thanks to Hensel's lifting lemma, this
            // also works in modular arithmetic, doubling the correct bits in each step.
            inverse *= 2 - denominator * inverse; // inverse mod 2^8
            inverse *= 2 - denominator * inverse; // inverse mod 2^16
            inverse *= 2 - denominator * inverse; // inverse mod 2^32
            inverse *= 2 - denominator * inverse; // inverse mod 2^64
            inverse *= 2 - denominator * inverse; // inverse mod 2^128
            inverse *= 2 - denominator * inverse; // inverse mod 2^256

            // Because the division is now exact we can divide by multiplying with the modular inverse of
            // denominator. This will give us the correct result modulo 2^256. Since the preconditions guarantee
            // that the outcome is less than 2^256, this is the final result. We don't need to compute the high
            // bits of the result and prod1 is no longer required.
            result = prod0 * inverse;
            return result;
        }
    }

    /**
     * @notice Calculates ceil(a * b / denominator) with full precision. Reverts if result
     * overflows a uint256 or denominator == 0.
     */
    function mulDivUp(uint256 a, uint256 b, uint256 denominator) external pure returns (uint256) {
        uint256 result = mulDiv(a, b, denominator);
        if (mulmod(a, b, denominator) > 0) {
            result += 1;
        }
        return result;
    }

    /**
     * @dev Returns the results a math operation if a condition is met. Otherwise returns the 'a' value without any
     * modification.
     */
    function conditional(bool condition, bytes4 method, uint256 a, uint256 b) external view returns (uint256) {
        if (condition) {
            (bool success, bytes memory n) = address(this).staticcall(abi.encodeWithSelector(method, a, b));
            if (success) return abi.decode(n, (uint256));
        }
        return a;
    }
}
