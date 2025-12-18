# Harbor Protocol - Comprehensive User Testing Plan

This document provides a detailed testing plan covering all user-facing features of the Harbor protocol from an end-user perspective.

## Testing Overview

### Test Environment Setup
- **Network**: Local Anvil (or testnet)
- **Test Accounts**: 
  - Primary user account (with funds)
  - Secondary user account (for multi-user scenarios)
  - Admin/owner account (for governance actions)
- **Initial State**: Clean deployment with Genesis ended, tokens available

### Testing Principles
1. **User Journey Focus**: Test complete workflows, not just individual features
2. **Real-World Scenarios**: Test common use cases and edge cases
3. **Error Handling**: Verify graceful error messages and recovery
4. **UI/UX Validation**: Check clarity, feedback, and user guidance
5. **Data Accuracy**: Verify all displayed data matches on-chain state

---

## Phase 1: Initial Setup & Discovery

### 1.1 Wallet Connection
**Objective**: Verify wallet connection works correctly

**Test Steps**:
1. Open Harbor app
2. Click "Connect Wallet"
3. Select wallet provider (MetaMask, WalletConnect, etc.)
4. Approve connection
5. Verify wallet address displays correctly
6. Check wallet balance is shown

**Expected Results**:
- ✅ Wallet connects successfully
- ✅ User address displays in header/nav
- ✅ Balance shows correct amount
- ✅ Network matches expected (local/testnet/mainnet)

**Edge Cases**:
- Wrong network selected → Shows network switch prompt
- Wallet disconnected → Shows reconnection prompt
- Insufficient balance → Shows appropriate message

---

### 1.2 Dashboard Overview
**Objective**: Verify main dashboard displays correctly

**Test Steps**:
1. After connecting, view main dashboard
2. Check all key metrics display:
   - Collateral ratio
   - Total TVL
   - Stability pool sizes
   - Volatility risk indicator
3. Verify market selector (if multiple markets)
4. Check navigation menu works

**Expected Results**:
- ✅ All metrics display with correct values
- ✅ Market selector shows available markets
- ✅ Navigation is intuitive
- ✅ Data refreshes appropriately

**Edge Cases**:
- No data available → Shows "No data" or loading state
- Network error → Shows error message with retry option

---

## Phase 2: Genesis Phase (If Applicable)

### 2.1 View Genesis Status
**Objective**: Verify Genesis phase information displays

**Test Steps**:
1. Navigate to Genesis page
2. Check if Genesis is active or ended
3. View Genesis details:
   - Total deposits
   - Time remaining (if active)
   - Claimable tokens (if ended)
4. Check token allocation breakdown

**Expected Results**:
- ✅ Genesis status clearly displayed
- ✅ All relevant information visible
- ✅ Claim button available if Genesis ended
- ✅ Historical data accurate

---

### 2.2 Genesis Deposit (If Active)
**Objective**: Test depositing to Genesis

**Test Steps**:
1. Navigate to Genesis page
2. Enter deposit amount
3. Check displayed:
   - Expected ha token allocation
   - Expected hs token allocation
   - Fee (if any)
4. Approve token spending
5. Submit deposit transaction
6. Wait for confirmation
7. Verify deposit appears in "My Deposits"

**Expected Results**:
- ✅ Deposit amount validation works
- ✅ Expected allocations calculated correctly
- ✅ Transaction succeeds
- ✅ Deposit reflected in UI immediately
- ✅ Balance updates correctly

**Edge Cases**:
- Amount below minimum → Shows error
- Amount exceeds balance → Shows insufficient funds
- Transaction fails → Shows error with reason
- Genesis ends during deposit → Handles gracefully

---

### 2.3 Genesis Claim (If Ended)
**Objective**: Test claiming Genesis tokens

**Test Steps**:
1. Navigate to Genesis page
2. View claimable tokens:
   - ha tokens claimable
   - hs tokens claimable
