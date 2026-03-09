# New markets deployment – prep checklist

Preparation for deploying USD and other new markets. **Do not deploy until reviewed.**

## Before you deploy

- [ ] **RPC** – Set `MAINNET_RPC_URL` / `MEGAETH_RPC_URL` / `MONAD_RPC_URL` (and `ETHERSCAN_KEY` for mainnet verification) in `.env` or `export`.
- [ ] **Deployer** – For non-local: `--account <keystore-name>`; ensure the account has gas on the target chain.
- [ ] **Salt** – Decide salt prefix and use it consistently for the chain. Production: e.g. `harbor_v1`. Test: e.g. `megaeth_test_v1` (keeps test state separate).
- [ ] **Peg token** – Use `--deploy-peg` the first time you deploy a peg on that network; omit for additional collaterals only.
- [ ] **Oracles (unsalted)** – After each market deploy, call `Minter_v1(minter).updatePriceOracle(yourOracleAddress)` as owner for each minter. Have a list of (marketKey, minter address, oracle address) ready.
- [ ] **Monad sUSDe** – If deploying sUSDe markets, set the real `sUSDe()` address in `ConfigChain_monad.sol` when it has an address.
- [ ] **Post-deploy** – Run `script/check-blockchain --network <net> --salt <salt>` (and `script/check-etherscan` for mainnet) to validate.

## Done (mainnet USD)

- **ConfigPeg_USD** – `script/config/pegs/ConfigPeg_USD.sol`
- **Mainnet chain** – `ConfigChain_mainnet`: added `PAXG()`, `tBTC()` (wBTC, wstETH already present)
- **Mainnet collaterals** – PAXG, tBTC, wBTC, wstETH in `script/config/collaterals/ConfigCollateral_*_mainnet.sol`
- **Mainnet USD markets** – `script/config/markets/ConfigMarket_USD_{PAXG,tBTC,wBTC,wstETH}_mainnet.sol`
- **Deploy scripts** – `script/src/Deploy_USD_Minter.sol`, `script/Deploy_USD_mainnet.s.sol`
- **CLI** – `script/deploy` accepts `--peg USD`; usage lists USD.

### Deploy mainnet USD (when ready)

```bash
# All USD mainnet markets (PAXG, tBTC, wBTC, wstETH)
script/deploy --peg USD --network mainnet --salt harbor_v1 --deploy-peg

# Single collateral
script/deploy --peg USD --network mainnet --salt harbor_v1 --collateral wstETH
```

**Price oracles:** The market deploy script in this repo does **not** deploy the wrapped price oracle. It only predicts its address from the key `collateral::peg::wrappedPriceAggregator` and sets `minter.updatePriceOracle(thatAddress)`. The actual oracle contract must be deployed elsewhere (e.g. bao-base or your oracle pipeline) using the same factory/salt so it lands at that address; otherwise the minter will point at an empty or wrong contract.

---

## Done: megaeth

- **Chain** – `script/config/chains/ConfigChain_megaeth.sol` (chain ID 4326). **Replace placeholder token addresses** (BTC, wstETH, USDMY) with actual MegaETH mainnet addresses before deploy.
- **Pegs** – ConfigPeg_HYPE, ConfigPeg_SOL (for USDMY markets).
- **Collaterals** – ConfigCollateral_BTC_megaeth, ConfigCollateral_wstETH_megaeth, ConfigCollateral_USDMY_megaeth.
- **Markets** – USD::BTC, USD::wstETH; BTC::USDMY, ETH::USDMY, HYPE::USDMY, SOL::USDMY.
- **Deploy scripts** – Deploy_USD_megaeth.s.sol, Deploy_BTC_megaeth.s.sol, Deploy_ETH_megaeth.s.sol, Deploy_HYPE_megaeth.s.sol, Deploy_SOL_megaeth.s.sol.
- **RPC** – `megaeth = "${MEGAETH_RPC_URL}"` in `foundry.toml`.

### Deploy megaeth (when ready)

```bash
export MEGAETH_RPC_URL="https://..."   # or set in .env

# USD markets (BTC, wstETH)
script/deploy --peg USD --network megaeth --salt harbor_v1 --deploy-peg

# USDMY pairs (one peg per script)
script/deploy --peg BTC --network megaeth --salt harbor_v1 --deploy-peg
script/deploy --peg ETH --network megaeth --salt harbor_v1 --deploy-peg
script/deploy --peg HYPE --network megaeth --salt harbor_v1 --deploy-peg
script/deploy --peg SOL --network megaeth --salt harbor_v1 --deploy-peg
```

