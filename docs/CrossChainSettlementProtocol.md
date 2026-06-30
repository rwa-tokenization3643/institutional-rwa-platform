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
# Cross-Chain Settlement Protocol

## Problem Statement

The current cross-chain architecture commits sender value before destination acceptance:

```
Sender validation → BURN (irrevocable) → CCIP → Receiver validation → MINT (may fail)
```

For institutional settlement this is unacceptable. Participants must know the counterparty
and compliance checks pass on both sides before any value moves. This document defines a
two-phase settlement protocol that mirrors SWIFT, securities settlement, and Delivery-vs-Payment
workflows.

The protocol is an extension layer. It does not modify vendored ERC-3643, ONCHAINID,
Chainlink CCIP, or Chainlink ACE contracts.

---

## Architecture Overview

### New Contracts

| Contract | Chain | Purpose |
|---|---|---|
| `SettlementCoordinator` | Every chain | Orchestrates the two-phase protocol. Manages TransferIntent state machine. |
| `IntentVault` | Every chain | Optionally holds tokens during Phase 1 to prevent double-spending. |
| `CrossChainSettlementModule` | Every chain | T-REX `IModule` compliance module that recognizes settlement intents. |
| `SettlementBridgeAdapter` | Every chain | Outbound: sends Phase 1 validation requests and Phase 2 settlement instructions. |
| `SettlementCCIPReceiver` | Every chain | Inbound: processes remote validation responses and settlement instructions. |

### Communication Flow

```text
 Source Chain                           Destination Chain
 ──────────────────────────────────────────────────────────
  SettlementCoordinator               SettlementCoordinator
       │                                     │
       │  ─── Phase 1: ValidateIntent ────>  │
       │  <─── Phase 1: IntentApproved ────  │
       │                                     │
       │  ─── Phase 2: SettleIntent ──────>  │
       │                                     │
```

Phase 1 messages contain the transfer parameters and a unique intent ID. Phase 2 messages
reference the confirmed intent ID and authorize the mint.

---

## Transfer Intent

A `TransferIntent` is a first-class object representing a proposed cross-chain transfer.
It is created during Phase 1 and consumed during Phase 2 or expired/rolled back.

### Data Structure

```text
struct TransferIntent {
    bytes32 id;                        // Unique intent identifier
    address sender;                    // Token holder on source chain
    address recipient;                 // Token recipient on destination chain
    uint256 amount;                    // Token amount
    bytes32 partition;                 // ERC-1400 partition (bytes32(0) if none)
    uint64 sourceChainSelector;        // CCIP chain selector for source
    uint64 destChainSelector;          // CCIP chain selector for destination
    address sourceToken;               // ERC-3643 token address on source
    address destToken;                 // ERC-3643 token address on destination
    uint256 createdAt;                 // Block timestamp of creation
    uint256 expiry;                    // Block timestamp after which intent expires
    IntentState state;                 // Current lifecycle state
    bytes32 sourceValidationMsgId;     // CCIP message ID from source validation request
    bytes32 destValidationMsgId;       // CCIP message ID from destination approval
}
```

### State Machine

```text
                          ┌──────────────┐
                          │   PENDING    │
                          │  VALIDATION  │
                          └──────┬───────┘
                                 │
                    ┌────────────┴────────────┐
                    │                         │
                    ▼                         ▼
             ┌──────────────┐        ┌──────────────┐
             │  VALIDATED   │        │  REJECTED    │
             │  (CONFIRMED) │        │              │
             └──────┬───────┘        └──────────────┘
                    │
          ┌─────────┴─────────┐
          │                   │
          ▼                   ▼
   ┌──────────────┐   ┌──────────────┐
   │  SETTLED     │   │  EXPIRED     │
   │              │   │              │
   └──────────────┘   └──────────────┘

Recovery path (Phase 2 failure):
   ┌──────────────┐
   │  ROLLED_BACK │
   │              │
   └──────────────┘
```

### State Transitions

| From | To | Trigger | Value Moved |
|---|---|---|---|
| `PENDING_VALIDATION` | `VALIDATED` | Destination chain approves intent via CCIP | No |
| `PENDING_VALIDATION` | `REJECTED` | Destination chain rejects intent via CCIP | No |
| `PENDING_VALIDATION` | `EXPIRED` | `createdAt + expiry` reached | No |
| `VALIDATED` | `SETTLING` | Settlement initiated on source chain | No (burn starts) |
| `SETTLING` | `SETTLED` | Destination CCIP receiver confirms mint | Yes |
| `SETTLING` | `ROLLED_BACK` | Bridge operator invokes rollback after destination failure | Yes (recovery) |
| `VALIDATED` | `EXPIRED` | `createdAt + expiry` reached before settlement | No |
| `VALIDATED` | `REJECTED` | Compliance officer or bridge operator cancels | No |
| `REJECTED` | (terminal) | - | No |
| `EXPIRED` | (terminal) | - | No |
| `SETTLED` | (terminal) | - | Yes |
| `ROLLED_BACK` | (terminal) | - | Yes (reversed) |

