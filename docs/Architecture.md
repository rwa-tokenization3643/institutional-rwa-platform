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
# Architecture

## Overview

The Institutional RWA Platform is organized as a modular system for issuing, managing, and transferring compliant real-world asset tokens across chains.

The architecture separates user-facing portals, backend coordination, identity, compliance, cross-chain messaging, token behavior, documents, partitions, and future extensions.

## Module Diagram

```text
                            Institutional RWA Platform

                                        |
                      +-----------------+------------------+
                      |                                    |
               Issuer Portal                       Investor Portal
                      |                                    |
                      +--------------+---------------------+
                                     |
                              Backend API
                                     |
      +------------------------------+------------------------------+
      |                              |                              |
 Identity Module             Compliance Module              Bridge Module
      |                              |                              |
 ONCHAINID                    Chainlink ACE                 Chainlink CCIP
      |                              |                              |
      +------------------------------+------------------------------+
                                     |
                             ERC3643 Token
                                     |
                +--------------------+--------------------+
                |                                         |
        Document Registry                    Partition Manager
                |                                         |
          Corporate Actions                  Future Modules
```

## Modules

## Phase Modules

### Phase 1

#### Role Manager

The role manager defines administrative authority across the platform.

It separates issuer, agent, compliance, pauser, upgrader, bridge, and operational permissions so each module can enforce least-privilege access.

#### Pause Manager

The pause manager coordinates emergency stop behavior.

It provides a common control point for pausing sensitive platform actions during incidents, upgrades, compliance reviews, or operational intervention.

#### Identity Registry

The identity registry links wallet addresses to verified identities.

It is the primary on-chain registry used by the token and compliance modules to determine whether an account is eligible to hold or receive regulated assets.

### Phase 2

#### Trusted Issuers

The trusted issuers module manages which claim issuers are accepted by the platform.

It allows the system to recognize approved identity, compliance, accreditation, jurisdiction, or institutional verification providers.

#### Claim Topics

The claim topics module defines the claim categories required for platform participation.

It allows the platform to express which identity or compliance claims are needed before an investor can hold or transfer tokens.

#### Identity Factory

The identity factory supports creation and registration of identity contracts.

It standardizes investor identity onboarding and helps connect new participant identities to the identity registry.

### Phase 3

#### Compliance Engine

The compliance engine is the central transfer validation module.

It determines whether token actions are allowed based on identity status, configured rules, Chainlink ACE policies, and issuer-defined restrictions.

#### Rule Engine

The rule engine organizes reusable compliance checks.

It allows rules to be composed, enabled, disabled, and reused without duplicating compliance logic across token, bridge, or partition workflows.

#### Country Rules

Country rules define jurisdiction-based restrictions.

They support requirements such as blocked jurisdictions, allowed markets, residency limits, and country-specific compliance constraints.

#### Holding Rules

Holding rules define ownership and balance restrictions.

They support requirements such as maximum investor count, minimum holdings, maximum holdings, lockups, and investor concentration limits.

#### Investor Rules

Investor rules define account-level eligibility requirements.

They support investor classification, accreditation status, KYC state, sanctions checks, and other identity-linked restrictions.

### Phase 4

#### ERC3643 Token

The ERC-3643 token is the core regulated asset token.

It represents ownership, relies on the identity registry and compliance engine for transfer validation, and remains lightweight by delegating specialized behavior to modules.

### Phase 5

#### Partition Manager

The partition manager provides ERC-1400 inspired partitioned balances.

It tracks token balances by issuer-defined categories while preserving ERC-3643 as the core token model.

### Phase 6

#### Document Registry

The document registry stores references to asset, issuer, compliance, and investor-facing documents.

It supports regulated disclosure, auditability, document updates, and lifecycle records.

### Phase 7

#### Corporate Actions

The corporate actions module supports asset lifecycle events.

It covers issuer-driven actions such as redemptions, distributions, recalls, splits, conversions, and other regulated asset servicing workflows.

### Phase 8

#### Bridge Adapter

The bridge adapter coordinates compliant cross-chain token movement.

It provides a controlled integration point between the token, compliance engine, and supported cross-chain messaging systems.

#### CCIP Receiver

The CCIP receiver handles inbound Chainlink CCIP messages.

It validates cross-chain instructions and routes accepted messages to the appropriate platform modules.

#### ACE Adapter

The ACE adapter connects platform compliance workflows to Chainlink ACE.

It allows the compliance engine to use ACE-backed policy decisions while keeping the platform compliance interface stable.

### Issuer Portal

The issuer portal is the operational interface for issuers, administrators, compliance teams, and asset managers.

It supports platform workflows such as asset setup, investor onboarding coordination, document management, transfer oversight, and corporate action administration.

### Investor Portal

The investor portal is the interface for investors and token holders.

It supports identity-linked participation, portfolio visibility, document access, and compliant transfer workflows.

### Backend API

The backend API coordinates off-chain application workflows and connects portals to on-chain modules.

It does not replace on-chain compliance. On-chain modules remain the source of truth for identity, eligibility, transfer validation, and token state.

### Identity Module

The identity module represents investor and participant identity state.

It integrates with ONCHAINID so token ownership and transfer eligibility can be linked to verifiable identity claims.

### Compliance Module

The compliance module evaluates whether token actions are allowed.

It integrates with Chainlink ACE and supports institutional compliance requirements such as jurisdiction rules, investor eligibility, transfer restrictions, and policy enforcement.

### Bridge Module

The bridge module coordinates cross-chain token movement.

It integrates with Chainlink CCIP so compliant RWA transfers can be represented across supported chains.

### ERC3643 Token

The ERC-3643 token is the core regulated token.

It remains lightweight and delegates identity, compliance, bridge, document, and partition responsibilities to dedicated modules.

### Document Registry

The document registry manages asset and token-related document references.

It supports institutional requirements for offering documents, disclosures, legal agreements, attestations, and other regulated records.

### Partition Manager

The partition manager provides ERC-1400 inspired partitioned balance behavior.

It allows balances to be organized by asset class, tranche, lockup status, jurisdiction, or other issuer-defined categories without making partitions the core token standard.

### Corporate Actions

Corporate action modules support issuer-driven lifecycle events.

Examples include distributions, redemptions, splits, conversions, freezes, recalls, and other asset administration workflows.

### Future Modules

The architecture reserves space for additional modules without forcing changes into the token core.

Future modules may include governance, reporting, audit automation, additional bridge providers, alternative compliance engines, or expanded asset servicing features.
