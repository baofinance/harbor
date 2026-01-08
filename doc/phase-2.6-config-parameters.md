# Phase 2.6: Config Parameter Methods

## Overview

Phase 2.6 completes the config contract architecture by adding parameter accessor methods. These methods provide the actual values needed during deployment (addresses, fees, thresholds, etc.) in a type-safe, DRY manner.

## Status

**NOT STARTED** - This phase blocks Phase 3 actual deployment implementation.

## What's Missing

The config contracts currently only provide:
- `peg()` - returns peg identifier (e.g., "ETH", "BTC")
- `collateral()` - returns collateral identifier (e.g., "fxUSD", "stETH")
- Static constants (MIN_DEPOSIT, MIN_TOTAL_SUPPLY, REBALANCE_COLLATERAL_RATIO)

But deployment needs additional methods to access:

### Required by Minter Deployment

From the design document (HarborDeploymentBase.sol comments):

```solidity
// Example from doc/deployment2-design.md lines 50-104:

// 1. Minter deployment needs:
config.owner()                    // Who owns the minter
config.peggedBurnSignature()      // Method signature for burning pegged tokens

// 2. Minter initialization needs:
config.owner()                    // Owner for AccessControl

// 3. StabilityPool deployment needs:
config.earlyWithdrawalFee()       // Withdrawal fee
config.feeAddress()               // Where fees go
config.withdrawalStartDelay()     // Delay before withdrawals start
config.withdrawalEndWindow()      // Window for withdrawals
config.minTotalSupply()           // Minimum total supply (already exists in peg configs)

// 4. StabilityPoolManager deployment needs:
config.treasury()                 // Treasury address

// 5. Minter configuration needs:
config.priceOracle()              // Oracle address for price feeds
config.feeReceiver()              // Fee receiver address

// 6. Address resolution needs:
config.wrappedCollateral()        // Collateral token address (not just identifier)
config.peggedToken()              // Pegged token address (computed via predictAddress)
```

## Implementation Strategy

### 1. Add methods to base config contracts

Each config piece should provide the parameters it logically owns:

**Config_Chain_Mainnet** (already has addresses as constants):
```solidity
abstract contract Config_Chain_Mainnet {
    address constant FXUSD = 0x085780639CC2cACd35E474e71f4d000e2405d8f6;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant TREASURY = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;
    address constant MINTER_FEE_RECEIVER = 0x...;
    
    // Add accessor methods:
    function treasury() public pure returns (address) { return TREASURY; }
    function minterFeeReceiver() public pure returns (address) { return MINTER_FEE_RECEIVER; }
}
```

**Config_Peg_ETH** (already has constants, needs methods):
```solidity
abstract contract Config_Peg_ETH {
    uint256 constant MIN_DEPOSIT = 0.01 ether;
    uint256 constant MIN_TOTAL_SUPPLY = 0.1 ether;
    string constant PEGGED_BURN_SIGNATURE = "burn(uint256)";
    
    // Add accessor methods:
    function minDeposit() public pure returns (uint256) { return MIN_DEPOSIT; }
    function minTotalSupply() public pure returns (uint256) { return MIN_TOTAL_SUPPLY; }
    function peggedBurnSignature() public pure returns (string memory) { return PEGGED_BURN_SIGNATURE; }
}
```

**Config_PriceVolatility_130** (already has method):
```solidity
abstract contract Config_PriceVolatility_130 {
    uint256 constant REBALANCE_COLLATERAL_RATIO = 1.3e18;
    uint256 constant EARLY_WITHDRAWAL_FEE = 0.005e18; // 0.5%
    uint256 constant WITHDRAWAL_START_DELAY = 1 days;
    uint256 constant WITHDRAWAL_END_WINDOW = 7 days;
    
    function minterConfig() internal pure virtual returns (MinterConfig memory) {
        return MinterConfig({ 
            mintPeggedBounds: [1.31e18, 1.40e18, 1.50e18], 
            mintPeggedRatios: [1e18, 0.02e18, 0.01e18] 
        });
    }
    
    // Add accessor methods:
    function rebalanceCollateralRatio() public pure returns (uint256) { return REBALANCE_COLLATERAL_RATIO; }
    function earlyWithdrawalFee() public pure returns (uint256) { return EARLY_WITHDRAWAL_FEE; }
    function withdrawalStartDelay() public pure returns (uint256) { return WITHDRAWAL_START_DELAY; }
    function withdrawalEndWindow() public pure returns (uint256) { return WITHDRAWAL_END_WINDOW; }
}
```