---

## Phase 1: Pre-Settlement Validation

Phase 1 validates the entire transfer on both chains without moving any value.
It is the institutional equivalent of a SWIFT MT300 confirmation or a securities
trade confirmation before settlement.

### Sequence: Phase 1 Success

```text
User          SettlementCoordinator     Source Identity    Source Compliance     CCIP      Dest SettlementCoordinator     Dest Identity    Dest Compliance
 │                     │                       │                  │              │                │                          │                  │
 │-- initiateIntent -->│                       │                  │              │                │                          │                  │
 │  (dest, to, amt)    │                       │                  │              │                │                          │                  │
 │                     │                       │                  │              │                │                          │                  │
 │                     │-- validateSender ----->│                  │              │                │                          │                  │
 │                     │   (check IdentityReg) │                  │              │                │                          │                  │
 │                     │<-- identity ok -------│                  │              │                │                          │                  │
 │                     │                       │                  │              │                │                          │                  │
 │                     │-- checkSourceCompl -->│                  │              │                │                          │                  │
 │                     │   (ModularCompliance) │                  │              │                │                          │                  │
 │                     │   + ACEAdapter        │                  │              │                │                          │                  │
 │                     │<-- compliance ok -----│                  │              │                │                          │                  │
 │                     │                       │                  │              │                │                          │                  │
 │                     │-- checkBalance ------>│   (Token)        │              │                │                          │                  │
 │                     │   (balance >= amt)    │                  │              │                │                          │                  │
 │                     │<-- balance ok --------│                  │              │                │                          │                  │
 │                     │                       │                  │              │                │                          │                  │
 │                     │ Creates TransferIntent                    │              │                │                          │                  │
 │                     │ state=PENDING_VALIDATION                  │              │                │                          │                  │
 │                     │                       │                  │              │                │                          │                  │
 │                     │-- sendValidateIntent ->│                  │--- msg ---->│                          │                  │
 │                     │  (CCIP)                │                  │              │-- receiveValidateIntent ->│                  │
 │                     │                       │                  │              │    (sender, rec, amt)     │                  │
 │                     │                       │                  │              │                           │                  │
 │                     │                       │                  │              │    -- validateRecipient -->│                  │
 │                     │                       │                  │              │    (check IdentityReg)   │                  │
 │                     │                       │                  │              │    <-- identity ok -------│                  │
 │                     │                       │                  │              │                           │                  │
 │                     │                       │                  │              │    -- checkDestCompl ---->│                  │
 │                     │                       │                  │              │    (ModularCompliance)   │                  │
 │                     │                       │                  │              │    + ACEAdapter          │                  │
 │                     │                       │                  │              │    <-- compliance ok ----│                  │
 │                     │                       │                  │              │                           │                  │
 │                     │                       │                  │              │    -- checkHoldingLimits-> │   (Partition)   │
 │                     │                       │                  │              │    <-- holding ok -------│                  │
 │                     │                       │                  │              │                           │                  │
 │                     │                       │                  │              │    Intent stored locally │                  │
 │                     │                       │                  │              │    state=PENDING_LOCAL   │                  │
 │                     │                       │                  │              │                           │                  │
 │                     │                       │                  │              │-- sendIntentApproval --->│                  │
 │                     │                       │                  │<--- msg -----│   (intentId, approved)   │                  │
 │                     │                       │                  │              │                           │                  │
 │                     │-- receiveApproval --->│                  │              │                           │                  │
 │                     │   state=VALIDATED     │                  │              │                           │                  │
 │                     │                       │                  │              │                           │                  │
 │<-- IntentConfirmed -│                       │                  │              │                           │                  │
 │                     │                       │                  │              │                           │                  │
```

### Expiry Clock

The expiry counter starts when the intent enters `PENDING_VALIDATION` state on the
source chain. The expiry duration is a configurable parameter controlled by `COMPLIANCE_ROLE`.

Recommended default: 24 hours.

If the destination chain has not responded before expiry, the source-side
`SettlementCoordinator` transitions the intent to `EXPIRED`. The destination chain
detects the expiry when it receives a stale intent message and discards it.

