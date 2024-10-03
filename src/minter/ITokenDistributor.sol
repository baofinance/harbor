// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITokenDistributor {
    /*//////////////////////////////////////////////////////////////
                        PUBLIC UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Distributes owned tokens of all known tokens to all known recipients according to the recipient's share
    function distribute() external;
}