3. Click "Claim" button
4. Approve transaction
5. Wait for confirmation
6. Verify tokens received in wallet

**Expected Results**:
- ✅ Claimable amounts accurate
- ✅ Claim transaction succeeds
- ✅ Tokens appear in wallet
- ✅ UI updates to show claimed status

---

## Phase 3: Minting Tokens

### 3.1 Mint Pegged Token (haPB)
**Objective**: Test minting anchor tokens

**Test Steps**:
1. Navigate to "Mint" page
2. Select "Mint Anchor Token (haPB)"
3. Enter collateral amount (e.g., 1 wstETH)
4. Review displayed information:
   - Expected ha tokens to receive
   - Current fee percentage
   - Fee amount in USD
   - Collateral ratio impact
5. Check fee explanation (why fee is this amount)
6. Approve collateral token spending
7. Submit mint transaction
8. Wait for confirmation
9. Verify:
   - ha tokens received in wallet
   - Balance updated
   - Transaction history updated

**Expected Results**:
- ✅ Fee calculation accurate
- ✅ Expected tokens match received amount
- ✅ Fee explanation clear
- ✅ Transaction succeeds
- ✅ UI updates immediately

**Edge Cases**:
- Amount below minimum → Shows error
- Insufficient balance → Shows error
- Fee too high (system unhealthy) → Shows warning
- Transaction fails → Shows error with reason
- Slippage protection → Handles if needed

**Test Different Collateral Ratios**:
- Test when system is healthy (low fee)
- Test when system is stressed (high fee)
- Test when system is at risk (very high fee)
- Verify fee changes appropriately

---

### 3.2 Mint Leveraged Token (hsPB)
**Objective**: Test minting sail tokens

**Test Steps**:
1. Navigate to "Mint" page
2. Select "Mint Sail Token (hsPB)"
3. Enter collateral amount
4. Review displayed information:
   - Expected hs tokens to receive
   - Current fee/discount
   - Leverage ratio impact
   - Collateral ratio impact
5. Approve collateral token spending
6. Submit mint transaction
7. Wait for confirmation
8. Verify hs tokens received

**Expected Results**:
- ✅ Discount shown when system unhealthy (negative fee)
- ✅ Fee shown when system healthy
- ✅ Leverage impact explained
- ✅ Transaction succeeds

**Edge Cases**:
- System very unhealthy → Shows discount (negative fee)
- System healthy → Shows normal fee
- Maximum leverage reached → Shows error

---

## Phase 4: Stability Pool Deposits

### 4.1 View Stability Pools
**Objective**: Verify stability pool information displays

**Test Steps**:
1. Navigate to "Stability Pools" page
2. View both pools:
   - Collateral Pool
   - Leveraged Pool
3. Check displayed metrics for each:
   - Total TVL
   - Current APR
   - Reward tokens available
   - Number of depositors
4. Compare pools side-by-side

**Expected Results**:
- ✅ Both pools visible
- ✅ All metrics accurate
- ✅ APR calculations correct
- ✅ Reward tokens listed

---

### 4.2 Deposit to Collateral Pool
**Objective**: Test depositing ha tokens to stability pool

**Test Steps**:
1. Navigate to Collateral Pool
2. Click "Deposit"
3. Enter deposit amount (e.g., 100 ha tokens)
4. Review displayed information:
   - Minimum deposit requirement
   - Expected rewards (APR)
   - Reward tokens you'll earn
   - Withdrawal terms (delay, fees)
5. Approve ha token spending
6. Submit deposit transaction
7. Wait for confirmation
8. Verify:
   - Deposit appears in "My Positions"
   - Balance updated
   - Rewards section shows pending rewards

**Expected Results**:
- ✅ Deposit succeeds
- ✅ Position appears immediately
- ✅ Rewards start accruing
- ✅ Withdrawal terms clearly explained