### Rejection Handling

The destination chain may reject during Phase 1 for any compliance reason:
- Recipient identity not verified
- Recipient in restricted jurisdiction
- Holding limit would be exceeded
- ACE policy violation

Rejection is communicated via CCIP with a reason code. The source chain transitions
the intent to `REJECTED`. No value has moved.

---

## Phase 2: Settlement Execution

Phase 2 executes the transfer only after Phase 1 confirmed both sides are compliant.
This is the institutional equivalent of SWIFT MT202 settlement or DvP delivery.

### Sequence: Phase 2 Success

```text
User/Relayer     SettlementCoordinator     Source Token     CCIP        Dest SettlementCoordinator     Dest Token
 │                       │                     │              │                 │                         │
 │-- settleIntent ------>│                     │              │                 │                         │
 │  (intentId)           │                     │              │                 │                         │
 │                       │                     │              │                 │                         │
 │                       │-- validateState --->│              │                 │                         │
 │                       │   (state=VALIDATED) │              │                 │                         │
 │                       │   (expiry not hit)  │              │                 │                         │
 │                       │   (balance >= amt)  │              │                 │                         │
 │                       │<-- state ok --------│              │                 │                         │
 │                       │                     │              │                 │                         │
 │                       │-- transitionState ->│              │                 │                         │
 │                       │   state=SETTLING    │              │                 │                         │
 │                       │                     │              │                 │                         │
 │                       │-- burn(recip,amt) ->│              │                 │                         │
 │                       │   (via BURNER_ROLE) │              │                 │                         │
 │                       │<-- burn ok ---------│              │                 │                         │
 │                       │                     │              │                 │                         │
 │                       │-- sendSettleIntent >│-- msg ------>│                         │
 │                       │   (intentId)        │              │-- receiveSettle --->│         │
 │                       │                     │              │                     │          │
 │                       │                     │              │  -- verifyState --->│          │
 │                       │                     │              │  <-- state ok ------│          │
 │                       │                     │              │                     │          │
 │                       │                     │              │  -- mint(sender,amt)│─ mint -->│
 │                       │                     │              │   (via BURNER_ROLE) │          │
 │                       │                     │              │  <-- mint ok -------│          │
 │                       │                     │              │                     │          │
 │                       │                     │              │  state=SETTLED_LOCAL│          │
 │                       │                     │              │                     │          │
 │                       │                     │              │-- sendSettlementAck>│          │
 │                       │<-- receiveAck ------│<--- msg -----│  (intentId)         │          │
 │                       │                     │              │                     │          │
 │                       │ state=SETTLED       │              │                     │          │
 │                       │                     │              │                     │          │
 │<-- IntentSettled -----│                     │              │                     │          │
 │                       │                     │              │                     │          │
```

### Settlement Invocation

Settlement may be invoked by:
1. **The user** who initiated the intent (after receiving confirmation that Phase 1 passed).
2. **A relayer** operated by the Bridge Operator that monitors `VALIDATED` intents and settles them automatically.
3. **The backend API** after off-chain compliance review.

The gas cost of settlement is borne by the invoker. For relayers, the protocol may
offer a small gas rebate or the user pre-pays gas in a relayer contract.

### Balance Check at Settlement Time

The `settleIntent` function checks that the sender still has a sufficient balance at
settlement time. If the sender moved tokens between Phase 1 and Phase 2:

1. `settleIntent` reverts with `InsufficientBalance`.
2. The intent remains in `VALIDATED` state.
3. The sender can acquire tokens and retry settlement, or explicitly cancel the intent.

This avoids locking tokens during Phase 1 while still guaranteeing the destination
will accept at settlement time. The risk exposure is bounded to the Phase 1 window,
which is configurable (recommended: 24 hours).

---

## TransferIntent Lifecycle (Complete View)

