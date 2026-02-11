# Manual Upgrade Verification Tests

These tests verify that upgrading StabilityPool v1 to v2 preserves all on-chain
state and produces identical behavior. They run against a local anvil fork and
are NOT part of CI -- run them manually during the upgrade deployment workflow.

## Output

Each run produces two files in `tmp/`:
- `{version}_pre.json` -- state snapshot before any interactions
- `{version}_post.json` -- interaction results + state snapshot after interactions

## Workflow

### 1. Start anvil fork and capture v1 state

```bash
anvil -f mainnet --fork-block-number <BLOCK>
```

Note the block number from anvil's output -- you'll need it for step 3.

In a separate terminal:

```bash
VERSION=v1 forge test \
  --match-path script/test/MainnetForkUpgradeTest.t.sol \
  --fork-url http://localhost:8545 -vvv
```

Output: `tmp/v1_pre.json` and `tmp/v1_post.json`

Stop anvil (Ctrl+C).

### 2. Start fresh anvil fork and deploy the upgrade

```bash
anvil -f mainnet --fork-block-number <SAME BLOCK AS STEP 1>
```

Deploy the upgrade against the local fork:

```bash
./script/deploy-stabilityPool_v2 --network mainnet --salt harbor_v1 --local
```

### 3. Capture v2 state (same anvil instance, post-upgrade)

```bash
VERSION=v2 forge test \
  --match-path script/test/MainnetForkUpgradeTest.t.sol \
  --fork-url http://localhost:8545 -vvv
```

Output: `tmp/v2_pre.json` and `tmp/v2_post.json`

Stop anvil.

### 4. Compare

```bash
# State before interactions -- should be identical
diff tmp/v1_pre.json tmp/v2_pre.json

# Interactions + post-interaction state -- broken pools now work
diff tmp/v1_post.json tmp/v2_post.json
```

For a more readable diff:

```bash
jq --sort-keys . tmp/v1_pre.json > /tmp/v1_pre.json
jq --sort-keys . tmp/v2_pre.json > /tmp/v2_pre.json
diff --color /tmp/v1_pre.json /tmp/v2_pre.json

jq --sort-keys . tmp/v1_post.json > /tmp/v1_post.json
jq --sort-keys . tmp/v2_post.json > /tmp/v2_post.json
diff --color /tmp/v1_post.json /tmp/v2_post.json
```

## Expected differences

### Pre files (`v1_pre.json` vs `v2_pre.json`)

| Key | v1 | v2 | Meaning |
|-----|----|----|---------|
| `version` | `"v1"` | `"v2"` | Test metadata |
| `*_reward_*_pendingRewards_ok` | `"false"` | `"true"` | pendingRewards no longer reverts on broken pools |

Everything else should be **identical** -- proves the upgrade preserves all state.

### Post files (`v1_post.json` vs `v2_post.json`)

| Key | v1 | v2 | Meaning |
|-----|----|----|---------|
| `version` | `"v1"` | `"v2"` | Test metadata |
| `*_interact_deposit_success` | `"false"` | `"true"` | Broken pools now accept deposits |
| `*_interact_depositReward_success` | `"false"` | `"true"` | Broken pools now accept rewards |
| `*_interact_withdraw_success` | `"false"` | `"true"` | Broken pools now allow withdrawals |
| post-interaction state | differs | differs | State for newly-fixed pools reflects successful interactions |

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
