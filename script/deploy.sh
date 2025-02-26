#!/bin/bash

blockchainname=$1; shift
blockchainconfig=./script/addresses-$blockchainname.json
blockchainnumber=$(jq)


# Constants
OUTPUT_FILE="$0-deployment/summary.txt"
MAX_RETRIES=10  # Maximum retries for transaction confirmation
RETRY_DELAY=5   # Delay (in seconds) between retries


wsteth_address=$(jq -r ".wsteth" ./script/addresses-$blockchainname.json )
echo $wsteth_address
exit

#Markets
marketname1="bd_baoBTC";
marketsymbol1="bdbaoBTC";
marketname2="bd_Ether_baoBTC";
marketsymbol2="bdETH";
marketname3="bd_tbtc_baoBTC";
marketsymbol3="bdbaoTBTC";
marketname4="bd_wsteth_baoBTC";
marketsymbol4="bdbaoWSTETH";
marketname5="bd_reth_baoBTC";
marketsymbol5="bdbaoRETH";

# Price Feed Addresses Arbitrum
#BTC_PRICE_FEED_ADDRESS="0x6ce185860a4963106506C203335A2910413708e9"
#ETH_PRICE_FEED_ADDRESS="0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612"
#TBTC_PRICE_FEED_ADDRESS="0xE808488e8627F6531bA79a13A9E0271B39abEb1C"
#WSTETH_PRICE_FEED_ADDRESS="0xdB9Ee83CE2ec52655b707171C3515e9A0Cb1eE91"
#RETH_PRICE_FEED_ADDRESS="0xC111C7902e5A92BeF45fD0c294CA41321b78fF6d"

# Price Feed Addresses Mainnet
BTC_PRICE_FEED_ADDRESS="0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c"
ETH_PRICE_FEED_ADDRESS="0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419"
TBTC_PRICE_FEED_ADDRESS="0x8350b7De6a6a2C1368E7D4Bd968190e13E354297"
WSTETH_PRICE_FEED_ADDRESS="0x97541208c6C8ecfbe57B8A44ba86f2A88bA783e2"
RETH_PRICE_FEED_ADDRESS="0xc44cb0ff4Cd01ca5F79DE6365C37b2aFe2d266CB"

# CERC20 Delegates
# ETH MAINNET
implementation="0xDb3401beF8f66E7f6CD95984026c26a4F47eEe84"
# ARB MAINNET
# implementation="0x90e877e9660a52443cBabD86CA0871A1D60f27e1"

# Ensure environment variables are set
# export RPC_URL="https://your-rpc-url.com"
# export PRIVATE_KEY="your-private-key"
# export ETHERSCAN_API_KEY="your-etherscan-api-key"

# Ensure the output directory exists
mkdir -p "$(dirname "$OUTPUT_FILE")"



# Start Deployment
echo "Starting deployment..." > "$OUTPUT_FILE"

# Deploy contracts sequentially
read comptroller_address comptroller_block <<< $(deploy_contract "src/markets/Comptroller/Comptroller.sol:Comptroller")
read unitroller_address unitroller_block <<< $(deploy_contract "src/markets/Comptroller/Unitroller.sol:Unitroller")
read oracle_address oracle_block <<< $(deploy_contract "src/utils/Oracle.sol:Oracle")

# Comptroller Configuration
echo "----------------------------------" >> "$OUTPUT_FILE"
echo "Comptroller configuration..." >> "$OUTPUT_FILE"
send_transaction "$unitroller_address" "$(cast calldata "_setPendingImplementation(address)" $comptroller_address)" "Unitroller - SetImplementation"
send_transaction "$comptroller_address" "$(cast calldata "_become(address)" $unitroller_address)" "Comptroller - AcceptImplementation"

# Resuming Deployment
echo "----------------------------------" >> "$OUTPUT_FILE"
echo "Resuming contract deployment..." >> "$OUTPUT_FILE"

read bao_btc_address bao_btc_block <<< $(
   deploy_contract "src/markets/ERC20.sol:ERC20" \
       "Bao BTC" \
       "baoBTC" \
       18
)