```text
 Time │
      │
      │  User initiates intent
      │      │
      │      ▼
      │  ┌──────────────────────────────────────────────────────┐
      │  │  PENDING_VALIDATION                                 │
      │  │  • Source: sender, compliance, balance checked      │
      │  │  • CCIP: validation request sent to destination     │
      │  └──────────────────────────────────────────────────────┘
      │      │                               │
      │      │ Destination approves          │ Destination rejects │ Expiry reached
      │      ▼                               ▼                    ▼
      │  ┌──────────────┐            ┌──────────────┐    ┌──────────────┐
      │  │  VALIDATED   │            │  REJECTED    │    │  EXPIRED     │
      │  │  • Ready for  │            │  • No value   │    │  • No value   │
      │  │    settlement │            │    moved     │    │    moved     │
      │  └──────┬───────┘            └──────────────┘    └──────────────┘
      │         │
      │         │ Settlement initiated
      │         ▼
      │  ┌──────────────┐
      │  │  SETTLING    │
      │  │  • Burn executed on source
      │  │  • CCIP settlement sent
      │  └──────┬───────┘
      │         │
      │    ┌────┴────┐
      │    ▼         ▼
      │  ┌──────┐ ┌──────────┐
      │  │SETTLED│ │ROLLED_BACK│
      │  │• Mint │ │• Re-mint  │
      │  │  done │ │  on source│
      │  └──────┘ └──────────┘
      ▼
```

---

## Timeout Handling

### Source-Side Timeout (Phase 1)

If the destination chain does not respond to a validation request before the
intent's `expiry` timestamp, the source `SettlementCoordinator` transitions the
intent to `EXPIRED`.

```
Function: expireIntent(bytes32 intentId)
Called by: anyone (public, gas-compensated cleanup)
Effect: state → EXPIRED if (block.timestamp > intent.expiry)
```

The destination chain independently enforces the same deadline on its side.
When it receives a `ValidateIntent` message with a stale `expiry`, it discards
it silently.

### Destination-Side Timeout (Phase 1)

The destination `SettlementCoordinator` stores received `ValidateIntent` messages
with their `expiry`. If settlement is not initiated before `expiry`, the destination
entry is eligible for cleanup.

### Settlement Window (Phase 2)

Once an intent is in `VALIDATED` state, settlement must occur before `expiry`.
If `expiry` is reached while the intent is still `VALIDATED`, it transitions to
`EXPIRED` and cannot be settled.

The sender must re-initiate (create a new intent) if they still wish to transfer.

### Cross-Chain Clock Considerations

Block timestamps on different chains may differ by minutes to hours. The protocol
uses the source chain's timestamp as the authoritative reference. A configurable
**clock drift tolerance** (default: 30 minutes) is added to the destination side:

```
dest_side_expiry = intent.expiry + clockDriftTolerance
```

This prevents premature expiration due to chain timestamp divergence.

---

## Replay Protection

### Intent ID Uniqueness

The intent ID is computed as:

```
intentId = keccak256(
    abi.encode(sender, recipient, amount, partition,
               sourceChainSelector, destChainSelector,
               sourceToken, destToken, block.timestamp, userNonce)
)
```

`userNonce` is a per-sender counter incremented on each `initiateIntent` call.
This ensures intent IDs are globally unique even if the same user submits the
same transfer parameters multiple times.

### CCIP Message Uniqueness

- Phase 1 validation requests are tagged with `intentId`.
- The destination `SettlementCCIPReceiver` stores processed `intentId` values and
  rejects duplicates.
- Phase 2 settlement messages reference `intentId` and the destination verifies
  the intent is in the expected state (`PENDING_LOCAL` → `SETTLING` on destination).

### Nonce Per Sender

The `SettlementCoordinator` maintains a `userNonce[userAddress]` counter.
This prevents:
- Intent ID collisions
- Replay of old `initiateIntent` transactions
- Front-running of intent creation with identical parameters

---

## Failure Recovery

### Classification of Failures

| Failure | Phase | Impact | Recovery |
|---|---|---|---|
| Destination compliance rejects | Phase 1 | None | Intent → REJECTED. User notified. |
| Timeout before destination response | Phase 1 | None | Intent → EXPIRED. User retries. |
| Balance insufficient at settlement | Phase 2 | None | `settleIntent` reverts. Intent stays VALIDATED. |
| Burn succeeds, CCIP fails | Phase 2 | Tokens burned but not delivered | CCIP manual retry. |
| CCIP delivered, mint fails | Phase 2 | Tokens burned, CCIP gas used | CCIP manual retry after fixing mint issue. |
| Mint fails permanently | Phase 2 | Tokens burned, cannot mint | Rollback: re-mint on source. |

### Phase 1 Failures

Phase 1 failures never move value. They are handled by state transitions:

- **Destination rejects** → `REJECTED`. The `Rejected` event includes a `reasonCode`
  for off-chain analysis.
- **Timeout** → `EXPIRED`. Any party may call `expireIntent()` and receive a gas rebate.

### Phase 2 Failures

#### Case: Burn succeeds, CCIP message delivery fails

CCIP's `ManualExecution` allows the Bridge Operator to retry message delivery.
The Operator monitors for `BurnExecuted` events without corresponding
`SettlementAck` events and retries delivery via the CCIP router.

