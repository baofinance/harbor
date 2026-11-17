// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IGenesis} from "@harbor/interfaces/IGenesis.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {eurMintersConfig} from "@harbor-script/src/Deploy_EUR_Minter.sol";
import {DeployEURSetUp} from "@harbor-test/deployment/DeployEURSetUp.t.sol";

/// @notice The markets of a peg share one pegged token, so its holder can take it to a market that has not had its
///         genesis. That market's minter redeems none of it, and its pools take it as they take any pegged token: nothing
///         can take it from them while the market is empty, and it comes back.
/// @dev EUR::fxUSD mints the pegged token. EUR::stETH is the market before its genesis.
contract MarketBeforeItsGenesisTest is DeployEURSetUp {
    address private holder = makeAddr("holder");
    uint256 private heldPegged;

    function setUp() public override {
        super.setUp();
        heldPegged = _mintPegged(fxUSD.minter, holder, 1000 ether);
        assertEq(IMinter(stETH.minter).peggedTokenBalance(), 0, "precondition: this market has minted nothing");
        assertEq(IMinter(stETH.minter).collateralTokenBalance(), 0, "precondition: this market holds no collateral");
        assertEq(IERC20(stETH.pegged).balanceOf(holder), heldPegged, "precondition: the market mints the same token");
    }

    /// The fee-paying redeem refuses another market's pegged token, naming the token, and takes none of it.
    function test_itsMinter_refusesARedeemOfAnotherMarketsPegged() public {
        vm.startPrank(holder);
        IERC20(pegged).approve(stETH.minter, heldPegged);
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, pegged));
        IMinter(stETH.minter).redeemPeggedToken(heldPegged, holder, 0);
        vm.stopPrank();

        assertEq(IERC20(pegged).balanceOf(holder), heldPegged, "the holder keeps their pegged token");
    }

    /// Both pools credit another market's pegged token one for one, and the market's minter records nothing of it.
    function test_itsPools_takeADepositOfAnotherMarketsPegged() public {
        uint256 each = heldPegged / 2;
        address[2] memory pools = [stETH.collateralPool, stETH.leveragedPool];
        for (uint256 i = 0; i < pools.length; ++i) {
            _deposit(pools[i], each);
            assertEq(IStabilityPool_v3(pools[i]).assetBalanceOf(holder), each, "the holder is credited one for one");
            assertEq(IStabilityPool_v3(pools[i]).totalAssetSupply(), each, "the pool's supply is the deposit");
            assertEq(IERC20(pegged).balanceOf(pools[i]), each, "the pool holds the pegged token");
        }
        assertEq(IMinter(stETH.minter).peggedTokenBalance(), 0, "the minter records nothing it did not mint");
    }

    /// A rebalance cannot take the deposit: the market's minter has minted no pegged token, so there is none it can
    /// redeem. The rebalance reverts having nothing to take, and none is offered.
    function test_thatDeposit_cannotBeRebalancedAway() public {
        uint256 each = heldPegged / 2;
        _deposit(stETH.collateralPool, each);
        _deposit(stETH.leveragedPool, each);
        address keeper = makeAddr("keeper");

        assertFalse(IStabilityPoolManager_v2(stETH.manager).rebalanceable(), "no rebalance is on offer");
        vm.expectRevert(abi.encodeWithSelector(IStabilityPoolManager_v2.NoTokensToLiquidate.selector, pegged));
        IStabilityPoolManager_v2(stETH.manager).rebalance(keeper, 0);

        assertEq(IStabilityPool_v3(stETH.collateralPool).totalAssetSupply(), each, "the collateral pool keeps it");
        assertEq(IStabilityPool_v3(stETH.leveragedPool).totalAssetSupply(), each, "the leveraged pool keeps it");
    }

    /// A sole depositor gets back all but the pool's floor, which stays theirs: free of fee inside a requested window,
    /// and less the pool's fee outside one.
    function test_thatDeposit_comesBack() public {
        uint256 each = heldPegged / 2;
        _deposit(stETH.collateralPool, each);
        _deposit(stETH.leveragedPool, each);

        vm.startPrank(holder);
        IStabilityPool_v3(stETH.collateralPool).requestWithdrawal();
        vm.stopPrank();
        (uint64 windowStart, ) = IStabilityPool_v3(stETH.collateralPool).withdrawalRequest(holder);
        vm.warp(windowStart);

        uint256 floor = IStabilityPool_v3(stETH.collateralPool).MIN_TOTAL_ASSET_SUPPLY();
        uint256 paidInWindow = _withdrawAll(stETH.collateralPool);
        assertEq(paidInWindow, each - floor, "inside the window, all but the floor and no fee");
        assertEq(IStabilityPool_v3(stETH.collateralPool).assetBalanceOf(holder), floor, "the floor stays the holder's");

        address feeReceiver = IStabilityPool_v3(stETH.leveragedPool).feeReceiver();
        uint256 feeReceiverBefore = IERC20(pegged).balanceOf(feeReceiver);
        uint256 leavingThePool = each - IStabilityPool_v3(stETH.leveragedPool).MIN_TOTAL_ASSET_SUPPLY();
        uint256 fee = (leavingThePool * IStabilityPool_v3(stETH.leveragedPool).earlyWithdrawalFeeRatio()) / 1 ether;
        assertGt(fee, 0, "precondition: the pool charges a fee");

        uint256 paidOutsideAWindow = _withdrawAll(stETH.leveragedPool);
        assertEq(paidOutsideAWindow, leavingThePool - fee, "outside a window, less the pool's fee");
        assertEq(IERC20(pegged).balanceOf(feeReceiver), feeReceiverBefore + fee, "the fee goes to the pool's receiver");
    }

    /// When the genesis ends, the deposit stays whole, and the minter's record counts only what the genesis minted.
    function test_thatDeposit_staysWhole_whenTheGenesisEnds() public {
        _deposit(stETH.collateralPool, heldPegged);
        (, Config_MinterMarket[] memory markets) = eurMintersConfig();
        address genesis = deployRun.genesisAddress(markets[1]);

        uint256 genesisDeposit = 10 ether;
        deal(stETH.wrappedCollateral, address(this), genesisDeposit);
        IERC20(stETH.wrappedCollateral).approve(genesis, genesisDeposit);
        IGenesis(genesis).deposit(genesisDeposit, address(this));
        vm.startPrank(HARBOR_MULTISIG);
        IGenesis(genesis).endGenesis();
        vm.stopPrank();

        uint256 mintedByTheGenesis = IERC20(pegged).balanceOf(genesis);
        assertGt(mintedByTheGenesis, 0, "the genesis minted pegged tokens");
        assertEq(IMinter(stETH.minter).peggedTokenBalance(), mintedByTheGenesis, "the record is the genesis's alone");
        assertGt(IMinter_v3(stETH.minter).collateralRatio(), 1 ether, "the market is open, above the peg");
        assertEq(IStabilityPool_v3(stETH.collateralPool).assetBalanceOf(holder), heldPegged, "the deposit is whole");
        assertEq(
            IStabilityPool_v3(stETH.collateralPool).totalAssetSupply(),
            heldPegged,
            "the pool's supply is unchanged"
        );
    }

    function _deposit(address pool, uint256 amount) private {
        vm.startPrank(holder);
        IERC20(pegged).approve(pool, amount);
        IStabilityPool_v3(pool).deposit(amount, holder, amount);
        vm.stopPrank();
    }

    /// @dev Withdraw the holder's whole balance from `pool` and return what the holder received.
    function _withdrawAll(address pool) private returns (uint256 paid) {
        uint256 before = IERC20(pegged).balanceOf(holder);
        vm.startPrank(holder);
        IStabilityPool_v3(pool).withdraw(type(uint256).max, holder, 0);
        vm.stopPrank();
        paid = IERC20(pegged).balanceOf(holder) - before;
    }
}
