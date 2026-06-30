# ERC-3643 and ONCHAINID Analysis

This analysis is based on the upstream Tokeny `T-REX` repository and the `onchain-id/solidity` repository, which are the actual references behind the vendored ERC-3643 and ONCHAINID projects.

The local `vendor/erc3643/` and `vendor/onchainid/` directories are currently placeholders, so this document captures the intended upstream architecture and integration points.

## Contract Hierarchy

### ONCHAINID

The ONCHAINID project is centered on a small set of identity contracts and supporting storage/proxy/factory components.

- `contracts/Identity.sol` is the main identity contract.
- `contracts/ClaimIssuer.sol` extends `Identity.sol` to add claim revocation behavior for trusted issuers.
- `contracts/interface/*` contains ERC-734 and ERC-735 interfaces used by the identity contracts.
- `contracts/storage/*` separates storage from behavior so the logic contract can be upgradeable.
- `contracts/proxy/*` contains the proxy layer.
- `contracts/factory/*` contains identity factory interfaces and deployment helpers.
- `contracts/gateway/*`, `contracts/verifiers/*`, and `contracts/version/*` provide supporting behavior around issuance and verification.

Observed relationship:

- `Identity.sol` inherits `Storage`, `IIdentity`, and `Version`.
- `ClaimIssuer.sol` inherits `Identity`.
- `Identity.sol` implements the key-holder and claim-holder model from ERC-734 and ERC-735.

### ERC-3643 / T-REX

The T-REX suite is composed of token, registry, compliance, roles, factory, and proxy layers.

- `contracts/token/Token.sol` is the regulated token core.
- `contracts/token/TokenStorage.sol` isolates token state.
- `contracts/token/IToken.sol` defines the token interface.
- `contracts/compliance/modular/ModularCompliance.sol` is the compliance router.
- `contracts/compliance/modular/MCStorage.sol` isolates compliance state.
- `contracts/compliance/modules/*` contains plug-in compliance modules.
- `contracts/registry/*` contains the identity and claim registries.
- `contracts/roles/*` contains the role and agent control contracts.
- `contracts/factory/TREXFactory.sol` orchestrates deployment of the full suite.
- `contracts/factory/TREXGateway.sol` and `contracts/factory/ITREXFactory.sol` are the deployment-facing interfaces.
- `contracts/proxy/*` contains proxy contracts for the suite components.
- `contracts/interface/*` contains suite-wide interfaces and shared definitions.

Observed relationship:

- `Token.sol` inherits `IToken`, `AgentRoleUpgradeable`, and `TokenStorage`.
- `ModularCompliance.sol` inherits `IModularCompliance`, `OwnableUpgradeable`, and `MCStorage`.
- `TREXFactory.sol` deploys the suite with CREATE2 and proxy contracts.

## Deployment Order

The deployment order below is inferred from `TREXFactory.deployTREXSuite()` and the ONCHAINID contract structure.

1. Deploy the ONCHAINID implementation or identity contract family first, because claims and management keys live there.
2. Deploy the TREX implementation authority and the ONCHAINID identity factory.
3. Deploy the suite through `TREXFactory`.
4. During suite deployment, the factory creates:
   - Trusted Issuers Registry
   - Claim Topics Registry
   - Modular Compliance
   - Identity Registry Storage, if one is not supplied
   - Identity Registry
   - Token
5. If no ONCHAINID address is provided for the token, the factory creates one with the identity factory and binds it to the token.
6. Seed claim topics and trusted issuers.
7. Bind identity registry storage to the identity registry.
8. Add agents to the identity registry and token.
9. Add compliance modules and module settings.
10. Transfer ownership of the deployed suite contracts to the token owner.

## Identity Flow

1. A user creates an ONCHAINID identity.
2. The identity contract stores management keys and claim keys.
3. Trusted issuers sign claims against the identity.
4. The identity contract stores the claim data and tracks claims by topic and issuer.
5. `ClaimIssuer` can validate claims and revoke them.
6. The identity registry links a wallet to an identity and determines whether the wallet is eligible to hold the token.
7. The token reads the identity registry before minting or transferring.

Key behavior observed in `Identity.sol`:

- `onlyManager` gates management operations.
- `onlyClaimKey` gates claim operations.
- `addClaim()` checks claim validity against the issuer.
- `getClaim()` returns topic, scheme, issuer, signature, data, and URI.
- `keyHasPurpose()` returns whether a key has management or a requested purpose.

## Compliance Flow

1. The token calls the compliance contract before a mint, transfer, or forced transfer.
2. `ModularCompliance` acts as a dispatcher rather than a monolith.
3. Compliance modules are bound to the compliance contract.
4. Each module receives:
   - `moduleCheck()` for transfer validation
   - `moduleMintAction()` for mints
   - `moduleTransferAction()` for transfers
   - `moduleBurnAction()` for burns
