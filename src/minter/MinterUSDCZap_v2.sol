// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "src/util/ReentrancyGuard.sol";
import {IMinter} from "src/interfaces/IMinter.sol";

/// @notice Interface for the diamond contract's depositToFxSave function
interface IFxUSDDiamondV2 {
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

/// @title MinterUSDCZapV2
/// @notice One-click zapper for minting pegged or leveraged tokens with USDC or fxUSD via fxSAVE
/// @dev Enables users to mint pegged or leveraged tokens in a single transaction
/// @dev Flow: USDC/fxUSD → fxSAVE → Minter mint
/// @author Harbor Yield Protocol
contract MinterUSDCZapV2 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice USDC address (mainnet)
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @notice fxSAVE vault address (mainnet)
    address public constant FXSAVE = 0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39;

    /// @notice fxUSD Diamond contract address (handles deposits to fxSAVE)
    address public constant FXUSD_DIAMOND = 0x33636D49FbefBE798e15e7F356E8DBef543CC708;

    /// @notice fxUSD swap router/converter address (for USDC and fxUSD deposits)
    address public constant FXUSD_SWAP_ROUTER = 0x12AF4529129303D7FbD2563E242C4a2890525912;

    /// @notice fxUSD token address (mainnet)
    address public constant FXUSD = 0x085780639CC2cACd35E474e71f4d000e2405d8f6;

    // ============ Immutables ============

    /// @notice Minter contract address
    address public immutable MINTER;

    // ============ Configurable ============

    address public owner;

    // ============ Events ============

    /// @notice Emitted when USDC is zapped to mint pegged tokens
    /// @param user Address that initiated the zap
    /// @param minter Address of the Minter contract
    /// @param receiver Address that will receive the pegged tokens
    /// @param usdcAmount Amount of USDC deposited
    /// @param fxSaveAmount Amount of fxSAVE received
    /// @param peggedOut Amount of pegged tokens minted
    event USDCZappedToPegged(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 usdcAmount,
        uint256 fxSaveAmount,
        uint256 peggedOut
    );

    /// @notice Emitted when USDC is zapped to mint leveraged tokens
    /// @param user Address that initiated the zap
    /// @param minter Address of the Minter contract
    /// @param receiver Address that will receive the leveraged tokens
    /// @param usdcAmount Amount of USDC deposited
    /// @param fxSaveAmount Amount of fxSAVE received
    /// @param leveragedOut Amount of leveraged tokens minted
    event USDCZappedToLeveraged(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 usdcAmount,
        uint256 fxSaveAmount,
        uint256 leveragedOut
    );

    /// @notice Emitted when fxUSD is zapped to mint pegged tokens
    /// @param user Address that initiated the zap
    /// @param minter Address of the Minter contract
    /// @param receiver Address that will receive the pegged tokens
    /// @param fxUsdAmount Amount of fxUSD deposited
    /// @param fxSaveAmount Amount of fxSAVE received
    /// @param peggedOut Amount of pegged tokens minted
    event FXUSDZappedToPegged(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 fxUsdAmount,
        uint256 fxSaveAmount,
        uint256 peggedOut
    );

    /// @notice Emitted when fxUSD is zapped to mint leveraged tokens
    /// @param user Address that initiated the zap
    /// @param minter Address of the Minter contract
    /// @param receiver Address that will receive the leveraged tokens
    /// @param fxUsdAmount Amount of fxUSD deposited
    /// @param fxSaveAmount Amount of fxSAVE received
    /// @param leveragedOut Amount of leveraged tokens minted
    event FXUSDZappedToLeveraged(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 fxUsdAmount,
        uint256 fxSaveAmount,
        uint256 leveragedOut
    );

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ============ Errors ============

    /// @notice Thrown when zero amount is provided
    error ZeroAmount();

    /// @notice Thrown when contract addresses are invalid
    error InvalidAddress();

    /// @notice Thrown when fxSAVE address doesn't match Minter wrapped collateral token
    error CollateralMismatch(address expected, address provided);

    error Unauthorized();
    error FunctionNotFound();

    // ============ Constructor ============

