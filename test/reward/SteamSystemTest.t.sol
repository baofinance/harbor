// SPDX-License-Identifier: MIT
pragma solidity >=0.8.21 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Test} from "forge-std/Test.sol";

// Interfaces
import {IERC20STEAM} from "src/interfaces/IERC20STEAM.sol";
import {ISteamMinter} from "src/interfaces/ISteamMinter.sol";
import {IGaugeController} from "src/interfaces/IGaugeController.sol";
import {ILiquidityGaugeV6} from "src/interfaces/ILiquidityGaugeV6.sol";
import {IVotingEscrowVy} from "src/interfaces/IVotingEscrowVy.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

import {VotingEscrow_v1} from "src/reward/voting-escrow/VotingEscrow_v1.sol";

abstract contract SteamSystemTest is Test {
    IERC20STEAM public steam;
    ISteamMinter public minter;
    IGaugeController public controller;
    ILiquidityGaugeV6 public gauge;
    address public escrow;

    address public multisig = 0x3dFc49e5112005179Da613BdE5973229082dAc35;
    address public user;

    uint256 public constant TOTAL_SUPPLY = 100_000_000 ether;
    uint256 public constant INITIAL_RATE = 154_585_000_000_000_000;
    uint256 public constant RATE_REDUCTION_COEFFICIENT = 1_147_080_000_000_000_000;

    bool public vyperEscrow;

    constructor(bool vyperEscrow_) {
        vyperEscrow = vyperEscrow_;
    }

    function setUp() public virtual {
        user = makeAddr("user");

        // Deploy and initialize the STEAM token
        steam = IERC20STEAM(vm.deployCode("ERC20STEAM.vy"));

        vm.prank(multisig);
        steam.initialize(61_000_000 ether, INITIAL_RATE, RATE_REDUCTION_COEFFICIENT, multisig, "STEAM", "STEAM");

        if (vyperEscrow) {
            // // 1. Deploy escrow
            escrow = vm.deployCode("VotingEscrow.vy");
            // // 2. Call initialize manually
            vm.prank(multisig);
            IVotingEscrowVy(escrow).initialize(multisig, address(steam), "Voting Escrow Steam", "veSTEAM", "1.0");
        } else {
            // Use the Solidity version of the escrow
            escrow = UnsafeUpgrades.deployUUPSProxy(
                address(new VotingEscrow_v1(address(steam))),
                // "Zhenglong Voting Escrow", "veSTEAM", "1"
                abi.encodeCall(VotingEscrow_v1.initialize, (multisig, "Voting Escrow STEAM", "veSTEAM", "1.0"))
            );

            // VotingEscrow_v1 logic = new VotingEscrow_v1(address(steam));

            // // Prepare the initialization calldata
            // bytes memory initData = abi.encodeWithSelector(
            //     VotingEscrow_v1.initialize.selector,
            //     multisig,
            //     "Voting Escrow Steam",
            //     "veSTEAM",
            //     "1.0"
            // );

            // // Deploy the proxy with the logic address and the initializer calldata
            // ERC1967Proxy proxy = new ERC1967Proxy(address(logic), initData);

            // // Cast the proxy address to VotingEscrow_v1 to interact with it
            // escrow = VotingEscrow_v1(address(proxy));

            IBaoOwnable(escrow).transferOwnership(multisig);
        }

        // Deploy the Gauge Controller and add a gauge type
        controller = IGaugeController(vm.deployCode("GaugeController.vy", abi.encode(address(steam), address(escrow))));
        controller.add_type("Liquidity", 1); // Add type index 0

        // Deploy the Minter and assign it to STEAM
        minter = ISteamMinter(vm.deployCode("SteamMinter.vy", abi.encode(address(steam), address(controller))));

        vm.prank(multisig);
        steam.set_minter(address(minter));
        assertEq(steam.minter(), address(minter));

        // Deploy the Liquidity Gauge V6
        gauge = ILiquidityGaugeV6(
            vm.deployCode(
                "LiquidityGaugeV6.vy",
                abi.encode(
                    address(steam),
                    address(steam),
                    address(controller),
                    address(minter),
                    address(escrow),
                    address(escrow)
                )
            )
        );

        // Register the gauge in the controller
        controller.add_gauge(address(gauge), 0, 1); // 0 = type index, 1 = weight
    }

    function test_Deployment() public view {
        assertEq(steam.totalSupply(), 61_000_000 ether);
        assertEq(steam.balanceOf(multisig), 61_000_000 ether);
        assertEq(steam.minter(), address(minter));
    }

    function test_MinterAddressIsCorrect() public view {
        // The minter should be correctly set by this point
        address expectedMinter = address(minter);

        // Fetch the actual minter address from the STEAM token
        address actualMinter = steam.minter();

        // Assert that the expected and actual addresses match
        assertEq(actualMinter, expectedMinter, "Minter address not set correctly");
    }

    function test_MiningAndMinting() public {
        // 1. Advance time to enable first mining epoch
        skip(365 days);
        steam.update_mining_parameters();

        // 2. Setup test user and amounts
        address eoa = 0xb9ab9578a34a05c86124c399735fdE44dEc80E7F; // test EOA
        uint256 lockAmount = 100 ether;
        uint256 depositAmount = 100 ether;
        uint256 unlockTime = block.timestamp + 4 * 365 days;

        // 3. Fund EOA with STEAM tokens
        vm.prank(multisig);
        steam.transfer(eoa, lockAmount + depositAmount);

        // 4. Lock STEAM in Voting Escrow
        vm.startPrank(eoa, eoa);
        steam.approve(address(escrow), lockAmount);
        IVotingEscrowVy(address(escrow)).create_lock(lockAmount, unlockTime);
        IVotingEscrowVy(address(escrow)).checkpoint();

        // 5. Deposit STEAM in Gauge (staking)
        steam.approve(address(gauge), depositAmount);
        gauge.deposit(depositAmount);
        vm.stopPrank();

        // 6. Advance time to accrue rewards
        skip(7 days); // simulate reward accumulation period

        // 7. User calls checkpoint
        vm.prank(eoa);
        gauge.user_checkpoint(eoa);

        // 8. Allow minter to mint for user
        vm.prank(eoa);
        minter.toggle_approve_mint(address(this));
        assertTrue(minter.allowed_to_mint_for(address(this), eoa));

        // 9. Mint STEAM rewards
        minter.mint_for(address(gauge), eoa);

        // 10. Assert minted balance
        uint256 minted = steam.balanceOf(eoa);
        assertGt(minted, 0, "User should have received minted STEAM");
    }

    function test_SupplyCap() public {
        // Simulate passage of 50 years
        skip(50 * 365 days);

        // Update mining parameters for each year
        for (uint256 i = 0; i < 50; i++) {
            steam.update_mining_parameters();
        }

        uint256 emitted = steam.available_supply();

        // Define upper and lower bounds
        uint256 tolerance = 1e16; // 0.01 ether
        uint256 upperBound = TOTAL_SUPPLY + tolerance; // 100M + 0.01 tokens
        uint256 lowerBound = (TOTAL_SUPPLY * 985) / 1000; // 98.5% of TOTAL_SUPPLY

        // Assertions
        assertGt(emitted, lowerBound, "Emitted too little (<98.5% of total supply)");
        assertLe(emitted, upperBound, "Emitted too much (>100M + 0.01)");
    }

    function test_GaugeNotInControllerReverts() public {
        address badGauge = 0xF93e3b13103a22b49d272A8B638da0ACFe79EDd7;
        vm.prank(user);
        minter.toggle_approve_mint(address(this)); // Allow this test contract to mint for `user`

        vm.expectRevert();
        minter.mint_for(badGauge, user);
    }

    function test_ToggleApproveMint() public {
        bool initial = minter.allowed_to_mint_for(address(this), user);

        // Simulate user calling toggle for msg.sender = address(this)
        vm.prank(user);
        minter.toggle_approve_mint(address(this));

        bool afterToggle = minter.allowed_to_mint_for(address(this), user);

        assertTrue(initial != afterToggle, "Toggle should flip state");
    }

    function test_ControllerGaugeType() public view {
        assertEq(controller.gauge_types(address(gauge)), 0);
    }

    function test_EscrowLockCreatesBalance() public {
        uint256 lockAmount = 100 ether;
        uint256 unlockTime = block.timestamp + 4 * 365 days;

        address eoa = 0xb9ab9578a34a05c86124c399735fdE44dEc80E7F;

        vm.prank(multisig);
        steam.transfer(eoa, lockAmount);

        // Simulate tx.origin and msg.sender being the same
        vm.startPrank(eoa, eoa); // <- sets msg.sender and tx.origin
        steam.approve(escrow, lockAmount);
        IVotingEscrowVy(escrow).create_lock(lockAmount, unlockTime);
        vm.stopPrank();

        assertGt(IVotingEscrowVy(escrow).balanceOf(eoa), 0);
    }

    function test_SmartContractCannotCreateLock() public {
        uint256 lockAmount = 100 ether;
        uint256 unlockTime = block.timestamp + 4 * 365 days;

        // Give the test contract STEAM tokens
        vm.prank(multisig);
        steam.transfer(address(this), lockAmount);

        steam.approve(escrow, lockAmount);

        // Expect revert with exact revert message
        vyperEscrow
            ? vm.expectRevert("Smart contract depositors not allowed")
            : vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IVotingEscrowVy(escrow).create_lock(lockAmount, unlockTime);
    }
}

contract SteamSystemVyEscrowTest is SteamSystemTest {
    constructor() SteamSystemTest(true) {}
}

contract SteamSystemSolEscrowTest is SteamSystemTest {
    constructor() SteamSystemTest(false) {}
}
