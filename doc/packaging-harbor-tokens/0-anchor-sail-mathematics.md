# Harbor Anchor-Sail Token Mathematics

**Date:** 2026-02-15
**Purpose:** Mathematical foundation for all Harbor token products

---

## 1. Core System Invariant

### 1.1 Fundamental Equation

```
C = A + S

Where:
C = Total collateral value (in peg terms, e.g., wstETH priced in USD)
A = Total anchored token value (always ≈ 1 USD per token × supply)
S = Total sail token value (residual)
```

**Invariant property:** This equation always holds. The total collateral backing the system equals the sum of anchored and sail token values.

**Proof:** By construction. Anchored tokens are minted 1:1 against collateral, sail tokens represent the residual claim.

---

### 1.2 Collateral Ratio

```
CR = C / A

Typical range: 1.3 to 3.0
- CR < 1.0: System insolvent (impossible by design)
- CR = 1.0: Sail tokens worthless (S = 0)
- CR < 1.3: Rebalancing triggered
- CR > 2.0: System well-collateralized
```

**Relationship to sail value:**
```
S = C - A = A(CR - 1)

∴ Sail value = Anchored value × (CR - 1)
```

---

## 2. Value Functions

### 2.1 Sail Token Value

**Total sail value:**
```
S(C, A) = C - A
```

**Per-token value:**
```
s(C, A, n) = (C - A) / n

Where n = sail token supply
```

**Properties:**
- Linear in C
- Linear in A (negative)
- Inversely proportional to n

---

### 2.2 Leverage Ratio

**Definition:** Effective leverage of sail tokens relative to collateral price movements.

```
L(C, A) = C / (C - A) = C / S = CR / (CR - 1)
```

**Properties:**
- L → ∞ as C → A (approaching wipeout)
- L decreases as C increases (de-leveraging when winning)
- L increases as C decreases (leveraging when losing)

**Typical values:**

| CR | Leverage L |
|----|-----------|
| 1.3 | 4.33x |
| 1.5 | 3.0x |
| 2.0 | 2.0x |
| 3.0 | 1.5x |

---

## 3. Delta Analysis (First-Order Sensitivities)

**Important:** C, A, and S are linked by the invariant C = A + S. You cannot change one independently - all changes occur through specific operations (minting/redeeming). The deltas below show mathematical relationships, but see Section 5 for how they combine in actual operations.

### 3.1 Fundamental Relationships

From the invariant S = C - A, we have:

**Sail value sensitivity to collateral (holding A constant):**
```
∂S/∂C = 1

Interpretation: If collateral increases by $1 and anchored supply stays fixed,
sail value increases by $1.
```

**Sail value sensitivity to anchored supply (holding C constant):**
```
∂S/∂A = -1

Interpretation: If anchored supply increases by $1 and collateral stays fixed,
sail value decreases by $1.
```

**Note:** These are partial derivatives showing mathematical relationships. In practice, you cannot change A without changing C (minting anchored requires depositing collateral). See Section 5 for actual operation effects.

---

### 3.2 Leverage Deltas

**Leverage sensitivity to collateral (holding A constant):**
```
∂L/∂C = ∂(C/S)/∂C = ∂(C/(C-A))/∂C = -A / (C - A)² = -A / S²

Sign: Negative (leverage decreases as collateral increases)

Magnitude: Inversely proportional to S² (larger when sail value is small)
```

**Example calculation:**

C = $100, A = $40, S = $60

```
∂L/∂C = -40 / 60² = -0.0111

Meaning: If C increases by $1 (with A held fixed), leverage decreases by ~0.0111.
At current L = 1.67x, this represents a -0.67% relative change.
```

**Leverage sensitivity to anchored supply (holding C constant):**
```
∂L/∂A = ∂(C/S)/∂A = ∂(C/(C-A))/∂A = C / (C - A)² = C / S²

Sign: Positive (leverage increases as anchored supply increases)
```

**Again:** These show how L changes with C or A individually. Real operations change both simultaneously - see Section 4.

---

## 4. Effects of Token Operations

**Key principle:** You cannot change C, A, or S independently. All changes occur through specific minting/redeeming operations that affect multiple variables simultaneously.

