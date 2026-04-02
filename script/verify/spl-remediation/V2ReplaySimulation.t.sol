// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {HarborFactoryDeployer} from "script/src/HarborFactoryDeployer.sol";
import {StabilityPoolManager_v1} from "src/minter/StabilityPoolManager_v1.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {Minter_v2} from "src/minter/Minter_v2.sol";
import {MockWrappedPriceOracle} from "test/mocks/MockWrappedPriceOracle.sol";
import {console2 as console} from "forge-std/console2.sol";

/// @title V1/V2 Replay Simulation
/// @notice Replays the exact sequence of on-chain events (5 rebalances + user
/// claims/withdrawals/redeems) from a single fork, mocking oracle prices.
/// test_v1Replay validates against mainnet. test_v2Replay produces the "correct world".
contract V2ReplaySimulation is BaoTest, HarborFactoryDeployer {
    uint256 constant FORK_BLOCK = 24687073;

    address spm;
    address minterAddr;
    address spl;
    address spc;
    address lev;
    address peg;
    address realOracle;
    address proxyOwner;
    MockWrappedPriceOracle mockOracle;

    address constant CLAIMER = 0xb9ab9578a34a05c86124c399735fdE44dEc80E7F;
    address constant EXITER = 0x31632636D664895f1BD9D03f5F7c162A2A6980EB;

    // ---- Event timeline data ----
    // Each step has oracle + timing data plus expected mainnet state after.
    struct Step {
        uint256 blockNum;
        uint256 timestamp;
        uint256 oraclePrice;
        uint256 oracleRate;
        // Expected mainnet state AFTER this step (for v1 validation)
        uint256 supply; // leveraged totalSupply
        uint256 splLevBal; // SPL's leveraged token balance
        uint256 claimerLevBal; // Claimer's leveraged token balance
        uint256 exiterLevBal; // Exiter's leveraged token balance
        uint256 exiterDep; // Exiter's SPL deposit (assetBalanceOf)
        uint256 levPrice; // leveragedTokenPrice
    }

    // 15 steps matching the exact on-chain event sequence
    // Step fields: blockNum, timestamp, oraclePrice, oracleRate, supply, splLevBal, claimerLevBal, exiterLevBal, exiterDep, levPrice
    Step[15] steps;

    function _initSteps() private {
        steps[0] = Step(
            24687074,
            1773869531,
            456157348740503,
            1079654693991021390,
            9288233300350354394,
            8827773010867127157,
            321340262873233811,
            0,
            20549016838011003,
            171058457268324856
        ); // rebalance #1
        steps[1] = Step(
            24687129,
            1773870203,
            453806599545179,
            1079654693991021390,
            9364262415083554865,
            8903041834452995624,
            321340262873233811,
            0,
            20242765329382950,
            167181252548294929
        ); // rebalance #2
        steps[2] = Step(
            24687671,
            1773876755,
            455692972302981,
            1079654693991021390,
            9364262415083554865,
            8903041834452995624,
            321340262873233811,
            0,
            20242765329382950,
            170192638227862011
        ); // Claimer claim SPC
        steps[3] = Step(
            24687673,
            1773876779,
            455692972302981,
            1079654693991021390,
            9364262415083554865,
            8850077945877066644,
            374304151449162791,
            0,
            20242765329382950,
            170192638227862011
        ); // Claimer claim SPL
        steps[4] = Step(
            24687779,
            1773878063,
            453348203154396,
            1079654693991021390,
            9378509517354262631,
            8864182577125067333,
            374304151449162791,
            0,
            20183617272428115,
            166447421346637119
        ); // rebalance #3
        steps[5] = Step(
            24688804,
            1773890435,
            450940541568587,
            1079654693991021390,
            9457787779369386130,
            8942668056520039598,
            374304151449162791,
            0,
            19873530393504445,
            162557587478438970
        ); // rebalance #4
        steps[6] = Step(
            24688832,
            1773890771,
            448641948991509,
            1079654693991021390,
            9534306388543177905,
            9018421479602093456,
            374304151449162791,
            0,
            19580408351166092,
            158913752513332402
        ); // rebalance #5
        steps[7] = Step(
            24699077,
            1774014095,
            468323881240092,
            1079826826931326495,
            9534306388543177905,
            9018421479602093456,
            374304151449162791,
            0,
            19580408351166092,
            189123801845367388
        ); // Exiter requestWithdrawal SPC
        steps[8] = Step(
            24699086,
            1774014203,
            468323881240092,
            1079826826931326495,
            9534306388543177905,
            9018421479602093456,
            374304151449162791,
            0,
            19580408351166092,
            189123801845367388
        ); // Exiter requestWithdrawal SPL
        steps[9] = Step(
            24699093,
            1774014287,
            468323881240092,
            1079826826931326495,
            9534306388543177905,
            9018421479602093456,
            374304151449162791,
            0,
            19580408351166092,
            189123801845367388
        ); // Exiter claim SPC
        steps[10] = Step(
            24699098,
            1774014347,
            468323881240092,
            1079826826931326495,
            9534306388543177905,
            8790311679740400961,
            374304151449162791,
            228109799861692495,
            19580408351166092,
            189123801845367388
        ); // Exiter claim SPL
        steps[11] = Step(
            24699444,
            1774018499,
            468123570204327,
            1079826826931326495,
            9534306388543177905,
            8790311679740400961,
            374304151449162791,
            228109799861692495,
            19580408351166092,
            188816341876712769
        ); // Exiter withdraw SPC
        steps[12] = Step(
            24699446,
            1774018523,
            468123570204327,
            1079826826931326495,
            9534306388543177905,
            8790311679740400961,
            374304151449162791,
            228109799861692495,
            0,
            188816341876712769
        ); // Exiter withdraw SPL
        steps[13] = Step(
            24699456,
            1774018643,
            468123570204327,
            1079826826931326495,
            9534306388543177905,
            8790311679740400961,
            374304151449162791,
            228109799861692495,
            0,
            188816341876712769
        ); // Exiter redeemPegged
        steps[14] = Step(
            24699497,
            1774019135,
            470511631711623,
            1079826826931326495,
            9306196588681485410,
            8790311679740400961,
            374304151449162791,
            0,
            0,
            192462471843639196
        ); // Exiter redeemLev
    }

    address[] holders;

    // Pre-rebalance per-holder value in haETH: (hsHeld + hsClaimable) * levPrice / 1e18 + haInSPL
    uint256[] preValues;
    uint256 preLevPrice;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK);
        _setSaltPrefix("harbor_v1");

        spm = _predictAddress(_key("ETH", "fxUSD", "stabilityPoolManager"));
        minterAddr = _predictAddress(_key("ETH", "fxUSD", "minter"));
        spl = _predictAddress(_key("ETH", "fxUSD", "stabilityPoolLeveraged"));
        spc = _predictAddress(_key("ETH", "fxUSD", "stabilityPoolCollateral"));
        lev = _predictAddress(_key("ETH", "fxUSD", "leveraged"));
        peg = _predictAddress(_key("ETH", "pegged"));
        proxyOwner = IBaoOwnable(minterAddr).owner();
        realOracle = IMinter(minterAddr).priceOracle();

        // Validate hardcoded oracle against live fork
        (uint256 liveP, , uint256 liveR, ) = IWrappedPriceOracle(realOracle).latestAnswer();
        assertEq(liveP, 456157348740503, "oracle price mismatch at fork block");
        assertEq(liveR, 1079654693991021390, "oracle rate mismatch at fork block");

        // Deploy mock oracle, install on minter
        mockOracle = new MockWrappedPriceOracle();
        mockOracle.setLatestAnswer(liveP, liveR);
        vm.prank(proxyOwner);
        IMinter(minterAddr).updatePriceOracle(address(mockOracle));

        _initSteps();
        _initHolders();

        // Capture pre-rebalance value for each holder
        preLevPrice = IMinter(minterAddr).leveragedTokenPrice();
        for (uint256 i = 0; i < holders.length; i++) {
            preValues.push(_holderValue(holders[i], preLevPrice));
        }
    }

    // fxSAVE received by Exiter from redeem calls (accumulated during replay)
    uint256 exiterFxSaveReceived;

    /// @dev Value in haETH: (hsHeld + hsClaimable) * levPrice / 1e18 + haInSPL
    /// For the Exiter, also includes fxSAVE received from redeems * oraclePrice.
    function _holderValue(address h, uint256 levPrice) private view returns (uint256) {
        uint256 totalHs = IERC20(lev).balanceOf(h) + IMultipleRewardAccumulator(spl).claimable(h, lev);
        uint256 haInSpl = IStabilityPool(spl).assetBalanceOf(h);
        uint256 value = (totalHs * levPrice) / 1 ether + haInSpl;
        if (h == EXITER && exiterFxSaveReceived > 0) {
            (uint256 oraclePrice, , , ) = mockOracle.latestAnswer();
            value += (exiterFxSaveReceived * oraclePrice) / 1 ether;
        }
        return value;
    }

    // ---- Helpers ----

    function _advanceTo(uint256 i) private {
        vm.roll(steps[i].blockNum);
        vm.warp(steps[i].timestamp);
        mockOracle.setLatestAnswer(steps[i].oraclePrice, steps[i].oracleRate);
    }

    /// @dev Assert v1 state matches mainnet after step i. Only checks for v1 replay.
    bool private _v1Mode;

    function _check(uint256 i) private view {
        if (!_v1Mode) {
            console.log("  step %d: levPrice=%e", i, IMinter(minterAddr).leveragedTokenPrice());
            return;
        }
        Step memory s = steps[i];
        string memory step = vm.toString(i);
        assertEq(IERC20(lev).totalSupply(), s.supply, string.concat("supply @ step ", step));
        assertEq(IERC20(lev).balanceOf(spl), s.splLevBal, string.concat("splLevBal @ step ", step));
        assertEq(IERC20(lev).balanceOf(CLAIMER), s.claimerLevBal, string.concat("claimerLev @ step ", step));
        assertEq(IERC20(lev).balanceOf(EXITER), s.exiterLevBal, string.concat("exiterLev @ step ", step));
        assertEq(IStabilityPool(spl).assetBalanceOf(EXITER), s.exiterDep, string.concat("exiterDep @ step ", step));
        assertEq(IMinter(minterAddr).leveragedTokenPrice(), s.levPrice, string.concat("levPrice @ step ", step));
    }

    function _upgradeMinterV2() private {
        IMinter m = IMinter(minterAddr);
        vm.startPrank(proxyOwner);
        Minter_v2(minterAddr).upgradeToAndCall(
            address(
                new Minter_v2(m.WRAPPED_COLLATERAL_TOKEN(), m.PEGGED_TOKEN(), m.LEVERAGED_TOKEN(), "burn(uint256)")
            ),
            ""
        );
        StabilityPoolManager_v1 mgr = StabilityPoolManager_v1(spm);
        mgr.upgradeToAndCall(address(new StabilityPoolManager_v1(minterAddr, mgr.TREASURY(), spc, spl)), "");
        vm.stopPrank();
    }

    // ---- Replay: inline sequential actions ----

    function _replayTimeline() private {
        // Step 0: Rebalance #1
        _advanceTo(0);
        StabilityPoolManager_v1(spm).rebalance(makeAddr("bounty"), 0);
        _check(0);

        // Step 1: Rebalance #2
        _advanceTo(1);
        try StabilityPoolManager_v1(spm).rebalance(makeAddr("bounty"), 0) {} catch {}
        _check(1);

        // Step 2: Claimer claim SPC (fxSAVE only)
        _advanceTo(2);
        vm.prank(CLAIMER);
        IMultipleRewardAccumulator(spc).claim();
        _check(2);

        // Step 3: Claimer claim SPL (sailETH to wallet)
        _advanceTo(3);
        vm.prank(CLAIMER);
        IMultipleRewardAccumulator(spl).claim();
        _check(3);

        // Step 4: Rebalance #3
        _advanceTo(4);
        try StabilityPoolManager_v1(spm).rebalance(makeAddr("bounty"), 0) {} catch {}
        _check(4);

        // Step 5: Rebalance #4
        _advanceTo(5);
        try StabilityPoolManager_v1(spm).rebalance(makeAddr("bounty"), 0) {} catch {}
        _check(5);

        // Step 6: Rebalance #5
        _advanceTo(6);
        try StabilityPoolManager_v1(spm).rebalance(makeAddr("bounty"), 0) {} catch {}
        _check(6);

        // Step 7: Exiter requestWithdrawal on SPC
        _advanceTo(7);
        if (IStabilityPool(spc).assetBalanceOf(EXITER) > 0) {
            vm.prank(EXITER);
            IStabilityPool(spc).requestWithdrawal();
        }
        _check(7);

        // Step 8: Exiter requestWithdrawal on SPL
        _advanceTo(8);
        if (IStabilityPool(spl).assetBalanceOf(EXITER) > 0) {
            vm.prank(EXITER);
            IStabilityPool(spl).requestWithdrawal();
        }
        _check(8);

        // Step 9: Exiter claim SPC (fxSAVE rewards)
        _advanceTo(9);
        vm.prank(EXITER);
        IMultipleRewardAccumulator(spc).claim();
        _check(9);

        // Step 10: Exiter claim SPL (sailETH rewards to wallet)
        _advanceTo(10);
        vm.prank(EXITER);
        IMultipleRewardAccumulator(spl).claim();
        _check(10);

        // Step 11: Exiter withdraw from SPC (haETH to wallet)
        _advanceTo(11);
        vm.prank(EXITER);
        try IStabilityPool(spc).withdraw(type(uint256).max, EXITER, 0) {} catch {}
        _check(11);

        // Step 12: Exiter withdraw from SPL (haETH to wallet)
        _advanceTo(12);
        vm.prank(EXITER);
        try IStabilityPool(spl).withdraw(type(uint256).max, EXITER, 0) {} catch {}
        _check(12);

        // Step 13: Exiter redeemPeggedToken (redeems ALL haETH)
        _advanceTo(13);
        uint256 exiterPegBal = IERC20(peg).balanceOf(EXITER);
        if (exiterPegBal > 0) {
            vm.startPrank(EXITER);
            IERC20(peg).approve(minterAddr, exiterPegBal);
            uint256 fxSaveFromPeg = IMinter(minterAddr).redeemPeggedToken(exiterPegBal, EXITER, 0);
            vm.stopPrank();
            exiterFxSaveReceived += fxSaveFromPeg;
        }
        _check(13);

        // Step 14: Exiter redeemLeveragedToken
        _advanceTo(14);
        uint256 exiterLevBal = IERC20(lev).balanceOf(EXITER);
        if (exiterLevBal > 0) {
            vm.startPrank(EXITER);
            IERC20(lev).approve(minterAddr, exiterLevBal);
            uint256 fxSaveFromLev = IMinter(minterAddr).redeemLeveragedToken(exiterLevBal, EXITER, 0);
            vm.stopPrank();
            exiterFxSaveReceived += fxSaveFromLev;
        }
        _check(14);
    }

    // ---- CSV output ----

    // ETH/USD at the end of the event window (block 24699497)
    // 1 haETH ~= 1 ETH; oracle price 470e12 means 1 fxSAVE = 470e-6 haETH
    // so 1 haETH = 1/470e-6 fxSAVE = ~2128 fxUSD ~= $2128
    // More precisely: ETH/USD = 1e18 / oraclePrice_at_last_step = 1e18 / 470511631711623
    uint256 constant ETH_USD = 2125; // approximate, for display only

    function _captureCSV(string memory filename) private {
        uint256 postLevPrice = IMinter(minterAddr).leveragedTokenPrice();

        string memory csv = "Address,$ Before,$ After,$ Change,hs Held,hs Claimable,hs Claimed,ha in SPL\n";

        for (uint256 i = 0; i < holders.length; i++) {
            address h = holders[i];
            if (h == spl || h == spc) continue;

            uint256 postValue = _holderValue(h, postLevPrice);
            uint256 preValue = preValues[i];

            uint256 levBal = IERC20(lev).balanceOf(h);
            uint256 claimable = IMultipleRewardAccumulator(spl).claimable(h, lev);
            uint256 claimed = IMultipleRewardAccumulator(spl).claimed(h, lev);
            uint256 splDep = IStabilityPool(spl).assetBalanceOf(h);

            if (preValue == 0 && postValue == 0) continue;

            int256 change = int256(postValue) - int256(preValue);

            csv = string.concat(
                csv,
                vm.toString(h),
                ",",
                _usd(preValue),
                ",",
                _usd(postValue),
                ",",
                _signedUsd(change),
                ","
            );
            csv = string.concat(
                csv,
                vm.toString(levBal),
                ",",
                vm.toString(claimable),
                ",",
                vm.toString(claimed),
                ",",
                vm.toString(splDep),
                "\n"
            );
        }

        csv = string.concat(csv, "\nSystem\n");
        csv = string.concat(csv, "leveragedTokenPrice before,", vm.toString(preLevPrice), "\n");
        csv = string.concat(csv, "leveragedTokenPrice after,", vm.toString(postLevPrice), "\n");
        csv = string.concat(csv, "leveragedTotalSupply,", vm.toString(IERC20(lev).totalSupply()), "\n");
        csv = string.concat(csv, "peggedTokenBalance,", vm.toString(IMinter(minterAddr).peggedTokenBalance()), "\n");
        csv = string.concat(
            csv,
            "collateralTokenBalance,",
            vm.toString(IMinter(minterAddr).collateralTokenBalance()),
            "\n"
        );
        csv = string.concat(csv, "SPL levBalance,", vm.toString(IERC20(lev).balanceOf(spl)), "\n");

        vm.createDir("results", true);
        vm.writeFile(string.concat("results/", filename), csv);
        console.log("  -> results/%s", filename);
    }

    /// @dev Format as scientific notation: "1.234e18"
    function _sci(uint256 v) private pure returns (string memory) {
        if (v == 0) return "0";
        uint256 exp;
        uint256 tmp = v;
        while (tmp >= 10) {
            tmp /= 10;
            exp++;
        }
        // Get 4 significant digits
        uint256 divisor = 1;
        if (exp >= 3) {
            for (uint256 i = 0; i < exp - 3; i++) divisor *= 10;
        }
        uint256 sig = v / divisor;
        uint256 whole = sig / 1000;
        uint256 frac = sig % 1000;
        string memory fracStr = vm.toString(frac);
        while (bytes(fracStr).length < 3) fracStr = string.concat("0", fracStr);
        return string.concat(vm.toString(whole), ".", fracStr, "e", vm.toString(exp));
    }

    function _signedSci(int256 v) private pure returns (string memory) {
        if (v >= 0) return _sci(uint256(v));
        return string.concat("-", _sci(uint256(-v)));
    }

    /// @dev Convert haETH wei to approximate USD string: "$1234.56"
    function _usd(uint256 haEthWei) private pure returns (string memory) {
        uint256 cents = (haEthWei * ETH_USD) / 1e16;
        uint256 whole = cents / 100;
        uint256 frac = cents % 100;
        string memory fracStr = vm.toString(frac);
        if (bytes(fracStr).length < 2) fracStr = string.concat("0", fracStr);
        return string.concat("$", vm.toString(whole), ".", fracStr);
    }

    function _signedUsd(int256 v) private pure returns (string memory) {
        if (v >= 0) return string.concat("+", _usd(uint256(v)));
        return string.concat("-", _usd(uint256(-v)));
    }

    // ---- Tests ----

    function test_v1Replay() public {
        console.log("=== V1 REPLAY (validation) ===");
        _v1Mode = true;
        _replayTimeline();
        _captureCSV("v1_replay.csv");
        console.log("  [OK] All 15 steps match mainnet exactly");
    }

    function test_v2Replay() public {
        console.log("=== V2 REPLAY (correct world) ===");
        console.log("  pre-rebalance levPrice: %e", IMinter(minterAddr).leveragedTokenPrice());
        _upgradeMinterV2();
        _replayTimeline();

        console.log("  final levPrice:  %e", IMinter(minterAddr).leveragedTokenPrice());
        console.log("  final levSupply: %e", IERC20(lev).totalSupply());

        _captureCSV("v2_correct_state.csv");
    }

    // ---- Holder list ----

    function _initHolders() private {
        holders.push(0x08453DdD21Cae8f430a07eB8c82e0520882e82c1);
        holders.push(0x13F210c8bAf5f5DBAFf3E917E2e5A49E73BBAF12);
        holders.push(0x1a9152528AEFbcD9E5df4E0770f4F510e7056913);
        holders.push(0x1e085ff3CdD38b1E5F04Ace2345966056F0C85E4);
        holders.push(0x1F985CF7C10A81DE1940da581208D2855D263D72);
        holders.push(0x31632636D664895f1BD9D03f5F7c162A2A6980EB);
        holders.push(0x3dFc49e5112005179Da613BdE5973229082dAc35);
        holders.push(0x3Fdaf8A9af23D27C884e10820130eAB1dB6dDBeD);
        holders.push(0x4382916A88b6EEd40530ef47deD0D402563dDACa);
        holders.push(0x438B29EC7a1770dDbA37D792F1A6e76231Ef8E06);
        holders.push(0x4dAf8ce9D729ca4F121381ec4B22123627C1C004);
        holders.push(0x50b3Bf1B3119afc37A25c841c06C1BDD05Da1Fab);
        holders.push(0x6453E9D859fE2578DfC4aa8D3ec7B3a80574C00f);
        holders.push(0x742fC5146d7Ff18291E3B7499811AD87015Fc7E4);
        holders.push(0x754Ba099408892F500e3675b9816ea1B0dc33CBb);
        holders.push(0x7F14A89F5333A334C0EA3B5AAA7Dc2c8E1C72de6);
        holders.push(0x81253f3Fc43D5e399610beE4D7a235826A7663b8);
        holders.push(0x8335459a89A17Ed8ed128aa98F9AF86802DACF30);
        holders.push(0x8AcF2f327e47FdDD1124a55eb4eFC1DfdAcAA34c);
        holders.push(0x8b7698945dBCedF33F5e8d9E62B1Af8101318575);
        holders.push(0x97C79691407Aea845FaA24C8A905bC3151034ADD);
        holders.push(0x98e917437041f213472C02835cdDC39356086618);
        holders.push(0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2);
        holders.push(0x9db1D99D1C79A3A2C0123fcd0abB13d9B7c75657);
        holders.push(0x9Dd897df19FfC27d6685E98Accc394f88a73e475);
        holders.push(0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e);
        holders.push(0xb2810d84dE0A80d0560D8C1FCF1c0589F850592c);
        holders.push(0xb9ab9578a34a05c86124c399735fdE44dEc80E7F);
        holders.push(0xbA26035B9CD76cdA5b767A966b8A3392E476Fc0F);
        holders.push(0xc16A44D0759ec03c677E97eF020a2345d4dC27Fb);
        holders.push(0xC9df4f62474Cf6cdE6c064DB29416a9F4f27EBdC);
        holders.push(0xcadF9F065e96516483afF69fBd8D0b81201199d9);
        holders.push(0xD1AE4d9205F07333916f628850Fc79f1366dC2F8);
        holders.push(0xd6E2F8e57b4aFB51C6fA4cbC012e1cE6aEad989F);
        holders.push(0xDC1330EF8dc913C39bd29F9523418eEEacEf03D6);
        holders.push(0xDD0CDF8D98d9Ad3ADfaa49AaECD444Bfa01d9C9a);
        holders.push(0xdd9c0BB1102D45357bEC81BbdffBb615D64C0ff9);
        holders.push(0xE60849FA39c4D4Ebef88C95cB27583bA2ea26E78);
        holders.push(0xeebF37253066532AFeB3FACB4f2C411703353a83);
        holders.push(0xef5E7606769400DC667DDC520C911D84405e61b7);
        holders.push(0xF7e64540f42094497E2De0F06232992b03942898);
        holders.push(0xf7e9CAaaEEb6cC9657E1Dd490F044114AecC31B2);
    }
}
