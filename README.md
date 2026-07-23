# Institutional RWA Platform

A production-grade platform for issuing, managing, and transferring compliant Real World Asset (RWA) tokens across blockchains. Built on [ERC-3643](https://eips.ethereum.org/EIPS/eip-3643) security tokens, [ONCHAINID](https://ethereum-onchain-identity.readthedocs.io/) identity, and [Chainlink CCIP](https://chain.link/ccip) cross-chain messaging.

## What This Project Does

Institutional investors need to move tokenized assets (bonds, equities, real estate) between chains while staying compliant with jurisdictional regulations. This platform solves that with a **6-phase cross-chain settlement protocol**:

```
Investor A (Sepolia, US)
    │
    │  submitTransfer(intent)
    ▼
┌─────────────────────┐       CCIP        ┌─────────────────────┐
│  Source Chain        │ ────────────────►  │  Destination Chain   │
│                     │  VALIDATION_REQ    │                     │
│  Compliance check   │  VALIDATION_RESP   │  Compliance check   │
│  Reserve tokens     │  SETTLEMENT_INSTR  │  Mint tokens        │
│  Burn on ack        │  SETTLEMENT_ACK    │                     │
└─────────────────────┘ ◄────────────────  └─────────────────────┘
    │
    │  150 RWA tokens settle atomically
    ▼
Investor B (Fuji, EU)
```

**Key properties:**
- Tokens are reserved only after both chains approve (no lock contention during validation)
- Tokens are burned on source only after destination confirms mint (no supply inflation)
- Dual-layer compliance: protocol-level pre-flight + ERC-3643 token-level enforcement
- Vendor-agnostic: adapter pattern supports ERC-3643, ERC-1400, ERC-20

## Project Structure

```
token/
├── protocol/                    ← Smart contracts, deployment scripts, tests
│   ├── contracts/               21 Solidity files (core, adapters, extensions)
│   ├── script/                  26 deployment scripts (Anvil, Sepolia, Fuji)
│   ├── test/                    27 test files (unit, integration, 13 conformance)
│   └── AGENTS.md                Detailed architecture reference
│
├── vendor/                      ← Git submodules
│   ├── erc3643/                 ERC-3643 (T-REX) token standard
│   └── onchainid/               ONCHAINID identity framework
│
├── docs/                        ← Design documentation
│   ├── Architecture.md          Full module diagram and descriptions
│   ├── CrossChainSettlementProtocol.md
│   ├── ThreatModel.md
│   ├── SecurityPrinciples.md
│   ├── erc3643-analysis.md      ERC-3643 integration analysis
│   ├── adr/                     6 Architecture Decision Records
│   └── specs/                   Protocol specifications
│
├── agents/prompts/              ← AI agent prompts for dev workflows
├── sdk/                         ← (planned) TypeScript client library
├── backend/                     ← (planned) Off-chain coordination
└── examples/                    ← (planned) Usage examples
```

## What's Built

| Module | Status | Description |
|--------|--------|-------------|
| **Protocol Access Manager** | Done | Role-based access control (ADMIN, BRIDGE, COMPLIANCE) |
| **Transfer Intent Manager** | Done | Intent lifecycle, state machine, persistence |
| **Rule Engine Compliance** | Done | 9-dimension pre-flight compliance pipeline |
| **ERC-3643 Asset Adapter** | Done | Vendor-agnostic mint/burn/reserve abstraction |
| **CCIP Transport Provider** | Done | Chainlink CCIP bridge adapter with delivery guarantees |
| **Settlement Coordinator** | Done | 6-phase orchestration across chains |
| **ERC-3643 Token** | Done | Full T-REX deployment with identity, compliance, agents |
| **Cross-chain Settlement** | Done | Verified end-to-end on Sepolia + Fuji testnets |
| **Conformance Tests** | Done | 13 invariant scenarios covering all failure modes |
| **Integration Tests** | Done | Full lifecycle, multi-scenario, cross-chain |

## What's Planned

| Phase | Module | Description |
|-------|--------|-------------|
| 5 | **Partition Manager** | ERC-1400-inspired token partitions |
| 6 | **Document Registry** | On-chain document binding to tokens |
| 7 | **Recovery Manager** | Automated rollback recovery for failed settlements |
| 8 | **Corporate Actions** | Dividends, splits, voting |
| 9 | **SDK** | TypeScript client library |
| 10 | **Production** | Multi-sig admin, audit, mainnet deployment |

## Quick Start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/) (`forge`, `anvil`, `cast`)
- Git submodules initialized

### Build and Test

```bash
git clone <repo-url> && cd token
git submodule update --init --recursive

cd protocol
forge build
forge test
```

### Local Deployment (Anvil)

```bash
cd protocol

# Start two local chains
anvil --port 8545 &
anvil --port 8546 &

# Deploy full stack and execute test transfer
forge script script/DeployLocal.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --unlocked \
  --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
```

### Testnet Deployment

Deploy to Sepolia and Fuji with real Chainlink CCIP:

```bash
cd protocol

# Deploy to Sepolia
forge script script/DeploySepolia.s.sol \
  --rpc-url <SEPOLIA_RPC> \
  --broadcast \
  --private-key <KEY>

# Deploy to Fuji
forge script script/DeployFuji.s.sol \
  --rpc-url <FUJI_RPC> \
  --broadcast \
  --private-key <KEY>
```

See **[protocol/README.md](protocol/README.md)** for full deployment instructions, cross-chain wiring, LINK funding, and contract addresses.

## Architecture

### Settlement Protocol

```
                    ┌──────────────────────────┐
                    │    SettlementCoordinator   │
                    │  (workflow, no persistence)│
                    └─────┬────┬────┬────┬──────┘
                          │    │    │    │
              ┌───────────┘    │    │    └───────────┐
              ▼                ▼    ▼                ▼
    ┌──────────────┐  ┌────────┐ ┌────────┐ ┌──────────────┐
    │   Transfer    │  │RuleEng.│ │ERC3643 │ │    CCIP       │
    │   Intent      │  │Compli. │ │Asset   │ │  Transport    │
    │   Manager     │  │Provider│ │Adapter │ │  Provider     │
    └──────────────┘  └────────┘ └────────┘ └──────────────┘
         state         9-check     vendor-     Chainlink
         machine       pipeline    agnostic    CCIP bridge
```

### Compliance Layers

1. **Protocol-level** (`RuleEngineComplianceProvider`) — evaluates intent against 9 rules before any assets move (action, identity, asset, jurisdiction, classification, limits, time)
2. **Token-level** (ERC-3643) — enforces at mint/burn/transfer time via pluggable compliance modules

### Roles

| Role | Purpose |
|------|---------|
| `DEFAULT_ADMIN` | Role management |
| `BRIDGE_ROLE` | Settlement operations, transport, state transitions |
| `COMPLIANCE_ROLE` | Asset configuration, compliance rules, policy |
| `AGENT_ROLE` (ERC-3643) | Token mint/burn operations |

## Standards

| Standard | Usage |
|----------|-------|
| [ERC-3643](https://eips.ethereum.org/EIPS/eip-3643) | Security token (T-REX) — regulated asset transfers |
| [ONCHAINID](https://ethereum-onchain-identity.readthedocs.io/) | On-chain identity — wallet-to-identity binding |
| [Chainlink CCIP](https://chain.link/ccip) | Cross-chain messaging — settlement message transport |
| [Chainlink ACE](https://chain.link/automation) | (planned) Automated compliance enforcement |
| [OpenZeppelin v5](https://docs.openzeppelin.com/contracts/5.x/) | Access control, ERC-165, security patterns |

## Documentation

| Document | Description |
|----------|-------------|
| [protocol/README.md](protocol/README.md) | Deployment guide, contract addresses, configuration |
| [protocol/AGENTS.md](protocol/AGENTS.md) | Detailed architecture for codebase navigation |
| [docs/Architecture.md](docs/Architecture.md) | Full module diagram and descriptions |
| [docs/CrossChainSettlementProtocol.md](docs/CrossChainSettlementProtocol.md) | Settlement protocol design |
| [docs/ThreatModel.md](docs/ThreatModel.md) | Security threat modeling |
| [docs/SecurityPrinciples.md](docs/SecurityPrinciples.md) | Security principles and guarantees |
| [docs/erc3643-analysis.md](docs/erc3643-analysis.md) | ERC-3643 integration analysis |

## Design Principles

- **Modular contracts** — each concern is a separate, independently testable contract
- **Vendor-agnostic core** — SettlementCoordinator never imports ERC-3643, CCIP, or any vendor contract
- **100% Foundry** — all tests, deployment, and tooling in Solidity
- **NatSpec documentation** — every contract, function, and parameter documented
- **Custom errors** — no `require` strings, gas-efficient revert reasons
- **No duplicated logic** — shared state machines, single source of truth

## License

Apache 2.0
