# Minter Fee Structure Summary

## Overview

The Minter contract uses a **health-based fee structure** that dynamically adjusts fees based on the current collateral ratio. This incentivizes actions that improve system health and discourages actions that worsen it.

## Token Types

- **ha tokens** = Anchor (Pegged) Tokens
- **hs tokens** = Sail (Leveraged) Tokens

## Fee Structure by Collateral Ratio

### 1. Mint Anchor (ha) Tokens

| Collateral Ratio | Fee | Effect |
|-----------------|-----|--------|
| < 1.0x | **100% (BLOCKED)** | ❌ Cannot mint - system undercollateralized |
| 1.0x - 1.05x | **50%** | Very expensive - system at risk |
| 1.05x - 1.1x | **20%** | High fee - system stressed |
| 1.1x - 1.2x | **10%** | Medium fee - system recovering |
| 1.2x - 1.3x | **5%** | Low fee - system healthy |
| 1.3x - 1.5x | **2%** | Very low fee - system very healthy |
| 1.5x - 2.0x | **1%** | Minimal fee - system extremely healthy |
| > 2.0x | **0.5%** | Minimal fee - system overcollateralized |

**Rationale**: Discourages minting when system is unhealthy to prevent further stress.

---

### 2. Redeem Anchor (ha) Tokens

| Collateral Ratio | Fee/Discount | Effect |
|-----------------|--------------|--------|
| < 1.0x | **-10% (Discount)** | ✅ You get 10% bonus - strongly encouraged |
| 1.0x - 1.05x | **-5% (Discount)** | ✅ You get 5% bonus - encouraged |
| 1.05x - 1.1x | **0% (FREE)** | ✅ No fee - system needs help |
| 1.1x - 1.2x | **1%** | Low fee - system recovering |
| 1.2x - 1.3x | **2%** | Small fee - system healthy |
| 1.3x - 1.5x | **3%** | Moderate fee - system very healthy |
| 1.5x - 2.0x | **4%** | Higher fee - system extremely healthy |
| > 2.0x | **5%** | Standard fee - system overcollateralized |

**Rationale**: Encourages redemption when system is unhealthy (improves collateral ratio).

---

### 3. Mint Sail (hs) Tokens

| Collateral Ratio | Fee/Discount | Effect |
|-----------------|--------------|--------|
| < 1.0x | **-15% (Discount)** | ✅ You get 15% bonus - strongly encouraged |
| 1.0x - 1.05x | **-10% (Discount)** | ✅ You get 10% bonus - encouraged |
| 1.05x - 1.1x | **-5% (Discount)** | ✅ You get 5% bonus - small incentive |
| 1.1x - 1.2x | **-2% (Discount)** | ✅ You get 2% bonus - minimal incentive |
| 1.2x - 1.3x | **0% (FREE)** | ✅ No fee - system healthy |
| 1.3x - 1.5x | **1%** | Small fee - system very healthy |
| 1.5x - 2.0x | **2%** | Moderate fee - system extremely healthy |
| > 2.0x | **3%** | Standard fee - system overcollateralized |

**Rationale**: Encourages minting when system is unhealthy (increases leverage, improves collateral ratio).

---

### 4. Redeem Sail (hs) Tokens

| Collateral Ratio | Fee | Effect |
|-----------------|-----|--------|
| < 1.0x | **100% (BLOCKED)** | ❌ Cannot redeem - would worsen system health |
| 1.0x - 1.05x | **30%** | Very expensive - system at risk |
| 1.05x - 1.1x | **15%** | High fee - system stressed |
| 1.1x - 1.2x | **8%** | Medium-high fee - system recovering |
| 1.2x - 1.3x | **5%** | Medium fee - system healthy |
| 1.3x - 1.5x | **3%** | Low fee - system very healthy |
| 1.5x - 2.0x | **2%** | Very low fee - system extremely healthy |
| > 2.0x | **1.5%** | Minimal fee - system overcollateralized |

**Rationale**: Discourages redemption when system is unhealthy (reduces leverage, worsens collateral ratio).

---

## Example Scenarios

### Scenario 1: System at 1.05x (Stressed)
- **Mint ha**: 20% fee (expensive)
- **Redeem ha**: -5% discount (you get 5% bonus)
- **Mint hs**: -10% discount (you get 10% bonus)
- **Redeem hs**: 30% fee (very expensive)

### Scenario 2: System at 1.25x (Healthy)
- **Mint ha**: 5% fee (reasonable)
- **Redeem ha**: 2% fee (normal)
- **Mint hs**: -2% discount (you get 2% bonus)
- **Redeem hs**: 5% fee (normal)

### Scenario 3: System at 0.98x (Undercollateralized)
- **Mint ha**: BLOCKED ❌
- **Redeem ha**: -10% discount (you get 10% bonus)
- **Mint hs**: -15% discount (you get 15% bonus)
- **Redeem hs**: BLOCKED ❌

### Scenario 4: System at 2.0x (Overcollateralized)
- **Mint ha**: 0.5% fee (minimal)
- **Redeem ha**: 5% fee (standard)
- **Mint hs**: 3% fee (standard)
- **Redeem hs**: 1.5% fee (minimal)

---

## How Fees Work

### Positive Values = Fees
- `0.05e18` = 5% fee
- `1.0e18` = 100% fee = BLOCKED

### Negative Values = Discounts
- `-0.1e18` = -10% discount (you get 10% bonus)
- `-0.15e18` = -15% discount (you get 15% bonus)

### Zero = Free
- `0` = No fee, no discount

---

## Key Principles

1. **Minting ha tokens**: Discouraged when unhealthy (expensive fees)
2. **Redeeming ha tokens**: Encouraged when unhealthy (discounts/free)
3. **Minting hs tokens**: Encouraged when unhealthy (discounts)
4. **Redeeming hs tokens**: Discouraged when unhealthy (expensive fees/blocked)

---

## Configuration Files

- **Config JSON**: `script/minter-fee-config-health-based.json`
- **Forge Script**: `script/UpdateMinterFees.s.sol`
- **Helper Script**: `script/apply-fee-config.sh`
- **Full Documentation**: `FEE-STRUCTURE-DESIGN.md`

---

## Notes

- Fees are calculated dynamically based on the current collateral ratio
- The system uses bands to determine which fee applies
- Only the contract owner can update the config
- Fees are applied at the time of transaction execution