read jump_rate_model_address jump_rate_model_block <<< $(
    deploy_contract "src/utils/InterestRateModels/JumpRateModelV2.sol:JumpRateModelV2" \
        0 \
        "49999999998268800" \
        "1089999999998841600" \
        "800000000000000000" \
        "$SAFE_GOV"
)

read white_paper_model_address white_paper_model_block <<< $(
    deploy_contract "src/utils/InterestRateModels/WhitePaperInterestRateModel.sol:WhitePaperInterestRateModel" \
        "19999999999728000" \
        "99999999998640000" \
        "$SAFE_GOV"
)

read bdbao_btc_address bdbao_btc_block <<< $(
    deploy_contract "src/markets/CErc20Delegator.sol:CErc20Delegator" \
    "$bao_btc_address" \
    "$unitroller_address" \
    "$jump_rate_model_address" \
    "$exchangerate" \
    "$marketname1" \
    "$marketsymbol1" \
    "$decimals" \
    "$implementation" \
    "$data"
)

read bd_eth_address bd_eth_block <<< $(
    deploy_contract "src/markets/CEther.sol:CEther" \
    "$unitroller_address" \
    "$white_paper_model_address" \
    "$exchangerate" \
    "$marketname2" \
    "$marketsymbol2" \
    "$decimals"
)

read bdbao_tbtc_address bdbao_tbtc_block <<< $(
    deploy_contract "src/markets/CErc20Delegator.sol:CErc20Delegator" \
    "$tbtc_address" \
    "$unitroller_address" \
    "$jump_rate_model_address" \
    "$exchangerate" \
    "$marketname3" \
    "$marketsymbol3" \
    "$decimals" \
    "$implementation" \
    "$data"
)

read bdbao_wsteth_address bdbao_wsteth_block <<< $(
    deploy_contract "src/markets/CErc20Delegator.sol:CErc20Delegator" \
    "$wsteth_address" \
    "$unitroller_address" \
    "$jump_rate_model_address" \
    "$exchangerate" \
    "$marketname4" \
    "$marketsymbol4" \
    "$decimals" \
    "$implementation" \
    "$data"
)

read bdbao_reth_address bdbao_reth_block <<< $(
    deploy_contract "src/markets/CErc20Delegator.sol:CErc20Delegator" \
    "$reth_address" \
    "$unitroller_address" \
    "$jump_rate_model_address" \
    "$exchangerate" \
    "$marketname5" \
    "$marketsymbol5" \
    "$decimals" \
    "$implementation" \
    "$data"
)

read bao_btc_fed bao_btc_fed_block <<< $(
    deploy_contract "src/utils/BaoSynthFed.sol:BaoSynthFed" \
    "$bdbao_btc_address" \
    "$bao_btc_address" \
    "$SAFE_CHAIR" \
    "$SAFE_GOV"
)

# Confirm deployments
echo "----------------------------------" >> "$OUTPUT_FILE"
echo "Confirming deployment..." >> "$OUTPUT_FILE"
confirm_deployment "Comptroller" "$comptroller_address" "$comptroller_block"
confirm_deployment "Unitroller" "$unitroller_address" "$unitroller_block"
confirm_deployment "Oracle" "$oracle_address" "$oracle_block"
confirm_deployment "BaoBTC" "$bao_btc_address" "$bao_btc_block"
confirm_deployment "JumpRateModel" "$jump_rate_model_address" "$jump_rate_model_block"
confirm_deployment "WhitePaperModel" "$white_paper_model_address" "$white_paper_model_block"
confirm_deployment "bdbaoBTC" "$bdbao_btc_address" "$bdbao_btc_block"
confirm_deployment "bdETH" "$bd_eth_address" "$bd_eth_block"
confirm_deployment "bdbaotBTC" "$bdbao_tbtc_address" "$bdbao_tbtc_block"
confirm_deployment "bdbaowstETH" "$bdbao_wsteth_address" "$bdbao_wsteth_block"
confirm_deployment "bdbaorETH" "$bdbao_reth_address" "$bdbao_reth_block"
confirm_deployment "BaoSynthFed" "$bao_btc_fed" "$bao_btc_fed_block"