### 4.1 Minting Anchored Tokens

**User deposits ΔC collateral, receives ΔA = ΔC anchored tokens (1:1 backing):**

```
C_new = C + ΔC
A_new = A + ΔC  (since ΔA = ΔC for 1:1 backing)
S_new = C_new - A_new = (C + ΔC) - (A + ΔC) = C - A = S

∴ Sail value UNCHANGED by anchored minting
```

**But leverage changes:**

```
L_old = C / S
L_new = (C + ΔC) / S

ΔL = ΔC / S > 0

Leverage INCREASES!
```

**Intuition:** More collateral backing same sail value → higher effective leverage.

**Example:**

C = $100, A = $40, S = $60, L = 1.67x

User mints $10 anchored:
- C_new = $110, A_new = $50, S_new = $60 (unchanged)
- L_new = 110/60 = 1.83x (leverage increased from 1.67x to 1.83x)

**Sail holders benefit:** Their token value stays same, but effective leverage (and potential upside) increases.

---

### 4.2 Redeeming Anchored Tokens

**User burns ΔA anchored tokens, receives ΔC = ΔA collateral:**

```
C_new = C - ΔC
A_new = A - ΔC
S_new = C_new - A_new = (C - ΔC) - (A - ΔC) = C - A = S

∴ Sail value UNCHANGED
```

**Leverage changes:**

```
L_new = (C - ΔC) / S

ΔL = -ΔC / S < 0

Leverage DECREASES
```

**Example:**

C = $100, A = $40, S = $60, L = 1.67x

User redeems $10 anchored:
- C_new = $90, A_new = $30, S_new = $60 (unchanged)
- L_new = 90/60 = 1.5x (leverage decreased from 1.67x to 1.5x)

**Sail holders harmed:** Effective leverage (upside potential) decreases.

---

### 4.3 Minting Sail Tokens

**User deposits ΔC collateral, receives Δn sail tokens:**

The sail value increases by the deposited collateral:

```
S_new = S + ΔC
C_new = C + ΔC  (collateral added)
A_new = A  (no anchored tokens created)
```

**Fair pricing:** Δn should be set so existing holders' per-token value is preserved:

```
Value per existing token before: s_old = S / n
New shares: Δn = ΔC / s_old = ΔC × n / S

Total supply after: n_new = n + Δn = n + ΔC × n / S = n(S + ΔC)/S

Value per token after: s_new = S_new / n_new
                              = (S + ΔC) / (n(S + ΔC)/S)
                              = S / n
                              = s_old ✓

Fair minting preserves per-token value.
```

**Leverage effect:**

```
L_old = C / S
L_new = (C + ΔC) / (S + ΔC)

For small ΔC:
L_new ≈ L_old × (1 + ΔC/C) / (1 + ΔC/S)
     ≈ L_old × (1 + ΔC/C - ΔC/S)
     = L_old × (1 + ΔC(S - C)/(CS))
     = L_old × (1 - ΔC×A/(CS))

Since A > 0: L_new < L_old

∴ Sail minting DECREASES leverage
```

**Intuition:** Adding more sail value at current prices means less leverage per unit collateral.

---

### 4.4 Redeeming Sail Tokens

**User burns Δn sail tokens, receives ΔC collateral:**

The sail value decreases by the redeemed amount:

```
Fair redemption: ΔC = s_old × Δn = (S/n) × Δn

S_new = S - ΔC = S - S×Δn/n = S(1 - Δn/n)
C_new = C - ΔC  (collateral withdrawn)
A_new = A  (no anchored tokens affected)
n_new = n - Δn = n(1 - Δn/n)

s_new = S_new / n_new = S(1 - Δn/n) / (n(1 - Δn/n)) = S/n = s_old ✓

Fair redemption preserves per-token value.
```

**Leverage effect:**

```
L_old = C / S
L_new = (C - ΔC) / (S - ΔC)

Following similar analysis: L_new > L_old

∴ Sail redemption INCREASES leverage
```

**Intuition:** Removing sail value at current prices concentrates leverage among remaining holders.

