// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "script/config/ConfigBase.sol";

import {ForceMigrateAccumulator_v1} from "script/verify/sp-v3-migration/ForceMigrateAccumulator_v1.sol";
import {IMultipleRewardDistributor} from "src/interfaces/IMultipleRewardDistributor.sol";

import {Deploy_BTC_Minter} from "script/src/v3/Deploy_BTC_Minter.sol";
import {Deploy_ETH_Minter} from "script/src/v3/Deploy_ETH_Minter.sol";
import {Deploy_EUR_Minter} from "script/src/v3/Deploy_EUR_Minter.sol";
import {Deploy_GOLD_Minter} from "script/src/v3/Deploy_GOLD_Minter.sol";
import {Deploy_MCAP_Minter} from "script/src/v3/Deploy_MCAP_Minter.sol";
import {Deploy_SILVER_Minter} from "script/src/v3/Deploy_SILVER_Minter.sol";

import {SafeBatch} from "script/safe/SafeBatch.s.sol";

/// @notice Force-migrate accumulator storage from V1 (uint192) to V2 (uint256) format
/// for all stability pools across all markets.
///
/// Per pool, the Safe batch contains 3 atomic transactions:
///   1. Upgrade proxy → ForceMigrateAccumulator_v1
///   2. Call remediate(tokens, holders) to copy V1 → V2
///   3. Restore proxy → existing StabilityPool_v2 implementation
///
/// After this, all users have V2 data. The V1 fallback in the accumulator
/// still exists but never triggers. A subsequent upgrade to StabilityPool_v3
/// removes the fallback permanently.
///
/// Run via:
///   script/run-script Remediate_Accumulators --salt harbor_v1 --network mainnet --broadcast --local
contract Remediate_Accumulators is
    SafeBatch,
    Deploy_BTC_Minter,
    Deploy_ETH_Minter,
    Deploy_EUR_Minter,
    Deploy_GOLD_Minter,
    Deploy_MCAP_Minter,
    Deploy_SILVER_Minter
{
    using LibString for address;

    // StabilityPoolCollateral and StabilityPoolLeveraged inherited from StabilityPool deployment helper

    // ERC1967 implementation slot
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // Deployed once, shared across all pools (no constructor params)
    address migImpl;

    function _doOneMinter(Config_MinterMarket[] memory markets) internal {
        for (uint256 i = 0; i < markets.length; i++) {
            string memory marketKey = MinterMarketConfigLib.salt(markets[i]);

            _remediatePool(marketKey, StabilityPoolCollateral);
            _remediatePool(marketKey, StabilityPoolLeveraged);
        }
    }

    function _remediatePool(string memory marketKey, string memory spType) internal {
        string memory fullSalt = _saltString(_key(marketKey, spType));
        address pool = _predictAddressFromFullSalt(fullSalt);

        // Read current implementation (to restore after remediation)
        address currentImpl = address(uint160(uint256(vm.load(pool, IMPL_SLOT))));
        require(currentImpl.code.length != 0, string.concat("no impl for ", fullSalt));

        // Read active reward tokens before upgrade (pauser fallback would revert)
        address[] memory tokens = IMultipleRewardDistributor(pool).activeRewardTokens();

        // Get holders for this pool (defined per-pool below)
        address[] memory holders = _getHolders(marketKey, spType);

        if (holders.length == 0) {
            console.log("    > %s: no holders, skipping", fullSalt);
            return;
        }

        console.log("    > %s: %d holders, %d tokens", fullSalt, holders.length, tokens.length);

        // 1. Upgrade to migration contract
        queue(
            fullSalt,
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (migImpl, "")),
            "upgrade to ForceMigrateAccumulator_v1"
        );

        // 2. Remediate
        queue(
            pool,
            abi.encodeCall(ForceMigrateAccumulator_v1.remediate, (tokens, holders)),
            string.concat("remediate ", fullSalt)
        );

        // 3. Restore to original implementation
        queue(
            fullSalt,
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (currentImpl, "")),
            string.concat("restore to ", currentImpl.toHexString())
        );
    }

    function build() internal override {
        Config_MinterMarket[] memory markets;

        vm.startBroadcast();
        migImpl = address(new ForceMigrateAccumulator_v1());
        console.log("  Migration impl: %s", migImpl);
        vm.stopBroadcast();

        (, markets) = createBTCMintersConfig();
        _doOneMinter(markets);

        (, markets) = createETHMintersConfig();
        _doOneMinter(markets);

        (, markets) = createEURMintersConfig();
        _doOneMinter(markets);

        (, markets) = createGOLDMintersConfig();
        _doOneMinter(markets);

        (, markets) = createMCAPMintersConfig();
        _doOneMinter(markets);

        (, markets) = createSILVERMintersConfig();
        _doOneMinter(markets);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Holder lists per pool
    // Source: Etherscan tokentx API query, 2026-03-28
    // Pools with 0 holders are omitted (MCAP markets, some GOLD/SILVER)
    // ═══════════════════════════════════════════════════════════════════════

    // solhint-disable func-name-mixedcase

    function _getHolders(string memory marketKey, string memory spType) internal pure returns (address[] memory) {
        bytes32 key = keccak256(abi.encodePacked(marketKey, "::", spType));

        if (key == keccak256("BTC::fxUSD::stabilityPoolCollateral")) return _holders_BTC_fxUSD_Col();
        if (key == keccak256("BTC::fxUSD::stabilityPoolLeveraged")) return _holders_BTC_fxUSD_Lev();
        if (key == keccak256("BTC::stETH::stabilityPoolCollateral")) return _holders_BTC_stETH_Col();
        if (key == keccak256("BTC::stETH::stabilityPoolLeveraged")) return _holders_BTC_stETH_Lev();
        if (key == keccak256("ETH::fxUSD::stabilityPoolCollateral")) return _holders_ETH_fxUSD_Col();
        if (key == keccak256("ETH::fxUSD::stabilityPoolLeveraged")) return _holders_ETH_fxUSD_Lev();
        if (key == keccak256("EUR::fxUSD::stabilityPoolCollateral")) return _holders_EUR_fxUSD_Col();
        if (key == keccak256("EUR::fxUSD::stabilityPoolLeveraged")) return _holders_EUR_fxUSD_Lev();
        if (key == keccak256("EUR::stETH::stabilityPoolCollateral")) return _holders_EUR_stETH_Col();
        if (key == keccak256("EUR::stETH::stabilityPoolLeveraged")) return _holders_EUR_stETH_Lev();
        if (key == keccak256("GOLD::fxUSD::stabilityPoolCollateral")) return _holders_GOLD_fxUSD_Col();
        if (key == keccak256("GOLD::fxUSD::stabilityPoolLeveraged")) return _holders_GOLD_fxUSD_Lev();
        if (key == keccak256("GOLD::stETH::stabilityPoolCollateral")) return _holders_GOLD_stETH_Col();
        if (key == keccak256("GOLD::stETH::stabilityPoolLeveraged")) return _holders_GOLD_stETH_Lev();
        if (key == keccak256("SILVER::fxUSD::stabilityPoolCollateral")) return _holders_SILVER_fxUSD_Col();
        if (key == keccak256("SILVER::fxUSD::stabilityPoolLeveraged")) return _holders_SILVER_fxUSD_Lev();
        if (key == keccak256("SILVER::stETH::stabilityPoolCollateral")) return _holders_SILVER_stETH_Col();
        if (key == keccak256("SILVER::stETH::stabilityPoolLeveraged")) return _holders_SILVER_stETH_Lev();

        // MCAP pools: 0 holders
        return new address[](0);
    }

    function _holders_BTC_fxUSD_Col() internal pure returns (address[] memory h) {
        h = new address[](9);
        h[0] = 0x061B84FDe0aa74ecbF8eCDB0481576feE9Ae35aa;
        h[1] = 0x1a9152528AEFbcD9E5df4E0770f4F510e7056913;
        h[2] = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;
        h[3] = 0x9Dd897df19FfC27d6685E98Accc394f88a73e475;
        h[4] = 0xaa17879e7cac3AEE12D6aa568691e638EF0C57f0;
        h[5] = 0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e;
        h[6] = 0xb9ab9578a34a05c86124c399735fdE44dEc80E7F;
        h[7] = 0xbA26035B9CD76cdA5b767A966b8A3392E476Fc0F;
        h[8] = 0xDD4dAd7E9FD518e271bEA1d820B95E3215D735D5;
    }

    function _holders_BTC_fxUSD_Lev() internal pure returns (address[] memory h) {
        h = new address[](13);
        h[0] = 0x2880a6bb2cD1DF6E03dC8BbFBEd009DE586c2603;
        h[1] = 0x5dE79E0C5632056B9FB19a740cE0f3EF03adEEB3;
        h[2] = 0x742fC5146d7Ff18291E3B7499811AD87015Fc7E4;
        h[3] = 0x754Ba099408892F500e3675b9816ea1B0dc33CBb;
        h[4] = 0x7e4f98217A085F1a06332EDff805513b6Ea79357;
        h[5] = 0x9Af8FBF66Bf3645f505D58614D7a13D411b99907;
        h[6] = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;
        h[7] = 0x9Dd897df19FfC27d6685E98Accc394f88a73e475;
        h[8] = 0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e;
        h[9] = 0xb9ab9578a34a05c86124c399735fdE44dEc80E7F;
        h[10] = 0xbA26035B9CD76cdA5b767A966b8A3392E476Fc0F;
        h[11] = 0xDD0CDF8D98d9Ad3ADfaa49AaECD444Bfa01d9C9a;
        h[12] = 0xDD4dAd7E9FD518e271bEA1d820B95E3215D735D5;
    }

    // TODO: Add remaining holder lists for all pools
    // For now, returning empty arrays for pools not yet populated

    function _holders_BTC_stETH_Col() internal pure returns (address[] memory) {
        return new address[](0);
    }
    function _holders_BTC_stETH_Lev() internal pure returns (address[] memory) {
        return new address[](0);
    }
    function _holders_ETH_fxUSD_Col() internal pure returns (address[] memory) {
        return new address[](0);
    }
    function _holders_ETH_fxUSD_Lev() internal pure returns (address[] memory) {
        return new address[](0);
    }
    function _holders_EUR_fxUSD_Col() internal pure returns (address[] memory) {
        return new address[](0);
    }
    function _holders_EUR_fxUSD_Lev() internal pure returns (address[] memory) {
        return new address[](0);
    }
    function _holders_EUR_stETH_Col() internal pure returns (address[] memory) {
        return new address[](0);
    }
    function _holders_EUR_stETH_Lev() internal pure returns (address[] memory) {
        return new address[](0);
    }
    function _holders_GOLD_fxUSD_Col() internal pure returns (address[] memory) {
        return new address[](0);
    }
    function _holders_GOLD_fxUSD_Lev() internal pure returns (address[] memory) {
        return new address[](0);
    }
    function _holders_GOLD_stETH_Col() internal pure returns (address[] memory) {
        return new address[](0);
    }
    function _holders_GOLD_stETH_Lev() internal pure returns (address[] memory) {
        return new address[](0);
    }
    function _holders_SILVER_fxUSD_Col() internal pure returns (address[] memory) {
        return new address[](0);
    }
    function _holders_SILVER_fxUSD_Lev() internal pure returns (address[] memory) {
        return new address[](0);
    }
    function _holders_SILVER_stETH_Col() internal pure returns (address[] memory) {
        return new address[](0);
    }
    function _holders_SILVER_stETH_Lev() internal pure returns (address[] memory) {
        return new address[](0);
    }

    // solhint-enable func-name-mixedcase
}
