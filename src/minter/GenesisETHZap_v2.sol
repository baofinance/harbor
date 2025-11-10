// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "src/util/ReentrancyGuard.sol";
import {IGenesis} from "src/interfaces/IGenesis.sol";

/// @notice Interface for stETH submit function
interface ISTETHV2 {
    function submit(address referral) external payable returns (uint256);
}

/// @notice Interface for wstETH wrap function (not included in IWstETH view-only interface)
interface IWstETHWrapV2 {
    function wrap(uint256 stEthAmount) external returns (uint256);
}

/// @title GenesisETHZapV2
/// @notice One-click zapper for depositing ETH into Genesis contracts via wstETH
/// @dev Enables users to deposit ETH in a single transaction
/// @dev Flow: ETH → stETH → wstETH → Genesis deposit
/// @author Harbor Yield Protocol
contract GenesisETHZapV2 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Lido stETH address (mainnet)
    address public constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    /// @notice Lido wstETH address (mainnet)
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    /// @notice Default referral address for Lido deposits
    address public constant DEFAULT_REFERRAL = 0x3dFc49e5112005179Da613BdE5973229082dAc35;

    // ============ Immutables ============

    /// @notice Genesis contract address
    address public immutable GENESIS;

    // ============ Configurable ============

    address public owner;
    address public referral;

    // ============ Events ============

    /// @notice Emitted when ETH is zapped into Genesis
    /// @param user Address that initiated the zap
    /// @param genesis Address of the Genesis contract
    /// @param receiver Address that will receive the Genesis shares
    /// @param ethAmount Amount of ETH deposited
    /// @param wstEthAmount Amount of wstETH received
    /// @param collateralAmount Amount of collateral deposited to Genesis
    event ETHZappedToGenesis(
        address indexed user,
        address indexed genesis,
        address indexed receiver,
        uint256 ethAmount,
        uint256 wstEthAmount,
        uint256 collateralAmount
    );

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ReferralUpdated(address indexed oldReferral, address indexed newReferral);

    // ============ Errors ============

    /// @notice Thrown when zero amount is provided
    error ZeroAmount();

    /// @notice Thrown when contract addresses are invalid
    error InvalidAddress();

    /// @notice Thrown when wstETH address doesn't match Genesis collateral token
    error WstETHMismatch(address expected, address provided);

    error Unauthorized();
    error FunctionNotFound();

    // ============ Constructor ============

    /// @notice Constructor sets the Genesis address
    /// @param genesis_ Address of the Genesis contract (must accept wstETH as collateral)
    /// @param referral_ Lido referral address (or address(0))
    constructor(address genesis_, address referral_) {
        if (genesis_ == address(0)) revert InvalidAddress();

        // Verify that wstETH matches the Genesis collateral token
        address expectedCollateral = IGenesis(genesis_).WRAPPED_COLLATERAL_TOKEN();
        if (WSTETH != expectedCollateral) {
            revert WstETHMismatch(expectedCollateral, WSTETH);
        }

        GENESIS = genesis_;
        owner = msg.sender;

        address initialReferral = referral_ == address(0) ? DEFAULT_REFERRAL : referral_;
        referral = initialReferral;

        emit OwnershipTransferred(address(0), msg.sender);
        emit ReferralUpdated(address(0), initialReferral);
    }

    // ============ Modifiers ============

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    function _checkOwner() internal view {
        if (msg.sender != owner) revert Unauthorized();
    }

    // ============ External Functions ============

    /// @notice Zap ETH into Genesis contract in one transaction
    /// @dev Flow: ETH → stETH → wstETH → Genesis deposit
    /// @param receiver Address that will receive the Genesis shares
    /// @return collateralAmount Amount of collateral deposited to Genesis
    function zapEthToGenesis(address receiver) external payable nonReentrant returns (uint256 collateralAmount) {
        if (msg.value == 0) revert ZeroAmount();
        if (receiver == address(0)) revert InvalidAddress();

        uint256 ethAmount = msg.value;

        // 1. ETH → stETH via Lido
        uint256 stEthReceived = ISTETHV2(STETH).submit{value: ethAmount}(referral);

        // 2. stETH → wstETH
        IERC20(STETH).forceApprove(WSTETH, stEthReceived);
        uint256 wstEthAmount = IWstETHWrapV2(WSTETH).wrap(stEthReceived);

        // 3. wstETH → Genesis deposit
        IERC20(WSTETH).forceApprove(GENESIS, wstEthAmount);
        IGenesis(GENESIS).deposit(wstEthAmount, receiver);

        collateralAmount = wstEthAmount;

        emit ETHZappedToGenesis(msg.sender, GENESIS, receiver, ethAmount, wstEthAmount, collateralAmount);

        // Reset allowances after interactions
        IERC20(STETH).forceApprove(WSTETH, 0);
        IERC20(WSTETH).forceApprove(GENESIS, 0);
    }

    // ============ Owner Functions ============

    function setReferral(address newReferral) external onlyOwner {
        emit ReferralUpdated(referral, newReferral);
        referral = newReferral;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function rescueEth() external onlyOwner {
        payable(owner).transfer(address(this).balance);
    }

    function rescueToken(address token) external onlyOwner {
        IERC20(token).safeTransfer(owner, IERC20(token).balanceOf(address(this)));
    }

    // ============ Safety Functions ============

    receive() external payable {
        // Allow receiving ETH for zapEthToGenesis() function
    }

    fallback() external payable {
        revert FunctionNotFound();
    }
}