# Contract Configuration
echo "----------------------------------" >> "$OUTPUT_FILE"
echo "Contract configuration..." >> "$OUTPUT_FILE"

# Interacting with deployed contracts
send_transaction "$oracle_address" "$(cast calldata "setFeed(address,address,uint8)" $bdbao_btc_address $BTC_PRICE_FEED_ADDRESS "8")" "Oracle - SetFeed BTC"
send_transaction "$oracle_address" "$(cast calldata "setFeed(address,address,uint8)" $bd_eth_address $ETH_PRICE_FEED_ADDRESS "8")" "Oracle - SetFeed ETH"
send_transaction "$oracle_address" "$(cast calldata "setFeed(address,address,uint8)" $bdbao_tbtc_address $TBTC_PRICE_FEED_ADDRESS "8")" "Oracle - SetFeed TBTC"
send_transaction "$oracle_address" "$(cast calldata "setFeed(address,address,uint8)" $bdbao_wsteth_address $WSTETH_PRICE_FEED_ADDRESS "18")" "Oracle - SetFeed WSTETH"
send_transaction "$oracle_address" "$(cast calldata "setFeed(address,address,uint8)" $bdbao_reth_address $RETH_PRICE_FEED_ADDRESS "18")" "Oracle - SetFeed RETH"

