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
# Cross-Chain Architecture

## Scope

This document defines the cross-chain architecture for compliant institutional RWA transfers built on ERC-3643 (T-REX), ONCHAINID, Chainlink CCIP, and Chainlink ACE. It covers topology, token model, identity, compliance, messaging, failure recovery, and upgrade strategy.

All recommendations extend the vendored T-REX and ONCHAINID contracts without modification, using adapters, compliance modules, and bridge contracts in `protocol/contracts/extensions/`.

---

## Canonical Chain

The **issuance chain** is the canonical chain.

- The ERC-3643 token is originally deployed and minted on the issuance chain.
- The issuance chain holds the authoritative total supply record.
- Issuer-initiated corporate actions (mints, burns, distributions, splits) originate here.
- The issuance chain is selected at protocol deployment and does not change without a governance-managed migration.

Selection criteria:
- Regulatory domicile of the issuer
- Institutional custody availability
- Chainlink CCIP and ACE availability
- Transaction finality characteristics

All token supply changes (issuance, redemption) happen on the canonical chain. Cross-chain transfers move existing supply between chains; they never create or destroy value.

---

## Mirror Chains

A **mirror chain** hosts a compliant ERC-3643 token contract that represents the asset on that chain.

- Mirror tokens are deployed via the same `TREXFactory` pattern with proxy-and-implementation-authority.
- Mirror token addresses are registered in a protocol-managed `ChainRegistry` contract on the canonical chain.
- Mirror tokens are **not** independently issuable. Only the bridge adapter can mint mirror supply, and only in response to a verified burn on the source chain.

Chain onboarding criteria:
- CCIP router support
- Regulatory assessment by Compliance Officer
- Bridge infrastructure deployment
- Identity registry deployment and bootstrap

Mirror chains may be added or removed by the Protocol Administrator with appropriate compliance review.

---

## Burn/Mint vs Lock/Mint Analysis

### Lock/Mint

| Aspect | Assessment |
|---|---|
| Total supply clarity | Two representations exist simultaneously. Total supply across chains is not the canonical supply. |
| Regulatory fit | Regulators see "live" tokens on multiple chains simultaneously. Harder to audit total outstanding. |
| Failure case | If unlock fails on the source chain, tokens are locked forever but mirrored supply remains in circulation. |
| Partition tracking | Locked tokens retain their partition on the source chain; mirrored tokens have the same partition on the destination. Dual entries complicate reconciliation. |
| Compliance | Source-chain identity registry sees locked balances; destination registry sees mirrored balances. Compliance must be enforced on both sides independently. |
| Upgrade complexity | Lock vault is an additional contract requiring upgrade coordination. |

### Burn/Mint

| Aspect | Assessment |
|---|---|
| Total supply clarity | Supply moves atomically with the burn. Total supply at any moment equals the canonical supply. |
| Regulatory fit | At any point, the sum across chains equals the canonical supply. Clear audit trail. |
| Failure case | If mint fails on destination, tokens are burned on source and lost. Requires robust retry and recovery. |
| Partition tracking | Partition is encoded in the burn event and restored on mint at destination. No dual entries. |
| Compliance | Source chain verifies the sender before burn (transfer out of their wallet). Destination chain verifies the recipient before mint. Each chain enforces its own compliance at its boundary. |
| Upgrade complexity | Relies on existing `_burn` in T-REX `Token.sol` and a controlled mint path via the bridge adapter. No lock vault needed. |

### Recommendation

**Burn/Mint** is the recommended model for institutional RWAs.

Rationale:
1. Regulatory clarity: supply is always canonical; no double-representation risk.
2. Simpler audit: sum of balances across all chains equals the issuance chain's minted total minus redemptions.
3. No lock vault: reduces attack surface and upgrade burden.
4. Aligns with ERC-3643's existing burn mechanism: `Token.sol` already implements `_burn`. The bridge adapter only needs authority to mint.

The risk of failed mints is mitigated by:
- CCIP's built-in retry mechanism
- A `BridgeCoordination` contract on the canonical chain that holds a retry buffer
- Off-chain monitoring and manual retry by Bridge Operator

