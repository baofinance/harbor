// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

interface ITokenOwner {
    /**
     * @notice emits when a token has been sweeped
     * @param token the token being sweeped
     * @param amount amount of given token sweeped
     * @param to address the tokens have been transferred to
     */
    event Swept(address token, uint256 amount, address to);

    /****************************
     * Public Mutator Functions *
     ****************************/
    function sweep(address token, uint256 amount, address receiver) external;
}
