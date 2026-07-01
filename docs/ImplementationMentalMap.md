<!--
 Copyright 2026 mohitvaish

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

     https://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
-->
# Implementation Mental Map

A navigation guide that ties every document, contract, interface, and data flow
together so an implementer knows where to look, what to build, and in what order.

---

## 1. Document Dependency Graph

Read these in order to understand the full architecture:

```text
1. PROJECT_CONTEXT.md           ── What and why
       │
2. docs/Architecture.md         ── High-level module map, 8-phase plan
       │
3. docs/erc3643-analysis.md     ── How upstream T-REX/ONCHAINID work (vendored primitives)
       │
4. docs/ExtensionArchitecture.md ── Extension philosophy, all platform components, 12 rules
       │
5. docs/CrossChainArchitecture.md── Cross-chain topology, burn/mint, per-chain identity
       │
6. docs/CrossChainSettlementProtocol.md ── Two-phase settlement, TransferIntent state machine
       │
7. docs/SecurityPrinciples.md   ── Non-negotiable security rules for all code
       │
8. docs/CodingStandards.md      ── Solidity conventions, formatting, NatSpec rules
```

Supporting documents (implementer should reference as needed):

```text
docs/specs/ProtocolAccessManager.md  ── Role definitions and API contract
docs/specs/Actors.md                 ── Actor definitions and role mapping
docs/PROMPTS.md                      ── Code generation prompt template
```

---

## 2. Contract Dependency Graph (Implementation Order)

Arrows mean "depends on" or "must be deployed/available before." This is the
implementation priority order.

```text
Layer 0: Foundation
    ProtocolAccessManager          (implemented)
    IIdentityRegistry, IToken,
    IModularCompliance             (vendor interfaces, already exist in upstream)
        │
        ▼
Layer 1: Infrastructure
    ChainRegistry                  ── chain metadata, bridge provider registry
    IBridgeProvider (interface)    ── bridge-agnostic message transport
    ICompliancePolicyProvider      ── compliance-agnostic evaluation interface
        │
        ▼
Layer 2: Compliance Modules
    CountryRulesModule             ── jurisdiction-based IModule
    InvestorRulesModule            ── KYC/accreditation IModule
    HoldingRulesModule             ── balance limit IModule
    CrossChainSettlementModule     ── settlement-aware IModule
        │
        ▼
Layer 3: Bridge Provider
    CCIPBridgeProvider             ── implements IBridgeProvider via Chainlink CCIP
        │
        ▼
Layer 4: Settlement
    SettlementCoordinator          ── orchestrates two-phase settlement protocol
    ├── TransferIntentManager      ── intent lifecycle storage and state transitions
    ├── SettlementExecutor         ── executes burn/mint after validation
    └── RecoveryManager            ── timeout, rollback, retry
        │
        ▼
Layer 5: Identity Sync
    CrossChainIdentitySync         ── relays identity proofs/claims between chains
        │
        ▼
Layer 6: Policy Provider
    ACEPolicyProvider              ── implements ICompliancePolicyProvider via Chainlink ACE
        │
        ▼
Layer 7: Token Extensions
    PartitionManager               ── ERC-1400 partitioned balances alongside ERC-3643
    DocumentRegistry               ── hashed document references
    CorporateActions               ── distributions, redemptions, splits, recalls
        │
        ▼
Layer 8: Coordination & Deployment
    BridgeCoordination             ── canonical-chain retry, rollback, reconciliation
    IssuerFactory                  ── wraps TREXFactory for full-suite deployment
```

**Ordering rule for Phase 1 implementation:** Build bottom-up through the stack.
Each layer only depends on layers below it.

---

## 3. System Data Flow

### Identity Flow (how an investor becomes eligible)

```text
Investor
  │  submits KYC docs
  ▼
Backend API
  │  verifies identity off-chain
  ▼
ONCHAINID ClaimIssuer
  │  issues identity claim (credential)
  ▼
Identity Registry (per chain)
  │  links wallet → ONCHAINID identity via registerIdentity()
  │  isVerified(wallet) returns true
  ▼
CrossChainIdentitySync (if cross-chain)
  │  relays identity proof to mirror chains via IBridgeProvider
  ▼
Destination Identity Registry
  │  registerIdentity() called with same identity data
```

**Key invariant:** A wallet must be `isVerified()` on BOTH source and destination
chains before a cross-chain transfer involving that wallet can proceed past Phase 1.

