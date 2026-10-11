# FlatSale V6 Generation — Deployment Runbook (for Manus)

This runbook is the single source of truth for deploying the reviewed V6-generation
contracts and bringing them live. Execute the steps **in order**. Do not skip any
verification step. If any check fails, stop and report — do not retry blindly.

**Contracts covered:**

| Contract | Source | Role |
|----------|--------|------|
| FlatSaleV6 | `src/sale/FlatSaleV6.sol` | Oracle-priced ETH→FLAT sale. No pool/router/LP surface. 100% of buyer ETH forwards to the Safe in the purchase transaction. |
| SflatSaveRedeemer | `src/sale/SflatSaveRedeemer.sol` | Lets sFLAT holders redeem shares for SAVE (instead of FLAT) at the V6 oracle price. All FLAT proceeds forward to the Safe. |
| FlatLiquidityExecutor | `src/sale/FlatLiquidityExecutor.sol` | Operator-exclusive FLAT/WETH liquidity adds. LP tokens mint **directly to the Safe**. Pool-vs-oracle deviation guard built in. |

**Fixed addresses (Ethereum Mainnet, Chain ID 1):**

| Name | Address |
|------|---------|
| FLAT token | `0x6AD27352CEb1B55A1Cbf885cEfC2Ed5A9183aE99` |
| SAVE token | `0x9f0DD6e940478293964aE778e4C720B720cf9cAe` |
| sFLAT vault (share token + ERC-4626 vault) | `0xD5d09e49AdF6C7A98b7B0e0157F5d537Ca6e7091` |
| Chainlink ETH/USD feed (8 decimals) | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` |
| Uniswap V2 Router02 | `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D` |
| FLAT/WETH pair | `0x2bC1036435A95DB36E44230Dba14Cb00E3C47205` |
| FlatSale V5 (retiring; price reference) | `0xE0c26C7f04cAcB13f99A772C5e3888d9C1A6a408` |
| Protocol Gnosis Safe | `0x781fc238a2e8D0a7a986B4BD2C8835C60dC9C714` |
| Relayer (deployer wallet, ~$100 ETH) | `0x959886194B5F42891A804be614Eb0e6dBBaBbea2` |
| Operator (owner-at-birth / liquidity operator) | `0xdDf493752E2578f64dd78249D846E3C87A6936bC` |

Note: `INITIAL_OWNER` is hard-coded in `FlatSaleV6` and `SflatSaveRedeemer` as the
operator address above. The deployer is the relayer; control starts with the
operator; ownership then moves (two-step) to the Safe.

---

## Step 0 — Build environment

```bash
git clone https://github.com/flat-cash/flat-contracts.git
cd flat-contracts
# V6 imports @openzeppelin/* — the repo does not vendor lib/, install it:
forge install OpenZeppelin/openzeppelin-contracts
forge build
```

The repo `foundry.toml` pins `solc = "0.8.28"`, `optimizer = true`,
`optimizer_runs = 200`. All three contracts compile under this profile
(`pragma solidity ^0.8.24` accepts 0.8.28). **Use these exact settings for
deployment and verification so the Etherscan verification is an Exact Match.**
`forge verify-contract` reads them automatically.

## Step 1 — Deploy FlatSaleV6

Constructor takes one `DeployParams` struct. **Field order matters:**

```
DeployParams {
  address flat;                 // 0x6AD27352CEb1B55A1Cbf885cEfC2Ed5A9183aE99
  address ethUsdFeed;           // 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
  address protocolSafe;         // 0x781fc238a2e8D0a7a986B4BD2C8835C60dC9C714
  uint256 baseCPI;              // 329336
  uint256 initialCPI;           // 334131
  uint256 initialRefCPI;        // 333979
  uint256 initialRatePerSecond; // 1000000000057713711392792996
  uint256 initialBasePrice;     // read fresh, see below
  Config initialConfig;         // see table
  Bounds limits;                // see table
}
```

**`initialBasePrice` — read it fresh, do not copy a stale number.** Immediately
before deploying, call `getFlatPriceUSD()` on FlatSale V5
(`0xE0c26C7f04cAcB13f99A772C5e3888d9C1A6a408`) and use the exact returned value.
Reference value at preparation time: `1019661727694054150` (≈ $1.0197). The
constructor reverts if it is outside `[0.5e18, 3e18]`.

**`initialConfig` (Config, in order):**

| Field | Value |
|-------|-------|
| buyerFlatCap | `25000000000000000000000` (25,000 FLAT) |
| maxFlatPerTx | `2500000000000000000000` (2,500 FLAT) |
| maxFlatPerWindow | `5000000000000000000000` (5,000 FLAT / rolling 24 h) |
| minPurchaseEth | `10000000000000000` (0.01 ETH) |
| ethUsdStaleness | `3600` (seconds) |

**`limits` (Bounds, in order — immutable after deployment):**

| Field | Value |
|-------|-------|
| maxBuyerFlatCap | `1000000000000000000000000` (1,000,000 FLAT) |
| maxFlatPerTx | `50000000000000000000000` (50,000 FLAT) |
| maxFlatPerWindow | `100000000000000000000000` (100,000 FLAT) |
| minPurchaseEth | `1000000000000000` (0.001 ETH) |
| maxEthUsdStaleness | `7200` |
| minFlatPriceUsd | `500000000000000000` (0.5 USD) |
| maxFlatPriceUsd | `3000000000000000000` (3 USD) |
| minAnnualFactorRay | `880000000000000000000000000` (0.88e27) |
| maxAnnualFactorRay | `1120000000000000000000000000` (1.12e27) |
| annualRateToleranceBps | `25` |
| annualizationSeconds | `31536000` |
| cpiPeriodsPerYear | `4` |
| salesWindowSeconds | `86400` |
| configDelaySeconds | `86400` (24 h) |
| unpauseDelaySeconds | `172800` (48 h) |

Deploy **from the relayer**. The contract starts **paused with zero inventory** —
this is expected and required.

## Step 2 — Verify FlatSaleV6 on-chain (two independent RPCs)

Before anything else depends on the address, confirm on **two different RPC
endpoints** (e.g. your primary provider and a public fallback):

1. `flat()` == FLAT, `ethUsdFeed()` == Chainlink feed, `protocolSafe()` == Safe.
2. `owner()` == operator `0xdDf4…936bC`.
3. `paused()` == `true`.
4. `basePrice()` == the `initialBasePrice` you supplied; `ratePerSecond()` ==
   `1000000000057713711392792996`; `currentCPI()` == `334131`;
   `refCPI()` == `333979`.
5. Compute `keccak256` of the deployed runtime bytecode (`eth_getCode`) and
   **record it** — the website pins this exact hash
   (`FLAT_SALE_V6_RUNTIME_HASH`).

Then submit the source for verification:

```bash
forge verify-contract <V6_ADDRESS> src/sale/FlatSaleV6.sol:FlatSaleV6 \
  --chain 1 --etherscan-api-key <KEY> --watch
