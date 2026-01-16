// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {Deploy_BTC_Minter} from "script/src/Deploy_BTC_Minter.sol";
import {Deploy_ETH_Minter} from "script/src/Deploy_ETH_Minter.sol";
import {Deploy_EUR_Minter} from "script/src/Deploy_EUR_Minter.sol";
import {Deploy_GOLD_Minter} from "script/src/Deploy_GOLD_Minter.sol";
import {Deploy_SILVER_Minter} from "script/src/Deploy_SILVER_Minter.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "script/config/ConfigBase.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";
import {WellKnownAddress} from "@bao-script/deployment/FactoryDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {console2 as console} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @notice Interface to query well-known addresses from any chain config.
interface IWellKnownAddresses {
    function getWellKnownAddresses() external pure returns (WellKnownAddress[] memory);
}

/// @notice Test contract that inherits from all deployers for direct access to internal functions.
contract DeployMintersTest is
    BaoTest,
    Deploy_BTC_Minter,
    Deploy_ETH_Minter,
    Deploy_EUR_Minter,
    Deploy_GOLD_Minter,
    Deploy_SILVER_Minter
{
    using stdJson for string;
    using MinterMarketConfigLib for Config_MinterMarket;

    // ========== DEPLOYER OVERRIDES ==========

    function _shouldPersistState() internal pure override returns (bool) {
        return false;
    }

    // ========== TEST INFRASTRUCTURE ==========

    // Label width for aligned output (longest salt prefix like "harbor_v1_candidate" = 19)
    uint256 private constant LABEL_WIDTH = 19;

    // BaoFactory address, set up in setUp()
    address internal _baoFactory;

    /// @notice Contract spec for dynamic comparison. Maps salt suffixes to artifacts.
    struct ContractSpec {
        string salt; // e.g., "ETH::pegged", "ETH::fxUSD::minter"
        string artifact; // Artifact path for ABI loading
        string marketKey; // e.g., "ETH::fxUSD" for minter lookup (empty for pegged tokens)
    }

    /// @notice Build the full list of contract specs to compare.
    /// @dev Matches the ownership transfer list: pegged tokens, leveraged tokens, then per-market infrastructure.
    /// @param pegName The peg identifier (e.g., "BTC", "SILVER")
    /// @param mktConfigs Array of market configs to compare
    function _buildContractSpecs(
        string memory pegName,
        Config_MinterMarket[] memory mktConfigs
    ) private view returns (ContractSpec[] memory specs) {
        // 1 pegged + mktConfigs.length leveraged + mktConfigs.length × 6 infrastructure
        uint256 totalSpecs = 1 + mktConfigs.length + mktConfigs.length * 6;
        specs = new ContractSpec[](totalSpecs);
        uint256 idx;

        // Pegged token
        specs[idx++] = ContractSpec({
            salt: string.concat(pegName, "::pegged"),
            artifact: "out/MintableBurnableERC20_v1.sol/MintableBurnableERC20_v1.json",
            marketKey: ""
        });

        // Leveraged tokens (one per market)
        for (uint256 i = 0; i < mktConfigs.length; i++) {
            string memory marketKey = mktConfigs[i].salt();
            specs[idx++] = ContractSpec({
                salt: string.concat(marketKey, "::leveraged"),
                artifact: "out/MintableBurnableERC20_v1.sol/MintableBurnableERC20_v1.json",
                marketKey: marketKey
            });
        }

        // Per-market infrastructure contracts
        for (uint256 i = 0; i < mktConfigs.length; i++) {
            string memory marketKey = mktConfigs[i].salt();
            // Order matches ownership transfer list
            specs[idx++] = ContractSpec({
                salt: string.concat(marketKey, "::reservePool"),
                artifact: "out/ReservePool_v1.sol/ReservePool_v1.json",
                marketKey: marketKey
            });
            specs[idx++] = ContractSpec({
                salt: string.concat(marketKey, "::minter"),
                artifact: "out/Minter_v1.sol/Minter_v1.json",
                marketKey: marketKey
            });
            specs[idx++] = ContractSpec({
                salt: string.concat(marketKey, "::stabilityPoolCollateral"),
                artifact: "out/StabilityPool_v1.sol/StabilityPool_v1.json",
                marketKey: marketKey
            });
            specs[idx++] = ContractSpec({
                salt: string.concat(marketKey, "::stabilityPoolLeveraged"),
                artifact: "out/StabilityPool_v1.sol/StabilityPool_v1.json",
                marketKey: marketKey
            });
            specs[idx++] = ContractSpec({
                salt: string.concat(marketKey, "::stabilityPoolManager"),
                artifact: "out/StabilityPoolManager_v1.sol/StabilityPoolManager_v1.json",
                marketKey: marketKey
            });
            specs[idx++] = ContractSpec({
                salt: string.concat(marketKey, "::genesis"),
                artifact: "out/Genesis_v1.sol/Genesis_v1.json",
                marketKey: marketKey
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
        AddressArrayKind,
        UintKind,
        IntKind,
        StringKind,
        BoolKind,
        TupleKind
    }

    // Populated per-deployment to support mismatch diagnostics and address-arg view testing.
    // Reference addresses (from reference deployment or well-known)
    address[] private refKnownAddrs;
    // Candidate addresses (corresponding to refKnownAddrs by index)
    address[] private candKnownAddrs;
    // Salt/label for each address pair
    string[] private knownSalts;

    // Well-known addresses cache (populated on first use)
    WellKnownAddress[] private _wellKnownCache;

    struct TokenCompareState {
        address refToken;
        address candToken;
    }

    struct CompareTotals {
        uint256 total;
        uint256 passed;
    }

    struct FuncSpec {
        string sig;
        ReturnKind kind;
    }

    function setUp() public virtual {
        _baoFactory = _ensureBaoFactory();
    }

    function test_BTC() public {
        string memory refSalt = "harbor_v1";
        _forkAndSetup();
        (ConfigPeg peg, Config_MinterMarket[] memory mktConfigs) = createBTCMintersConfig();
        deployForPeg(string.concat(refSalt, "_candidate"), peg, mktConfigs, "mainnet", true, mktConfigs);
        _compareMintersAgainstReference(refSalt, peg, mktConfigs);
    }

    function test_OG_BTC() public {
        string memory refSalt = "harbor_v1";
        _forkAndSetup();

        (ConfigPeg btcPeg, Config_MinterMarket[] memory btcMkts) = createBTCMintersConfig();
        deployForPeg(string.concat(refSalt, "_candidate"), btcPeg, btcMkts, "mainnet", true, btcMkts);

        _compareMintersAgainstReference(refSalt, btcPeg, btcMkts);
    }

    function test_OG_ETH() public {
        string memory refSalt = "harbor_v1";
        _forkAndSetup();

        (ConfigPeg ethPeg, Config_MinterMarket[] memory ethMkts) = createETHMintersConfig();
        deployForPeg(string.concat(refSalt, "_candidate"), ethPeg, ethMkts, "mainnet", true, ethMkts);

        _compareMintersAgainstReference(refSalt, ethPeg, ethMkts);
    }
    function test_OG_EUR() public {
        string memory refSalt = "harbor_v1";
        _forkAndSetup();

        (ConfigPeg eurPeg, Config_MinterMarket[] memory eurMkts) = createEURMintersConfig();
        Config_MinterMarket[] memory fxUSDMarkets = parseCollateralFilter(eurMkts, "fxUSD");
        deployForPeg(string.concat(refSalt, "_candidate"), eurPeg, eurMkts, "mainnet", true, fxUSDMarkets);

        _compareMintersAgainstReference(refSalt, eurPeg, fxUSDMarkets);
    }

    function test_OG_GOLD() public {
        string memory refSalt = "harbor_v1";
        _forkAndSetup();

        (ConfigPeg goldPeg, Config_MinterMarket[] memory goldMkts) = createGOLDMintersConfig();
        Config_MinterMarket[] memory fxUSDMarkets = parseCollateralFilter(goldMkts, "fxUSD");
        deployForPeg(string.concat(refSalt, "_candidate"), goldPeg, goldMkts, "mainnet", true, fxUSDMarkets);

        _compareMintersAgainstReference(refSalt, goldPeg, fxUSDMarkets);
    }

    function test_SILVER_peg() public {
        string memory refSalt = "test3";
        _forkAndSetup();
        (ConfigPeg peg, Config_MinterMarket[] memory mktConfigs) = createSILVERMintersConfig();
        // Deploy peg only, no markets
        Config_MinterMarket[] memory noMarkets = new Config_MinterMarket[](0);
        deployForPeg(string.concat(refSalt, "_candidate"), peg, mktConfigs, "mainnet", true, noMarkets);
        _compareMintersAgainstReference(refSalt, peg, noMarkets);
    }

    function test_SILVER_fxUSD() public {
        string memory refSalt = "test3";
        _forkAndSetup();
        (ConfigPeg peg, Config_MinterMarket[] memory mktConfigs) = createSILVERMintersConfig();
        // Deploy peg + fxUSD market only
        Config_MinterMarket[] memory fxUSDOnly = parseCollateralFilter(mktConfigs, "fxUSD");
        deployForPeg(string.concat(refSalt, "_candidate"), peg, mktConfigs, "mainnet", true, fxUSDOnly);
        _compareMintersAgainstReference(refSalt, peg, fxUSDOnly);
    }

    function test_SILVER_stETH() public {
        string memory refSalt = "test3";
        _forkAndSetup();
        (ConfigPeg peg, Config_MinterMarket[] memory mktConfigs) = createSILVERMintersConfig();
        // Deploy peg + stETH market only
        Config_MinterMarket[] memory stETHOnly = parseCollateralFilter(mktConfigs, "stETH");
        deployForPeg(string.concat(refSalt, "_candidate"), peg, mktConfigs, "mainnet", true, stETHOnly);
        _compareMintersAgainstReference(refSalt, peg, stETHOnly);
    }

    /// @dev Fork mainnet and register this contract as factory operator.
    function _forkAndSetup() private {
        uint256 forkId = vm.createSelectFork(vm.rpcUrl("mainnet"));
        vm.selectFork(forkId);
        vm.prank(IBaoFactory(_baoFactory).owner());
        IBaoFactory(_baoFactory).setOperator(address(this), 365 days);
    }

    /// @dev Log all addresses from the global mapping (well-known + deployed contracts).
    function _logAllKnownAddresses() private view {
        console.log("All known addresses:");
        for (uint256 i = 0; i < knownSalts.length; i++) {
            if (refKnownAddrs[i] != address(0)) {
                if (refKnownAddrs[i] == candKnownAddrs[i]) {
                    // Well-known address (same for both)
                    console.log("  %s: %s", knownSalts[i], refKnownAddrs[i]);
                } else {
                    // Deployed address (different for ref/cand)
                    console.log("  %s: ref=%s cand=%s", knownSalts[i], refKnownAddrs[i], candKnownAddrs[i]);
                }
            }
        }
    }

    /// @dev Compare freshly deployed minters against existing reference deployment.
    /// @dev Candidate salt is derived as referenceSalt + "_candidate".
    /// @param referenceSalt Salt prefix for reference deployment (e.g., "harbor_v1")
    /// @param peg Peg config (provides peg name)
    /// @param mktConfigs Market configs to compare (provides peg/collateral for each market)
    function _compareMintersAgainstReference(
        string memory referenceSalt,
        ConfigPeg peg,
        Config_MinterMarket[] memory mktConfigs
    ) private {
        string memory candidateSalt = string.concat(referenceSalt, "_candidate");
        delete diffLog;
        delete mismatchDetails;

        string memory pegName = peg.peg();
        ContractSpec[] memory specs = _buildContractSpecs(pegName, mktConfigs);
        CompareTotals memory agg;

        // Build global address-to-salt mapping for ALL contracts in both deployments
        _buildGlobalAddressMapping(specs, referenceSalt, candidateSalt, mktConfigs);

        // Log all addresses (well-known + deployed)
        _logAllKnownAddresses();

        for (uint256 i = 0; i < specs.length; i++) {
            ContractSpec memory spec = specs[i];
            string memory fullRefSalt = string.concat(referenceSalt, "::", spec.salt);

            bytes32 refSaltHash = keccak256(abi.encodePacked(referenceSalt, "::", spec.salt));
            bytes32 candSaltHash = keccak256(abi.encodePacked(candidateSalt, "::", spec.salt));

            address refAddr = IBaoFactory(_baoFactory).predictAddress(refSaltHash);
            address candAddr = IBaoFactory(_baoFactory).predictAddress(candSaltHash);

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

            // Address-arg views use all known addresses from the global mapping
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

        // Fail the test if there are any diffs or mismatches
        assertEq(agg.passed, agg.total, "Not all view functions matched between reference and candidate");
        assertEq(mismatchDetails.length, 0, "There are contract mismatches (missing code, etc.)");
    }

    /// @notice Build global address-to-salt mapping for ALL contracts in both deployments.
    /// @dev Creates parallel arrays: refKnownAddrs[i] and candKnownAddrs[i] are the same logical entity.
    function _buildGlobalAddressMapping(
        ContractSpec[] memory specs,
        string memory referenceSalt,
        string memory candidateSalt,
        Config_MinterMarket[] memory mktConfigs
    ) private {
        // Query well-known addresses from peg config (all configs inherit chain config)
        // Handle empty mktConfigs case by using a default well-known count
        WellKnownAddress[] memory wellKnown;
        if (mktConfigs.length > 0) {
            wellKnown = IWellKnownAddresses(address(mktConfigs[0])).getWellKnownAddresses();
        } else {
            wellKnown = new WellKnownAddress[](0);
        }
        uint256 wellKnownCount = wellKnown.length;

        // Price oracles for each market (one entry per market)
        uint256 priceOracleCount = mktConfigs.length;

        // Each spec creates 1 entry (ref/cand pair) + well-known + price oracles
        uint256 totalEntries = specs.length + wellKnownCount + priceOracleCount;
        refKnownAddrs = new address[](totalEntries);
        candKnownAddrs = new address[](totalEntries);
        knownSalts = new string[](totalEntries);

        uint256 idx;

        // Add well-known external addresses (same for both ref and cand)
        for (uint256 i = 0; i < wellKnownCount; i++) {
            refKnownAddrs[idx] = wellKnown[i].addr;
            candKnownAddrs[idx] = wellKnown[i].addr; // Same address for both
            knownSalts[idx++] = wellKnown[i].label;
        }

        // Add all deployed contracts (ref/cand pairs)
        for (uint256 i = 0; i < specs.length; i++) {
            ContractSpec memory spec = specs[i];

            bytes32 refSaltHash = keccak256(abi.encodePacked(referenceSalt, "::", spec.salt));
            bytes32 candSaltHash = keccak256(abi.encodePacked(candidateSalt, "::", spec.salt));

            refKnownAddrs[idx] = IBaoFactory(_baoFactory).predictAddress(refSaltHash);
            candKnownAddrs[idx] = IBaoFactory(_baoFactory).predictAddress(candSaltHash);
            knownSalts[idx++] = spec.salt; // Use salt tail only (without prefix)
        }

        // Add price oracle addresses for each market (ref/cand pairs)
        for (uint256 i = 0; i < mktConfigs.length; i++) {
            string memory oracleSalt = mktConfigs[i].priceOracleKey();

            bytes32 refSaltHash = keccak256(abi.encodePacked(referenceSalt, "::", oracleSalt));
            bytes32 candSaltHash = keccak256(abi.encodePacked(candidateSalt, "::", oracleSalt));

            refKnownAddrs[idx] = IBaoFactory(_baoFactory).predictAddress(refSaltHash);
            candKnownAddrs[idx] = IBaoFactory(_baoFactory).predictAddress(candSaltHash);
            knownSalts[idx++] = oracleSalt;
        }
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
        // Test with ALL known addresses (well-known + deployed contracts)
        for (uint256 i = 0; i < sigs.length; i++) {
            for (uint256 j = 0; j < knownSalts.length; j++) {
                if (refKnownAddrs[j] == address(0)) continue;
                totals = _compareCallAddressArg(label, sigs[i], s, refKnownAddrs[j], candKnownAddrs[j], j, totals);
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

    function _skipAddressArgFunction(string memory name) private pure returns (bool) {
        bytes32 h = keccak256(bytes(name));
        // Skip genesis claimable - depends on minter address which differs between deployments
        if (h == keccak256("claimable")) return true;
        // Skip balance/state queries - values depend on actual usage, not deployment config
        if (h == keccak256("balanceOf")) return true;
        if (h == keccak256("assetBalanceOf")) return true;
        if (h == keccak256("getWithdrawalRequest")) return true;
        if (h == keccak256("pendingRewards")) return true;
        if (h == keccak256("rewardData")) return true;
        if (h == keccak256("rewardReceiver")) return true;
        if (h == keccak256("nonces")) return true;
        return false;
    }

    function _returnKind(string memory raw, uint256 i) private view returns (ReturnKind) {
        uint256 outs = _outputsLength(raw, i);
        if (outs != 1) return ReturnKind.TupleKind;

        string memory t = _parseJsonString(raw, _abiPathOutputTypeAt(i, 0));
        bytes32 h = keccak256(bytes(t));
        if (h == keccak256("address")) return ReturnKind.AddressKind;
        if (h == keccak256("address[]")) return ReturnKind.AddressArrayKind;
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
            string memory name = _parseJsonString(raw, _abiPathName(i));
            if (_skipAddressArgFunction(name)) continue;
            ++count;
        }

        sigs = new FuncSpec[](count);
        uint256 idx;
        for (uint256 i = 0; i < len; i++) {
            if (!_isAddressViewEntry(raw, i)) continue;
            string memory name = _parseJsonString(raw, _abiPathName(i));
            if (_skipAddressArgFunction(name)) continue;
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
            } else if (
                okRef &&
                okCand &&
                spec.kind == ReturnKind.AddressArrayKind &&
                _secondChanceAddressArrayMatch(refOut, candOut)
            ) {
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
        string memory sigWithArg = string.concat(spec.sig, " ", knownSalts[argIndex]);
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
        } else if (kind == ReturnKind.AddressArrayKind) {
            // Address arrays: show each element with salt lookup
            _logAddressArrayMismatch(refOut, candOut);
        } else {
            // Simple types: format with aligned labels
            string memory refStr = _formatReturn(refOut, kind);
            string memory candStr = _formatReturn(candOut, kind);
            string memory refLine = string.concat("    ", _padLabel("ref"), ": ", refStr);
            string memory candLine = string.concat("    ", _padLabel("cand"), ": ", candStr);
            mismatchDetails.push(refLine);
            mismatchDetails.push(candLine);
        }
    }

    /// @notice Log address array mismatch with element-by-element comparison and salt lookup.
    function _logAddressArrayMismatch(bytes memory refOut, bytes memory candOut) private {
        address[] memory refAddrs = abi.decode(refOut, (address[]));
        address[] memory candAddrs = abi.decode(candOut, (address[]));

        uint256 refLen = refAddrs.length;
        uint256 candLen = candAddrs.length;
        uint256 maxLen = refLen > candLen ? refLen : candLen;

        mismatchDetails.push(string.concat("    ", _padLabel("ref"), " (", vm.toString(refLen), " elements):"));
        for (uint256 i = 0; i < refLen; i++) {
            string memory salt = _findSalt(refAddrs[i]);
            mismatchDetails.push(string.concat("      [", vm.toString(i), "] ", _formatAddr(refAddrs[i], salt)));
        }

        mismatchDetails.push(string.concat("    ", _padLabel("cand"), " (", vm.toString(candLen), " elements):"));
        for (uint256 i = 0; i < candLen; i++) {
            string memory salt = _findSalt(candAddrs[i]);
            mismatchDetails.push(string.concat("      [", vm.toString(i), "] ", _formatAddr(candAddrs[i], salt)));
        }

        // Also show element-by-element comparison for matching indices
        if (refLen == candLen && refLen > 0) {
            mismatchDetails.push("    Element comparison:");
            for (uint256 i = 0; i < maxLen; i++) {
                address refAddr = i < refLen ? refAddrs[i] : address(0);
                address candAddr = i < candLen ? candAddrs[i] : address(0);

                if (refAddr != candAddr) {
                    // Check second-chance match
                    if (
                        _secondChanceWordMatch(bytes32(uint256(uint160(refAddr))), bytes32(uint256(uint160(candAddr))))
                    ) {
                        mismatchDetails.push(string.concat("      [", vm.toString(i), "] [MATCH via salt]"));
                    } else {
                        string memory refSalt = _findSalt(refAddr);
                        string memory candSalt = _findSalt(candAddr);
                        mismatchDetails.push(
                            string.concat(
                                "      [",
                                vm.toString(i),
                                "] DIFF: ",
                                _formatAddr(refAddr, refSalt),
                                " vs ",
                                _formatAddr(candAddr, candSalt)
                            )
                        );
                    }
                }
            }
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
                mismatchDetails.push(string.concat("      ", _padLabel("ref"), ": ", refFormatted));
                mismatchDetails.push(string.concat("      ", _padLabel("cand"), ": ", candFormatted));
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
        _compareIncentiveConfig(
            "mintPeggedIncentiveConfig",
            refConfig.mintPeggedIncentiveConfig,
            candConfig.mintPeggedIncentiveConfig
        );
        _compareIncentiveConfig(
            "redeemPeggedIncentiveConfig",
            refConfig.redeemPeggedIncentiveConfig,
            candConfig.redeemPeggedIncentiveConfig
        );
        _compareIncentiveConfig(
            "mintLeveragedIncentiveConfig",
            refConfig.mintLeveragedIncentiveConfig,
            candConfig.mintLeveragedIncentiveConfig
        );
        _compareIncentiveConfig(
            "redeemLeveragedIncentiveConfig",
            refConfig.redeemLeveragedIncentiveConfig,
            candConfig.redeemLeveragedIncentiveConfig
        );
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
            mismatchDetails.push(string.concat("      ", _padLabel("ref"), ": ", _formatIncentiveConfig(ref)));
            mismatchDetails.push(string.concat("      ", _padLabel("cand"), ": ", _formatIncentiveConfig(cand)));
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

    function _secondChanceAddressArrayMatch(
        bytes memory refOut,
        bytes memory candOut
    ) private view returns (bool matched) {
        address[] memory refAddrs = abi.decode(refOut, (address[]));
        address[] memory candAddrs = abi.decode(candOut, (address[]));

        if (refAddrs.length != candAddrs.length) return false;

        for (uint256 i = 0; i < refAddrs.length; i++) {
            if (refAddrs[i] == candAddrs[i]) continue;

            // Check second-chance match via salt tail
            string memory refSalt = _findSalt(refAddrs[i]);
            string memory candSalt = _findSalt(candAddrs[i]);
            if (bytes(refSalt).length == 0 || bytes(candSalt).length == 0) return false;

            string memory refTail = _saltTail(refSalt);
            string memory candTail = _saltTail(candSalt);
            if (keccak256(bytes(refTail)) != keccak256(bytes(candTail))) return false;
        }

        matched = true;
    }

    function _findSalt(address addr) private view returns (string memory salt) {
        for (uint256 i = 0; i < knownSalts.length; i++) {
            if (refKnownAddrs[i] == addr || candKnownAddrs[i] == addr) {
                return knownSalts[i];
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