### Compliance Flow (how a transfer is validated on one chain)

```text
Token.transfer() or SettlementCoordinator
  │  calls ModularCompliance.canTransfer()
  ▼
ModularCompliance (vendor)
  │  iterates registered IModule instances:
  │    CountryRulesModule     → checks jurisdiction
  │    InvestorRulesModule    → checks KYC/accreditation
  │    HoldingRulesModule     → checks balance limits
  │    CrossChainSettlementModule → checks settlement-specific rules
  │    ACEPolicyProvider      → evaluates ACE policies (as IModule)
  ▼
Result: allowed (bool), reason (bytes)
```

### Settlement Flow (cross-chain transfer end-to-end)

```text
SOURCE CHAIN                                DESTINATION CHAIN

User calls initiateIntent(recipient, amount)
  │
  ▼
SettlementCoordinator creates TransferIntent (PENDING_VALIDATION)
  │  checks: isVerified(sender) via IIdentityRegistry
  │  checks: canTransfer(sender, recipient, amount) via IModularCompliance
  │
  ▼
IBridgeProvider.sendMessage() ── Phase 1 ──►  SettlementCoordinator receives
  │  TransferIntentPayload                        │
  │  phase=1 (VALIDATION_REQUEST)                  │  validates:
  │                                                │    source chain is registered
  │                                                │    recipient isVerified()
  │                                                │    recipient has required claims
  │                                                │    holding limits on destination OK
  │                                                │    destination token active
  │                                                ▼
  │                                            Emits IntentValidated or IntentRejected
  │
  ◄──── Phase 1 response ──── IBridgeProvider ───┘
  │
  ▼
SettlementCoordinator transitions to VALIDATED
  │
  ▼  (relayer or user calls settleIntent())
  │
  ▼
IBridgeProvider.sendMessage() ── Phase 2 ──►  SettlementCoordinator receives
  │  TransferIntentPayload                        │
  │  phase=2 (SETTLEMENT_INSTRUCTION)             │  mints tokens to recipient
  │                                                │  transitions to SETTLED
  ▼  burns tokens from sender                      ▼
  transitions to SETTLED                      Emits Settled(intentId)
```

### Failure Recovery Flow

```text
Failure: Phase 1 reject → intent stays PENDING_VALIDATION until expiry
  → after deadline: SettlementCoordinator transitions to EXPIRED
  → no value moved, no recovery needed

Failure: Phase 2 timeout → intent stays VALIDATED past deadline
  → RecoveryManager.forceRollback() called
  → intent transitions to ROLLED_BACK
  → no tokens moved (Phase 2 never executed)

Failure: Phase 2 mint fails → destination reverts
  → source is in RESERVED state, tokens locked (not burned)
  → BridgeCoordination.rollbackIntent() on canonical chain
  → releaseReservation unlocks tokens back to sender
```

---

## 4. Component Ownership Map

| Component | Doc | Section | Status | Implementer |
|---|---|---|---|---|
| ProtocolAccessManager | ExtensionArchitecture.md | Platform-Owned | ✅ Implemented | - |
| ChainRegistry | ExtensionArchitecture.md | Platform-Owned | 📄 Specified | Protocol |
| IBridgeProvider | ExtensionArchitecture.md | Platform-Owned | 📄 Specified | Protocol |
| ICompliancePolicyProvider | ExtensionArchitecture.md | Platform-Owned | 📄 Specified | Protocol |
| SettlementCoordinator | SettlementProtocol.md | Architecture Overview | 📄 Specified | Protocol |
| CCIPBridgeProvider | ExtensionArchitecture.md | Platform-Owned | 📄 Specified | Protocol |
| ACEPolicyProvider | ExtensionArchitecture.md | Platform-Owned | 📄 Specified | Protocol |
| CrossChainSettlementModule | SettlementProtocol.md | Architecture Overview | 📄 Specified | Protocol |
| CountryRulesModule | ExtensionArchitecture.md | Platform-Owned | 📄 Specified | Protocol |
| HoldingRulesModule | ExtensionArchitecture.md | Platform-Owned | 📄 Specified | Protocol |
| InvestorRulesModule | ExtensionArchitecture.md | Platform-Owned | 📄 Specified | Protocol |
| CrossChainIdentitySync | ExtensionArchitecture.md | Platform-Owned | 📄 Specified | Protocol |
| BridgeCoordination | ExtensionArchitecture.md | Platform-Owned | 📄 Specified | Protocol |
| PartitionManager | ExtensionArchitecture.md | Platform-Owned | 📄 Specified | Protocol |
| DocumentRegistry | ExtensionArchitecture.md | Platform-Owned | 📄 Specified | Protocol |
| CorporateActions | ExtensionArchitecture.md | Platform-Owned | 📄 Specified | Protocol |
| IssuerFactory | ExtensionArchitecture.md | Platform-Owned | ❌ Not started | Protocol |
| SDK | ExtensionArchitecture.md | Platform-Owned | ❌ Not started | SDK |
| Backend API | ExtensionArchitecture.md | Platform-Owned | ❌ Not started | Backend |
| AI Agent Platform | ExtensionArchitecture.md | Platform-Owned | 🚧 Bootstrapped | Agents |