    /// @notice Constructor sets the Minter address
    /// @param minter_ Address of the Minter contract (must accept fxSAVE as wrapped collateral)
    constructor(address minter_) {
        if (minter_ == address(0)) revert InvalidAddress();

        // Verify that fxSAVE matches the Minter wrapped collateral token
        address expectedCollateral = IMinter(minter_).WRAPPED_COLLATERAL_TOKEN();
        if (FXSAVE != expectedCollateral) {
            revert CollateralMismatch(expectedCollateral, FXSAVE);
        }

        MINTER = minter_;
        owner = msg.sender;

        emit OwnershipTransferred(address(0), msg.sender);
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

    /// @notice Zap USDC into pegged tokens in one transaction
    /// @dev Flow: USDC → fxSAVE → Minter mint pegged
    /// @param usdcAmount Amount of USDC to zap
    /// @param receiver Address that will receive the pegged tokens
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @return peggedOut Amount of pegged tokens minted
    function zapUsdcToPegged(
        uint256 usdcAmount,
        address receiver,
        uint256 minPeggedOut
    ) external nonReentrant returns (uint256 peggedOut) {
        if (usdcAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert InvalidAddress();

        // 1. Pull USDC from user
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), usdcAmount);

        // 2. USDC → fxSAVE via diamond contract
        IERC20 usdcToken = IERC20(USDC);

        if (usdcToken.allowance(address(this), FXUSD_DIAMOND) > 0) {
            usdcToken.forceApprove(FXUSD_DIAMOND, 0);
        }
        usdcToken.forceApprove(FXUSD_DIAMOND, usdcAmount);

        bytes memory swapData = abi.encodeWithSelector(0xed52d54c, USDC, usdcAmount, uint256(0), "");

        IFxUSDDiamondV2.ConvertInParams memory params = IFxUSDDiamondV2.ConvertInParams({
            tokenIn: USDC,
            amount: usdcAmount,
            target: FXUSD_SWAP_ROUTER,
            data: swapData,
            minOut: 0,
            signature: ""
        });

        uint256 fxSaveBalanceBefore = IERC20(FXSAVE).balanceOf(address(this));

        IFxUSDDiamondV2(FXUSD_DIAMOND).depositToFxSave{value: 0}(params, USDC, 0, address(this));

        uint256 fxSaveAmount = IERC20(FXSAVE).balanceOf(address(this)) - fxSaveBalanceBefore;

        // 3. fxSAVE → Minter mint pegged
        IERC20(FXSAVE).forceApprove(MINTER, fxSaveAmount);
        peggedOut = IMinter(MINTER).mintPeggedToken(fxSaveAmount, receiver, minPeggedOut);

        emit USDCZappedToPegged(msg.sender, MINTER, receiver, usdcAmount, fxSaveAmount, peggedOut);

        // Reset allowances to limit exposure
        usdcToken.forceApprove(FXUSD_DIAMOND, 0);
        IERC20(FXSAVE).forceApprove(MINTER, 0);
    }

    /// @notice Zap USDC into leveraged tokens in one transaction
    /// @dev Flow: USDC → fxSAVE → Minter mint leveraged
    /// @param usdcAmount Amount of USDC to zap
    /// @param receiver Address that will receive the leveraged tokens
    /// @param minLeveragedOut Minimum amount of leveraged tokens to receive
    /// @return leveragedOut Amount of leveraged tokens minted
    function zapUsdcToLeveraged(
        uint256 usdcAmount,
        address receiver,
        uint256 minLeveragedOut
    ) external nonReentrant returns (uint256 leveragedOut) {
        if (usdcAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert InvalidAddress();

        // 1. Pull USDC from user
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), usdcAmount);

        // 2. USDC → fxSAVE via diamond contract
        IERC20 usdcToken = IERC20(USDC);

        if (usdcToken.allowance(address(this), FXUSD_DIAMOND) > 0) {
            usdcToken.forceApprove(FXUSD_DIAMOND, 0);
        }
        usdcToken.forceApprove(FXUSD_DIAMOND, usdcAmount);

        bytes memory swapData = abi.encodeWithSelector(0xed52d54c, USDC, usdcAmount, uint256(0), "");

        IFxUSDDiamondV2.ConvertInParams memory params = IFxUSDDiamondV2.ConvertInParams({
            tokenIn: USDC,
            amount: usdcAmount,
            target: FXUSD_SWAP_ROUTER,
            data: swapData,
            minOut: 0,
            signature: ""
        });

        uint256 fxSaveBalanceBefore = IERC20(FXSAVE).balanceOf(address(this));

        IFxUSDDiamondV2(FXUSD_DIAMOND).depositToFxSave{value: 0}(params, USDC, 0, address(this));

        uint256 fxSaveAmount = IERC20(FXSAVE).balanceOf(address(this)) - fxSaveBalanceBefore;

        // 3. fxSAVE → Minter mint leveraged
        IERC20(FXSAVE).forceApprove(MINTER, fxSaveAmount);
        leveragedOut = IMinter(MINTER).mintLeveragedToken(fxSaveAmount, receiver, minLeveragedOut);

        emit USDCZappedToLeveraged(msg.sender, MINTER, receiver, usdcAmount, fxSaveAmount, leveragedOut);

