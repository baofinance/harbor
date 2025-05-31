// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {Token} from "@bao/Token.sol";
import {ITokenHolder} from "@bao/interfaces/ITokenHolder.sol";
import {IHarvester} from "src/interfaces/IHarvester.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {Bounty, IBounty} from "src/common/Bounty.sol";

/// @author rootminus0x1
/// @dev Uses UUPS proxy, erc7201 storage
/// @custom:oz-upgrades
// solhint-disable-next-line contract-name-camelcase
contract Harvester_v1 is Initializable, UUPSUpgradeable, ReentrancyGuardTransientUpgradeable, Bounty, IHarvester {
    using SafeERC20 for IERC20;

    /*************
     * Variables *
     *************/

    // these variables are set in the constructor, not the initializer, to improve contract size and gas usage
    // to change them the contract must be upgraded
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable MINTER;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable BOUNTY_TOKEN;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable TREASURY;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable

    // The number of harvest receivers
    uint8 private immutable HARVEST_RECEIVER_COUNT;
    // Individual immutable addresses instead of an array
    address private immutable HARVEST_RECEIVER_0;
    address private immutable HARVEST_RECEIVER_1;
    address private immutable HARVEST_RECEIVER_2;
    address private immutable HARVEST_RECEIVER_3;

    /// @inheritdoc IHarvester
    function HARVEST_RECEIVER(uint index) external view returns (address) {
        require(index < HARVEST_RECEIVER_COUNT, "Index out of bounds");

        if (index == 0) return HARVEST_RECEIVER_0;
        if (index == 1) return HARVEST_RECEIVER_1;
        if (index == 2) return HARVEST_RECEIVER_2;
        if (index == 3) return HARVEST_RECEIVER_3;
        // Add more if needed

        return address(0);
    }

    function initialize(address owner_) public initializer {
        __Bounty_init(owner_);
        __UUPSUpgradeable_init();
    }

    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// https://forum.openzeppelin.com/t/what-does-disableinitializers-function-mean/28730
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address minter_, address[] memory harvestReceivers, address treasury) {
        Token.ensureContract(minter_);
        // slither-disable-next-line missing-zero-check
        MINTER = minter_;

        address bountyToken = IMinter(minter_).WRAPPED_COLLATERAL_TOKEN();
        Token.sanityCheckERC20Token(bountyToken);
        // slither-disable-next-line missing-zero-check
        BOUNTY_TOKEN = bountyToken;

        // Store length
        require(harvestReceivers.length > 0, "Too few harvest receivers"); // Adjust limit as needed
        require(harvestReceivers.length <= 4, "Too many harvest receivers"); // Adjust limit as needed
        HARVEST_RECEIVER_COUNT = uint8(harvestReceivers.length);

        // Store individual addresses
        if (HARVEST_RECEIVER_COUNT > 0) {
            Token.ensureNonZeroAddress(harvestReceivers[0]);
            HARVEST_RECEIVER_0 = harvestReceivers[0];
        }
        if (HARVEST_RECEIVER_COUNT > 1) {
            Token.ensureNonZeroAddress(harvestReceivers[1]);
            HARVEST_RECEIVER_1 = harvestReceivers[1];
        }
        if (HARVEST_RECEIVER_COUNT > 2) {
            Token.ensureNonZeroAddress(harvestReceivers[2]);
            HARVEST_RECEIVER_2 = harvestReceivers[2];
        }
        if (HARVEST_RECEIVER_COUNT > 3) {
            Token.ensureNonZeroAddress(harvestReceivers[3]);
            HARVEST_RECEIVER_3 = harvestReceivers[3];
        }

        Token.ensureNonZeroAddress(treasury);
        // slither-disable-next-line missing-zero-check
        TREASURY = treasury;

        _disableInitializers();
    }

    /// @notice The check that allow this contract to be upgraded:
    /// In UUPS proxies the implementation is responsible for upgrading itself
    /// only owners can upgrade this contract.
    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(IHarvester).interfaceId ||
            interfaceId == type(IBounty).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IHarvester
    function harvest(address bountyReceiver, uint256 minBounty) public virtual nonReentrant {
        uint256 totalHarvest = IMinter(MINTER).harvestable();
        uint256 bounty_ = _calcBounty(totalHarvest);

        // check if the caller thinks it's worthwhile
        if (bounty_ < minBounty) revert IHarvester.InsufficientBounty(BOUNTY_TOKEN, bounty_, minBounty);

        // check if it's actually worthwhile
        if (totalHarvest - bounty_ > 0) {
            // send the bounty
            ITokenHolder(MINTER).sweep(BOUNTY_TOKEN, bounty_, bountyReceiver);

            // Amount to distribute
            uint256 harvestAmount = totalHarvest - bounty_;

            // now do the actual harvest
            // Calculate total BOUNTY_TOKEN balance across all receivers
            uint256 totalBalance = 0;
            uint256 receiverHolding_0;
            uint256 receiverHolding_1;
            uint256 receiverHolding_2;
            uint256 receiverHolding_3;
            // Store individual addresses
            if (HARVEST_RECEIVER_COUNT > 0) {
                receiverHolding_0 = IERC20(BOUNTY_TOKEN).balanceOf(HARVEST_RECEIVER_0);
                totalBalance += receiverHolding_0;
            }
            if (HARVEST_RECEIVER_COUNT > 1) {
                receiverHolding_1 = IERC20(BOUNTY_TOKEN).balanceOf(HARVEST_RECEIVER_1);
                totalBalance += receiverHolding_1;
            }
            if (HARVEST_RECEIVER_COUNT > 2) {
                receiverHolding_2 = IERC20(BOUNTY_TOKEN).balanceOf(HARVEST_RECEIVER_2);
                totalBalance += receiverHolding_2;
            }
            if (HARVEST_RECEIVER_COUNT > 3) {
                receiverHolding_3 = IERC20(BOUNTY_TOKEN).balanceOf(HARVEST_RECEIVER_3);
                totalBalance += receiverHolding_3;
            }

            // distribute the harvest amount proportionally
            // we don't worry about dust here, as it will be picked up in a later harvest call
            if (totalBalance > 0) {
                if (receiverHolding_0 > 0) {
                    uint256 amountToSweep = (harvestAmount * receiverHolding_0) / totalBalance;
                    ITokenHolder(MINTER).sweep(BOUNTY_TOKEN, amountToSweep, HARVEST_RECEIVER_0);
                }
                if (receiverHolding_1 > 0) {
                    uint256 amountToSweep = (harvestAmount * receiverHolding_1) / totalBalance;
                    ITokenHolder(MINTER).sweep(BOUNTY_TOKEN, amountToSweep, HARVEST_RECEIVER_1);
                }
                if (receiverHolding_2 > 0) {
                    uint256 amountToSweep = (harvestAmount * receiverHolding_2) / totalBalance;
                    ITokenHolder(MINTER).sweep(BOUNTY_TOKEN, amountToSweep, HARVEST_RECEIVER_2);
                }
                if (receiverHolding_3 > 0) {
                    uint256 amountToSweep = (harvestAmount * receiverHolding_3) / totalBalance;
                    ITokenHolder(MINTER).sweep(BOUNTY_TOKEN, amountToSweep, HARVEST_RECEIVER_3);
                }
            } else {
                // we sent it to the treasury for use in reserve
                ITokenHolder(MINTER).sweep(BOUNTY_TOKEN, harvestAmount, TREASURY);
            }
        }
    }
}