**Edge Cases**:
- Amount below minimum → Shows error
- Insufficient balance → Shows error
- First deposit (pool empty) → Handles correctly
- Pool at capacity → Shows appropriate message

---

### 4.3 Deposit to Leveraged Pool
**Objective**: Test depositing to leveraged pool

**Test Steps**:
1. Navigate to Leveraged Pool
2. Follow same steps as Collateral Pool
3. Verify different reward structure (if applicable)
4. Check leverage ratio impact

**Expected Results**:
- ✅ Deposit succeeds
- ✅ Position tracked separately
- ✅ Rewards calculated correctly

---

### 4.4 View Stability Pool Position
**Objective**: Verify position details display correctly

**Test Steps**:
1. Navigate to "My Positions" or pool detail page
2. View position information:
   - Deposited amount
   - Current value (USD)
   - Claimable rewards (by token)
   - Total rewards earned
   - APR breakdown
3. Check reward tokens:
   - List of all reward tokens
   - Claimable amount for each
   - USD value of claimable
4. Verify historical data:
   - Deposit history
   - Reward accrual over time

**Expected Results**:
- ✅ All position data accurate
- ✅ Rewards update in real-time
- ✅ Historical data available
- ✅ USD values calculated correctly

---

## Phase 5: Rewards & Claiming

### 5.1 View Claimable Rewards
**Objective**: Verify rewards display correctly

**Test Steps**:
1. Navigate to rewards section
2. View claimable rewards:
   - Total claimable value (USD)
   - Breakdown by reward token
   - Individual token amounts
   - USD value per token
3. Check reward sources:
   - Harvest rewards
   - Liquidation rewards (if any)
4. Verify APR display:
   - Current APR
   - Projected APR
   - APR breakdown by reward token

**Expected Results**:
- ✅ Claimable amounts accurate
- ✅ All reward tokens listed
- ✅ USD values correct
- ✅ APR calculations reasonable

**Edge Cases**:
- No rewards yet → Shows "No rewards" or "0.00"
- Rewards vesting → Shows vesting progress
- Multiple reward tokens → All displayed correctly

---

### 5.2 Claim Rewards
**Objective**: Test claiming rewards

**Test Steps**:
1. Navigate to rewards section
2. View claimable rewards
3. Click "Claim" button
4. Review transaction details:
   - Tokens to receive
   - Amounts per token
   - Gas estimate
5. Approve transaction
6. Wait for confirmation
7. Verify:
   - Tokens received in wallet
   - Claimable amount reset
   - Transaction history updated

**Expected Results**:
- ✅ Claim succeeds
- ✅ All reward tokens received
- ✅ Amounts match displayed
- ✅ UI updates immediately

**Edge Cases**:
- No claimable rewards → Button disabled
- Partial claim → Handles correctly
- Claim fails → Shows error
- Multiple reward tokens → All claimed

---

### 5.3 Reward Vesting Display
**Objective**: Verify vesting information displays

**Test Steps**:
1. After deposit, view rewards section
2. Check vesting information:
   - Time until next claimable amount
   - Vesting progress bar
   - Estimated full vesting time
3. Wait for time to pass (or advance blocks)
4. Verify claimable amount increases

**Expected Results**:
- ✅ Vesting progress visible
- ✅ Time remaining accurate
- ✅ Claimable updates over time
- ✅ Visual feedback clear

---

## Phase 6: Withdrawals

### 6.1 Request Withdrawal
**Objective**: Test withdrawal request mechanism

**Test Steps**:
1. Navigate to stability pool position
2. Click "Withdraw" or "Request Withdrawal"
3. Enter withdrawal amount
4. Review withdrawal information:
   - Current withdrawal request status
   - Early withdrawal fee (if applicable)
   - Withdrawal window timing
   - Fee-free window explanation
5. Submit withdrawal request
6. Wait for confirmation
7. Verify:
   - Withdrawal request appears
   - Timer shows time until withdrawal window
   - Fee information displayed

