// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "@bao-test/deployment/BaoDeploymentTest.sol";
import {BaoFactoryBytecode} from "@bao-factory/BaoFactoryBytecode.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {DeployMintersBase} from "script/bao-basedeployment/DeployMintersBase.sol";
import {DeploymentTypes} from "script/bao-basedeployment/DeploymentTypes.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2 as console} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @notice Test harness for minter token deployment (pegged + leveraged).
contract TestDeployMintersHarness is DeployMintersBase {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function baoFactory() public pure override returns (address) {
        return BaoFactoryBytecode.PREDICTED_PROXY;
    }

    function _shouldPersistState() internal pure override returns (bool) {
        return false;
    }

    // Expose for testing
    function deployAllMintersWrapper(string memory systemSalt, string memory network, bool useLocal) external {
        deployAllMinters(systemSalt, network, useLocal);
    }
}

contract DeployMintersTest is BaoDeploymentTest {
    using stdJson for string;

    string private constant REFERENCE_SALT = "harbor_v1";
    string private constant CANDIDATE_SALT = "test";
    string private constant TOKEN_ARTIFACT = "out/MintableBurnableERC20_v1.sol/MintableBurnableERC20_v1.json";

    // Market definitions: peg::collateral format
    function _getMarketSalts() private pure returns (string[7] memory) {
        return ["ETH::fxUSD", "BTC::fxUSD", "BTC::stETH", "GOLD::fxUSD", "GOLD::stETH", "EUR::fxUSD", "EUR::stETH"];
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
        TupleKind
    }

    // Populated per-token to support mismatch diagnostics.
    address[] private currentKnownAddrs;
    string[] private currentKnownSalts;

    TestDeployMintersHarness private harness;
    address private baoFactory;

    struct TokenCompareState {
        address refToken;
        address candToken;
        address[] refMinters;
        address[] candMinters;
        string[] minterKeys;
        address[] knownAddrs;
        string[] knownSalts;
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
        baoFactory = _baoFactory;

        // Create test harness after factory is ready
        harness = new TestDeployMintersHarness();

        // Allow harness to deploy via factory
        vm.prank(IBaoFactory(baoFactory).owner());
        IBaoFactory(baoFactory).setOperator(address(harness), 365 days);
    }

    function test_deployAllMinters_deploysAllTokens_() public {
        string memory systemSalt = "test_minters";
        string memory network = "mainnet";

        // Deploy all minter tokens
        harness.deployAllMintersWrapper(systemSalt, network, true);

        // Verify 4 pegged tokens were deployed
        address[4] memory peggedTokens = _predictPeggedTokens(systemSalt);
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
        address[7] memory leveragedTokens = _predictLeveragedTokens(systemSalt);
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
        baoFactory = _baoFactory;
        vm.prank(IBaoFactory(baoFactory).owner());
        IBaoFactory(baoFactory).setOperator(address(harness), 365 days);

        harness.deployAllMintersWrapper(CANDIDATE_SALT, "mainnet", false);

        _compareMintersAgainstReference(REFERENCE_SALT, CANDIDATE_SALT);
    }

    /// @dev Compare freshly deployed minters (candidateSalt) against existing deployment (referenceSalt).
    function _compareMintersAgainstReference(string memory referenceSalt, string memory candidateSalt) private {
        delete diffLog;
        delete mismatchDetails;
        string[4] memory pegs = ["ETH", "BTC", "GOLD", "EUR"];

        CompareTotals memory agg;

        // Compare pegged tokens
        for (uint256 iPeg = 0; iPeg < pegs.length; iPeg++) {
            string memory peg = pegs[iPeg];
            TokenCompareState memory s;

            string memory pegKey = string.concat(peg, "::pegged");
            bytes32 refSalt = keccak256(abi.encodePacked(referenceSalt, "::", pegKey));
            bytes32 candSalt = keccak256(abi.encodePacked(candidateSalt, "::", pegKey));
            s.refToken = IBaoFactory(baoFactory).predictAddress(refSalt);
            s.candToken = IBaoFactory(baoFactory).predictAddress(candSalt);

            if (!_hasCode(s.refToken)) {
                console.log("reference pegged token missing code for %s", peg);
                continue;
            }
            if (!_hasCode(s.candToken)) {
                console.log("candidate pegged token missing code for %s", peg);
                continue;
            }

            (s.refMinters, s.minterKeys) = _predictMintersForPeg(referenceSalt, peg);
            (s.candMinters, ) = _predictMintersForPeg(candidateSalt, peg);

            _populateKnownAddresses(peg, referenceSalt, candidateSalt, s);

            CompareTotals memory pegTotals = _processToken(string.concat("pegged::", peg), s);
            agg.total += pegTotals.total;
            agg.passed += pegTotals.passed;
        }

        // Compare leveraged tokens
        string[7] memory marketSalts = _getMarketSalts();
        for (uint256 iMarket = 0; iMarket < 7; iMarket++) {
            string memory marketKey = marketSalts[iMarket];
            TokenCompareState memory s;

            string memory leveragedKey = string.concat(marketKey, "::leveraged");
            bytes32 refSalt = keccak256(abi.encodePacked(referenceSalt, "::", leveragedKey));
            bytes32 candSalt = keccak256(abi.encodePacked(candidateSalt, "::", leveragedKey));
            s.refToken = IBaoFactory(baoFactory).predictAddress(refSalt);
            s.candToken = IBaoFactory(baoFactory).predictAddress(candSalt);

            if (!_hasCode(s.refToken)) {
                console.log("reference leveraged token missing code for %s", marketKey);
                continue;
            }
            if (!_hasCode(s.candToken)) {
                console.log("candidate leveraged token missing code for %s", marketKey);
                continue;
            }

            // Leveraged tokens have a single minter per market
            s.refMinters = new address[](1);
            s.candMinters = new address[](1);
            s.minterKeys = new string[](1);
            s.refMinters[0] = IBaoFactory(baoFactory).predictAddress(
                keccak256(abi.encodePacked(referenceSalt, "::", marketKey, "::minter"))
            );
            s.candMinters[0] = IBaoFactory(baoFactory).predictAddress(
                keccak256(abi.encodePacked(candidateSalt, "::", marketKey, "::minter"))
            );
            s.minterKeys[0] = marketKey;

            _populateLeveragedKnownAddresses(marketKey, referenceSalt, candidateSalt, s);

            CompareTotals memory levTotals = _processToken(string.concat("leveraged::", marketKey), s);
            agg.total += levTotals.total;
            agg.passed += levTotals.passed;
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

    function _processToken(
        string memory label,
        TokenCompareState memory s
    ) private returns (CompareTotals memory totals) {
        currentKnownAddrs = s.knownAddrs;
        currentKnownSalts = s.knownSalts;
        totals = _compareNoArgViews(label, s);
        totals = _compareAddressArgViews(label, s, totals);
    }

    function _compareNoArgViews(
        string memory label,
        TokenCompareState memory s
    ) private returns (CompareTotals memory totals) {
        FuncSpec[] memory specs = _loadZeroArgViewFunctions();
        for (uint256 i = 0; i < specs.length; i++) {
            totals = _compareCall(label, specs[i], s, totals);
        }
    }

    function _compareAddressArgViews(
        string memory label,
        TokenCompareState memory s,
        CompareTotals memory totals
    ) private returns (CompareTotals memory) {
        FuncSpec[] memory sigs = _loadAddressViewFunctions();
        if (s.refMinters.length != s.candMinters.length) return totals;
        for (uint256 i = 0; i < sigs.length; i++) {
            for (uint256 j = 0; j < s.refMinters.length; j++) {
                totals = _compareCallAddressArg(label, sigs[i], s, s.refMinters[j], s.candMinters[j], j, totals);
            }
        }
        return totals;
    }

    function _loadZeroArgViewFunctions() private view returns (FuncSpec[] memory sigs) {
        string memory raw = vm.readFile(TOKEN_ARTIFACT);
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
        return
            h == keccak256("DOMAIN_SEPARATOR") || h == keccak256("DOMAIN_SEPARATORS") || h == keccak256("eip712Domain");
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
        return ReturnKind.TupleKind;
    }

    function _loadAddressViewFunctions() private view returns (FuncSpec[] memory sigs) {
        string memory raw = vm.readFile(TOKEN_ARTIFACT);
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
        tokens[0] = IBaoFactory(baoFactory).predictAddress(
            keccak256(abi.encodePacked(systemSalt, "::", "ETH::pegged"))
        );
        tokens[1] = IBaoFactory(baoFactory).predictAddress(
            keccak256(abi.encodePacked(systemSalt, "::", "BTC::pegged"))
        );
        tokens[2] = IBaoFactory(baoFactory).predictAddress(
            keccak256(abi.encodePacked(systemSalt, "::", "GOLD::pegged"))
        );
        tokens[3] = IBaoFactory(baoFactory).predictAddress(
            keccak256(abi.encodePacked(systemSalt, "::", "EUR::pegged"))
        );
    }

    function _predictLeveragedTokens(string memory systemSalt) internal view returns (address[7] memory tokens) {
        string[7] memory marketSalts = _getMarketSalts();
        for (uint256 i = 0; i < 7; i++) {
            string memory leveragedKey = string.concat(marketSalts[i], "::leveraged");
            tokens[i] = IBaoFactory(baoFactory).predictAddress(
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
            addrs[idx] = IBaoFactory(baoFactory).predictAddress(
                keccak256(abi.encodePacked(systemSalt, "::", marketSalts[i], "::minter"))
            );
            keys[idx] = marketSalts[i];
            ++idx;
        }
    }

    function _populateKnownAddresses(
        string memory peg,
        string memory referenceSalt,
        string memory candidateSalt,
        TokenCompareState memory s
    ) private pure {
        uint256 perPeg = 2 + s.refMinters.length + s.candMinters.length;
        s.knownAddrs = new address[](perPeg);
        s.knownSalts = new string[](perPeg);

        uint256 idx;
        s.knownAddrs[idx] = s.refToken;
        s.knownSalts[idx++] = string.concat(referenceSalt, "::", peg, "::pegged");

        s.knownAddrs[idx] = s.candToken;
        s.knownSalts[idx++] = string.concat(candidateSalt, "::", peg, "::pegged");

        for (uint256 i = 0; i < s.refMinters.length; i++) {
            s.knownAddrs[idx] = s.refMinters[i];
            s.knownSalts[idx++] = string.concat(referenceSalt, "::", s.minterKeys[i], "::minter");
        }

        for (uint256 i = 0; i < s.candMinters.length; i++) {
            s.knownAddrs[idx] = s.candMinters[i];
            s.knownSalts[idx++] = string.concat(candidateSalt, "::", s.minterKeys[i], "::minter");
        }
    }

    function _populateLeveragedKnownAddresses(
        string memory marketKey,
        string memory referenceSalt,
        string memory candidateSalt,
        TokenCompareState memory s
    ) private pure {
        uint256 size = 2 + s.refMinters.length + s.candMinters.length;
        s.knownAddrs = new address[](size);
        s.knownSalts = new string[](size);

        uint256 idx;
        s.knownAddrs[idx] = s.refToken;
        s.knownSalts[idx++] = string.concat(referenceSalt, "::", marketKey, "::leveraged");

        s.knownAddrs[idx] = s.candToken;
        s.knownSalts[idx++] = string.concat(candidateSalt, "::", marketKey, "::leveraged");

        for (uint256 i = 0; i < s.refMinters.length; i++) {
            s.knownAddrs[idx] = s.refMinters[i];
            s.knownSalts[idx++] = string.concat(referenceSalt, "::", s.minterKeys[i], "::minter");
        }

        for (uint256 i = 0; i < s.candMinters.length; i++) {
            s.knownAddrs[idx] = s.candMinters[i];
            s.knownSalts[idx++] = string.concat(candidateSalt, "::", s.minterKeys[i], "::minter");
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
        string memory refStr = _formatReturn(refOut, kind);
        string memory candStr = _formatReturn(candOut, kind);
        string memory refLabel = _valueLabel(true);
        string memory candLabel = _valueLabel(false);

        string memory detail = string.concat(
            "- ",
            label,
            " ",
            sig,
            prefix,
            " ",
            refLabel,
            "=",
            refStr,
            " ",
            candLabel,
            "=",
            candStr
        );
        mismatchDetails.push(detail);
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
            if (ok) return vm.toString(v);
        } else if (kind == ReturnKind.IntKind) {
            (bool ok, int256 v) = _tryDecodeInt(data);
            if (ok) return vm.toString(uint256(v));
        } else if (kind == ReturnKind.StringKind) {
            (bool ok, string memory s) = _tryDecodeString(data);
            if (ok) return s;
        }
        return _toHex(data);
    }

    function _valueLabel(bool isRef) private pure returns (string memory) {
        return isRef ? REFERENCE_SALT : CANDIDATE_SALT;
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
        return bytes(salt).length == 0 ? vm.toString(addr) : string.concat(vm.toString(addr), " (", salt, ")");
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
