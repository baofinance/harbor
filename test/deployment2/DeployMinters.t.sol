// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "@bao-test/deployment/BaoDeploymentTest.sol";
import {BaoFactoryBytecode} from "@bao-factory/BaoFactoryBytecode.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {DeployMintersBase, AllMintersConfig} from "script/bao-basedeployment/DeployMintersBase.sol";
import {DeploymentTypes} from "script/bao-basedeployment/DeploymentTypes.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";
import {WellKnownAddress} from "script/config/chains/Config_Protocol.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2 as console} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @notice Interface to query well-known addresses from any config that inherits Config_Protocol.
interface IWellKnownAddresses {
    function getWellKnownAddresses() external pure returns (WellKnownAddress[] memory);
}

/// @notice Test harness for minter deployment (tokens + infrastructure).
contract TestDeployMintersHarness is DeployMintersBase {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function baoFactory() public pure override returns (address) {
        return BaoFactoryBytecode.PREDICTED_PROXY;
    }

    function _shouldPersistState() internal pure override returns (bool) {
        return false;
    }

    /// @notice Deploy all minter contracts (tokens + infrastructure).
    /// @dev Requires fork with real external contracts (wrapped collateral, etc).
    function deployAllMintersWrapper(string memory systemSaltArg, string memory network, bool useLocal) external {
        _setSystemSalt(systemSaltArg);
        AllMintersConfig memory config = createAllMintersConfig();
        deployAllMinters(config, network, useLocal);
    }

    /// @notice Return well-known addresses from the market config (which inherits chain config).
    /// @dev Queries the config's getWellKnownAddresses() - fully generic, no hardcoded list here.
    function queryWellKnownAddresses() external returns (WellKnownAddress[] memory) {
        // Create a market config to access chain-specific addresses
        // Market configs inherit from Config_Chain_* which provides getWellKnownAddresses()
        AllMintersConfig memory config = createAllMintersConfig();
        return IWellKnownAddresses(address(config.marketsETH[0])).getWellKnownAddresses();
    }
}

