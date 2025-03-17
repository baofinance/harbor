#!/usr/bin/env bash
set -euo pipefail

network=${1:-mainnet}

# start a subprocess to set up anvil after it has been started (see below)
(
baousd=$(lib/bao-base/run -q bcinfo $network baousd address)
multisig=$(lib/bao-base/run -q bcinfo $network baomultisig address)

echo "baousd: $baousd"
echo "multisig: $multisig"
# wait for anvil to start
while ! nc -z localhost 8545; do
  sleep 1
done
echo "allowing Bao multisig to be impersonated..."
cast rpc anvil_impersonateAccount "$multisig"
echo "giving Bao multisig some ETH..."
cast rpc anvil_setBalance "$multisig" $(cast to-hex $(cast to-wei 100)) #0x56BC75E2D63100000
cast balance $multisig
echo "anvil ready to use..."
echo "---------------------"
)&

# start anvil
anvil -f $network
