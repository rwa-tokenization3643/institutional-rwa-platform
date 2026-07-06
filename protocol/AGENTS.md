# Protocol Architecture

## Overview

Cross-chain settlement protocol for institutional RWA (Real World Asset) transfers. Uses a 6-phase message exchange with compliance checking, asset reservation, and transport-level delivery guarantees.

## Contract Architecture

```
Access Layer
  ProtocolAccessManager       — Role-based access (DEFAULT_ADMIN, BRIDGE, COMPLIANCE, etc.)
  IProtocolAccessManager      — Interface with UPPER_CASE role constant functions

Core
  SettlementCoordinator       — Orchestrates 6-phase settlement lifecycle
  TransferIntentManager       — Single source of truth for intent state machine

Compliance
  RuleEngineComplianceProvider — 10-check pipeline (action, identity, asset, jurisdiction,
                                 classification, transfer limit, holding limit, time validity)

Asset Adapter
  ERC3643AssetAdapter         — Anti-corruption layer for ERC-3643 tokens
                                Supports: BURN_MINT (implemented)
                                Future: LOCK_MINT, LOCK_UNLOCK, ESCROW_RELEASE

Transport
  CCIPTransportProvider       — Chainlink CCIP bridge integration
  MockCCIPRouter              — Test mock

Interfaces (contracts/interfaces/)
  IProtocolAccessManager, ITransferIntentManager, IAssetAdapter,
  ICompliancePolicyProvider, ISettlementCoordinator, ITransportProvider
```

## Settlement Protocol (6 Phases)

| Phase | Direction | Action | State Change |
|-------|-----------|--------|-------------|
| 1 | Source | submitTransfer | → PENDING_VALIDATION |
| 2 | Source → Dest | VALIDATION_REQUEST | Dest: → VALIDATED |
| 3 | Dest → Source | VALIDATION_RESPONSE | Source: → VALIDATED → RESERVED |
| 4 | Source → Dest | SETTLEMENT_INSTRUCTION | Dest: → SETTLED |
| 5 | Dest → Source | SETTLEMENT_ACK | Source: → SETTLED |
| 6 | Both | Final verification | Invariants checked |

## State Machine

```
PENDING_VALIDATION ──→ VALIDATED ──→ RESERVED ──→ SETTLED
         │                  │            │
         ├──→ REJECTED      ├──→ REJECTED ├──→ ROLLED_BACK
         └──→ EXPIRED       └──→ EXPIRED  └──→ EXPIRED
```

Terminal states: `SETTLED`, `REJECTED`, `EXPIRED`, `ROLLED_BACK`

## Test Structure

- `test/integration/SettlementFlow.t.sol` — Complete 6-phase lifecycle
- `test/integration/ProtocolIntegration.t.sol` — 10 multi-scenario scenarios
- `test/conformance/` — 13 per-invariant conformance tests
- `test/utils/ProtocolFixture.sol` — Deploy helpers and struct
- `test/mocks/` — MockERC3643Token, MockCCIPRouter

### Conformance Tests (13 files)

| # | File | Invariant |
|---|------|-----------|
| 01 | ComplianceRejection | Blocked action → REJECTED |
| 02 | ReplayProtection | Double delivery → MessageNotRetryable |
| 03 | UnknownAsset | Unconfigured asset → REJECTED |
| 04 | ExpiredIntent | Past expiry → IntentExpired revert |
| 05 | TransferLimitExceeded | Amount > max → REJECTED |
| 06 | InvalidJurisdiction | Blocked jurisdiction → REJECTED |
| 07 | TransportFailure | Mint revert → FAILED, retry → SETTLED |
| 08 | ReservationRollback | Release → ROLLED_BACK, balance restored |
| 09 | InvalidTransportSender | Unallowlisted sender → SenderNotAllowed |
| 10 | UnsupportedSettlementModel | Bad model → adapter revert |
| 11 | InvalidIdentity | Zero identity hash → REJECTED |
| 12 | PartialFill | Insufficient balance → reservation fail → REJECTED |
| 13 | ConcurrentIntentsWithFailure | Valid + invalid → no state corruption |

## Design Decisions

- **TransferIntentManager**: Single source of truth, isolates state machine from coordinator
- **Fixture precomputes coordinator address**: Uses `computeCreateAddress` for deterministic deployment
- **RuleEngineComplianceProvider**: 10-check pipeline, extensible with new rules
- **ERC3643AssetAdapter**: Anti-corruption layer, reservation via internal accounting (tokens not moved)
- **Reservation strategy**: Internal accounting with intentId-keyed mapping; temporary — future vault contract
- **Burn-before-mint**: Current reserve-then-mint-then-burn; preferred would be burn-before-mint (CCTP pattern) to prevent supply inflation on mint-success/burn-failure asymmetry
- **Compliance on both chains**: Source checks local compliance; dest independently re-checks

## Known Issues

### Bug (Fixed)
~~`_handleValidationResponse` checked `state != VALIDATED` instead of `state != PENDING_VALIDATION`, causing the entire handler to return early. Now fixed.~~

### Slither Findings (Medium/Info)

1. **Reentrancy (all handlers)**: `_processedMessages[messageId]` written AFTER external calls in all message handlers. Protection relies on CCIP atomic delivery (same tx), not CEI pattern. Acceptable for current architecture but should be reviewed if routing changes.
2. **Unchecked return values**: `sendMessage`, `burnReservedAssets`, `mintAssets`, `releaseReservation` return values ignored (coordinator uses try/catch wrappers internally; direct calls in rollback/ack handlers lack them).
3. **Variable shadowing**: `assetId` parameter shadows struct field name in ERC3643AssetAdapter (cosmetic).
4. **Inline assembly**: Used in `evaluateWithReasons` for memory layout (intentional, gas optimization).
5. **Strict equality for existence**: `createdAt == 0` checks (standard pattern, not a bug).

## Build & Test

```bash
forge build
forge test
forge test -vvv                          # verbose
forge test --match-path "test/conformance/11*"  # specific test
```

## Key Roles

- `BRIDGE_ROLE` — transitionState, sendMessage, reserveAssets, burnReservedAssets, mintAssets
- `COMPLIANCE_ROLE` — configureAsset, configureCompliance, cancelTransferIntent
- `DEFAULT_ADMIN_ROLE` — role management (ProtocolAccessManager)

## Files

```
contracts/
  access/ProtocolAccessManager.sol, IProtocolAccessManager.sol
  adapters/ERC3643AssetAdapter.sol
  common/ProtocolTypes.sol
  compliance/RuleEngineComplianceProvider.sol
  core/SettlementCoordinator.sol, TransferIntentManager.sol
  extensions/bridge/CCIPTransportProvider.sol
  interfaces/IAssetAdapter.sol, ICompliancePolicyProvider.sol,
            ISettlementCoordinator.sol, ITransferIntentManager.sol,
            ITransportProvider.sol
test/
  conformance/01_*.sol through 13_*.sol
  integration/ProtocolIntegration.t.sol, SettlementFlow.t.sol
  mocks/MockCCIPRouter.sol, MockERC3643Token.sol
  utils/ProtocolFixture.sol
```