**Expected Results**:
- ✅ Withdrawal request succeeds
- ✅ Timer accurate
- ✅ Fee information clear
- ✅ Window timing explained

**Edge Cases**:
- Amount exceeds balance → Shows error
- Already has withdrawal request → Shows existing request
- Within fee-free window → Shows no fee
- Outside window → Shows fee amount

---

### 6.2 Wait for Withdrawal Window
**Objective**: Test waiting period

**Test Steps**:
1. After requesting withdrawal, wait for window
2. Monitor countdown timer
3. Check fee-free window timing:
   - Start time
   - End time
   - Current status
4. Verify UI updates as time passes

**Expected Results**:
- ✅ Timer counts down correctly
- ✅ Window status updates
- ✅ Fee information updates
- ✅ User can see when fee-free window starts

---

### 6.3 Execute Withdrawal
**Objective**: Test completing withdrawal

**Test Steps**:
1. Wait for withdrawal window (or test with early withdrawal)
2. Navigate to withdrawal request
3. Click "Withdraw" or "Complete Withdrawal"
4. Review:
   - Amount to receive
   - Fee (if early)
   - Expected tokens
5. Submit withdrawal transaction
6. Wait for confirmation
7. Verify:
   - Tokens received in wallet
   - Position updated
   - Withdrawal request cleared

**Expected Results**:
- ✅ Withdrawal succeeds
- ✅ Correct amount received
- ✅ Fee deducted (if early)
- ✅ Position updated

**Edge Cases**:
- Early withdrawal → Fee applied correctly
- Within window → No fee
- After window → Fee applied
- Partial withdrawal → Handles correctly

---

### 6.4 Cancel Withdrawal Request
**Objective**: Test canceling withdrawal request

**Test Steps**:
1. After requesting withdrawal
2. Click "Cancel Withdrawal Request"
3. Confirm cancellation
4. Submit transaction
5. Verify request canceled

**Expected Results**:
- ✅ Cancellation succeeds
- ✅ Request removed
- ✅ Can deposit again

---

## Phase 7: Redemptions

### 7.1 Redeem Pegged Token (haPB)
**Objective**: Test redeeming ha tokens for collateral

**Test Steps**:
1. Navigate to "Redeem" page
2. Select "Redeem Anchor Token (haPB)"
3. Enter amount to redeem
4. Review displayed information:
   - Expected collateral to receive
   - Current fee/discount
   - Collateral ratio impact
   - Why fee is this amount
5. Approve ha token spending
6. Submit redemption transaction
7. Wait for confirmation
8. Verify collateral received

**Expected Results**:
- ✅ Redemption succeeds
- ✅ Discount shown when system unhealthy
- ✅ Fee shown when system healthy
- ✅ Amount received matches expected

**Edge Cases**:
- System unhealthy → Shows discount (negative fee)
- System healthy → Shows normal fee
- Insufficient balance → Shows error
- Slippage protection → Handles if needed

---

### 7.2 Redeem Leveraged Token (hsPB)
**Objective**: Test redeeming hs tokens

**Test Steps**:
1. Navigate to "Redeem" page
2. Select "Redeem Sail Token (hsPB)"
3. Enter amount to redeem
4. Review fee information
5. Submit redemption
6. Verify collateral received

**Expected Results**:
- ✅ Redemption succeeds
- ✅ Fee structure appropriate
- ✅ Amount correct

---

## Phase 8: Viewing Data & Analytics

### 8.1 Collateral Ratio Display
**Objective**: Verify collateral ratio information

**Test Steps**:
1. Navigate to dashboard or market page
2. View collateral ratio:
   - Current ratio
   - Minimum ratio
   - Rebalance threshold
   - Health indicator
3. Check visual indicators:
   - Health status (healthy/warning/critical)
   - Color coding
   - Progress bars
4. Verify tooltips/explanations