**New: Config_Collateral_fxUSD** (needs address accessor):
```solidity
abstract contract Config_Collateral_fxUSD is Config_Chain_Mainnet {
    function wrappedCollateral() public pure returns (address) { return FXUSD; }
}
```

**New: Config_Collateral_stETH**:
```solidity
abstract contract Config_Collateral_stETH is Config_Chain_Mainnet {
    function wrappedCollateral() public pure returns (address) { return STETH; }
}
```

### 2. Add owner() to concrete market configs

Each market config needs to specify the owner:

```solidity
contract Config_Market_ETH_fxUSD is
    Config_MinterMarket,
    Config_Chain_Mainnet,
    Config_Peg_ETH,
    Config_Collateral_fxUSD,
    Config_PriceVolatility_130
{
    address constant PRICE_ORACLE = 0x71437C90F1E0785dd691FD02f7bE0B90cd14c097;
    address constant OWNER = 0x...; // Deployer/multisig
    
    function priceOracle() public pure returns (address) { return PRICE_ORACLE; }
    function owner() public pure returns (address) { return OWNER; }
}
```

### 3. Create collateral config contracts

Currently missing - need to create:
- `script/config/collaterals/Config_Collateral_fxUSD.sol`
- `script/config/collaterals/Config_Collateral_stETH.sol`

These provide `wrappedCollateral()` method.

### 4. Update market configs to inherit collateral configs

```solidity
// Before:
contract Config_Market_ETH_fxUSD is
    Config_MinterMarket,
    Config_Chain_Mainnet,
    Config_Peg_ETH,
    Config_PriceVolatility_130
{
    address constant COLLATERAL = FXUSD; // Direct reference
}

// After:
contract Config_Market_ETH_fxUSD is
    Config_MinterMarket,
    Config_Chain_Mainnet,
    Config_Peg_ETH,
    Config_Collateral_fxUSD,  // Inherits wrappedCollateral()
    Config_PriceVolatility_130
{}
```

## Checklist

- [ ] Add accessor methods to Config_Chain_Mainnet
- [ ] Add accessor methods to Config_Peg_* contracts
- [ ] Add accessor methods to Config_PriceVolatility_* contracts
- [ ] Create Config_Collateral_* contracts with wrappedCollateral() method
- [ ] Update market configs to inherit collateral configs
- [ ] Add owner() and priceOracle() to concrete market configs
- [ ] Add feeAddress() method (may live in chain config or market config)
- [ ] Update Config_MinterMarket to declare required methods as abstract
- [ ] Write tests for config parameter methods

## Testing Strategy

Tests should verify:
1. Each config provides all required methods
2. Methods return expected values
3. Multiple inheritance doesn't create conflicts
4. Concrete market configs have all required parameters

Example test:
```solidity
function test_market_config_provides_all_parameters() public {
    Config_Market_ETH_fxUSD config = new Config_Market_ETH_fxUSD();
    
    // Verify all required methods exist and return valid values
    assertTrue(config.owner() != address(0));
    assertTrue(config.treasury() != address(0));
    assertTrue(config.wrappedCollateral() != address(0));
    assertTrue(config.priceOracle() != address(0));
    assertTrue(config.minterFeeReceiver() != address(0));
    assertGt(config.minDeposit(), 0);
    assertGt(config.minTotalSupply(), 0);
    assertGt(config.earlyWithdrawalFee(), 0);
    assertGt(config.rebalanceCollateralRatio(), 1e18);
    assertTrue(bytes(config.peggedBurnSignature()).length > 0);
}
```

## Dependencies

Phase 3 actual deployment implementation is blocked until Phase 2.6 is complete. The deployment code can't call `config.owner()`, `config.wrappedCollateral()`, etc. until these methods exist.

## Notes

- Keep accessors simple - just return constants or call inherited constants
- Don't duplicate data - inherit from the config piece that logically owns it
- All addresses should be validated (non-zero) in tests
- Consider making some methods abstract in base classes to force implementation
