#!/usr/bin/env bash
set -euo pipefail
# Function to handle SIGINT and terminate subprocess
cleanup() {
    echo "Terminating subprocess..."
    kill 0
}

# Trap SIGINT and call cleanup
trap cleanup SIGINT


network="mainnet"
command="start"
token=""
to=""
amount=""
role=""
on=""
deploy_log="./log/deploy-local.log"

# Function to display usage
usage() {
    echo "Usage: $0 -f <network> [command] [options]"
    echo "Commands:"
    echo "  steal [--erc20 <token>] --to <address> --amount <amount>"
    echo "  grant --role <number> --on <address> --to <address>"
    echo "  impersonate --on <address>"
    echo "  start (default)"
    exit 1
}

# Parse command line options using getopt
PARSED_OPTIONS=$(getopt -n "$0" -o hf:t:a:r:o: --long help,rpc-url:,erc20:,to:,amount:,role:,on: -- "$@")
if [[ $? -ne 0 ]]; then
    usage
fi
eval set -- "$PARSED_OPTIONS"

while true; do
    echo "Processing option: $1"
    case "$1" in
        -f|--rpc-url)
            network=$2
            shift 2
            ;;
        --erc20)
            token=$2
            shift 2
            ;;
        -t|--to)
            to=$2
            shift 2
            ;;
        -a|--amount)
            amount=$2
            shift 2
            ;;
        -r|--role)
            role=$2
            shift 2
            ;;
        -o|--on)
            on=$2
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            usage
            ;;
    esac
done

# Check for required options
if [[ -z "$network" ]]; then
    usage
fi

command="${1:-$command}"

#############################################################################################################
# internal functions

# TODO: add a function to extract the address from the deployment log

bcinfo() {
    local name="$1"
    local field="${2:-address}"
    lib/bao-base/run -q bcinfo $network $name $field
}

address_of() {
    local wallet="$1"
    local address
    if [[ "$wallet" == 0x* ]]; then
        address=$wallet
    elif [[ "$wallet" == "me" ]]; then
        local pk=$(lookup_env "PRIVATE_KEY")
        if [[ "$pk" != "" ]]; then
            address=$(cast wallet address --private-key $pk)
        else
            echo "error: no private key found in env"
            exit 1
        fi
    else
        address=$(bcinfo $wallet)

        # If not found in bcinfo, check the local deploy log
        if [[ -z "$address" && -f "$deploy_log" ]]; then
            # Look for pattern: name = 0xaddress
            address=$(jq -r ".addresses.$wallet // empty" "$deploy_log")
        fi

        # If still not found, use wallet as ENS name
        if [[ -z "$address" ]]; then
            # may be an ENS name
            address="$wallet"
        fi
    fi
    echo "$address"
}

grab() {
    local wallet="$1"
    local eth_amount="$2" # whole units
    shift 2
    local address
    address=$(address_of "$wallet")
    if [[ "$wallet" != "$address" ]]; then
        wallet="$wallet ($address)"
    fi
    local wei_amount=$(cast to-wei "$eth_amount")
    local wei_balance=$(cast balance "$address")
    local eth_balance=$(cast from-wei "$wei_balance")
    echo "*** giving $wallet $eth_amount ETH (current: $eth_balance)..."
    cast rpc anvil_setBalance "$address" $(cast to-hex "$wei_amount") > /dev/null
    wei_balance=$(cast balance "$address")
    eth_balance=$(cast from-wei "$wei_balance")
    echo "*** $wallet balance is now $eth_balance"
}

