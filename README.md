# FLAT Protocol Smart Contracts

Verified Solidity source code and deployment evidence for FLAT Protocol contracts on **Ethereum Mainnet**. Source-verification status is recorded per contract.

> *Mathematica Inevitabilis Est* — The math is inevitable.

## Overview

FLAT Protocol is a CPI-pegged stablecoin system with irreversible supply absorption, private transfer infrastructure, and custodial vaults for the FlatID account system. Each entry states its own source-verification and control status; do not generalize one contract’s status to another.

**Website:** [flat.cash](https://flat.cash) · **Contracts Page:** [flat.cash/contracts](https://flat.cash/contracts) · **Agents:** [flat.cash/agents](https://flat.cash/agents)

## Deployed Contracts

| Contract | Address | Tier | Compiler |
|----------|---------|------|----------|
| **FLAT** | [`0x6AD27352CEb1B55A1Cbf885cEfC2Ed5A9183aE99`](https://etherscan.io/address/0x6ad27352ceb1b55a1cbf885cefc2ed5a9183ae99) | Fully Immutable | 0.8.24 |
| **FlatSale V4** | [`0x968A01C2C54e295573411ef5db52D2a5F56D215b`](https://etherscan.io/address/0x968a01c2c54e295573411ef5db52d2a5f56d215b) | Ownable2Step | 0.8.28 |
| **RISE** | [`0xc1E141863414f434E46162A1184345E45CF5a14A`](https://etherscan.io/address/0xc1e141863414f434e46162a1184345e45cf5a14a) | Fully Immutable | 0.8.26 |
| **SAVE (Vault)** | [`0x9f0DD6e940478293964aE778e4C720B720cf9cAe`](https://etherscan.io/address/0x9f0dd6e940478293964ae778e4c720b720cf9cae) | Fully Immutable | 0.8.26 |
| **SAVESale v3** | [`0x1735e5a74E4f948E16e987D4C8Ba2a8DE05Cd3CB`](https://etherscan.io/address/0x1735e5a74E4f948E16e987D4C8Ba2a8DE05Cd3CB) | Guardian (3yr) | 0.8.26 |
| **BearerSwapV4** | [`0xD46633C54058D28Cad5d77C897df042dCCdADF4c`](https://etherscan.io/address/0xD46633C54058D28Cad5d77C897df042dCCdADF4c) | Guardian (3yr) | 0.8.24 |
| **FlatIDVaultV3** | [`0x25ec1e6d07d70427BFA049Cc349079448080568C`](https://etherscan.io/address/0x25ec1e6d07d70427BFA049Cc349079448080568C) | Admin-Controlled | 0.8.20 |
| **FlatIDSaveVaultV3** | [`0xe1b70B17AEf2dc810C5EA9b73aEA092B7cA1270B`](https://etherscan.io/address/0xe1b70B17AEf2dc810C5EA9b73aEA092B7cA1270B) | Admin-Controlled | 0.8.20 |
| **FlatEthVault** | [`0xb7796498cfF4592CAd396e24828e1BC981c9684F`](https://etherscan.io/address/0xb7796498cfF4592CAd396e24828e1BC981c9684F) | Deployed vault; source publication pending | 0.8.24 (bytecode metadata) |

> **FlatEthVault source status.** The Ethereum mainnet address is deployed, but its Solidity source is not currently published in this repository, Etherscan, Blockscout, or Sourcify. Its compiler-metadata evidence is documented in [`docs/FlatEthVault.DEPLOYMENT.md`](./docs/FlatEthVault.DEPLOYMENT.md). Do not treat this repository’s FlatEthVault entry as verified source until a source build has been matched to the deployed bytecode.

### Uniswap V2 Pairs

| Pair | Address |
|------|---------|
| FLAT/WETH | [`0x2bC1036435A95DB36E44230Dba14Cb00E3C47205`](https://etherscan.io/address/0x2bc1036435a95db36e44230dba14cb00e3c47205) |
| SAVE/WETH | [`0xEC404E3d1F513cbf88bFc1e15af65BCaBB142bEa`](https://etherscan.io/address/0xEC404E3d1F513cbf88bFc1e15af65BCaBB142bEa) |
| RISE/WETH | [`0x2cC90956C7bB5B1b7644CbaBdf031Fdd883216d5`](https://etherscan.io/address/0x2cC90956C7bB5B1b7644CbaBdf031Fdd883216d5) |

## Repository Structure

```
src/
├── core/
│   ├── FLAT.sol          # CPI-pegged stablecoin (100T supply, immutable)
│   ├── RISE.sol          # Base token (425M supply, burnable, immutable)
│   └── SAVE.sol          # Irreversible RISE lock vault (absorption mechanism)
├── sale/
│   ├── FlatSaleV4.sol    # ETH→FLAT sale with on-chain CPI oracle
│   └── SaveSaleV3.sol    # Composable SAVE sale with POL routing
├── privacy/
│   └── BearerSwapV4.sol  # Private transfer & swap infrastructure
└── vault/
    ├── FlatIDVaultV3.sol      # Custodial FLAT vault (FlatID accounts)
    └── FlatIDSaveVaultV3.sol  # Custodial SAVE vault (FlatID accounts)
docs/
└── FlatEthVault.DEPLOYMENT.md # Deployed-address evidence; source recovery pending
interfaces/
├── IAggregatorV3.sol     # Chainlink price feed interface
├── IUniswapV2Router02.sol
└── IUniswapV2Pair.sol
```

## Security Model

### Tier 1 — Fully Immutable
**FLAT, RISE, SAVE**: No owner, no admin, no pause, no proxy, no blacklist. Pure immutable bytecode. Cannot be modified by anyone after deployment.

### Tier 2 — Guardian Pattern
**FlatSale V4, SAVESale v3, BearerSwapV4**: Guardian (Gnosis Safe multisig) can pause new operations but **withdrawals are NEVER pausable**. Guardian expires after 3 years — contracts become fully immutable.

### Tier 3 — Admin-Controlled Vaults
**FlatIDVaultV3, FlatIDSaveVaultV3**: Custodial by design. Admin (Ledger cold wallet) manages deposits/withdrawals for FlatID accounts. Security features:
- Heartbeat dead-man's switch (admin must ping every 30 days)
- Bounded pause (7 days max, 7-day cooldown)
- Emergency withdrawal (users can always exit with principal)
- Operator daily settlement cap (bounds compromised operator damage)
- Solvency invariant (vault always holds ≥ sum of all balances)

## Key Addresses

| Role | Address |
|------|---------|
| Protocol Owner | `0x11d6bac585a6B1d905080f90b86Ba86B18CbfC2e` |
| FlatID Admin (Ledger) | `0xdDf493752E2578f64dd78249D846E3C87A6936bC` |
| Operator (Relayer) | `0x959886194B5F42891A804be614Eb0e6dBBaBbea2` |
| Treasury (Gnosis Safe) | `0x781fc238a2e8D0a7a986B4BD2C8835C60dC9C714` |
| Network | Ethereum Mainnet (Chain ID: 1) |

## The Singularity Equation

```
P(α) = C / (1 - α)
```

As absorption (α) approaches 1, price approaches infinity. SAVE locks RISE permanently — supply can only decrease. The protocol is designed to approach the event horizon through mechanical buyback and irreversible locking.

## Frameworks Used

- **FLAT, RISE, SAVE**: OpenZeppelin 5.x (Remix)
- **FlatSale V4**: OpenZeppelin 5.x (Foundry)
- **SAVESale v3**: OpenZeppelin 5.x (Remix)
- **BearerSwapV4**: OpenZeppelin 5.x (Foundry)
- **FlatIDVaultV3/FlatIDSaveVaultV3**: Inlined SafeERC20 (Hardhat, 0.8.20)

## Verification

For contracts identified as source-verified, compare the repository source with the verified on-chain source:

1. Visit the Etherscan link for any contract above
2. Go to the "Contract" tab → "Read Contract" or "Code"
3. Compare with the corresponding `.sol` file in this repo

FlatEthVault is intentionally excluded from that verified-source claim until its original Solidity source is recovered and its compiled bytecode is matched to the deployment.

## Note on BearerSwapV4

The BearerSwapV4 source in this repository shows the contract structure, state variables, events, and function signatures. The full implementation (~1130 nSLOC) is available on [Etherscan](https://etherscan.io/address/0xD46633C54058D28Cad5d77C897df042dCCdADF4c#code). Function bodies are condensed here for readability — the on-chain verified source is the canonical reference.

## Links

- **Website**: [flat.cash](https://flat.cash)
- **Contracts Page**: [flat.cash/contracts](https://flat.cash/contracts)
- **AI Agent Economy**: [flat.cash/agents](https://flat.cash/agents)
- **Agent Wallet Demo**: [github.com/flat-cash/private-agent-wallet](https://github.com/flat-cash/private-agent-wallet)
- **Twitter**: [@FlatProtocol](https://x.com/FlatProtocol)

## License

MIT — see [LICENSE](./LICENSE) for details.

---

*Author: Flat Protocol team*