5. The owner can add or remove modules.
6. The owner can call module-specific configuration functions through `callModuleFunction()`.

Important inference:

- The compliance model is intentionally modular. The base compliance contract is not the place to put business rules; it is the coordination layer for rule modules.

## Transfer Flow

Observed token transfer path in `Token.sol`:

1. The token checks pause state.
2. The token checks frozen wallet state.
3. The token checks available balance versus frozen tokens.
4. The token verifies the recipient through the identity registry.
5. The token checks `canTransfer()` on the compliance contract.
6. The token executes the transfer.
7. The token notifies compliance with `transferred()`.

Observed mint path:

1. Recipient must be verified in the identity registry.
2. Compliance must allow the mint via `canTransfer(address(0), to, amount)`.
3. The token mints.
4. Compliance receives `created()`.

Observed forced transfer path:

1. The agent checks available balance.
2. Frozen partial balances may be adjusted to satisfy the forced transfer.
3. Recipient verification is still required.
4. Compliance receives `transferred()`.

## Extension Points

The upstream architecture is intentionally extensible in these places:

- Compliance modules under `contracts/compliance/modules/*`.
- Identity claims and claim topics.
- Trusted issuers and issuer-based verification policy.
- Registry storage and registry composition.
- Agent roles and operational permissions.
- Factory-level deployment orchestration.
- Proxy-backed implementation upgrades.

For this project, the safest extension strategy is to add new modules and adapters around these boundaries rather than editing the upstream core contracts.

## Upgradeability Approach

### T-REX

T-REX uses a proxy-and-implementation-authority model.

- `TREXFactory` deploys proxy contracts for the registries, compliance contract, and token.
- The factory depends on an implementation authority contract to point proxies at the current implementations.
- Token and registry state is split into dedicated storage contracts such as `TokenStorage.sol` and `MCStorage.sol`.
- This keeps the upgrade boundary explicit and avoids mixing storage with business logic.

### ONCHAINID

ONCHAINID separates logic from storage.

- `Identity.sol` inherits from a dedicated storage contract.
- `delegatedOnly` prevents direct interaction with the logic contract.
- This design supports upgradeable logic while keeping identity state stable.

Practical implication:

- Storage layout must be treated as part of the contract interface.
- Upgrades should be done by swapping implementations behind the existing proxy/authority boundary.
- Business logic should not be embedded into storage contracts.

## Contracts That Should Never Be Modified

If we vendor these projects, the following should be treated as frozen upstream artifacts and not edited directly:

- `contracts/token/Token.sol`
- `contracts/token/TokenStorage.sol`
- `contracts/token/IToken.sol`
- `contracts/compliance/modular/ModularCompliance.sol`
- `contracts/compliance/modular/MCStorage.sol`
- `contracts/compliance/modules/*`
- `contracts/registry/*`
- `contracts/roles/*`
- `contracts/proxy/*`
- `contracts/interface/*`
- `contracts/factory/TREXFactory.sol`
- `contracts/factory/TREXGateway.sol`
- `contracts/factory/ITREXFactory.sol`
- `contracts/factory/ITREXGateway.sol`
- `contracts/Identity.sol`
- `contracts/ClaimIssuer.sol`
- `contracts/storage/*`
- `contracts/version/*`
- `contracts/interface/*` in ONCHAINID

Reason:

- These files define the vendor boundary, the storage boundary, or the proxy boundary.
- Modifying them directly makes future upstream syncing and security review harder.

## Contracts That Are Intended To Be Extended

These are the parts of the upstream designs that are meant to absorb project-specific behavior:

- Compliance modules under `contracts/compliance/modules/*`
- New module adapters that implement `IModule`
- New issuer or claim-verification policies layered around identity claims
- Factory wrappers or deployment orchestration helpers
- Identity- and compliance-facing adapters for bridge, documents, partitions, and corporate actions
- New registry consumers that read from identity and claim data without changing the core identity contract

For this project, the preferred pattern is:

1. Keep vendor contracts unchanged.
2. Add project-specific extension contracts in our own `protocol/contracts/extensions/*` tree.
3. Use interfaces and adapters to connect our modules to the vendored core.

## Sources Reviewed

- https://github.com/TokenySolutions/T-REX
- https://raw.githubusercontent.com/TokenySolutions/T-REX/main/contracts/factory/TREXFactory.sol
- https://raw.githubusercontent.com/TokenySolutions/T-REX/main/contracts/token/Token.sol
- https://raw.githubusercontent.com/TokenySolutions/T-REX/main/contracts/compliance/modular/ModularCompliance.sol
- https://github.com/onchain-id/solidity
- https://github.com/onchain-id/solidity/blob/main/contracts/Identity.sol
- https://github.com/onchain-id/solidity/blob/main/contracts/ClaimIssuer.sol