grab_erc20() {
    local wallet="$1"
    local eth_amount="$2" # whole units
    local token="$3"

    local wallet_address
    wallet_address=$(address_of "$wallet")
    if [[ "$wallet" != "$wallet_address" ]]; then
        wallet="$wallet ($wallet_address)"
    fi
    local token_address
    token_address=$(address_of "$token")
    if [[ "$token" != "$token_address" ]]; then
        token="$token ($token_address)"
    fi

    local wei_balance=$(cast call "$token_address" "balanceOf(address)(uint256)" "$wallet_address" | cut -d' ' -f1)
    local eth_balance=$(cast from-wei "$wei_balance")
    echo "*** giving $wallet $eth_amount erc20 $token (current: $eth_balance)..."

    local wei_amount=$(cast to-wei "$eth_amount")

    # don't steal from the same address twice, nor the current wallet
    local done=("$wallet_address")

    # fetch transfer events in chunks
    local latest_block=$(cast block latest -f number)
    local start_block=$((latest_block - 2000))
    local end_block=$latest_block

    local wei_amount_transferred=0
    while [[ $end_block -ge 0 ]]; do
        # echo "fetching events from block $start_block to $end_block..."
        local events=$(cast logs --from-block $start_block --to-block $end_block --address "$token_address" "Transfer(address,address,uint256)")

        while read -r to; do
            to="0x${to:26}"

            # Check if the address is a valid Ethereum address and not already processed
            if [[ "$to" == 0x* ]] && [[ "${to#0x}" =~ ^[0-9a-fA-F]+$ ]] && [[ "${to#0x}" =~ [1-9a-fA-F] \
                 && ! " ${done[*]} " =~ " ${to} " ]]; then
                done+=("$to")

                local wei_pawn_holding=$(cast call "$token_address" "balanceOf(address)(uint256)" "$to" | cut -d' ' -f1)
                # echo "pawn holding: $pawn_holding."

                if (( $(echo "$wei_pawn_holding > 10000000000000" | bc) == 1 )); then
                    local wei_to_steal=$(echo "$wei_pawn_holding * 9 / 10" | bc) # steal 90% of the balance
                    if (( $(echo "$wei_to_steal > $wei_amount - $wei_amount_transferred" | bc) == 1 )); then
                        wei_to_steal=$(echo "$wei_amount - $wei_amount_transferred" | bc)
                    fi
                    local eth_to_steal=$(cast from-wei "$wei_to_steal")
                    echo "*** stealing $eth_to_steal of $token from $to..."

                    # echo "impersonating $to..."
                    cast rpc anvil_impersonateAccount "$to" > /dev/null
                    cast rpc anvil_setBalance "$to" $(cast to-hex 27542757796200000000) > /dev/null # give them 27.5 ETH so they can pay gas
                    # echo "transferring $wei_to_steal..."
                    cast send "$token_address" "transfer(address,uint256)" "$wallet_address" "$wei_to_steal" --from "$to" --unlocked > /dev/null # transfer the tokens
                    cast rpc anvil_stopImpersonatingAccount "$to" > /dev/null # stop impersonating

                    wei_amount_transferred=$(echo "$wei_amount_transferred + $wei_to_steal" | bc) # add amount transferred
                    local eth_amount_transferred=$(cast from-wei "$wei_amount_transferred")
                    echo "*** total amount stolen so far: $eth_amount_transferred of $eth_amount"
                    # echo "total amount stolen: $wei_amount_transferred of $wei_amount"
                    if (( $(echo "$wei_amount_transferred >= $wei_amount" | bc) == 1 )); then
                        break 2
                    fi
                fi
            fi
        done < <(echo "$events" | awk '/topics:/ {getline; getline; print}')

        end_block=$((start_block - 1))
        start_block=$((end_block - 2000))
        if [[ $start_block -lt 0 ]]; then
            start_block=0
        fi
    done
}

lookup_env() {
    local env_name="$1"
    local value=""
    # look up the environment - check if the variable exists before trying to access it
    if declare -p "$env_name" &>/dev/null; then
        eval "value=\${$env_name}"
    elif [[ -f .env ]]; then
        # Use a subshell to source .env without polluting the parent environment
        value=$(
            # shellcheck disable=SC1091 # file exists check above
            source .env
            if declare -p "$env_name" &>/dev/null; then
                eval "echo \${$env_name}"
            else
                echo ""
            fi
        )
    fi
    echo "$value"
}

#############################################################################################################

transfer() {
    local to="$1"
    local eth_amount="$2"
    local token="$3"

    if [[ -n "$token" ]]; then
        echo "*** transfer $to $eth_amount ERC20 $token"
        grab_erc20 "$to" "$eth_amount" "$token"
    else
        echo "*** transfer $to $eth_amount ETH"
        grab "$to" "$eth_amount"
    fi
}

grant() {
    local role="$1"
    local on="$2"
    local to="$3"
    echo "*** grant role $role on $on to $to..."
    # Add the logic to grant the role here
}

impersonate() {
    local on="$1"
    echo "Impersonating $on..."
    cast rpc anvil_impersonateAccount "$on"
}

start() {
    network="$1"
    # Start Anvil process
    (
        # wait for anvil to start
        while ! nc -z localhost 8545; do
            sleep 1
        done

        echo "*** allowing baomultisig to be impersonated..."
        cast rpc anvil_impersonateAccount $(bcinfo baomultisig) > /dev/null

        grab baomultisig 1

        # pk=$(lookup_env "PRIVATE_KEY")
        # if [[ "$pk" != "" ]]; then
        #     wallet=$(cast wallet address --private-key $pk)
        #     grab $wallet 100
        #     grab_erc20 $wallet 100 wsteth
        # fi

        echo "anvil ready to use..."
        echo "---------------------"
    )&

    # start anvil
    anvil -f $network
}

# Execute the command
echo "processing command: $command"
case $command in

    steal | pinch | nick | grab | pilfer | embezzle | rob | swipe | thieve | filch | purloin |  lift | pillage | plunder | loot | snatch)
        if [[ -z "$to" || -z "$amount" ]]; then
            usage
        fi
        transfer "$to" "$amount" "$token"
        ;;
    grant)
        if [[ -z "$role" || -z "$on" || -z "$to" ]]; then
            usage
        fi
        grant "$role" "$on" "$to"
        ;;
    impersonate)
        if [[ -z "$on" ]]; then
            usage
        fi
        impersonate "$on"
        ;;
    start)
        start "$network"
        ;;
    *)
        usage
        ;;
esac
