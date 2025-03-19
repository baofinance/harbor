#!/usr/bin/env bash
set -euo pipefail

network=${1:-mainnet}

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

bcinfo() {
    local name="$1"
    local field="${2:-address}"
    lib/bao-base/run -q bcinfo $network $name $field
}

grab() {
    local wallet="$1"
    local eth_amount="$2" # whole units
    shift 2
    local address
    if [[ "$wallet" == 0x* ]]; then
        address=$wallet
    else
        address=$(bcinfo $wallet)
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
    if [[ "$wallet" == 0x* ]]; then
        wallet_address=$wallet
    else
        wallet_address=$(bcinfo $wallet)
        wallet="$wallet ($wallet_address)"
    fi

    local token_address
    if [[ "$token" == 0x* ]]; then
        token_address=$token
    else
        token_address=$(bcinfo $token)
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

# Function to handle SIGINT and terminate subprocess
cleanup() {
    echo "Terminating subprocess..."
    kill 0
}

# Trap SIGINT and call cleanup
trap cleanup SIGINT

# start a subprocess to set up anvil after it has been started (see below)
(
    # wait for anvil to start
    while ! nc -z localhost 8545; do
        sleep 1
    done

    baousd=$(bcinfo baousd)
    wsteth=$(bcinfo wsteth)

    echo "*** allowing baomultisig to be impersonated..."
    cast rpc anvil_impersonateAccount $(bcinfo baomultisig)
    echo "*** done."

    grab baomultisig 100

    pk=$(lookup_env "PRIVATE_KEY")
    if [[ "$pk" != "" ]]; then
        wallet=$(cast wallet address --private-key $pk)
        grab $wallet 100
        grab_erc20 $wallet 100 wsteth
    fi

    echo "anvil ready to use..."
    echo "---------------------"
)&

# start anvil
anvil -f $network
