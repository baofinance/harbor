// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface ITokenDistributor {
    /****************************
     * Public Mutator Functions *
     ****************************/

    /// @notice distribute owned tokens of all known tokens to all known recipients.
    function distribute() external;
}