```

Confirm Etherscan shows **Exact Match**. If it shows only "Similar Match", stop
and resolve the compiler settings before continuing.

## Step 3 — Deploy SflatSaveRedeemer

Constructor — **9 positional arguments, in order**:

| # | Arg | Value |
|---|-----|-------|
| 1 | sflatToken | `0xD5d09e49AdF6C7A98b7B0e0157F5d537Ca6e7091` |
| 2 | flatToken | `0x6AD27352CEb1B55A1Cbf885cEfC2Ed5A9183aE99` |
| 3 | saveToken | `0x9f0DD6e940478293964aE778e4C720B720cf9cAe` |
| 4 | sflatVault | `0xD5d09e49AdF6C7A98b7B0e0157F5d537Ca6e7091` (same as #1) |
| 5 | flatPriceSource | **the FlatSaleV6 address from Step 1** |
| 6 | safe | `0x781fc238a2e8D0a7a986B4BD2C8835C60dC9C714` |
| 7 | initialSaveUsdRate | `1000000000000000000` (1.00 USD) |
| 8 | maxSavePerTx_ | `25000000000000000000000` (25,000 SAVE) |
| 9 | maxSavePerWindow_ | `100000000000000000000000` (100,000 SAVE / 24 h) |

Starts paused. Verify on-chain: `priceSource()` == V6, `owner()` == operator,
`paused()` == true, then `forge verify-contract` (Exact Match). Record the
runtime hash as in Step 2.

## Step 4 — Deploy FlatLiquidityExecutor

Constructor — **7 positional arguments, in order**:

| # | Arg | Value |
|---|-----|-------|
| 1 | flatToken | `0x6AD27352CEb1B55A1Cbf885cEfC2Ed5A9183aE99` |
| 2 | flatPriceSource | **the FlatSaleV6 address from Step 1** |
| 3 | ethUsdFeed_ | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` |
| 4 | flatWethPair | `0x2bC1036435A95DB36E44230Dba14Cb00E3C47205` |
| 5 | uniswapRouter | `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D` |
| 6 | safe | `0x781fc238a2e8D0a7a986B4BD2C8835C60dC9C714` |
| 7 | initialOperator | `0xdDf493752E2578f64dd78249D846E3C87A6936bC` |