---

## Identity Synchronization

ONCHAINID identities are chain-native. An identity contract deployed on chain A has no automatic representation on chain B.

### Strategy: Per-Chain Identity Registries with Claim Relay

Each chain runs its own:
- `IdentityRegistry` (from T-REX)
- `ClaimTopicsRegistry` (from T-REX)
- `TrustedIssuersRegistry` (from T-REX)
- ONCHAINID `Identity` contracts

Identity synchronization follows these rules:

1. **Investors register on each chain independently.** An investor deploys or links an ONCHAINID identity on each chain where they intend to hold tokens. The identity address on each chain may differ.

2. **The canonical chain's IdentityRegistry is the source of truth for identity-address links.** When an investor is verified on the canonical chain, the link between their wallet, their identity, and their claims is established there.

3. **Claim relay via CCIP.** When an investor is verified on the canonical chain, a CCIP message relays their identity metadata (claim topic, issuer, status) to registered mirror chains. A `CrossChainIdentitySync` adapter on each mirror chain receives these messages and updates the local `ClaimTopicsRegistry` and `TrustedIssuersRegistry` as needed.

4. **Identity Registry links are independently maintained.** A wallet address on a mirror chain may link to a different ONCHAINID identity than the same wallet on the canonical chain. The bridge validates that the `_msgSender()` on the source chain has a verified identity before allowing a burn-to-bridge.

5. **Compliance officers may pre-verify investors on mirror chains.** The off-chain backend can pre-register identities on mirror chains before the first cross-chain transfer, avoiding the need for CCIP relay latency during the first transfer.

### Extension Contracts

- `CrossChainIdentitySync`: CCIP receiver that updates mirror-chain registries.
- `IdentityRegistryAdapter`: Wraps the T-REX `IdentityRegistry` to allow programmatic registration by the bridge adapter.

---

## Compliance Execution

Compliance is evaluated on both the source and destination chains independently.

### Source-Chain Compliance (Before Burn)

Before burning tokens for a cross-chain transfer, the bridge adapter on the source chain verifies:

1. `_msgSender()` has a verified identity in the source `IdentityRegistry`.
2. The source `ModularCompliance` allows the transfer (via `canTransfer(from, address(0), amount)` with a compliance module that recognizes cross-chain burns).
3. The sender's balance (including partition considerations) is sufficient.

The compliance module `CrossChainTransferComplianceModule` extends `IModule` and checks:
- The destination chain is a registered mirror chain.
- The sender is not in a restricted jurisdiction for outbound transfers.
- The transfer does not violate holding limits on the source side.

### Destination-Chain Compliance (Before Mint)

Before minting on the destination chain, the bridge adapter verifies:

1. The recipient has a verified identity in the destination `IdentityRegistry`.
2. The destination `ModularCompliance` allows the mint (via `canTransfer(address(0), to, amount)`).
3. The recipient's partition and holding limits on the destination chain are satisfied.

The destination compliance runtime runs the same `ModularCompliance` dispatcher with chain-specific compliance modules:
- `CountryRulesModule` — jurisdiction-based restrictions for the destination chain
- `HoldingRulesModule` — investor/holding limits
- `InvestorRulesModule` — KYC/accreditation checks

### ACE Integration

Chainlink ACE policies are evaluated via the `ACEAdapter` on each chain independently:

- The `ACEAdapter` implements `IModule` and is registered as a compliance module in `ModularCompliance`.
- Before a cross-chain burn or mint, `ModularCompliance` calls `moduleCheck()` on the `ACEAdapter`.
- The `ACEAdapter` evaluates the transfer against ACE-based policies (e.g., sanctions screening, jurisdiction blocks, wallet velocity).
- ACE policies are deployed independently on each chain and configured by the Compliance Officer.

---

## Chainlink CCIP Integration Points

CCIP is the cross-chain messaging layer. Integration occurs at the following points:

### Bridge Adapter (Outbound)

`protocol/contracts/extensions/bridge/CCIPBridge.sol`

