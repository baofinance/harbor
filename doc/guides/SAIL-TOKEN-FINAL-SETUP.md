# Sail Token Subgraph - Final Setup Instructions

## ✅ Completed

1. ✅ Handler file: `/Users/andrewyoung/Harbor-App/harbor-app/subgraph/src/sailToken.ts`
2. ✅ Schema: `SailTokenBalance` entity added to `schema.graphql`

## ⚠️ Action Required: Fix subgraph.yaml

The `subgraph.yaml` file has structural issues. Here's the **simplest way to fix it**:

### Option 1: Manual Edit (Recommended)

1. Open `/Users/andrewyoung/Harbor-App/harbor-app/subgraph/subgraph.yaml`
2. Find the `HaToken_haPB` data source (around line 40-60)
3. After the line `file: ./src/haToken.ts`, add a blank line
4. Insert this exact block (with proper 2-space indentation):

```yaml
  # Static data source for hsPB token (sail token)
  - kind: ethereum
    name: SailToken_hsPB
    network: anvil
    source:
      address: "0x367761085BF3C12e5DA2Df99AC6E1a824612b8fb"
      abi: ERC20
      startBlock: 93
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

5. **Remove any duplicate** `SailToken_hsPB` entries elsewhere in the file
6. Save the file

### Option 2: Use Backup and Re-add

If the file is too corrupted:

```bash
cd /Users/andrewyoung/Harbor-App/harbor-app/subgraph
# Make a backup
cp subgraph.yaml subgraph.yaml.backup

# Remove all sail token references
grep -v "SailToken_hsPB" subgraph.yaml > subgraph.yaml.tmp
mv subgraph.yaml.tmp subgraph.yaml

# Then manually add the sail token block after HaToken_haPB (see Option 1)
```

## After Fixing YAML

### Step 1: Run Codegen

```bash
cd /Users/andrewyoung/Harbor-App/harbor-app/subgraph
yarn codegen
```

**Expected**: Should generate types without errors

### Step 2: Build

```bash
yarn build
```

**Expected**: Should compile successfully

### Step 3: Deploy

```bash
graph deploy --node http://localhost:8020/ --ipfs http://localhost:5001 harbor-marks-local --version-label v1.1.0
```

## Verification

After deployment, test:

```graphql
{
  sailTokenBalances(where: {user: "0xae7dbb17bc40d53a6363409c6b1ed88d3cfdc31e"}) {
    id
    balance
    balanceUSD
    accumulatedMarks
    marksPerDay
  }
}
```

## Summary

- ✅ Handler: `src/sailToken.ts` - **DONE**
- ✅ Schema: `SailTokenBalance` entity - **DONE**  
- ⚠️ YAML: Needs manual fix - **ACTION REQUIRED**

The YAML file needs careful manual editing to ensure proper structure. Once fixed, codegen → build → deploy should work.



