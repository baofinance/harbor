# Stability Pool Overflow Risk Monitoring

Scripts to check all stability pools for uint192 integral overflow risk.

## Quick Start

### Python Script (Recommended)

```bash
# Check mainnet pools
./script/check_pool_overflow_risk.py mainnet

# Check sepolia pools
./script/check_pool_overflow_risk.py sepolia
```

### Bash Script (Alternative)

```bash
# Check mainnet pools
./script/check-pool-overflow-risk.sh mainnet

# Check sepolia pools
./script/check-pool-overflow-risk.sh sepolia
```

## Prerequisites

### Environment Variables

Set the appropriate RPC URL:

```bash
export MAINNET_RPC_URL="https://..."
export SEPOLIA_RPC_URL="https://..."  # Optional, for testnet
```

### Required Tools

- `cast` (from Foundry)
- `python3` (for Python script)
- `script/predict` (Harbor deployment script)

## What the Scripts Check

For each pool, the scripts report:

1. **Deployment Status**: Whether the pool is deployed
2. **Total Deposits**: Amount of assets deposited in the pool
3. **Active Reward Tokens**: List of reward tokens being distributed
4. **Per-Token Metrics**:
   - Current integral value
   - Capacity used (% of uint192 max)
   - Risk level (🟢 LOW, 🟡 MEDIUM, 🟠 HIGH, 🔴 CRITICAL)
   - Queued rewards (if any)
   - Distribution rate
   - Weekly integral growth
   - Time to overflow (in weeks)

## Pool Combinations Checked

The scripts check all combinations of:

- **Pegs**: BTC, ETH, EUR
- **Collaterals**: fxUSD, stETH
- **Liquidation Types**: Collateral, Leveraged

Total: 3 × 2 × 2 = **12 pools** per network

## Risk Levels

| Level | Capacity Used | Typical Time to Overflow |
|-------|---------------|--------------------------|
| 🟢 LOW | < 60% | > 12 weeks |
| 🟡 MEDIUM | 60-80% | 4-12 weeks |
| 🟠 HIGH | 80-90% | 2-4 weeks |
| 🔴 CRITICAL | > 90% | < 2 weeks |

## Example Output

```
────────────────────────────────────────────────────────────────────────────────
Pool: BTC::fxUSD::Leveraged
Address: 0x9e56F1E1E80EBf165A1dAa99F9787B41cD5bFE40
Status: DEPLOYED ✅
Total Deposits: 9.700e+16
Magnitude: 1.000e+36

Active Reward Tokens (2):

  Token 1: fxSAVE
    Address: 0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39
    Integral: 5.934e+57
    Capacity Used: 94.53%
    Risk Level: 🔴 CRITICAL
    Rate: 1.116e+18 tokens/second
    Weekly Growth: 7.730e+56
    Time to Overflow: 0.4 weeks 🔴 URGENT

  Token 2: hsBTC-fxUSD
    Address: 0x9567c243F647f9Ac37efb7Fc26BD9551Dce0BE1B
    Integral: 1.234e+55
    Capacity Used: 1.97%
    Risk Level: 🟢 LOW
    Rate: 5.000e+16 tokens/second
    Weekly Growth: 3.456e+54
    Time to Overflow: 1815.3 weeks 🟢 OK
```

## Interpreting Results

### Critical Findings (🔴)

**Immediate action required**. Pool will overflow within 2 weeks:
- Deploy queueing fix immediately
- Monitor daily
- Consider emergency pause of reward distributions

### High Risk (🟠)

**Action needed soon**. Pool will overflow within 2-4 weeks:
- Schedule fix deployment
- Monitor weekly
- Prepare communication plan

### Medium Risk (🟡)

**Monitor closely**. Pool will overflow within 1-3 months:
- Track in monitoring dashboard
- Plan fix deployment
- Consider increasing deposits via incentives

### Low Risk (🟢)

**Normal monitoring**. Pool healthy for >3 months:
- Continue standard monitoring
- No immediate action needed

## Automated Monitoring

### Cron Job Example

```bash
# Add to crontab for daily monitoring
0 9 * * * cd /path/to/harbor && ./script/check_pool_overflow_risk.py mainnet > /tmp/pool-status.txt 2>&1 && grep CRITICAL /tmp/pool-status.txt && mail -s "Pool Critical Alert" team@example.com < /tmp/pool-status.txt
```

### CI/CD Integration

```yaml
# GitHub Actions example
- name: Check Pool Overflow Risk
  run: |
    ./script/check_pool_overflow_risk.py mainnet
  env:
    MAINNET_RPC_URL: ${{ secrets.MAINNET_RPC_URL }}
```

## Troubleshooting

### "Error: Could not determine address"

The pool configuration doesn't exist in deployment state. This is expected for pools that haven't been deployed yet.

### "Error: Could not read totalAssetSupply"

The contract ABI might have changed, or the contract is not a StabilityPool. Verify the address manually:

```bash
cast call <address> "totalAssetSupply()(uint128,uint128)" --rpc-url $MAINNET_RPC_URL
```

### "RPC URL not set"

Set the appropriate environment variable:

```bash
export MAINNET_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/YOUR-KEY"
```

## Manual Checks

To manually check a specific pool:

```bash
# Get pool address
POOL=$(script/predict --porcelain "harbor_v1::BTC::fxUSD::StabilityPoolLeveraged" | head -1)

# Check total deposits
cast call $POOL "totalAssetSupply()(uint128,uint128)" --rpc-url $MAINNET_RPC_URL

# Check active tokens
cast call $POOL "activeRewardTokens()(address[])" --rpc-url $MAINNET_RPC_URL

# Check integral for a specific token
TOKEN=0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39
cast call $POOL "tokenToExponentToIntegral(address,uint8)(uint192)" $TOKEN 0 --rpc-url $MAINNET_RPC_URL

# Check reward data
cast call $POOL "rewardData(address)(uint96,uint256,uint64,uint64)" $TOKEN --rpc-url $MAINNET_RPC_URL
```

## Related Documentation

- [EXECUTIVE_SUMMARY_EXPANDED.md](../EXECUTIVE_SUMMARY_EXPANDED.md) - User experience and business impact
- [SOLUTION_ANALYSIS.md](../SOLUTION_ANALYSIS.md) - Technical deep dive
- [OVERFLOW_SCOPE_ANALYSIS.md](../OVERFLOW_SCOPE_ANALYSIS.md) - Scope and limitations

## Support

If the scripts report critical issues:

1. Review the executive summary for business impact
2. Check the solution analysis for technical details
3. Prepare for queueing fix deployment
4. Communicate with users per communication strategy
