// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

interface ITokenDistributor {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when configuring recipients and shares
    error RecipientsAndSharesDifferentSizes(uint recipientsLength, uint sharesLength); // solhint-disable-line explicit-types

    /// @notice Thrown when an attemt to set a share size to 0. Remove the recipient instead.
    error ShareAmountIsZero(address recipient);

    /// @notice Thrown when a duplicate of a recipient is being configured in the same call.
    /// Attempting to add a recipient which already pre-exists results in that recipient being changed
    error DuplicateRecipient(address recipient);

    /// @notice Thrown when a share value is too high. Maximum size is very high.
    error ShareAmountIsTooHigh(address recipient, uint shares); // solhint-disable-line explicit-types

    /// @notice Thrown when trying to extract a leftover tokens when it is still in use.
    /// Remove the token first.
    error TokenStillInUse(address token);

    /*//////////////////////////////////////////////////////////////
                         PUBLIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice The role needed to be able to distribute
    // solhint-disable-next-line func-name-mixedcase
    function CLAIMER_ROLE() external view returns (uint256);

    /// @notice Returns the name of the contract. The name should indicate the contract's purpose.
    function name() external view returns (string memory name_);

    /// @notice Returns the list of tokens managed
    /// @return tokens_ The list of tokens currently configured
    function tokens() external view returns (address[] memory tokens_);

    /// @notice Returns the distribution {recipient, share} pairs.
    /// @return recipients The list of recipients.
    /// @return shares The corresponding list of shares each recipient holds.
    /// @return totalShares The total of the above shares.
    function distribution()
        external
        view
        returns (
            address[] memory recipients,
            uint256[] memory shares,
            uint totalShares // solhint-disable-line explicit-types
        );

    /*//////////////////////////////////////////////////////////////
                        PUBLIC UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                       PROTECTED UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Adds a token to be managed.
    /// @param token The address of the token to be managed.
    function addToken(address token) external;

    /// @notice Removes a managed token.
    /// If the token is not being managed then there is no error.
    /// @param token The address of the token to be removed.
    function removeToken(address token) external;

    /// @notice Configures the distribution of all the managed tokens.
    /// @param recipients The recipients of a share of the tokens.
    /// @param shares The size of the share the recipient receives.
    function setDistribution(
        address[] calldata recipients,
        uint[] calldata shares // solhint-disable-line explicit-types
    ) external;

    /// @notice Adds a recipient to the list of recipients, with the given number of shares. If the recipient already
    /// exists in the list then the number of shares is adjusted accordingly.
    /// @param recipient The address of the recipient to be added.
    /// @param share The number of shares allocated to the recipient. This number cannot be 0: use the `removeRecipient`
    ///        call to set the shares to 0.
    /// @dev The share of every other recipient remains the same value but the `totalShares` is decreased, effectively
    /// increasing the calculated share of each remaining recipient.
    function addOrUpdateRecipient(address recipient, uint256 share) external;

    /// @notice Removes a recipient from the list of recipients
    /// @param recipient The address of the recipient to be removed.
    /// @dev The share of every other recipient remains the same value but the `totalShares` is decreased, effectively
    /// increasing the calculated share of each remaining recipient.
    function removeRecipient(address recipient) external;

    /// @notice Distributes owned tokens of all known tokens to all known recipients according to the recipient's share
    function distribute() external;
}
