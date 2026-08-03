// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {HarborReporting} from "@harbor-script/src/HarborReporting.sol";
import {SaltString} from "@bao-script/deployment/SaltString.sol";
import {Config_MinterMarket, Market, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {WellKnownAddress} from "@bao-script/deployment/FactoryDeployer.sol";
import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";

/// @notice Harbor-specific deployment base for scripts and tests.
/// @dev Inherit from this for all Harbor deployment contracts.
///      Provides owner()/treasury(), well-known address labels, Safe batch machinery,
///      and centralized role granting. Add `is Script` at the concrete script level
///      for forge broadcast context.
abstract contract HarborDeployer is HarborReporting {
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
    // traces. The `(peg, collateral)` key functions are `pure`; the config forms are `view`
    // because they read the market config.
    //
    // Every per-market getter comes in two forms: a `Market` primitive, and a `Config_MinterMarket`
    // overload delegating to it. Both populations are real — deploy code and config-driven tests
    // hold a config, while fork verifications against live markets and hand-written Safe batches
    // have only the names (there is no config for a market this repo did not configure). Naming
    // the identity rather than encoding it as an arity difference is also what lets the price
    // oracle share the shape: its key is REVERSED (collateral::peg::wrappedPriceAggregator), so it
    // cannot be derived from a composed market key without splitting the string, which configs
    // exist to avoid.

    /// @notice The salt key of a peg's pegged token.
    /// @param peg The peg name (e.g. "ETH").
    /// @dev The one getter here that takes a peg rather than a Market: a single pegged token is shared by
    ///      every market on that peg, so it genuinely does not depend on the collateral. A caller holding a
    ///      Market passes `market.peg`.
    function peggedTokenKey(string memory peg) public pure returns (string memory) {
        return SaltString.key(peg, "pegged");
    }

    function peggedTokenKey(Config_MinterMarket config) public view returns (string memory) {
        return peggedTokenKey(MinterMarketConfigLib.peg(config));
    }

    /// @notice The predicted address of a peg's pegged token.
    function peggedTokenAddress(string memory peg) public returns (address) {
        return _predictAddress(peggedTokenKey(peg));
    }

    function peggedTokenAddress(Config_MinterMarket config) public returns (address) {
        return peggedTokenAddress(MinterMarketConfigLib.peg(config));
    }

    /// @notice The salt key of a market's leveraged token.
    function leveragedTokenKey(Market memory market) public pure returns (string memory) {
        return SaltString.key(_marketKey(market), "leveraged");
    }

    function leveragedTokenKey(Config_MinterMarket config) public view returns (string memory) {
        return leveragedTokenKey(MinterMarketConfigLib.market(config));
    }

    /// @notice The predicted address of a market's leveraged token.
    function leveragedTokenAddress(Market memory market) public returns (address) {
        return _predictAddress(leveragedTokenKey(market));
    }

    function leveragedTokenAddress(Config_MinterMarket config) public returns (address) {
        return leveragedTokenAddress(MinterMarketConfigLib.market(config));
    }

    /// @notice The salt key of a market's minter.
    function minterKey(Market memory market) public pure returns (string memory) {
        return SaltString.key(_marketKey(market), "minter");
    }

    function minterKey(Config_MinterMarket config) public view returns (string memory) {
        return minterKey(MinterMarketConfigLib.market(config));
    }

    /// @notice The predicted address of a market's minter.
    function minterAddress(Market memory market) public returns (address) {
        return _predictAddress(minterKey(market));
    }

    function minterAddress(Config_MinterMarket config) public returns (address) {
        return minterAddress(MinterMarketConfigLib.market(config));
    }

    /// @notice The salt key of a market's reserve pool.
    function reservePoolKey(Market memory market) public pure returns (string memory) {
        return SaltString.key(_marketKey(market), "reservePool");
    }

    function reservePoolKey(Config_MinterMarket config) public view returns (string memory) {
        return reservePoolKey(MinterMarketConfigLib.market(config));
    }

    /// @notice The predicted address of a market's reserve pool.
    function reservePoolAddress(Market memory market) public returns (address) {
        return _predictAddress(reservePoolKey(market));
    }

    function reservePoolAddress(Config_MinterMarket config) public returns (address) {
        return reservePoolAddress(MinterMarketConfigLib.market(config));
    }

    /// @notice The salt key of one of a market's two stability pools.
    function stabilityPoolKey(Market memory market, StabilityPoolType poolType) public pure returns (string memory) {
        return
            SaltString.key(
                _marketKey(market),
                poolType == StabilityPoolType.Collateral ? "stabilityPoolCollateral" : "stabilityPoolLeveraged"
            );
    }

    function stabilityPoolKey(
        Config_MinterMarket config,
        StabilityPoolType poolType
    ) public view returns (string memory) {
        return stabilityPoolKey(MinterMarketConfigLib.market(config), poolType);
    }

    /// @notice The predicted address of one of a market's two stability pools.
    function stabilityPoolAddress(Market memory market, StabilityPoolType poolType) public returns (address) {
        return _predictAddress(stabilityPoolKey(market, poolType));
    }

    function stabilityPoolAddress(Config_MinterMarket config, StabilityPoolType poolType) public returns (address) {
        return stabilityPoolAddress(MinterMarketConfigLib.market(config), poolType);
    }

    /// @notice The salt key of a market's stability pool manager.
    function stabilityPoolManagerKey(Market memory market) public pure returns (string memory) {
        return SaltString.key(_marketKey(market), "stabilityPoolManager");
    }

    function stabilityPoolManagerKey(Config_MinterMarket config) public view returns (string memory) {
        return stabilityPoolManagerKey(MinterMarketConfigLib.market(config));
    }

    /// @notice The predicted address of a market's stability pool manager.
    function stabilityPoolManagerAddress(Market memory market) public returns (address) {
        return _predictAddress(stabilityPoolManagerKey(market));
    }

    function stabilityPoolManagerAddress(Config_MinterMarket config) public returns (address) {
        return stabilityPoolManagerAddress(MinterMarketConfigLib.market(config));
    }

    /// @notice The salt key of a market's genesis contract.
    function genesisKey(Market memory market) public pure returns (string memory) {
        return SaltString.key(_marketKey(market), "genesis");
    }

    function genesisKey(Config_MinterMarket config) public view returns (string memory) {
        return genesisKey(MinterMarketConfigLib.market(config));
    }

    /// @notice The predicted address of a market's genesis contract.
    function genesisAddress(Market memory market) public returns (address) {
        return _predictAddress(genesisKey(market));
    }

    function genesisAddress(Config_MinterMarket config) public returns (address) {
        return genesisAddress(MinterMarketConfigLib.market(config));
    }

    /// @notice The salt key of a market's wrapped price oracle.
    /// @dev Reversed relative to every other key here — collateral first — matching the naming used by
    ///      harbor-price-aggregators, which deploys this contract. Composed here rather than read off the
    ///      config so that callers without a config resolve the same address.
    function wrappedPriceOracleKey(Market memory market) public pure returns (string memory) {
        return SaltString.key(market.collateral, market.peg, "wrappedPriceAggregator");
    }

    function wrappedPriceOracleKey(Config_MinterMarket config) public view returns (string memory) {
        return wrappedPriceOracleKey(MinterMarketConfigLib.market(config));
    }

    /// @notice The predicted address of a market's wrapped price oracle.
    /// @dev A separate deployment (harbor-price-aggregators), referenced by the deploy while the address is
    ///      still codeless — exactly as production does. To substitute a mock, `vm.etch` it here AFTER the
    ///      deploy has run; do not override this function, or the deploy stops exercising that path.
    function wrappedPriceOracleAddress(Market memory market) public returns (address) {
        return _predictAddress(wrappedPriceOracleKey(market));
    }

    function wrappedPriceOracleAddress(Config_MinterMarket config) public returns (address) {
        return wrappedPriceOracleAddress(MinterMarketConfigLib.market(config));
    }

    /// @dev The "peg::collateral" market key every per-market key above is built on. Private: callers name a
    ///      contract, not a market — the composed market key is an implementation detail of these getters.
    function _marketKey(Market memory market) private pure returns (string memory) {
        return SaltString.key(market.peg, market.collateral);
    }

    // ─── Role granting ─────────────────────────────────────────────────────────

    // Harbor's share of the deploy's running commentary lives in `HarborReporting`, inherited above,
    // in its own file so that its permanently-uncovered message bodies do not mask the coverage of the
    // deployment code in this one.

    function _grantRoles(
        string memory granterLabel,
        address target,
        address grantee,
        string memory granteeLabel,
        uint256 roles,
        string memory roleDescription
    ) internal {
        _reportRoleGrant(granterLabel, granteeLabel, roleDescription);
        IHarborRoles(target).grantRoles(grantee, roles);
    }
}