---

### 4.5 Collateral Price Changes

**Price changes from P₀ to P₁ (holding physical amount V₀ constant):**

```
C₀ = V₀ × P₀
C₁ = V₀ × P₁
ΔC = V₀ × ΔP

A unchanged (anchored supply in tokens doesn't change with price)

S₁ = C₁ - A = V₀P₁ - A
S₀ = C₀ - A = V₀P₀ - A
ΔS = V₀ × ΔP = ΔC

∴ Sail value changes 1:1 with collateral value
```

**Sail return:**

```
ΔS/S₀ = V₀ΔP / (V₀P₀ - A)
      = V₀ΔP / S₀
      = (C₀ / S₀) × (ΔP/P₀)
      = L₀ × (ΔP/P₀)

∴ Sail return ≈ Initial Leverage × Collateral return
```

**Leverage changes:**

```
L₁ = C₁/S₁ = V₀P₁ / (V₀P₁ - A)
L₀ = C₀/S₀ = V₀P₀ / (V₀P₀ - A)

For small ΔP:
L₁ ≈ L₀(1 - A×ΔP / (S₀×P₀))

∴ Leverage DECREASES when price increases (ΔP > 0)
  Leverage INCREASES when price decreases (ΔP < 0)
```

**Example: Price increase (+10%)**

Initial: V₀ = 100 wstETH, P₀ = $3,000, C₀ = $300k, A = $180k, S₀ = $120k, L₀ = 2.5x

```
P₁ = $3,300
C₁ = $330k
S₁ = $150k
L₁ = 2.2x

ΔS/S₀ = $30k / $120k = +25% (≈ 2.5x × 10%)
ΔL = -0.3x (de-leveraging)
```

**Example: Price decrease (-10%)**

```
P₁ = $2,700
C₁ = $270k
S₁ = $90k
L₁ = 3.0x

ΔS/S₀ = -$30k / $120k = -25% (≈ 2.5x × -10%)
ΔL = +0.5x (re-leveraging - DANGER!)
```

---

### 4.6 Operations Summary Table

| Operation | ΔC | ΔA | ΔS | ΔL | Notes |
|-----------|----|----|----|----|-------|
| **Mint anchored** | +ΔA | +ΔA | 0 | + | Sail value unchanged, leverage increases |
| **Redeem anchored** | -ΔA | -ΔA | 0 | - | Sail value unchanged, leverage decreases |
| **Mint sail** | +ΔC | 0 | +ΔC | - | Per-token value preserved (if fair), leverage decreases |
| **Redeem sail** | -ΔC | 0 | -ΔC | + | Per-token value preserved (if fair), leverage increases |
| **Price increase** | +ΔC | 0 | +ΔC | - | Sail gains, leverage decreases (de-leveraging) |
| **Price decrease** | -ΔC | 0 | -ΔC | + | Sail loses, leverage increases (re-leveraging) |

---

## 5. Gamma Analysis (Second-Order Sensitivities)

### 5.1 Sail Value Gammas

**Gamma with respect to collateral:**
```
∂²S/∂C² = 0

Interpretation: Sail value is LINEAR in collateral. No convexity.
```

**Gamma with respect to anchored supply:**
```
∂²S/∂A² = 0

Interpretation: Sail value is LINEAR in anchored supply. No convexity.
```

**Key insight:** Sail token VALUE has zero gamma. However, sail token LEVERAGE has non-zero gamma (see below).

---

### 5.2 Leverage Gammas

**Gamma with respect to collateral:**
```
∂²L/∂C² = 2A / (C - A)³ = 2A / S³

Sign: Positive (convex function)

Interpretation: Leverage ACCELERATION
- As C decreases, leverage increases at an increasing rate
- As C increases, leverage decreases at a decreasing rate
```

**Example calculation:**

C = $100, A = $40, S = $60

```
∂²L/∂C² = 2 × 40 / 60³ = 0.000370

Meaning: Second derivative is positive → leverage change accelerates as C declines
```

**Physical interpretation:**

When collateral drops:
1. First-order: Leverage increases (negative delta)
2. Second-order: Rate of increase accelerates (positive gamma)
3. Result: "Negative gamma" for sail holders (losses accelerate)

