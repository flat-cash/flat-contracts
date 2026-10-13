# FlatIDVaultV4 — Specification

**Status:** Implemented, self-reviewed, and tested (36-check behavioral suite green) — deployment pending
**Supersedes:** FlatIDVaultV3 (`0x25ec1e6d07d70427BFA049Cc349079448080568C`, abandoned 2026-08-18) and FlatIDSaveVaultV3 (`0xe1b70B17AEf2dc810C5EA9b73aEA092B7cA1270B`, abandoned 2026-08-18)
**Design drivers:** V3 post-mortem (heartbeat single-point-of-failure → permanent abandonment), FlatID dashboard (three-lane view: Checking / Savings / Investment), sFLAT transparency model (shares stored, FLAT-equivalent displayed).

---

## 1. Overview

One contract, three asset lanes per FlatID account:

| Lane | Token held by vault | Dashboard card | Notes |
|---|---|---|---|
| **FLAT** (Checking) | FLAT | Spend — "Safe" | Stable unit of account, $1.0197 CPI oracle |
| **sFLAT** (Savings) | sFLAT shares (ERC-4626) | Save — "Factor 1.18×" ticker | Yield accrues on-chain; display = `convertToAssets` |
| **SAVE** (Investment) | SAVE | Invest — "Market risk" | Protocol equity, market-priced |

Key properties:

- **Single contract, per-lane accounting.** Each lane has independent user balances, principal tracking, operator caps, and solvency invariants.
- **The vault holds real tokens**, including actual sFLAT shares — backing exists on-chain, not as a ledger promise.
- **Liveness by redundancy:** heartbeat callable by admin, operator, or Safe guardian.
- **Abandonment is survivable:** users withdraw forever; Safe can recover surplus (30-day timelock) and revive once (7-day timelock).
- **Hygiene (self-review hardening):** seeding is frozen while abandoned; `sweepForeign` recovers stray non-lane tokens; `setSflatVault` requires zero outstanding sFLAT claims.
- **No fiat on-chain.** Local-currency display is a pure presentation-layer multiplication over token balances (see §9).

---

## 2. Roles

| Role | Holder | Powers |
|---|---|---|
| **Guardian (Safe)** | Protocol Safe multisig | Pause/unpause, `recoverSurplus`, `sweepForeign`, `queueRevive`/`revive` |
| **Admin** | Backend admin key (existing FlatID service account) | `heartbeat()`, configuration, seed finalization, lane ops |
| **Operator** | Relayer `0x959886194B5F42891A804be614Eb0e6dBBaBbea2` | `heartbeat()`, `settleTransfer`, capped withdrawals settlement |
| **User** | Any EOA with a credited balance | `emergencyWithdraw(token)` — permissionless, eternal |

All state-changing configuration follows the existing doctrine: bounded unsigned plans, no bundled gated actions, stop-and-report on failure, Etherscan Exact Match verification after deploy.

---

## 3. State (per lane)

For each token `t ∈ {FLAT, sFLAT, SAVE}`:

```solidity
mapping(address account => uint256) userBalances[t];      // current claim
mapping(address account => uint256) principalOf[t];       // deposited principal (anti-mixing)
uint256 totalUserBalances[t];                             // solvency denominator

// Operator caps (per-lane, V3 structure retained)
uint256 dailyWithdrawLimit[t];
uint256 dailySettlePrincipalLimit[t];
```

Global:

```solidity
uint256 public lastHeartbeat;
uint256 public constant HEARTBEAT_INTERVAL = 60 days;     // settable (decrease-only) by admin
uint256 public constant RECOVERY_TIMELOCK   = 30 days;    // after abandonment
uint256 public constant REVIVE_TIMELOCK     = 7 days;
bool    public seedingComplete;
bool    public revived;        // one-time revive spent
uint256 public reviveEta;
```

### Solvency invariant (per lane, checked after every mutating op)

```
token.balanceOf(vault) >= totalUserBalances[t]            // FLAT, SAVE lanes
sflatVault.balanceOf(vault) >= totalUserBalances[sFLAT]   // sFLAT lane, in shares
```

---

## 4. Heartbeat (the V3 fix)

```solidity
function heartbeat() external {
    require(msg.sender == admin || msg.sender == operator || msg.sender == guardian, "!heartbeat-caller");
    require(!isAbandoned(), "abandoned");
    lastHeartbeat = block.timestamp;
    emit Heartbeat(msg.sender, block.timestamp);
}
```

- **Three independent callers** — abandonment now requires *everyone* to walk away, which is exactly when the abandoned-state protections should engage.
- Backend monitoring alerts at **T-14, T-7, T-1 days** to admin + operator channels (off-chain; part of deployment checklist).
- Abandonment start is derived: `abandonmentStart() = lastHeartbeat + heartbeatInterval` (no latching needed).

