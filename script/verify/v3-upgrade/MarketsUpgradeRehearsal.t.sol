// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IClaimReward} from "@harbor/interfaces/IClaimReward.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {HolderCaptureLib} from "@harbor-script/holders/HolderCaptureLib.sol";
import {allMintersConfig} from "@harbor-script/src/AllMintersConfig.sol";
import {MarketAddresses} from "@harbor-script/src/MarketAddresses.sol";
import {MarketVerification} from "@harbor-script/src/MarketVerification.sol";
import {UpgradeMarketToV3} from "@harbor-script/src/UpgradeMarketToV3.sol";
import {Upgrade_MarketsToV3_mainnet} from "@harbor-script/Upgrade_MarketsToV3_mainnet.s.sol";

import {MockStabilityPool} from "@harbor-test/mocks/MockStabilityPool.sol";

/// @dev The production read of frozen markets, `readFrozenMarketUpgradeInputs`, held so a test can call it.
contract FrozenMarketsRead is UpgradeMarketToV3 {
    constructor() {
        _setSaltPrefix("harbor_v1");
    }

    function read(
        Config_MinterMarket[] memory markets,
        string memory capture
    ) external returns (MarketUpgradeInput[] memory) {
        return readFrozenMarketUpgradeInputs(markets, capture, "mainnet");
    }
}

