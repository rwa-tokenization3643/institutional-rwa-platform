# Cross-Chain RWA Settlement Protocol

Institutional-grade cross-chain settlement protocol for Real World Assets (RWA). Uses ERC-3643 security tokens with Chainlink CCIP for cross-chain messaging and a 6-phase settlement lifecycle with dual-chain compliance enforcement.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     SettlementCoordinator                        │
│              (orchestrates lifecycle, owns no state)             │
├──────────────┬──────────────┬──────────────┬────────────────────┤
│  Transfer    │  RuleEngine  │  ERC3643     │  CCIPTransport     │
│  Intent      │  Compliance  │  Asset       │  Provider          │
│  Manager     │  Provider    │  Adapter     │                    │
│              │              │              │                    │
│  intent      │  9-check     │  vendor-     │  Chainlink CCIP    │
│  lifecycle   │  pipeline    │  agnostic    │  bridge adapter    │
│  + state     │  (view-only) │  mint/burn   │  encode/decode     │
│  machine     │              │              │  + delivery        │
└──────────────┴──────────────┴──────────────┴────────────────────┘
```

**Key design principle:** The SettlementCoordinator never interacts with ERC-3643, CCIP, or any vendor contract directly. Every interaction is mediated by one of four sub-component interfaces (`ITransferIntentManager`, `ICompliancePolicyProvider`, `IAssetAdapter`, `ITransportProvider`).

## Settlement Lifecycle (6 Phases)

| Phase | Direction | Action | State Change |
|-------|-----------|--------|-------------|
| 1 | Source | User calls `submitTransfer` | `→ PENDING_VALIDATION` |
| 2 | Source → Dest | `VALIDATION_REQUEST` via CCIP | Dest: `→ VALIDATED` |
| 3 | Dest → Source | `VALIDATION_RESPONSE` via CCIP | Source: `→ VALIDATED → RESERVED` |
| 4 | Source → Dest | `SETTLEMENT_INSTRUCTION` via CCIP | Dest: `→ SETTLED` |
| 5 | Dest → Source | `SETTLEMENT_ACK` via CCIP | Source: `→ SETTLED` |
| 6 | Both | Invariant verification | Terminal state |

```
PENDING_VALIDATION ──→ VALIDATED ──→ RESERVED ──→ SETTLED
         │                  │            │
         ├──→ REJECTED      ├──→ REJECTED ├──→ ROLLED_BACK
         └──→ EXPIRED       └──→ EXPIRED  └──→ EXPIRED
```

## Prerequisites

- [Foundry](https://book.getfoundry.sh/) (forge, anvil, cast)
- Git submodules initialized
- For testnet deployment: ETH on Sepolia + AVAX on Fuji, plus LINK tokens

### Install Foundry

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Clone and Initialize

```bash
git clone <repo-url>
cd token
git submodule update --init --recursive
```

## Build

From the `protocol/` directory:

```bash
cd protocol
forge build
```

Solidity 0.8.30 with optimizer (200 runs) and via-IR pipeline enabled. A `novir` profile exists for faster local iteration:

```bash
forge build --profile novir
```

## Test

```bash
forge test                          # all tests
forge test -vvv                     # verbose output
forge test --match-path "test/conformance/*"  # conformance tests only
```

### Test Structure

| Directory | Count | Description |
|-----------|-------|-------------|
| `test/conformance/` | 13 scenarios | One per protocol invariant (replay protection, rollback, compliance rejection, etc.) |
| `test/integration/` | 3 files | Full lifecycle, multi-scenario, cross-chain settlement |
| `test/access/` | 1 file | ProtocolAccessManager unit tests |
| `test/adapters/` | 1 file | ERC3643AssetAdapter unit tests |
| `test/extensions/` | 1 file | CCIPTransportProvider tests |
| `test/mocks/` | 4 files | MockCCIPRouter, MockERC3643Token, RealisticERC3643Token |

## Local Deployment (Anvil)

Spin up two local chains and run the full settlement flow end-to-end:

```bash
# Terminal 1: Start Anvil with two instances
anvil --port 8545 &
anvil --port 8546 &