        // Reset allowances to limit exposure
        usdcToken.forceApprove(FXUSD_DIAMOND, 0);
        IERC20(FXSAVE).forceApprove(MINTER, 0);
    }

    /// @notice Zap fxUSD into pegged tokens in one transaction
    /// @dev Flow: fxUSD → fxSAVE → Minter mint pegged
    /// @param fxUsdAmount Amount of fxUSD to zap
    /// @param receiver Address that will receive the pegged tokens
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @return peggedOut Amount of pegged tokens minted
    function zapFxUsdToPegged(
        uint256 fxUsdAmount,
        address receiver,
        uint256 minPeggedOut
    ) external nonReentrant returns (uint256 peggedOut) {
        if (fxUsdAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert InvalidAddress();

        // 1. Pull fxUSD from user
        IERC20(FXUSD).safeTransferFrom(msg.sender, address(this), fxUsdAmount);

        // 2. fxUSD → fxSAVE via diamond contract
        IERC20 fxUsdToken = IERC20(FXUSD);

        if (fxUsdToken.allowance(address(this), FXUSD_DIAMOND) > 0) {
            fxUsdToken.forceApprove(FXUSD_DIAMOND, 0);
        }
        fxUsdToken.forceApprove(FXUSD_DIAMOND, fxUsdAmount);

        // Build swap data: fxUSD to fxSAVE (similar to USDC flow)
        bytes memory swapData = abi.encodeWithSelector(0xed52d54c, FXUSD, fxUsdAmount, uint256(0), "");

        IFxUSDDiamondV2.ConvertInParams memory params = IFxUSDDiamondV2.ConvertInParams({
            tokenIn: FXUSD,
            amount: fxUsdAmount,
            target: FXUSD_SWAP_ROUTER,
            data: swapData,
            minOut: 0,
            signature: ""
        });

        uint256 fxSaveBalanceBefore = IERC20(FXSAVE).balanceOf(address(this));

        IFxUSDDiamondV2(FXUSD_DIAMOND).depositToFxSave{value: 0}(params, FXUSD, 0, address(this));

        uint256 fxSaveAmount = IERC20(FXSAVE).balanceOf(address(this)) - fxSaveBalanceBefore;

        // 3. fxSAVE → Minter mint pegged
        IERC20(FXSAVE).forceApprove(MINTER, fxSaveAmount);
        peggedOut = IMinter(MINTER).mintPeggedToken(fxSaveAmount, receiver, minPeggedOut);

        emit FXUSDZappedToPegged(msg.sender, MINTER, receiver, fxUsdAmount, fxSaveAmount, peggedOut);

        // Reset allowances to limit exposure
        fxUsdToken.forceApprove(FXUSD_DIAMOND, 0);
        IERC20(FXSAVE).forceApprove(MINTER, 0);
    }

    /// @notice Zap fxUSD into leveraged tokens in one transaction
    /// @dev Flow: fxUSD → fxSAVE → Minter mint leveraged
    /// @param fxUsdAmount Amount of fxUSD to zap
    /// @param receiver Address that will receive the leveraged tokens
    /// @param minLeveragedOut Minimum amount of leveraged tokens to receive
    /// @return leveragedOut Amount of leveraged tokens minted
    function zapFxUsdToLeveraged(
        uint256 fxUsdAmount,
        address receiver,
        uint256 minLeveragedOut
    ) external nonReentrant returns (uint256 leveragedOut) {
        if (fxUsdAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert InvalidAddress();

        // 1. Pull fxUSD from user
        IERC20(FXUSD).safeTransferFrom(msg.sender, address(this), fxUsdAmount);

        // 2. fxUSD → fxSAVE via diamond contract
        IERC20 fxUsdToken = IERC20(FXUSD);

        if (fxUsdToken.allowance(address(this), FXUSD_DIAMOND) > 0) {
            fxUsdToken.forceApprove(FXUSD_DIAMOND, 0);
        }
        fxUsdToken.forceApprove(FXUSD_DIAMOND, fxUsdAmount);

        // Build swap data: fxUSD to fxSAVE (similar to USDC flow)
        bytes memory swapData = abi.encodeWithSelector(0xed52d54c, FXUSD, fxUsdAmount, uint256(0), "");

        IFxUSDDiamondV2.ConvertInParams memory params = IFxUSDDiamondV2.ConvertInParams({
            tokenIn: FXUSD,
            amount: fxUsdAmount,
            target: FXUSD_SWAP_ROUTER,
            data: swapData,
            minOut: 0,
            signature: ""
        });

        uint256 fxSaveBalanceBefore = IERC20(FXSAVE).balanceOf(address(this));

        IFxUSDDiamondV2(FXUSD_DIAMOND).depositToFxSave{value: 0}(params, FXUSD, 0, address(this));

        uint256 fxSaveAmount = IERC20(FXSAVE).balanceOf(address(this)) - fxSaveBalanceBefore;

        // 3. fxSAVE → Minter mint leveraged
        IERC20(FXSAVE).forceApprove(MINTER, fxSaveAmount);
        leveragedOut = IMinter(MINTER).mintLeveragedToken(fxSaveAmount, receiver, minLeveragedOut);

        emit FXUSDZappedToLeveraged(msg.sender, MINTER, receiver, fxUsdAmount, fxSaveAmount, leveragedOut);

        // Reset allowances to limit exposure
        fxUsdToken.forceApprove(FXUSD_DIAMOND, 0);
        IERC20(FXSAVE).forceApprove(MINTER, 0);
    }

    // ============ Owner Functions ============

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
        // Allow contract to receive ETH for recovery
    }

    fallback() external payable {
        revert FunctionNotFound();
    }
}

