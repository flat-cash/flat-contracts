# FlatEthVault Deployment Evidence

## Scope

This document records the deployed Ethereum mainnet FlatEthVault address while the original Solidity source is recovered. It is **not** a substitute for verified source code and does not make claims about access controls, pausing, reward rates, or user-fund permissions that require a source-to-bytecode match.

| Field | Recorded evidence |
|---|---|
| Contract | FlatEthVault |
| Network | Ethereum Mainnet (chain ID 1) |
| Address | [`0xb7796498cfF4592CAd396e24828e1BC981c9684F`](https://etherscan.io/address/0xb7796498cfF4592CAd396e24828e1BC981c9684F) |
| Public explorer creator | `0x959886194B5F42891A804be614Eb0e6dBBaBbea2` |
| Explorer source status | Unverified bytecode at the time this record was prepared |
| Compiler metadata | Solidity `0.8.24` encoded in the deployed bytecode metadata |
| Metadata IPFS CID | `QmU719eHUuz6UBTcmznLNGN4Sr65SLibwprzPqHJjFXKtC` |
| Source lookup | No metadata/source bundle was available through Etherscan, Blockscout, or Sourcify during recovery |

## Recovery Requirement

Before adding `src/vault/FlatEthVault.sol` to this repository as verified source, recover the original project artifact or source file, compile it using the recorded compiler settings, and compare the resulting runtime bytecode with the contract deployed at the address above. Until that comparison succeeds, the source status must remain **publication pending**.
