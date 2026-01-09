// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice Shared minter fee receiver parameters.
/// @dev Pure helpers so market configs can inherit without pulling chain context.
abstract contract Config_Minter_Common {
    function feeReceiverName() public pure returns (string memory) {
        return "Minter Fee Receiver";
    }

    function feeReceiverTokens() public pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = wrappedCollateral();
    }

    function feeReceiverRecipients() public pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = treasury();
    }

    function feeReceiverShares() public pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = 1e18;
    }

    // To be supplied by concrete market configs
    function wrappedCollateral() public pure virtual returns (address);
    function treasury() public pure virtual returns (address);
}