- Invoked by the user or Bridge Operator to initiate a cross-chain transfer.
- Locks in the sender, recipient, amount, partition, and destination chain.
- Calls the source token's `_burn` to remove supply.
- Encodes a CCIP message with: sender, recipient, amount, partition, source chain nonce.
- Sends the message via `IRouterClient.ccipSend()`.
- Emits `BridgeTransferInitiated(sender, recipient, amount, partition, destChain, messageId)`.

### CCIP Receiver (Inbound)

`protocol/contracts/extensions/bridge/CCIPReceiver.sol`

- Implements `CCIPReceiver.sol` from Chainlink.
- Validates the source chain is a registered mirror chain and the sender is the authorized bridge adapter on that chain.
- Authenticates the message via `CCIPMessageVerificationModule`.
- Decodes the payload: sender, recipient, amount, partition.
- Calls destination compliance checks.
- Mints tokens to the recipient via the destination token's `mint()` (called through a bridge-authorized role).
- Emits `BridgeTransferCompleted(sender, recipient, amount, partition, sourceChain, messageId)`.

### Message Format

```text
CCIP message payload (encoded as bytes):
  abi.encode(
    address sender,    // original sender on source chain
    address recipient, // recipient on destination chain
    uint256 amount,    // token amount (wei)
    bytes32 partition, // ERC-1400 partition identifier (bytes32(0) if none)
    uint256 nonce      // source-chain nonce for replay protection
  )
```

### Gas Limits

CCIP `extraArgs` must set gas limits sufficient for:
- Identity registry lookup
- Compliance module evaluation (including ACE adapter calls)
- Token mint

The Bridge Operator sets gas limits at deployment and adjusts them via the configuration function.

---

## Chainlink ACE Integration Points

ACE policies are evaluated through the `ACEAdapter` compliance module.

### Policy Deployment

Policies are authored and deployed via the ACE `PolicyRegistry` on each chain. Each policy governs a specific compliance dimension:

| Policy | Purpose |
|---|---|
| `SanctionsScreening` | Checks sender/recipient against sanction lists |
| `JurisdictionBlock` | Blocks transfers involving restricted jurisdictions |
| `AccreditationCheck` | Verifies investor accreditation status |
| `TransferVelocity` | Limits cross-chain transfer frequency per wallet |
| `HoldingLimit` | Enforces per-investor minimum/maximum holdings |

### Compliance Module Integration

The `ACEAdapter` implements `IModule` from T-REX:

```
function moduleCheck(
    address from,
    address to,
    uint256 amount,
    bytes calldata data
) external view returns (bool allowed);
```

- `from` is the sender (or `address(0)` for mints).
- `to` is the recipient (or `address(0)` for burns).
- `amount` is the transfer amount.
- `data` encodes the partition and chain ID for cross-chain context.

The adapter calls ACE's `IPolicyRegistry.evaluatePolicies()` and reverts if any policy fails.

### Cross-Chain Policy Consistency

ACE policies are deployed independently per chain. The Compliance Officer ensures policy consistency across chains through the off-chain admin interface. Differences are intentional (e.g., a jurisdiction may be restricted on one chain but not another based on local regulation).

---

## Replay Protection

Replay attacks are prevented at three levels:

### Source-Chain Nonce

Each bridge adapter maintains a `nonce` counter per source chain. Every outbound CCIP message includes the current nonce, and the nonce is incremented after sending.

### CCIP Message ID

Chainlink CCIP assigns a unique `messageId` per message. The CCIP receiver stores processed `messageId` values in a mapping and rejects duplicates.

### Destination-Chain Nonce Check

The receiver maintains a mapping `sourceChainNonces[sourceChainSelector][sourceNonce]` to ensure each source nonce is processed at most once. This prevents replay even if the same CCIP message is delivered multiple times.

---

## Failure Recovery

### Mint Failure on Destination

If the destination chain's `ModularCompliance` or `_mint` reverts, the CCIP message will fail. CCIP supports a **manual retry** via `ManualExecution`. The Bridge Operator:

1. Inspects the failure reason (via CCIP event logs).
2. Resolves the compliance issue (e.g., registers recipient identity, updates compliance module).
3. Retries the message execution via CCIP's manual execution pathway.

