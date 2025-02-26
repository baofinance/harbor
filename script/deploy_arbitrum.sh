#!/bin/bash

# Constants
SAFE_CHAIR="0x2F1567c4A651ED93dB0FC6D9Df1EA9196054f63e"
SAFE_GOV="0x3dFc49e5112005179Da613BdE5973229082dAc35"
MINT_LIMIT="50000000000000000000"
OUTPUT_FILE="./script/deployment/deployment_summary.txt"
MAX_RETRIES=10  # Maximum retries for transaction confirmation
RETRY_DELAY=5   # Delay (in seconds) between retries
exchangerate="200000000000000000000000"
decimals="8"
data=0x00;

#Tokens
# Arbitrum
reth_address="0xEC70Dcb4A1EFa46b8F2D97C310C9c4790ba5ffA8"
tbtc_address="0x6c84a8f1c29108F47a79964b5Fe888D4f4D0dE40"
wsteth_address="0x0fBcbaEA96Ce0cF7Ee00A8c19c3ab6f5Dc8E1921"
# Mainnet
# reth_address="0xae78736Cd615f374D3085123A210448E74Fc6393"
# tbtc_address="0x18084fbA666a33d37592fA2633fD49a74DD93a88"
# wsteth_address="0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0"

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
BTC_PRICE_FEED_ADDRESS="0x6ce185860a4963106506C203335A2910413708e9"
ETH_PRICE_FEED_ADDRESS="0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612"
TBTC_PRICE_FEED_ADDRESS="0xE808488e8627F6531bA79a13A9E0271B39abEb1C"
WSTETH_PRICE_FEED_ADDRESS="0xdB9Ee83CE2ec52655b707171C3515e9A0Cb1eE91"
RETH_PRICE_FEED_ADDRESS="0xC111C7902e5A92BeF45fD0c294CA41321b78fF6d"

# Price Feed Addresses Mainnet
# BTC_PRICE_FEED_ADDRESS="0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c"
# ETH_PRICE_FEED_ADDRESS="0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419"
# TBTC_PRICE_FEED_ADDRESS="0x8350b7De6a6a2C1368E7D4Bd968190e13E354297"
# WSTETH_PRICE_FEED_ADDRESS="0x97541208c6C8ecfbe57B8A44ba86f2A88bA783e2"
# RETH_PRICE_FEED_ADDRESS="0xc44cb0ff4Cd01ca5F79DE6365C37b2aFe2d266CB"

# CERC20 Delegates
# ETH MAINNET
# implementation="0xDb3401beF8f66E7f6CD95984026c26a4F47eEe84"
# ARB MAINNET
implementation="0x90e877e9660a52443cBabD86CA0871A1D60f27e1"

# Ensure environment variables are set
# export RPC_URL="https://your-rpc-url.com"
# export PRIVATE_KEY="your-private-key"
# export ARBISCAN_API_KEY="your-arbiscan-api-key"

# Ensure the output directory exists
mkdir -p "$(dirname "$OUTPUT_FILE")"

# Helper Functions
deploy_contract() {
    local contract_path=$1
    shift
    local constructor_args=("$@")
    local contract_name=$(basename "$contract_path" | cut -d ':' -f 2)
    local output
    local address
    local tx_hash
    local block_number

    # Deploy the contract
    if [ ${#constructor_args[@]} -eq 0 ]; then
        output=$(forge create "$contract_path" \
            --rpc-url "$RPC_URL" \
            --private-key "$PRIVATE_KEY" \
            --etherscan-api-key "$ARBISCAN_API_KEY" \
            --verify \
            --broadcast 2>&1)
    else
        output=$(forge create "$contract_path" \
            --rpc-url "$RPC_URL" \
            --private-key "$PRIVATE_KEY" \
            --etherscan-api-key "$ARBISCAN_API_KEY" \
            --verify \
            --broadcast \
            --constructor-args "${constructor_args[@]}" 2>&1)
    fi

    # Extract address and transaction hash
    address=$(echo "$output" | awk '/Deployed to:/ {print $NF}')
    tx_hash=$(echo "$output" | awk '/Transaction hash:/ {print $NF}')

    if [[ -z "$address" || -z "$tx_hash" ]]; then
        echo "Error: Failed to deploy $contract_name. See logs for details."
        echo "$output" >> "$OUTPUT_FILE"
        exit 1
    fi

    # Get block number of deployment transaction
    block_number=$(cast tx $tx_hash --rpc-url $RPC_URL | awk '/blockNumber/ {print $2}')

    if [[ -z "$block_number" ]]; then
        echo "Error: Failed to retrieve block number for $contract_name deployment."
        exit 1
    fi

    # Append deployment to output file
    echo "Deployment contract >> $contract_name: $address (Block: $block_number)" >> "$OUTPUT_FILE"
    echo "$address $block_number"
}

confirm_deployment() {
    local contract_name=$1
    local contract_address=$2
    local deployment_block=$3
    local retry_count=0
    local current_block

    echo "Confirming deployment of $contract_name at $contract_address (Block: $deployment_block)..."

    while true; do
        current_block=$(cast block latest --rpc-url $RPC_URL | awk '/number/ {print $2}')
        if [[ -n "$current_block" && "$current_block" -gt "$deployment_block" ]]; then
            echo "Contract $contract_name confirmed. Current block: $current_block"
            echo "Contract confirmed >> $contract_name: $contract_address (Confirmed in Block: $deployment_block)" >> "$OUTPUT_FILE"
            break
        fi
        if [[ $retry_count -ge $MAX_RETRIES ]]; then
            echo "Error: Contract $contract_name at $contract_address not confirmed after $MAX_RETRIES retries."
            exit 1
        fi
        echo "Waiting for contract $contract_name confirmation. Current block: $current_block. Retry $((retry_count + 1))/$MAX_RETRIES"
        sleep $RETRY_DELAY
        retry_count=$((retry_count + 1))
    done
}

send_transaction() {
    local target_address=$1
    local calldata=$2
    local contract_name=$3
    local output

    echo "Sending transaction to $contract_name:$target_address..."
    output=$(cast send \
        --rpc-url "$RPC_URL" \
        --private-key "$PRIVATE_KEY" \
        "$target_address" \
        "$calldata" 2>&1)

    if [ $? -ne 0 ]; then
        echo "Error: Transaction to $contract_name:$target_address failed. See logs for details."
        echo "$output" >> "$OUTPUT_FILE"
        exit 1
    fi


    # Log the transaction details without the transaction hash
    echo "Transaction to $contract_name at $target_address >> calldata: $calldata" >> "$OUTPUT_FILE"
    echo "Transaction to $contract_name at $target_address succeeded."
}

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
send_transaction "$oracle_address" "$(cast calldata "setFeed(address,address,uint8)" $bdbao_btc_address $BTC_PRICE_FEED_ADDRESS "18")" "Oracle - SetFeed BTC"
send_transaction "$oracle_address" "$(cast calldata "setFeed(address,address,uint8)" $bd_eth_address $ETH_PRICE_FEED_ADDRESS "18")" "Oracle - SetFeed ETH"
send_transaction "$oracle_address" "$(cast calldata "setFeed(address,address,uint8)" $bdbao_tbtc_address $TBTC_PRICE_FEED_ADDRESS "18")" "Oracle - SetFeed TBTC"
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