# Deploy Tests

`test-deploy` is a convenience wrapper for running `DeployMinters.t.sol` tests.
These tests verify that fresh deployments produce correct contract state by
comparing against reference deployments on a mainnet fork.

## Usage

```bash
# List all tests
script/verify/minter-v2-upgrade/test-deploy --list

# Run BTC deploy test
script/verify/minter-v2-upgrade/test-deploy BTC

# List tests matching SILVER
script/verify/minter-v2-upgrade/test-deploy --list SILVER
```

## How it works

The test creates a candidate deployment on a mainnet fork and compares all view
function outputs against the reference deployment. It uses ABI-based comparison
with dynamic address substitution to verify all contract state is identical.
