# Deployment History

All contracts deployed on **Ethereum Mainnet (Chain ID: 1)**.

Status legend: **Live** (in the current application path) · **Pending activation** (deployed paused, awaiting Safe action) · **Superseded** (paused ahead of a newer deployment) · **Retired** (paused and emptied) · **Inactive** (paused/inert, kept for historical reference) · **Abandoned** (dead-man's switch tripped; all admin/operator paths permanently frozen, only user `emergencyWithdraw` remains) · **In development** (specified and tested, not yet deployed).

## Timeline

| Date | Event |
|------|-------|
| April 26, 2026 | Original deployment (FLAT, RISE, SAVE, FlatSale V1) |
| April 29, 2026 | V2 migration (FlatSale V2) |
| June 2, 2026 | V3/V4 migration (FlatSale V4, SAVESale v3) |
| June 17–19, 2026 | FlatID vault lineage deployed: V1 vault (`0xee05…1644`) → V2.9 vault (`0xaca8…f59a`) → V3 vaults (FlatIDVaultV3 + FlatIDSaveVaultV3) with P2P settleTransfer |
| July 10, 2026 | SAVESale v3 inventory swept; retired |
| July 16, 2026 | BearerSwapV4 deployed (later superseded in the application by BearerSwapV3) |
| August 18, 2026 | **Both FlatID V3 vaults abandoned** — 60-day heartbeat (last heartbeat June 19, 2026 05:54–05:56 UTC) expired; all admin/operator functions permanently frozen |
| September 22, 2026 | FlatSale V5 Etherscan exact-match verified |
| September 27, 2026 | SAVESale V4 paused and complete SAVE inventory swept; retired |
| October 2026 | V6 generation deployed paused: FlatSale V6, sFLAT Save Redeemer, Flat Liquidity Executor; ownership transferred (two-step) to the Gnosis Safe; FlatSale V5 paused ahead of the cutover |
| October 14, 2026 | FlatSale V6 unpause timelock executable (06:50:23 UTC) — pending Safe execution |
| October 14, 2026 | FlatIDVaultV4 specified, implemented, and tested (`src/vault/FlatIDVaultV4.sol`, `test/FlatIDVaultV4.t.sol`, 29-check behavioral suite green) — deployment pending |

## Contract Addresses

### Core Tokens

| Contract | Address | Status | Etherscan |
|----------|---------|--------|-----------|
| FLAT | `0x6AD27352CEb1B55A1Cbf885cEfC2Ed5A9183aE99` | Live (immutable) | [View](https://etherscan.io/address/0x6ad27352ceb1b55a1cbf885cefc2ed5a9183ae99) |
| RISE | `0xc1E141863414f434E46162A1184345E45CF5a14A` | Live (immutable) | [View](https://etherscan.io/address/0xc1e141863414f434e46162a1184345e45cf5a14a) |
| SAVE | `0x9f0DD6e940478293964aE778e4C720B720cf9cAe` | Live (immutable; irreversible RISE lock vault) | [View](https://etherscan.io/address/0x9f0dd6e940478293964ae778e4c720b720cf9cae) |

### Sale Contracts

| Contract | Address | Status | Etherscan |
|----------|---------|--------|-----------|
| FlatSale V6 | `0x15B6F6E7789D515827D93C42d0d37E838f065700` | Pending activation (deployed paused; owner = Gnosis Safe; unpause queued for October 14, 2026 06:50:23 UTC) | [View](https://etherscan.io/address/0x15b6f6e7789d515827d93c42d0d37e838f065700) |
| FlatSale V5 | `0xE0c26C7f04cAcB13f99A772C5e3888d9C1A6a408` | Superseded (paused ahead of the V6 cutover) | [View](https://etherscan.io/address/0xe0c26c7f04cacb13f99a772c5e3888d9c1a6a408) |
| FlatSale V4 | `0x968A01C2C54e295573411ef5db52D2a5F56D215b` | Superseded (paused) | [View](https://etherscan.io/address/0x968a01c2c54e295573411ef5db52d2a5f56d215b) |
| FlatSale v3 | `0x01ddC49b9C366D5c40C57d002BA08fD0eA669189` | Superseded (do not use for new integrations) | [View](https://etherscan.io/address/0x01ddc49b9c366d5c40c57d002ba08fd0ea669189) |
| SAVESale V4 | `0x8582E7626Ac9d23a6a1d176F5770C4C28b87bd97` | Retired (paused; zero SAVE / zero ETH since September 27, 2026) | [View](https://etherscan.io/address/0x8582e7626ac9d23a6a1d176f5770c4c28b87bd97) |
| SAVESale v3 | `0x1735e5a74E4f948E16e987D4C8Ba2a8DE05Cd3CB` | Retired (inventory swept July 10, 2026) | [View](https://etherscan.io/address/0x1735e5a74e4f948e16e987d4c8ba2a8de05cd3cb) |

### Savings (sFLAT)

| Contract | Address | Status | Etherscan |
|----------|---------|--------|-----------|
| Savings FLAT (sFLAT vault) | `0xD5d09e49AdF6C7A98b7B0e0157F5d537Ca6e7091` | Live (exact-match verified; 180,000,000-FLAT locked launch reserve) | [View](https://etherscan.io/address/0xd5d09e49adf6c7a98b7b0e0157f5d537ca6e7091) |
| Savings FLAT ETH Adapter | `0x283E45528C7Cf58C6838d4316AD032e4B707510F` | Live, gated upstream (hard-bound FlatSale V5 dependency is paused pending a V6-compatible path) | [View](https://etherscan.io/address/0x283e45528c7cf58c6838d4316ad032e4b707510f) |
| sFLAT Save Redeemer | `0x6B83Fe1B0330b448613FFf6A013E08B652742C35` | Pending activation (deployed paused; owner = Gnosis Safe; requires SAVE funding and a fresh SAVE/USD rate before unpause) | [View](https://etherscan.io/address/0x6b83fe1b0330b448613fff6a013e08b652742c35) |

### Liquidity

| Contract | Address | Status | Etherscan |
|----------|---------|--------|-----------|
| Flat Liquidity Executor | `0x0D1f21cF2E839f600c19185dC4ae629065F5bf9D` | Pending activation (deployed paused; operator = `0xdDf493752E2578f64dd78249D846E3C87A6936bC`; unpause is Safe-only) | [View](https://etherscan.io/address/0x0d1f21cf2e839f600c19185dc4ae629065f5bf9d) |

### Privacy Infrastructure

| Contract | Address | Status | Etherscan |
|----------|---------|--------|-----------|
| BearerSwapV3 | `0x5de315Dab49012c5bbeC41d7a3B25c6829a3e566` | Live (current FlatBearer application contract) | [View](https://etherscan.io/address/0x5de315dab49012c5bbec41d7a3b25c6829a3e566) |
| BearerSwapV4 | `0xD46633C54058D28Cad5d77C897df042dCCdADF4c` | Historical (not in the current application inventory) | [View](https://etherscan.io/address/0xD46633C54058D28Cad5d77C897df042dCCdADF4c) |

### FlatID Vaults — Version Registry

The FlatID application currently points at the **V3** vaults (see `server/flatid-account.ts`, `server/flatid-savings.ts`, `server/admin-vault.ts`). **Both V3 vaults tripped their 60-day dead-man's switch on August 18, 2026** and are permanently frozen: deposits still land (plain ERC-20 transfers), but `withdraw`, `settleTransfer`, and every admin/operator function revert. User principal remains claimable via `emergencyWithdraw()`.

| Version | Contract | Address | Status | On-chain balances |
|---------|----------|---------|--------|-------------------|
| V4 | FlatIDVaultV4 (FLAT + sFLAT + SAVE, three lanes) | *not yet deployed* | **In development** — spec in `docs/FLATIDVAULT_V4_SPECIFICATION.md`; source `src/vault/FlatIDVaultV4.sol`; tests `test/FlatIDVaultV4.t.sol` | Will honor legacy claims: 1,188.62 SAVE (V3 SAVE vault) + 49.03 FLAT (V2.9 vault) via one-time seed |
| V3 (current app wiring) | FlatIDVaultV3 (FLAT checking) | `0x25ec1e6d07d70427BFA049Cc349079448080568C` | **Abandoned** since Aug 18, 2026 | 1,000,157.05 FLAT held; 104.57 FLAT owed to users (`totalUserBalances`); ~1,000,052 FLAT surplus has no extraction path |
| V3 (current app wiring) | FlatIDSaveVaultV3 (SAVE savings) | `0xe1b70B17AEf2dc810C5EA9b73aEA092B7cA1270B` | **Abandoned** since Aug 18, 2026 | 1,188.62 SAVE held; 1,188.62 SAVE owed to users (fully user funds, no surplus) |
| V2.9-era | FlatID vault (FLAT) | `0xaca852a130033bf18cd028a87ce463ff6babf59a` | Abandoned; superseded by V3 | 49.03 FLAT held = 49.03 owed to users; funded June 17, 2026; migrated ~1,000,157 FLAT to V3 on June 19, 2026 (block 25,349,441) |
| V2.9-era | FlatID SAVE vault | `0xe2597be66c5a6fdefb668b98254f62c044ca91e9` | Retired (empty; abandoned) | 0 SAVE; swept to V3 on June 19, 2026 (block 25,349,459) |
| V1-era | FlatID vault (FLAT) | `0xee0505bc4eca8ce7a48aa4c7037bc11555881644` | Retired (empty) | 0 FLAT; funded the V2.9 vault in June 2026 |

Version labels for the pre-V3 contracts are inferred from the on-chain migration chain and the V3 source's V1/V2.9 migration notes; their bytecode exposes the same admin/operator/guardian ABI family with admin = `0xdDf493752E2578f64dd78249D846E3C87A6936bC`.

**Operational consequence:** FlatID withdrawals queued in the app cannot settle on-chain while the app points at the abandoned V3 vaults. Resolution path: deploy **FlatIDVaultV4** (heartbeat callable by admin/operator/guardian, survivable abandonment with `recoverSurplus` + one-time `revive`, per-lane caps), re-point the server constants, and seed the honored legacy claims (1,188.62 SAVE + 49.03 FLAT) via `seedBalances`/`finalizeSeed`. The ~1,000,052 FLAT surplus in FlatIDVaultV3 is permanently locked — treat it as burned supply in all circulation accounting.

### FETH V5 System (inactive)

| Contract | Address | Status | Etherscan |
|----------|---------|--------|-----------|
| FETH / FlatEthVault V5 | `0x1baEeBDcE5464bd578168d2Db433362570843971` | Inactive (exact-source verified and inert; deposits disabled and unqueued; zero assets) | [View](https://etherscan.io/address/0x1baeebdcE5464bd578168d2Db433362570843971) |
| FETH Governance Controller V1 | `0xeEa97e224C4aaEd5D50238Ee11Ca7F45eAe4C7FE` | Inactive (typed delayed governance; Safe handoff not queued) | [View](https://etherscan.io/address/0xeea97e224c4aaed5d50238ee11ca7f45eae4c7fe) |
| FETH Reward Controller V1 | `0x80A7CA3097D2232f7A086dbF48f3ac1Ed3230a52` | Inactive (no reward epoch or funding authorized) | [View](https://etherscan.io/address/0x80a7ca3097d2232f7a086dbf48f3ac1ed3230a52) |
| FETH V5 Deployment Factory | `0xCC98737AdF07E132ed61C0Ba1E0BBaE7fD1f63a8` | Inactive (constructor-only deployment record) | [View](https://etherscan.io/address/0xcc98737adf07e132ed61c0ba1e0bbae7fd1f63a8) |

### Other Historical Contracts

| Contract | Address | Status | Etherscan |
|----------|---------|--------|-----------|
| FlatArbitrage | `0x20eB6397f14D7dBbF2467B1d3f446caA7803b73C` | Inactive (paused; peg-maintenance path not in current application) | [View](https://etherscan.io/address/0x20eb6397f14d7dbbf2467b1d3f446caa7803b73c) |

### FlatEthVault (legacy, source unpublished)

| Contract | Address | Etherscan | Source status |
|----------|---------|-----------|---------------|
| FlatEthVault | `0xb7796498cfF4592CAd396e24828e1BC981c9684F` | [View](https://etherscan.io/address/0xb7796498cfF4592CAd396e24828e1BC981c9684F) | Inactive; deployed; original Solidity source recovery and bytecode match pending |

The FlatEthVault record is intentionally distinct from source-verified contract entries. Its address, creator, compiler metadata, and public-source lookup results are recorded in [`docs/FlatEthVault.DEPLOYMENT.md`](./docs/FlatEthVault.DEPLOYMENT.md).

### Oracles

| Contract | Address | Status | Purpose |
|----------|---------|--------|---------|
| CPIOracle v4 | `0x6C7B097af674F8e2daaeADcE05Eb7725083ecF7a` | Live (owner `0x11d6B213C96fE2DFCF9a6b1eE55c1019057fC2e`) | CPI-U interpolating FLAT target price; used by FlatSale v3 and FlatArbitrage. FlatSale V6 maintains its own internal CPI-compounding rate instead |
| Chainlink ETH/USD | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` | External dependency | ETH/USD read for FlatSale V6 and Flat Liquidity Executor |

### Uniswap V2 Pairs

| Pair | Address | Etherscan |
|------|---------|-----------|
| FLAT/WETH | `0x2bC1036435A95DB36E44230Dba14Cb00E3C47205` | [View](https://etherscan.io/address/0x2bc1036435a95db36e44230dba14cb00e3c47205) |
| SAVE/WETH | `0xEC404E3d1F513cbf88bFc1e15af65BCaBB142bEa` | [View](https://etherscan.io/address/0xEC404E3d1F513cbf88bFc1e15af65BCaBB142bEa) |
| RISE/WETH | `0x2cC90956C7bB5B1b7644CbaBdf031Fdd883216d5` | [View](https://etherscan.io/address/0x2cC90956C7bB5B1b7644CbaBdf031Fdd883216d5) |

### External Dependencies

| Contract | Address | Purpose |
|----------|---------|---------|
| Chainlink ETH/USD | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` | Price feed for FlatSale V6 and Flat Liquidity Executor |
| Uniswap V2 Router | `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D` | Liquidity routing (Flat Liquidity Executor) |
| Uniswap V2 Factory | `0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f` | Pair creation |

## Key Roles

| Role | Address | Notes |
|------|---------|-------|
| Protocol Treasury (Gnosis Safe) | `0x781fc238a2e8D0a7a986B4BD2C8835C60dC9C714` | Owner of FlatSale V6 and sFLAT Save Redeemer (two-step, completed); controls Flat Liquidity Executor unpause and operator rotation; receives all sale proceeds and LP tokens |
| Liquidity Operator | `0xdDf493752E2578f64dd78249D846E3C87A6936bC` | Exclusive `addLiquidity` caller on Flat Liquidity Executor; FlatID vaults admin (Ledger cold wallet — frozen on the abandoned V3 vaults); initial owner used at V6-generation deployment before Safe handoff |
| Operator/Relayer | `0x959886194B5F42891A804be614Eb0e6dBBaBbea2` | Hot wallet for deployment and operations transactions |
| Legacy Protocol Owner | `0x11d6bac585a6B1d905080f90b86Ba86B18CbfC2e` | Deployer; still owner of legacy modules (CPIOracle v4, FlatArbitrage) pending migration |

## V6 Generation — Deployment Record

Deployed per [`docs/FLATSALE_V6_DEPLOYMENT_RUNBOOK.md`](./docs/FLATSALE_V6_DEPLOYMENT_RUNBOOK.md).
All three contracts launched **paused**; ownership of FlatSale V6 and sFLAT Save Redeemer was transferred to the Gnosis Safe via two-step `transferOwnership`/`acceptOwnership` (transfers are restricted to the Safe and renunciation is disabled).

| Contract | Source | Address | On-chain state |
|----------|--------|---------|----------------|
| FlatSaleV6 | `src/sale/FlatSaleV6.sol` | `0x15B6F6E7789D515827D93C42d0d37E838f065700` | Paused; owner = Safe; unpause queued, executable October 14, 2026 06:50:23 UTC |
| SflatSaveRedeemer | `src/sale/SflatSaveRedeemer.sol` | `0x6B83Fe1B0330b448613FFf6A013E08B652742C35` | Paused; owner = Safe; requires SAVE funding + `setSaveUsdRate` before unpause |
| FlatLiquidityExecutor | `src/sale/FlatLiquidityExecutor.sol` | `0x0D1f21cF2E839f600c19185dC4ae629065F5bf9D` | Paused; operator = `0xdDf493752E2578f64dd78249D846E3C87A6936bC`; unpause Safe-only |

Activation checklist (Safe transactions, in order):
1. FlatSale V6: fund FLAT inventory, then `executeUnpause()` once the timelock matures (October 14, 2026 06:50:23 UTC).
2. Flat Liquidity Executor: Safe `unpause()` when liquidity adds are intended; operator funds each call (FLAT approval + ETH).
3. SflatSaveRedeemer: fund SAVE inventory, `setSaveUsdRate(...)` within 0.25–4 USD bounds, then `unpause()`; the rate must be refreshed at least every 24 hours thereafter.

Related live infrastructure referenced by the V6 generation: the sFLAT vault
(`0xD5d09e49AdF6C7A98b7B0e0157F5d537Ca6e7091`) and the FLAT exit router
(`0xd3777f99DA02072466067820cE0d6E4e3579ec1b`).