/// @notice The live upgrade rehearsed on a fork of the chain's head: the upgrade script itself, run with the frozen
///         capture, reads every market at the capture's block and saves its batches, which execute as the multisig.
///         Afterwards every market holds what it held at the capture's block, as Minter_v3 and StabilityPool_v3 report
///         it, and each pool divides rewards by what its holders hold.
/// @dev The capture is HOLDERS_DIR, set by `run-upgrade-rehearsal --holders-dir`; the upgrade script reads it there too.
contract MarketsUpgradeRehearsal is Test, MarketVerification {
    /// @dev What a pool holds, as its version reports it: its supply, reward tokens and streams, and each captured
    ///      holder's balance and claimed rewards.
    struct PoolHoldings {
        uint256 supply;
        address[] tokens;
        bytes streams;
        uint256[] balances;
        bytes claimed;
    }

    string internal capture;
    uint256 internal captureBlock;
    Config_MinterMarket[] internal markets;

    function setUp() public {
        capture = vm.envString("HOLDERS_DIR");
        captureBlock = HolderCaptureLib.captureBlock(capture);
        _setSaltPrefix("harbor_v1");
        markets = allMintersConfig();
        for (uint256 i = 0; i < markets.length; ++i) {
            vm.makePersistent(address(markets[i]));
        }
    }

    /// The upgrade script, given the frozen capture, builds every market's batch and each executes as the multisig.
    /// Afterwards every minter keeps its config and balances and is not impaired, every manager reports
    /// StabilityPoolManager_v2, every pool keeps its supply, reward tokens and streams, and each captured holder's
    /// balance and claimed rewards, and divides rewards by exactly what its holders hold - and each market's contracts
    /// name its tokens and each other.
    function test_theUpgradeBuildsAndExecutesEveryMarket() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), captureBlock);
        bytes[] memory mintersBefore = new bytes[](markets.length);
        PoolHoldings[] memory poolsBefore = new PoolHoldings[](2 * markets.length);
        for (uint256 i = 0; i < markets.length; ++i) {
            mintersBefore[i] = _minterHoldings(markets[i]);
            poolsBefore[2 * i] = _poolHoldingsOnV2(markets[i], StabilityPoolType.Collateral);
            poolsBefore[2 * i + 1] = _poolHoldingsOnV2(markets[i], StabilityPoolType.Leveraged);
        }

        vm.createSelectFork(vm.rpcUrl("mainnet"));
        new Upgrade_MarketsToV3_mainnet().run("harbor_v1");

        for (uint256 i = 0; i < markets.length; ++i) {
            string memory market = MinterMarketConfigLib.salt(markets[i]);
            assertEq(
                _minterHoldings(markets[i]),
                mintersBefore[i],
                string.concat(market, ": the minter keeps its config and balances")
            );
            (uint256 recorded, uint256 held) = IMinter_v3(minterAddress(markets[i])).impairment();
            assertLe(recorded, held, string.concat(market, ": the minter's recorded backing is held"));
            assertTrue(
                IERC165(stabilityPoolManagerAddress(markets[i])).supportsInterface(
                    type(IStabilityPoolManager_v2).interfaceId
                ),
                string.concat(market, ": the manager reports StabilityPoolManager_v2")
            );
            _assertPoolKept(markets[i], StabilityPoolType.Collateral, poolsBefore[2 * i]);
            _assertPoolKept(markets[i], StabilityPoolType.Leveraged, poolsBefore[2 * i + 1]);
            MarketAddresses memory addresses = marketAddresses(markets[i]);
            verifyMarket(
                markets[i],
                addresses,
                addresses.minter,
                addresses.collateralPool,
                addresses.leveragedPool,
                addresses.manager
            );
        }
    }

    /// A capture not taken at the last block before the pause is refused: at the block after an earlier capture's, the
    /// first market's minter still answers, and the read names it and that block.
    function test_theUpgradeRefusesACaptureBeforeTheLastBlock() public {
        string memory earlier = "test/fixtures/holders-25272609/";
        vm.createSelectFork(vm.rpcUrl("mainnet"));
        FrozenMarketsRead frozenRead = new FrozenMarketsRead();
        string memory refusal = string.concat(
            minterKey(markets[0]),
            " answers at block ",
            vm.toString(HolderCaptureLib.captureBlock(earlier) + 1),
            ", the block after the capture's: the capture must end at the last block before the pause"
        );

        vm.expectRevert(bytes(refusal));
        frozenRead.read(markets, earlier);
    }

    /// @dev The minter's config and balances, encoded: Minter_v2 and Minter_v3 report them alike.
    function _minterHoldings(Config_MinterMarket market) private returns (bytes memory) {
        address minter = minterAddress(market);
        return
            abi.encode(
                IMinter(minter).config(),
                IMinter(minter).collateralTokenBalance(),
                IMinter(minter).peggedTokenBalance(),
                IMinter(minter).leveragedTokenBalance()
            );
    }

    /// @dev What the pool holds, as StabilityPool_v2 reports it.
    function _poolHoldingsOnV2(
        Config_MinterMarket market,
        StabilityPoolType poolType
    ) private returns (PoolHoldings memory holdings) {
        address pool = stabilityPoolAddress(market, poolType);
        holdings.supply = IStabilityPool(pool).totalAssetSupply();
        holdings.tokens = IMultipleRewardDistributor(pool).activeRewardTokens();
        holdings.streams = _streams(pool, holdings.tokens);
        address[] memory holders = HolderCaptureLib.holders(capture, stabilityPoolKey(market, poolType));
        holdings.balances = new uint256[](holders.length);
        for (uint256 h = 0; h < holders.length; ++h) {
            holdings.balances[h] = IStabilityPool(pool).assetBalanceOf(holders[h]);
            uint256[] memory claimed = new uint256[](holdings.tokens.length);
            for (uint256 t = 0; t < holdings.tokens.length; ++t) {
                claimed[t] = IMultipleRewardAccumulator(pool).claimed(holders[h], holdings.tokens[t]);
            }
            holdings.claimed = bytes.concat(holdings.claimed, abi.encode(claimed));
        }
    }

    /// @dev Asserts the pool, now on StabilityPool_v3, holds what `before` records, and that its reward divisor is
    ///      exactly what its captured holders hold.
    function _assertPoolKept(
        Config_MinterMarket market,
        StabilityPoolType poolType,
        PoolHoldings memory before
    ) private {
        string memory key = stabilityPoolKey(market, poolType);
        address pool = stabilityPoolAddress(market, poolType);
        address[] memory holders = HolderCaptureLib.holders(capture, key);
        address[] memory tokens = IMultipleRewardDistributor(pool).activeRewardTokens();

        assertEq(IStabilityPool_v3(pool).totalAssetSupply(), before.supply, string.concat(key, ": the supply is kept"));
        assertEq(tokens, before.tokens, string.concat(key, ": the reward tokens are kept"));
        assertEq(_streams(pool, tokens), before.streams, string.concat(key, ": the reward streams are kept"));
        uint256 summed;
        bytes memory claimed;
        for (uint256 h = 0; h < holders.length; ++h) {
            uint256 balance = IStabilityPool_v3(pool).assetBalanceOf(holders[h]);
            assertEq(
                balance,
                before.balances[h],
                string.concat(key, ": ", vm.toString(holders[h]), "'s balance is kept")
            );
            summed += balance;
            claimed = bytes.concat(claimed, abi.encode(IClaimReward(pool).claimed(holders[h], tokens)));
        }
        assertEq(claimed, before.claimed, string.concat(key, ": every holder's claimed rewards are kept"));
        assertEq(_rewardDivisor(pool), summed, string.concat(key, ": rewards divide by what the holders hold"));
    }

    /// @dev Each reward stream of `tokens` on `pool`, encoded: both versions report it alike.
    function _streams(address pool, address[] memory tokens) private view returns (bytes memory streams) {
        for (uint256 t = 0; t < tokens.length; ++t) {
            (uint256 lastUpdate, uint256 finishAt, uint256 rate, uint256 queued) = IMultipleRewardDistributor(pool)
                .rewardData(tokens[t]);
            streams = bytes.concat(streams, abi.encode(lastUpdate, finishAt, rate, queued));
        }
    }

    /// @dev The StabilityPool_v3 pool's reward divisor, which it keeps internal: read through `MockStabilityPool`, which
    ///      is StabilityPool_v3 with accessors added, put in place of the pool's code - built with the pool's own
    ///      settings - only inside a snapshot that is then reverted.
    function _rewardDivisor(address pool) private returns (uint256 divisor) {
        uint256 snapshot = vm.snapshotState();
        (uint64 startDelay, uint64 endWindow) = IStabilityPool_v3(pool).getWithdrawalWindow();
        address exposer = address(
            new MockStabilityPool(
                IStabilityPool_v3(pool).MINTER(),
                IStabilityPool_v3(pool).ASSET_TOKEN(),
                startDelay,
                endWindow,
                IStabilityPool_v3(pool).MIN_TOTAL_ASSET_SUPPLY(),
                IERC20Metadata(pool).name(),
                IERC20Metadata(pool).symbol()
            )
        );
        vm.etch(pool, exposer.code);
        divisor = MockStabilityPool(pool).__rewardDivisor();
        vm.revertToState(snapshot);
    }
}
