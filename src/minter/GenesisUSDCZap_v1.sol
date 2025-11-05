// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGenesis} from "src/interfaces/IGenesis.sol";

/// @notice Interface for the diamond contract's depositToFxSave function
interface IFxUSDDiamond {
    struct ConvertInParams {
        address tokenIn;
        uint256 amount;
        address target;
        bytes data;
        uint256 minOut;
        bytes signature;
    }
    
    function depositToFxSave(
        ConvertInParams memory params,
        address tokenOut,
        uint256 minShares,
        address receiver
    ) external payable;
}

/// @title GenesisUSDCZap
/// @notice One-click zapper for depositing USDC into Genesis contracts via fxSAVE
/// @dev Enables users to deposit USDC in a single transaction
/// @dev Flow: USDC → fxSAVE → Genesis deposit
/// @author Harbor Yield Protocol
contract GenesisUSDCZap_v1 {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice USDC address (mainnet)
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @notice fxSAVE vault address (mainnet)
    address public constant FXSAVE = 0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39;

    /// @notice fxUSD Diamond contract address (handles deposits to fxSAVE)
    address public constant FXUSD_DIAMOND = 0x33636D49FbefBE798e15e7F356E8DBef543CC708;

    /// @notice fxUSD swap router/converter address (for USDC deposits)
    address public constant FXUSD_SWAP_ROUTER = 0x12AF4529129303D7FbD2563E242C4a2890525912;

    // ============ Immutables ============

    /// @notice Genesis contract address
    address public immutable GENESIS;

    // ============ Events ============

    /// @notice Emitted when USDC is zapped into Genesis
    /// @param user Address that initiated the zap
    /// @param genesis Address of the Genesis contract
    /// @param receiver Address that will receive the Genesis shares
    /// @param usdcAmount Amount of USDC deposited
    /// @param fxSAVEAmount Amount of fxSAVE received
    /// @param collateralAmount Amount of collateral deposited to Genesis
    event USDCZappedToGenesis(
        address indexed user,
        address indexed genesis,
        address indexed receiver,
        uint256 usdcAmount,
        uint256 fxSAVEAmount,
        uint256 collateralAmount
    );

    // ============ Errors ============

    /// @notice Thrown when zero amount is provided
    error ZeroAmount();

    /// @notice Thrown when contract addresses are invalid
    error InvalidAddress();

    /// @notice Thrown when fxSAVE address doesn't match Genesis collateral token
    error CollateralMismatch(address expected, address provided);

    // ============ Constructor ============

    /// @notice Constructor sets the Genesis address
    /// @param genesis_ Address of the Genesis contract (must accept fxSAVE as collateral)
    constructor(address genesis_) {
        if (genesis_ == address(0)) revert InvalidAddress();

        // Verify that fxSAVE matches the Genesis collateral token
        address expectedCollateral = IGenesis(genesis_).WRAPPED_COLLATERAL_TOKEN();
        if (FXSAVE != expectedCollateral) {
            revert CollateralMismatch(expectedCollateral, FXSAVE);
        }

        GENESIS = genesis_;
    }

    // ============ External Functions ============

    /// @notice Zap USDC into Genesis contract in one transaction
    /// @dev Flow: USDC → fxSAVE → Genesis deposit
    /// @param usdcAmount Amount of USDC to zap
    /// @param receiver Address that will receive the Genesis shares
    /// @return collateralAmount Amount of collateral deposited to Genesis
    function zapUSDCtoGenesis(uint256 usdcAmount, address receiver) external returns (uint256 collateralAmount) {
        if (usdcAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert InvalidAddress();

        // 1. Pull USDC from user
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), usdcAmount);

        // 2. USDC → fxSAVE via diamond contract
        // Approve diamond contract to spend USDC
        IERC20 usdcToken = IERC20(USDC);
        // Reset allowance to 0 first (required for some tokens like USDC)
        if (usdcToken.allowance(address(this), FXUSD_DIAMOND) > 0) {
            usdcToken.forceApprove(FXUSD_DIAMOND, 0);
        }
        usdcToken.forceApprove(FXUSD_DIAMOND, usdcAmount);
        
        // Call depositToFxSave on the diamond contract
        // Based on working transaction, target must be the swap router address
        // The data field contains encoded swap parameters
        bytes memory swapData = abi.encodeWithSelector(
            0xed52d54c, // swap function selector
            USDC, // tokenIn
            usdcAmount, // amountIn
            uint256(0), // amountOutMin (0 for no slippage protection)
            "" // path (empty for direct USDC)
        );
        
        IFxUSDDiamond.ConvertInParams memory params = IFxUSDDiamond.ConvertInParams({
            tokenIn: USDC,
            amount: usdcAmount,
            target: FXUSD_SWAP_ROUTER, // Swap router address (required for conversion)
            data: swapData, // Swap data for converting USDC
            minOut: 0, // No minimum output
            signature: "" // No signature needed
        });
        
        // Get fxSAVE balance before deposit
        uint256 fxSAVEBalanceBefore = IERC20(FXSAVE).balanceOf(address(this));
        
        // Deposit via diamond contract
        // tokenOut is USDC (as shown in the example transaction data)
        IFxUSDDiamond(FXUSD_DIAMOND).depositToFxSave{value: 0}(
            params,
            USDC, // tokenOut: USDC (as per the example transaction)
            0, // minShares: 0 (no slippage protection for now)
            address(this) // receiver: zap contract receives fxSAVE shares
        );
        
        // Calculate fxSAVE amount received
        uint256 fxSAVEAmount = IERC20(FXSAVE).balanceOf(address(this)) - fxSAVEBalanceBefore;

        // 3. fxSAVE → Genesis deposit
        IERC20 fxsaveToken = IERC20(FXSAVE);
        fxsaveToken.forceApprove(GENESIS, fxSAVEAmount);
        IGenesis(GENESIS).deposit(fxSAVEAmount, receiver);
        collateralAmount = fxSAVEAmount;

        emit USDCZappedToGenesis(msg.sender, GENESIS, receiver, usdcAmount, fxSAVEAmount, collateralAmount);
    }
}

