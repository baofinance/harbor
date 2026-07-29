// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {Deployer} from "@bao-script/deployment/Deployer.sol";
import {SaltString} from "@bao-script/deployment/SaltString.sol";
import {WellKnownAddress} from "@bao-script/deployment/FactoryDeployer.sol";
import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";

/// @notice Harbor-specific deployment base for scripts and tests.
/// @dev Inherit from this for all Harbor deployment contracts.
///      Provides owner()/treasury(), well-known address labels, Safe batch machinery,
///      and centralized role granting. Add `is Script` at the concrete script level
///      for forge broadcast context.
abstract contract HarborDeployer is Deployer {
    address private constant TREASURY_OWNER = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;

    /// @notice Which of a market's two stability pools is meant.
    /// @dev The single discriminator for the pair. Each market has one pool taking wrapped collateral
    ///      and one taking the leveraged token; every place that differs between them keys off this.
    enum StabilityPoolType {
        Collateral,
        Leveraged
    }

    function treasury() public view virtual override returns (address) {
        return TREASURY_OWNER;
    }

    function owner() public view virtual override returns (address) {
        return TREASURY_OWNER;
    }

    function getWellKnownAddresses() public view virtual override returns (WellKnownAddress[] memory addrs) {
        addrs = new WellKnownAddress[](3);
        addrs[0] = WellKnownAddress({addr: TREASURY_OWNER, label: "harbor_multisig"});
        addrs[1] = WellKnownAddress({addr: baoFactory(), label: "baoFactory"});
        addrs[2] = WellKnownAddress({addr: 0xf1674FE69b2920b4de51E909cbf060dd78724CD8, label: "bao_auto"});
    }

    // ─── Salt keys and predicted addresses ─────────────────────────────────────

    // Every contract this deploy stack creates has exactly one key function and one address
    // function here. The key function is the ONLY place its salt sub-key string is written
    // down; the address function is the ONLY way to reach its CREATE3 address. Nothing else
    // in the repo — deploy scripts, the stack, or tests — spells a sub-key out or calls
    // `_predictAddress` with a hand-built key, so changing a key moves the deploy and every
    // test that observes it in the same edit.
    //
    // These are deliberately NOT `virtual`: the deploy CREATE3-deploys each contract *to* the
    // address its resolver returns, so an override would not relocate anything, it would only
    // break the lookup. To substitute a mock, `vm.etch` it at the resolved address.
    //
    // They are `public` rather than `internal` because tests observe them from composed
    // harnesses, not only from inheritors.
    //
    // The address functions are not `view`: `_predictAddress` labels the address for readable
    // traces. The key functions are `pure`.

    /// @notice The salt key of a peg's pegged token, shared by every market on that peg.
    /// @param pegKey The peg key (e.g. "ETH").
    function peggedTokenKey(string memory pegKey) public pure returns (string memory) {
        return SaltString.key(pegKey, "pegged");
    }

    /// @notice The predicted address of a peg's pegged token.
    function peggedTokenAddress(string memory pegKey) public returns (address) {
        return _predictAddress(peggedTokenKey(pegKey));
    }

    /// @notice The salt key of a market's leveraged token.
    /// @param marketKey The market key (e.g. "ETH::fxUSD").
    function leveragedTokenKey(string memory marketKey) public pure returns (string memory) {
        return SaltString.key(marketKey, "leveraged");
    }

    /// @notice The predicted address of a market's leveraged token.
    function leveragedTokenAddress(string memory marketKey) public returns (address) {
        return _predictAddress(leveragedTokenKey(marketKey));
    }

    /// @notice The salt key of a market's minter.
    function minterKey(string memory marketKey) public pure returns (string memory) {
        return SaltString.key(marketKey, "minter");
    }

    /// @notice The predicted address of a market's minter.
    function minterAddress(string memory marketKey) public returns (address) {
        return _predictAddress(minterKey(marketKey));
    }

    /// @notice The salt key of a market's reserve pool.
    function reservePoolKey(string memory marketKey) public pure returns (string memory) {
        return SaltString.key(marketKey, "reservePool");
    }

    /// @notice The predicted address of a market's reserve pool.
    function reservePoolAddress(string memory marketKey) public returns (address) {
        return _predictAddress(reservePoolKey(marketKey));
    }

    /// @notice The salt key of one of a market's two stability pools.
    function stabilityPoolKey(string memory marketKey, StabilityPoolType poolType) public pure returns (string memory) {
        return
            SaltString.key(
                marketKey,
                poolType == StabilityPoolType.Collateral ? "stabilityPoolCollateral" : "stabilityPoolLeveraged"
            );
    }

    /// @notice The predicted address of one of a market's two stability pools.
    function stabilityPoolAddress(string memory marketKey, StabilityPoolType poolType) public returns (address) {
        return _predictAddress(stabilityPoolKey(marketKey, poolType));
    }

    /// @notice The salt key of a market's stability pool manager.
    function stabilityPoolManagerKey(string memory marketKey) public pure returns (string memory) {
        return SaltString.key(marketKey, "stabilityPoolManager");
    }

    /// @notice The predicted address of a market's stability pool manager.
    function stabilityPoolManagerAddress(string memory marketKey) public returns (address) {
        return _predictAddress(stabilityPoolManagerKey(marketKey));
    }

    /// @notice The salt key of a market's genesis contract.
    function genesisKey(string memory marketKey) public pure returns (string memory) {
        return SaltString.key(marketKey, "genesis");
    }

    /// @notice The predicted address of a market's genesis contract.
    function genesisAddress(string memory marketKey) public returns (address) {
        return _predictAddress(genesisKey(marketKey));
    }

    /// @notice The predicted address of a market's wrapped price oracle.
    /// @param oracleKey The oracle's key, supplied by the market config — this contract is deployed by
    ///        harbor-price-aggregators, not by this stack, so the key is not composed here.
    /// @dev Referenced by the deploy while the address is still codeless, exactly as production does when
    ///      the oracle is deployed separately. To substitute a mock, `vm.etch` it at this address AFTER the
    ///      deploy has run — do not override this function, or the deploy stops exercising that path.
    function wrappedPriceOracleAddress(string memory oracleKey) public returns (address) {
        return _predictAddress(oracleKey);
    }

    // ─── Role granting ─────────────────────────────────────────────────────────

    function _grantRoles(
        string memory granterLabel,
        address target,
        address grantee,
        string memory granteeLabel,
        uint256 roles,
        string memory roleDescription
    ) internal {
        console.log("      %s: %s role -> %s", granterLabel, roleDescription, granteeLabel);
        IHarborRoles(target).grantRoles(grantee, roles);
    }

    function _logManualRoleGrant(
        string memory granterLabel,
        address target,
        address grantee,
        string memory granteeLabel,
        uint256 roles,
        string memory roleDescription
    ) internal pure {
        console.log("      %s: %s role -> %s (MANUAL TX REQUIRED)", granterLabel, roleDescription, granteeLabel);
        console.log("          To:    %s", target);
        console.log("          Call:  grantRoles(%s, %s)", grantee, roles);
    }
}
