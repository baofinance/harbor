# Manager Dual-Mode Swaps Execution Checklist

Source plan: `/Users/fabiansmith/.cursor/plans/manager_dual-mode_swaps_0239d320.plan.md`

Use this as the implementation tracker for manager-level dual-mode swaps.

## Architecture Guardrails (Set Before Coding)

- [x] Swapping is executed generically through a common interface (`ISwapper`), not per-hyToken bespoke swap logic.
- [x] Routing configuration is per-`hyToken` (same token pair can resolve to different routes depending on hyToken strategy).
- [x] Manager enforces that route resolution is strategy-aware (`hyToken` context included in route lookup key/payload).

## 0) Project Setup

- [ ] Confirm implementation target repo and contracts path (`harbor` vs `harbor-yield` paths referenced in plan).
- [ ] Create and switch to a dedicated feature branch for this workstream.
- [ ] Record baseline: current swap entrypoints and manager touchpoints before refactor.

## 1) Define Core Swap Abstractions

- [x] Add `ISwapper.sol` with canonical swap interface:
  - [x] `swap(tokenIn, tokenOut, amountIn, minAmountOut, data)` style method.
  - [x] Return/output conventions documented and consistent.
- [x] Add `ISwapRouteRegistry.sol` for strategy-aware route lifecycle and lookup.
  - [x] Route key includes `hyToken` context (for example `(hyToken, tokenIn, tokenOut, routeId)`).
- [x] Define shared route mode enum (`OnchainPredefined`, `AggregatorData`).
- [x] Define canonical events/errors for manager-driven swap execution.
- [x] Ensure new interfaces compile and are referenced by manager/adapters.

## 2) Build 1inch Adapter (`OneInchSwapper`)

- [x] Implement adapter around `IAggregationRouterV6`.
- [ ] Validate `tokenIn`, `tokenOut`, `amountIn`, and `minAmountOut` invariants before/after execution.
- [x] Add robust malformed calldata revert behavior.
- [ ] Emit or propagate canonical swap data used by manager.
- [x] Add unit tests with mock router for success + revert paths.

## 3) Build Predefined-Route Adapter (`OnchainRouteSwapper`)

- [x] Implement predefined-route execution path with route-type dispatch.
- [x] Support initial route family implementation (minimum one concrete family).
- [x] Scaffold extensibility for additional route families (Uniswap/Curve/Balancer).
- [ ] Confirm each route template builder against official protocol docs (Uniswap, Curve, Balancer), including selector and parameter semantics.
- [ ] Enforce pair checks and `minAmountOut` slippage guard.
- [ ] Add tests for valid execution and failure modes per route type.

## 4) Create Manager Orchestrator (`SwapManager_v1`)

- [x] Add manager contract with role-gated swap orchestration.
- [x] Add role bits:
  - [x] `SWAP_ADMIN_ROLE` (`_ROLE_0`) for config/emergency controls.
  - [x] `SWAP_EXECUTOR_ROLE` (`_ROLE_1`) for keeper execution.
  - [x] `REBALANCER_ROLE` (`_ROLE_2`) for rebalance flows.
- [x] Implement dual-mode dispatcher:
  - [x] `OnchainPredefined` -> route registry + onchain adapter.
  - [x] `AggregatorData` -> 1inch adapter.
- [x] Enforce unified slippage policy and route policy checks, including `hyToken`-scoped route validation.
- [x] Emit canonical swap event for both execution modes.
- [x] Add unit tests for RBAC and dispatcher behavior.

## 5) Implement Route Registry Management

- [x] Add admin APIs to register/update/disable predefined routes.
- [x] Store route metadata (`routeType`, encoded route config, status).
- [x] Ensure registry supports different route configs per `hyToken` for the same token pair.
- [x] Validate route existence/enabled state in execution flow using `hyToken`-aware lookup.
- [ ] Add tests for route lifecycle (`add -> update -> disable -> execute fail when disabled`).

## 6) Refactor `hyToken_v1` to Thin Integration Layer

- [ ] Remove or soft-deprecate direct 1inch execution path in `hyToken_v1`.
- [ ] Delegate swap execution calls to manager entrypoints.
- [ ] Keep hyToken focused on vault/accounting logic (no heavy swap routing logic).
- [ ] Add compatibility handling for rollout period (if old path temporarily retained).
- [ ] Add tests proving manager-mediated swaps are used in updated flows.

## 7) Align Dependent Interfaces

- [ ] Update `IHyToken.sol` for manager-driven events/errors/signatures.
- [ ] Update `IStabilityPoolManager.sol` only where manager swap hooks are required.
- [ ] Verify no interface/implementation signature drift after refactor.

## 8) Validation and Test Plan

- [ ] Unit tests:
  - [x] RBAC restrictions on configuration and execution functions.
  - [ ] Slippage reverts in both execution modes.
  - [ ] Malformed aggregator route-data reverts.
  - [x] Same-asset passthrough behavior (if supported by design).
  - [x] Route registry lifecycle and disabled route behavior.
- [ ] Integration tests:
  - [ ] `hyToken/rebalance -> manager -> adapter` end-to-end path.
  - [ ] Predefined route selected for time-sensitive flow.
  - [ ] 1inch mode used for non-time-sensitive flow.
  - [ ] Two different `hyToken` instances can resolve and execute different routes for the same `tokenIn/tokenOut`.
  - [ ] Failure paths and revert reason expectations validated.
- [ ] Run full suite and confirm deterministic outcomes.

## 9) Migration and Rollout

- [ ] Phase 1: deploy manager + adapters + interfaces in parallel with old path.
- [ ] Phase 2: wire hyToken swap flows to manager.
- [ ] Phase 3: deprecate direct `executeSwapWith1inch` path in next upgrade.
- [ ] Phase 4: finalize operator runbooks for both modes.
- [ ] Verify monitoring/alerting on unified manager swap events.

## 10) Operations and Documentation

- [ ] Create fast rebalance runbook (predefined routes).
- [ ] Create routine operations runbook (1inch route-data mode).
- [ ] Document role assignment, emergency disable, and fallback procedure.
- [ ] Document migration/deprecation notices and expected cutover timeline.

## 11) Release Readiness

- [ ] Confirm all tests green (unit + integration + relevant static checks).
- [ ] Confirm no direct hyToken swap path remains for newly wired flows.
- [ ] Prepare PR summary and reviewer checklist.
- [ ] Capture follow-ups for later route-family expansion.