---

## 5. Interface Relationships

```text
Platform-Defined Interfaces:

IBridgeProvider                  ICompliancePolicyProvider
  │ sendMessage()                   │ evaluateTransfer()
  │ registerReceiver()              │ evaluateIdentity()
  │                                 │
  └── Implemented by:               └── Implemented by:
      CCIPBridgeProvider                ACEPolicyProvider
      (future: LayerZero,               (future: custom RuleEngine,
       Hyperlane, Axelar)                 ZK verifier)


Vendor Interfaces (used by platform, never modified):

IToken            IIdentityRegistry     IModularCompliance    IClaimTopicsRegistry
  │ mint()           │ isVerified()        │ canTransfer()        │ getClaimTopics()
  │ burn()           │ registerIdentity()  │ addModule()
  │ balanceOf()      │ identity()          │ moduleCheck()


T-REX IModule Interface (platform implements for compliance):

IModule
  │ moduleCheck()
  │ moduleTransfer()
  │ moduleBurn()

Implemented by: CountryRulesModule, HoldingRulesModule, InvestorRulesModule,
                CrossChainSettlementModule, ACEPolicyProvider
```

---

## 6. Key Architectural Invariants (Never Violate)

1. **Vendor contracts are frozen.** Never modify `vendor/`. Never inherit from vendor
   contracts. Never read vendor storage directly. Always use public interfaces.

2. **Composition over inheritance.** Platform contracts call vendor contracts through
   interfaces — they never inherit from them. Exception: implementing `IModule` is
   interface conformance, not inheritance.

3. **Burn/mint, never lock/mint.** Tokens are burned on the source chain and minted
   on the destination. No lock vault for standard transfers (IntentVault is optional).

4. **Two-phase settlement.** Never move value before destination-side validation.
   Phase 1 = validate both sides. Phase 2 = execute only after Phase 1 passes.

5. **Per-chain identity.** Each chain has its own `IdentityRegistry`. Cross-chain
   identity sync relays proofs — it does not share storage.

6. **Bridge-agnostic message transport.** `SettlementCoordinator` calls `IBridgeProvider`,
   never a concrete bridge implementation.

7. **Compliance-agnostic evaluation.** `SettlementCoordinator` calls
   `ICompliancePolicyProvider`, never a concrete policy engine.

8. **Always check compliance on both sides.** Source chain checks before burn.
   Destination chain checks before mint.

9. **Supply invariant.** The canonical chain's total supply equals the sum of all
   mirror chain holdings. Burn/mint maintains this automatically.

10. **Events for every state change.** Every meaningful state transition emits an
    event with indexed parameters.

---

## 7. Open Questions Blocking Implementation

| Question | Blocks | Doc Location |
|---|---|---|
| Partition tracking model (standalone vs multi-token vs wrapper) | PartitionManager | ExtensionArchitecture.md, ADR 1 |
| Cross-chain identity sync model (independent registration + relay vs universal identity) | CrossChainIdentitySync | ExtensionArchitecture.md, ADR 2 |
| IntentVault (optional vs mandatory vs none) | SettlementCoordinator gas model | ExtensionArchitecture.md, ADR 3 |
| Relayer incentives (operator vs user-pays vs protocol rebate) | Production deployment | ExtensionArchitecture.md, ADR 4 |
| Governance registry sync across chains | CrossChainIdentitySync scope | ExtensionArchitecture.md, ADR 5 |

**Implementation recommendation:** Build the system with the default choices
already specified (standalone PartitionManager, independent identity registration,
no IntentVault, operator relayers, identity-only sync). The architecture is
designed so these choices can be changed later without rewriting the core.