---

## 5. Abandoned-state behavior

| Function | Normal | Abandoned |
|---|---|---|
| `emergencyWithdraw(token)` | ❌ | ✅ — permissionless, eternal |
| `heartbeat()` | ✅ | ❌ reverts (unless revived) |
| `settleTransfer` / operator ops | ✅ | ❌ |
| `seedBalances` / `finalizeSeed` | ✅ | ❌ — no new claims can be born into an abandoned vault; revive first |
| `recoverSurplus(token)` | ❌ | ✅ after `abandonmentStart + 30 days`, guardian only |
| `sweepForeign(token)` | ✅ non-lane only | ✅ non-lane only — can never touch a lane token |
| `queueRevive()` → `revive()` | ❌ | ✅ guardian only, 7-day timelock, one-time |

`emergencyWithdraw(token)` pays `min(balance, principal, available)` and reads only on-chain state — a user can always exit with up to their principal even if the entire FlatCash stack is gone.

`recoverSurplus(token)` pays the guardian `balance − totalUserBalances` — user claims are structurally untouchable.

Rationale for revive: accidental key/infra loss shouldn't permanently strand user funds behind per-user withdrawals. One chance, a week of public visibility, never repeatable. A second abandonment is final.

---

## 6. Seed migration (honoring legacy claims)

Legacy real-user claims being honored:

| Source vault | Token | Amount | Notes |
|---|---|---|---|
| FlatIDSaveVaultV3 `0xe1b7…270B` | SAVE | **1,188.62 SAVE** | All user funds |
| V2.9-era FLAT vault `0xaca8…f59a` | FLAT | **49.03 FLAT** | All user funds |
| FlatIDVaultV3 `0x25ec…568C` | FLAT | ~~104.57 FLAT~~ | **Excluded** — test claims, confirmed by owner |

- `seedBalances(token, users[], amounts[])` — admin only, pre-finalize, frozen while abandoned, one `BalanceSeeded` event per account so anyone can reconcile the migration against the legacy vault states on Etherscan.
- `finalizeSeed()` reverts unless the vault actually holds the seeded tokens for every lane with claims. After sealing, `seedBalances` is dead forever.
- Funding plan: Safe transfers 49.03 FLAT + 1,188.62 SAVE to V4 before `finalizeSeed`. The legacy vaults' tokens stay locked forever; the seed is funded from Safe's existing holdings (economically neutral — the locked tokens are already excluded from circulation).

---

## 7. Normal operations

### 7.1 Deposits (crediting)

Unchanged from the working V3 model: users send tokens to their system-generated receive wallet; the backend verifies the on-chain transfer and operator/admin credits via `recordDeposit(token, user, amount)` (solvency-checked, principal-building). This flow survived V3 without incident and is retained.

### 7.2 Transfers between FlatIDs

`settleTransfer(token, from, to, amount)` moves balance AND principal (`principalMoved = min(amount, principalOf[from])`), conserving total principal. Operator subject to the lane's `dailySettlePrincipalLimit`; admin exempt. Batch variant is atomic.

### 7.3 Withdrawals to external wallets

User requests in app → backend queue → operator settles on-chain within the lane's daily withdrawal cap → vault transfers the token to the user's external address, debiting balance + principal.

### 7.4 Lane conversions (FLAT ↔ sFLAT)

- `convertFlatToSflat(user, flatAmount, minSharesOut)` — debits the FLAT lane, deposits into the live sFLAT ERC-4626, credits the REAL shares received (principal fully backed). Atomic; lane solvency holds throughout.
- `convertSflatToFlat(user, shareAmount, minFlatOut)` — redeems at the then-current factor; the user always receives ≥ the displayed ticker value (the sFLAT rate ratchets upward only).
- FLAT ↔ SAVE conversions go through the live market route (SAVESale / pool) with backend coordination — no on-chain conversion function, so no hard-coded market math in the vault.
- `setSflatVault(newVault)` (admin) is guarded: it reverts while any sFLAT claims are outstanding, so a lane-key switch can never orphan user shares.

---

## 8. Operator caps (per-lane)

V3's caps never failed; V4 keeps the structure and splits per lane:

```solidity
lanes[FLAT].dailyWithdrawLimit / dailySettlePrincipalLimit
lanes[sFLAT].dailyWithdrawLimit / dailySettlePrincipalLimit
lanes[SAVE].dailyWithdrawLimit / dailySettlePrincipalLimit
```

- Settable by admin only; 0 == unlimited (default). Operator-only; admin exempt.
- Rollover at UTC day boundary, as V3.
- A busy savings day cannot starve checking settlements.

---

## 9. Backend / dashboard surface (what V4 must serve)

