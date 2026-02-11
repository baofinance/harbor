// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IMultipleRewardDistributor} from "src/interfaces/IMultipleRewardDistributor.sol";
import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {LibString} from "@solady/utils/LibString.sol";

/// @title Mainnet Fork Upgrade Verification Test
/// @notice Captures all view function results and interaction outcomes for every deployed
/// StabilityPool, writing them to JSON files. Run twice (v1 before upgrade, v2 after)
/// and diff the output files to verify the upgrade preserves all state and behavior.
/// @dev NOT part of CI -- run manually via the workflow in script/test/README.md
///
/// Produces two files per run:
///   tmp/{version}_pre.json  -- state snapshot before any interactions
///   tmp/{version}_post.json -- interaction results + state snapshot after interactions
contract MainnetForkUpgradeTest is Test {
    using LibString for string;

    struct PoolConfig {
        address proxy;
        address minter;
        string label;
    }

    /// @dev Mutable JSON object key -- switched between "pre" and "post" phases
    string private _jsonKey;

    PoolConfig[] pools;
    // proxy => known depositors (discovered via cast logs, hardcoded below)
    mapping(address => address[]) poolDepositors;

    address testUser;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("local"));

        testUser = makeAddr("testUser");

        // ---- Register all 22 pools (proxy, minter, label) ----
        // BTC::fxUSD
        pools.push(
            PoolConfig(
                0x86561cdB34ebe8B9abAbb0DD7bEA299fA8532a49,
                0x33e32ff4d0677862fa31582CC654a25b9b1e4888,
                "BTC_fxUSD_col"
            )
        );
        pools.push(
            PoolConfig(
                0x9e56F1E1E80EBf165A1dAa99F9787B41cD5bFE40,
                0x33e32ff4d0677862fa31582CC654a25b9b1e4888,
                "BTC_fxUSD_lev"
            )
        );
        // BTC::stETH
        pools.push(
            PoolConfig(
                0x667Ceb303193996697A5938cD6e17255EeAcef51,
                0xF42516EB885E737780EB864dd07cEc8628000919,
                "BTC_stETH_col"
            )
        );
        pools.push(
            PoolConfig(
                0xCB4F3e21DE158bf858Aa03E63e4cEc7342177013,
                0xF42516EB885E737780EB864dd07cEc8628000919,
                "BTC_stETH_lev"
            )
        );
        // ETH::fxUSD
        pools.push(
            PoolConfig(
                0x1F985CF7C10A81DE1940da581208D2855D263D72,
                0xd6E2F8e57b4aFB51C6fA4cbC012e1cE6aEad989F,
                "ETH_fxUSD_col"
            )
        );
        pools.push(
            PoolConfig(
                0x438B29EC7a1770dDbA37D792F1A6e76231Ef8E06,
                0xd6E2F8e57b4aFB51C6fA4cbC012e1cE6aEad989F,
                "ETH_fxUSD_lev"
            )
        );
        // EUR::fxUSD
        pools.push(
            PoolConfig(
                0xe60054E6b518f67411834282cE1557381f050B13,
                0xDEFB2C04062350678965CBF38A216Cc50723B246,
                "EUR_fxUSD_col"
            )
        );
        pools.push(
            PoolConfig(
                0xc5e0dA7e0a178850438E5E97ed59b6eb2562e88E,
                0xDEFB2C04062350678965CBF38A216Cc50723B246,
                "EUR_fxUSD_lev"
            )
        );
        // EUR::stETH
        pools.push(
            PoolConfig(
                0x000564B33FFde65E6c3b718166856654e039D69B,
                0x68911ea33E11bc77e07f6dA4db6cd23d723641cE,
                "EUR_stETH_col"
            )
        );
        pools.push(
            PoolConfig(
                0x7553fb328ef35aF1c2ac4E91e53d6a6B62DFDdEa,
                0x68911ea33E11bc77e07f6dA4db6cd23d723641cE,
                "EUR_stETH_lev"
            )
        );
        // GOLD::fxUSD
        pools.push(
            PoolConfig(
                0xC1EF32d4B959F2200efDeDdedadA226461d14DaC,
                0x880600E0c803d836E305B7c242FC095Eed234A8f,
                "GOLD_fxUSD_col"
            )
        );
        pools.push(
            PoolConfig(
                0x5bDED171f1c08B903b466593B0E022F9FdE8399c,
                0x880600E0c803d836E305B7c242FC095Eed234A8f,
                "GOLD_fxUSD_lev"
            )
        );
        // GOLD::stETH
        pools.push(
            PoolConfig(
                0x215C28DcCe0041eF9a17277CA271F100d9F345CF,
                0xB315DC4698DF45A477d8bb4B0Bc694C4D1Be91b5,
                "GOLD_stETH_col"
            )
        );
        pools.push(
            PoolConfig(
                0x2af96e906D568c92E53e96bB2878ce35E05dE69a,
                0xB315DC4698DF45A477d8bb4B0Bc694C4D1Be91b5,
                "GOLD_stETH_lev"
            )
        );
        // MCAP::fxUSD
        pools.push(
            PoolConfig(
                0x7928a145Eed1374f5594c799290419B80fCd03f0,
                0x3d3EAe3a4Ee52ef703216c62EFEC3157694606dE,
                "MCAP_fxUSD_col"
            )
        );
        pools.push(
            PoolConfig(
                0x8CF0C5F1394E137389D6dbfE91c56D00dEcdDAD8,
                0x3d3EAe3a4Ee52ef703216c62EFEC3157694606dE,
                "MCAP_fxUSD_lev"
            )
        );
        // MCAP::stETH
        pools.push(
            PoolConfig(
                0x4cFf4948A0EA73Ee109327b56da0bead8c323189,
                0xe37e34Ab0AaaabAc0e20c911349c1dEfAD0691B6,
                "MCAP_stETH_col"
            )
        );
        pools.push(
            PoolConfig(
                0x505bfC99D2FB1A1424b2A4AA81303346df4f27E9,
                0xe37e34Ab0AaaabAc0e20c911349c1dEfAD0691B6,
                "MCAP_stETH_lev"
            )
        );
        // SILVER::fxUSD
        pools.push(
            PoolConfig(
                0x7619664fe05c9cbDA5B622455856D7CA11Cb8800,
                0x177bb50574CDA129BDd0B0F50d4E061d38AA75Ef,
                "SILVER_fxUSD_col"
            )
        );
        pools.push(
            PoolConfig(
                0x24AEf2d27146497B18df180791424b1010bf1889,
                0x177bb50574CDA129BDd0B0F50d4E061d38AA75Ef,
                "SILVER_fxUSD_lev"
            )
        );
        // SILVER::stETH
        pools.push(
            PoolConfig(
                0x1C9c1cF9aa9fc86dF980086CbC5a5607522cFc3E,
                0x1c0067BEe039A293804b8BE951B368D2Ec65b3e9,
                "SILVER_stETH_col"
            )
        );
        pools.push(
            PoolConfig(
                0x4C0F988b3c0C58F5ea323238E9d62B79582738e6,
                0x1c0067BEe039A293804b8BE951B368D2Ec65b3e9,
                "SILVER_stETH_lev"
            )
        );

        // ---- Known depositors (discovered via cast logs --from-block 24049405) ----
        // BTC::fxUSD collateral pool
        poolDepositors[0x86561cdB34ebe8B9abAbb0DD7bEA299fA8532a49].push(0x061B84FDe0aa74ecbF8eCDB0481576feE9Ae35aa);
        poolDepositors[0x86561cdB34ebe8B9abAbb0DD7bEA299fA8532a49].push(0x1a9152528AEFbcD9E5df4E0770f4F510e7056913);
        poolDepositors[0x86561cdB34ebe8B9abAbb0DD7bEA299fA8532a49].push(0x9Dd897df19FfC27d6685E98Accc394f88a73e475);
        poolDepositors[0x86561cdB34ebe8B9abAbb0DD7bEA299fA8532a49].push(0xaa17879e7cac3AEE12D6aa568691e638EF0C57f0);
        poolDepositors[0x86561cdB34ebe8B9abAbb0DD7bEA299fA8532a49].push(0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e);
        poolDepositors[0x86561cdB34ebe8B9abAbb0DD7bEA299fA8532a49].push(0xb9ab9578a34a05c86124c399735fdE44dEc80E7F);
        poolDepositors[0x86561cdB34ebe8B9abAbb0DD7bEA299fA8532a49].push(0xbA26035B9CD76cdA5b767A966b8A3392E476Fc0F);
        poolDepositors[0x86561cdB34ebe8B9abAbb0DD7bEA299fA8532a49].push(0xDD4dAd7E9FD518e271bEA1d820B95E3215D735D5);
        // BTC::fxUSD leveraged pool
        poolDepositors[0x9e56F1E1E80EBf165A1dAa99F9787B41cD5bFE40].push(0x2880a6bb2cD1DF6E03dC8BbFBEd009DE586c2603);
        poolDepositors[0x9e56F1E1E80EBf165A1dAa99F9787B41cD5bFE40].push(0x5dE79E0C5632056B9FB19a740cE0f3EF03adEEB3);
        poolDepositors[0x9e56F1E1E80EBf165A1dAa99F9787B41cD5bFE40].push(0x742fC5146d7Ff18291E3B7499811AD87015Fc7E4);
        poolDepositors[0x9e56F1E1E80EBf165A1dAa99F9787B41cD5bFE40].push(0x754Ba099408892F500e3675b9816ea1B0dc33CBb);
        poolDepositors[0x9e56F1E1E80EBf165A1dAa99F9787B41cD5bFE40].push(0x9Dd897df19FfC27d6685E98Accc394f88a73e475);
        poolDepositors[0x9e56F1E1E80EBf165A1dAa99F9787B41cD5bFE40].push(0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e);
        poolDepositors[0x9e56F1E1E80EBf165A1dAa99F9787B41cD5bFE40].push(0xb9ab9578a34a05c86124c399735fdE44dEc80E7F);
        poolDepositors[0x9e56F1E1E80EBf165A1dAa99F9787B41cD5bFE40].push(0xbA26035B9CD76cdA5b767A966b8A3392E476Fc0F);
        poolDepositors[0x9e56F1E1E80EBf165A1dAa99F9787B41cD5bFE40].push(0xDD4dAd7E9FD518e271bEA1d820B95E3215D735D5);
        // BTC::stETH collateral pool
        poolDepositors[0x667Ceb303193996697A5938cD6e17255EeAcef51].push(0x2880a6bb2cD1DF6E03dC8BbFBEd009DE586c2603);
        poolDepositors[0x667Ceb303193996697A5938cD6e17255EeAcef51].push(0x619e71ec0d528520961571Dcea6f13f8B63410E3);
        poolDepositors[0x667Ceb303193996697A5938cD6e17255EeAcef51].push(0x742fC5146d7Ff18291E3B7499811AD87015Fc7E4);
        poolDepositors[0x667Ceb303193996697A5938cD6e17255EeAcef51].push(0x8b7698945dBCedF33F5e8d9E62B1Af8101318575);
        poolDepositors[0x667Ceb303193996697A5938cD6e17255EeAcef51].push(0xA01Ad5f0b5C521266d1dd3f926dA92f2CD9661e2);
        poolDepositors[0x667Ceb303193996697A5938cD6e17255EeAcef51].push(0xA0DD64775018b624978cCf55fE11c50dA621534E);
        poolDepositors[0x667Ceb303193996697A5938cD6e17255EeAcef51].push(0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e);
        poolDepositors[0x667Ceb303193996697A5938cD6e17255EeAcef51].push(0xbA26035B9CD76cdA5b767A966b8A3392E476Fc0F);
        poolDepositors[0x667Ceb303193996697A5938cD6e17255EeAcef51].push(0xD1AE4d9205F07333916f628850Fc79f1366dC2F8);
        poolDepositors[0x667Ceb303193996697A5938cD6e17255EeAcef51].push(0xE81003515B5c537Cd4EE57A41dbEcF01FF429135);
        poolDepositors[0x667Ceb303193996697A5938cD6e17255EeAcef51].push(0xecfFe7b0E11935CdB4f2107ff22140b67d36dCED);
        poolDepositors[0x667Ceb303193996697A5938cD6e17255EeAcef51].push(0xEE517179cef2e52aF9D52667C7C9a43a5093F775);
        // BTC::stETH leveraged pool
        poolDepositors[0xCB4F3e21DE158bf858Aa03E63e4cEc7342177013].push(0x2f75E925C38f83785A7D0630f65Aed8C65C1454f);
        poolDepositors[0xCB4F3e21DE158bf858Aa03E63e4cEc7342177013].push(0x619e71ec0d528520961571Dcea6f13f8B63410E3);
        poolDepositors[0xCB4F3e21DE158bf858Aa03E63e4cEc7342177013].push(0x7e4f98217A085F1a06332EDff805513b6Ea79357);
        poolDepositors[0xCB4F3e21DE158bf858Aa03E63e4cEc7342177013].push(0x803ecCE255901F352FAf339fc8a5C87Adf0083B7);
        poolDepositors[0xCB4F3e21DE158bf858Aa03E63e4cEc7342177013].push(0x9Af8FBF66Bf3645f505D58614D7a13D411b99907);
        poolDepositors[0xCB4F3e21DE158bf858Aa03E63e4cEc7342177013].push(0x9Dd897df19FfC27d6685E98Accc394f88a73e475);
        poolDepositors[0xCB4F3e21DE158bf858Aa03E63e4cEc7342177013].push(0xA01Ad5f0b5C521266d1dd3f926dA92f2CD9661e2);
        poolDepositors[0xCB4F3e21DE158bf858Aa03E63e4cEc7342177013].push(0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e);
        poolDepositors[0xCB4F3e21DE158bf858Aa03E63e4cEc7342177013].push(0xb9ab9578a34a05c86124c399735fdE44dEc80E7F);
        poolDepositors[0xCB4F3e21DE158bf858Aa03E63e4cEc7342177013].push(0xbA26035B9CD76cdA5b767A966b8A3392E476Fc0F);
        poolDepositors[0xCB4F3e21DE158bf858Aa03E63e4cEc7342177013].push(0xD1AE4d9205F07333916f628850Fc79f1366dC2F8);
        poolDepositors[0xCB4F3e21DE158bf858Aa03E63e4cEc7342177013].push(0xDc9CDd31BC0F598e6B2c8302312B40852F636E60);
        // ETH::fxUSD collateral pool
        poolDepositors[0x1F985CF7C10A81DE1940da581208D2855D263D72].push(0x1a9152528AEFbcD9E5df4E0770f4F510e7056913);
        poolDepositors[0x1F985CF7C10A81DE1940da581208D2855D263D72].push(0x31632636D664895f1BD9D03f5F7c162A2A6980EB);
        poolDepositors[0x1F985CF7C10A81DE1940da581208D2855D263D72].push(0x3dFc49e5112005179Da613BdE5973229082dAc35);
        poolDepositors[0x1F985CF7C10A81DE1940da581208D2855D263D72].push(0x4dAf8ce9D729ca4F121381ec4B22123627C1C004);
        poolDepositors[0x1F985CF7C10A81DE1940da581208D2855D263D72].push(0x50b3Bf1B3119afc37A25c841c06C1BDD05Da1Fab);
        poolDepositors[0x1F985CF7C10A81DE1940da581208D2855D263D72].push(0x742fC5146d7Ff18291E3B7499811AD87015Fc7E4);
        poolDepositors[0x1F985CF7C10A81DE1940da581208D2855D263D72].push(0x7F14A89F5333A334C0EA3B5AAA7Dc2c8E1C72de6);
        poolDepositors[0x1F985CF7C10A81DE1940da581208D2855D263D72].push(0x81253f3Fc43D5e399610beE4D7a235826A7663b8);
        poolDepositors[0x1F985CF7C10A81DE1940da581208D2855D263D72].push(0x8b7698945dBCedF33F5e8d9E62B1Af8101318575);
        poolDepositors[0x1F985CF7C10A81DE1940da581208D2855D263D72].push(0x9db1D99D1C79A3A2C0123fcd0abB13d9B7c75657);
        poolDepositors[0x1F985CF7C10A81DE1940da581208D2855D263D72].push(0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e);
        poolDepositors[0x1F985CF7C10A81DE1940da581208D2855D263D72].push(0xb9ab9578a34a05c86124c399735fdE44dEc80E7F);
        poolDepositors[0x1F985CF7C10A81DE1940da581208D2855D263D72].push(0xbA26035B9CD76cdA5b767A966b8A3392E476Fc0F);
        poolDepositors[0x1F985CF7C10A81DE1940da581208D2855D263D72].push(0xc16A44D0759ec03c677E97eF020a2345d4dC27Fb);
        poolDepositors[0x1F985CF7C10A81DE1940da581208D2855D263D72].push(0xDC1330EF8dc913C39bd29F9523418eEEacEf03D6);
        poolDepositors[0x1F985CF7C10A81DE1940da581208D2855D263D72].push(0xdd9c0BB1102D45357bEC81BbdffBb615D64C0ff9);
        poolDepositors[0x1F985CF7C10A81DE1940da581208D2855D263D72].push(0xef5E7606769400DC667DDC520C911D84405e61b7);
        poolDepositors[0x1F985CF7C10A81DE1940da581208D2855D263D72].push(0xF7e64540f42094497E2De0F06232992b03942898);
        poolDepositors[0x1F985CF7C10A81DE1940da581208D2855D263D72].push(0xF7E9CaAaeeB6CC9595C7b415289D59cF203F23A9);
        // ETH::fxUSD leveraged pool
        poolDepositors[0x438B29EC7a1770dDbA37D792F1A6e76231Ef8E06].push(0x08453DdD21Cae8f430a07eB8c82e0520882e82c1);
        poolDepositors[0x438B29EC7a1770dDbA37D792F1A6e76231Ef8E06].push(0x1a9152528AEFbcD9E5df4E0770f4F510e7056913);
        poolDepositors[0x438B29EC7a1770dDbA37D792F1A6e76231Ef8E06].push(0x1e085ff3CdD38b1E5F04Ace2345966056F0C85E4);
        poolDepositors[0x438B29EC7a1770dDbA37D792F1A6e76231Ef8E06].push(0x31632636D664895f1BD9D03f5F7c162A2A6980EB);
        poolDepositors[0x438B29EC7a1770dDbA37D792F1A6e76231Ef8E06].push(0x3dFc49e5112005179Da613BdE5973229082dAc35);
        poolDepositors[0x438B29EC7a1770dDbA37D792F1A6e76231Ef8E06].push(0x6453E9D859fE2578DfC4aa8D3ec7B3a80574C00f);
        poolDepositors[0x438B29EC7a1770dDbA37D792F1A6e76231Ef8E06].push(0x754Ba099408892F500e3675b9816ea1B0dc33CBb);
        poolDepositors[0x438B29EC7a1770dDbA37D792F1A6e76231Ef8E06].push(0x8335459a89A17Ed8ed128aa98F9AF86802DACF30);
        poolDepositors[0x438B29EC7a1770dDbA37D792F1A6e76231Ef8E06].push(0x97C79691407Aea845FaA24C8A905bC3151034ADD);
        poolDepositors[0x438B29EC7a1770dDbA37D792F1A6e76231Ef8E06].push(0x9Dd897df19FfC27d6685E98Accc394f88a73e475);
        poolDepositors[0x438B29EC7a1770dDbA37D792F1A6e76231Ef8E06].push(0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e);
        poolDepositors[0x438B29EC7a1770dDbA37D792F1A6e76231Ef8E06].push(0xb9ab9578a34a05c86124c399735fdE44dEc80E7F);
        poolDepositors[0x438B29EC7a1770dDbA37D792F1A6e76231Ef8E06].push(0xbA26035B9CD76cdA5b767A966b8A3392E476Fc0F);
        // EUR::fxUSD collateral pool
        poolDepositors[0xe60054E6b518f67411834282cE1557381f050B13].push(0x1a9152528AEFbcD9E5df4E0770f4F510e7056913);
        poolDepositors[0xe60054E6b518f67411834282cE1557381f050B13].push(0x31bd3B75672bAfbBa1b2F27789DCBF6ee7429D74);
        poolDepositors[0xe60054E6b518f67411834282cE1557381f050B13].push(0x8335459a89A17Ed8ed128aa98F9AF86802DACF30);
        // EUR::fxUSD leveraged pool
        poolDepositors[0xc5e0dA7e0a178850438E5E97ed59b6eb2562e88E].push(0x1a9152528AEFbcD9E5df4E0770f4F510e7056913);
        poolDepositors[0xc5e0dA7e0a178850438E5E97ed59b6eb2562e88E].push(0xb9ab9578a34a05c86124c399735fdE44dEc80E7F);
        // EUR::stETH collateral pool
        poolDepositors[0x000564B33FFde65E6c3b718166856654e039D69B].push(0x619e71ec0d528520961571Dcea6f13f8B63410E3);
        poolDepositors[0x000564B33FFde65E6c3b718166856654e039D69B].push(0xbA26035B9CD76cdA5b767A966b8A3392E476Fc0F);
        poolDepositors[0x000564B33FFde65E6c3b718166856654e039D69B].push(0xD1AE4d9205F07333916f628850Fc79f1366dC2F8);
        // EUR::stETH leveraged pool
        poolDepositors[0x7553fb328ef35aF1c2ac4E91e53d6a6B62DFDdEa].push(0x619e71ec0d528520961571Dcea6f13f8B63410E3);
        poolDepositors[0x7553fb328ef35aF1c2ac4E91e53d6a6B62DFDdEa].push(0xbA26035B9CD76cdA5b767A966b8A3392E476Fc0F);
        // GOLD, MCAP, SILVER pools: no depositors found
    }

    // ========================================================================
    // HELPERS (called many times across pools/phases)
    // ========================================================================

    /// @dev Serialize a uint256 as both decimal and 32-byte hex (full bit pattern).
    function _serializeUint(string memory key, uint256 value) internal {
        vm.serializeString(_jsonKey, key, vm.toString(value));
        vm.serializeString(_jsonKey, string.concat(key, "_hex"), vm.toString(bytes32(value)));
    }

    /// @dev Serialize metadata and field descriptions into the current JSON object.
    /// Called twice: once for the pre file and once for the post file.
    function _serializeHeader(string memory version) internal {
        vm.serializeString(_jsonKey, "version", version);
        _serializeUint("block_number", block.number);
        _serializeUint("block_timestamp", block.timestamp);

        vm.serializeString(_jsonKey, "desc_totalAssetSupply", "Total deposited assets in pool (wei)");
        vm.serializeString(_jsonKey, "desc_lastAssetLossError", "Cumulative rounding error from liquidation losses");
        vm.serializeString(_jsonKey, "desc_earlyWithdrawalFee", "Early withdrawal penalty (18 decimals)");
        vm.serializeString(_jsonKey, "desc_feeAddress", "Address receiving early withdrawal fees");
        vm.serializeString(_jsonKey, "desc_withdrawalStartDelay", "Seconds before withdrawal window opens");
        vm.serializeString(_jsonKey, "desc_withdrawalEndWindow", "Seconds the withdrawal window stays open");
        vm.serializeString(_jsonKey, "desc_liquidationToken", "Token received from liquidations");
        vm.serializeString(_jsonKey, "desc_minTotalAssetSupply", "Minimum pool size retained after liquidation");
        vm.serializeString(_jsonKey, "desc_minDeposit", "Minimum deposit amount");
        vm.serializeString(_jsonKey, "desc_assetToken", "Pegged token deposited by users");
        vm.serializeString(_jsonKey, "desc_rewardPeriodLength", "Reward distribution period (seconds)");
        vm.serializeString(_jsonKey, "desc_reward_rate", "Reward tokens distributed per second");
        vm.serializeString(_jsonKey, "desc_reward_finishAt", "Timestamp when reward period ends (0 = broken)");
        vm.serializeString(
            _jsonKey,
            "desc_pendingRewards_ok",
            "Whether pendingRewards() succeeded (false = broken pool)"
        );
        vm.serializeString(_jsonKey, "desc_hex", "Full 32-byte bit pattern of the value");
    }

    /// @dev Serialize reward token data for one token. Called per-token per-pool per-phase.
    function _serializeRewardToken(address proxy, address token, string memory ri) internal {
        vm.serializeString(_jsonKey, string.concat(ri, "_token"), vm.toString(token));
        vm.serializeString(_jsonKey, string.concat(ri, "_isActive"), "true");

        {
            (uint256 lastUpdate, uint256 finishAt, uint256 rate, uint256 queued) = IMultipleRewardDistributor(proxy)
                .rewardData(token);
            _serializeUint(string.concat(ri, "_lastUpdate"), lastUpdate);
            _serializeUint(string.concat(ri, "_finishAt"), finishAt);
            _serializeUint(string.concat(ri, "_rate"), rate);
            _serializeUint(string.concat(ri, "_queued"), queued);
        }

        // pendingRewards may revert on broken pools (finishAt=0 bug)
        try IMultipleRewardDistributor(proxy).pendingRewards(token) returns (
            uint256 distributable,
            uint256 undistributed
        ) {
            vm.serializeString(_jsonKey, string.concat(ri, "_pendingRewards_ok"), "true");
            _serializeUint(string.concat(ri, "_pendingDistributable"), distributable);
            _serializeUint(string.concat(ri, "_pendingUndistributed"), undistributed);
        } catch {
            vm.serializeString(_jsonKey, string.concat(ri, "_pendingRewards_ok"), "false");
            _serializeUint(string.concat(ri, "_pendingDistributable"), 0);
            _serializeUint(string.concat(ri, "_pendingUndistributed"), 0);
        }
    }

    /// @dev Serialize per-user view data. Called per-user per-pool per-phase.
    function _serializeUser(address proxy, address user, address[] memory activeTokens, string memory ui) internal {
        vm.serializeString(_jsonKey, string.concat(ui, "_address"), vm.toString(user));
        _serializeUint(string.concat(ui, "_assetBalance"), IStabilityPool(proxy).assetBalanceOf(user));

        {
            (uint64 wStart, uint64 wEnd) = IStabilityPool(proxy).getWithdrawalRequest(user);
            _serializeUint(string.concat(ui, "_withdrawalStart"), uint256(wStart));
            _serializeUint(string.concat(ui, "_withdrawalEnd"), uint256(wEnd));
        }

        vm.serializeString(
            _jsonKey,
            string.concat(ui, "_rewardReceiver"),
            vm.toString(IMultipleRewardAccumulator(proxy).rewardReceiver(user))
        );

        for (uint256 t = 0; t < activeTokens.length; t++) {
            string memory ut = string.concat(ui, "_reward_", vm.toString(t));
            _serializeUint(
                string.concat(ut, "_claimable"),
                IMultipleRewardAccumulator(proxy).claimable(user, activeTokens[t])
            );
            _serializeUint(
                string.concat(ut, "_claimed"),
                IMultipleRewardAccumulator(proxy).claimed(user, activeTokens[t])
            );
        }
    }

    /// @dev Serialize all view functions for a pool into the current JSON object.
    /// Called 4x per pool (pre + post for each of the two files across v1/v2 runs).
    function _serializePoolState(address proxy, address[] memory depositors, string memory prefix) internal {
        // Pool-global views
        {
            IStabilityPool pool = IStabilityPool(proxy);
            _serializeUint(string.concat(prefix, "_totalAssetSupply"), pool.totalAssetSupply());
            _serializeUint(string.concat(prefix, "_lastAssetLossError"), pool.lastAssetLossError());
            _serializeUint(string.concat(prefix, "_earlyWithdrawalFee"), pool.getEarlyWithdrawalFee());
            vm.serializeString(_jsonKey, string.concat(prefix, "_feeAddress"), vm.toString(pool.getFeeAddress()));
            {
                (uint64 startDelay, uint64 endWindow) = pool.getWithdrawalWindow();
                _serializeUint(string.concat(prefix, "_withdrawalStartDelay"), uint256(startDelay));
                _serializeUint(string.concat(prefix, "_withdrawalEndWindow"), uint256(endWindow));
            }
            vm.serializeString(
                _jsonKey,
                string.concat(prefix, "_liquidationToken"),
                vm.toString(pool.LIQUIDATION_TOKEN())
            );
            _serializeUint(string.concat(prefix, "_minTotalAssetSupply"), pool.MIN_TOTAL_ASSET_SUPPLY());
            _serializeUint(string.concat(prefix, "_minDeposit"), pool.MIN_DEPOSIT());
            vm.serializeString(_jsonKey, string.concat(prefix, "_assetToken"), vm.toString(pool.ASSET_TOKEN()));
        }

        _serializeUint(
            string.concat(prefix, "_rewardPeriodLength"),
            uint256(IMultipleRewardDistributor(proxy).REWARD_PERIOD_LENGTH())
        );

        // Active reward tokens
        {
            address[] memory activeTokens = IMultipleRewardDistributor(proxy).activeRewardTokens();
            _serializeUint(string.concat(prefix, "_activeRewardTokenCount"), activeTokens.length);
            for (uint256 i = 0; i < activeTokens.length; i++) {
                _serializeRewardToken(proxy, activeTokens[i], string.concat(prefix, "_reward_", vm.toString(i)));
            }
        }

        // Historical reward tokens
        {
            address[] memory historicalTokens = IMultipleRewardDistributor(proxy).historicalRewardTokens();
            _serializeUint(string.concat(prefix, "_historicalRewardTokenCount"), historicalTokens.length);
            for (uint256 i = 0; i < historicalTokens.length; i++) {
                vm.serializeString(
                    _jsonKey,
                    string.concat(prefix, "_historicalRewardToken_", vm.toString(i)),
                    vm.toString(historicalTokens[i])
                );
            }
        }

        // Per-user views
        {
            address[] memory activeTokens = IMultipleRewardDistributor(proxy).activeRewardTokens();
            _serializeUint(string.concat(prefix, "_depositorCount"), depositors.length);
            for (uint256 u = 0; u < depositors.length; u++) {
                _serializeUser(proxy, depositors[u], activeTokens, string.concat(prefix, "_user_", vm.toString(u)));
            }
        }
    }

    /// @dev Try all interactions on a pool. Called once per pool = 22x total.
    /// Records success/failure and amounts into the current JSON object.
    function _doInteractions(address proxy, string memory prefix) internal {
        // 1. Deposit
        {
            address assetToken = IStabilityPool(proxy).ASSET_TOKEN();
            deal(assetToken, testUser, 100 ether);
            vm.startPrank(testUser);
            IERC20(assetToken).approve(proxy, type(uint256).max);
            try IStabilityPool(proxy).deposit(100 ether, testUser, 0) {
                vm.serializeString(_jsonKey, string.concat(prefix, "_deposit_success"), "true");
            } catch {
                vm.serializeString(_jsonKey, string.concat(prefix, "_deposit_success"), "false");
            }
            vm.stopPrank();
            _serializeUint(string.concat(prefix, "_deposit_amount"), 100 ether);
        }

        // 2. Deposit reward (prank owner who already has depositor role)
        {
            address liquidationToken = IStabilityPool(proxy).LIQUIDATION_TOKEN();
            address owner = IBaoOwnable(proxy).owner();
            deal(liquidationToken, owner, 10 ether);
            vm.startPrank(owner);
            IERC20(liquidationToken).approve(proxy, type(uint256).max);
            try IMultipleRewardDistributor(proxy).depositReward(liquidationToken, 10 ether) {
                vm.serializeString(_jsonKey, string.concat(prefix, "_depositReward_success"), "true");
            } catch {
                vm.serializeString(_jsonKey, string.concat(prefix, "_depositReward_success"), "false");
            }
            vm.stopPrank();
            vm.serializeString(_jsonKey, string.concat(prefix, "_depositReward_token"), vm.toString(liquidationToken));
            _serializeUint(string.concat(prefix, "_depositReward_amount"), 10 ether);
        }

        // 3. Warp half period and capture mid-period reward state
        {
            uint256 halfPeriod = uint256(IMultipleRewardDistributor(proxy).REWARD_PERIOD_LENGTH()) / 2;
            vm.warp(block.timestamp + halfPeriod);
            _serializeUint(string.concat(prefix, "_warp_half_seconds"), halfPeriod);

            address[] memory activeTokens = IMultipleRewardDistributor(proxy).activeRewardTokens();
            for (uint256 t = 0; t < activeTokens.length; t++) {
                string memory mt = string.concat(prefix, "_mid_reward_", vm.toString(t));
                _serializeUint(
                    string.concat(mt, "_testUser_claimable"),
                    IMultipleRewardAccumulator(proxy).claimable(testUser, activeTokens[t])
                );
                // Also capture mid-period claimable for existing depositors
                address[] memory depositors = poolDepositors[proxy];
                for (uint256 d = 0; d < depositors.length; d++) {
                    _serializeUint(
                        string.concat(mt, "_user_", vm.toString(d), "_claimable"),
                        IMultipleRewardAccumulator(proxy).claimable(depositors[d], activeTokens[t])
                    );
                }
            }
        }

        // 4. Warp remaining half period
        {
            uint256 halfPeriod = uint256(IMultipleRewardDistributor(proxy).REWARD_PERIOD_LENGTH()) / 2;
            vm.warp(block.timestamp + halfPeriod);
            _serializeUint(string.concat(prefix, "_warp_total_seconds"), halfPeriod * 2);
        }

        // 5. Claim for existing depositors
        {
            address[] memory depositors = poolDepositors[proxy];
            for (uint256 i = 0; i < depositors.length; i++) {
                string memory ci = string.concat(prefix, "_claim_user_", vm.toString(i));
                vm.prank(depositors[i]);
                try IMultipleRewardAccumulator(proxy).claim(depositors[i]) {
                    vm.serializeString(_jsonKey, string.concat(ci, "_success"), "true");
                } catch {
                    vm.serializeString(_jsonKey, string.concat(ci, "_success"), "false");
                }
            }
        }

        // 6. Withdraw for test user (request, warp into window, withdraw)
        vm.startPrank(testUser);
        try IStabilityPool(proxy).requestWithdrawal() {
            vm.serializeString(_jsonKey, string.concat(prefix, "_requestWithdrawal_success"), "true");
            vm.stopPrank();

            {
                (uint64 wStart, ) = IStabilityPool(proxy).getWithdrawalRequest(testUser);
                if (wStart > 0) {
                    vm.warp(uint256(wStart) + 1);
                }
            }

            uint256 withdrawAmount = IStabilityPool(proxy).assetBalanceOf(testUser) / 2;
            vm.prank(testUser);
            try IStabilityPool(proxy).withdraw(withdrawAmount, testUser, 0) {
                vm.serializeString(_jsonKey, string.concat(prefix, "_withdraw_success"), "true");
            } catch {
                vm.serializeString(_jsonKey, string.concat(prefix, "_withdraw_success"), "false");
            }
            _serializeUint(string.concat(prefix, "_withdraw_amount"), withdrawAmount);
        } catch {
            vm.stopPrank();
            vm.serializeString(_jsonKey, string.concat(prefix, "_requestWithdrawal_success"), "false");
            vm.serializeString(_jsonKey, string.concat(prefix, "_withdraw_success"), "false");
            _serializeUint(string.concat(prefix, "_withdraw_amount"), 0);
        }
    }

    // ========================================================================
    // TEST FUNCTION
    // ========================================================================

    /// @notice Capture all view function results and interaction outcomes to JSON files.
    /// @dev Run with VERSION=v1 or VERSION=v2 environment variable.
    /// Produces two files: tmp/{version}_pre.json and tmp/{version}_post.json
    function test_captureState() public {
        string memory version = vm.envOr("VERSION", string("v1"));
        string memory poolFilter = vm.envOr("POOL_FILTER", string(""));

        // ================================================================
        // PRE FILE: state snapshot before any interactions
        // ================================================================
        _jsonKey = "pre";
        _serializeHeader(version);
        uint256 activeCount = 0;
        for (uint256 i = 0; i < pools.length; i++) {
            if (bytes(poolFilter).length > 0 && !pools[i].label.contains(poolFilter)) continue;
            activeCount++;
            vm.serializeString(_jsonKey, string.concat(pools[i].label, "_proxy"), vm.toString(pools[i].proxy));
            _serializePoolState(pools[i].proxy, poolDepositors[pools[i].proxy], pools[i].label);
        }
        vm.writeJson(vm.serializeString(_jsonKey, "_complete", "true"), string.concat("tmp/", version, "_pre.json"));
        console.log("Pre-interaction state:", string.concat("tmp/", version, "_pre.json"));

        // ================================================================
        // INTERACTIONS: deposit, depositReward, warp, claim, withdraw
        // (serialized into the "post" JSON object below)
        // ================================================================
        _jsonKey = "post";
        _serializeHeader(version);
        for (uint256 i = 0; i < pools.length; i++) {
            if (bytes(poolFilter).length > 0 && !pools[i].label.contains(poolFilter)) continue;
            _doInteractions(pools[i].proxy, string.concat(pools[i].label, "_interact"));
        }

        // ================================================================
        // POST FILE: interaction results + state after interactions
        // ================================================================
        for (uint256 i = 0; i < pools.length; i++) {
            if (bytes(poolFilter).length > 0 && !pools[i].label.contains(poolFilter)) continue;
            address[] memory depositors = poolDepositors[pools[i].proxy];
            address[] memory postDepositors = new address[](depositors.length + 1);
            for (uint256 j = 0; j < depositors.length; j++) {
                postDepositors[j] = depositors[j];
            }
            postDepositors[depositors.length] = testUser;
            vm.serializeString(_jsonKey, string.concat(pools[i].label, "_proxy"), vm.toString(pools[i].proxy));
            _serializePoolState(pools[i].proxy, postDepositors, pools[i].label);
        }
        vm.writeJson(vm.serializeString(_jsonKey, "_complete", "true"), string.concat("tmp/", version, "_post.json"));
        console.log("Post-interaction state:", string.concat("tmp/", version, "_post.json"));
        console.log("Pool count:", activeCount);
    }
}
