<p align="center">
  <a href="https://www.harborfinance.io/">
    <img src="https://github.com/baofinance/harbor-app/raw/main/public/logo.svg"
         alt="Harbor Protocol - A Safer Harbor For Leverage, Uncharted Waters For Yield"
         width="480"
         style="max-width:100%; height:auto;">
  </a>
</p>

<p align="center">
  <br>
  <i>A Safer Harbor For Leverage, Uncharted Waters For Yield.</i><br>
</p>

<br>

# Build status

### harbor

[![CI](https://github.com/baofinance/harbor/actions/workflows/CI-test-foundry-stable.yml/badge.svg)](https://github.com/baofinance/harbor/actions/workflows/CI-test-foundry-stable.yml)

### bao-base

[![CI](https://github.com/baofinance/bao-base/actions/workflows/CI-test-foundry-stable.yml/badge.svg)](https://github.com/baofinance/bao-base/actions/workflows/test.yml)

# Introduction

Harbor turns a single yield-bearing collateral asset into **two tokens with opposite risk profiles**, and keeps them both honest without an external liquidator, an auction, or a counterparty.

- **Anchor tokens** (_ha_) track the value of a chosen underlying — a currency, commodity or index, anything with a price feed. They are the stable, senior claim, redeemable from the protocol for collateral.
- **Sail tokens** (_hs_) take whatever is left over: a leveraged long on the collateral, with no liquidation price, no margin call and no funding rate.

Every unit of collateral value is claimed by exactly one of the two, so they are complementary by construction — the anchor holder gets stability, and the sail holder is paid to carry the price risk that provides it.

The protocol's job is to keep that split solvent, meaning the collateral it holds is always worth at least the anchor tokens it has issued. Four mechanisms do that: a fee and discount schedule that varies with the collateral ratio, stability pools that can be drawn down to restore it, a reserve pool funding the discounts, and a per-contract pause.

Harbor is deployed once per **market** — one (collateral, underlying) pair — and each market is independent, with its own tokens, pools and solvency.

## Documentation

**[Functional specification](doc/functional-spec.md)** — what the protocol achieves, in full: the domain model and accounting identity, the actors and what each must trust, user stories with acceptance criteria, the core flows as sequence diagrams, the keeper-driven background processes, the incentive design, the invariants, the attack vectors, and the operational states.

| | |
|---|---|
| [Fee structure](doc/guides/fee-structure.md) | How the fee, discount and disallow mechanism is configured |
| [Stability pool rewards](doc/guides/stability-pool-rewards.md) | How depositors earn, and how to read it off-chain |
| [Risk parameters](doc/guides/risk-parameters.md) | Collateral ratio thresholds and their meaning |
| [Oracle price feeds](doc/guides/oracle-price-feeds.md) | How prices are sourced and validated |
| [Numerical envelope](doc/DataEnvelope.md) | What the stack can hold, and the limits testing located |
| [HarborYield design](https://github.com/baofinance/harbor-yield/blob/main/doc/design.md) | The yield layer above the stability pools — designed and deployed in the harbor-yield repository |
| [Deployment design](doc/harbor-deployment.md) | Peg families, markets, seeding and deploy switches |

# Development

## Tooling

- Foundry installation and usage is [here](https://book.getfoundry.sh/)
- Python dependencies are managed by uv, installation and usage is [here](https://docs.astral.sh/uv/getting-started/installation/)

## Usage

This project uses both node and python dependencies

```sh
$ yarn
$ uv sync
```

Then you can either:

- activate the python virtual environment by

  ```sh
  $ source .venv/bin/activate
  ```

  and everything works as you'd expect, or

- prefix all the commands that need a vyper compiler
  ```sh
  $ uv run [commmand needing vyper]
  ```
  If you use vscode and have the microsoft python extension installed it activates in the termainal automatically

Then add a good definition of <code>MAINNET_RPC_URL</code> to your <code>.env</code> and call

```sh
$ yarn test
```

which builds and tests the code.

There are other yarn scripts for running linters, formatters, coverage, gas, contract sizes, etc: check the scripts in <code>package.json</code>

You can also run

```sh
$ yarn CI
```

which runs all the scripts. It actually runs the github actions locally under docker.

```sh
$ script/deploy --peg BTC --network mainnet --salt harbor_v1 --local
```

which deploys a **Harbor** minter on a local anvil fork.

`script/run-script` is the universal forge script runner used by both deploy and safe-batch scripts:

```sh
$ script/run-script Deploy_StabilityPool_v2_mainnet --network mainnet --salt harbor_v1 --broadcast --local
```

`script/check-blockchain` validates deployed contracts against the state file (salt prediction, deployed code, UUPS proxy, owner, implementation, stub):

```sh
$ script/check-blockchain --network mainnet --salt harbor_v1
$ script/check-blockchain --network mainnet --salt harbor_v1 --since 2 days --check implementation,owner
```

`script/check-etherscan` generates an Etherscan verification report for all proxies and implementations:

```sh
$ script/check-etherscan --network mainnet --salt harbor_v1
```

Also note that config files for [wake](https://ackee.xyz/wake/docs/4.11.0/) are provided.

### Regression test artifacts

Note that some "yarn test" artifacts:

- the code-coverage report
- the contract sizes
- the gas reports
- generated graphs

are stored in git in the <code>regression</code> folder. This provides a simple, albeit crude and pedantic, mechanism to check for regressions in coverage, gas usage and model values.