If the failure cannot be resolved:
1. The Bridge Operator calls a recovery function on the canonical chain's `BridgeCoordination` contract.
2. `BridgeCoordination` re-mints the burned tokens to the original sender's address.
3. A `BridgeTransferRolledBack` event is emitted for off-chain reconciliation.

### CCIP Message Delivery Failure

If CCIP fails to deliver the message (e.g., destination chain not reachable), the `BRIDGE_ROLE` account can:

1. Retry via CCIP's built-in retry.
2. If retry fails after a configurable timeout, invoke the `rollbackBurn()` function on the canonical chain's `BridgeCoordination` contract. This only works if the message was never executed (verified via the nonce mapping on the destination).

### Bridge Adapter Pause

The bridge adapter supports a pause mechanism gated by `PAUSER_ROLE`. When paused:
- New outbound bridge transfers are rejected.
- Inbound CCIP messages are still processed (to avoid blocking completed transfers).
- The pause is used during incident response, compliance review, or bridge upgrades.

### Off-Chain Monitoring

A monitoring service tracks:
- CCIP message status (via CCIP event indexing, e.g., `CCIPMessageSent`, `CCIPMessageReceived`).
- Nonce gaps on source and destination chains.
- Compliance module configuration drift across chains.

---

## Partition Preservation

Partitions (ERC-1400 inspired) must be preserved across chains to maintain asset categorization.

### Encoding in CCIP Messages

The partition identifier (`bytes32`) is encoded in every CCIP bridge message. When tokens are burned on the source chain, the partition is recorded in the burn event. On the destination chain, tokens are minted into the same partition.

### Partition Registry Per Chain

Each chain has its own `PartitionManager` (in `protocol/contracts/extensions/partitions/`). Partitions are defined on the canonical chain and relayed to mirror chains via the off-chain admin interface. The partition definition (name, type, restrictions) is consistent across chains, but the balance book is independent per chain.

### Cross-Chain Partition Consistency

The `BridgeCoordination` contract on the canonical chain maintains a `PartitionRegistry` that maps partition identifiers to their definitions. When a new partition is created, a CCIP message may be sent to mirror chains to create the corresponding partition in their `PartitionManager` (or the off-chain admin does this out of band).

Balances in a given partition on a given chain represent tokens in that partition that are currently resident on that chain.

---

## Supply Consistency

### Invariant

```
canonical_total_supply = sum(source_partition_balances)
                        + sum(mirror_chain_partition_balances)
```

No cross-chain transfer increases or decreases total supply. Only issuer-authorized `mint()` and `burn()` on the canonical chain change total supply.

### Verification

The `BridgeCoordination` contract exposes a view function:

```
function totalSupplyAcrossChains() external view returns (uint256);
```

This returns the canonical token's `totalSupply()`. Off-chain monitors periodically reconcile:
- Sum of `balanceOf` across all chains for each holder
- Sum of partition balances across all chains
- Canonical `totalSupply()`

Discrepancies trigger alerts for the Compliance Officer and Bridge Operator.

### Emergency Correction

If a supply discrepancy is detected:
1. The Compliance Officer pauses the bridge on all chains.
2. The Bridge Operator investigates the discrepancy via event logs and CCIP message history.
3. If tokens were minted on a mirror chain without a corresponding source-chain burn, a forced burn (via transfer agent role) corrects the balance.
4. If tokens were burned on the source chain without a corresponding mirror-chain mint, `BridgeCoordination.retryMint()` re-mints on the destination.

---

## Upgrade Strategy

### Per-Chain UUPS Proxies

All bridge-related contracts use UUPS upgradeable proxies:
- `CCIPBridge` (outbound adapter)
- `CCIPReceiver` (inbound adapter)
- `BridgeCoordination` (canonical-chain coordination)
- `CrossChainIdentitySync` (identity relay)
- `ACEAdapter` (compliance module wrapper)

Upgrades are authorized by `UPGRADER_ROLE` on each chain independently.

### Coordination

Upgrades across chains are coordinated via the off-chain admin interface:
1. Deploy new implementation on each target chain.
2. Upgrade proxy on each chain (order: mirror chains first, then canonical chain last).
3. Verify cross-chain message flow after upgrade.

