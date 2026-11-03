// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {Token} from "@bao/Token.sol";
import {IGenesis} from "@harbor/interfaces/IGenesis.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";
import {marketsToUpgrade} from "@harbor-script/src/AllMintersConfig.sol";
import {FROZEN_MARKETS_CAPTURE} from "@harbor-script/Upgrade_MarketsToV3_mainnet.s.sol";
import {MarketHarvestCheck} from "@harbor-script/verify/v3-upgrade/MarketHarvestCheck.sol";

import {MarketUpgradeRun} from "@harbor-test/harness/MarketUpgradeRun.sol";

/// @title UpgradedUnopenedMarketsOpen - the markets named that have not opened, upgraded, open and run
/// @notice A market that has not opened has a deployed Genesis_v1 that has not ended and a minter that holds nothing, so
///         its genesis ending against Minter_v3, and everything after, has never happened on it. The rehearsal's records
///         compare empty contracts with empty contracts, so this does what they cannot: it opens each such market through
///         its genesis, then uses it.
/// @dev On a fork of mainnet at the chain's head, where the markets run and their oracles answer. The markets named
///      whose genesis has not ended there are the ones opened. Two depositors enter each genesis while the minter is
///      still v2, then the upgrade script's own function upgrades the named markets. A run naming no such market skips
///      the tests, and each says so.
contract UpgradedUnopenedMarketsOpen is MarketHarvestCheck {
    /// @dev Why every test skips when no market named has a genesis still to end.
    string private constant NOTHING_TO_OPEN = "no market named has an unended genesis";

    /// @dev What each depositor enters a genesis with, in dollars of the market's wrapped collateral.
    uint256 private constant DOLLARS_IN_GENESIS = 100_000;

    /// @dev What a retail user trades with, in dollars.
    uint256 private constant DOLLARS_RETAIL = 1_000;

    /// @dev A market's name and the contracts its tests read, all resolved once.
    struct MarketContracts {
        string name;
        address genesis;
        address minter;
        address wrapped;
        address pegged;
        address leveraged;
        address feeReceiver;
    }

    Config_MinterMarket[] private markets;
    address private stayer = makeAddr("stayer");
    address private leaver = makeAddr("leaver");
    address private lateDepositor = makeAddr("lateDepositor");
    address private retail = makeAddr("retail");
    address private keeper = makeAddr("keeper");

    function setUp() public {
        Config_MinterMarket[] memory named = marketsToUpgrade();
        for (uint256 i = 0; i < named.length; ++i) {
            // Made before the fork below, and read on it.
            vm.makePersistent(address(named[i]));
        }
        vm.createSelectFork("mainnet");
        _setSaltPrefix("harbor_v1");
        for (uint256 i = 0; i < named.length; ++i) {
            if (!IGenesis(genesisAddress(named[i])).genesisIsEnded()) {
                markets.push(named[i]);
            }
        }
        if (markets.length == 0) {
            return;
        }
        for (uint256 i = 0; i < markets.length; ++i) {
            _enterGenesis(markets[i], stayer);
            _enterGenesis(markets[i], leaver);
        }
        MarketUpgradeRun upgrade = new MarketUpgradeRun(named, FROZEN_MARKETS_CAPTURE);
        upgrade.run("harbor_v1");
    }

    /// Genesis_v1 opens each upgraded market: its end mints, for free, half the collateral as pegged at the oracle's low
    /// price and low rate, and the other half as leveraged, the market's residual at its high price. The minter records
    /// that, and holds all the collateral. Each depositor, whether they entered before the upgrade or after, claims
    /// their share of both.
    function test_genesisV1_opensEachUpgradedMarket() public {
        vm.skip(markets.length == 0, NOTHING_TO_OPEN);
        for (uint256 i = 0; i < markets.length; ++i) {
            MarketContracts memory m = _contractsOf(markets[i]);
            _enterGenesis(markets[i], lateDepositor);
            uint256 total = IERC20(m.wrapped).balanceOf(m.genesis);
            assertEq(total, 3 * _inGenesis(markets[i]), string.concat(m.name, ": precondition: three deposits"));

            (uint256 pegged, uint256 leveraged, uint256 backing) = _openingAtTheOracle(m.minter, total);
            _endGenesis(m.genesis);

            assertTrue(IGenesis(m.genesis).genesisIsEnded(), string.concat(m.name, ": the genesis has ended"));
            assertEq(IMinter_v3(m.minter).peggedTokenBalance(), pegged, string.concat(m.name, ": the pegged minted"));
            assertEq(
                IMinter_v3(m.minter).leveragedTokenBalance(),
                leveraged,
                string.concat(m.name, ": the leveraged minted")
            );
            assertEq(
                IMinter_v3(m.minter).collateralTokenBalance(),
                backing,
                string.concat(m.name, ": the backing recorded")
            );
            assertEq(
                IERC20(m.wrapped).balanceOf(m.minter),
                total,
                string.concat(m.name, ": the minter holds the collateral")
            );
            assertEq(IERC20(m.wrapped).balanceOf(m.genesis), 0, string.concat(m.name, ": the genesis holds none"));

            address[3] memory depositors = [stayer, leaver, lateDepositor];
            for (uint256 d = 0; d < depositors.length; ++d) {
                _claimsItsShare(markets[i], depositors[d], _inGenesis(markets[i]), total, pegged, leveraged);
            }
        }
    }

    /// A deposit made in a genesis before the upgrade survives it. Its depositor can still take it out before the end,
    /// and it is all theirs. One left in claims the whole opening, as the only share left, and can no longer be taken
    /// out. The depositor who took theirs out has nothing to claim.
    function test_aGenesisDepositFromBeforeTheUpgrade_survivesIt() public {
        vm.skip(markets.length == 0, NOTHING_TO_OPEN);
        for (uint256 i = 0; i < markets.length; ++i) {
            MarketContracts memory m = _contractsOf(markets[i]);
            uint256 deposited = _inGenesis(markets[i]);
            assertEq(IGenesis(m.genesis).balanceOf(stayer), deposited, string.concat(m.name, ": the stayer's share"));
            assertEq(IGenesis(m.genesis).balanceOf(leaver), deposited, string.concat(m.name, ": the leaver's share"));

            vm.startPrank(leaver);
            uint256 out = IGenesis(m.genesis).withdraw(deposited, leaver);
            vm.stopPrank();
            assertEq(out, deposited, string.concat(m.name, ": the leaver takes it all out"));
            assertEq(IERC20(m.wrapped).balanceOf(leaver), deposited, string.concat(m.name, ": and holds it"));
            assertEq(IGenesis(m.genesis).balanceOf(leaver), 0, string.concat(m.name, ": with no share left"));

            (uint256 pegged, uint256 leveraged, ) = _openingAtTheOracle(m.minter, deposited);
            _endGenesis(m.genesis);

            vm.startPrank(stayer);
            vm.expectRevert(IGenesis.GenesisIsEnded.selector);
            IGenesis(m.genesis).withdraw(deposited, stayer);
            vm.stopPrank();

            _claimsItsShare(markets[i], stayer, deposited, deposited, pegged, leveraged);

            vm.startPrank(leaver);
            vm.expectRevert(abi.encodeWithSelector(Token.ZeroInputBalance.selector, m.wrapped));
            IGenesis(m.genesis).claim(leaver);
            vm.stopPrank();
        }
    }

    /// An opened market takes a retail user through all it offers. The mints and redemptions do what their dry runs say, on
    /// the market's own oracle and fee bands, and pay the fee they state to the fee receiver. Each pool takes a deposit
    /// and gives it back, less its config's early-withdrawal fee, paid to its fee receiver.
    function test_eachOpenedMarket_takesPoolDepositsAndRedeems() public {
        vm.skip(markets.length == 0, NOTHING_TO_OPEN);
        for (uint256 i = 0; i < markets.length; ++i) {
            MarketContracts memory m = _contractsOf(markets[i]);
            _open(markets[i]);
            uint256 wrappedIn = DOLLARS_RETAIL * IHarborConfig(address(markets[i])).aboutADollarInWrappedCollateral();
            deal(m.wrapped, retail, 2 * wrappedIn);
            uint256 peggedAtStart = IERC20(m.pegged).balanceOf(retail);

            // Mint pegged. Asking for less than the dry run's figure would let a shortfall pass.
            uint256 peggedMinted;
            {
                (, uint256 fee, uint256 taken, uint256 minted, , ) = IMinter_v3(m.minter).mintPeggedTokenDryRun(
                    wrappedIn
                );
                assertGt(minted, 0, string.concat(m.name, ": a retail mint buys pegged"));
                uint256 feesBefore = IERC20(m.wrapped).balanceOf(m.feeReceiver);
                uint256 wrappedBefore = IERC20(m.wrapped).balanceOf(retail);
                vm.startPrank(retail);
                IERC20(m.wrapped).approve(m.minter, 2 * wrappedIn);
                peggedMinted = IMinter_v3(m.minter).mintPeggedToken(wrappedIn, retail, minted);
                vm.stopPrank();
                assertEq(peggedMinted, minted, string.concat(m.name, ": the pegged mint is as its dry run says"));
                assertEq(
                    IERC20(m.pegged).balanceOf(retail) - peggedAtStart,
                    minted,
                    string.concat(m.name, ": and is received")
                );
                assertEq(
                    wrappedBefore - IERC20(m.wrapped).balanceOf(retail),
                    taken,
                    string.concat(m.name, ": for the collateral it states")
                );
                assertEq(
                    IERC20(m.wrapped).balanceOf(m.feeReceiver) - feesBefore,
                    fee,
                    string.concat(m.name, ": and the fee it states")
                );
            }

            // Both pools
            _depositsAndWithdrawsFrom(markets[i], StabilityPoolType.Collateral, peggedMinted / 4);
            _depositsAndWithdrawsFrom(markets[i], StabilityPoolType.Leveraged, peggedMinted / 4);

            // Redeem pegged: all that is out of the pools.
            {
                uint256 peggedIn = IERC20(m.pegged).balanceOf(retail) - peggedAtStart;
                assertGt(peggedIn, 0, string.concat(m.name, ": precondition: pegged to redeem"));
                (, uint256 fee, , uint256 redeemed, uint256 returned, , ) = IMinter_v3(m.minter)
                    .redeemPeggedTokenDryRun(peggedIn);
                assertGt(returned, 0, string.concat(m.name, ": a retail redemption returns collateral"));
                uint256 feesBefore = IERC20(m.wrapped).balanceOf(m.feeReceiver);
                uint256 wrappedBefore = IERC20(m.wrapped).balanceOf(retail);
                uint256 peggedBefore = IERC20(m.pegged).balanceOf(retail);
                vm.startPrank(retail);
                IERC20(m.pegged).approve(m.minter, peggedIn);
                uint256 out = IMinter_v3(m.minter).redeemPeggedToken(peggedIn, retail, returned);
                vm.stopPrank();
                assertEq(out, returned, string.concat(m.name, ": the pegged redemption is as its dry run says"));
                assertEq(
                    IERC20(m.wrapped).balanceOf(retail) - wrappedBefore,
                    returned,
                    string.concat(m.name, ": and is received")
                );
                assertEq(
                    peggedBefore - IERC20(m.pegged).balanceOf(retail),
                    redeemed,
                    string.concat(m.name, ": for the pegged it states")
                );
                assertEq(
                    IERC20(m.wrapped).balanceOf(m.feeReceiver) - feesBefore,
                    fee,
                    string.concat(m.name, ": and the fee it states")
                );
            }

            // Mint leveraged, then redeem it all.
            {
                (, uint256 fee, , uint256 used, uint256 minted, , ) = IMinter_v3(m.minter).mintLeveragedTokenDryRun(
                    wrappedIn
                );
                assertGt(minted, 0, string.concat(m.name, ": a retail mint buys leveraged"));
                uint256 feesBefore = IERC20(m.wrapped).balanceOf(m.feeReceiver);
                uint256 wrappedBefore = IERC20(m.wrapped).balanceOf(retail);
                vm.startPrank(retail);
                uint256 leveragedMinted = IMinter_v3(m.minter).mintLeveragedToken(wrappedIn, retail, minted);
                vm.stopPrank();
                assertEq(leveragedMinted, minted, string.concat(m.name, ": the leveraged mint is as its dry run says"));
                assertEq(IERC20(m.leveraged).balanceOf(retail), minted, string.concat(m.name, ": and is received"));
                assertEq(
                    wrappedBefore - IERC20(m.wrapped).balanceOf(retail),
                    used,
                    string.concat(m.name, ": for the collateral it states")
                );
                assertEq(
                    IERC20(m.wrapped).balanceOf(m.feeReceiver) - feesBefore,
                    fee,
                    string.concat(m.name, ": and the fee it states")
                );
            }
            {
                uint256 leveragedIn = IERC20(m.leveraged).balanceOf(retail);
                (, uint256 fee, uint256 redeemed, uint256 returned, , ) = IMinter_v3(m.minter)
                    .redeemLeveragedTokenDryRun(leveragedIn);
                assertGt(returned, 0, string.concat(m.name, ": a retail redemption of leveraged returns collateral"));
                uint256 feesBefore = IERC20(m.wrapped).balanceOf(m.feeReceiver);
                uint256 wrappedBefore = IERC20(m.wrapped).balanceOf(retail);
                vm.startPrank(retail);
                IERC20(m.leveraged).approve(m.minter, leveragedIn);
                uint256 out = IMinter_v3(m.minter).redeemLeveragedToken(leveragedIn, retail, returned);
                vm.stopPrank();
                assertEq(out, returned, string.concat(m.name, ": the leveraged redemption is as its dry run says"));
                assertEq(
                    IERC20(m.wrapped).balanceOf(retail) - wrappedBefore,
                    returned,
                    string.concat(m.name, ": and is received")
                );
                assertEq(
                    leveragedIn - IERC20(m.leveraged).balanceOf(retail),
                    redeemed,
                    string.concat(m.name, ": for the leveraged it states")
                );
                assertEq(
                    IERC20(m.wrapped).balanceOf(m.feeReceiver) - feesBefore,
                    fee,
                    string.concat(m.name, ": and the fee it states")
                );
            }
        }
    }

    /// An opened market's harvest pays by its config's terms in each of the three cases it can meet: no pool holding a
    /// deposit, so the treasury takes what the pools would; pools holding deposits, which receive only what the config's
    /// bounty and cut leave - nothing, as configured today, where the two are the whole harvest; and a harvest large enough
    /// that the bounty stops at the config's ceiling, which is denominated in this market's own collateral.
    function test_eachOpenedMarket_harvestsByItsConfigsTerms() public {
        vm.skip(markets.length == 0, NOTHING_TO_OPEN);
        for (uint256 i = 0; i < markets.length; ++i) {
            MarketContracts memory m = _contractsOf(markets[i]);
            IHarborConfig config = IHarborConfig(address(markets[i]));
            _open(markets[i]);
            uint256 ceiling = config.harvestBountyCeiling();
            assertGt(ceiling, 0, string.concat(m.name, ": precondition: the config states a ceiling"));
            // The yield whose bounty at the config's ratio is half the ceiling.
            uint256 yieldBelowTheCeiling = Math.mulDiv(ceiling, 1 ether, config.harvestBountyRatio()) / 2;

            // No pool holds a deposit
            _addsYield(m, yieldBelowTheCeiling);
            assertLt(
                _harvestAtItsConfigsTerms(markets[i], keeper),
                ceiling,
                string.concat(m.name, ": below the ceiling")
            );

            // Both pools hold deposits
            address collateralPool = stabilityPoolAddress(markets[i], StabilityPoolType.Collateral);
            address leveragedPool = stabilityPoolAddress(markets[i], StabilityPoolType.Leveraged);
            uint256 inEachPool = DOLLARS_RETAIL * config.aboutADollarInPegged();
            vm.startPrank(stayer);
            IERC20(m.pegged).approve(collateralPool, inEachPool);
            IStabilityPool_v3(collateralPool).deposit(inEachPool, stayer, 0);
            IERC20(m.pegged).approve(leveragedPool, inEachPool);
            IStabilityPool_v3(leveragedPool).deposit(inEachPool, stayer, 0);
            vm.stopPrank();
            _addsYield(m, yieldBelowTheCeiling);
            // The pools hold equal deposits, so each is owed half, and streams what the bounty and the cut leave of it.
            uint256 toEachPool = Math.mulDiv(
                IMinter_v3(m.minter).harvestable() / 2,
                1 ether - config.harvestBountyRatio() - config.harvestCutRatio(),
                1 ether
            );
            assertLt(
                _harvestAtItsConfigsTerms(markets[i], keeper),
                ceiling,
                string.concat(m.name, ": below the ceiling")
            );
            assertEq(
                IERC20(m.wrapped).balanceOf(collateralPool),
                toEachPool,
                string.concat(m.name, ": one pool's stream")
            );
            assertEq(IERC20(m.wrapped).balanceOf(leveragedPool), toEachPool, string.concat(m.name, ": the other's"));

            // Enough that the bounty stops at the ceiling
            _addsYield(m, 4 * yieldBelowTheCeiling);
            assertEq(_harvestAtItsConfigsTerms(markets[i], keeper), ceiling, string.concat(m.name, ": at the ceiling"));
        }
    }

    /// @dev `market`'s name and contracts.
    function _contractsOf(Config_MinterMarket market) private returns (MarketContracts memory m) {
        m.name = MinterMarketConfigLib.salt(market);
        m.genesis = genesisAddress(market);
        m.minter = minterAddress(market);
        m.wrapped = IMinter_v3(m.minter).WRAPPED_COLLATERAL_TOKEN();
        m.pegged = IMinter_v3(m.minter).PEGGED_TOKEN();
        m.leveraged = IMinter_v3(m.minter).LEVERAGED_TOKEN();
        m.feeReceiver = IMinter_v3(m.minter).feeReceiver();
    }

    /// @dev What each depositor enters `market`'s genesis with.
    function _inGenesis(Config_MinterMarket market) private view returns (uint256) {
        return DOLLARS_IN_GENESIS * IHarborConfig(address(market)).aboutADollarInWrappedCollateral();
    }

    /// @dev `depositor` enters `market`'s genesis, through its public deposit.
    function _enterGenesis(Config_MinterMarket market, address depositor) private {
        address genesis = genesisAddress(market);
        address wrapped = IHarborConfig(address(market)).wrappedCollateralToken();
        uint256 amount = _inGenesis(market);
        deal(wrapped, depositor, amount);
        vm.startPrank(depositor);
        IERC20(wrapped).approve(genesis, amount);
        IGenesis(genesis).deposit(amount, depositor);
        vm.stopPrank();
    }

    /// @dev `genesis` ends, as its owner ends it.
    function _endGenesis(address genesis) private {
        address owner_ = IBaoOwnable(genesis).owner();
        vm.startPrank(owner_);
        IGenesis(genesis).endGenesis();
        vm.stopPrank();
    }

    /// @dev `market` opens: its genesis ends, and the stayer claims its share.
    function _open(Config_MinterMarket market) private {
        address genesis = genesisAddress(market);
        _endGenesis(genesis);
        vm.startPrank(stayer);
        IGenesis(genesis).claim(stayer);
        vm.stopPrank();
    }

    /// @dev What `endGenesis` should mint and record on a market with nothing in it, for `wrappedIn` of wrapped collateral,
    ///      at the minter's oracle now. Half of it, floored, buys pegged at the low price and the low rate, each conversion
    ///      floored. The rest is credited at the low rate and buys, as a market's first leveraged tokens, the value of the
    ///      whole backing at the high price, less the pegged minted.
    function _openingAtTheOracle(
        address minter,
        uint256 wrappedIn
    ) private view returns (uint256 pegged, uint256 leveraged, uint256 backing) {
        (uint256 minPrice, uint256 maxPrice, uint256 minRate, ) = IWrappedPriceOracle(IMinter_v3(minter).priceOracle())
            .latestAnswer();
        uint256 wrappedForPegged = wrappedIn / 2;
        uint256 collateralForPegged = Math.mulDiv(wrappedForPegged, minRate, 1 ether);
        pegged = Math.mulDiv(collateralForPegged, minPrice, 1 ether);
        backing = collateralForPegged + Math.mulDiv(wrappedIn - wrappedForPegged, minRate, 1 ether);
        leveraged = (backing * maxPrice - pegged * 1 ether) / 1 ether;
    }

    /// @dev `depositor` claims from `market`'s ended genesis what `share` of `total` gives of the pegged and leveraged the
    ///      genesis minted, and receives it. The pegged token is shared by the peg's markets, so what it receives is read
    ///      as a change.
    function _claimsItsShare(
        Config_MinterMarket market,
        address depositor,
        uint256 share,
        uint256 total,
        uint256 peggedMinted,
        uint256 leveragedMinted
    ) private {
        MarketContracts memory m = _contractsOf(market);
        uint256 peggedExpected = Math.mulDiv(share, peggedMinted, total);
        uint256 leveragedExpected = Math.mulDiv(share, leveragedMinted, total);
        (uint256 peggedClaimable, uint256 leveragedClaimable) = IGenesis(m.genesis).claimable(depositor);
        assertEq(peggedClaimable, peggedExpected, string.concat(m.name, ": the pegged it states as claimable"));
        assertEq(
            leveragedClaimable,
            leveragedExpected,
            string.concat(m.name, ": the leveraged it states as claimable")
        );
        uint256 peggedBefore = IERC20(m.pegged).balanceOf(depositor);
        uint256 leveragedBefore = IERC20(m.leveraged).balanceOf(depositor);

        vm.startPrank(depositor);
        IGenesis(m.genesis).claim(depositor);
        vm.stopPrank();

        assertEq(
            IERC20(m.pegged).balanceOf(depositor) - peggedBefore,
            peggedExpected,
            string.concat(m.name, ": the depositor's share of the pegged")
        );
        assertEq(
            IERC20(m.leveraged).balanceOf(depositor) - leveragedBefore,
            leveragedExpected,
            string.concat(m.name, ": the depositor's share of the leveraged")
        );
        assertEq(IGenesis(m.genesis).balanceOf(depositor), 0, string.concat(m.name, ": with no share left"));
    }

    /// @dev The retail user deposits `amount` in `market`'s `poolType` pool, then takes half of it out with no request,
    ///      paying the config's early-withdrawal fee on it to the pool's fee receiver.
    function _depositsAndWithdrawsFrom(Config_MinterMarket market, StabilityPoolType poolType, uint256 amount) private {
        string memory name = MinterMarketConfigLib.salt(market);
        address pool = stabilityPoolAddress(market, poolType);
        address pegged = IStabilityPool_v3(pool).ASSET_TOKEN();
        address feeReceiver = IStabilityPool_v3(pool).feeReceiver();
        assertEq(
            IStabilityPool_v3(pool).earlyWithdrawalFeeRatio(),
            IHarborConfig(address(market)).stabilityPoolEarlyWithdrawalFeeRatio(),
            string.concat(name, ": precondition: the pool charges its config's fee")
        );

        vm.startPrank(retail);
        IERC20(pegged).approve(pool, amount);
        IStabilityPool_v3(pool).deposit(amount, retail, 0);
        vm.stopPrank();
        assertEq(IStabilityPool_v3(pool).assetBalanceOf(retail), amount, string.concat(name, ": the pool credits it"));

        uint256 leaving = amount / 2;
        uint256 fee = Math.mulDiv(leaving, IStabilityPool_v3(pool).earlyWithdrawalFeeRatio(), 1 ether);
        assertGt(fee, 0, string.concat(name, ": precondition: the withdrawal pays a fee"));
        uint256 feesBefore = IERC20(pegged).balanceOf(feeReceiver);
        uint256 peggedBefore = IERC20(pegged).balanceOf(retail);

        vm.startPrank(retail);
        uint256 out = IStabilityPool_v3(pool).withdraw(leaving, retail, 0);
        vm.stopPrank();

        assertEq(out, leaving - fee, string.concat(name, ": what leaves, less the fee"));
        assertEq(IERC20(pegged).balanceOf(retail) - peggedBefore, leaving - fee, string.concat(name, ": is received"));
        assertEq(IERC20(pegged).balanceOf(feeReceiver) - feesBefore, fee, string.concat(name, ": the fee is paid"));
        assertEq(
            IStabilityPool_v3(pool).assetBalanceOf(retail),
            amount - leaving,
            string.concat(name, ": the rest stays in the pool")
        );
    }

    /// @dev Gives the minter `amount` more wrapped collateral than its record needs, which is what yield is to its
    ///      `harvestable`. A rate that had grown would do the same, and a fork's clock cannot grow it.
    function _addsYield(MarketContracts memory m, uint256 amount) private {
        deal(m.wrapped, m.minter, IERC20(m.wrapped).balanceOf(m.minter) + amount);
    }
}