Starts paused; `unpause()` is **Safe-only** (a compromised operator cannot
re-enable itself). There is no owner and no ownership transfer on this contract.
Verify `operator()` == operator address, `protocolSafe()` == Safe,
`paused()` == true, then `forge verify-contract` (Exact Match).

## Step 5 — Transfer ownership to the Safe (V6 + Redeemer)

For **FlatSaleV6** and **SflatSaveRedeemer** (not the executor — it has no owner):

1. From the **operator** wallet: `transferOwnership(0x781fc238a2e8D0a7a986B4BD2C8835C60dC9C714)`.
   The contract rejects any other target.
2. From the **Safe** (Gnosis Safe UI → New Transaction → Contract Interaction):
   `acceptOwnership()`.
3. Confirm `owner()` == Safe on both contracts (two RPCs).

After this, the operator EOA has no privileges on V6 or the redeemer.

## Step 6 — Fund inventory

From the **Safe**:

1. Transfer FLAT sale inventory to FlatSaleV6. Initial float: **25,000 FLAT**
   (matches `buyerFlatCap`; do not exceed the cap).
2. Transfer SAVE inventory to SflatSaveRedeemer (protocol decision; the
   per-window cap bounds outflow regardless).

Both contracts expose paused-only, Safe-bound recovery
(`recoverFlatToSafe` / `recoverToken`), so inventory is retrievable while paused.

## Step 7 — Activation and first transactions

V6 activation is deliberately a **two-transaction, 48-hour-delayed** process:

1. From the Safe: `queueUnpause()` on FlatSaleV6.
2. Wait until `unpauseExecutableAt()` (48 h later).
3. From the Safe: `executeUnpause()`. The contract re-checks that a minimum
   purchase is currently purchasable before it will unpause.
4. Make one small test purchase (~0.01 ETH) from a test wallet via
   `buyTo(recipient, minFlatOut, deadline)` with a fresh `quote()`. Confirm:
   - FLAT arrived at the recipient;
   - **the full ETH amount is sitting in the Safe** (V6 retains nothing);
   - `Purchased` event fields match the quote.

For SflatSaveRedeemer: the Safe calls `unpause()` directly (no delay), then test
a small `redeemToSave` with fresh approvals. **Remember: the SAVE/USD rate must
be refreshed by the owner at least every 24 h** (`RATE_STALENESS_SECONDS =
86400`) or redemptions revert with `StaleRate`. Establish the operations cadence
before enabling.

For FlatLiquidityExecutor: the Safe calls `unpause()`. Only the operator EOA can
then call `addLiquidity(flatAmount, maxDeviationBps, deadline)` — funding each
call with FLAT (approve first) plus ETH value; LP tokens mint straight to the
Safe; unused ETH/FLAT refund to the operator in the same transaction.

## Step 8 — Website go-live (only after Steps 1–7 verify clean)

The website ships **fail-closed**: every V6 surface stays dark until reviewed
coordinates are committed. In the `flatcash-vps` repo, in **one commit**:

1. `shared/sflat.ts` — set `FLAT_SALE_V6_ADDRESS` (deployed V6 address) and
   `FLAT_SALE_V6_RUNTIME_HASH` (the `keccak256` runtime hash recorded in Step 2).
2. `shared/flatsale-v6.ts` — set `FLATSALE_V6_BUY_FRONTEND_ENABLED = true`.
3. `shared/sflat.ts` — set the `SFLAT_SAVE_EXIT_*` coordinates to the deployed
   SflatSaveRedeemer address + runtime hash (enables the sFLAT → SAVE option
   alongside the existing sFLAT → FLAT redemption).
4. `server/flatsale-v6-release.test.ts` — update the pinned expectations in the
   same commit (the test intentionally fails the build while coordinates are
   null).
5. Add the three contracts to the `/contracts` registry
   (`client/src/pages/ContractInterfaces.tsx`).

Once this commit deploys, `/api/flatsale` serves V6 (`version: 6`) and the Buy
FLAT page switches to the verified V6 purchase panel automatically.

## Abort / incident rules

- Never re-broadcast a transaction whose hash you did not record; check the
  relayer's on-chain nonce/history first.
- If any verification step mismatches, pause everything (the Safe can pause all
  three contracts instantly) and report the exact mismatch.
- The V5 sale contract is retired by the website switch, not by an on-chain
  action; its owner can keep it paused permanently.
