# 0001 Modular Architecture

## Decision

The platform will use a modular architecture.

The ERC-3643 token will remain lightweight and delegate identity checks, compliance rules, bridge behavior, document handling, and partition accounting to dedicated modules.

Identity, compliance, bridge, and partition logic will be implemented as separate contracts or libraries with clear interfaces.

## Reason

Institutional RWA systems need strong separation between token ownership, investor eligibility, transfer restrictions, cross-chain messaging, and asset-specific extensions.

Keeping the token lightweight reduces upgrade risk, simplifies audits, and avoids duplicating business logic across features.

Separate modules make the system easier to test, replace, upgrade, and reason about. They also allow compliance, identity, bridge, and partition behavior to evolve independently while preserving a stable token core.