---

## 8. Where Code Lives vs Where Specs Live

```text
Solidity Contracts:
  protocol/contracts/access/ProtocolAccessManager.sol     ✅ Implemented
  protocol/contracts/extensions/bridge/CCIPBridge.sol      📄 Stub (empty file)
  protocol/contracts/extensions/ace/ACEAdapter.sol         📄 Stub (empty file)
  protocol/contracts/interfaces/ICompliance.sol            ❌ Empty interface
  protocol/contracts/interfaces/IdentityRegistry.sol      ❌ Empty interface
  protocol/contracts/interfaces/IERC3643Token.sol          ❌ Empty interface
  (+ 4 more empty interface files)

Interface Definitions (in docs):
  IBridgeProvider              → ExtensionArchitecture.md (lines 323-353)
  ICompliancePolicyProvider    → ExtensionArchitecture.md (lines 404-434)
  TransferIntentPayload        → ExtensionArchitecture.md (lines 1052-1068)

State Machine Specification:
  TransferIntent states        → CrossChainSettlementProtocol.md

Sequence Diagrams:
  Settlement protocol flows    → CrossChainSettlementProtocol.md
```

---

## 9. Document Guide for Implementers

When implementing a specific contract, read these files in order:

| Contract | Read These First |
|---|---|
| Any contract | CodingStandards.md, SecurityPrinciples.md, ExtensionArchitecture.md (Rules 1-12) |
| SettlementCoordinator | CrossChainSettlementProtocol.md (full), ExtArch (Settlement Layer), CrossChainArchitecture.md (topology) |
| CCIPBridgeProvider | ExtArch (IBridgeProvider, CCIPBridgeProvider), CrossChainArchitecture.md (CCIP integration) |
| ACEPolicyProvider | ExtArch (ICompliancePolicyProvider, ACEPolicyProvider), erc3643-analysis.md (IModule) |
| CrossChainIdentitySync | ExtArch (Identity Layer), CrossChainArchitecture.md (per-chain identity) |
| Compliance modules | erc3643-analysis.md (IModule, ModularCompliance), ExtArch (Compliance Layer) |
| PartitionManager | ExtArch (Asset-Centric Domain Model, Token Extensions), Architecture.md (Phase 5) |
| DocumentRegistry | ExtArch (Token Extensions), Architecture.md (Phase 6) |
| CorporateActions | ExtArch (Token Extensions), Architecture.md (Phase 7) |
| IssuerFactory | ExtArch (Deployment Layer), erc3643-analysis.md (TREXFactory) |

---

## 10. Quick Reference: Where to Find Things

| What | Where | Line(s) |
|---|---|---|
| Extension philosophy | ExtensionArchitecture.md | 31-84 |
| Asset domain model | ExtensionArchitecture.md | 87-165 |
| All vendor components | ExtensionArchitecture.md | 170-268 |
| All platform components | ExtensionArchitecture.md | 272-630 |
| 12 extension rules | ExtensionArchitecture.md | 643-720 |
| Dependency architecture | ExtensionArchitecture.md | 722-811 |
| Upgrade strategy | ExtensionArchitecture.md | 814-885 |
| External integrations | ExtensionArchitecture.md | 888-984 |
| Bridge message spec | ExtensionArchitecture.md | 1042-1135 |
| All Mermaid diagrams | ExtensionArchitecture.md | 1138-1400 |
| Open ADRs | ExtensionArchitecture.md | 1404-1523 |
| Cross-chain topology | CrossChainArchitecture.md | full doc |
| Burn/mint rationale | CrossChainArchitecture.md | 62-101 |
| Per-chain identity | CrossChainArchitecture.md | 109-155 |
| TransferIntent state machine | CrossChainSettlementProtocol.md | 73-141 |
| State transition table | CrossChainSettlementProtocol.md | 132-141 |
| Sequence diagrams | CrossChainSettlementProtocol.md | 152-540 |
| Failure recovery | CrossChainSettlementProtocol.md | 467-540 |
| Extension hooks | CrossChainSettlementProtocol.md | 542-559 |
| Event catalog | CrossChainSettlementProtocol.md | 600-628 |
| Security assumptions | CrossChainSettlementProtocol.md | 633-695 |
| Vendor analysis | erc3643-analysis.md | full doc |
| ProtocolAccessManager API | specs/ProtocolAccessManager.md | full doc |
| Actor definitions | specs/Actors.md | full doc |
