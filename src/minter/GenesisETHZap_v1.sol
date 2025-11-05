// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGenesis} from "src/interfaces/IGenesis.sol";

/// @notice Interface for stETH submit function
interface ISTETH {
    function submit(address referral) external payable returns (uint256);
}

/// @notice Interface for wstETH wrap function (not included in IWstETH view-only interface)
interface IWstETHWrap {
    function wrap(uint256 _stETHAmount) external returns (uint256);
}

/// @title GenesisETHZap
/// @notice One-click zapper for depositing ETH into Genesis contracts via wstETH
/// @dev Enables users to deposit ETH in a single transaction
/// @dev Flow: ETH → stETH → wstETH → Genesis deposit
/// @author Harbor Yield Protocol
contract GenesisETHZap_v1 {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Lido stETH address (mainnet)
    address public constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    /// @notice Lido wstETH address (mainnet)
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    // ============ Immutables ============

    /// @notice Genesis contract address
    address public immutable GENESIS;

    // ============ Events ============

    /// @notice Emitted when ETH is zapped into Genesis
    /// @param user Address that initiated the zap
    /// @param genesis Address of the Genesis contract
    /// @param receiver Address that will receive the Genesis shares
    /// @param ethAmount Amount of ETH deposited
    /// @param wstETHAmount Amount of wstETH received
    /// @param collateralAmount Amount of collateral deposited to Genesis
    event ETHZappedToGenesis(
        address indexed user,
        address indexed genesis,
        address indexed receiver,
        uint256 ethAmount,
        uint256 wstETHAmount,
        uint256 collateralAmount
    );

    // ============ Errors ============

    /// @notice Thrown when zero amount is provided
    error ZeroAmount();

    /// @notice Thrown when contract addresses are invalid
    error InvalidAddress();

    /// @notice Thrown when wstETH address doesn't match Genesis collateral token
    error WstETHMismatch(address expected, address provided);

    // ============ Constructor ============

    /// @notice Constructor sets the Genesis address
    /// @param genesis_ Address of the Genesis contract (must accept wstETH as collateral)
    constructor(address genesis_) {
        if (genesis_ == address(0)) revert InvalidAddress();

        // Verify that wstETH matches the Genesis collateral token
        address expectedCollateral = IGenesis(genesis_).WRAPPED_COLLATERAL_TOKEN();
        if (WSTETH != expectedCollateral) {
            revert WstETHMismatch(expectedCollateral, WSTETH);
        }

        GENESIS = genesis_;
    }

    // ============ External Functions ============

    /// @notice Zap ETH into Genesis contract in one transaction
    /// @dev Flow: ETH → stETH → wstETH → Genesis deposit
    /// @param receiver Address that will receive the Genesis shares
    /// @return collateralAmount Amount of collateral deposited to Genesis
    function zapETHtoGenesis(address receiver) external payable returns (uint256 collateralAmount) {
        if (msg.value == 0) revert ZeroAmount();
        if (receiver == address(0)) revert InvalidAddress();

        uint256 ethAmount = msg.value;

        // 1. ETH → stETH via Lido
        ISTETH stETH = ISTETH(STETH);
        uint256 stETHReceived = stETH.submit{value: ethAmount}(address(0));

        // 2. stETH → wstETH
        IERC20 stETHToken = IERC20(STETH);
        stETHToken.forceApprove(WSTETH, stETHReceived);
        uint256 wstETHAmount = IWstETHWrap(WSTETH).wrap(stETHReceived);

        // 3. wstETH → Genesis deposit
        IERC20 wstETHToken = IERC20(WSTETH);
        wstETHToken.forceApprove(GENESIS, wstETHAmount);
        IGenesis(GENESIS).deposit(wstETHAmount, receiver);
        collateralAmount = wstETHAmount;

        emit ETHZappedToGenesis(msg.sender, GENESIS, receiver, ethAmount, wstETHAmount, collateralAmount);
    }

    // ============ Safety Functions ============

    /// @notice Allow contract to receive ETH
    receive() external payable {
        // Allow receiving ETH for zapETHtoGenesis() function
    }

    /// @notice Fallback function
    fallback() external payable {
        revert("Function not found");
    }
}