### Vendor Contract Stability

T-REX `Token.sol`, `ModularCompliance.sol`, `IdentityRegistry.sol`, and `ONCHAINID` contracts are not modified. If an upgrade is needed in vendor contracts, it is handled by:
1. Deploying a new proxy pointing to the updated implementation (if the vendor provides one).
2. Migrating state via the existing storage migration pattern.

No bridge logic depends on internal storage layout of vendor contracts. All bridge dependencies are through public interfaces (`IIdentityRegistry`, `IModularCompliance`, `IToken`).

---

## Trust Assumptions

### Bridge Operator

- Has `BRIDGE_ROLE` on all chains.
- Authorized to initiate retries, rollbacks, and emergency corrections.
- Trusted to not initiate unauthorized bridge transfers.
- Mitigation: All bridge operations emit events. Multi-sig or DAO can control `BRIDGE_ROLE`.

### CCIP Infrastructure

- Chainlink CCIP routers, donnetworks, and commit chains are trusted to deliver messages correctly.
- CCIP's risk management network (RMN) provides finality guarantees.
- Mitigation: Use CCIP's built-in rate limits and sanity checks. Monitor RMN status.

### ACE Policies

- ACE policy authors and the `PolicyRegistry` admin are trusted to configure accurate compliance rules.
- ACE oracles are trusted to provide correct data (sanctions lists, jurisdiction data).
- Mitigation: Policies are reviewed off-chain before deployment. Compliance Officer has separate oversight.

### Protocol Administrator

- `DEFAULT_ADMIN_ROLE` controls all roles including `BRIDGE_ROLE`, `UPGRADER_ROLE`, `PAUSER_ROLE`.
- Trusted to manage role assignments appropriately.
- Mitigation: Multi-sig wallet for `DEFAULT_ADMIN_ROLE`. Timelock for sensitive operations.

### Mirror Chain Validity

- The `ChainRegistry` mapping of approved mirror chains is maintained by the Protocol Administrator.
- Adding an invalid chain could lead to bridge messages being misrouted.
- Mitigation: Chain addition requires multi-sig approval. CCIP's `allowedSenders` provides an additional layer.

---

## Sequence Diagrams

### Cross-Chain Transfer: Success Path

```text
User                Source Bridge         Source Token        CCIP           Dest Bridge        Dest Token
 |                      |                     |                |                |                  |
 |-- bridgeTransfer --->|                     |                |                |                  |
 |   (dest, to, amt)    |                     |                |                |                  |
 |                      |-- verifySender ---->|                |                |                  |
 |                      |<- identity ok ------|                |                |                  |
 |                      |                     |                |                |                  |
 |                      |-- checkCompliance ->|                |                |                  |
 |                      |  (ModularCompliance)|                |                |                  |
 |                      |<- compliance ok ----|                |                |                  |
 |                      |                     |                |                |                  |
 |                      |-- burn(amt) ------->|                |                |                  |
 |                      |<- burn ok ----------|                |                |                  |
 |                      |                     |                |                |                  |
 |                      |-- ccipSend -------->|---- msg ------>|                |                  |
 |                      |<- messageId --------|                |-- receive ---->|                  |
 |                      |                     |                |                |                  |
 |<-- BridgeInitiated --|                     |                |                |-- verifyRecip ->|
 |                      |                     |                |                |<- identity ok --|
 |                      |                     |                |                |                  |
 |                      |                     |                |                |-- checkCompl ->|
 |                      |                     |                |                |<- compliance ok|
 |                      |                     |                |                |                  |
 |                      |                     |                |                |-- mint(amt) --->|
 |                      |                     |                |                |<- mint ok ------|
 |                      |                     |                |                |                  |
 |                      |                     |                |<-- ack ---------|                  |
 |                                                                                                |
 |<-- BridgeCompleted ----------------------------------------------------------------------------|
 |   (recipient notified)
```

### Cross-Chain Transfer: Compliance Failure on Destination

