// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {TestStabilityPoolSetUp} from "test/StabilityPool.t.sol";

// OpenZeppelin & Forge
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Interfaces
import {IERC20STEAM} from "src/interfaces/IERC20STEAM.sol";
import {ISteamMinter} from "src/interfaces/ISteamMinter.sol";
import {IGaugeController} from "src/interfaces/IGaugeController.sol";
import {ILiquidityGaugeV6} from "src/interfaces/ILiquidityGaugeV6.sol";
import {IVotingEscrowVy} from "src/interfaces/IVotingEscrowVy.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IMultipleRewardDistributor} from "src/interfaces/IMultipleRewardDistributor.sol";

// Implementations
import {VotingEscrow_v1} from "src/reward/voting-escrow/VotingEscrow_v1.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

contract TestStabilityPoolWithSteam is TestStabilityPoolSetUp {
    // Roles & actors
    address public user3;
    address public rewarder;
    address public rebalancer;
    address public rewardManager;
    address public multisig = 0x3dFc49e5112005179Da613BdE5973229082dAc35;

    // STEAM setup
    IERC20STEAM public steam2;
    ISteamMinter public minter2;
    IGaugeController public controller;
    ILiquidityGaugeV6 public gauge;
    address public escrow;

    // Additional mock tokens
    MockERC20 public rewardToken;
    MockERC20 public liquidationToken;

    // Constants
    uint256 public constant INITIAL_BALANCE = 1000 ether;
    uint256 public constant DEPOSIT_AMOUNT = 100 ether;
    uint256 public constant REWARD_AMOUNT = 50 ether;
    uint256 public constant INITIAL_RATE = 154_585_000_000_000_000;
    uint256 public constant RATE_REDUCTION_COEFFICIENT = 1_147_080_000_000_000_000;
    uint256 constant MINTER_ROLE = 1;
    uint256 constant BURNER_ROLE = 2;

    function setUp() public override {
        super.setUp();

        // Deploy STEAM
        steam2 = IERC20STEAM(vm.deployCode("ERC20STEAM.vy"));
        vm.prank(multisig);
        steam2.initialize(61_000_000 ether, INITIAL_RATE, RATE_REDUCTION_COEFFICIENT, multisig, "STEAM", "STEAM");

        // Deploy escrow
        escrow = UnsafeUpgrades.deployUUPSProxy(
            address(new VotingEscrow_v1(address(steam2))),
            abi.encodeCall(VotingEscrow_v1.initialize, (multisig, "Voting Escrow STEAM", "veSTEAM", "1.0"))
        );
        IBaoOwnable(escrow).transferOwnership(multisig);

        // Gauge controller + minter
        controller = IGaugeController(
            vm.deployCode("GaugeController.vy", abi.encode(address(steam2), address(escrow)))
        );
        controller.add_type("Liquidity", 1);
        minter2 = ISteamMinter(vm.deployCode("SteamMinter.vy", abi.encode(address(steam2), address(controller))));

        vm.prank(multisig);
        steam2.set_minter(address(minter2));

        // Create actors
        user3 = vm.createWallet("user3").addr;
        rewarder = vm.createWallet("rewarder").addr;
        rebalancer = vm.createWallet("rebalancer").addr;
        rewardManager = vm.createWallet("rewardManager").addr;

        // Create mock reward & liquidation tokens
        rewardToken = new MockERC20("Reward Token", "RWD", 18);
        liquidationToken = new MockERC20("Liquidation Token", "LQT", 18);

        // Grant roles to new addresses
        uint256 rebalancerRole = IStabilityPool(stabilityPoolCollateral).REBALANCER_ROLE();
        uint256 rewarderRole = IStabilityPool(stabilityPoolCollateral).REWARDER_ROLE();
        uint256 rewardManagerRole = IMultipleRewardDistributor(stabilityPoolCollateral).REWARD_MANAGER_ROLE();

        vm.startPrank(owner);
        IBaoRoles(stabilityPoolCollateral).grantRoles(rewarder, rewarderRole);
        IBaoRoles(stabilityPoolCollateral).grantRoles(rebalancer, rebalancerRole);
        IBaoRoles(stabilityPoolCollateral).grantRoles(rewardManager, rewardManagerRole);
        IMultipleRewardDistributor(stabilityPoolCollateral).registerRewardToken(
            address(rewardToken),
            stabilityPoolCollateral
        );
        vm.stopPrank();

        // Mint and distribute tokens
        rewardToken.mint(rewarder, INITIAL_BALANCE);
        liquidationToken.mint(rebalancer, INITIAL_BALANCE);

        // Approvals
        vm.prank(user1);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);

        vm.prank(user2);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);

        vm.prank(user3);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);

        vm.prank(rewarder);
        rewardToken.approve(stabilityPoolCollateral, type(uint256).max);

        // Allocate test funds
        deal(peggedToken, user1, INITIAL_BALANCE);
        deal(peggedToken, user2, INITIAL_BALANCE);
        deal(peggedToken, user3, INITIAL_BALANCE);

        // Deploy a dummy gauge (can be overridden later)
        gauge = ILiquidityGaugeV6(
            vm.deployCode(
                "LiquidityGaugeV6.vy",
                abi.encode(
                    address(peggedToken),
                    address(steam2),
                    address(controller),
                    address(minter2),
                    address(escrow),
                    address(escrow)
                )
            )
        );
        controller.add_gauge(address(gauge), 0, 1);

        setUp_collateral(1000 ether, 1000 ether);
    }

    function testInitialState() public view {
        // Check initial state
        assertEq(IStabilityPool(stabilityPoolCollateral).totalAssetSupply(), 0);
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1), 0);
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user2), 0);
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user3), 0);
    }

    function testDeposit() public {
        // User1 deposits
        vm.startPrank(user1);
        uint256 deposited = IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();

        // Check deposit results
        assertEq(deposited, DEPOSIT_AMOUNT);
        assertEq(IStabilityPool(stabilityPoolCollateral).totalAssetSupply(), DEPOSIT_AMOUNT);
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1), DEPOSIT_AMOUNT);
    }

    function testDepositAndUpdateGauge() public {
        // Step 1: Deposit into StabilityPool
        vm.startPrank(user1);
        uint256 deposited = IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();

        // Step 2: Deploy a new LiquidityGauge using SPT as lp_token
        address spt = IStabilityPool(stabilityPoolCollateral).GAUGE_STAKE_TOKEN();

        vm.startPrank(address(this)); // Test contract owns the SPT
        IBaoRoles(spt).grantRoles(address(stabilityPoolCollateral), 1); // 1 = SMART_CONTRACT_MANAGER_ROLE or MINTER_ROLE
        vm.stopPrank();

        ILiquidityGaugeV6 newGauge = ILiquidityGaugeV6(
            vm.deployCode(
                "LiquidityGaugeV6.vy",
                abi.encode(
                    address(stabilityPoolCollateral),
                    address(steam),
                    address(controller),
                    address(minter),
                    address(escrow),
                    address(escrow)
                )
            )
        );

        // Step 3: Register gauge
        controller.add_gauge(address(newGauge), 0, 1);

        // Step 4: Update the gauge in the StabilityPool
        address ownerOfSP = IBaoOwnable(stabilityPoolCollateral).owner();
        vm.prank(ownerOfSP);
        IStabilityPool(stabilityPoolCollateral).updateGauge(address(newGauge));

        // ✅ Final assertions
        assertEq(deposited, DEPOSIT_AMOUNT);
        assertEq(IStabilityPool(stabilityPoolCollateral).totalAssetSupply(), DEPOSIT_AMOUNT);
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1), DEPOSIT_AMOUNT);
    }

    function testUpdateGaugeTwiceMovesSPT() public {
        // Initial deposit into the StabilityPool
        vm.startPrank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();

        // Fetch SPT token used by the gauge system
        address spt = IStabilityPool(stabilityPoolCollateral).GAUGE_STAKE_TOKEN();

        // Ensure the test contract owns the SPT token (proxy likely owns it initially)
        address sptOwner = IBaoOwnable(spt).owner();
        if (sptOwner != address(this)) {
            vm.prank(sptOwner);
            IBaoOwnable(spt).transferOwnership(address(this));
        }

        // Grant MINTER and BURNER roles to the StabilityPool
        vm.prank(address(this));
        IBaoRoles(spt).grantRoles(stabilityPoolCollateral, MINTER_ROLE); // 1 = MINTER_ROLE or SMART_CONTRACT_MANAGER_ROLE

        vm.prank(address(this));
        IBaoRoles(spt).grantRoles(stabilityPoolCollateral, BURNER_ROLE);

        // Prepare the first gauge
        ILiquidityGaugeV6 gauge1 = ILiquidityGaugeV6(
            vm.deployCode(
                "LiquidityGaugeV6.vy",
                abi.encode(
                    stabilityPoolCollateral,
                    address(steam2),
                    address(controller),
                    address(minter2),
                    address(escrow),
                    address(escrow)
                )
            )
        );
        controller.add_gauge(address(gauge1), 0, 1);

        // Update gauge to gauge1
        address spOwner = IBaoOwnable(stabilityPoolCollateral).owner();
        vm.prank(spOwner);
        IStabilityPool(stabilityPoolCollateral).updateGauge(address(gauge1));

        // Confirm gauge1 now holds 1e18 stake
        assertEq(gauge1.balanceOf(stabilityPoolCollateral), 1 ether);

        // Prepare second gauge
        ILiquidityGaugeV6 gauge2 = ILiquidityGaugeV6(
            vm.deployCode(
                "LiquidityGaugeV6.vy",
                // abi.encode(spt, address(steam2), address(controller), address(minter2), address(escrow), address(escrow))
                abi.encode(
                    stabilityPoolCollateral,
                    address(steam2),
                    address(controller),
                    address(minter2),
                    address(escrow),
                    address(escrow)
                )
            )
        );
        controller.add_gauge(address(gauge2), 0, 1);

        // Update to second gauge — will withdraw from gauge1 and burn, then mint to gauge2
        vm.prank(spOwner);
        IStabilityPool(stabilityPoolCollateral).updateGauge(address(gauge2));

        // Final assertion: new gauge holds exactly 1 ether of SPT
        assertEq(gauge2.balanceOf(stabilityPoolCollateral), 1 ether);
    }

    function testUpdateGaugeToZeroBurnsSPT() public {
        // Step 1: User deposits into StabilityPool
        vm.startPrank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();

        // Step 2: Setup the SPT and deploy gauge
        address spt = IStabilityPool(stabilityPoolCollateral).GAUGE_STAKE_TOKEN();
        ILiquidityGaugeV6 gauge1 = ILiquidityGaugeV6(
            vm.deployCode(
                "LiquidityGaugeV6.vy",
                abi.encode(
                    stabilityPoolCollateral,
                    address(steam2),
                    address(controller),
                    address(minter2),
                    address(escrow),
                    address(escrow)
                )
            )
        );
        controller.add_gauge(address(gauge1), 0, 1);

        // Step 3: Assign BURNER_ROLE on SPT to the StabilityPool
        address sptOwner = IBaoOwnable(spt).owner();
        vm.startPrank(sptOwner);
        IBaoRoles(spt).grantRoles(address(stabilityPoolCollateral), BURNER_ROLE);
        vm.stopPrank();

        // Step 4: Assign SMART_CONTRACT_MANAGER_ROLE so SP can mint/transfer SPT
        vm.prank(address(this));
        IBaoRoles(spt).grantRoles(address(stabilityPoolCollateral), 1); // SMART_CONTRACT_MANAGER_ROLE

        // Step 5: SP owner updates to use a gauge
        address spOwner = IBaoOwnable(stabilityPoolCollateral).owner();
        vm.prank(spOwner);
        IStabilityPool(stabilityPoolCollateral).updateGauge(address(gauge1));

        // Step 6: Gauge should have non-zero stake after update
        uint256 staked = gauge1.balanceOf(stabilityPoolCollateral);
        assertGt(staked, 0);

        // Step 7: SP owner updates to null gauge (should burn SPT)
        vm.prank(spOwner);
        IStabilityPool(stabilityPoolCollateral).updateGauge(address(0));

        // Step 8: Assert both gauge and SP hold zero SPT after burn
        assertEq(gauge1.balanceOf(stabilityPoolCollateral), 0);
        assertEq(IERC20(spt).balanceOf(stabilityPoolCollateral), 0);
    }

    function testDepositAndMintRewards() public {
        // Step 1: Deposit into StabilityPool
        vm.startPrank(user1);
        uint256 deposited = IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();

        // Step 2: Deploy gauge with SPT
        address spt = IStabilityPool(stabilityPoolCollateral).GAUGE_STAKE_TOKEN();

        // Step 3: Grant roles for minting and burning
        address sptOwner = IBaoOwnable(spt).owner();
        if (sptOwner != address(this)) {
            vm.prank(sptOwner);
            IBaoOwnable(spt).transferOwnership(address(this));
        }

        vm.prank(address(this));
        IBaoRoles(spt).grantRoles(address(stabilityPoolCollateral), MINTER_ROLE);
        vm.prank(address(this));
        IBaoRoles(spt).grantRoles(address(stabilityPoolCollateral), BURNER_ROLE);

        // Step 4: Deploy and register gauge
        ILiquidityGaugeV6 newGauge = ILiquidityGaugeV6(
            vm.deployCode(
                "LiquidityGaugeV6.vy",
                abi.encode(
                    stabilityPoolCollateral,
                    address(steam2),
                    address(controller),
                    address(minter2),
                    address(escrow),
                    address(escrow)
                )
            )
        );
        controller.add_gauge(address(newGauge), 0, 1);

        // Step 5: Update gauge
        address spOwner = IBaoOwnable(stabilityPoolCollateral).owner();
        vm.prank(spOwner);
        IStabilityPool(stabilityPoolCollateral).updateGauge(address(newGauge));

        // Step 6: Advance time to enable emissions
        skip(365 days); // emission epoch delay
        steam2.update_mining_parameters();

        // Step 7: Simulate some inflation time
        skip(30 days);

        // Step 8: Ensure gauge weight records are updated
        controller.checkpoint_gauge(address(newGauge));
        uint256 weight = controller.gauge_relative_weight(address(newGauge));
        console2.log("Gauge relative weight:", weight); // should be > 0

        // Step 9: Approve the test contract to mint rewards on behalf of StabilityPool
        vm.prank(address(stabilityPoolCollateral));
        minter2.toggle_approve_mint(address(this));

        // Sanity check
        assertTrue(minter2.allowed_to_mint_for(address(this), address(stabilityPoolCollateral)));

        // Step 10: Mint STEAM rewards to the StabilityPool
        minter2.mint_for(address(newGauge), address(stabilityPoolCollateral));

        // Final assertion: StabilityPool should have received STEAM
        uint256 rewardBalance = steam2.balanceOf(address(stabilityPoolCollateral));
        assertGt(rewardBalance, 0, "STEAM should have been minted to StabilityPool");
    }
}
