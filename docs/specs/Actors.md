# Actors Specification

## Purpose

Define the protocol actors before implementing identity, compliance, token, bridge, and administrative modules.

Every role in `ProtocolAccessManager` should map directly to one or more actors defined in this specification.

## Actors

| Actor | Responsibilities |
| --- | --- |
| Issuer | Creates assets and issues tokens. |
| Investor | Holds and transfers tokens. |
| Compliance Officer | Approves and revokes investor eligibility. |
| Identity Provider | Issues identity claims. |
| Trusted Issuer | Signs identity claims. |
| Transfer Agent | Performs administrative transfers. |
| Bridge Operator | Oversees cross-chain operations. |
| Protocol Administrator | Manages protocol configuration. |
| Auditor | Reviews events and compliance logs. |

## Role Mapping

Role mappings are intentionally defined after the actor model so access control remains tied to explicit protocol responsibilities.

Future specifications must reference these actors when defining privileged operations.
