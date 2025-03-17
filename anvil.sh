#!/usr/bin/env bash
set -euo pipefail

# start a subprocess to set up anvil after it has been started (see below)
(
baoUSD=$(lib/bao-base/run -q bcinfo mainnet baousd address)
multisig=$(lib/bao-base/run -q bcinfo mainnet safe_gov address)

echo "baoUSD: $baoUSD"
echo "multisig: $multisig"
# wait for anvil to start
while ! nc -z localhost 8545; do
  sleep 1
done
echo "allowing Bao multisig to be impersonated..."
cast rpc anvil_impersonateAccount 0xfc69e0a5823e2afcbeb8a35d33588360f1496a00
echo "giving Bao multisig some ETH..."
cast rpc anvil_setBalance 0xfc69e0a5823e2afcbeb8a35d33588360f1496a00 0x56BC75E2D63100000
echo "anvil ready to use..."
echo "---------------------"
)&

# start anvil
anvil -f mainnet
