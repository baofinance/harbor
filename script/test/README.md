# Manual Upgrade Verification Tests

These tests verify that upgrading StabilityPool v1 to v2 preserves all on-chain
state and produces identical behavior. They run against a local anvil fork and
are NOT part of CI -- run them manually during the upgrade deployment workflow.

## Output

Each run produces one JSON file per pool in two directories:

```
tmp/{version}/pre/{label}.json   -- state snapshot before any interactions
tmp/{version}/post/{label}.json  -- interaction results + state snapshot after
```

## Workflow

### 1. Start anvil fork and capture v1 state

A good block number would be 24433566, just before the actual deploy and upgrade

```bash
anvil -f mainnet --fork-block-number <BLOCK> --auto-impersonate
```

Note the block number from anvil's output -- you'll need it for step 3.

In a separate terminal:

```bash
VERSION=v1 forge test \
  --match-path script/test/MainnetForkUpgradeTest.t.sol \
  --fork-url local -vvv
```

Output: `tmp/v1/pre/*.json` and `tmp/v1/post/*.json`

Stop anvil (Ctrl+C).

### 2. Start fresh anvil fork and deploy the upgrade

```bash
anvil -f mainnet --fork-block-number <SAME BLOCK AS STEP 1> --auto-impersonate
```

Deploy the upgrade against the local fork:

```bash
./script/deploy-stabilityPool_v2 --network mainnet --salt harbor_v1 --local
```

### 3. Capture v2 state (same anvil instance, post-upgrade)

```bash
VERSION=v2 forge test \
  --match-path script/test/MainnetForkUpgradeTest.t.sol \
  --fork-url local -vvv
```

Output: `tmp/v2/pre/*.json` and `tmp/v2/post/*.json`

Stop anvil.

### 4. Compare

Using meld (recommended -- shows all pools side by side):

```bash
# State before interactions -- should be identical
meld tmp/v1/pre tmp/v2/pre

# Interactions + post-interaction state -- broken pools now work
meld tmp/v1/post tmp/v2/post
```

Using diff:

```bash
diff -ru tmp/v1/pre tmp/v2/pre
diff -ru tmp/v1/post tmp/v2/post
```

Single pool with sorted keys:

```bash
jq --sort-keys . tmp/v1/pre/BTC_fxUSD_col.json > /tmp/v1.json
jq --sort-keys . tmp/v2/pre/BTC_fxUSD_col.json > /tmp/v2.json
diff --color /tmp/v1.json /tmp/v2.json
```

## Environment variables

| Variable      | Default | Description                                                    |
| ------------- | ------- | -------------------------------------------------------------- |
| `VERSION`     | `v1`    | Labels the output directories (`v1` or `v2`)                   |
| `POOL_FILTER` | (none)  | Substring filter on pool labels -- only matching pools run     |

`POOL_FILTER` examples:

```bash
# Only BTC pools
POOL_FILTER=BTC VERSION=v1 forge test ...

# Only collateral pools
POOL_FILTER=_col VERSION=v1 forge test ...

# Single pool
POOL_FILTER=GOLD_fxUSD_lev VERSION=v1 forge test ...
```

Pool labels: `BTC_fxUSD_col`, `BTC_fxUSD_lev`, `BTC_stETH_col`, `BTC_stETH_lev`,
`ETH_fxUSD_col`, `ETH_fxUSD_lev`, `EUR_fxUSD_col`, `EUR_fxUSD_lev`,
`EUR_stETH_col`, `EUR_stETH_lev`, `GOLD_fxUSD_col`, `GOLD_fxUSD_lev`,
`GOLD_stETH_col`, `GOLD_stETH_lev`, `MCAP_fxUSD_col`, `MCAP_fxUSD_lev`,
`MCAP_stETH_col`, `MCAP_stETH_lev`, `SILVER_fxUSD_col`, `SILVER_fxUSD_lev`,
`SILVER_stETH_col`, `SILVER_stETH_lev`

## Expected differences

### Pre files (`v1/pre/*.json` vs `v2/pre/*.json`)

| Key                               | v1        | v2       | Meaning                                          |
| --------------------------------- | --------- | -------- | ------------------------------------------------ |
| `version`                         | `"v1"`    | `"v2"`   | Test metadata                                    |
| `state_reward_*_pendingRewards_ok` | `"false"` | `"true"` | pendingRewards no longer reverts on broken pools |

Everything else should be **identical** -- proves the upgrade preserves all state.

### Post files (`v1/post/*.json` vs `v2/post/*.json`)

| Key                                   | v1        | v2       | Meaning                                                      |
| ------------------------------------- | --------- | -------- | ------------------------------------------------------------ |
| `version`                             | `"v1"`    | `"v2"`   | Test metadata                                                |
| `interact_deposit_success`            | `"false"` | `"true"` | Broken pools now accept deposits                             |
| `interact_depositReward_success`      | `"false"` | `"true"` | Broken pools now accept rewards                              |
| `interact_withdraw_success`           | `"false"` | `"true"` | Broken pools now allow withdrawals                           |
| post-interaction state                | differs   | differs  | State for newly-fixed pools reflects successful interactions |

## Adding depositors

The test currently has one hardcoded depositor. To discover more:

```bash
TOPIC0=$(cast sig-event "Deposit(address indexed,address indexed,uint256)")
POOL=0x9e56F1E1E80EBf165A1dAa99F9787B41cD5bFE40
cast logs --rpc-url mainnet --address $POOL \
  --from-block 0 --to-block 24404265 $TOPIC0 \
  | jq -r '.[].topics[1]' | sort -u
```

Add discovered addresses to the `poolDepositors` mapping in `setUp()`.
