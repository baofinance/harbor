# Sail Token Subgraph Setup - Manual Instructions

## Current Status

✅ Handler file created: `/Users/andrewyoung/Harbor-App/harbor-app/subgraph/src/sailToken.ts`
✅ Schema updated: `SailTokenBalance` entity added to `schema.graphql`
⚠️ **YAML needs manual fix**: `subgraph.yaml` has structural issues that need to be fixed manually

## Manual Fix Required

The `subgraph.yaml` file needs the sail token data source added in the correct location. Here's what to do:

### Step 1: Locate HaToken_haPB Data Source

Find this section in `subgraph.yaml` (around line 40-60):

```yaml
  # Static data source for haPB token (ha token)
  - kind: ethereum
    name: HaToken_haPB
    network: anvil
    source:
      address: "0x1c85638e118b37167e9298c2268758e058DdfDA0" # haPB token address
      abi: ERC20
      startBlock: 93 # Start from Genesis deployment block
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - HaTokenBalance
        - MarksMultiplier
        - UserTotalMarks
        - PriceFeed
      abis:
        - name: ERC20
          file: ./abis/ERC20.json
        - name: ChainlinkAggregator
          file: ./abis/ChainlinkAggregator.json
      eventHandlers:
        - event: Transfer(indexed address,indexed address,uint256)
          handler: handleHaTokenTransfer
      file: ./src/haToken.ts
```

### Step 2: Add Sail Token Data Source Right After

Insert this **immediately after** the `file: ./src/haToken.ts` line:

```yaml
  # Static data source for hsPB token (sail token)
  - kind: ethereum
    name: SailToken_hsPB
    network: anvil
    source:
      address: "0x367761085BF3C12e5DA2Df99AC6E1a824612b8fb" # hsPB token address
      abi: ERC20
      startBlock: 93 # Start from Genesis deployment block
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - SailTokenBalance
        - MarksMultiplier
        - UserTotalMarks
        - PriceFeed
      abis:
        - name: ERC20
          file: ./abis/ERC20.json
        - name: ChainlinkAggregator
          file: ./abis/ChainlinkAggregator.json
      eventHandlers:
        - event: Transfer(indexed address,indexed address,uint256)
          handler: handleSailTokenTransfer
      file: ./src/sailToken.ts
```

### Step 3: Remove Any Duplicates

Search for `SailToken_hsPB` in the file and remove any duplicate entries. There should be only **one** sail token data source.

### Step 4: Verify YAML Structure

Make sure:
- ✅ Indentation is correct (2 spaces)
- ✅ No duplicate `SailToken_hsPB` entries
- ✅ The sail token entry is in the `dataSources:` section
- ✅ It comes after `HaToken_haPB` and before `StabilityPoolCollateral`

### Step 5: Run Codegen

```bash
cd /Users/andrewyoung/Harbor-App/harbor-app/subgraph
yarn codegen
```

Expected output: Should generate types for `SailToken_hsPB` without errors.

### Step 6: Build

```bash
yarn build
```

Expected output: Should compile successfully.

### Step 7: Deploy

```bash
graph deploy --node http://localhost:8020/ --ipfs http://localhost:5001 harbor-marks-local --version-label v1.1.0
```

## Verification

After deployment, test with:

```graphql
query GetSailTokenMarks($userAddress: Bytes!) {
  sailTokenBalances(where: { user: $userAddress }) {
    id
    tokenAddress
    balance
    balanceUSD
    accumulatedMarks
    marksPerDay
    lastUpdated
  }
}
```

## Files Status

- ✅ `/Users/andrewyoung/Harbor-App/harbor-app/subgraph/src/sailToken.ts` - Handler file created
- ✅ `/Users/andrewyoung/Harbor-App/harbor-app/subgraph/schema.graphql` - `SailTokenBalance` entity added
- ⚠️ `/Users/andrewyoung/Harbor-App/harbor-app/subgraph/subgraph.yaml` - Needs manual fix (see above)

## Quick Fix Command

If you want to try an automated fix, you can use this Python script:

```python
import re

with open('subgraph.yaml', 'r') as f:
    content = f.read()

# Remove all existing sail token entries
content = re.sub(r'  # Static data source for hsPB token.*?file: \.\/src\/sailToken\.ts\n', '', content, flags=re.DOTALL)

# Insert sail token after haToken
sail_config = '''  # Static data source for hsPB token (sail token)
  - kind: ethereum
    name: SailToken_hsPB
    network: anvil
    source:
      address: "0x367761085BF3C12e5DA2Df99AC6E1a824612b8fb" # hsPB token address
      abi: ERC20
      startBlock: 93 # Start from Genesis deployment block
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - SailTokenBalance
        - MarksMultiplier
        - UserTotalMarks
        - PriceFeed
      abis:
        - name: ERC20
          file: ./abis/ERC20.json
        - name: ChainlinkAggregator
          file: ./abis/ChainlinkAggregator.json
      eventHandlers:
        - event: Transfer(indexed address,indexed address,uint256)
          handler: handleSailTokenTransfer
      file: ./src/sailToken.ts
'''

content = re.sub(
    r'(file: \.\/src\/haToken\.ts)\n',
    r'\1\n' + sail_config + '\n',
    content,
    count=1
)

with open('subgraph.yaml', 'w') as f:
    f.write(content)
```

Save this as `fix-yaml.py` and run:
```bash
cd /Users/andrewyoung/Harbor-App/harbor-app/subgraph
python3 fix-yaml.py
```



