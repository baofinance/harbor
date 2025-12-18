# TypeScript Tests

## Overview

This directory contains TypeScript/JavaScript tests for the Harbor Yield deployment system.

## Why TypeScript Tests?

While the core smart contract logic is tested via:

- **Foundry tests** (`test/**/*.t.sol`) - Comprehensive Solidity unit/integration tests
- **Wake tests** (`tests/**/*.py`) - Python-based deployment and interaction tests

TypeScript tests provide:

1. **Script validation** - Ensure deployment scripts can be executed
2. **Integration testing** - Verify deployment flow from a JS/TS perspective
3. **Compatibility** - Test interaction with standard Web3 tooling (ethers.js, viem, etc.)

## Running Tests

```bash
# Run TypeScript tests
yarn test:ts

# Run all tests (Foundry + Wake + TypeScript)
yarn test:all
```

## Test Structure

- `deploy-registry.test.ts` - Tests for the DeployRegistry pattern
- `deploy-functions.test.ts` - Tests for deployment helper functions
- `integration.test.ts` - End-to-end deployment tests

## Note

These tests primarily validate that the deployment infrastructure works correctly,
not the smart contract logic itself (which is thoroughly tested in Solidity).