**Gamma with respect to anchored supply:**
```
∂²L/∂A² = 2C / (C - A)³ = 2C / S³

Sign: Positive

Interpretation: Leverage increase accelerates as anchored supply grows
```

---

### 5.3 Effective Gamma for Returns

While sail value has zero gamma (∂²S/∂C² = 0), sail RETURNS have negative gamma due to leverage drift.

**Return as function of collateral change:**

```
dS/S = L × (dC/C) - (corrections)

Effective gamma = ∂²(dS/S) / ∂C²
```

**Derivation:**

```
S = C - A
dS = dC (assuming A constant)
dS/S = dC / (C - A)

Taking second derivative:
∂²(dS/S) / ∂C² = ∂/∂C [1/(C-A)] = -1/(C-A)² < 0

∴ Negative gamma
```

**Interpretation:** Sail token returns exhibit negative convexity:
- Gains decelerate when collateral rises (leverage decreases)
- Losses accelerate when collateral falls (leverage increases)

---
## 6. Plotting Functions

### 6.1 Python Code for Value Plots

```python
import numpy as np
import matplotlib.pyplot as plt

# Parameters
A = 40  # Anchored token value ($40M)
C_range = np.linspace(40, 200, 1000)  # Collateral from $40M to $200M

# Calculate sail value and leverage
S = C_range - A
S = np.maximum(S, 0)  # Can't be negative (wipeout at C = A)

L = np.divide(C_range, S, where=S>0, out=np.full_like(S, np.inf))

# Plot 1: Sail Value vs Collateral
fig, axes = plt.subplots(3, 1, figsize=(10, 12))

axes[0].plot(C_range, S, 'b-', linewidth=2)
axes[0].axhline(y=0, color='k', linestyle='--', alpha=0.3)
axes[0].axvline(x=A, color='r', linestyle='--', alpha=0.3, label='Wipeout (C=A)')
axes[0].set_xlabel('Collateral Value C ($M)')
axes[0].set_ylabel('Sail Value S ($M)')
axes[0].set_title('Sail Value vs Collateral (A = $40M)')
axes[0].grid(True, alpha=0.3)
axes[0].legend()

# Plot 2: Leverage vs Collateral
axes[1].plot(C_range[S>0], L[S>0], 'g-', linewidth=2)
axes[1].axvline(x=A, color='r', linestyle='--', alpha=0.3, label='Wipeout (C=A)')
axes[1].axhline(y=1, color='k', linestyle='--', alpha=0.3, label='No leverage')
axes[1].set_xlabel('Collateral Value C ($M)')
axes[1].set_ylabel('Leverage L (ratio)')
axes[1].set_title('Leverage vs Collateral (A = $40M)')
axes[1].set_ylim([0, 10])
axes[1].grid(True, alpha=0.3)
axes[1].legend()

# Plot 3: Delta (∂L/∂C) vs Collateral
dL_dC = -A / (S**2)
dL_dC[S <= 0] = np.nan

axes[2].plot(C_range, dL_dC, 'r-', linewidth=2)
axes[2].axhline(y=0, color='k', linestyle='--', alpha=0.3)
axes[2].axvline(x=A, color='r', linestyle='--', alpha=0.3, label='Wipeout (C=A)')
axes[2].set_xlabel('Collateral Value C ($M)')
axes[2].set_ylabel('∂L/∂C (leverage delta)')
axes[2].set_title('Leverage Delta vs Collateral (A = $40M)')
axes[2].set_ylim([-0.1, 0])
axes[2].grid(True, alpha=0.3)
axes[2].legend()

plt.tight_layout()
plt.savefig('sail_value_leverage_delta.png', dpi=150)
plt.show()
```

### 6.2 Gamma Plot

