# Deployment History

All contracts deployed on **Ethereum Mainnet (Chain ID: 1)**.

## Timeline

| Date | Event |
|------|-------|
| April 26, 2026 | Original deployment (FLAT, RISE, SAVE, FlatSale V1) |
| April 29, 2026 | V2 migration (FlatSale V2) |
| June 2, 2026 | V3/V4 migration (FlatSale V4, SAVESale v3) |
| June 18, 2026 | FlatIDVaultV3 + FlatIDSaveVaultV3 deployed |
| July 16, 2026 | BearerSwapV4 deployed |

## Contract Addresses

### Core Tokens

| Contract | Address | Etherscan |
|----------|---------|-----------|
| FLAT | `0x6AD27352CEb1B55A1Cbf885cEfC2Ed5A9183aE99` | [View](https://etherscan.io/address/0x6ad27352ceb1b55a1cbf885cefc2ed5a9183ae99) |
| RISE | `0xc1E141863414f434E46162A1184345E45CF5a14A` | [View](https://etherscan.io/address/0xc1e141863414f434e46162a1184345e45cf5a14a) |
| SAVE | `0x9f0DD6e940478293964aE778e4C720B720cf9cAe` | [View](https://etherscan.io/address/0x9f0dd6e940478293964ae778e4c720b720cf9cae) |

### Sale Contracts

| Contract | Address | Etherscan |
|----------|---------|-----------|
| FlatSale V4 | `0x968A01C2C54e295573411ef5db52D2a5F56D215b` | [View](https://etherscan.io/address/0x968a01c2c54e295573411ef5db52d2a5f56d215b) |
| SAVESale v3 | `0x1735e5a74E4f948E16e987D4C8Ba2a8DE05Cd3CB` | [View](https://etherscan.io/address/0x1735e5a74E4f948E16e987D4C8Ba2a8DE05Cd3CB) |

### Privacy Infrastructure

| Contract | Address | Etherscan |
|----------|---------|-----------|
| BearerSwapV4 | `0xD46633C54058D28Cad5d77C897df042dCCdADF4c` | [View](https://etherscan.io/address/0xD46633C54058D28Cad5d77C897df042dCCdADF4c) |

### FlatID Vaults

| Contract | Address | Etherscan |
|----------|---------|-----------|
| FlatIDVaultV3 | `0x25ec1e6d07d70427BFA049Cc349079448080568C` | [View](https://etherscan.io/address/0x25ec1e6d07d70427BFA049Cc349079448080568C) |
| FlatIDSaveVaultV3 | `0xe1b70B17AEf2dc810C5EA9b73aEA092B7cA1270B` | [View](https://etherscan.io/address/0xe1b70B17AEf2dc810C5EA9b73aEA092B7cA1270B) |

### Uniswap V2 Pairs

| Pair | Address | Etherscan |
|------|---------|-----------|
| FLAT/WETH | `0x2bC1036435A95DB36E44230Dba14Cb00E3C47205` | [View](https://etherscan.io/address/0x2bc1036435a95db36e44230dba14cb00e3c47205) |
| SAVE/WETH | `0xEC404E3d1F513cbf88bFc1e15af65BCaBB142bEa` | [View](https://etherscan.io/address/0xEC404E3d1F513cbf88bFc1e15af65BCaBB142bEa) |
| RISE/WETH | `0x2cC90956C7bB5B1b7644CbaBdf031Fdd883216d5` | [View](https://etherscan.io/address/0x2cC90956C7bB5B1b7644CbaBdf031Fdd883216d5) |

### External Dependencies

| Contract | Address | Purpose |
|----------|---------|---------|
| Chainlink ETH/USD | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` | Price feed for FlatSale V4 |
| Uniswap V2 Router | `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D` | Liquidity routing |
| Uniswap V2 Factory | `0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f` | Pair creation |

## Key Roles

| Role | Address | Notes |
|------|---------|-------|
| Protocol Owner | `0x11d6bac585a6B1d905080f90b86Ba86B18CbfC2e` | Deployer |
| FlatID Admin | `0xdDf493752E2578f64dd78249D846E3C87A6936bC` | Ledger cold wallet |
| Operator/Relayer | `0x959886194B5F42891A804be614Eb0e6dBBaBbea2` | Hot wallet for operations |
| Treasury (Gnosis Safe) | `0x781fc238a2e8D0a7a986B4BD2C8835C60dC9C714` | Protocol treasury |