The dashboard mock ("The Ledger" reference) requires:

```
GET /flatid/balances →
{
  flat:  { balanceFlat },
  sflat: { shares, flatEquivalent, factor, ratePerSecondFlat,
           earningSince, earnedSoFarFlat },   // ticker anchors
  save:  { balanceSave, usdPrice, change24h },
  quotesAt: <block timestamp>
}
```

- **sFLAT ticker:** backend anchors every 30–60s (`convertToAssets(shares)`, `streamPerSecond`); client interpolates `anchor + Δt × rate` between anchors. Payout ≥ display, always.
- **Fiat conversion:** display-only. `displayFiat = tokenAmount × tokenUSD × (USD→fiat FX)`. FLAT/USD from CPI oracle ($1.0197); sFLAT/USD = factor × FLAT/USD; SAVE/USD = market (SAVE/ETH pool × Chainlink ETH/USD). FX via `shared/currencies.ts` (~160 currencies; Frankfurter/ECB for majors, labeled fallback rates for the long tail).
- **Paused-rate honesty:** if the sFLAT stream is paused or a rate change is pending, the ticker freezes and displays "Rate update pending" — never animate a number the vault won't honor.

---

## 10. Events (audit surface)

`Heartbeat(caller, timestamp)`, `BalanceSeeded(token, user, amount)`, `SeedingCompleted()`, `SettleTransfer(token, from, to, amount, principalMoved)`, `Withdrawal(token, to, amount, calledBy)`, `Converted(user, fromToken, toToken, fromAmount, toAmount)`, `EmergencyWithdrawal(token, user, amount)`, `SurplusRecovered(token, amount)`, `ForeignSwept(token, amount)`, `ReviveQueued(eta)`, `Revived(by, timestamp)`, `LaneWithdrawLimitChanged`, `LaneSettlePrincipalLimitChanged`, `Paused/Unpaused`, `SflatVaultChanged`.

---

## 11. Test evidence (behavioral suite — green)

Verified on a local EVM against solc-0.8.24-compiled bytecode (36 checks), with the deployed source verified byte-identical to the tested build (git blob SHA `eaf8f4ebe04cbe3dd3fd47ae03723f2ece6fb8ef`):

1. Heartbeat authorization matrix (admin ✅ / operator ✅ / guardian ✅ / rando ❌ / post-abandonment ❌ for all callers).
2. Deposit solvency: cannot credit beyond vault holdings; unknown lane rejected.
3. Per-lane caps: operator settle cap enforced per lane; admin exempt; exhausting the FLAT cap does not block sFLAT or SAVE settlements.
4. sFLAT round-trip: deposit shares → yield accrues → redeem ≥ displayed preview; FLAT out > FLAT in (yield captured); lane solvency holds after conversion.
5. Seed: `finalizeSeed` reverts if any lane underfunded; `seedBalances` dead after finalize.
6. Abandonment: `emergencyWithdraw` pays `min(balance, principal)` per lane; `recoverSurplus` reverts before the 30-day timelock, rejects non-guardian, pays exactly `balance − claims`, and leaves user claims withdrawable afterwards.
7. Revive: queue + 7-day timelock enforced; clears abandonment; one-time only (second `queueRevive` reverts).
8. Pause: guardian pause/unpause with bounded expiry; settle/convert blocked while paused; 7-day re-pause cooldown enforced.
9. Self-review fixes: `seedBalances`/`finalizeSeed` revert while abandoned; `sweepForeign` rejects lane tokens and non-guardian callers, and recovers stray tokens even while abandoned; `setSflatVault` reverts with outstanding claims and succeeds once cleared.

Foundry mirror suite: `test/FlatIDVaultV4.t.sol` (self-contained, no forge-std dependency).

---

## 12. Deployment checklist (doctrine-compliant)

1. Bounded unsigned plan → deploy via Relayer (`0x959886194B5F42891A804be614Eb0e6dBBaBbea2`).
2. Etherscan Exact Match verify (Solidity 0.8.24, optimizer 200 runs). Stop-and-report on any mismatch.
3. Admin transactions (Ledger cold wallet `0xdDf4…36bC`, one per action, never bundled): set per-lane caps if desired (defaults are unlimited).
4. Safe (guardian) funding txs: transfer 49.03 FLAT + 1,188.62 SAVE to V4.
5. Admin `seedBalances` batches → verify `BalanceSeeded` events → `finalizeSeed`.
6. Backend cutover: `flatid-account.ts` / `flatid-savings.ts` / `admin-vault.ts` point to V4; heartbeat monitors armed (T-14/T-7/T-1).
7. `DEPLOYMENTS.md` updated: V4 row → Live with address; V3 rows remain Abandoned (historical).
