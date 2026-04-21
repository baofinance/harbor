// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LibString} from "@solady/utils/LibString.sol";

/// @dev Formatting helpers for debug logging.
library FmtLib {
    /// @dev Returns "123456789 [1.235e8]" style string for a uint256 (rounded to 3 decimal places).
    function sci(uint256 x) internal pure returns (string memory) {
        if (x == 0) return "0 [0]";
        uint256 e = 0;
        uint256 tmp = x;
        while (tmp >= 10) {
            tmp /= 10;
            e++;
        }
        // Extract top 4 significant digits with rounding
        uint256 top4;
        if (e >= 3) {
            uint256 divisor = 1;
            for (uint256 i = 0; i < e - 3; i++) divisor *= 10;
            top4 = (x + divisor / 2) / divisor;
        } else {
            top4 = x;
            // slither-disable-next-line divide-before-multiply
            for (uint256 i = e; i < 3; i++) top4 *= 10;
        }
        // Rounding may have pushed us to 5 digits (e.g. 9999 + round → 10000)
        if (top4 >= 10000) {
            top4 /= 10;
            e++;
        }
        return
            string.concat(
                LibString.toString(x),
                " [",
                LibString.toString(top4 / 1000),
                ".",
                LibString.toString((top4 % 1000) / 100),
                LibString.toString((top4 % 100) / 10),
                LibString.toString(top4 % 10),
                "e",
                LibString.toString(e),
                "]"
            );
    }
}