```text
User            Source Bridge       Source Token       CCIP          Dest Bridge        Dest Token
 |                    |                 |                |               |                  |
 |-- bridgeTransfer ->|                 |                |               |                  |
 |                    |-- burn --------->|               |               |                  |
 |                    |<- burn ok ------|                |               |                  |
 |                    |-- ccipSend ---->|---- msg ------>|               |                  |
 |                    |                 |                |-- receive --> |                  |
 |                    |                 |                |               |-- checkCompl ->  |
 |                    |                 |                |               |   (ModularComp)  |
 |                    |                 |                |               |<- REVERT -------| |
 |                    |                 |                |               |                  |
 |                    |                 |                |<- execution   |                  |
 |                    |                 |                |   failed -----|                  |
 |                    |                 |                |               |                  |
 |                    |                 |                |               | (CCIP manual     |
 |                    |                 |                |               |  retry or        |
 |                    |                 |                |               |  rollback)       |
```

### Identity Relay via CCIP

```text
Compliance Officer     Canonical ID Reg     CrossChainIdentitySync    CCIP     Mirror ID Reg
 |                          |                      |                  |            |
 |-- verifyIdentity ------>|                      |                  |            |
 |   (wallet, claims)      |                      |                  |            |
 |                          |-- store claim ------>|                  |            |
 |                          |                      |                  |            |
 |                          |                      |-- ccipSend ----->|-- msg ---->|
 |                          |                      |                  |            |
 |                          |                      |                  |-- update ->|
 |                          |                      |                  |   registries
 |                          |                      |                  |            |
 |                          |                      |<-- ack ----------|            |
```

### Failure Recovery: Rollback Burn

```text
Bridge Operator     BridgeCoordination       Source Token         User
 |                        |                      |                  |
 |-- rollbackBurn ------>|                      |                  |
 |   (msgId, reason)     |                      |                  |
 |                        |-- verify msg ------->|                  |
 |                        |   never executed     |                  |
 |                        |                      |                  |
 |                        |-- mint(to, amt) ---->|                  |
 |                        |<- mint ok ----------|                  |
 |                        |                      |                  |
 |<-- RollbackCompleted --|                      |                  |
 |                        |                      |-- notify ------->|
 |                        |                      |   "transfer      |
 |                        |                      |    rolled back"  |
```

### Supply Reconciliation (Off-Chain Monitor)

```text
Monitor            Canonical Token         Mirror A Token         Mirror B Token
 |                       |                      |                     |
 |-- totalSupply() ----->|                      |                     |
 |<-- 1,000,000 ---------|                      |                     |
 |                       |                      |                     |
 |          -- balanceOf(accts) ->              |                     |
 |          <- sum = 600,000 --------------------                     |
 |                                             |                     |
 |                         -- balanceOf(accts) ->                     |
 |                         <- sum = 300,000 --------------------------
 |                                                                   |
 |                                      -- balanceOf(accts) -------->
 |                                      <- sum = 100,000 -------------
 |                                                                   |
 | Verify: 600k + 300k + 100k == 1,000,000                          |
 | If mismatch: alert Compliance Officer and Bridge Operator          |
```

---

## Extension Contracts Summary

| Contract | Location | Purpose |
|---|---|---|
| `CCIPBridge` | `extensions/bridge/` | Outbound bridge adapter; burns and sends CCIP messages |
| `CCIPReceiver` | `extensions/bridge/` | Inbound CCIP receiver; validates and mints |
| `BridgeCoordination` | `extensions/bridge/` | Canonical-chain coordination; retry and rollback |
| `ChainRegistry` | `extensions/bridge/` | Registered mirror chain metadata |
| `ACEAdapter` | `extensions/ace/` | ACE policy evaluation as a T-REX compliance module |
| `CrossChainIdentitySync` | `extensions/compliance/` | Relays identity claims to mirror chains via CCIP |
| `CrossChainTransferComplianceModule` | `extensions/compliance/` | Compliance module for cross-chain transfer validation |
| `PartitionManager` | `extensions/partitions/` | ERC-1400 inspired partition balance tracking |

All contracts extend rather than modify the vendored T-REX and ONCHAINID contracts.