```text
Bridge Operator     SettlementCoordinator (source)     CCIP     SettlementCoordinator (dest)
 │                            │                        │                  │
 │-- detectMissingAck() ---->│                        │                  │
 │   (burned but no ack)     │                        │                  │
 │                            │                        │                  │
 │-- retryDelivery(intentId)->│-- ccipRetry() ------->│--- msg --------->│
 │                            │                        │                  │-- mint() --+
 │                            │                        │                  │            │
 │                            │                        │<-- ack ----------│<-----------+
 │                            │                        │                  │
 │                            │-- receiveAck --------->│                  │
 │                            │ state=SETTLED          │                  │
```

#### Case: Delivery succeeds, mint fails (compliance changed between phases)

If the recipient's compliance status changed between Phase 1 and Phase 2:

1. `mint()` on the destination reverts.
2. The destination `SettlementCoordinator` does NOT transition to `SETTLED`.
3. The CCIP execution fails; CCIP returns a failure event.
4. The Bridge Operator invokes `rollbackIntent()` on the source chain's
   `SettlementCoordinator` (or via `BridgeCoordination` on the canonical chain).

```text
Bridge Operator     SettlementCoordinator (source)     Source Token     BridgeCoordination (canonical)
 │                            │                            │                    │
 │                            │                            │                    │
 │-- rollbackIntent -------->│                            │                    │
 │   (intentId, reason)      │                            │                    │
 │                            │-- verifyBurnExecuted ----->│                    │
 │                            │   (event log)             │                    │
 │                            │<-- burn confirmed --------│                    │
 │                            │                            │                    │
 │                            │-- requestReMint --------->│                    │
 │                            │   (sender, amount)        │                    │
 │                            │                            │-- mint(sender,amt)>│
 │                            │                            │<-- mint ok -------│
 │                            │                            │                    │
 │                            │ state=ROLLED_BACK          │                    │
 │                            │                            │                    │
 │<-- RollbackCompleted ------│                            │                    │
```

### Manual Intervention

Manual operations are available to `BRIDGE_ROLE` and `COMPLIANCE_ROLE`:

| Operation | Role | Effect |
|---|---|---|
| `forceCancel(bytes32 intentId)` | `COMPLIANCE_ROLE` | Cancels a VALIDATED intent (e.g., after discovering sanctioned address). |
| `rollbackIntent(bytes32 intentId)` | `BRIDGE_ROLE` | Re-mints on source after confirmed destination failure. |
| `retryDelivery(bytes32 intentId)` | `BRIDGE_ROLE` | Retries CCIP delivery for a stuck Phase 2 message. |
| `emergencyPause()` | `PAUSER_ROLE` | Halts all new intent creation on a chain. |
| `emergencyUnpause()` | `PAUSER_ROLE` | Resumes intent creation. |

### Graceful Shutdown

If a mirror chain must be decommissioned:
1. `PAUSER_ROLE` pauses the chain's `SettlementCoordinator`.
2. Open `VALIDATED` intents must be settled or cancelled.
3. A configurable cooldown period allows pending intents to resolve.
4. After cooldown, `BRIDGE_ROLE` cancels remaining intents (re-minting if burned).
5. The chain is removed from `ChainRegistry`.
6. Investors are notified to move tokens back to the canonical chain.

---

## Idempotency

Every state-mutating operation is idempotent:

| Function | Idempotency Mechanism |
|---|---|
| `initiateIntent` | Reverts if `userNonce[sender]` already used for same parameters. |
| `settleIntent` | Reverts if intent state is not `VALIDATED`. |
| `expireIntent` | Reverts if intent is already expired or settled. |
| `rollbackIntent` | Reverts if intent is not in a recoverable state. |
| CCIP receive validation | Reverts if `intentId` already processed. |
| CCIP receive settlement | Reverts if intent already settled on destination. |

Idempotency ensures that relayer retries, block reorgs, and duplicate CCIP deliveries
never result in double-settlement or double-burn.

---

## Audit Events

Every intent state transition emits an event:

```text
event IntentCreated(
    bytes32 indexed intentId,
    address indexed sender,
    address indexed recipient,
    uint256 amount,
    bytes32 partition,
    uint64 sourceChainSelector,
    uint64 destChainSelector,
    address sourceToken,
    address destToken,
    uint256 expiry
);

event IntentValidated(
    bytes32 indexed intentId,
    uint64 destChainSelector,
    bytes32 destValidationMsgId
);

event IntentSettled(
    bytes32 indexed intentId,
    uint256 amount,
    bytes32 sourceBurnMsgId
);

event IntentRejected(
    bytes32 indexed intentId,
    uint8 reasonCode,
    bytes reasonData
);

event IntentExpired(
    bytes32 indexed intentId
);

event IntentRolledBack(
    bytes32 indexed intentId,
    address recoveredTo,
    uint256 amount,
    uint8 reasonCode
);

event IntentForceCancelled(
    bytes32 indexed intentId,
    address cancelledBy
);
```

