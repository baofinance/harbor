// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {HarborOwnable} from "@bao/HarborOwnable.sol";
import {Token} from "@bao/Token.sol";
import {TokenHolder_v2} from "@bao/TokenHolder_v2.sol";

import {IRepayment_v1} from "@harbor/interfaces/IRepayment_v1.sol";

/// @notice Repays a fixed list of debts in one token from whatever is paid in, the same fraction to everyone: see
///         `IRepayment_v1`. Set as the fee receiver of the markets' contracts, it collects their fees until the debts are
///         covered; a fee paid in another token is swept by the owner, converted, and paid back in.
/// @dev UUPS, ERC-7201 storage. The debts are recorded once, in `initialize`, and have no setter.
// solhint-disable-next-line contract-name-capwords
contract Repayment_v1 is IRepayment_v1, Initializable, UUPSUpgradeable, TokenHolder_v2, HarborOwnable {
    using SafeERC20 for IERC20;

    /// @inheritdoc IRepayment_v1
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable TOKEN;

    /// @custom:storage-location erc7201:bao.storage.Repayment
    struct RepaymentStorage {
        uint256 totalDebt;
        uint256 totalClaimed;
        mapping(address account => uint256) debt;
        mapping(address account => uint256) claimed;
    }

    // keccak256(abi.encode(uint256(keccak256("bao.storage.Repayment")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _REPAYMENT_STORAGE = 0x8f4198de171ff14d40cebd26f11ed9a64ab0693934dd0818c093c78414793500;

    function _getRepaymentStorage() private pure returns (RepaymentStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _REPAYMENT_STORAGE
        }
    }

    /// @param token The token the debts are in and are repaid in.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address token) {
        Token.ensureNonZeroAddress(token);
        TOKEN = token;
        _disableInitializers();
    }

    /// @notice Records the debts. The de-facto constructor of the proxy.
    /// @param deployerOwner The owner during deployment.
    /// @param pendingOwner The owner the deployer hands over to.
    /// @param accounts The accounts owed, each once.
    /// @param debts What each is owed, in `TOKEN`, none zero.
    function initialize(
        address deployerOwner,
        address pendingOwner,
        address[] calldata accounts,
        uint256[] calldata debts
    ) external initializer {
        _initializeOwner(deployerOwner, pendingOwner);
        if (accounts.length != debts.length) {
            revert AccountsAndDebtsDifferentSizes(accounts.length, debts.length);
        }
        RepaymentStorage storage $ = _getRepaymentStorage();
        uint256 total;
        for (uint256 i = 0; i < accounts.length; ++i) {
            Token.ensureNonZeroAddress(accounts[i]);
            if (debts[i] == 0) {
                revert ZeroDebt(accounts[i]);
            }
            if ($.debt[accounts[i]] != 0) {
                revert DuplicateAccount(accounts[i]);
            }
            $.debt[accounts[i]] = debts[i];
            total += debts[i];
            emit DebtRecorded(accounts[i], debts[i]);
        }
        $.totalDebt = total;
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    /*//////////////////////////////////////////////////////////////
                           PUBLIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRepayment_v1
    function debt(address account) external view returns (uint256) {
        return _getRepaymentStorage().debt[account];
    }

    /// @inheritdoc IRepayment_v1
    function claimed(address account) external view returns (uint256) {
        return _getRepaymentStorage().claimed[account];
    }

    /// @inheritdoc IRepayment_v1
    function claimable(address account) external view returns (uint256) {
        return _claimable(_getRepaymentStorage(), account);
    }

    /// @inheritdoc IRepayment_v1
    function received() external view returns (uint256) {
        return _received(_getRepaymentStorage());
    }

    /// @inheritdoc IRepayment_v1
    function totalDebt() external view returns (uint256) {
        return _getRepaymentStorage().totalDebt;
    }

    /// @inheritdoc IRepayment_v1
    function totalClaimed() external view returns (uint256) {
        return _getRepaymentStorage().totalClaimed;
    }

    /*//////////////////////////////////////////////////////////////
                          PUBLIC UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRepayment_v1
    function claim() external nonReentrant returns (uint256 amount) {
        return _claim(msg.sender);
    }

    /// @inheritdoc IRepayment_v1
    function claim(address receiver) external nonReentrant returns (uint256 amount) {
        Token.ensureNonZeroAddress(receiver);
        return _claim(receiver);
    }

    /// @notice Sweep a token the owner wants out: any token but `TOKEN` freely, `TOKEN` only beyond the debts, so every
    ///         unclaimed amount stays claimable.
    /// @inheritdoc TokenHolder_v2
    function sweep(address token, uint256 amount, address receiver) external override onlySweeper nonReentrant {
        Token.ensureNonZeroAddress(receiver);
        if (token == TOKEN) {
            RepaymentStorage storage $ = _getRepaymentStorage();
            uint256 received_ = _received($);
            if (received_ < $.totalDebt) {
                revert DebtsNotCovered(received_, $.totalDebt);
            }
            uint256 surplus = received_ - $.totalDebt;
            if (amount == type(uint256).max) {
                amount = surplus;
            } else if (amount > surplus) {
                revert SweepExceedsSurplus(amount, surplus);
            }
        } else {
            amount = Token.allOf(address(this), token, amount);
        }
        _sweep(token, amount, receiver);
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Everything paid in so far: what is here, and what has already been claimed.
    function _received(RepaymentStorage storage $) private view returns (uint256) {
        return IERC20(TOKEN).balanceOf(address(this)) + $.totalClaimed;
    }

    /// @dev `account`'s debt times the fraction of the total debt paid in so far, capped at the whole debt and floored,
    ///      less what it has claimed.
    function _claimable(RepaymentStorage storage $, address account) private view returns (uint256) {
        uint256 debt_ = $.debt[account];
        if (debt_ == 0) {
            return 0;
        }
        uint256 paidIn = Math.min(_received($), $.totalDebt);
        return Math.mulDiv(debt_, paidIn, $.totalDebt) - $.claimed[account];
    }

    /// @dev Pays `receiver` what the caller can claim, recorded against the caller.
    function _claim(address receiver) private returns (uint256 amount) {
        RepaymentStorage storage $ = _getRepaymentStorage();
        address account = msg.sender;
        if ($.debt[account] == 0) {
            revert NoDebt(account);
        }
        amount = _claimable($, account);
        if (amount == 0) {
            revert NothingToClaim(account);
        }
        $.claimed[account] += amount;
        $.totalClaimed += amount;
        emit Claimed(account, receiver, amount);
        IERC20(TOKEN).safeTransfer(receiver, amount);
    }
}
