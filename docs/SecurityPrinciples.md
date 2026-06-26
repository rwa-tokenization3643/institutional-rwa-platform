# Security Principles

These principles are non-negotiable design rules for the Institutional RWA Platform.

## Least Privilege

Every account, role, contract, and module must receive only the minimum authority required to perform its responsibility.

## Role-Based Access Control

Administrative and operational permissions must be enforced through explicit roles.

Roles must be scoped by responsibility, such as issuer, agent, compliance, pauser, upgrader, bridge, and document administration.

## Checks-Effects-Interactions

Contract logic must follow the Checks-Effects-Interactions pattern when external calls are involved.

State validation must happen before state mutation, and external interactions must happen after internal state changes.

## Pull Over Push Payments

Payment and distribution flows should prefer pull-based claiming over push-based transfers.

This reduces failure risk, limits gas griefing, and avoids blocking workflows because a recipient cannot receive funds.

## Reentrancy Protection

External-call flows must be reviewed for reentrancy risk.

Sensitive functions must use appropriate reentrancy protections when value transfers, callbacks, bridge receivers, or external protocol calls are involved.

## Upgrade Safety

Upgradeable contracts must use UUPS-compatible patterns and explicit upgrade authorization.

Storage layout changes must be reviewed before every upgrade, and initializers must be protected from reuse.

## Pause Mechanisms

Sensitive modules must support controlled pause behavior where appropriate.

Pause authority must be role-gated and used for incident response, compliance intervention, and operational protection.

## Comprehensive Test Coverage

The protocol must target 100% Foundry test coverage.

Unit tests, integration tests, fuzz tests, invariant tests, and upgrade tests should be used where appropriate for the risk level of each module.