**Expected Results**:
- ✅ Ratio accurate
- ✅ Visual indicators clear
- ✅ Explanations helpful
- ✅ Updates in real-time

---

### 8.2 Volatility Risk Display
**Objective**: Verify volatility risk indicator

**Test Steps**:
1. Navigate to market page
2. View volatility risk indicator
3. Check displayed information:
   - Price drop needed to drain pools
   - Current safety margin
   - Historical context
4. Verify calculation accuracy

**Expected Results**:
- ✅ Risk indicator visible
- ✅ Calculation accurate
- ✅ Context provided
- ✅ Updates with pool changes

---

### 8.3 Token Prices & Values
**Objective**: Verify price displays

**Test Steps**:
1. Check all token price displays:
   - ha token price (should be ~$1)
   - hs token price (variable)
   - Collateral price (wstETH/stETH)
2. Verify USD conversions
3. Check price sources displayed
4. Verify price updates

**Expected Results**:
- ✅ Prices accurate
- ✅ USD conversions correct
- ✅ Price sources visible
- ✅ Updates appropriately

---

### 8.4 Transaction History
**Objective**: Verify transaction history

**Test Steps**:
1. Navigate to "History" or "Transactions"
2. View transaction list:
   - All transactions
   - Filter by type
   - Sort by date
3. Check transaction details:
   - Type (mint, redeem, deposit, withdraw, claim)
   - Amounts
   - Timestamp
   - Transaction hash
   - Status
4. Verify links to block explorer

**Expected Results**:
- ✅ All transactions listed
- ✅ Details accurate
- ✅ Filters work
- ✅ Explorer links work

---

## Phase 9: Error Handling & Edge Cases

### 9.1 Insufficient Balance
**Objective**: Test handling of insufficient funds

**Test Steps**:
1. Try to mint with insufficient balance
2. Try to deposit with insufficient balance
3. Try to redeem more than owned
4. Verify error messages

**Expected Results**:
- ✅ Clear error messages
- ✅ Suggests solutions
- ✅ Prevents invalid transactions

---

### 9.2 Network Issues
**Objective**: Test network error handling

**Test Steps**:
1. Disconnect network
2. Try to perform action
3. Reconnect network
4. Verify recovery

**Expected Results**:
- ✅ Shows network error
- ✅ Retry option available
- ✅ Recovers when reconnected

---

### 9.3 Transaction Failures
**Objective**: Test transaction failure handling

**Test Steps**:
1. Cause transaction to fail (e.g., slippage, revert)
2. Verify error message
3. Check if state is preserved
4. Verify can retry

**Expected Results**:
- ✅ Error message clear
- ✅ Reason provided
- ✅ State not corrupted
- ✅ Can retry

---

### 9.4 Slippage Protection
**Objective**: Test slippage handling

**Test Steps**:
1. Set very low slippage tolerance
2. Try to mint/redeem
3. Verify transaction fails if slippage too high
4. Adjust slippage and retry

**Expected Results**:
- ✅ Slippage protection works
- ✅ Clear error if exceeded
- ✅ Can adjust and retry

---

### 9.5 System Health Changes
**Objective**: Test UI updates when system health changes

**Test Steps**:
1. Perform action that changes collateral ratio
2. Verify UI updates:
   - Fee changes
   - Health indicator updates
   - Warnings appear (if needed)
3. Check all dependent displays update

**Expected Results**:
- ✅ UI updates immediately
- ✅ Fee changes reflected
- ✅ Health indicators accurate
- ✅ Warnings appropriate

---

## Phase 10: Multi-User Scenarios

### 10.1 Multiple Depositors
**Objective**: Test with multiple users

**Test Steps**:
1. User 1 deposits to pool
2. User 2 deposits to pool
3. Verify both positions tracked separately
4. Check rewards distributed proportionally
5. Verify each user sees only their data

**Expected Results**:
- ✅ Positions separate
- ✅ Rewards proportional
- ✅ Privacy maintained
- ✅ No data leakage

