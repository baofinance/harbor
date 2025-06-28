// SPDX-License-Identifier: MIT
pragma solidity >=0.8.21 <0.9.0;

import {Test} from "forge-std/Test.sol";

// Interfaces
import {IERC20STEAM} from "src/interfaces/IERC20STEAM.sol";
import {ISteamMinter} from "src/interfaces/ISteamMinter.sol";
import {IGaugeController} from "src/interfaces/IGaugeController.sol";
import {ILiquidityGaugeV6} from "src/interfaces/ILiquidityGaugeV6.sol";
import {VotingEscrow_v1} from "src/reward/voting-escrow/VotingEscrow_v1.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

interface ILiquidityGaugeV6Mock is ILiquidityGaugeV6 {
    function set_mock_fraction(address user, uint256 value) external;
}

error Unauthorized();

contract SteamSystemTest is Test {
    IERC20STEAM public steam;
    ISteamMinter public minter;
    IGaugeController public controller;
    ILiquidityGaugeV6 public gauge;
    VotingEscrow_v1 public escrow;

    address public multisig = 0x3dFc49e5112005179Da613BdE5973229082dAc35;
    address public user;

    uint256 public constant TOTAL_SUPPLY = 100_000_000 ether;
    uint256 public constant INITIAL_RATE = 159_529_984_450_000_000;
    uint256 public constant RATE_REDUCTION_COEFFICIENT = 1290000000;

    function setUp() public {
        user = makeAddr("user");

        // Deploy and initialize the STEAM token
        steam = IERC20STEAM(vm.deployCode("ERC20STEAM.vy"));

        vm.prank(multisig);
        steam.initialize(
            61_000_000 ether,
            INITIAL_RATE,
            RATE_REDUCTION_COEFFICIENT,
            multisig,
            "STEAM",
            "STEAM"
        );

        // Deploy the Gauge Controller and add a gauge type
        controller = IGaugeController(vm.deployCode("GaugeController.vy", abi.encode(address(steam), address(0xDEAD))));
        controller.add_type("Liquidity", 1);  // Add type index 0

        // Deploy the Minter and assign it to STEAM
        minter = ISteamMinter(vm.deployCode("SteamMinter.vy", abi.encode(address(steam), address(controller))));

        vm.prank(multisig);
        steam.set_minter(address(minter));

        // Deploy the logic (implementation) contract
        VotingEscrow_v1 logic = new VotingEscrow_v1(address(steam));

        // Prepare the initialization calldata
        bytes memory initData = abi.encodeWithSelector(
            VotingEscrow_v1.initialize.selector,
            multisig,
            "Voting Escrow Steam",
            "veSTEAM",
            "1.0"
        );

        // Deploy the proxy with the logic address and the initializer calldata
        ERC1967Proxy proxy = new ERC1967Proxy(address(logic), initData);

        // Cast the proxy address to VotingEscrow_v1 to interact with it
        escrow = VotingEscrow_v1(address(proxy));

        // Deploy the Liquidity Gauge V6
        gauge = ILiquidityGaugeV6(
            vm.deployCode("LiquidityGaugeV6.vy", abi.encode(address(steam), address(steam), address(controller), address(minter), address(escrow)))
        );

        // Register the gauge in the controller
        controller.add_gauge(address(gauge), 0, 1);  // 0 = type index, 1 = weight
     }

    function test_Deployment() public view {
        assertEq(steam.totalSupply(), 61_000_000 ether);
        assertEq(steam.balanceOf(multisig), 61_000_000 ether);
        assertEq(steam.minter(), address(minter));
    }

    function test_MiningAndMinting() public {
        skip(365 days);
        steam.update_mining_parameters();

        vm.prank(user);
        gauge.user_checkpoint(user);
        ILiquidityGaugeV6Mock(address(gauge)).set_mock_fraction(user, 100 ether);

        vm.prank(user);
        minter.toggle_approve_mint(address(this));
        minter.mint_for(address(gauge), user);

        assertGt(steam.balanceOf(user), 0);
    }

    function test_SupplyCap() public {
        skip(20 * 365 days);
        for (uint256 i = 0; i < 20; i++) {
            steam.update_mining_parameters();
        }
        assertLe(steam.available_supply(), TOTAL_SUPPLY);
    }

    function test_MintMany() public {
        skip(365 days);
        steam.update_mining_parameters();

        vm.prank(user);
        gauge.user_checkpoint(user);
        ILiquidityGaugeV6Mock(address(gauge)).set_mock_fraction(user, 100 ether);

        vm.prank(user);
        minter.toggle_approve_mint(address(this));

        address[8] memory gauges;
        gauges[0] = address(gauge);

        minter.mint_many(gauges);

        assertGt(steam.balanceOf(user), 0);
    }

    function test_GaugeNotInControllerReverts() public {
        address badGauge = 0xF93e3b13103a22b49d272A8B638da0ACFe79EDd7;
        vm.prank(user);
        minter.toggle_approve_mint(address(this)); // Allow this test contract to mint for `user`

        vm.expectRevert("Gauge not in controller");
        minter.mint_for(badGauge, user);
    }

    function test_ToggleApproveMint() public {
        bool initial = minter.allowed_to_mint_for(address(this), user);
        minter.toggle_approve_mint(user);
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
        vm.startPrank(eoa, eoa);  // <- sets msg.sender and tx.origin
        steam.approve(address(escrow), lockAmount);
        escrow.create_lock(lockAmount, unlockTime);
        vm.stopPrank();

        assertGt(escrow.balanceOf(eoa), 0);
    }

    function test_SmartContractCannotCreateLock() public {
        uint256 lockAmount = 100 ether;
        uint256 unlockTime = block.timestamp + 4 * 365 days;

        // Give the test contract STEAM tokens
        vm.prank(multisig);
        steam.transfer(address(this), lockAmount);

        steam.approve(address(escrow), lockAmount);

        // Expect revert with the actual error used in the contract
        vm.expectRevert(Unauthorized.selector);
        escrow.create_lock(lockAmount, unlockTime);
    }

}