# Terminal 2: Deploy and execute
cd protocol
forge script script/DeployLocal.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --unlocked \
  --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
```

This deploys the full stack on both chains (ERC-3643 tokens, protocol contracts, CCIP mock router, compliance config, cross-chain transport wiring, and executes a test transfer).

## Testnet Deployment

### Supported Networks

| Network | Protocol Chain ID | CCIP Selector | CCIP Router |
|---------|------------------|---------------|-------------|
| Ethereum Sepolia | 1 | 16015286601757825753 | `0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59` |
| Avalanche Fuji | 2 | 14767482510784806043 | `0xF694E193200268f9a4868e4Aa017A0118C9a8177` |

### LINK Token Addresses

| Network | Address |
|---------|---------|
| Sepolia | `0x779877A7B0D9E8603169DdbD7836e478b4624789` |
| Fuji | `0x0b9d5D9136855f6FEc3c0993feE6E9CE8a297846` |

### Deploy to Sepolia

You need a funded deployer wallet (private key + Sepolia ETH + Sepolia LINK).

```bash
cd protocol

# Deploy full stack on Sepolia
forge script script/DeploySepolia.s.sol \
  --rpc-url <SEPOLIA_RPC_URL> \
  --broadcast \
  --private-key <DEPLOYER_PRIVATE_KEY>
```

### Deploy to Fuji

```bash
cd protocol

# Deploy full stack on Fuji
forge script script/DeployFuji.s.sol \
  --rpc-url <FUJI_RPC_URL> \
  --broadcast \
  --private-key <DEPLOYER_PRIVATE_KEY>
```

### Cross-Chain Wiring

After deploying on both chains, wire them together. Deploy chain B first, then chain A, passing chain B's transport address:

```bash
# 1. Deploy Fuji first (no remote receiver yet)
forge script script/DeployFuji.s.sol \
  --rpc-url <FUJI_RPC_URL> \
  --broadcast \
  --private-key <KEY>

# Note the Fuji CCIPTransportProvider address from output

# 2. Deploy Sepolia with Fuji transport address
FUJI_TRANSPORT=<FUJI_TRANSPORT_ADDRESS> \
forge script script/DeploySepolia.s.sol \
  --rpc-url <SEPOLIA_RPC_URL> \
  --broadcast \
  --private-key <KEY>

# Note the Sepolia CCIPTransportProvider address from output

# 3. Configure Fuji to point to Sepolia
SEPOLIA_TRANSPORT=<SEPOLIA_TRANSPORT_ADDRESS> \
forge script script/ConfigureFuji.s.sol \
  --rpc-url <FUJI_RPC_URL> \
  --broadcast \
  --private-key <KEY>
```

### Fund Transport Providers

The `CCIPTransportProvider` needs LINK for CCIP message fees and native gas:

```bash
# Using cast to send LINK (run from protocol/ directory)
cast send <LINK_TOKEN_ADDRESS> \
  "transfer(address,uint256)" \
  <TRANSPORT_PROVIDER_ADDRESS> \
  5000000000000000000 \
  --rpc-url <RPC_URL> \
  --private-key <KEY>

# Fund with native gas (0.1 AVAX on Fuji)
cast send <TRANSPORT_PROVIDER_ADDRESS> \
  --value 0.1ether \
  --rpc-url <RPC_URL> \
  --private-key <KEY>
```

### Submit a Cross-Chain Transfer

```bash
forge script script/SubmitTransfer.s.sol \
  --rpc-url <SOURCE_CHAIN_RPC> \
  --broadcast \
  --private-key <KEY>