---

### 10.2 Pool Dynamics
**Objective**: Test pool behavior with multiple users

**Test Steps**:
1. Multiple users deposit
2. One user withdraws
3. Verify:
   - Other users' positions unaffected
   - Rewards recalculate correctly
   - Pool TVL updates
   - APR adjusts

**Expected Results**:
- ✅ Withdrawal doesn't affect others
- ✅ Rewards recalculate
- ✅ Metrics update correctly

---

## Phase 11: Advanced Features

### 11.1 Rebalancing
**Objective**: Test rebalancing display and impact

**Test Steps**:
1. Monitor system approaching rebalance threshold
2. Verify warnings/alerts appear
3. Trigger rebalance (or wait for it)
4. Check:
   - Rebalance notification
   - Impact on positions
   - Liquidation rewards distributed
   - System health after rebalance

**Expected Results**:
- ✅ Warnings before rebalance
- ✅ Rebalance notification clear
- ✅ Rewards distributed correctly
- ✅ System health improves

---

### 11.2 Harvest
**Objective**: Test harvest display

**Test Steps**:
1. Monitor harvestable amount
2. Check if harvest is available
3. View harvest information:
   - Harvestable amount
   - Expected distribution
   - Bounty and cut amounts
4. After harvest, verify:
   - Rewards deposited to pools
   - APR updates
   - Claimable amounts increase

**Expected Results**:
- ✅ Harvest info accurate
- ✅ Rewards distributed correctly
- ✅ APR updates
- ✅ Users benefit from harvest

---

## Phase 12: Mobile & Responsive Design

### 12.1 Mobile View
**Objective**: Test mobile responsiveness

**Test Steps**:
1. Open app on mobile device/browser
2. Test all major features:
   - Wallet connection
   - Deposits
   - Withdrawals
   - Rewards claiming
3. Verify:
   - Layout is usable
   - Buttons accessible
   - Data readable
   - Navigation works

**Expected Results**:
- ✅ Mobile layout functional
- ✅ All features accessible
- ✅ No horizontal scrolling
- ✅ Touch targets adequate

---

### 12.2 Tablet View
**Objective**: Test tablet layout

**Test Steps**:
1. Open app on tablet
2. Verify layout adapts
3. Check all features work

**Expected Results**:
- ✅ Tablet layout optimized
- ✅ Features accessible

---

## Phase 13: Performance & Loading

### 13.1 Loading States
**Objective**: Test loading indicators

**Test Steps**:
1. Perform slow operations
2. Verify loading indicators appear
3. Check loading messages are helpful
4. Verify data loads correctly

**Expected Results**:
- ✅ Loading indicators visible
- ✅ Messages helpful
- ✅ No blank screens

---

### 13.2 Data Refresh
**Objective**: Test data update frequency

**Test Steps**:
1. Perform on-chain action
2. Verify UI updates:
   - Immediately after transaction
   - After block confirmation
   - On periodic refresh
3. Check update frequency is reasonable

**Expected Results**:
- ✅ Updates promptly
- ✅ Not too frequent (performance)
- ✅ Not too slow (stale data)

---

## Phase 14: Documentation & Help

### 14.1 Tooltips & Help Text
**Objective**: Verify help information

**Test Steps**:
1. Check all tooltips (?) icons
2. Verify explanations are:
   - Clear
   - Accurate
   - Helpful
3. Test help documentation links

**Expected Results**:
- ✅ Tooltips present
- ✅ Explanations clear
- ✅ Documentation accessible

---

### 14.2 Error Messages
**Objective**: Verify error messages are helpful

**Test Steps**:
1. Trigger various errors
2. Verify error messages:
   - Explain what went wrong
   - Suggest solutions
   - Are user-friendly
3. Check error recovery options

**Expected Results**:
- ✅ Errors clear
- ✅ Solutions suggested
- ✅ Recovery possible

