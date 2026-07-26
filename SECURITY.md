# Security

## Audit Status

These contracts have **not** been audited by an independent security firm. They are verified on Etherscan and have been reviewed by AI (Grok, Claude) but this does not constitute a formal audit.

## Reporting Vulnerabilities

If you discover a security vulnerability, please report it responsibly:

- **Email:** team@flat.cash
- **Subject:** `[SECURITY] Brief description`

Do NOT open a public GitHub issue for security vulnerabilities.

## Security Model

### Immutable Contracts (FLAT, RISE, SAVE)

These contracts have zero admin surface. No one can:
- Mint new tokens
- Burn other users' tokens
- Pause transfers
- Blacklist addresses
- Upgrade the contract

### Guardian Pattern (BearerSwapV4, SAVESale v3)

- Guardian (Gnosis Safe multisig) can pause **new deposits only**
- Withdrawals and reclaims are **NEVER pausable** — users can always exit
- Guardian expires after 3 years — contract becomes fully immutable
- No proxy, no upgrade path

### Admin-Controlled Vaults (FlatIDVaultV3, FlatIDSaveVaultV3)

Custodial by design — the admin has full control. This is intentional for the FlatID account system. Security defenses:

1. **Heartbeat dead-man's switch**: Admin must ping every 30 days. If missed, users can emergency-withdraw their principal.
2. **Bounded pause**: Maximum 7 days, with 7-day cooldown between pauses.
3. **Emergency withdrawal**: Users can always withdraw up to their `principalOf` amount if the heartbeat expires.
4. **Operator daily cap**: Limits how much principal a compromised operator can redistribute per day.
5. **Solvency invariant**: Contract always holds ≥ sum of all user balances.

### FlatSale V4

- Ownable2Step (two-step transfer, renounce disabled)
- CPI rate verified on-chain (12% annual circuit breaker)
- Daily purchase cap (1000 FLAT)
- Chainlink staleness check
- ReentrancyGuard

## Known Limitations

1. No formal third-party audit
2. BearerSwapV4 guardian period is 3 years (expires ~July 2029)
3. FlatID vaults are custodial — trust in the admin is required
4. FlatSale V4 relies on Chainlink ETH/USD feed availability