Reference (oracle/minter addresses from spec): BTC/USD `0xD3902...`, wstETH/USD `0xF183D...`, USDMY/BTC `0xf9cB...`, USDMY/ETH `0x756B...`, USDMY/HYPE `0x830A...`, USDMY/SOL `0xE296...`.

---

## Done: monad

- **Chain** – `script/config/chains/ConfigChain_monad.sol` (chain ID 143). **Replace placeholder token addresses** (wstETH, sUSDe) with actual Monad mainnet addresses before deploy.
- **Peg** – ConfigPeg_XAU (gold).
- **Collaterals** – ConfigCollateral_wstETH_monad, ConfigCollateral_sUSDe_monad.
- **Markets** – USD::wstETH; BTC::wstETH, BTC::sUSDe; ETH::sUSDe; XAU::wstETH, XAU::sUSDe.
- **Deploy scripts** – Deploy_USD_monad.s.sol, Deploy_BTC_monad.s.sol, Deploy_ETH_monad.s.sol, Deploy_XAU_monad.s.sol.
- **RPC** – `monad = "${MONAD_RPC_URL}"` in `foundry.toml`.

### Deploy monad (when ready)

```bash
export MONAD_RPC_URL="https://..."     # or set in .env

script/deploy --peg USD --network monad --salt harbor_v1 --deploy-peg
script/deploy --peg BTC --network monad --salt harbor_v1 --deploy-peg
script/deploy --peg ETH --network monad --salt harbor_v1 --deploy-peg
script/deploy --peg XAU --network monad --salt harbor_v1 --deploy-peg
```

**Oracles:** Deploy/register wrapped price aggregators so keys match `collateral::peg::wrappedPriceAggregator` (e.g. `wstETH::USD::wrappedPriceAggregator`, `sUSDe::BTC::wrappedPriceAggregator`). Naming can align with Aggregator_wstETH_USD_monad, etc.

---

## How deployment works

- **Entrypoint:** `script/deploy --network <name> --salt <salt> --peg <peg>` (plus optional `--deploy-peg`, `--collateral`, `--account`, `--local`, etc.; see `script/deploy --help`).
- **Network:** Identifies the chain and selects the RPC URL from `foundry.toml` (e.g. `mainnet` → `MAINNET_RPC_URL`). Use `--local` to use local anvil instead.
- **Naming:** `script/deploy --peg SILVER --network mainnet` runs `script/Deploy_SILVER_mainnet.s.sol`. For a new (peg, network) you add a new `script/Deploy_<peg>_<network>.s.sol`.
- **Collateral:** `--collateral <name>` deploys only that market; if omitted, defaults to **all** collaterals for that peg on that network.
- **`--deploy-peg`:** Yes, use it the **first time** you deploy that peg on that network (so the pegged token, e.g. haUSD, haETH, is deployed). Omit when you are only adding another collateral market for an already-deployed peg.

## Naming convention reminder

- `script/deploy --peg <PEG> --network <NETWORK>` runs `script/Deploy_<PEG>_<NETWORK>.s.sol`.
- Market salt is `peg::collateral` (e.g. `USD::PAXG`). Price oracle key is `collateral::peg::wrappedPriceAggregator`.
- **Oracles at the predicted address:** Deploy wrapped price aggregators **through the same Bao factory** with salt `saltPrefix::collateral::peg::wrappedPriceAggregator` (e.g. `harbor_v1::PAXG::USD::wrappedPriceAggregator`). Then the minter deploy will point at them automatically; no `updatePriceOracle` needed.

## State file (implementations vs proxies)

The state file has an `implementations` map (address → metadata) and a `proxies` map (role → address + implementation). You can get **double implementations** (two entries per logical contract, e.g. two Genesis_v1 addresses) because:

1. **Two-phase deploy** – The deploy script may deploy each contract once (proxy + impl), then run an upgrade step that deploys a fresh implementation and calls `upgradeToAndCall` on the proxy. Each deployment calls `recordImplementation()`, so both the initial and the upgraded implementation addresses are stored.
2. **Re-runs** – If you run the deploy script again (e.g. to add a market or resume), new implementations are deployed and recorded; the old ones remain in the map.

