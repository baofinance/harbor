// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HarborFixedOwnable} from "@bao/HarborFixedOwnable.sol";

import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {Minter_v3} from "@harbor/minter/Minter_v3.sol";

import {IMinter_v3_Upgrader} from "@harbor-script/UpgradeMinter_v2_v3/IMinter_v3_Upgrader.sol";

/// @title Minter_v3_Upgrader
/// @notice One-shot throwaway implementation for upgrading to Minter_v3 a minter that records backing but holds no
///         wrapped collateral - a retired market's rounding dust - run atomically as a TEMPORARY proxy implementation.
///         `zeroBackingAndUpgrade`, in one transaction:
///           1. refuses unless the minter holds none of the wrapped collateral the Minter_v3 implementation is built
///              for - the token is read from that implementation, so the caller cannot name another;
///           2. sets the recorded backing to zero, what nothing held is worth, so Minter_v3 does not halt the market as
///              impaired;
///           3. upgrades the proxy to Minter_v3, running `upgradeCall` there - the config load.
///         It reads no price, and leaves no write-off code on the functional contract.
/// @dev Owner-gated and single-shot by construction: it upgrades away from itself in the same transaction, so
///      `zeroBackingAndUpgrade` can never run twice. Storage safety: it reaches the minter's namespace through
///      Minter_v3's canonical struct type at the namespace's ERC-7201 slot, which storage-successor verifies against
///      its canonical hash; the bao-upgrades-from below makes storage-successor compare that struct against
///      Minter_v2's same namespace. OZ sees only @custom:oz-upgrades and validates it in isolation.
/// @custom:oz-upgrades
/// @custom:bao-upgrades-from src/minter/Minter_v2.sol:Minter_v2
// solhint-disable-next-line contract-name-capwords
contract Minter_v3_Upgrader is Initializable, UUPSUpgradeable, HarborFixedOwnable, IMinter_v3_Upgrader {
    /// @dev The minter's ERC-7201 slot, reached through the canonical `MinterStorage` type below, so only the slot is
    ///      copied and the layout cannot drift.
    bytes32 private constant _MINTER_STORAGE = 0x92e73fe9557052b4a0b810a38eb7ef595ff750f166ca39d63b3f4c74937fef00;

    /// @param owner_ The account authorised to run the upgrade - the same account that owns the proxy (the Harbor
    ///        multisig in production).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address owner_) HarborFixedOwnable(address(0), owner_, 0) {
        _disableInitializers();
    }

    /// @inheritdoc IMinter_v3_Upgrader
    function zeroBackingAndUpgrade(address minterV3, bytes calldata upgradeCall) external onlyOwner {
        address wrappedCollateral = IMinter_v3(minterV3).WRAPPED_COLLATERAL_TOKEN();
        uint256 held = IERC20(wrappedCollateral).balanceOf(address(this));
        if (held != 0) {
            revert MinterHoldsWrappedCollateral(wrappedCollateral, held);
        }

        Minter_v3.MinterStorage storage $ = _minterStorage();
        emit BackingZeroed($.underlyingCollateral);
        $.underlyingCollateral = 0;

        upgradeToAndCall(minterV3, upgradeCall);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    /// @dev The minter's namespaced storage, referenced through its canonical struct type at its fixed slot.
    function _minterStorage() private pure returns (Minter_v3.MinterStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _MINTER_STORAGE
        }
    }
}