```

Monitor progress on the [Chainlink CCIP Explorer](https://ccip.chain.link/).

## How It Works

### Compliance (Two Layers)

**1. Protocol-level (`RuleEngineComplianceProvider`)** — pre-flight check before any assets move. Evaluates 9 dimensions:

| Check | Description |
|-------|-------------|
| Action type | Is the intent action allowed? |
| Sender identity | Is the sender's identity hash non-zero? |
| Recipient identity | Is the recipient's identity hash non-zero? |
| Asset | Is this asset configured for transfers? |
| Jurisdictions | Are source/dest chain jurisdictions permitted? |
| Classification | Does the sender/recipient meet the minimum investor classification? |
| Transfer amount | Does the amount not exceed the per-asset maximum? |
| Holding limit | Does the amount not exceed the per-asset holding cap? |
| Time validity | Has the intent not expired? |

Both source and destination chains evaluate compliance independently during Phase 1.

**2. Token-level (ERC-3643)** — enforcement inside the token contract at mint/burn/transfer time. The token's `canTransfer()` iterates through bound compliance modules. Any module returning `false` blocks the transfer.

### Asset Reservation

Tokens are NOT locked during Phase 1 validation. Reservation happens in Phase 2 after both chains approve — this eliminates lock contention when validation fails. The current strategy uses internal accounting (temporary); a dedicated vault contract is planned.

### Burn-on-Ack

Tokens are only burned on the source chain after the destination confirms successful mint via `SETTLEMENT_ACK`. This ensures tokens are never destroyed unless delivery is confirmed.

## Contract Addresses (Sepolia + Fuji)

### Sepolia (Protocol Chain ID = 1)

| Contract | Address |
|----------|---------|
| ProtocolAccessManager | `0x4Adc11101De09D31bc2a931DC27774b0886d8d20` |
| TransferIntentManager | `0x1b7b2e85bE973D875b4Ed5C20cF0ab01ECBB93Ab` |
| RuleEngineComplianceProvider | `0x959986D83905D256133ebFf7d8Fa5Fe8Ed1CED133` |
| ERC3643AssetAdapter | `0x5Fb39789367DF587D8BD742472b922013FEE9D66` |
| CCIPTransportProvider | `0x40BBD60d3952f9C5C0654cbA6bb9f0c99fCb3C4a` |
| SettlementCoordinator | `0x02fC65e85d0c3940D2Af62a836420F97Ef520185` |
| RWA Token | `0x9DbEB1Bc4eB090a653F19d166eDE17A5BFFc896d` |

### Fuji (Protocol Chain ID = 2)

| Contract | Address |
|----------|---------|
| ProtocolAccessManager | `0x576FdA6522B2490e872356e3C8adf70D3361cdb9` |
| TransferIntentManager | `0x4e2E8f19a95BE64C0df6efEC0f60b3aE2876Ede7` |
| RuleEngineComplianceProvider | `0xC4D82d10968FD86550D95E6A24Cb2a1621F26104` |
| ERC3643AssetAdapter | `0x01CA5C34b2e74815B22aB0Ef5b499C34cA3a4ea6` |
| CCIPTransportProvider | `0x1D28767d8e0Cd01A05EC23f80b977fe39C62892d` |
| SettlementCoordinator | `0x40c6c6b2cfA5b53E146F9E2b0B4fb3cb51710D46` |
| RWA Token | `0xf66ab3981E0479Be90866dBEB19a9662Eea8bba8` |

## Roles

| Role | Granted To | Permissions |
|------|-----------|-------------|
| `DEFAULT_ADMIN` | Deployer wallet | Role management on ProtocolAccessManager |
| `BRIDGE_ROLE` | SettlementCoordinator, Bridge operator | `transitionState`, `sendMessage`, `reserveAssets`, `burnReservedAssets`, `mintAssets` |
| `COMPLIANCE_ROLE` | Compliance operator | `configureAsset`, `configureCompliance`, `cancelTransferIntent` |
| `AGENT_ROLE` (ERC-3643) | Deployer wallet, AssetAdapter | `mint`, `burn` on ERC-3643 token |

## Configuration

### Compliance Parameters

Set during deployment via `COMPLIANCE_ROLE`:

```
allowedAssets[ASSET_ID]                    = true
allowedActions[TRANSFER]                   = true
chainJurisdiction(Sepolia)                 = keccak256("US")
chainJurisdiction(Fuji)                    = keccak256("EU")
minimumClassification                      = INSTITUTIONAL
maxTransferAmount(ASSET_ID)                = 100,000 tokens
maxHolding(ASSET_ID)                       = 1,000,000 tokens
policyVersion                              = keccak256("POLICY:v1")
```

### Asset ID

```
ASSET_ID = keccak256("RWA_TOKEN")
```

## Project Structure

```
protocol/
├── contracts/
│   ├── access/          ProtocolAccessManager (role registry)
│   ├── adapters/        ERC3643AssetAdapter (vendor bridge)
│   ├── common/          ProtocolTypes (shared enums/structs)
│   ├── compliance/      RuleEngineComplianceProvider
│   ├── core/            SettlementCoordinator, TransferIntentManager
│   ├── extensions/
│   │   ├── bridge/      CCIPTransportProvider (CCIP adapter)
│   │   ├── ace/         ACEAdapter (future)
│   │   ├── corporate/   CorporateActions (future)
│   │   ├── documents/   DocumentRegistry (future)
│   │   └── partitions/  PartitionManager (future)
│   ├── factories/       (planned)
│   └── interfaces/      IAssetAdapter, ISettlementCoordinator, etc.
├── script/              26 deployment scripts (DeployBase, Config, chain-specific)
├── test/
│   ├── conformance/     13 invariant scenarios
│   ├── integration/     full lifecycle tests
│   ├── mocks/           MockCCIPRouter, MockERC3643Token
│   └── utils/           ProtocolFixture, ERC3643Deployer
├── lib/                 forge-std, openzeppelin-contracts
├── foundry.toml         build config
└── AGENTS.md            detailed architecture reference
```

### Vendor Libraries (submodules)

| Library | Path | Purpose |
|---------|------|---------|
| ERC-3643 | `../vendor/erc3643/` | T-REX security token standard |
| ONCHAINID | `../vendor/onchainid/` | On-chain identity framework |
| OpenZeppelin | `lib/openzeppelin-contracts/` | Standard contracts (v5) |
| OpenZeppelin Upgradeable | `lib/openzeppelin-contracts-upgradeable/` | Upgradeable contracts (v5) |

## Extending the Adapter Layer

The `IAssetAdapter` interface is token-standard-agnostic. To support a new token standard (ERC-1400, ERC-20, etc.):

1. Implement `IAssetAdapter` for the new token standard
2. Deploy alongside existing contracts
3. Point a new `SettlementCoordinator` to the new adapter

The SettlementCoordinator works unchanged — it only sees `IAssetAdapter`.

## Extending Transport

The `ITransportProvider` interface is transport-agnostic. To use a different bridge:

1. Implement `ITransportProvider` for the new transport
2. Deploy alongside existing contracts
3. Point a new `SettlementCoordinator` to the new transport provider

## Future Work

- [ ] **Reservation Extension** — replace internal accounting with dedicated lock vault
- [ ] **RecoveryManager** — automated rollback recovery for failed settlements
- [ ] **ERC-3643 Modular Compliance** — bind CountryRestriction, MaxBalance, etc. modules
- [ ] **Multi-sig Admin** — replace single EOA admin on ProtocolAccessManager
- [ ] **LOCK_MINT / ESCROW_RELEASE** settlement models
- [ ] **SDK** — TypeScript client library
- [ ] **Backend** — off-chain intent builder and monitoring
- [ ] **CI/CD** — GitHub Actions for automated testing and deployment

## License

Apache 2.0
