// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {HolderCaptureLib} from "@harbor-script/holders/HolderCaptureLib.sol";
import {allMintersConfig, isFrozen, marketsToUpgrade} from "@harbor-script/src/AllMintersConfig.sol";
import {Pauser, pausers} from "@harbor-script/src/Pausers.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {FROZEN_MARKETS_CAPTURE} from "@harbor-script/Upgrade_MarketsToV3_mainnet.s.sol";

/// @notice The v3 upgrade reads the live markets at the end of the capture's block, the last before the pause that froze
///         them, and runs on the frozen state. These check the two are the same in everything the upgrade reads: the
///         pause changed only which implementation each minter and pool runs, and nothing earlier in the pause's block
///         changed a minter or a pool.
/// @dev The capture is the upgrade's, `FROZEN_MARKETS_CAPTURE`. A run naming a market the pause never froze skips them:
///      it reads that market at the chain's head, not here. Replaying the pause's block needs the Osaka EVM: the block holds EIP-7702 transactions, which forge refuses under the repository's Cancun setting.
contract FrozenMarketsReadPoint is Test, HarborDeployer {
    /// @dev The Safe transaction that paused every minter and stability pool, in block 26,248,724.
    bytes32 internal constant PAUSE = 0x0359c9fbfd7be6ef5b34e9f8aa8dfb8147b59aa7280d61787e83ffe9afc89a44;

    uint256 internal captureBlock;

    /// @dev Every market the pause froze, and those the run names: none where it names a market the pause never froze.
    Config_MinterMarket[] internal frozen;
    Config_MinterMarket[] internal markets;

    function setUp() public {
        captureBlock = HolderCaptureLib.captureBlock(FROZEN_MARKETS_CAPTURE);
        _setSaltPrefix("harbor_v1");
        // Which markets the pause froze is read where it took effect, the block after the capture's: each market whose
        // minter runs a pauser there. The configs are made before the fork and read on it and on the tests' own.
        Config_MinterMarket[] memory all = allMintersConfig();
        for (uint256 i = 0; i < all.length; ++i) {
            vm.makePersistent(address(all[i]));
        }
        Config_MinterMarket[] memory named = marketsToUpgrade();
        for (uint256 i = 0; i < named.length; ++i) {
            vm.makePersistent(address(named[i]));
        }
        vm.createSelectFork(vm.rpcUrl("mainnet"), captureBlock + 1);
        for (uint256 i = 0; i < all.length; ++i) {
            if (isFrozen(minterAddress(all[i]), "mainnet")) {
                frozen.push(all[i]);
            }
        }
        if (isFrozen(minterAddress(named[0]), "mainnet")) {
            markets = named;
        }
    }

    /// The pause changed only which implementation each minter and pool runs. Replayed on the state just before it, in
    /// the block after the capture's, its only storage changes are the ERC-1967 implementation slot of every minter
    /// and pool - each set to the same pauser - and the multisig's own. Every market it froze is checked, whichever the
    /// run names, because the one transaction froze them all.
    function test_thePauseChangedOnlyEachProxysImplementation() public {
        vm.skip(markets.length == 0);
        vm.createSelectFork(vm.rpcUrl("mainnet"), captureBlock);
        vm.setEvmVersion("osaka");
        vm.rollFork(PAUSE);
        assertEq(block.number, captureBlock + 1, "the pause is in the block after the capture's");
        address[] memory proxies = new address[](3 * frozen.length);
        for (uint256 i = 0; i < frozen.length; ++i) {
            proxies[3 * i] = minterAddress(frozen[i]);
            proxies[3 * i + 1] = stabilityPoolAddress(frozen[i], StabilityPoolType.Collateral);
            proxies[3 * i + 2] = stabilityPoolAddress(frozen[i], StabilityPoolType.Leveraged);
        }

        vm.startStateDiffRecording();
        vm.transact(PAUSE);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        uint256 implementationsChanged;
        bytes32 pauser;
        for (uint256 i = 0; i < accesses.length; ++i) {
            for (uint256 j = 0; j < accesses[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory access = accesses[i].storageAccesses[j];
                if (!access.isWrite || access.reverted || access.previousValue == access.newValue) {
                    continue;
                }
                string memory written = string.concat(vm.toString(access.account), " slot ", vm.toString(access.slot));
                if (!_contains(proxies, access.account)) {
                    assertEq(access.account, owner(), string.concat(written, ": the pause changed another account"));
                    continue;
                }
                assertEq(
                    access.slot,
                    ERC1967Utils.IMPLEMENTATION_SLOT,
                    string.concat(written, ": the pause changed a minter or pool beyond its implementation")
                );
                if (implementationsChanged == 0) {
                    pauser = access.newValue;
                }
                assertEq(access.newValue, pauser, string.concat(written, ": set to a different implementation"));
                ++implementationsChanged;
            }
        }
        assertEq(implementationsChanged, proxies.length, "every minter and pool changes implementation, once");
        Pauser[] memory recorded = pausers("mainnet");
        bool isRecorded;
        for (uint256 i = 0; i < recorded.length; ++i) {
            isRecorded = isRecorded || recorded[i].implementation == address(uint160(uint256(pauser)));
        }
        assertTrue(isRecorded, "the pause installed a pauser bao-base's deployment state records");
    }

    /// Nothing earlier in the pause's block changed a named market. At the same moment, its minter and pools answer the
    /// views the upgrade reads and copies the same at the end of the capture's block as just before the pause: the
    /// minter's config and balances; each pool's supply, floor, withdrawal window, fee, reward tokens and streams, and
    /// each captured holder's balance and claimable and claimed rewards.
    function test_nothingBeforeThePauseInItsBlockChangedAMarket() public {
        vm.skip(markets.length == 0);
        uint256 atCapture = vm.createSelectFork(vm.rpcUrl("mainnet"), captureBlock);
        uint256 beforePause = vm.createSelectFork(vm.rpcUrl("mainnet"), captureBlock);
        vm.setEvmVersion("osaka");
        vm.rollFork(PAUSE);
        uint256 moment = block.timestamp;

        for (uint256 i = 0; i < markets.length; ++i) {
            string memory market = MinterMarketConfigLib.salt(markets[i]);
            vm.selectFork(beforePause);
            bytes memory minterBeforePause = _minterAnswers(markets[i]);
            bytes memory collateralPoolBeforePause = _poolAnswers(markets[i], StabilityPoolType.Collateral);
            bytes memory leveragedPoolBeforePause = _poolAnswers(markets[i], StabilityPoolType.Leveraged);
            vm.selectFork(atCapture);
            vm.warp(moment);
            assertEq(_minterAnswers(markets[i]), minterBeforePause, string.concat(market, ": the minter changed"));
            assertEq(
                _poolAnswers(markets[i], StabilityPoolType.Collateral),
                collateralPoolBeforePause,
                string.concat(market, ": the collateral pool changed")
            );
            assertEq(
                _poolAnswers(markets[i], StabilityPoolType.Leveraged),
                leveragedPoolBeforePause,
                string.concat(market, ": the leveraged pool changed")
            );
        }
    }

    function _contains(address[] memory accounts, address account) private pure returns (bool) {
        for (uint256 i = 0; i < accounts.length; ++i) {
            if (accounts[i] == account) {
                return true;
            }
        }
        return false;
    }

    /// @dev The minter's config and balances, as Minter_v2 reports them, encoded.
    function _minterAnswers(Config_MinterMarket market) private returns (bytes memory) {
        address minter = minterAddress(market);
        return
            abi.encode(
                IMinter(minter).config(),
                IMinter(minter).collateralTokenBalance(),
                IMinter(minter).peggedTokenBalance(),
                IMinter(minter).leveragedTokenBalance()
            );
    }

    /// @dev The pool's supply, floor, withdrawal window, fee, reward tokens and streams, and each captured holder's
    ///      balance and claimable and claimed rewards, as StabilityPool_v2 reports them, encoded.
    function _poolAnswers(
        Config_MinterMarket market,
        StabilityPoolType poolType
    ) private returns (bytes memory answers) {
        address pool = stabilityPoolAddress(market, poolType);
        address[] memory tokens = IMultipleRewardDistributor(pool).activeRewardTokens();
        (uint64 startDelay, uint64 endWindow) = IStabilityPool(pool).getWithdrawalWindow();
        answers = abi.encode(
            IStabilityPool(pool).totalAssetSupply(),
            IStabilityPool(pool).MIN_TOTAL_ASSET_SUPPLY(),
            startDelay,
            endWindow,
            IStabilityPool(pool).getEarlyWithdrawalFee(),
            IStabilityPool(pool).getFeeAddress(),
            tokens
        );
        for (uint256 t = 0; t < tokens.length; ++t) {
            (uint256 lastUpdate, uint256 finishAt, uint256 rate, uint256 queued) = IMultipleRewardDistributor(pool)
                .rewardData(tokens[t]);
            answers = bytes.concat(answers, abi.encode(lastUpdate, finishAt, rate, queued));
        }
        address[] memory holders = HolderCaptureLib.holders(FROZEN_MARKETS_CAPTURE, stabilityPoolKey(market, poolType));
        for (uint256 h = 0; h < holders.length; ++h) {
            answers = bytes.concat(answers, abi.encode(IStabilityPool(pool).assetBalanceOf(holders[h])));
            for (uint256 t = 0; t < tokens.length; ++t) {
                answers = bytes.concat(
                    answers,
                    abi.encode(
                        IMultipleRewardAccumulator(pool).claimable(holders[h], tokens[t]),
                        IMultipleRewardAccumulator(pool).claimed(holders[h], tokens[t])
                    )
                );
            }
        }
    }
}
