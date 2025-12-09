# Frontend: Sail Token Marks - Quick Reference

## 🎯 Key Points

- **Sail tokens earn 5x marks** compared to ha tokens (5 marks per dollar per day vs 1 mark per dollar per day)
- **`marksPerDay` already includes the 5x multiplier** - don't multiply again!
- **Same zero-gas estimation approach** as ha tokens
- **Real-time updates** every second on frontend (zero gas)

## 📋 Implementation Checklist

### Step 1: Types
```typescript
interface SailTokenBalance {
  id: string;
  tokenAddress: string;
  balance: string;
  balanceUSD: string;
  accumulatedMarks: string;
  marksPerDay: string; // Already includes 5x multiplier!
  lastUpdated: string;
}
```

### Step 2: GraphQL Query
```graphql
query GetSailTokenMarks($userAddress: Bytes!) {
  sailTokenBalances(where: { user: $userAddress }) {
    accumulatedMarks
    marksPerDay
    balanceUSD
    lastUpdated
  }
}
```

### Step 3: Estimation Function
```typescript
function calculateEstimatedSailMarks(balance: SailTokenBalance): number {
  const storedMarks = parseFloat(balance.accumulatedMarks || "0");
  const marksPerDay = parseFloat(balance.marksPerDay || "0"); // Already 5x!
  const lastUpdated = parseInt(balance.lastUpdated || "0");
  
  if (lastUpdated === 0 || marksPerDay === 0) return storedMarks;
  
  const now = Math.floor(Date.now() / 1000);
  const daysSinceUpdate = (now - lastUpdated) / 86400;
  
  return storedMarks + (marksPerDay * daysSinceUpdate);
}
```

### Step 4: React Hook
```typescript
function useSailTokenMarks(userAddress: string | null) {
  const [balances, setBalances] = useState<SailTokenBalance[]>([]);
  const [estimatedMarks, setEstimatedMarks] = useState(0);
  
  // Fetch every 60s, estimate every 1s
  // ... (see full implementation guide)
  
  return { balances, estimatedMarks, marksPerDay, loading, error };
}
```

### Step 5: Update Combined Marks
```typescript
const totalMarks = haMarks + sailMarks + poolMarks + genesisMarks;
```

## 🔢 Expected Values

**User holds 100,000 sail tokens worth $100,000:**
- Marks per day: **500,000 marks/day** (5x multiplier)
- After 1 day: **500,000 marks**
- After 2 days: **1,000,000 marks**

## ⚠️ Common Mistakes

1. ❌ **Don't multiply `marksPerDay` by 5** - it's already included!
2. ❌ **Don't forget to use lowercase addresses** in GraphQL queries
3. ❌ **Don't poll too frequently** - 60s is enough for events
4. ✅ **Do use real-time estimation** - update every 1s for smooth UX

## 📊 Example Calculation

```
Balance: $100,000 sail tokens
Multiplier: 5x (default)
Rate: 5 marks per dollar per day
Marks per day: $100,000 × 5 = 500,000 marks/day
```

## 🔍 Verification

After implementation, verify:
- [ ] Sail token balances fetch correctly
- [ ] Estimated marks update every second
- [ ] Marks per day = balanceUSD × 5 (approximately)
- [ ] Total marks includes sail token marks
- [ ] No console errors

## 📚 Full Documentation

See `FRONTEND-SAIL-TOKEN-IMPLEMENTATION.md` for complete step-by-step guide with code examples.