send_transaction "$unitroller_address" "$(cast calldata "_setPriceOracle(address)" $oracle_address)" "Comptroller - PriceOracle"
send_transaction "$unitroller_address" "$(cast calldata "_setCloseFactor(uint256)" "500000000000000000")" "Comptroller - CloseFactor"
send_transaction "$unitroller_address" "$(cast calldata "_setLiquidationIncentive(uint256)" "1100000000000000000")" "Comptroller - LiquidationIncentive"
send_transaction "$unitroller_address" "$(cast calldata "_supportMarket(address)" $bdbao_btc_address)" "Comptroller - SupportMarket BaoBTC"
send_transaction "$unitroller_address" "$(cast calldata "_supportMarket(address)" $bd_eth_address)" "Comptroller - SupportMarket ETH"
send_transaction "$unitroller_address" "$(cast calldata "_supportMarket(address)" $bdbao_tbtc_address)" "Comptroller - SupportMarket TBTC"
send_transaction "$unitroller_address" "$(cast calldata "_supportMarket(address)" $bdbao_wsteth_address)" "Comptroller - SupportMarket WSTETH"
send_transaction "$unitroller_address" "$(cast calldata "_supportMarket(address)" $bdbao_reth_address)" "Comptroller - SupportMarket RETH"
send_transaction "$unitroller_address" "$(cast calldata "_setCollateralFactor(address,uint256)" $bdbao_btc_address "0")" "Comptroller - CollateralFactor BaoBTC"
send_transaction "$unitroller_address" "$(cast calldata "_setCollateralFactor(address,uint256)" $bd_eth_address "0")" "Comptroller - CollateralFactor ETH"
send_transaction "$unitroller_address" "$(cast calldata "_setCollateralFactor(address,uint256)" $bdbao_tbtc_address "0")" "Comptroller - CollateralFactor TBTC"
send_transaction "$unitroller_address" "$(cast calldata "_setCollateralFactor(address,uint256)" $bdbao_wsteth_address "0")" "Comptroller - CollateralFactor WSTETH"
send_transaction "$unitroller_address" "$(cast calldata "_setCollateralFactor(address,uint256)" $bdbao_reth_address "0")" "Comptroller - CollateralFactor RETH"
send_transaction "$unitroller_address" "$(cast calldata "_setIMFFactor(address,uint256)" $bdbao_btc_address "40000000000000000")" "Comptroller - IMFFactor BaoBTC"
send_transaction "$unitroller_address" "$(cast calldata "_setIMFFactor(address,uint256)" $bd_eth_address "40000000000000000")" "Comptroller - IMFFactor ETH"
send_transaction "$unitroller_address" "$(cast calldata "_setIMFFactor(address,uint256)" $bdbao_tbtc_address "40000000000000000")" "Comptroller - IMFFactor TBTC"
send_transaction "$unitroller_address" "$(cast calldata "_setIMFFactor(address,uint256)" $bdbao_wsteth_address "40000000000000000")" "Comptroller - IMFFactor WSTETH"
send_transaction "$unitroller_address" "$(cast calldata "_setIMFFactor(address,uint256)" $bdbao_reth_address "40000000000000000")" "Comptroller - IMFFactor RETH"
send_transaction "$unitroller_address" "$(cast calldata "_setMarketBorrowCaps(address[],uint256[])" "[$bdbao_btc_address]" "[$MINT_LIMIT]")" "Comptroller - BorrowCap BaoBTC"
send_transaction "$unitroller_address" "$(cast calldata "_setBorrowRestriction(address[],bool[])" "[$bdbao_btc_address]" "[false]")" "Comptroller - BorrowRestriction BaoBTC"
send_transaction "$bdbao_btc_address" "$(cast calldata "_setReserveFactor(uint256)" "500000000000000000")" "Bao Deposited BTC - ReserveFactor"
send_transaction "$bd_eth_address" "$(cast calldata "_setReserveFactor(uint256)" "500000000000000000")" "Bao Deposited ETH - ReserveFactor"
send_transaction "$bdbao_tbtc_address" "$(cast calldata "_setReserveFactor(uint256)" "500000000000000000")" "Bao Deposited TBTC - ReserveFactor"
send_transaction "$bdbao_wsteth_address" "$(cast calldata "_setReserveFactor(uint256)" "500000000000000000")" "Bao Deposited WSTEH - ReserveFactor"
send_transaction "$bdbao_reth_address" "$(cast calldata "_setReserveFactor(uint256)" "500000000000000000")" "Bao Deposited RETH - ReserveFactor"
send_transaction "$bdbao_btc_address" "$(cast calldata "_setPendingAdmin(address)" $SAFE_GOV)" "Bao Deposited BTC - SetPendingAdmin GOV"
send_transaction "$bd_eth_address" "$(cast calldata "_setPendingAdmin(address)" $SAFE_GOV)" "Bao Deposited ETH - SetPendingAdmin GOV"
send_transaction "$bdbao_tbtc_address" "$(cast calldata "_setPendingAdmin(address)" $SAFE_GOV)" "Bao Deposited TBTC - SetPendingAdmin GOV"
send_transaction "$bdbao_wsteth_address" "$(cast calldata "_setPendingAdmin(address)" $SAFE_GOV)" "Bao Deposited WSTEH - SetPendingAdmin GOV"
send_transaction "$bdbao_reth_address" "$(cast calldata "_setPendingAdmin(address)" $SAFE_GOV)" "Bao Deposited RETH - SetPendingAdmin GOV"
send_transaction "$unitroller_address" "$(cast calldata "_setPendingAdmin(address)" $SAFE_GOV)" "Unitroller - SetPendingAdmin GOV"
send_transaction "$bao_btc_address" "$(cast calldata "addMinter(address)" $bao_btc_fed)" "Bao BTC - AddMinter BaoSynthFed"
send_transaction "$bao_btc_fed" "$(cast calldata "expansion(uint256)" $MINT_LIMIT)" "Bao FED - Expansion"
send_transaction "$bao_btc_fed" "$(cast calldata "revokeChair()")" "Bao FED - Revoke deployment address"

# Output deployment summary
echo "----------------------------------" >> "$OUTPUT_FILE"
echo "BaoTreasuryMultisig (GOV) needs to accept Pending admin." >> "$OUTPUT_FILE"
echo "Don't forget to deposit min shares before setting the Collateral Factors." >> "$OUTPUT_FILE"
echo "Don't forget to set the Collateral Factors." >> "$OUTPUT_FILE"
echo "Check if Bao Synth is borrowable." >> "$OUTPUT_FILE"
echo "Deployment complete." >> "$OUTPUT_FILE"