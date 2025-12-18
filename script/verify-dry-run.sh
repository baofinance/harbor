#!/bin/bash
# Quick verification script for dry-run function
# Run this to verify the contract is working before debugging frontend issues

MINTER_ADDRESS="0x8A791620dd6260079BF849Dc5567aDC3F2FdC318"
RPC_URL="http://127.0.0.1:8545"

echo "=== Verifying Dry-Run Function ==="
echo ""

echo "1. Checking chain ID..."
CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
echo "   Chain ID: $CHAIN_ID"
if [ "$CHAIN_ID" != "31337" ]; then
  echo "   ❌ Wrong chain! Expected 31337"
  exit 1
else
  echo "   ✅ Correct chain"
fi

echo ""
echo "2. Checking contract bytecode..."
BYTECODE=$(cast code "$MINTER_ADDRESS" --rpc-url "$RPC_URL")
if [ -z "$BYTECODE" ] || [ "$BYTECODE" == "0x" ]; then
  echo "   ❌ Contract has no code!"
  exit 1
else
  BYTECODE_LEN=${#BYTECODE}
  echo "   ✅ Contract has code (length: $BYTECODE_LEN)"
fi

echo ""
echo "3. Testing redeemPeggedTokenDryRun function..."
RESULT=$(cast call "$MINTER_ADDRESS" "redeemPeggedTokenDryRun(uint256)" 1000000000000000000 --rpc-url "$RPC_URL" 2>&1)
if [ $? -eq 0 ] && [ -n "$RESULT" ] && [ "$RESULT" != "0x" ]; then
  echo "   ✅ Function works!"
  echo "   Result (hex): $RESULT"
  echo ""
  echo "   Decoded values:"
  echo "   - incentiveRatio: $(cast --to-dec "${RESULT:0:66}")"
  echo "   - fee: $(cast --to-dec "${RESULT:66:66}")"
  echo "   - discount: $(cast --to-dec "${RESULT:132:66}")"
  echo "   - peggedRedeemed: $(cast --to-dec "${RESULT:198:66}")"
  echo "   - wrappedCollateralReturned: $(cast --to-dec "${RESULT:264:66}")"
  echo "   - price: $(cast --to-dec "${RESULT:330:66}")"
  echo "   - rate: $(cast --to-dec "${RESULT:396:66}")"
else
  echo "   ❌ Function call failed or returned empty data"
  echo "   Error: $RESULT"
  exit 1
fi

echo ""
echo "4. Verifying function selector..."
SELECTOR=$(cast sig "redeemPeggedTokenDryRun(uint256)")
echo "   Function selector: $SELECTOR"
if echo "$BYTECODE" | grep -qi "${SELECTOR:2}"; then
  echo "   ✅ Selector found in bytecode"
else
  echo "   ⚠️  Selector not found in bytecode (may be in implementation)"
fi

echo ""
echo "=== All checks passed! ==="
echo ""
echo "Contract is working correctly. If frontend still fails:"
echo "  1. Verify frontend is on chain ID 31337"
echo "  2. Verify frontend RPC URL is http://127.0.0.1:8545"
echo "  3. Verify market config has minter address: $MINTER_ADDRESS"
echo "  4. Run the browser console diagnostic from FRONTEND-DRY-RUN-EMPTY-DATA-FIX.md"

