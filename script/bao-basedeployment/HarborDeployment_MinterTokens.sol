// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {FactoryDeployer} from "./FactoryDeployer.sol";
import {DeploymentState} from "./DeploymentState.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket, IMarketConfig, MinterMarketConfigLib} from "script/config/ConfigBase.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IMintableRole} from "@bao/interfaces/IMintableRole.sol";
import {IBurnableRole} from "@bao/interfaces/IBurnableRole.sol";
import {LibString} from "@solady/utils/LibString.sol";

/// @notice Harbor minter token deployment logic (pegged and leveraged tokens).
/// @dev Both token types use MintableBurnableERC20_v1 - the differences are:
/// @dev - Pegged: one per peg (ETH, BTC, GOLD, EUR), shared by all markets with that peg
/// @dev - Leveraged: one per market (e.g., hsFXUSD-BTC for BTC::fxUSD market)
///
/// @dev File Organization Pattern (see deployment2-design.md Section 3.3.2):
/// @dev - This file: contract-specific deployment + role granting for MinterTokens
/// @dev - DeployMintersBase.sol: orchestration (deployAllMinters, _deployAllPeggedTokens, etc.)
///
/// @dev Implementation/Proxy Separation Pattern:
/// @dev Functions split into deployXxxImpl() and deployXxxProxy() for composability:
/// @dev - Upgrade flows: deploy new impl, then upgrade existing proxy via Safe
/// @dev - Fresh deployments: deploy impl, then deploy proxy pointing to it
/// @dev The combined deployXxxToken() functions are convenience wrappers.
abstract contract HarborDeployment_MinterTokens is FactoryDeployer {
    using LibString for string;

    // ========== IMPLEMENTATION DEPLOYMENT ==========

    /// @notice Deploy a MintableBurnableERC20_v1 implementation.
    /// @dev Shared by both pegged and leveraged tokens - they use the same contract.
    /// @dev Use for upgrade flows where proxy already exists.
    function deployMinterTokenImpl()
        internal
        returns (address impl, DeploymentTypes.ImplementationRecord memory implRecord)
    {
        impl = address(new MintableBurnableERC20_v1());

        implRecord = DeploymentTypes.ImplementationRecord({
            proxy: "", // Will be set by caller when associating with a proxy
            contractSource: "@bao/MintableBurnableERC20_v1.sol",
            contractType: "MintableBurnableERC20_v1",
            implementation: impl,
            deploymentTime: uint64(block.timestamp)
        });
    }

    // ========== PEGGED TOKEN DEPLOYMENT ==========

    /// @notice Deploy only the proxy for a pegged token, pointing to an existing implementation.
    /// @dev Use after deployMinterTokenImpl() for fresh deployments.
    function deployPeggedProxy(
        address baoFactoryAddr,
        ConfigPeg pegConfig,
        address implementation,
        address tokenOwner,
        string memory systemSalt
    ) internal returns (address proxy, DeploymentTypes.ProxyRecord memory proxyRecord) {
        string memory pegKey = string.concat(pegConfig.key(), "::pegged");

        string memory tokenName = pegConfig.name();
        string memory tokenSymbol = pegConfig.symbol();
        console.log("      Name:   %s", tokenName);
        console.log("      Symbol: %s", tokenSymbol);

        bytes32 salt = keccak256(abi.encodePacked(systemSalt, "::", pegKey));
        bytes memory initData = abi.encodeCall(
            MintableBurnableERC20_v1.initialize,
            (tokenOwner, tokenName, tokenSymbol)
        );

        proxy = deployProxy(baoFactoryAddr, salt, implementation, initData);
        console.log("      Proxy:  %s", proxy);

        proxyRecord = DeploymentTypes.ProxyRecord({
            id: pegKey,
            fragment: DeploymentTypes.FragmentDescriptor({key: pegKey, kind: DeploymentTypes.FragmentKind.Peg}),
            proxy: proxy,
            implementation: implementation,
            salt: systemSalt,
            deploymentTime: uint64(block.timestamp)
        });
    }

    /// @notice Deploy a pegged token (implementation + proxy) for a specific peg.
    /// @dev Convenience wrapper combining deployMinterTokenImpl() and deployPeggedProxy().
    function deployPeggedToken(
        address baoFactoryAddr,
        ConfigPeg pegConfig,
        address tokenOwner,
        string memory systemSalt
    )
        internal
        returns (
            address impl,
            address proxy,
            DeploymentTypes.ImplementationRecord memory implRecord,
            DeploymentTypes.ProxyRecord memory proxyRecord
        )
    {
        string memory pegKey = string.concat(pegConfig.key(), "::pegged");
        console.log("  > %s", pegKey);

        // Deploy implementation
        (impl, implRecord) = deployMinterTokenImpl();
        console.log("      Impl:   %s", impl);
        implRecord.proxy = pegKey; // Associate with this proxy key

        // Deploy proxy
        (proxy, proxyRecord) = deployPeggedProxy(baoFactoryAddr, pegConfig, impl, tokenOwner, systemSalt);
    }

    /// @notice Deploy a pegged token, record in state, and grant minter roles.
    /// @dev Full deployment including state recording and role setup.
    /// @param stateData State to record deployment in.
    /// @param pegConfig Configuration for this peg.
    /// @param marketConfigs Markets that will mint this pegged token (for role grants).
    /// @param baoFactoryAddr BaoFactory address.
    /// @param tokenOwner Owner address for the deployed token.
    /// @param systemSalt System salt for CREATE3 deployment.
    function deployPeggedTokenWithRoles(
        DeploymentTypes.State memory stateData,
        ConfigPeg pegConfig,
        Config_MinterMarket[] memory marketConfigs,
        address baoFactoryAddr,
        address tokenOwner,
        string memory systemSalt
    ) internal returns (address peggedToken) {
        string memory pegKey = pegConfig.key();
        (
            ,
            address proxy,
            DeploymentTypes.ImplementationRecord memory implRecord,
            DeploymentTypes.ProxyRecord memory proxyRecord
        ) = deployPeggedToken(baoFactoryAddr, pegConfig, tokenOwner, systemSalt);

        DeploymentState.recordImplementation(stateData, implRecord);
        DeploymentState.recordProxy(stateData, proxyRecord);

        peggedToken = proxy;
        _registerForOwnershipTransfer(proxy, _saltString(proxyRecord.id));

        // Grant minter/burner roles to each market's minter contract
        console.log("      Roles:");
        for (uint256 i = 0; i < marketConfigs.length; i++) {
            IMarketConfig market = IMarketConfig(address(marketConfigs[i]));
            string memory configPeg = market.peg();

            // Validate that config peg matches this pegged token
            require(
                configPeg.eq(pegKey),
                string.concat("Market config peg '", configPeg, "' does not match pegged token '", pegKey, "'")
            );

            string memory minterKey = MinterMarketConfigLib.salt(marketConfigs[i]);
            address minter = _predictMinterAddress(baoFactoryAddr, systemSalt, minterKey);

            console.log("        MINTER -> %s", minterKey);
            _grantMinterRoles(peggedToken, minter);
        }
    }

    // ========== LEVERAGED TOKEN DEPLOYMENT ==========

    /// @notice Deploy only the proxy for a leveraged token, pointing to an existing implementation.
    /// @dev Use after deployMinterTokenImpl() for fresh deployments.
    function deployLeveragedProxy(
        address baoFactoryAddr,
        string memory peg,
        string memory collateral,
        address implementation,
        address tokenOwner,
        string memory systemSalt
    ) internal returns (address proxy, DeploymentTypes.ProxyRecord memory proxyRecord) {
        string memory leveragedKey = string.concat(peg, "::", collateral, "::leveraged");

        // Token name: "Harbor sail: variable leveraged long <COLLATERAL> against <PEG>"
        string memory tokenName = string.concat("Harbor sail: variable leveraged long ", collateral, " against ", peg);
        // Token symbol: "hs<COLLATERAL>-<PEG>"
        string memory tokenSymbol = string.concat("hs", collateral.upper(), "-", peg.upper());

        console.log("      Name:   %s", tokenName);
        console.log("      Symbol: %s", tokenSymbol);

        bytes32 salt = keccak256(abi.encodePacked(systemSalt, "::", leveragedKey));
        bytes memory initData = abi.encodeCall(
            MintableBurnableERC20_v1.initialize,
            (tokenOwner, tokenName, tokenSymbol)
        );

        proxy = deployProxy(baoFactoryAddr, salt, implementation, initData);
        console.log("      Proxy:  %s", proxy);

        proxyRecord = DeploymentTypes.ProxyRecord({
            id: leveragedKey,
            fragment: DeploymentTypes.FragmentDescriptor({
                key: leveragedKey,
                kind: DeploymentTypes.FragmentKind.MinterMarket
            }),
            proxy: proxy,
            implementation: implementation,
            salt: systemSalt,
            deploymentTime: uint64(block.timestamp)
        });
    }

    /// @notice Deploy a leveraged token (implementation + proxy) for a specific market.
    /// @dev Convenience wrapper combining deployMinterTokenImpl() and deployLeveragedProxy().
    function deployLeveragedToken(
        address baoFactoryAddr,
        string memory peg,
        string memory collateral,
        address tokenOwner,
        string memory systemSalt
    )
        internal
        returns (
            address impl,
            address proxy,
            DeploymentTypes.ImplementationRecord memory implRecord,
            DeploymentTypes.ProxyRecord memory proxyRecord
        )
    {
        string memory leveragedKey = string.concat(peg, "::", collateral, "::leveraged");
        console.log("  > %s", leveragedKey);

        // Deploy implementation
        (impl, implRecord) = deployMinterTokenImpl();
        console.log("      Impl:   %s", impl);
        implRecord.proxy = leveragedKey; // Associate with this proxy key

        // Deploy proxy
        (proxy, proxyRecord) = deployLeveragedProxy(baoFactoryAddr, peg, collateral, impl, tokenOwner, systemSalt);
    }

    /// @notice Deploy a leveraged token, record in state, and grant minter roles.
    /// @dev Full deployment including state recording and role setup.
    function deployLeveragedTokenWithRoles(
        DeploymentTypes.State memory stateData,
        Config_MinterMarket marketConfig,
        address baoFactoryAddr,
        address tokenOwner,
        string memory systemSalt
    ) internal returns (address leveragedToken) {
        IMarketConfig market = IMarketConfig(address(marketConfig));
        string memory marketKey = MinterMarketConfigLib.salt(marketConfig);
        (
            ,
            address proxy,
            DeploymentTypes.ImplementationRecord memory implRecord,
            DeploymentTypes.ProxyRecord memory proxyRecord
        ) = deployLeveragedToken(baoFactoryAddr, market.peg(), market.collateral(), tokenOwner, systemSalt);

        DeploymentState.recordImplementation(stateData, implRecord);
        DeploymentState.recordProxy(stateData, proxyRecord);

        leveragedToken = proxy;
        _registerForOwnershipTransfer(proxy, _saltString(proxyRecord.id));

        // Grant minter/burner roles to the market's minter contract
        console.log("      Roles:");
        address minter = _predictMinterAddress(baoFactoryAddr, systemSalt, marketKey);
        console.log("        MINTER -> %s", marketKey);
        _grantMinterRoles(leveragedToken, minter);
    }

    // ========== SHARED ROLE GRANTING ==========

    /// @notice Grant MINTER_ROLE and BURNER_ROLE to a minter contract.
    /// @dev Shared by both pegged and leveraged token deployment.
    function _grantMinterRoles(address token, address minter) private {
        uint256 minterRole = IMintableRole(token).MINTER_ROLE();
        uint256 burnerRole = IBurnableRole(token).BURNER_ROLE();
        IBaoRoles(token).grantRoles(minter, minterRole | burnerRole);
    }

    /// @notice Predict minter contract address from salt.
    /// @dev Legacy mainnet salt format appends "::minter" to the market key.
    function _predictMinterAddress(
        address baoFactoryAddr,
        string memory systemSalt,
        string memory marketKey
    ) private view returns (address) {
        bytes32 minterSalt = keccak256(abi.encodePacked(systemSalt, "::", marketKey, "::minter"));
        return IBaoFactory(baoFactoryAddr).predictAddress(minterSalt);
    }
}