---

## Phase 15: Security & Permissions

### 15.1 Transaction Approvals
**Objective**: Test approval flows

**Test Steps**:
1. Perform actions requiring approvals
2. Verify:
   - Approval prompts clear
   - Can approve exact amount
   - Can revoke approvals
   - Approval status displayed

**Expected Results**:
- ✅ Approvals work correctly
- ✅ Can manage approvals
- ✅ Status visible

---

### 15.2 Read-Only Operations
**Objective**: Test operations that don't require transactions

**Test Steps**:
1. View all read-only data:
   - Positions
   - Rewards
   - Market data
   - History
2. Verify no unnecessary transactions
3. Check data accuracy

**Expected Results**:
- ✅ Read operations work
- ✅ No unnecessary transactions
- ✅ Data accurate

---

## Testing Checklist Summary

### Critical Paths (Must Work)
- [ ] Wallet connection
- [ ] Mint pegged token
- [ ] Mint leveraged token
- [ ] Deposit to stability pool
- [ ] View rewards
- [ ] Claim rewards
- [ ] Request withdrawal
- [ ] Complete withdrawal
- [ ] Redeem tokens
- [ ] View positions

### Important Features (Should Work)
- [ ] Genesis deposit/claim
- [ ] Cancel withdrawal request
- [ ] Transaction history
- [ ] Collateral ratio display
- [ ] Volatility risk indicator
- [ ] APR calculations
- [ ] Fee explanations

### Edge Cases (Nice to Have)
- [ ] Error handling
- [ ] Network issues
- [ ] Slippage protection
- [ ] System health changes
- [ ] Multi-user scenarios

### Polish (Quality of Life)
- [ ] Mobile responsiveness
- [ ] Loading states
- [ ] Tooltips
- [ ] Error messages
- [ ] Performance

---

## Testing Schedule

### Week 1: Core Functionality
- Days 1-2: Setup, wallet, dashboard
- Days 3-4: Minting and redemptions
- Day 5: Stability pool deposits

### Week 2: Rewards & Withdrawals
- Days 1-2: Rewards viewing and claiming
- Days 3-4: Withdrawal requests and execution
- Day 5: Edge cases and error handling

### Week 3: Advanced & Polish
- Days 1-2: Multi-user scenarios, rebalancing
- Days 3-4: Mobile, performance, documentation
- Day 5: Final review and bug fixes

---

## Success Criteria

### Functional
- ✅ All critical paths work end-to-end
- ✅ No data inconsistencies
- ✅ Transactions succeed when they should
- ✅ Errors handled gracefully

### User Experience
- ✅ Interface is intuitive
- ✅ Feedback is clear
- ✅ Loading states appropriate
- ✅ Error messages helpful

### Performance
- ✅ Page loads < 3 seconds
- ✅ Transactions submit promptly
- ✅ Data updates within 5 seconds
- ✅ No unnecessary re-renders

### Security
- ✅ No unauthorized access
- ✅ Approvals work correctly
- ✅ Read operations don't require transactions
- ✅ User data privacy maintained

---

## Reporting Template

For each test:
- **Test ID**: [Unique identifier]
- **Feature**: [Feature name]
- **Steps**: [What was tested]
- **Expected**: [What should happen]
- **Actual**: [What actually happened]
- **Status**: [Pass/Fail/Blocked]
- **Notes**: [Additional observations]
- **Screenshots**: [If applicable]
- **Severity**: [Critical/High/Medium/Low]

---

## Notes

- Test with real transactions on testnet/local
- Document all bugs with steps to reproduce
- Test with different account balances
- Test with different system health states
- Verify all calculations match on-chain data
- Test error recovery flows
- Verify mobile experience
- Check browser console for errors
- Monitor gas usage
- Verify transaction confirmations

---

*This testing plan should be executed systematically, with results documented for each phase. Adjust based on actual app features and priorities.*