All events are indexed for off-chain monitoring, audit, and reconciliation.

---

## Security Assumptions

### Smart Contract Security

- `SettlementCoordinator` and all bridge contracts use UUPS upgradeable proxies.
- State transitions strictly follow the state machine; invalid transitions revert.
- Access control is enforced via `ProtocolAccessManager` roles.
- Reentrancy guards on all external-facing state-mutation functions.
- CCIP message authentication uses Chainlink's `msg.sender` router validation plus
  explicit `allowedSenders` mapping.

### Balance Integrity

- The `settleIntent` function performs a fresh balance check at settlement time.
- Burn is executed on the ERC-3643 token via the `BURNER_ROLE` that the
  `SettlementCoordinator` holds.
- Re-mint during rollback is executed on the canonical chain via `BridgeCoordination`.
- No function ever mints without a corresponding burn event verified on-chain.

### Cross-Chain Message Integrity

- Phase 1 validation requests include the `intentId` to prevent message spoofing.
- Phase 2 settlement messages require the `intentId` to be in `VALIDATED` state on
  the source (proving Phase 1 passed).
- The destination verifies that the source chain and source sender are registered
  in `ChainRegistry` and `allowedSenders` respectively.
- CCIP's built-in message sequencing and RMN attestation provide additional integrity.

---

## Trust Assumptions

### SettlementCoordinator Admin

- `DEFAULT_ADMIN_ROLE` controls role assignments across all settlement contracts.
- Trusted to not grant `BURNER_ROLE` or `MINTER_ROLE` to unauthorized accounts.
- Mitigation: Multi-sig wallet. All role changes emit events.

### Bridge Operator

- `BRIDGE_ROLE` is authorized to invoke `retryDelivery`, `rollbackIntent`, and
  other recovery operations.
- Trusted to only invoke recovery when genuinely stuck.
- Mitigation: Recovery operations emit events. Off-chain monitor alerts on anomalies.

### Compliance Officer

- `COMPLIANCE_ROLE` can force-cancel intents and adjust compliance parameters.
- Trusted to exercise cancellation only for legitimate compliance reasons.
- Mitigation: Cancellation requires a reason code. All cancellations are logged and auditable.

### CCIP Infrastructure

- Chainlink CCIP routers and donnetworks are trusted to deliver messages correctly.
- CCIP's RMN provides finality guarantees.
- Mitigation: Rate limits, `allowedSenders`, event monitoring.

### ACE Policies

- ACE policies evaluated during Phase 1 are trusted to remain stable until Phase 2.
- If a policy changes between phases, the destination may reject at settlement.
- Mitigation: Policy change cooldown. Compliance officers coordinate policy changes
  with settlement windows.

### Relayer Incentives

- Relayers executing `settleIntent` pay gas costs.
- The protocol assumes relayers are operated by the Bridge Operator or are
  incentivized by the protocol or the user (via a gas rebate or fee).

---

## Sequence Diagrams

### Complete Two-Phase Transfer: Success

