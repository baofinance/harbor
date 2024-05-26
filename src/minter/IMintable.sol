// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface IMintable {
    /****************************
     * Public Mutated Functions *
     ****************************/

    /// @notice Mint some token to someone.
    /// @param to The address of recipient.
    /// @param amount The amount of token to mint.
    function mint(address to, uint256 amount) external;
}

interface IBurnable {
    /****************************
     * Public Mutated Functions *
     ****************************/

    /// @notice Burn some token from someone.
    /// @param from The address of owner to burn.
    /// @param amount The amount of token to burn.
    function burn(address from, uint256 amount) external;
}

interface IBurnableNoAddress {
    /****************************
     * Public Mutated Functions *
     ****************************/

    /// @notice Burn some token from someone.
    /// @param amount The amount of token to burn.
    function burn(uint256 amount) external;
}