```python
# Plot 4: Gamma (∂²L/∂C²) vs Collateral
fig, ax = plt.subplots(figsize=(10, 6))

d2L_dC2 = 2 * A / (S**3)
d2L_dC2[S <= 0] = np.nan

ax.plot(C_range, d2L_dC2, 'm-', linewidth=2)
ax.axhline(y=0, color='k', linestyle='--', alpha=0.3)
ax.axvline(x=A, color='r', linestyle='--', alpha=0.3, label='Wipeout (C=A)')
ax.set_xlabel('Collateral Value C ($M)')
ax.set_ylabel('∂²L/∂C² (leverage gamma)')
ax.set_title('Leverage Gamma vs Collateral (A = $40M)')
ax.set_yscale('log')
ax.grid(True, alpha=0.3, which='both')
ax.legend()

plt.tight_layout()
plt.savefig('sail_leverage_gamma.png', dpi=150)
plt.show()
```

### 6.3 Heatmap: Sail Value vs (C, A)

```python
# Create 2D grid
C_vals = np.linspace(50, 200, 100)
A_vals = np.linspace(20, 100, 100)
C_grid, A_grid = np.meshgrid(C_vals, A_vals)

# Calculate S for each (C, A) pair
S_grid = C_grid - A_grid
S_grid[S_grid < 0] = 0  # Wipeout region

# Plot heatmap
fig, ax = plt.subplots(figsize=(10, 8))
im = ax.contourf(C_grid, A_grid, S_grid, levels=20, cmap='viridis')
ax.plot([20, 200], [20, 200], 'r--', linewidth=2, label='Wipeout line (C=A)')
ax.set_xlabel('Collateral C ($M)')
ax.set_ylabel('Anchored A ($M)')
ax.set_title('Sail Value S = C - A')
cbar = plt.colorbar(im, ax=ax)
cbar.set_label('Sail Value ($M)')
ax.legend()
plt.tight_layout()
plt.savefig('sail_value_heatmap.png', dpi=150)
plt.show()
```

---

## 7. Closed-Form Solutions Summary

### 7.1 Value Functions

| Function | Formula | Type |
|----------|---------|------|
| Sail value | S = C - A | Linear |
| Per-token sail | s = (C - A) / n | Hyperbolic in n |
| Leverage | L = C / (C - A) | Rational |
| Collateral ratio | CR = C / A | Linear in C |

### 7.2 First Derivatives (Deltas)

| Derivative | Formula | Sign |
|------------|---------|------|
| ∂S/∂C | 1 | Positive |
| ∂S/∂A | -1 | Negative |
| ∂L/∂C | -A / S² | Negative |
| ∂L/∂A | C / S² | Positive |
| ∂s/∂n | -s / n | Negative |

### 7.3 Second Derivatives (Gammas)

| Derivative | Formula | Sign |
|------------|---------|------|
| ∂²S/∂C² | 0 | Zero |
| ∂²S/∂A² | 0 | Zero |
| ∂²L/∂C² | 2A / S³ | Positive |
| ∂²L/∂A² | 2C / S³ | Positive |

---

## 8. Key Insights

1. **Sail value is linear in collateral** (∂²S/∂C² = 0), but **leverage is nonlinear** (∂²L/∂C² > 0).

2. **Negative gamma effect** comes from leverage drift, not direct value convexity.

3. **Anchored token minting/redemption** does NOT affect sail value directly, but DOES affect leverage.

4. **Sail token minting/redemption** preserves per-token value (if fair pricing) but changes aggregate leverage.

5. **Price changes** affect sail value linearly (ΔS = V₀ΔP) but leverage nonlinearly.

6. **Wipeout occurs at C = A**, where leverage → ∞.

7. **All formulas are closed-form** - no need for numerical approximations or bumping (except for plotting).

---

## 9. Applications to Product Design

This mathematical foundation applies to:

1. **Variable leverage sail** (current Harbor): Uses S = C - A directly
2. **Fixed leverage sail**: Adjusts redemption formula to maintain constant L
3. **Tiered risk sail**: Splits S into senior/junior with loss priorities
4. **Short leverage**: Creates tokens with ∂S/∂C < 0
5. **Dual-harbor products**: Combines (C₁, A₁, S₁) with (C₂, A₂, S₂) for custom profiles

Each product document will reference these core equations and build specific variations.

---

**Status:** Mathematical foundation complete.
**Next:** See individual product documents for implementations.