Only the addresses in `proxies.*.implementation` are the ones actually in use. To clean the state file so `implementations` contains only those, run:

```bash
jq '([.proxies[].implementation] | unique) as $used | .implementations |= (to_entries | map(select(.key as $k | ($used | index($k)) != null)) | from_entries)' deployments/megaeth/<salt>.state.json > deployments/megaeth/<salt>.state.json.tmp && mv deployments/megaeth/<salt>.state.json.tmp deployments/megaeth/<salt>.state.json
```

Replace `<salt>` with your state file name (e.g. `megaeth_test_v1`). After cleaning, `script/verify-megaeth` will only verify the 15 (or N) implementations that proxies point to.

## Verification (megaeth / monad)

- **Report (check status):** `script/check-etherscan --network megaeth --salt harbor_v1` (and same for `monad`) works. It uses Etherscan API v2 with `chainid` (4326 for MegaETH, 143 for Monad) and links to https://mega.etherscan.io and https://monadscan.com. Set `ETHERSCAN_KEY` in `.env` or `foundry.toml` so the script can call the API.
- **Submitting verification (MegaETH):** Use `script/verify-megaeth` to verify all implementation contracts from a deployment state file. It reads `deployments/megaeth/<salt>.state.json`, gets Standard JSON Input via `forge verify-contract --show-standard-json-input`, and POSTs to Etherscan API v2 with `chainid=4326`.
  - Run: `script/verify-megaeth --state deployments/megaeth/megaeth_test_v1.state.json --etherscan <API_KEY>` (or set `ETHERSCAN_KEY` and omit `--etherscan`). Requires `MEGAETH_RPC_URL` in `.env` or environment.
  - To also verify **proxy** contracts (ERC1967Proxy): add `--verify-proxies` and set `UUPS_PROXY_DEPLOY_STUB_ADDRESS` to the UUPSProxyDeployStub address from your deploy (same stub used for all proxies; find it in deploy logs or the first proxy’s deploy tx).
  - Check status: `script/check-etherscan --network megaeth --salt <salt>`.
- **Where to get UUPS_PROXY_DEPLOY_STUB_ADDRESS:** The deploy uses one UUPSProxyDeployStub for all proxies; you need its address to verify proxy contracts. (1) **From broadcast JSON:** After deploy, Foundry writes e.g. `broadcast/Deploy_USD_Minter_megaeth.s.sol/4326/run-*.json`. In that file, find the first tx with `"contractName": "UUPSProxyDeployStub"` and use its `contractAddress`. Example: `jq -r '.transactions[] | select(.contractName=="UUPSProxyDeployStub") | .contractAddress' broadcast/.../4326/run-*.json | head -1`. (2) **From chain:** On mega.etherscan.io, open the creation tx of any proxy (e.g. USD::pegged from state); the creation input includes ABI-encoded constructor args; the first 32-byte word (padded address) is the stub. If you have no broadcast logs and cannot decode the tx, proxy verification cannot be done (implementation verification is unchanged).
- **Manual / other chains:** For monad or single-contract verification, use the same approach as **bao-factory**: get Standard JSON with `forge verify-contract --rpc-url <rpc> --show-standard-json-input <address> <path:Contract>`, then POST to `https://api.etherscan.io/v2/api?chainid=143&...` (monad) with `module=contract`, `action=verifysourcecode`, `codeformat=solidity-standard-json-input`, `contractname=<path:Contract>`, etc.

## Price oracles (wrapped price aggregators)

Oracles are **not** deployed when you run `script/deploy` for a market. This repo’s deploy script:

1. Computes the oracle address via `_predictAddress(priceOracleKey)` where `priceOracleKey = collateral::peg::wrappedPriceAggregator` (e.g. `PAXG::USD::wrappedPriceAggregator`).
2. Calls `Minter_v1(minter).updatePriceOracle(priceOracle)` so the minter uses that address.

The real wrapped price oracle (e.g. a Chainlink-backed implementation) must be deployed **separately**—typically by bao-base or your oracle stack—using the same factory and salt/key so the deployed address matches what the minter expects. The implementation lives in this repo (e.g. `src/price/`), but deployment is outside the Harbor minter deploy flow (see also `script/test/DeployMinters.t.sol`: “Skip priceOracle (external contract, not factory-deployed)”).