```text
User         Source              Source     Source        CCIP        Dest            Dest      Dest
             SettlementCoord     Identity   Compliance               SettlementCoord  Identity  Compliance
 │                  │               │           │           │             │              │          │
 │  initiateIntent  │               │           │           │             │              │          │
 │ ────────────────>│               │           │           │             │              │          │
 │  (to, amt)       │               │           │           │             │              │          │
 │                  │               │           │           │             │              │          │
 │      █████████████  Phase 1  ████████████████████████████████████████████████████████████       │
 │      █            │           │           │           │             █              │          │
 │      █            │─ chkSend->│           │           │             █              │          │
 │      █            │<─ idOk ---│           │           │             █              │          │
 │      █            │─ chkCompl>│           │           │             █              │          │
 │      █            │<─ compOk ─│           │           │             █              │          │
 │      █            │─ chkBal ->│           │           │             █              │          │
 │      █            │<─ balOk ──│           │           │             █              │          │
 │      █            │           │           │           │             █              │          │
 │      █            │ intent=PENDING_VALID  │           │             █              │          │
 │      █            │           │           │           │             █              │          │
 │      █            │── sendValidateIntent ─│── msg ───>│─ receive ─>█              │          │
 │      █            │           │           │           │             █── chkRecip->│          │
 │      █            │           │           │           │             █<─ idOk -----│          │
 │      █            │           │           │           │             █── chkCompl─>│          │
 │      █            │           │           │           │             █<─ compOk ---│          │
 │      █            │           │           │           │             █── chkHold ─>│          │
 │      █            │           │           │           │             █<─ holdOk ---│          │
 │      █            │           │           │           │             █             │          │
 │      █            │           │           │           │             █ local=PENDING_LOCAL  │
 │      █            │           │           │           │             █             │          │
 │      █            │           │           │           │<── approved ─█             │          │
 │      █            │<────── approval ──────│<── msg ───│             █              │          │
 │      █            │           │           │           │             █              │          │
 │      █████████████  Phase 1 complete  ████████████████████████████████████████████████       │
 │                  │           │           │           │             │              │          │
 │<─ IntentConfirmed│ intent=VALIDATED      │           │             │              │          │
 │                  │           │           │           │             │              │          │
 │                  │           │           │           │             │              │          │
 │      █████████████  Phase 2  ████████████████████████████████████████████████████████████       │
 │                  │           │           │           │             │              │          │
 │ settleIntent     │           │           │           │             │              │          │
 │ ────────────────>│           │           │           │             │              │          │
 │                  │─ chkState>│           │           │             │              │          │
 │                  │<─ ok -----│           │           │             │              │          │
 │                  │─ chkBal ->│(Token)    │           │             │              │          │
 │                  │<─ balOk --│           │           │             │              │          │
 │                  │           │           │           │             │              │          │
 │                  │ state=SETTLING        │           │             │              │          │
 │                  │           │           │           │             │              │          │
 │                  │── burn() ────>│       │           │             │              │          │
 │                  │<─ ok ─────────│       │           │             │              │          │
 │                  │           │           │           │             │              │          │
 │                  │── sendSettle ─────────│── msg ───>│─ receive ──>│              │          │
 │                  │           │           │           │             │── mint() ──────────────>│
 │                  │           │           │           │             │<─ ok ───────────────────│
 │                  │           │           │           │             │             │          │
 │                  │           │           │           │             │ state=SETTLED_LOCAL    │
 │                  │           │           │           │             │             │          │
 │                  │           │           │           │<── ack ─────│             │          │
 │                  │<──────── ack ─────────│<── msg ───│             │              │          │
 │                  │           │           │           │             │              │          │
 │                  │ state=SETTLED         │           │             │              │          │
 │                  │           │           │           │             │              │          │
 │<─ IntentSettled ─│           │           │           │             │              │          │
 │                  │           │           │           │             │              │          │
 │      █████████████  Settlement complete ████████████████████████████████████████████████       │
```

### Phase 1 Rejection

```text
User        Source SettlementCoord     Source Compliance     CCIP      Dest SettlementCoord    Dest Compliance
 │                    │                      │                │               │                    │
 │ initiateIntent     │                      │                │               │                    │
 │ ──────────────────>│                      │                │               │                    │
 │                    │── validateSender ---─>│               │               │                    │
 │                    │<── ok ───────────────│                │               │                    │
 │                    │── checkSourceCompl ──>│               │               │                    │
 │                    │<── ok ───────────────│                │               │                    │
 │                    │                      │                │               │                    │
 │                    │── sendValidateIntent ─│── msg ──────>│               │                    │
 │                    │                      │                │── validate ->│                    │
 │                    │                      │                │   recipient  │                    │
 │                    │                      │                │              │                    │
 │                    │                      │                │── checkDest >│                    │
 │                    │                      │                │   compliance │                    │
 │                    │                      │                │<── REJECT ---│                    │
 │                    │                      │                │   (reason)   │                    │
 │                    │                      │                │              │                    │
 │                    │<── rejection ────────│<── msg ───────│              │                    │
 │                    │                      │                │               │                    │
 │                    │ state=REJECTED       │                │               │                    │
 │                    │                      │                │               │                    │
 │<── IntentRejected ─│                      │                │               │                    │
 │    (reasonCode)    │                      │                │               │                    │
```

### Phase 2 Mint Failure and Rollback