contract DeployMintersTest is BaoDeploymentTest {
    using stdJson for string;

    string private constant REFERENCE_SALT = "harbor_v1";
    string private constant CANDIDATE_SALT = "test";

    // Compute max label width for aligned output (harbor_v1 = 9, test = 4, so use 9)
    uint256 private constant LABEL_WIDTH = 9;

    // Artifact paths for different contract types
    string private constant TOKEN_ARTIFACT = "out/MintableBurnableERC20_v1.sol/MintableBurnableERC20_v1.json";
    string private constant MINTER_ARTIFACT = "out/Minter_v1.sol/Minter_v1.json";
    string private constant SPM_ARTIFACT = "out/StabilityPoolManager_v1.sol/StabilityPoolManager_v1.json";
    string private constant SP_ARTIFACT = "out/StabilityPool_v1.sol/StabilityPool_v1.json";
    string private constant RESERVE_ARTIFACT = "out/ReservePool_v1.sol/ReservePool_v1.json";
    string private constant GENESIS_ARTIFACT = "out/Genesis_v1.sol/Genesis_v1.json";

    /// @notice Contract spec for dynamic comparison. Maps salt suffixes to artifacts.
    struct ContractSpec {
        string salt; // e.g., "ETH::pegged", "ETH::fxUSD::minter"
        string artifact; // Artifact path for ABI loading
        string marketKey; // e.g., "ETH::fxUSD" for minter lookup (empty for pegged tokens)
    }

    // Market definitions: peg::collateral format
    function _getMarketSalts() private pure returns (string[7] memory) {
        return ["ETH::fxUSD", "BTC::fxUSD", "BTC::stETH", "GOLD::fxUSD", "GOLD::stETH", "EUR::fxUSD", "EUR::stETH"];
    }

    /// @notice Build the full list of contract specs to compare.
    /// @dev Matches the ownership transfer list: pegged tokens, leveraged tokens, then per-market infrastructure.
    function _buildContractSpecs() private pure returns (ContractSpec[] memory specs) {
        string[4] memory pegs = ["ETH", "BTC", "GOLD", "EUR"];
        string[7] memory markets = [
            "ETH::fxUSD",
            "BTC::fxUSD",
            "BTC::stETH",
            "GOLD::fxUSD",
            "GOLD::stETH",
            "EUR::fxUSD",
            "EUR::stETH"
        ];

        // 4 pegged + 7 leveraged + 7 markets × 6 contracts = 4 + 7 + 42 = 53
        specs = new ContractSpec[](53);
        uint256 idx;

        // Pegged tokens (one per peg)
        for (uint256 i = 0; i < 4; i++) {
            specs[idx++] = ContractSpec({
                salt: string.concat(pegs[i], "::pegged"),
                artifact: TOKEN_ARTIFACT,
                marketKey: ""
            });
        }

        // Leveraged tokens (one per market)
        for (uint256 i = 0; i < 7; i++) {
            specs[idx++] = ContractSpec({
                salt: string.concat(markets[i], "::leveraged"),
                artifact: TOKEN_ARTIFACT,
                marketKey: markets[i]
            });
        }

        // Per-market infrastructure contracts
        for (uint256 i = 0; i < 7; i++) {
            // Order matches ownership transfer list
            specs[idx++] = ContractSpec({
                salt: string.concat(markets[i], "::reservePool"),
                artifact: RESERVE_ARTIFACT,
                marketKey: markets[i]
            });
            specs[idx++] = ContractSpec({
                salt: string.concat(markets[i], "::minter"),
                artifact: MINTER_ARTIFACT,
                marketKey: markets[i]
            });
            specs[idx++] = ContractSpec({
                salt: string.concat(markets[i], "::stabilityPoolCollateral"),
                artifact: SP_ARTIFACT,
                marketKey: markets[i]
            });
            specs[idx++] = ContractSpec({
                salt: string.concat(markets[i], "::stabilityPoolLeveraged"),
                artifact: SP_ARTIFACT,
                marketKey: markets[i]
            });
            specs[idx++] = ContractSpec({
                salt: string.concat(markets[i], "::stabilityPoolManager"),
                artifact: SPM_ARTIFACT,
                marketKey: markets[i]
            });
            specs[idx++] = ContractSpec({
                salt: string.concat(markets[i], "::genesis"),
                artifact: GENESIS_ARTIFACT,
                marketKey: markets[i]
            });
        }
    }

    // Accumulates human-readable differences for summary output.
    string[] private diffLog;
    // Detailed mismatch records (with values/salts) emitted at the end.
    string[] private mismatchDetails;

    enum ReturnKind {
        Unknown,
        AddressKind,
        UintKind,
        IntKind,
        StringKind,
        BoolKind,
        TupleKind
    }

    // Populated per-token to support mismatch diagnostics.
    address[] private currentKnownAddrs;
    string[] private currentKnownSalts;

    TestDeployMintersHarness private harness;
    address private _factoryAddr;

    struct TokenCompareState {
        address refToken;
        address candToken;
        address[] refMinters;
        address[] candMinters;
        string[] minterKeys;
    }

    struct CompareTotals {
        uint256 total;
        uint256 passed;
    }

    struct FuncSpec {
        string sig;
        ReturnKind kind;
    }

    function setUp() public override {
        super.setUp();
        _factoryAddr = _baoFactory;

        // Create test harness after factory is ready
        harness = new TestDeployMintersHarness();

        // Allow harness to deploy via factory
        vm.prank(IBaoFactory(_factoryAddr).owner());
        IBaoFactory(_factoryAddr).setOperator(address(harness), 365 days);
    }

    function test_deployAllMinters_mainnetFork_() public {
        uint256 forkId = vm.createSelectFork(vm.rpcUrl("mainnet"));
        vm.selectFork(forkId);

        // Re-initialize harness on the forked mainnet state
        harness = new TestDeployMintersHarness();
        _factoryAddr = _baoFactory;
        vm.prank(IBaoFactory(_factoryAddr).owner());
        IBaoFactory(_factoryAddr).setOperator(address(harness), 365 days);

        harness.deployAllMintersWrapper(CANDIDATE_SALT, "mainnet", false);

        // Verify 4 pegged tokens were deployed
        address[4] memory peggedTokens = _predictPeggedTokens(CANDIDATE_SALT);
        for (uint256 i = 0; i < peggedTokens.length; i++) {
            assertTrue(peggedTokens[i] != address(0), "Pegged token address should not be zero");
            assertTrue(_hasCode(peggedTokens[i]), "Pegged token should have code");
        }

        // Verify each pegged token via ABI
        _verifyTokenViaABI(peggedTokens[0], "Harbor anchored ETH", "haETH");
        _verifyTokenViaABI(peggedTokens[1], "Harbor anchored BTC", "haBTC");
        _verifyTokenViaABI(peggedTokens[2], "Harbor anchored GOLD", "haGOLD");
        _verifyTokenViaABI(peggedTokens[3], "Harbor anchored EUR", "haEUR");

        // Verify 7 leveraged tokens were deployed
        address[7] memory leveragedTokens = _predictLeveragedTokens(CANDIDATE_SALT);
        for (uint256 i = 0; i < leveragedTokens.length; i++) {
            assertTrue(leveragedTokens[i] != address(0), "Leveraged token address should not be zero");
            assertTrue(_hasCode(leveragedTokens[i]), "Leveraged token should have code");
        }

        // Verify each leveraged token via ABI (name and symbol patterns)
        _verifyTokenViaABI(leveragedTokens[0], "Harbor sail: variable leveraged long fxUSD against ETH", "hsFXUSD-ETH");
        _verifyTokenViaABI(leveragedTokens[1], "Harbor sail: variable leveraged long fxUSD against BTC", "hsFXUSD-BTC");
        _verifyTokenViaABI(leveragedTokens[2], "Harbor sail: variable leveraged long stETH against BTC", "hsSTETH-BTC");
        _verifyTokenViaABI(
            leveragedTokens[3],
            "Harbor sail: variable leveraged long fxUSD against GOLD",
            "hsFXUSD-GOLD"
        );
        _verifyTokenViaABI(
            leveragedTokens[4],
            "Harbor sail: variable leveraged long stETH against GOLD",
            "hsSTETH-GOLD"
        );
        _verifyTokenViaABI(leveragedTokens[5], "Harbor sail: variable leveraged long fxUSD against EUR", "hsFXUSD-EUR");
        _verifyTokenViaABI(leveragedTokens[6], "Harbor sail: variable leveraged long stETH against EUR", "hsSTETH-EUR");
    }

    function test_compareMintersAgainstReference_mainnetFork_() public {
        uint256 forkId = vm.createSelectFork(vm.rpcUrl("mainnet"));
        vm.selectFork(forkId);

        // Re-initialize harness on the forked mainnet state
        harness = new TestDeployMintersHarness();
        _factoryAddr = _baoFactory;
        vm.prank(IBaoFactory(_factoryAddr).owner());
        IBaoFactory(_factoryAddr).setOperator(address(harness), 365 days);

        harness.deployAllMintersWrapper(CANDIDATE_SALT, "mainnet", false);

        _compareMintersAgainstReference(REFERENCE_SALT, CANDIDATE_SALT);
    }

    /// @dev Compare freshly deployed minters (candidateSalt) against existing deployment (referenceSalt).
    function _compareMintersAgainstReference(string memory referenceSalt, string memory candidateSalt) private {
        delete diffLog;
        delete mismatchDetails;

        ContractSpec[] memory specs = _buildContractSpecs();
        CompareTotals memory agg;

        // Build global address-to-salt mapping for ALL contracts in both deployments
        _buildGlobalAddressMapping(specs, referenceSalt, candidateSalt);

        for (uint256 i = 0; i < specs.length; i++) {
            ContractSpec memory spec = specs[i];
            string memory fullRefSalt = string.concat(referenceSalt, "::", spec.salt);

            bytes32 refSaltHash = keccak256(abi.encodePacked(referenceSalt, "::", spec.salt));
            bytes32 candSaltHash = keccak256(abi.encodePacked(candidateSalt, "::", spec.salt));

            address refAddr = IBaoFactory(_factoryAddr).predictAddress(refSaltHash);
            address candAddr = IBaoFactory(_factoryAddr).predictAddress(candSaltHash);

            if (!_hasCode(refAddr)) {
                mismatchDetails.push(string.concat("- ", fullRefSalt, ": missing code"));
                continue;
            }
            if (!_hasCode(candAddr)) {
                mismatchDetails.push(string.concat("- ", fullRefSalt, ": candidate missing code"));
                continue;
            }

            // Build TokenCompareState for this contract
            TokenCompareState memory s;
            s.refToken = refAddr;
            s.candToken = candAddr;

            // Set up minter addresses for role comparison (for address-arg view functions)
            if (bytes(spec.marketKey).length > 0) {
                s.refMinters = new address[](1);
                s.candMinters = new address[](1);
                s.minterKeys = new string[](1);
                s.refMinters[0] = IBaoFactory(_factoryAddr).predictAddress(
                    keccak256(abi.encodePacked(referenceSalt, "::", spec.marketKey, "::minter"))
                );
                s.candMinters[0] = IBaoFactory(_factoryAddr).predictAddress(
                    keccak256(abi.encodePacked(candidateSalt, "::", spec.marketKey, "::minter"))
                );
                s.minterKeys[0] = spec.marketKey;
            } else {
                // Pegged tokens: find all minters for this peg
                string memory peg = _extractPeg(spec.salt);
                (s.refMinters, s.minterKeys) = _predictMintersForPeg(referenceSalt, peg);
                (s.candMinters, ) = _predictMintersForPeg(candidateSalt, peg);
            }

            CompareTotals memory contractTotals = _processContract(fullRefSalt, s, spec.artifact);
            agg.total += contractTotals.total;
            agg.passed += contractTotals.passed;
        }

        console.log("");
        console.log(
            string.concat(
                "Summary ",
                vm.toString(agg.passed),
                "/",
                vm.toString(agg.total),
                " passed; ",
                vm.toString(agg.total - agg.passed),
                " diffs"
            )
        );
        console.log("");

        if (mismatchDetails.length > 0) {
            console.log("--- Mismatch details ---");
            for (uint256 i = 0; i < mismatchDetails.length; i++) {
                console.log(mismatchDetails[i]);
            }
        }
    }

    /// @notice Build global address-to-salt mapping for ALL contracts in both deployments.
    /// @dev This allows address resolution in any context, not just the current contract being compared.
    /// @dev Well-known addresses are queried from the harness (which inherits chain config).
    function _buildGlobalAddressMapping(
        ContractSpec[] memory specs,
        string memory referenceSalt,
        string memory candidateSalt
    ) private {
        // Query well-known addresses from harness (which queries the market config)
        WellKnownAddress[] memory wellKnown = harness.queryWellKnownAddresses();
        uint256 wellKnownCount = wellKnown.length;
        
        // Markets for price oracles
        string[7] memory markets = _getMarketSalts();
        uint256 priceOracleCount = markets.length * 2; // ref + candidate per market
        
        // Each spec creates 2 entries (ref + candidate) + well-known + price oracles
        uint256 totalEntries = specs.length * 2 + wellKnownCount + priceOracleCount;
        currentKnownAddrs = new address[](totalEntries);
        currentKnownSalts = new string[](totalEntries);

        uint256 idx;

        // Add well-known external addresses from harness config query
        for (uint256 i = 0; i < wellKnownCount; i++) {
            currentKnownAddrs[idx] = wellKnown[i].addr;
            currentKnownSalts[idx++] = wellKnown[i].label;
        }

        // Add all deployed contracts
        for (uint256 i = 0; i < specs.length; i++) {
            ContractSpec memory spec = specs[i];

            bytes32 refSaltHash = keccak256(abi.encodePacked(referenceSalt, "::", spec.salt));
            bytes32 candSaltHash = keccak256(abi.encodePacked(candidateSalt, "::", spec.salt));

            currentKnownAddrs[idx] = IBaoFactory(_factoryAddr).predictAddress(refSaltHash);
            currentKnownSalts[idx++] = string.concat(referenceSalt, "::", spec.salt);

            currentKnownAddrs[idx] = IBaoFactory(_factoryAddr).predictAddress(candSaltHash);
            currentKnownSalts[idx++] = string.concat(candidateSalt, "::", spec.salt);
        }
        
        // Add price oracle addresses for each market (not deployed by us, but needed for matching)
        for (uint256 i = 0; i < markets.length; i++) {
            string memory oracleSalt = string.concat(markets[i], "::wrappedPriceAggregator");
            
            bytes32 refSaltHash = keccak256(abi.encodePacked(referenceSalt, "::", oracleSalt));
            bytes32 candSaltHash = keccak256(abi.encodePacked(candidateSalt, "::", oracleSalt));

            currentKnownAddrs[idx] = IBaoFactory(_factoryAddr).predictAddress(refSaltHash);
            currentKnownSalts[idx++] = string.concat(referenceSalt, "::", oracleSalt);

            currentKnownAddrs[idx] = IBaoFactory(_factoryAddr).predictAddress(candSaltHash);
            currentKnownSalts[idx++] = string.concat(candidateSalt, "::", oracleSalt);
        }
    }

    /// @notice Extract the peg portion from a salt like "ETH::pegged" → "ETH"
    function _extractPeg(string memory salt) private pure returns (string memory) {
        bytes memory b = bytes(salt);
        for (uint256 i = 0; i + 1 < b.length; i++) {
            if (b[i] == ":" && b[i + 1] == ":") {
                bytes memory peg = new bytes(i);
                for (uint256 j = 0; j < i; j++) {
                    peg[j] = b[j];
                }
                return string(peg);
            }
        }
        return salt;
    }

    function _processContract(
        string memory label,
        TokenCompareState memory s,
        string memory artifactPath
    ) private returns (CompareTotals memory totals) {
        // Global address mapping is already populated by _buildGlobalAddressMapping
        totals = _compareNoArgViews(label, s, artifactPath);
        totals = _compareAddressArgViews(label, s, totals, artifactPath);
    }

    function _compareNoArgViews(
        string memory label,
        TokenCompareState memory s,
        string memory artifactPath
    ) private returns (CompareTotals memory totals) {
        FuncSpec[] memory specs = _loadZeroArgViewFunctions(artifactPath);
        for (uint256 i = 0; i < specs.length; i++) {
            totals = _compareCall(label, specs[i], s, totals);
        }
    }

    function _compareAddressArgViews(
        string memory label,
        TokenCompareState memory s,
        CompareTotals memory totals,
        string memory artifactPath
    ) private returns (CompareTotals memory) {
        FuncSpec[] memory sigs = _loadAddressViewFunctions(artifactPath);
        if (s.refMinters.length != s.candMinters.length) return totals;
        for (uint256 i = 0; i < sigs.length; i++) {
            for (uint256 j = 0; j < s.refMinters.length; j++) {
                totals = _compareCallAddressArg(label, sigs[i], s, s.refMinters[j], s.candMinters[j], j, totals);
            }
        }
        return totals;
    }

    function _loadZeroArgViewFunctions(string memory artifactPath) private view returns (FuncSpec[] memory sigs) {
        string memory raw = vm.readFile(artifactPath);
        uint256 len = _abiLength(raw);

        uint256 count;
        for (uint256 i = 0; i < len; i++) {
            string memory typeStr = _parseJsonString(raw, _abiPathType(i));
            if (keccak256(bytes(typeStr)) != keccak256("function")) continue;

            uint256 inputsLen = _inputsLength(raw, i);
            if (inputsLen != 0) continue;

            string memory mutability = _parseJsonString(raw, _abiPathStateMutability(i));
            bytes32 mutHash = keccak256(bytes(mutability));
            if (mutHash != keccak256("view") && mutHash != keccak256("pure")) continue;

            string memory name = _parseJsonString(raw, _abiPathName(i));
            if (_skipZeroArgFunction(name)) continue;

            ++count;
        }

        sigs = new FuncSpec[](count);
        uint256 idx;
        for (uint256 i = 0; i < len; i++) {
            string memory typeStr = _parseJsonString(raw, _abiPathType(i));
            if (keccak256(bytes(typeStr)) != keccak256("function")) continue;

            uint256 inputsLen = _inputsLength(raw, i);
            if (inputsLen != 0) continue;

            string memory mutability = _parseJsonString(raw, _abiPathStateMutability(i));
            bytes32 mutHash = keccak256(bytes(mutability));
            if (mutHash != keccak256("view") && mutHash != keccak256("pure")) continue;

            string memory name = _parseJsonString(raw, _abiPathName(i));
            if (_skipZeroArgFunction(name)) continue;
            sigs[idx++] = FuncSpec({sig: string.concat(name, "()"), kind: _returnKind(raw, i)});
        }
    }

    function _skipZeroArgFunction(string memory name) private pure returns (bool) {
        bytes32 h = keccak256(bytes(name));
        // Skip EIP-712 domain separator functions
        if (h == keccak256("DOMAIN_SEPARATOR")) return true;
        if (h == keccak256("DOMAIN_SEPARATORS")) return true;
        if (h == keccak256("eip712Domain")) return true;
        // Skip state-dependent functions that differ between fresh deployment and production
        if (h == keccak256("totalSupply")) return true;
        if (h == keccak256("collateralTotalBalance")) return true;
        if (h == keccak256("collateralTokenBalance")) return true;
        if (h == keccak256("totalAssetSupply")) return true;
        if (h == keccak256("harvestable")) return true;
        if (h == keccak256("leverageRatio")) return true;
        if (h == keccak256("leveragedTokenBalance")) return true;
        if (h == keccak256("leveragedTokenPrice")) return true;
        if (h == keccak256("mintLeveragedTokenIncentiveRatio")) return true;
        if (h == keccak256("mintPeggedTokenIncentiveRatio")) return true;
        if (h == keccak256("peggedTokenBalance")) return true;
        if (h == keccak256("redeemLeveragedTokenIncentiveRatio")) return true;
        if (h == keccak256("redeemPeggedTokenIncentiveRatio")) return true;
        if (h == keccak256("rebalanceable")) return true;
        if (h == keccak256("collateralRatio")) return true;
        // Skip genesis state functions (genesis ended, claims made)
        if (h == keccak256("genesisIsEnded")) return true;
        // Skip priceOracle (external contract, not factory-deployed)
        if (h == keccak256("priceOracle")) return true;
        return false;
    }

    function _returnKind(string memory raw, uint256 i) private view returns (ReturnKind) {
        uint256 outs = _outputsLength(raw, i);
        if (outs != 1) return ReturnKind.TupleKind;

        string memory t = _parseJsonString(raw, _abiPathOutputTypeAt(i, 0));
        bytes32 h = keccak256(bytes(t));
        if (h == keccak256("address")) return ReturnKind.AddressKind;
        if (h == keccak256("uint256")) return ReturnKind.UintKind;
        if (h == keccak256("int256")) return ReturnKind.IntKind;
        if (h == keccak256("string")) return ReturnKind.StringKind;
        if (h == keccak256("bool")) return ReturnKind.BoolKind;
        return ReturnKind.TupleKind;
    }

    function _loadAddressViewFunctions(string memory artifactPath) private view returns (FuncSpec[] memory sigs) {
        string memory raw = vm.readFile(artifactPath);
        uint256 len = _abiLength(raw);

        uint256 count;
        for (uint256 i = 0; i < len; i++) {
            if (!_isAddressViewEntry(raw, i)) continue;
            ++count;
        }

        sigs = new FuncSpec[](count);
        uint256 idx;
        for (uint256 i = 0; i < len; i++) {
            if (!_isAddressViewEntry(raw, i)) continue;
            string memory name = _parseJsonString(raw, _abiPathName(i));
            sigs[idx++] = FuncSpec({sig: string.concat(name, "(address)"), kind: _returnKind(raw, i)});
        }
    }

    // --- JSON ABI Parsing Helpers ---

    function _abiPathType(uint256 i) private pure returns (string memory) {
        return string.concat(".abi[", vm.toString(i), "].type");
    }

    function _abiPathStateMutability(uint256 i) private pure returns (string memory) {
        return string.concat(".abi[", vm.toString(i), "].stateMutability");
    }

    function _abiPathInputTypeAt(uint256 i, uint256 j) private pure returns (string memory) {
        return string.concat(".abi[", vm.toString(i), "].inputs[", vm.toString(j), "].type");
    }

    function _abiPathOutputTypeAt(uint256 i, uint256 j) private pure returns (string memory) {
        return string.concat(".abi[", vm.toString(i), "].outputs[", vm.toString(j), "].type");
    }

    function _abiPathName(uint256 i) private pure returns (string memory) {
        return string.concat(".abi[", vm.toString(i), "].name");
    }

    function _abiLength(string memory raw) private view returns (uint256 len) {
        while (true) {
            string memory path = _abiPathType(len);
            (bool ok, ) = _tryParseJsonString(raw, path);
            if (!ok) break;
            ++len;
        }
        require(len > 0, "abi length zero");
    }

    function _outputsLength(string memory raw, uint256 i) private view returns (uint256 len) {
        while (true) {
            string memory path = _abiPathOutputTypeAt(i, len);
            (bool ok, ) = _tryParseJsonString(raw, path);
            if (!ok) break;
            ++len;
        }
    }

    function _inputsLength(string memory raw, uint256 i) private view returns (uint256 len) {
        while (true) {
            string memory path = _abiPathInputTypeAt(i, len);
            (bool ok, ) = _tryParseJsonString(raw, path);
            if (!ok) break;
            ++len;
        }
    }

    function _isAddressViewEntry(string memory raw, uint256 i) private view returns (bool) {
        uint256 _balanceCheck = address(this).balance;
        if (_balanceCheck == type(uint256).max) return false;

        string memory typeStr = _parseJsonString(raw, _abiPathType(i));
        if (keccak256(bytes(typeStr)) != keccak256("function")) return false;

        uint256 inputsLen = _inputsLength(raw, i);
        if (inputsLen != 1) return false;

        string memory inputType = _parseJsonString(raw, _abiPathInputTypeAt(i, 0));
        if (keccak256(bytes(inputType)) != keccak256("address")) return false;

        string memory mutability = _parseJsonString(raw, _abiPathStateMutability(i));
        bytes32 mutHash = keccak256(bytes(mutability));
        return mutHash == keccak256("view") || mutHash == keccak256("pure");
    }

    function _tryParseJsonString(
        string memory raw,
        string memory path
    ) private view returns (bool ok, string memory value) {
        uint256 _balanceCheck = address(this).balance;
        if (_balanceCheck == type(uint256).max) return (false, "");

        try vm.parseJson(raw, path) returns (bytes memory data) {
            if (data.length == 0) return (false, "");
            value = abi.decode(data, (string));
            ok = true;
        } catch {
            return (false, "");
        }
    }

    function _parseJsonString(string memory raw, string memory path) private pure returns (string memory value) {
        try vm.parseJson(raw, path) returns (bytes memory data) {
            if (data.length == 0) {
                console.log("parseJson string empty payload at %s", path);
                revert("json string decode length");
            }
            value = abi.decode(data, (string));
        } catch (bytes memory err) {
            console.log("parseJson string failed at %s", path);
            if (err.length > 0) {
                assembly {
                    revert(add(err, 32), mload(err))
                }
            }
            revert("parseJson string failed");
        }
    }

    // --- Comparison Logic ---

    function _compareCall(
        string memory label,
        FuncSpec memory spec,
        TokenCompareState memory s,
        CompareTotals memory totals
    ) private returns (CompareTotals memory) {
        ++totals.total;
        bool ok = _compareNoArgOutputs(label, spec, s.refToken, s.candToken);
        if (ok) ++totals.passed;
        _logCheck(ok, string.concat(label, " ", spec.sig));
        return totals;
    }

    function _compareNoArgOutputs(
        string memory label,
        FuncSpec memory spec,
        address refToken,
        address candToken
    ) private returns (bool ok) {
        (bool okRef, bytes memory refOut) = refToken.staticcall(abi.encodeWithSignature(spec.sig));
        (bool okCand, bytes memory candOut) = candToken.staticcall(abi.encodeWithSignature(spec.sig));

        bool outputsEqual = keccak256(refOut) == keccak256(candOut);
        ok = (okRef && okCand && outputsEqual) || (!okRef && !okCand && outputsEqual);
        if (!ok) {
            if (okRef && okCand && spec.kind == ReturnKind.AddressKind && _secondChanceAddressMatch(refOut, candOut)) {
                ok = true;
            } else {
                _logMismatch(label, spec.sig, refOut, candOut, "", spec.kind);
            }
        }
    }

    function _compareCallAddressArg(
        string memory label,
        FuncSpec memory spec,
        TokenCompareState memory s,
        address refArg,
        address candArg,
        uint256 argIndex,
        CompareTotals memory totals
    ) private returns (CompareTotals memory) {
        string memory sigWithArg = string.concat(spec.sig, " arg#", vm.toString(argIndex));
        ++totals.total;
        bool ok = _compareAddressOutputs(label, sigWithArg, s.refToken, s.candToken, spec, refArg, candArg);
        if (ok) ++totals.passed;
        _logCheck(ok, string.concat(label, " ", sigWithArg));
        return totals;
    }

    function _compareAddressOutputs(
        string memory label,
        string memory sigWithArg,
        address refToken,
        address candToken,
        FuncSpec memory spec,
        address refArg,
        address candArg
    ) private returns (bool ok) {
        (bool okRef, bytes memory refOut) = refToken.staticcall(abi.encodeWithSignature(spec.sig, refArg));
        (bool okCand, bytes memory candOut) = candToken.staticcall(abi.encodeWithSignature(spec.sig, candArg));

        bool outputsEqual = keccak256(refOut) == keccak256(candOut);
        ok = (okRef && okCand && outputsEqual) || (!okRef && !okCand && outputsEqual);
        if (!ok) {
            if (okRef && okCand && spec.kind == ReturnKind.AddressKind && _secondChanceAddressMatch(refOut, candOut)) {
                ok = true;
            } else {
                _logMismatch(label, sigWithArg, refOut, candOut, _addressArgContext(refArg, candArg), spec.kind);
            }
        }
    }

    // --- Prediction Helpers ---

    function _predictPeggedTokens(string memory systemSalt) internal view returns (address[4] memory tokens) {
        tokens[0] = IBaoFactory(_factoryAddr).predictAddress(
            keccak256(abi.encodePacked(systemSalt, "::", "ETH::pegged"))
        );
        tokens[1] = IBaoFactory(_factoryAddr).predictAddress(
            keccak256(abi.encodePacked(systemSalt, "::", "BTC::pegged"))
        );
        tokens[2] = IBaoFactory(_factoryAddr).predictAddress(
            keccak256(abi.encodePacked(systemSalt, "::", "GOLD::pegged"))
        );
        tokens[3] = IBaoFactory(_factoryAddr).predictAddress(
            keccak256(abi.encodePacked(systemSalt, "::", "EUR::pegged"))
        );
    }

    function _predictLeveragedTokens(string memory systemSalt) internal view returns (address[7] memory tokens) {
        string[7] memory marketSalts = _getMarketSalts();
        for (uint256 i = 0; i < 7; i++) {
            string memory leveragedKey = string.concat(marketSalts[i], "::leveraged");
            tokens[i] = IBaoFactory(_factoryAddr).predictAddress(
                keccak256(abi.encodePacked(systemSalt, "::", leveragedKey))
            );
        }
    }

    function _predictMintersForPeg(
        string memory systemSalt,
        string memory peg
    ) private view returns (address[] memory addrs, string[] memory keys) {
        string[7] memory marketSalts = _getMarketSalts();
        uint256 count;
        for (uint256 i = 0; i < 7; i++) {
            if (_marketMatchesPeg(marketSalts[i], peg)) ++count;
        }
        addrs = new address[](count);
        keys = new string[](count);
        uint256 idx;
        for (uint256 i = 0; i < 7; i++) {
            if (!_marketMatchesPeg(marketSalts[i], peg)) continue;
            addrs[idx] = IBaoFactory(_factoryAddr).predictAddress(
                keccak256(abi.encodePacked(systemSalt, "::", marketSalts[i], "::minter"))
            );
            keys[idx] = marketSalts[i];
            ++idx;
        }
    }

    function _marketMatchesPeg(string memory marketSalt, string memory peg) private pure returns (bool) {
        bytes memory m = bytes(marketSalt);
        bytes memory p = bytes(peg);
        if (m.length < p.length) return false;
        for (uint256 i = 0; i < p.length; i++) {
            if (m[i] != p[i]) return false;
        }
        return true;
    }

    // --- Logging Helpers ---

    function _logCheck(bool ok, string memory label) private {
        console.log(string.concat(ok ? "[OK] " : "[ERR] ", label));
        if (!ok) {
            diffLog.push(label);
        }
    }

    function _logMismatch(
        string memory label,
        string memory sig,
        bytes memory refOut,
        bytes memory candOut,
        string memory context,
        ReturnKind kind
    ) private {
        string memory prefix = bytes(context).length == 0 ? "" : string.concat(" ", context);
        string memory header = string.concat("- ", label, " ", sig, prefix);
        mismatchDetails.push(header);

        // For tuples, do field-by-field comparison
        if (kind == ReturnKind.TupleKind) {
            // Special handling for config() which returns IMinter.Config with nested dynamic arrays
            if (keccak256(bytes(sig)) == keccak256("config()")) {
                _logMinterConfigMismatch(refOut, candOut);
            } else {
                _logTupleMismatch(refOut, candOut);
            }
        } else {
            // Simple types: format with aligned labels
            string memory refStr = _formatReturn(refOut, kind);
            string memory candStr = _formatReturn(candOut, kind);
            string memory refLine = string.concat("    ", _padLabel(REFERENCE_SALT), ": ", refStr);
            string memory candLine = string.concat("    ", _padLabel(CANDIDATE_SALT), ": ", candStr);
            mismatchDetails.push(refLine);
            mismatchDetails.push(candLine);
        }
    }

    /// @notice Log tuple mismatch with field-by-field comparison.
    /// @dev Parses tuples as sequences of 32-byte words, showing only differing fields with index.
    /// @dev Applies second-chance matching for addresses with matching salt tails.
    function _logTupleMismatch(bytes memory refOut, bytes memory candOut) private {
        uint256 refWords = refOut.length / 32;
        uint256 candWords = candOut.length / 32;
        uint256 maxWords = refWords > candWords ? refWords : candWords;

        for (uint256 i = 0; i < maxWords; i++) {
            bytes32 refWord = i < refWords ? _extractWord(refOut, i) : bytes32(0);
            bytes32 candWord = i < candWords ? _extractWord(candOut, i) : bytes32(0);

            if (refWord != candWord) {
                // Try second-chance matching for addresses with matching salt tails
                if (_secondChanceWordMatch(refWord, candWord)) {
                    continue; // Equivalent addresses, skip this field
                }
                
                // Determine likely type from content and format accordingly
                string memory refFormatted = _formatWord(refWord);
                string memory candFormatted = _formatWord(candWord);

                string memory idxStr = string.concat("[field ", vm.toString(i), "]");
                mismatchDetails.push(string.concat("    ", idxStr));
                mismatchDetails.push(string.concat("      ", _padLabel(REFERENCE_SALT), ": ", refFormatted));
                mismatchDetails.push(string.concat("      ", _padLabel(CANDIDATE_SALT), ": ", candFormatted));
            }
        }
    }

    /// @notice Decode and compare IMinter.Config structs field by field.
    /// @dev Properly handles nested IncentiveConfig with dynamic arrays.
    function _logMinterConfigMismatch(bytes memory refOut, bytes memory candOut) private {
        // Decode both configs using proper ABI decoding
        IMinter.Config memory refConfig = abi.decode(refOut, (IMinter.Config));
        IMinter.Config memory candConfig = abi.decode(candOut, (IMinter.Config));

        // Compare each IncentiveConfig
        _compareIncentiveConfig("mintPeggedIncentiveConfig", refConfig.mintPeggedIncentiveConfig, candConfig.mintPeggedIncentiveConfig);
        _compareIncentiveConfig("redeemPeggedIncentiveConfig", refConfig.redeemPeggedIncentiveConfig, candConfig.redeemPeggedIncentiveConfig);
        _compareIncentiveConfig("mintLeveragedIncentiveConfig", refConfig.mintLeveragedIncentiveConfig, candConfig.mintLeveragedIncentiveConfig);
        _compareIncentiveConfig("redeemLeveragedIncentiveConfig", refConfig.redeemLeveragedIncentiveConfig, candConfig.redeemLeveragedIncentiveConfig);
    }

    /// @notice Compare two IncentiveConfig structs and log differences.
    function _compareIncentiveConfig(
        string memory fieldName,
        IMinter.IncentiveConfig memory ref,
        IMinter.IncentiveConfig memory cand
    ) private {
        bool hasDiff = false;
        
        // Check if lengths differ
        if (ref.collateralRatioBandUpperBounds.length != cand.collateralRatioBandUpperBounds.length) {
            hasDiff = true;
        }
        if (ref.incentiveRatios.length != cand.incentiveRatios.length) {
            hasDiff = true;
        }
        
        // Check values (up to min length)
        uint256 boundsLen = ref.collateralRatioBandUpperBounds.length < cand.collateralRatioBandUpperBounds.length 
            ? ref.collateralRatioBandUpperBounds.length 
            : cand.collateralRatioBandUpperBounds.length;
        for (uint256 i = 0; i < boundsLen; i++) {
            if (ref.collateralRatioBandUpperBounds[i] != cand.collateralRatioBandUpperBounds[i]) {
                hasDiff = true;
                break;
            }
        }
        
        uint256 ratiosLen = ref.incentiveRatios.length < cand.incentiveRatios.length 
            ? ref.incentiveRatios.length 
            : cand.incentiveRatios.length;
        for (uint256 i = 0; i < ratiosLen; i++) {
            if (ref.incentiveRatios[i] != cand.incentiveRatios[i]) {
                hasDiff = true;
                break;
            }
        }
        
        if (hasDiff) {
            mismatchDetails.push(string.concat("    [", fieldName, "]"));
            mismatchDetails.push(string.concat("      ", _padLabel(REFERENCE_SALT), ": ", _formatIncentiveConfig(ref)));
            mismatchDetails.push(string.concat("      ", _padLabel(CANDIDATE_SALT), ": ", _formatIncentiveConfig(cand)));
        }
    }

    /// @notice Format an IncentiveConfig as a human-readable string.
    function _formatIncentiveConfig(IMinter.IncentiveConfig memory cfg) private pure returns (string memory) {
        string memory bounds = _formatUintArray(cfg.collateralRatioBandUpperBounds);
        string memory ratios = _formatIntArray(cfg.incentiveRatios);
        return string.concat("bounds=", bounds, " ratios=", ratios);
    }

    /// @notice Format uint256[] as comma-separated values with scientific notation.
    function _formatUintArray(uint256[] memory arr) private pure returns (string memory) {
        if (arr.length == 0) return "[]";
        
        string memory result = "[";
        for (uint256 i = 0; i < arr.length; i++) {
            if (i > 0) result = string.concat(result, ", ");
            result = string.concat(result, _formatUintScientific(arr[i]));
        }
        return string.concat(result, "]");
    }

    /// @notice Format int256[] as comma-separated values with scientific notation.
    function _formatIntArray(int256[] memory arr) private pure returns (string memory) {
        if (arr.length == 0) return "[]";
        
        string memory result = "[";
        for (uint256 i = 0; i < arr.length; i++) {
            if (i > 0) result = string.concat(result, ", ");
            result = string.concat(result, _formatIntScientific(arr[i]));
        }
        return string.concat(result, "]");
    }

    /// @notice Format uint256 with scientific notation for readability.
    function _formatUintScientific(uint256 v) private pure returns (string memory) {
        if (v == 0) return "0";
        if (v >= 1e18 && v % 1e15 == 0) {
            uint256 mantissa = v / 1e15;
            return string.concat(_uintToString(mantissa / 1000), ".", _padDecimals(mantissa % 1000, 3), "e18");
        }
        if (v >= 1e15 && v % 1e12 == 0) {
            uint256 mantissa = v / 1e12;
            return string.concat(_uintToString(mantissa / 1000), ".", _padDecimals(mantissa % 1000, 3), "e15");
        }
        return _uintToString(v);
    }

    /// @notice Format int256 with scientific notation for readability.
    function _formatIntScientific(int256 v) private pure returns (string memory) {
        if (v == 0) return "0";
        bool negative = v < 0;
        uint256 absVal = negative ? uint256(-v) : uint256(v);
        string memory formatted = _formatUintScientific(absVal);
        return negative ? string.concat("-", formatted) : formatted;
    }

    /// @notice Pad number with leading zeros to specified width.
    function _padDecimals(uint256 v, uint256 width) private pure returns (string memory) {
        string memory s = _uintToString(v);
        bytes memory b = bytes(s);
        if (b.length >= width) return s;
        
        bytes memory padded = new bytes(width);
        uint256 padding = width - b.length;
        for (uint256 i = 0; i < padding; i++) {
            padded[i] = "0";
        }
        for (uint256 i = 0; i < b.length; i++) {
            padded[padding + i] = b[i];
        }
        return string(padded);
    }

    /// @notice Simple uint to string conversion.
    function _uintToString(uint256 v) private pure returns (string memory) {
        if (v == 0) return "0";
        uint256 temp = v;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (v != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(v % 10)));
            v /= 10;
        }
        return string(buffer);
    }

    /// @notice Second-chance matching for 32-byte words that might be addresses with matching salt tails.
    function _secondChanceWordMatch(bytes32 refWord, bytes32 candWord) private view returns (bool) {
        uint256 refVal = uint256(refWord);
        uint256 candVal = uint256(candWord);
        
        // Both must look like addresses (fit in uint160)
        if (refVal > type(uint160).max || candVal > type(uint160).max) return false;
        if (refVal == 0 || candVal == 0) return false;
        
        address refAddr = address(uint160(refVal));
        address candAddr = address(uint160(candVal));
        
        string memory refSalt = _findSalt(refAddr);
        string memory candSalt = _findSalt(candAddr);
        
        // Both must have known salts
        if (bytes(refSalt).length == 0 || bytes(candSalt).length == 0) return false;
        
        // Compare salt tails (strip the system prefix)
        string memory refTail = _saltTail(refSalt);
        string memory candTail = _saltTail(candSalt);
        
        return keccak256(bytes(refTail)) == keccak256(bytes(candTail));
    }

    /// @notice Extract 32-byte word at index from bytes.
    function _extractWord(bytes memory data, uint256 index) private pure returns (bytes32 word) {
        uint256 offset = index * 32;
        assembly {
            word := mload(add(add(data, 32), offset))
        }
    }

    /// @notice Format a 32-byte word, guessing type from content.
    function _formatWord(bytes32 word) private view returns (string memory) {
        uint256 value = uint256(word);

        // Check if it looks like an address (top 12 bytes are zero, bottom 20 are non-zero)
        if (value != 0 && value <= type(uint160).max) {
            address addr = address(uint160(value));
            string memory salt = _findSalt(addr);
            // If we have a known salt OR the address has code, treat as address
            if (bytes(salt).length > 0 || _hasCode(addr)) {
                return _formatAddr(addr, salt);
            }
        }

        // Otherwise format as uint with scientific notation
        return _formatUint(value);
    }

    /// @notice Pad label to LABEL_WIDTH for aligned output.
    function _padLabel(string memory label) private pure returns (string memory) {
        bytes memory b = bytes(label);
        if (b.length >= LABEL_WIDTH) return label;

        bytes memory padded = new bytes(LABEL_WIDTH);
        for (uint256 i = 0; i < b.length; i++) {
            padded[i] = b[i];
        }
        for (uint256 i = b.length; i < LABEL_WIDTH; i++) {
            padded[i] = " ";
        }
        return string(padded);
    }

    function _formatReturn(bytes memory data, ReturnKind kind) private view returns (string memory) {
        if (kind == ReturnKind.AddressKind) {
            (bool ok, address a) = _tryDecodeAddress(data);
            if (ok) {
                string memory salt = _findSalt(a);
                return _formatAddr(a, salt);
            }
        } else if (kind == ReturnKind.UintKind) {
            (bool ok, uint256 v) = _tryDecodeUint(data);
            if (ok) return _formatUint(v);
        } else if (kind == ReturnKind.IntKind) {
            (bool ok, int256 v) = _tryDecodeInt(data);
            if (ok) return _formatInt(v);
        } else if (kind == ReturnKind.StringKind) {
            (bool ok, string memory s) = _tryDecodeString(data);
            if (ok) return s;
        } else if (kind == ReturnKind.BoolKind) {
            (bool ok, bool b) = _tryDecodeBool(data);
            if (ok) return b ? "true" : "false";
        }
        return _toHex(data);
    }

    /// @notice Format uint256 with scientific notation suffix for large values.
    function _formatUint(uint256 v) private pure returns (string memory) {
        if (v == 0) return "0";
        if (v < 1000) return vm.toString(v);

        // Count digits and compute scientific notation
        uint256 digits = 0;
        uint256 temp = v;
        while (temp > 0) {
            digits++;
            temp /= 10;
        }

        // Get mantissa: compute divisor to get first digit, then extract 2 decimal places
        uint256 exp = digits - 1;
        uint256 divisor = 1;
        for (uint256 i = 0; i < exp; i++) {
            divisor *= 10;
        }
        uint256 mantissaWhole = v / divisor;
        // For fractional part, divide by (divisor/100) to avoid overflow
        // remainder = v % divisor gives us everything after the first digit
        // Scale that to 2 decimal places
        uint256 remainder = v % divisor;
        uint256 mantissaFrac = (exp >= 2) ? (remainder / (divisor / 100)) : ((remainder * 100) / divisor);

        // Format: "123456789 [1.23e8]"
        string memory sci = string.concat(
            " [",
            vm.toString(mantissaWhole),
            ".",
            mantissaFrac < 10 ? "0" : "",
            vm.toString(mantissaFrac),
            "e",
            vm.toString(exp),
            "]"
        );
        return string.concat(vm.toString(v), sci);
    }

    /// @notice Format int256 with scientific notation suffix for large values.
    function _formatInt(int256 v) private pure returns (string memory) {
        if (v >= 0) {
            return _formatUint(uint256(v));
        }
        // Negative: format absolute value with minus prefix
        uint256 absVal = uint256(-v);
        return string.concat("-", _formatUint(absVal));
    }

    function _tryDecodeUint(bytes memory data) private pure returns (bool ok, uint256 v) {
        if (data.length < 32) return (false, 0);
        v = abi.decode(data, (uint256));
        ok = true;
    }

    function _tryDecodeInt(bytes memory data) private pure returns (bool ok, int256 v) {
        if (data.length < 32) return (false, 0);
        v = abi.decode(data, (int256));
        ok = true;
    }

    function _tryDecodeBool(bytes memory data) private pure returns (bool ok, bool v) {
        if (data.length < 32) return (false, false);
        v = abi.decode(data, (bool));
        ok = true;
    }

    function _tryDecodeString(bytes memory data) private pure returns (bool ok, string memory v) {
        if (data.length < 32) return (false, "");
        v = abi.decode(data, (string));
        ok = true;
    }

    function _secondChanceAddressMatch(bytes memory refOut, bytes memory candOut) private view returns (bool matched) {
        (bool refOk, address refAddr) = _tryDecodeAddress(refOut);
        (bool candOk, address candAddr) = _tryDecodeAddress(candOut);
        if (!refOk || !candOk) return false;

        string memory refSalt = _findSalt(refAddr);
        string memory candSalt = _findSalt(candAddr);
        if (bytes(refSalt).length == 0 || bytes(candSalt).length == 0) return false;

        string memory refTail = _saltTail(refSalt);
        string memory candTail = _saltTail(candSalt);
        if (keccak256(bytes(refTail)) != keccak256(bytes(candTail))) return false;

        matched = true;
        console.log(
            string.concat(
                "    address mismatch tolerated via salt tail match: ref=",
                vm.toString(refAddr),
                " (",
                refSalt,
                ") vs cand=",
                vm.toString(candAddr),
                " (",
                candSalt,
                ")"
            )
        );
    }

    function _findSalt(address addr) private view returns (string memory salt) {
        for (uint256 i = 0; i < currentKnownAddrs.length; i++) {
            if (currentKnownAddrs[i] == addr) {
                return currentKnownSalts[i];
            }
        }
        return "";
    }

    function _addressArgContext(address refArg, address candArg) private view returns (string memory) {
        if (refArg == address(0) && candArg == address(0)) return "";
        string memory refStr = _formatAddr(refArg, _findSalt(refArg));
        string memory candStr = _formatAddr(candArg, _findSalt(candArg));
        if (refArg == candArg) {
            return string.concat("arg=", refStr);
        }
        return string.concat("refArg=", refStr, " candArg=", candStr);
    }

    function _formatAddr(address addr, string memory salt) private pure returns (string memory) {
        if (addr == address(0)) return "<zero-address>";
        // Show only salt when known (more readable), otherwise show address
        return bytes(salt).length == 0 ? vm.toString(addr) : salt;
    }

    function _saltTail(string memory salt) private pure returns (string memory) {
        bytes memory b = bytes(salt);
        for (uint256 i = 0; i + 1 < b.length; i++) {
            if (b[i] == ":" && b[i + 1] == ":") {
                uint256 tailLen = b.length - (i + 2);
                bytes memory out = new bytes(tailLen);
                for (uint256 j = 0; j < tailLen; j++) {
                    out[j] = b[i + 2 + j];
                }
                return string(out);
            }
        }
        return salt;
    }

    function _tryDecodeAddress(bytes memory data) private pure returns (bool ok, address addr) {
        if (data.length < 32) return (false, address(0));
        addr = address(uint160(uint256(abi.decode(data, (uint256)))));
        ok = true;
    }

    function _toHex(bytes memory data) private pure returns (string memory) {
        bytes16 alphabet = 0x30313233343536373839616263646566;
        bytes memory out = new bytes(2 + data.length * 2);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i = 0; i < data.length; i++) {
            out[2 + i * 2] = alphabet[uint8(data[i] >> 4)];
            out[3 + i * 2] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(out);
    }

    function _hasCode(address target) private view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(target)
        }
        return size > 0;
    }

    /// @notice Verify a token via ABI calls.
    function _verifyTokenViaABI(
        address tokenAddr,
        string memory expectedName,
        string memory expectedSymbol
    ) private view {
        MintableBurnableERC20_v1 token = MintableBurnableERC20_v1(tokenAddr);
        assertEq(token.name(), expectedName, "Wrong name");
        assertEq(token.symbol(), expectedSymbol, "Wrong symbol");
        assertEq(token.decimals(), 18, "Wrong decimals");
    }
}