```text
User/Relayer   Source SCoord     Source Token   CCIP      Dest SCoord     Dest Token   BridgeCoord (canonical)
 │                   │               │          │             │               │               │
 │ settleIntent      │               │          │             │               │               │
 │ ─────────────────>│               │          │             │               │               │
 │                   │ state=SETTLING│          │             │               │               │
 │                   │-- burn() ---->│          │             │               │               │
 │                   │<-- ok --------│          │             │               │               │
 │                   │               │          │             │               │               │
 │                   │-- sendSettle ─│── msg ──>│-- receive >│               │               │
 │                   │               │          │             │-- mint() ────>│               │
 │                   │               │          │             │               │               │
 │                   │               │          │             │  COMPLIANCE   │               │
 │                   │               │          │             │  REVERTS      │               │
 │                   │               │          │             │               │               │
 │                   │               │          │<── exec     │               │               │
 │                   │               │          │   failed ──│               │               │
 │                   │               │          │             │               │               │
 │                   │               │          │             │               │               │
 │                   │  (Operator detects stuck intent)       │               │               │
 │                   │               │          │             │               │               │
 │ Bridge Operator   │               │          │             │               │               │
 │ ─────────────────>│               │          │             │               │               │
 │ rollbackIntent()  │               │          │             │               │               │
 │                   │-- verifyBurn >│          │             │               │               │
 │                   │<-- confirmed -│          │             │               │               │
 │                   │               │          │             │               │               │
 │                   │               │          │             │               │               │
 │                   │-- requestReMint(intentId, sender, amt) ──────────────>│               │
 │                   │               │          │             │               │-- mint() ---->│
 │                   │               │          │             │               │   (canonical) │
 │                   │               │          │             │               │<-- ok --------│
 │                   │               │          │             │               │               │
 │                   │ state=ROLLED_BACK       │             │               │               │
 │                   │               │          │             │               │               │
 │<-- RolledBack ----│               │          │             │               │               │
 │   (sender, amt)   │               │          │             │               │               │
```

### Cross-Chain Intent Status Reconciliation

```text
Off-Chain Monitor          Source SCoord               Dest SCoord
     │                            │                          │
     │-- queryIntent(id) -------->│                          │
     │<-- state=SETTLED ----------│                          │
     │                            │                          │
     │                   -- queryIntent(id) ---------------->│
     │                   <-- state=SETTLED_LOCAL ------------│
     │                            │                          │
     │  Match: source=SETTLED, dest=SETTLED_LOCAL            │
     │  → Intent is fully settled.                           │
     │                            │                          │
     │                            │                          │
     │-- queryIntent(id2) ------->│                          │
     │<-- state=SETTLING ---------│                          │
     │                            │                          │
     │                  -- queryIntent(id2) ---------------->│
     │                  <-- state=PENDING_LOCAL -------------│
     │                            │                          │
     │  MISMATCH: source burned but dest not minted.         │
     │  → Alert Bridge Operator for retry or rollback.       │
```

---

## Extension Points

| Hook | Called At | Purpose |
|---|---|---|
| `beforeIntentCreated` | `initiateIntent` start | Custom validation, fee collection |
| `afterIntentValidated` | Intent reaches `VALIDATED` | Off-chain notification, relayer trigger |
| `beforeSettlement` | `settleIntent` start | Final balance check, additional compliance |
| `afterSettled` | Intent reaches `SETTLED` | Post-settlement accounting, DvP trigger |
| `onRollback` | Intent reaches `ROLLED_BACK` | Off-chain reconciliation, user notification |

These hooks are implemented as external callback contracts registered by the
Protocol Administrator. They allow future modules (e.g., fee collection, DvP
integration, corporate actions) to observe and react to settlement events without
modifying the core protocol.

---

## Contract Summary

| Contract | Extends | Key Functions |
|---|---|---|
| `SettlementCoordinator` | UUPS upgradeable | `initiateIntent`, `settleIntent`, `expireIntent`, `rollbackIntent`, `forceCancel` |
| `SettlementCCIPReceiver` | `CCIPReceiver` | `ccipReceive` (validate + settle) |
| `SettlementBridgeAdapter` | - | `sendValidateIntent`, `sendSettleIntent`, `retryDelivery` |
| `IntentVault` | Optional, UUPS upgradeable | `deposit`, `withdraw`, `lock`, `unlock` |
| `CrossChainSettlementModule` | T-REX `IModule` | `moduleCheck` (recognizes settlement-bound burns) |
| `BridgeCoordination` | UUPS upgradeable | `reMint`, `rollbackBurn`, `totalSupplyAcrossChains` |

All contracts reside in `protocol/contracts/extensions/bridge/` and
`protocol/contracts/extensions/compliance/`. No vendored ERC-3643, ONCHAINID,
CCIP, or ACE contracts are modified.
