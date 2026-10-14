// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title FlatIDVaultV4
 * @notice Multi-asset custodial vault for FlatID accounts. ONE contract, THREE lanes:
 *         FLAT (Checking), sFLAT shares (Savings), SAVE (Investment).
 *
 * @dev V4 supersedes FlatIDVaultV3 + FlatIDSaveVaultV3 (both abandoned 2026-08-18 when the
 *      single off-chain heartbeat process stopped and no other key could call heartbeat()).
 *
 *      V4.1 revision — incorporates two independent adversarial reviews (Grok, Claude).
 *      Changes vs the original V4:
 *      A. HEARTBEAT IS A SIDE EFFECT — every successful admin/operator state-changing call
 *         refreshes lastHeartbeat, so liveness no longer depends on one dedicated process.
 *         heartbeat() is restricted to admin/operator: a guardian heartbeat could mask a
 *         dead backend and freeze users out of the abandoned-state exit. The guardian's
 *         tools are pause() / revokeOperator(); revive() covers accidental abandonment.
 *      B. OPERATOR LEDGER BUDGET — a compromised operator previously could rewrite the
 *         ledger with uncapped decreaseBalance/recordDeposit and drain after abandonment.
 *         All ledger mutations (recordDeposit, increaseBalance, decreaseBalance,
 *         settleTransfer) now charge a per-lane daily budget counted in AMOUNT.
 *      C. EMERGENCY EXIT PAYS FULL BALANCE (PHASE 2) — after abandonment +
 *         RECOVERY_TIMELOCK, emergencyWithdraw pays the user's FULL balance, not just
 *         principal. Non-principal balances (rewards etc.) are no longer stranded forever.
 *      D. CLAIM ADDRESSES — FlatID users do not hold their ledger keys. A user can register
 *         (via the authenticated backend) an emergencyClaimAddress; after abandonment,
 *         anyone can call emergencyWithdrawTo(token, user) and funds go ONLY to that
 *         registered address. This makes the dead-man's switch usable for keyless users.
 *      E. PAUSE FIXES — pause() reverts while already paused (guardian can no longer extend
 *         a pause indefinitely); recordDeposit/increaseBalance are pause-gated.
 *      F. CAPS AT BIRTH — withdraw limits and ledger budgets are constructor arguments,
 *         per lane; 0 means ZERO allowance (never "unlimited"); caps carry across
 *         setSflatVault.
 *      G. HARDENING — two-step setAdmin; distinct-role checks; guardian revokeOperator();
 *         setHeartbeatInterval cannot trigger instant abandonment; max heartbeat interval;
 *         sFLAT vault validation (code, asset() == FLAT, distinct lanes); code-length check
 *         in the call wrapper; convertSflatToFlat credits the MEASURED FLAT delta;
 *         proportional principal through conversions; principal clamped to balance in
 *         decreaseBalance; finalizeSeed requires exact expected lane totals; inline
 *         solvency check in seedBalances; FLAT allowance reset to 0 after sFLAT deposits;
 *         nonReentrant on every state-changing function; PrincipalChanged event and
 *         uniform balance events so the backend can rebuild ALL state from logs.
 *
 *      V4.2 revision — confirmation round (Claude 6/10, Grok 7/10; both DEPLOY WITH FIXES).
 *      Both reviewers independently found the same High: the V4.1 claim-address setter was
 *      an uncapped, un-pause-gated operator write that could redirect the WHOLE vault after
 *      abandonment. Claude found a second High: the self-exit paid msg.sender, so stolen
 *      server-side ledger keys beat registered claim addresses. V4.2 changes:
 *      H. CLAIM-ADDRESS AGING — a claim address is honored only if it was set at least
 *         CLAIM_ADDRESS_DELAY (30 days) BEFORE abandonment began; otherwise the previous
 *         matured address is used. A redirect therefore requires keeping the vault alive
 *         for 30 days with the change visible on-chain — during which the guardian can
 *         revokeOperator() and clearEmergencyClaimAddress(). Setter is pause-gated and
 *         rejects the vault itself and the sFLAT vault as destinations.
 *      I. SELF-EXIT ROUTES TO THE CLAIM ADDRESS — emergencyWithdraw pays the matured
 *         claim address when one exists; stolen ledger keys alone no longer suffice.
 *      J. ROUND-2 LOWS — measured share delta in convertFlatToSflat (mirrors the L-5
 *         redeem fix) and assets > 0 on redeem; unpause() requires an active pause;
 *         acceptAdmin re-checks distinct roles and proposals expire after 30 days;
 *         constructor emits cap/role events and checks token code; _touch() emits
 *         Heartbeat so lastHeartbeat is rebuildable from logs alone.
 *
 *      V4.3 revision — second confirmation round (Claude 7/10, Grok 8/10; both DEPLOY
 *      WITH FIXES). Both reviewers converged on one real bug: the guardian's remedy
 *      clearEmergencyClaimAddress deleted the user's matured fallback along with the
 *      attacker's fresh address — reopening the stolen-ledger-key exit it was meant
 *      to close. Claude added: the self-exit still paid the ledger key for registered
 *      users whose first address had not matured, and claim-address writes were
 *      uncapped while the guardian's remedy worked one user at a time. V4.3 changes:
 *      K. ROLLBACK, NOT DELETE — rollbackClaimAddresses(users) (batch; admin, or the
 *         guardian at ANY time including abandoned/paused) restores each user's last
 *         MATURED address as current with setAt = 0 (always matured) and clears
 *         previous. The guardian can now only move a user BACK to an address that
 *         user already held for 30+ days — never to nothing, never to a new address.
 *         Full deletion (clearEmergencyClaimAddress) is admin-only, while live.
 *      L. SELF-EXIT FALLBACK TIGHTENED — emergencyWithdraw falls back to msg.sender
 *         only for users who NEVER had a claim record. A registered user whose
 *         address has not matured reverts: stranded, not stolen.
 *      M. CLAIM-WRITE RATE LIMIT — the operator can set at most dailyClaimWriteLimit
 *         claim addresses per UTC day (0 = none; admin exempt). A mass redirect is
 *         now slow and loud, and the batch rollback keeps the guardian's response
 *         cheap (O(users) in ONE Safe transaction).
 *      N. ROUND-3 LOWS — unpause() advances an expired pause first (the re-pause
 *         cooldown is measured from the true expiry, not from a late unpause); claim
 *         addresses reject ALL lane tokens, not just the vaults; revive() emits
 *         Heartbeat so liveness stays rebuildable from logs; the constructor requires
 *         heartbeatInterval < CLAIM_ADDRESS_DELAY, so a set-and-stop redirect can
 *         NEVER mature before abandonment begins — any honored redirect spent at
 *         least 30 days visible on-chain, and at least (CLAIM_ADDRESS_DELAY -
 *         heartbeatInterval) of those with the vault verifiably alive.
 *
 *      V4.4 revision — third confirmation round (Claude 8/10 DEPLOY WITH FIXES,
 *      Grok 9/10 DEPLOY). Claude found that revive() — guardian-only, with no admin
 *      or operator present — resets the clock claim maturity is measured against, so
 *      the documented "revive rescues stranded users" remedy would also have matured
 *      attacker redirects the first abandonment had correctly ignored. Claude also
 *      found the guardian had NO remedy for records without a matured fallback (one
 *      operator write permanently strands a key-holding seeded user). Grok found the
 *      live-rollback inversion: a compromised operator can front-run a guardian
 *      rollback with one more write and promote the attacker address to `previous`.
 *      V4.4 changes:
 *      O. MATURITY FOLLOWS ADMIN/OPERATOR LIVENESS — claimTarget measures against
 *         lastLiveHeartbeat + heartbeatInterval, where lastLiveHeartbeat is set by
 *         the constructor, _touch(), heartbeat() and acceptAdmin() but NEVER by
 *         revive(). A guardian-only revive can no longer mature any claim address;
 *         a returning admin's first action re-arms the clock. First abandonment is
 *         unchanged (the two clocks are equal until a revive).
 *      P. GUARDIAN VOID — voidClaimAddresses(users) (batch; guardian any time, admin
 *         while live) neutralizes records that have NO matured fallback: current is
 *         zeroed and a sticky `voided` flag blocks both exits and any further writes
 *         to the record. Only an admin clear (live vault) lifts it. Voided-over-
 *         stolen: the user is stranded until the admin returns, but the attacker
 *         address can never be honored.
 *      Q. ROLLBACK WINDOW + INCIDENT MODE — rollback requires the current address to
 *         be younger than 2 * CLAIM_ADDRESS_DELAY (measured against abandonmentStart()
 *         once abandoned), so the guardian keeps a 30-day remedy after a redirect
 *         matures but can never send a user back to a wallet abandoned 60+ days ago.
 *         While the vault is LIVE, guardian rollback and void require operator ==
 *         address(0): revoke the compromised key first (same Safe batch), so no
 *         front-run can promote the attacker address to `previous` before the remedy
 *         lands.
 *      R. EmergencyClaimAddressSet now carries the caller, so claimWritesToday and
 *         admin/operator write attribution are rebuildable from logs alone.
 *
 *      V4.5 revision — independent third review of V4.3 (ChatGPT: 7/10, DEPLOY WITH
 *      FIXES; verified the blob hash and reproduced the 21,764-byte V4.3 build with
 *      solc 0.8.28 / via-IR / 200 runs). It converged on the revive-aging finding
 *      (its M1 = O) and the rollback-window finding (its M2 = Q), but its M1 fix
 *      recommendation explicitly required the SETTER's promotion rule to share the
 *      withdrawal-side maturity reference — which V4.4 had left on wall-clock. It
 *      also found one gap the other two reviewers missed. V4.5 changes:
 *      S. SHARED MATURITY REFERENCE — the claim setter's promotion of `current` to
 *         `previous` now uses the same lastLiveHeartbeat-based reference as
 *         claimTarget (new internal helper _claimMaturityRef). Without it, a
 *         guardian-only revive followed by one more operator write could
 *         wall-clock-promote a never-matured attacker address to `previous`,
 *         re-opening M1 through the promotion path. Invariant: `previous` is
 *         always an address claimTarget would honor.
 *      T. CONVERSIONS CHARGE LANE BUDGETS — convertFlatToSflat / convertSflatToFlat
 *         are operator ledger mutations but charged no budget, so a compromised
 *         operator could force-convert every user's full balance (protocol-wide
 *         yield stripping, rounding dust) even with both budgets at zero. Both
 *         sides of a conversion now charge their lane's budget (admin exempt):
 *         the source amount up front, the measured destination amount after the
 *         external call.
 *
 *      V4.6 revision — round-5 review of V4.5 (Claude). Changes:
 *      U. PROMOTION REFERENCE = min(block.timestamp, live-clock projection). V4.5's shared
 *         reference promoted addresses only (CLAIM_ADDRESS_DELAY - heartbeatInterval) old
 *         while live, so a compromised operator could erase a user's matured fallback in
 *         as little as one day (heartbeatInterval = 29d), leaving rollback (restores the
 *         attacker) and void (refused: previous != 0) both useless. Regression vs V4.3.
 *      V. VOID WINDOW — void is bounded like rollback (current younger than 60 days vs
 *         abandonmentStart once abandoned): the guardian can no longer strand a user's
 *         settled single registration or a post-rollback record.
 *      W. VOID COVERS HOSTILE `previous` — void may now neutralize records with a fallback
 *         (zeroing both addresses), so a slow-matured redirect is stranded, never paid.
 *      X. REVIVE REQUIRES A REVOKED OPERATOR — after a revive only the admin can act.
 *
 *      CUSTODIAL BY DESIGN: the admin (Ledger cold wallet) has full control. That is
 *      intentional and is not a vulnerability. The security model defends against a
 *      compromised OPERATOR, and against admin/operator disappearance.
 *
 *      KNOWN ACCEPTED TRADE-OFFS (documented, not bugs — confirmed by both reviewers):
 *      - Daily caps reset on UTC-day boundaries: up to 2x the cap can move within two
 *        blocks around midnight. Caps must also be sized for cross-lane exposure:
 *        FLAT value can leave through BOTH the FLAT and sFLAT lane caps the same day.
 *      - batchSettleTransfer is all-or-nothing: one stale entry reverts the batch. The
 *        backend pre-validates batches and splits on failure.
 *      - Emergency withdrawal is first-come-first-served if a lane is underfunded (which
 *        can only happen via a seeding mistake; an external sFLAT loss reduces share VALUE
 *        pro-rata but cannot underfund the share-denominated lane itself).
 *      - finalizeSeed's exact-total check is meaningful only if run BEFORE live deposits
 *        begin (lane totals include live balances afterwards). Runbook requirement.
 *      - A user's FIRST claim-address registration takes CLAIM_ADDRESS_DELAY to mature;
 *        registration at onboarding makes this a non-issue (operational requirement).
 *        If the vault is abandoned within those first 30 days, that user is STRANDED,
 *        not stolen from: both exits revert. A revive reopens normal operation (the
 *        address then matures against the renewed admin/operator heartbeat); if no
 *        admin or operator ever returns, the stranding is permanent. Deliberate
 *        (rounds 3-4): stranded-over-stolen. There is NO phase-3 honoring of immature
 *        addresses — deferred by both round-4 reviewers.
 *      - A voided claim record is frozen until the admin clears it (live vault); the
 *        guardian cannot delete records, and a voided user stays stranded, not stolen,
 *        in the meantime.
 *      - Rollback cannot touch a record whose current address is 60+ days old
 *        (measured against abandonmentStart once abandoned): by then it is treated as
 *        the user's settled choice. Guardian tooling must still check that a record's
 *        `previous` was not written by the operator after the compromise before
 *        batching a rollback (round-4 N-3 residual).
 *      - Guardian remedies while LIVE require a dead operator (operator == 0):
 *        revokeOperator() in the same Safe batch first. While abandoned this is
 *        unnecessary (the setter is frozen) and not required.
 *      - Conversions charge both lane budgets (V4.5): the per-lane daily budgets
 *        must be sized to include expected conversion volume, or legitimate
 *        conversions revert until the next UTC day or an admin budget raise.
 *        Admin is exempt.
 *      - An expired pendingAdmin keeps blocking that address from being appointed
 *        operator or guardian until cancelAdminHandover. Harmless housekeeping.
 *      - claimTarget() viewed WHILE LIVE measures maturity against the PROJECTED
 *        abandonment start; front-ends should display setAt + CLAIM_ADDRESS_DELAY
 *        as the maturity date instead.
 *      - A user who switches away from a compromised wallet keeps the OLD wallet
 *        honored as `previous` for up to CLAIM_ADDRESS_DELAY. Users must be told
 *        (docs/UI), and the guardian can roll back to it if the switch was hostile
 *        (within the 2x CLAIM_ADDRESS_DELAY rollback window).
 */

// Minimal IERC20 interface
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

// Minimal ERC-4626 subset for the sFLAT vault
interface IERC4626 {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
}

// Minimal SafeERC20 via low-level call
library Address {
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
        require(target.code.length > 0, "Address: call to non-contract");
        (bool success, bytes memory returndata) = target.call(data);
        require(success, "Address: low-level call failed");
        if (returndata.length > 0) {
            require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
        }
        return returndata;
    }
}

contract FlatIDVaultV4 {
    // ═══════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════

    uint256 public constant MIN_HEARTBEAT_INTERVAL = 7 days;
    uint256 public constant MAX_HEARTBEAT_INTERVAL = 365 days; // a typo must not disable the dead-man's switch
    uint256 public constant MAX_PAUSE_DURATION_CAP = 30 days;
    uint256 public constant REPAUSE_COOLDOWN = 7 days;
    uint256 public constant MAX_BATCH = 200;
    uint256 public constant RECOVERY_TIMELOCK = 30 days; // after abandonment, before recoverSurplus / phase-2 exit
    uint256 public constant REVIVE_TIMELOCK = 7 days;    // public delay on the one-time revive
    uint256 public constant CLAIM_ADDRESS_DELAY = 30 days; // a claim address must be this old (vs abandonment start) to be honored
    uint256 public constant PENDING_ADMIN_TTL = 30 days; // admin handover proposals expire

    // ═══════════════════════════════════════════════════════════════════
    // STATE VARIABLES
    // ═══════════════════════════════════════════════════════════════════

    address public admin;
    address public pendingAdmin; // two-step admin handover
    uint256 public pendingAdminEta; // proposal expires at this timestamp
    address public operator;
    address public guardian; // protocol Safe multisig

    address public immutable flatToken;
    address public immutable saveToken;
    address public sflatVault; // ERC-4626; the sFLAT LANE token is the share token (== sflatVault)

    bool public paused;
    uint256 public pauseExpiresAt;
    uint256 public maxPauseDuration;
    uint256 public lastPauseExpiredAt;

    uint256 public lastHeartbeat;
    uint256 public lastLiveHeartbeat; // set by admin/operator liveness only; revive() never touches it (claim-aging clock)
    uint256 public heartbeatInterval;

    bool public seedingComplete;

    bool public revived;       // one-time revive spent
    uint256 public reviveEta;  // set by queueRevive()

    uint256 public dailyClaimWriteLimit; // operator cap on claim-address writes per UTC day (0 = none; admin exempt)
    uint256 public lastClaimWriteResetDay;
    uint256 public claimWritesToday;

    uint256 private _reentrancyLock; // 1 == unlocked, 2 == locked

    struct Lane {
        uint256 totalUserBalances;     // solvency denominator for this token
        uint256 dailyWithdrawLimit;    // operator daily withdrawal cap (0 == operator cannot withdraw; admin exempt)
        uint256 lastWithdrawResetDay;
        uint256 withdrawnToday;
        uint256 dailyLedgerBudget;     // operator daily ledger-mutation budget in amount (0 == none; admin exempt)
        uint256 lastLedgerResetDay;
        uint256 ledgerSpentToday;
    }

    /// @dev Constructor bundle — one stack slot, keeps the constructor within EVM limits.
    ///      withdrawLimits / ledgerBudgets order: [FLAT, SAVE, sFLAT].
    struct DeployConfig {
        address flatToken;
        address saveToken;
        address sflatVault;
        address admin;
        address operator;
        address guardian;
        uint256 heartbeatInterval;
        uint256 maxPauseDuration;
        uint256 dailyClaimWriteLimit;
        uint256[3] withdrawLimits;
        uint256[3] ledgerBudgets;
    }

    mapping(address => Lane) public lanes;                        // token => lane
    mapping(address => mapping(address => uint256)) public userBalances; // token => user => balance
    mapping(address => mapping(address => uint256)) public principalOf;  // token => user => principal

    /// @notice Self-custody destination for abandoned-vault exits, with AGING: an address is
    ///         honored only if set at least CLAIM_ADDRESS_DELAY before abandonment began;
    ///         otherwise the previous matured address is used. Set by the backend on an
    ///         authenticated FlatID request. Setting it is NOT a spend — funds only go TO it.
    struct Claim {
        address current;   // most recently set address
        address previous;  // last MATURED address (fallback if current is too new)
        uint64 setAt;      // when current was set
        bool voided;       // guardian-voided (sticky; blocks writes and both exits; an admin clear lifts it)
    }
    mapping(address => Claim) public emergencyClaims; // ledger user => claim record

    // ═══════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════

    event AdminChangeProposed(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);
    event OperatorChanged(address indexed oldOperator, address indexed newOperator);
    event OperatorRevoked(address indexed oldOperator, address indexed byGuardian);
    event GuardianChanged(address indexed oldGuardian, address indexed newGuardian);
    event SflatVaultChanged(address indexed oldVault, address indexed newVault);
    event Heartbeat(address indexed caller, uint256 timestamp);
    event HeartbeatIntervalChanged(uint256 oldInterval, uint256 newInterval);
    event Paused(address indexed by, uint256 expiresAt);
    event Unpaused(address indexed by);
    event MaxPauseDurationChanged(uint256 oldDuration, uint256 newDuration);

    event LaneWithdrawLimitChanged(address indexed token, uint256 oldLimit, uint256 newLimit);
    event LaneLedgerBudgetChanged(address indexed token, uint256 oldBudget, uint256 newBudget);

    event Deposit(address indexed token, address indexed user, uint256 amount);
    event BalanceIncreased(address indexed token, address indexed user, uint256 amount, uint256 newBalance);
    event BalanceDecreased(address indexed token, address indexed user, uint256 amount, uint256 newBalance);
    event PrincipalChanged(address indexed token, address indexed user, uint256 newPrincipal);
    event Withdrawal(address indexed token, address indexed to, uint256 amount, address indexed calledBy);
    event SettleTransfer(address indexed token, address indexed from, address indexed to, uint256 amount, uint256 principalMoved);
    event Converted(address indexed user, address indexed fromToken, address indexed toToken, uint256 fromAmount, uint256 toAmount);

    event EmergencyClaimAddressSet(address indexed user, address indexed claimAddress, address previousAddress, address indexed by);
    event EmergencyClaimAddressRolledBack(address indexed user, address indexed restoredAddress, address indexed by);
    event EmergencyClaimAddressVoided(address indexed user, address indexed voidedAddress, address previousAddress, address indexed by);
    event EmergencyClaimAddressCleared(address indexed user, address indexed clearedBy);
    event ClaimWriteLimitChanged(uint256 oldLimit, uint256 newLimit);
    event EmergencyWithdrawal(address indexed token, address indexed user, uint256 amount, address indexed to);
    event BalanceSeeded(address indexed token, address indexed user, uint256 amount);
    event SeedingCompleted();
    event SurplusRecovered(address indexed token, uint256 amount);
    event ForeignSwept(address indexed token, uint256 amount);
    event ReviveQueued(uint256 eta);
    event Revived(address indexed by, uint256 timestamp);

    // ═══════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    modifier onlyOperatorOrAdmin() {
        require(msg.sender == operator || msg.sender == admin, "Not operator or admin");
        _;
    }

    modifier onlyGuardian() {
        require(msg.sender == guardian, "Not guardian");
        _;
    }

    modifier whenNotPaused() {
        require(!_isEffectivelyPaused(), "Paused");
        _;
    }

    modifier whenNotAbandoned() {
        require(!isAbandoned(), "Vault is abandoned, all operations frozen");
        _;
    }

    modifier nonReentrant() {
        require(_reentrancyLock == 1, "Reentrancy");
        _reentrancyLock = 2;
        _;
        _reentrancyLock = 1;
    }

    // ═══════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════

    constructor(DeployConfig memory cfg) {
        require(cfg.flatToken != address(0), "Invalid FLAT token");
        require(cfg.saveToken != address(0), "Invalid SAVE token");
        require(cfg.sflatVault != address(0), "Invalid sFLAT vault");
        require(
            cfg.flatToken != cfg.saveToken && cfg.flatToken != cfg.sflatVault && cfg.saveToken != cfg.sflatVault,
            "Lane tokens must be distinct"
        );
        require(cfg.sflatVault.code.length > 0, "sFLAT vault has no code");
        require(cfg.flatToken.code.length > 0, "FLAT token has no code");
        require(cfg.saveToken.code.length > 0, "SAVE token has no code");
        require(IERC4626(cfg.sflatVault).asset() == cfg.flatToken, "sFLAT vault asset is not FLAT");
        require(cfg.admin != address(0), "Invalid admin");
        require(cfg.operator != address(0), "Invalid operator");
        require(cfg.guardian != address(0), "Invalid guardian");
        require(
            cfg.admin != cfg.operator && cfg.admin != cfg.guardian && cfg.operator != cfg.guardian,
            "Roles must be distinct"
        );
        require(cfg.heartbeatInterval >= MIN_HEARTBEAT_INTERVAL, "Interval below minimum");
        require(cfg.heartbeatInterval <= MAX_HEARTBEAT_INTERVAL, "Interval above maximum");
        // Structural invariant: with interval < CLAIM_ADDRESS_DELAY, a set-and-stop
        // redirect can never mature before abandonment begins (setHeartbeatInterval
        // can only decrease, so this holds for the contract's life).
        require(cfg.heartbeatInterval < CLAIM_ADDRESS_DELAY, "Interval must be below claim delay");
        require(cfg.maxPauseDuration > 0, "Pause duration must be > 0");
        require(cfg.maxPauseDuration <= MAX_PAUSE_DURATION_CAP, "Pause duration exceeds cap");

        flatToken = cfg.flatToken;
        saveToken = cfg.saveToken;
        sflatVault = cfg.sflatVault;
        admin = cfg.admin;
        operator = cfg.operator;
        guardian = cfg.guardian;
        heartbeatInterval = cfg.heartbeatInterval;
        maxPauseDuration = cfg.maxPauseDuration;
        dailyClaimWriteLimit = cfg.dailyClaimWriteLimit;
        lastHeartbeat = block.timestamp;
        lastLiveHeartbeat = block.timestamp;
        paused = false;
        seedingComplete = false;
        revived = false;
        reviveEta = 0;
        _reentrancyLock = 1;

        emit AdminChanged(address(0), cfg.admin);
        emit OperatorChanged(address(0), cfg.operator);
        emit GuardianChanged(address(0), cfg.guardian);
        emit Heartbeat(address(0), block.timestamp);
        emit ClaimWriteLimitChanged(0, cfg.dailyClaimWriteLimit);

        _initLanes(
            cfg.flatToken, cfg.saveToken, cfg.sflatVault,
            cfg.withdrawLimits, cfg.ledgerBudgets
        );
    }

    /// @dev Constructor helper (keeps the constructor within the EVM stack limit).
    ///      Arrays ordered [FLAT, SAVE, sFLAT]. Emits cap events so the birth
    ///      configuration is auditable on Etherscan.
    function _initLanes(
        address flat, address save, address sflat,
        uint256[3] memory withdrawLimits, uint256[3] memory ledgerBudgets
    ) internal {
        lanes[flat].dailyWithdrawLimit = withdrawLimits[0];
        lanes[flat].dailyLedgerBudget = ledgerBudgets[0];
        lanes[save].dailyWithdrawLimit = withdrawLimits[1];
        lanes[save].dailyLedgerBudget = ledgerBudgets[1];
        lanes[sflat].dailyWithdrawLimit = withdrawLimits[2];
        lanes[sflat].dailyLedgerBudget = ledgerBudgets[2];
        emit LaneWithdrawLimitChanged(flat, 0, withdrawLimits[0]);
        emit LaneLedgerBudgetChanged(flat, 0, ledgerBudgets[0]);
        emit LaneWithdrawLimitChanged(save, 0, withdrawLimits[1]);
        emit LaneLedgerBudgetChanged(save, 0, ledgerBudgets[1]);
        emit LaneWithdrawLimitChanged(sflat, 0, withdrawLimits[2]);
        emit LaneLedgerBudgetChanged(sflat, 0, ledgerBudgets[2]);
    }

    // ═══════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════

    function vaultBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function isAbandoned() public view returns (bool) {
        return block.timestamp > lastHeartbeat + heartbeatInterval;
    }

    /// @notice Timestamp at which abandonment began (or will begin). Recovery timelock starts here.
    function abandonmentStart() public view returns (uint256) {
        return lastHeartbeat + heartbeatInterval;
    }

    function timeUntilAbandoned() external view returns (uint256) {
        uint256 deadline = lastHeartbeat + heartbeatInterval;
        if (block.timestamp >= deadline) return 0;
        return deadline - block.timestamp;
    }

    function _isEffectivelyPaused() internal view returns (bool) {
        if (!paused) return false;
        return block.timestamp < pauseExpiresAt;
    }

    function isEffectivelyPaused() external view returns (bool) {
        return _isEffectivelyPaused();
    }

    function getPauseExpiresAt() external view returns (uint256) {
        if (!paused) return 0;
        return pauseExpiresAt;
    }

    /// @notice Remaining withdrawal allowance for the OPERATOR in this lane today.
    /// @dev 0 when the lane cap is 0 (0 means NO allowance, not unlimited). Admin exempt.
    function remainingDailyWithdrawAllowance(address token) public view returns (uint256) {
        Lane storage l = lanes[token];
        if (l.dailyWithdrawLimit == 0) return 0;
        if (block.timestamp / 1 days > l.lastWithdrawResetDay) return l.dailyWithdrawLimit;
        if (l.withdrawnToday >= l.dailyWithdrawLimit) return 0;
        return l.dailyWithdrawLimit - l.withdrawnToday;
    }

    /// @notice Remaining ledger budget for the OPERATOR in this lane today.
    /// @dev 0 when the budget is 0 (0 means NO allowance, not unlimited). Admin exempt.
    function remainingDailyLedgerBudget(address token) public view returns (uint256) {
        Lane storage l = lanes[token];
        if (l.dailyLedgerBudget == 0) return 0;
        if (block.timestamp / 1 days > l.lastLedgerResetDay) return l.dailyLedgerBudget;
        if (l.ledgerSpentToday >= l.dailyLedgerBudget) return 0;
        return l.dailyLedgerBudget - l.ledgerSpentToday;
    }

    // ═══════════════════════════════════════════════════════════════════
    // HEARTBEAT — ADMIN/OPERATOR ONLY, AND A SIDE EFFECT OF EVERY ACTION
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Explicit heartbeat. Callable by admin or operator ONLY — a guardian heartbeat
    ///         could mask a dead backend and deny users the abandoned-state exit. The guardian
    ///         keeps the vault safe with pause()/revokeOperator(); revive() covers accidents.
    ///         In practice this rarely needs calling: every state-changing admin/operator
    ///         action refreshes the heartbeat automatically via _touch().
    function heartbeat() external nonReentrant {
        require(msg.sender == admin || msg.sender == operator, "Not heartbeat caller");
        require(!isAbandoned(), "Vault is abandoned, heartbeat disabled");
        lastHeartbeat = block.timestamp;
        lastLiveHeartbeat = block.timestamp;
        emit Heartbeat(msg.sender, block.timestamp);
    }

    function setHeartbeatInterval(uint256 newInterval) external onlyAdmin whenNotAbandoned nonReentrant {
        require(newInterval >= MIN_HEARTBEAT_INTERVAL, "Below minimum interval");
        require(newInterval <= MAX_HEARTBEAT_INTERVAL, "Above maximum interval");
        require(newInterval < heartbeatInterval, "Can only decrease interval");
        require(
            block.timestamp < lastHeartbeat + newInterval,
            "Would abandon the vault instantly"
        );
        emit HeartbeatIntervalChanged(heartbeatInterval, newInterval);
        heartbeatInterval = newInterval;
        _touch();
    }

    // ═══════════════════════════════════════════════════════════════════
    // OPERATOR/ADMIN LANE OPERATIONS (FROZEN WHEN ABANDONED/PAUSED)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Record a real deposit for a user. Builds principal. Enforces lane solvency.
    ///         Charges the operator's daily ledger budget (admin exempt).
    function recordDeposit(address token, address user, uint256 amount)
        external
        onlyOperatorOrAdmin
        whenNotPaused
        whenNotAbandoned
        nonReentrant
    {
        require(_isLane(token), "Unknown lane");
        require(user != address(0), "Invalid user");
        require(amount > 0, "Zero amount");
        _chargeLedgerBudget(token, amount);
        Lane storage l = lanes[token];
        require(
            l.totalUserBalances + amount <= IERC20(token).balanceOf(address(this)),
            "Exceeds vault solvency"
        );

        userBalances[token][user] += amount;
        l.totalUserBalances += amount;
        principalOf[token][user] += amount;

        emit Deposit(token, user, amount);
        emit BalanceIncreased(token, user, amount, userBalances[token][user]);
        emit PrincipalChanged(token, user, principalOf[token][user]);
        _touch();
    }

    /// @notice Increase a user's balance without principal (operator-assigned, e.g. rewards).
    ///         Charges the operator's daily ledger budget (admin exempt).
    function increaseBalance(address token, address user, uint256 amount)
        external
        onlyOperatorOrAdmin
        whenNotPaused
        whenNotAbandoned
        nonReentrant
    {
        require(_isLane(token), "Unknown lane");
        require(user != address(0), "Invalid user");
        require(amount > 0, "Zero amount");
        _chargeLedgerBudget(token, amount);
        Lane storage l = lanes[token];
        require(
            l.totalUserBalances + amount <= IERC20(token).balanceOf(address(this)),
            "Exceeds vault solvency"
        );

        userBalances[token][user] += amount;
        l.totalUserBalances += amount;

        emit BalanceIncreased(token, user, amount, userBalances[token][user]);
        _touch();
    }

    /// @notice Decrease a user's balance. Principal is clamped to the new balance —
    ///         the emergency claim always shrinks with the balance.
    ///         Charges the operator's daily ledger budget (admin exempt).
    function decreaseBalance(address token, address user, uint256 amount)
        external
        onlyOperatorOrAdmin
        whenNotPaused
        whenNotAbandoned
        nonReentrant
    {
        require(_isLane(token), "Unknown lane");
        require(amount > 0, "Zero amount");
        require(userBalances[token][user] >= amount, "Insufficient user balance");
        _chargeLedgerBudget(token, amount);

        userBalances[token][user] -= amount;
        lanes[token].totalUserBalances -= amount;

        uint256 newBal = userBalances[token][user];
        if (principalOf[token][user] > newBal) {
            principalOf[token][user] = newBal;
            emit PrincipalChanged(token, user, newBal);
        }

        emit BalanceDecreased(token, user, amount, newBal);
        _touch();
    }

    /// @notice Settle a user withdrawal to an external address. Per-lane daily cap for operator.
    function withdraw(address token, address to, uint256 amount)
        external
        onlyOperatorOrAdmin
        whenNotPaused
        whenNotAbandoned
        nonReentrant
    {
        require(_isLane(token), "Unknown lane");
        require(userBalances[token][to] >= amount, "Insufficient user balance");
        Lane storage l = lanes[token];

        if (msg.sender != admin) {
            _resetWithdrawAllowance(l);
            require(amount <= remainingDailyWithdrawAllowance(token), "Exceeds daily allowance");
            l.withdrawnToday += amount;
        }

        userBalances[token][to] -= amount;
        l.totalUserBalances -= amount;

        uint256 p = principalOf[token][to];
        uint256 newPrincipal = amount >= p ? 0 : p - amount;
        principalOf[token][to] = newPrincipal;

        emit BalanceDecreased(token, to, amount, userBalances[token][to]);
        emit PrincipalChanged(token, to, newPrincipal);

        Address.functionCall(
            token,
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );

        emit Withdrawal(token, to, amount, msg.sender);
        _touch();
    }

    // ═══════════════════════════════════════════════════════════════════
    // P2P SETTLEMENT (PER LANE) — MOVES BALANCE *AND* PRINCIPAL
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Settle a P2P trade within a lane: move balance AND principal seller -> buyer.
    /// @dev Principal moved = min(amount, principalOf[from]). CONSERVES total principal.
    ///      Charges the operator's daily ledger budget on the AMOUNT moved (admin exempt).
    function settleTransfer(address token, address from, address to, uint256 amount)
        external
        onlyOperatorOrAdmin
        whenNotPaused
        whenNotAbandoned
        nonReentrant
    {
        _settleTransfer(token, from, to, amount);
        _touch();
    }

    /// @notice Batch settlement. ATOMIC: any invalid entry reverts the entire batch.
    ///         The backend pre-validates entries and splits batches on failure.
    function batchSettleTransfer(
        address token,
        address[] calldata from,
        address[] calldata to,
        uint256[] calldata amounts
    )
        external
        onlyOperatorOrAdmin
        whenNotPaused
        whenNotAbandoned
        nonReentrant
    {
        require(from.length == to.length && to.length == amounts.length, "Length mismatch");
        require(from.length <= MAX_BATCH, "Batch too large");
        for (uint256 i = 0; i < from.length; i++) {
            _settleTransfer(token, from[i], to[i], amounts[i]);
        }
        _touch();
    }

    function _settleTransfer(address token, address from, address to, uint256 amount) internal {
        require(_isLane(token), "Unknown lane");
        require(from != address(0), "Invalid from address");
        require(to != address(0), "Invalid to address");
        require(from != to, "Self settle");
        require(amount > 0, "Zero amount");
        require(userBalances[token][from] >= amount, "Insufficient sender balance");
        _chargeLedgerBudget(token, amount);

        userBalances[token][from] -= amount;
        userBalances[token][to] += amount;

        uint256 pFrom = principalOf[token][from];
        uint256 principalMoved = amount < pFrom ? amount : pFrom;
        if (principalMoved > 0) {
            principalOf[token][from] = pFrom - principalMoved;
            principalOf[token][to] += principalMoved;
            emit PrincipalChanged(token, from, principalOf[token][from]);
            emit PrincipalChanged(token, to, principalOf[token][to]);
        }

        emit BalanceDecreased(token, from, amount, userBalances[token][from]);
        emit BalanceIncreased(token, to, amount, userBalances[token][to]);
        emit SettleTransfer(token, from, to, amount, principalMoved);
    }

    // ═══════════════════════════════════════════════════════════════════
    // LANE CONVERSIONS (FLAT <-> sFLAT) — ATOMIC THROUGH THE LIVE sFLAT VAULT
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Convert a user's FLAT lane balance into sFLAT lane shares, atomically.
    /// @dev Debits FLAT balance/principal, deposits the vault's FLAT into the sFLAT ERC-4626,
    ///      credits the user with the REAL shares received. Principal carries over
    ///      PROPORTIONALLY: sharePrincipal = shares * principalMoved / flatAmount, so a
    ///      conversion can never mint principal out of a non-principal balance.
    ///      Lane solvency holds throughout: FLAT claims drop by exactly the deposited amount,
    ///      share claims rise by exactly the shares received.
    ///      Both lane budgets are charged (V4.5): the FLAT amount up front and the
    ///      measured share credit after the deposit (admin exempt).
    function convertFlatToSflat(address user, uint256 flatAmount, uint256 minSharesOut)
        external
        onlyOperatorOrAdmin
        whenNotPaused
        whenNotAbandoned
        nonReentrant
        returns (uint256 shares)
    {
        require(user != address(0), "Invalid user");
        require(flatAmount > 0, "Zero amount");
        require(userBalances[flatToken][user] >= flatAmount, "Insufficient FLAT balance");

        // a conversion mutates BOTH lanes' ledgers: charge the source lane up front
        // (V4.5, round-4 ChatGPT L1; admin exempt via _chargeLedgerBudget)
        _chargeLedgerBudget(flatToken, flatAmount);

        // effects: debit FLAT lane
        userBalances[flatToken][user] -= flatAmount;
        lanes[flatToken].totalUserBalances -= flatAmount;
        uint256 pFrom = principalOf[flatToken][user];
        uint256 pMoved = flatAmount < pFrom ? flatAmount : pFrom;
        principalOf[flatToken][user] = pFrom - pMoved;

        // interaction: deposit into the live sFLAT vault (vault holds the shares),
        // then credit the MEASURED share delta, not deposit()'s reported return value
        Address.functionCall(
            flatToken,
            abi.encodeWithSelector(IERC20.approve.selector, sflatVault, flatAmount)
        );
        uint256 sharesBefore = IERC20(sflatVault).balanceOf(address(this));
        IERC4626(sflatVault).deposit(flatAmount, address(this));
        shares = IERC20(sflatVault).balanceOf(address(this)) - sharesBefore;
        require(shares > 0 && shares >= minSharesOut, "Slippage");
        _chargeLedgerBudget(sflatVault, shares); // measured destination-lane credit (V4.5)
        // hygiene: leave no standing allowance behind
        Address.functionCall(
            flatToken,
            abi.encodeWithSelector(IERC20.approve.selector, sflatVault, 0)
        );

        // effects: credit sFLAT lane (principal proportional to what the deposit carried)
        uint256 pCredit = (shares * pMoved) / flatAmount;
        userBalances[sflatVault][user] += shares;
        lanes[sflatVault].totalUserBalances += shares;
        principalOf[sflatVault][user] += pCredit;

        emit BalanceDecreased(flatToken, user, flatAmount, userBalances[flatToken][user]);
        emit BalanceIncreased(sflatVault, user, shares, userBalances[sflatVault][user]);
        emit PrincipalChanged(flatToken, user, principalOf[flatToken][user]);
        emit PrincipalChanged(sflatVault, user, principalOf[sflatVault][user]);
        emit Converted(user, flatToken, sflatVault, flatAmount, shares);
        _touch();
    }

    /// @notice Convert a user's sFLAT lane shares back into FLAT, atomically, at the
    ///         then-current ERC-4626 factor. The credited FLAT is the MEASURED balance
    ///         delta of this contract, not the vault's reported return value.
    ///         Both lane budgets are charged (V4.5): the share amount up front and the
    ///         measured FLAT credit after the redeem (admin exempt).
    function convertSflatToFlat(address user, uint256 shareAmount, uint256 minFlatOut)
        external
        onlyOperatorOrAdmin
        whenNotPaused
        whenNotAbandoned
        nonReentrant
        returns (uint256 assets)
    {
        require(user != address(0), "Invalid user");
        require(shareAmount > 0, "Zero amount");
        require(userBalances[sflatVault][user] >= shareAmount, "Insufficient sFLAT balance");

        // a conversion mutates BOTH lanes' ledgers: charge the source lane up front
        // (V4.5, round-4 ChatGPT L1; admin exempt via _chargeLedgerBudget)
        _chargeLedgerBudget(sflatVault, shareAmount);

        // effects: debit sFLAT lane
        userBalances[sflatVault][user] -= shareAmount;
        lanes[sflatVault].totalUserBalances -= shareAmount;
        uint256 pFrom = principalOf[sflatVault][user];
        uint256 pMoved = shareAmount < pFrom ? shareAmount : pFrom;
        principalOf[sflatVault][user] = pFrom - pMoved;

        // interaction: redeem from the live sFLAT vault, measure what actually arrived
        uint256 balBefore = IERC20(flatToken).balanceOf(address(this));
        IERC4626(sflatVault).redeem(shareAmount, address(this), address(this));
        assets = IERC20(flatToken).balanceOf(address(this)) - balBefore;
        require(assets > 0 && assets >= minFlatOut, "Slippage");
        _chargeLedgerBudget(flatToken, assets); // measured destination-lane credit (V4.5)

        // effects: credit FLAT lane (principal proportional to what the shares carried)
        uint256 pCredit = (assets * pMoved) / shareAmount;
        userBalances[flatToken][user] += assets;
        lanes[flatToken].totalUserBalances += assets;
        principalOf[flatToken][user] += pCredit;

        emit BalanceDecreased(sflatVault, user, shareAmount, userBalances[sflatVault][user]);
        emit BalanceIncreased(flatToken, user, assets, userBalances[flatToken][user]);
        emit PrincipalChanged(sflatVault, user, principalOf[sflatVault][user]);
        emit PrincipalChanged(flatToken, user, principalOf[flatToken][user]);
        emit Converted(user, sflatVault, flatToken, shareAmount, assets);
        _touch();
    }

    // ═══════════════════════════════════════════════════════════════════
    // EMERGENCY EXIT — PERMISSIONLESS, ONLY WHEN ABANDONED, ETERNAL
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Register the self-custody address that receives this ledger user's funds after
    ///         abandonment. Set by the backend on an authenticated FlatID request (the user
    ///         proves identity off-chain; the ledger key never signs anything). Setting or
    ///         changing this address is NOT a spend — funds can only ever go TO it.
    /// @dev    AGING (V4.2): an address is honored only if it was set at least
    ///         CLAIM_ADDRESS_DELAY (30 days) BEFORE abandonment began; otherwise the PREVIOUS
    ///         matured address is used. Since the constructor forces heartbeatInterval <
    ///         CLAIM_ADDRESS_DELAY, a set-and-stop redirect can never mature: any honored
    ///         redirect spent ≥ 30 days visible on-chain, with the vault heartbeating for at
    ///         least (CLAIM_ADDRESS_DELAY − heartbeatInterval) of them — during which the
    ///         guardian can revokeOperator() and rollbackClaimAddresses(). A guardian
    ///         revive() never ages claims (V4.4: lastLiveHeartbeat is untouched by
    ///         revive), so a set-and-stop redirect stays immature across revives too.
    ///         Pause-gated, and the OPERATOR is rate-limited to dailyClaimWriteLimit
    ///         writes per UTC day (V4.3; admin exempt), so a mass redirect is slow and
    ///         loud. Voided records (V4.4) reject writes until an admin clear.
    function setEmergencyClaimAddress(address user, address claimAddress)
        external
        onlyOperatorOrAdmin
        whenNotPaused
        whenNotAbandoned
        nonReentrant
    {
        require(user != address(0), "Invalid user");
        require(claimAddress != address(0), "Invalid claim address");
        require(
            claimAddress != address(this) && claimAddress != flatToken
                && claimAddress != saveToken && claimAddress != sflatVault,
            "Invalid claim address"
        );
        if (msg.sender != admin) {
            uint256 currentDay = block.timestamp / 1 days;
            if (currentDay > lastClaimWriteResetDay) {
                lastClaimWriteResetDay = currentDay;
                claimWritesToday = 0;
            }
            require(claimWritesToday < dailyClaimWriteLimit, "Exceeds daily claim writes");
            claimWritesToday++;
        }
        Claim storage c = emergencyClaims[user];
        require(!c.voided, "Record voided, admin clear required"); // voided records are frozen
        // promote the outgoing address to `previous` only if it is CLAIM_ADDRESS_DELAY old in
        // wall-clock time AND matured against the live clock (V4.6, _promotionRef). The live
        // clock alone (V4.5) is a PROJECTION while live — it promoted addresses only
        // (CLAIM_ADDRESS_DELAY - heartbeatInterval) old, letting an operator erase a user's
        // legit fallback in as little as one day. Wall-clock alone (V4.3) let a guardian-only
        // revive be followed by a promoting write (round-4 M1). The minimum closes both.
        if (c.current != address(0) && uint256(c.setAt) + CLAIM_ADDRESS_DELAY <= _promotionRef()) {
            c.previous = c.current;
        }
        c.current = claimAddress;
        c.setAt = uint64(block.timestamp);
        emit EmergencyClaimAddressSet(user, claimAddress, c.previous, msg.sender);
        _touch();
    }

    /// @notice Roll back hijacked claim records to each user's last MATURED address.
    ///         Batch: the guardian answers a mass redirect with ONE Safe transaction.
    ///         Callable by the guardian at ANY time (including abandoned/paused — a redirect
    ///         made just before silence stays neutralizable) or by the admin while live.
    /// @dev    V4.3, fixes the round-3 High: this REPLACES deletion as the guardian's remedy.
    ///         A rollback can only move a user BACK to an address that user already held for
    ///         30+ days (setAt = 0 is matured against any real abandonmentStart) — never to
    ///         nothing, and never to an address the guardian chooses. Reverts per-user when
    ///         no matured fallback exists (an immature `current` is already ignored by
    ///         claimTarget, so such users need no action — or a void, if hostile).
    ///         V4.4 bounds: the current address must be younger than 2 * CLAIM_ADDRESS_DELAY
    ///         (measured against abandonmentStart() once abandoned), so the guardian keeps a
    ///         30-day remedy after a redirect matures but can never send a user back to a
    ///         wallet abandoned 60+ days ago; and while the vault is LIVE the guardian must
    ///         have revoked the operator first, so a compromised operator cannot front-run
    ///         the remedy and promote the attacker address to `previous` (round-4, Grok).
    function rollbackClaimAddresses(address[] calldata users) external nonReentrant {
        require(msg.sender == admin || msg.sender == guardian, "Not admin or guardian");
        require(users.length <= MAX_BATCH, "Batch too large");
        uint256 ref = isAbandoned() ? abandonmentStart() : block.timestamp;
        if (msg.sender == admin) {
            require(!isAbandoned(), "Vault is abandoned");
            _touch();
        } else if (!isAbandoned()) {
            require(operator == address(0), "Revoke operator first"); // incident mode
        }
        for (uint256 i = 0; i < users.length; i++) {
            Claim storage c = emergencyClaims[users[i]];
            require(c.previous != address(0), "No matured fallback");
            require(uint256(c.setAt) + 2 * CLAIM_ADDRESS_DELAY > ref, "Rollback window closed");
            c.current = c.previous;
            c.previous = address(0);
            c.setAt = 0; // matured: 0 + CLAIM_ADDRESS_DELAY <= any real abandonmentStart()
            emit EmergencyClaimAddressRolledBack(users[i], c.current, msg.sender);
        }
    }

    /// @notice Void claim records: zeroes current AND previous and sets a sticky `voided` flag.
    ///         Batch; guardian any time, admin while live. The remedy for attacker writes on
    ///         never-registered or first-registration users (V4.4, round-4 N-2), and — V4.6 —
    ///         for records whose `previous` is itself hostile (rollback would restore it).
    ///         V4.6 bound: like rollback, only records whose current address is younger than
    ///         2 * CLAIM_ADDRESS_DELAY (vs abandonmentStart once abandoned) can be voided, so the
    ///         guardian can never strand a user's settled choice (incl. post-rollback records,
    ///         setAt == 0).
    /// @dev    Voided-over-stolen: a voided record blocks BOTH exits (the self-exit treats it
    ///         as registered) and rejects all further writes, so the attacker address can
    ///         never be honored and the user is stranded — never drained — until the admin
    ///         clears the record in a live vault and the user re-registers. While the vault
    ///         is LIVE the guardian must have revoked the operator first (same as rollback).
    function voidClaimAddresses(address[] calldata users) external nonReentrant {
        require(msg.sender == admin || msg.sender == guardian, "Not admin or guardian");
        require(users.length <= MAX_BATCH, "Batch too large");
        uint256 ref = isAbandoned() ? abandonmentStart() : block.timestamp;
        if (msg.sender == admin) {
            require(!isAbandoned(), "Vault is abandoned");
            _touch();
        } else if (!isAbandoned()) {
            require(operator == address(0), "Revoke operator first"); // incident mode
        }
        for (uint256 i = 0; i < users.length; i++) {
            Claim storage c = emergencyClaims[users[i]];
            require(c.current != address(0), "Nothing to void");
            require(uint256(c.setAt) + 2 * CLAIM_ADDRESS_DELAY > ref, "Void window closed");
            address voidedAddress = c.current;
            address voidedPrevious = c.previous;
            c.current = address(0);
            c.previous = address(0);
            c.setAt = 0;
            c.voided = true; // sticky until an admin clear deletes the whole record
            emit EmergencyClaimAddressVoided(users[i], voidedAddress, voidedPrevious, msg.sender);
        }
    }

    /// @notice Full deletion of a claim record — ADMIN ONLY, while the vault is live.
    ///         This is also the only way to lift a guardian void. After a clear, the user
    ///         has no record: self-exit falls back to their own ledger key and
    ///         emergencyWithdrawTo reverts until a new address matures.
    ///         Deliberately NOT a guardian power: deletion can strand a keyless user, so it
    ///         belongs only to the trusted admin in a live vault (e.g. user-requested reset).
    function clearEmergencyClaimAddress(address user) external onlyAdmin whenNotAbandoned nonReentrant {
        delete emergencyClaims[user];
        emit EmergencyClaimAddressCleared(user, msg.sender);
        _touch();
    }

    /// @notice The claim address that is honored RIGHT NOW: the current one only if it matured
    ///         before abandonment began; otherwise the previous matured one; else zero.
    /// @dev    Maturity is measured against lastLiveHeartbeat + heartbeatInterval — the clock
    ///         only admin/operator actions advance (V4.4). A guardian revive() does NOT move
    ///         it, so a revive can never mature a redirect the first abandonment correctly
    ///         ignored; nor can an attacker "age" a fresh address by waiting inside the
    ///         abandoned state. The SAME reference gates the setter's promotion of
    ///         `current` to `previous` (V4.5, _claimMaturityRef), so `previous` is always
    ///         an address this function would honor. While the vault is LIVE this measures
    ///         against the PROJECTED abandonment start — informational only; front-ends
    ///         should show setAt + CLAIM_ADDRESS_DELAY as the maturity date.
    function claimTarget(address user) public view returns (address) {
        Claim memory c = emergencyClaims[user];
        uint256 ref = _claimMaturityRef(); // guardian revives never age claims
        if (c.current != address(0) && uint256(c.setAt) + CLAIM_ADDRESS_DELAY <= ref) {
            return c.current;
        }
        return c.previous;
    }

    /// @notice After abandonment, exit for a user who holds their ledger key. Pays the MATURED
    ///         claim address when one exists; stolen server-side ledger keys alone never beat
    ///         it. Falls back to msg.sender ONLY for a user who NEVER had a claim record
    ///         (V4.3): a registered user whose address has not matured reverts — stranded,
    ///         not stolen. A guardian revive alone never matures it (V4.4); a revive reopens
    ///         normal operation, and maturity resumes against the renewed admin/operator
    ///         heartbeat. Voided records (V4.4) revert here too — also stranded, not stolen.
    ///         Phase 1 (before RECOVERY_TIMELOCK): claim = min(balance, principal, available).
    ///         Phase 2 (after RECOVERY_TIMELOCK): claim = min(FULL balance, available) —
    ///         non-principal balances (rewards etc.) are no longer stranded forever.
    ///         No role gate and no pause gate; cannot be disabled.
    function emergencyWithdraw(address token) external nonReentrant {
        address to = claimTarget(msg.sender);
        if (to == address(0)) {
            Claim memory c = emergencyClaims[msg.sender];
            require(
                c.current == address(0) && c.previous == address(0) && !c.voided,
                "Claim address not matured"
            );
            to = msg.sender;
        }
        _emergencyWithdraw(token, msg.sender, to);
    }

    /// @notice For users who do NOT hold their ledger key (the normal FlatID case): after
    ///         abandonment, ANYONE can trigger the exit for `user`, and funds go ONLY to the
    ///         matured claim address. Reverts if none matured — users should register one
    ///         while the protocol is live (registration at onboarding makes the 30-day
    ///         first-registration delay a non-issue).
    function emergencyWithdrawTo(address token, address user) external nonReentrant {
        address to = claimTarget(user);
        require(to != address(0), "No matured claim address");
        _emergencyWithdraw(token, user, to);
    }

    function _emergencyWithdraw(address token, address user, address to) internal {
        require(_isLane(token), "Unknown lane");
        require(isAbandoned(), "Vault is not abandoned");

        uint256 bal = userBalances[token][user];
        uint256 claim;
        if (block.timestamp >= abandonmentStart() + RECOVERY_TIMELOCK) {
            claim = bal; // phase 2: full-balance release
        } else {
            uint256 prin = principalOf[token][user];
            claim = bal < prin ? bal : prin;
        }
        require(claim > 0, "No claim");

        uint256 available = IERC20(token).balanceOf(address(this));
        uint256 withdrawAmount = claim < available ? claim : available;
        require(withdrawAmount > 0, "Vault is empty, try again later");

        userBalances[token][user] -= withdrawAmount;
        lanes[token].totalUserBalances -= withdrawAmount;
        uint256 p = principalOf[token][user];
        uint256 newPrincipal = withdrawAmount >= p ? 0 : p - withdrawAmount;
        principalOf[token][user] = newPrincipal;

        Address.functionCall(
            token,
            abi.encodeWithSelector(IERC20.transfer.selector, to, withdrawAmount)
        );

        emit BalanceDecreased(token, user, withdrawAmount, userBalances[token][user]);
        emit PrincipalChanged(token, user, newPrincipal);
        emit EmergencyWithdrawal(token, user, withdrawAmount, to);
    }

    // ═══════════════════════════════════════════════════════════════════
    // ABANDONED-STATE RECOVERY (GUARDIAN / SAFE ONLY)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Recover surplus (vault balance MINUS user claims) to the guardian, only after
    ///         abandonment + RECOVERY_TIMELOCK. Structurally cannot touch user claims.
    /// @dev    Runs in phase 2, when emergency exits already pay full balances — any balance
    ///         still counted in totalUserBalances remains claimable by users, so this only
    ///         ever skims what NO user can claim.
    function recoverSurplus(address token) external onlyGuardian nonReentrant {
        require(_isLane(token), "Unknown lane");
        require(isAbandoned(), "Not abandoned");
        require(
            block.timestamp >= abandonmentStart() + RECOVERY_TIMELOCK,
            "Recovery timelock active"
        );

        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 claims = lanes[token].totalUserBalances;
        uint256 surplus = balance > claims ? balance - claims : 0;
        require(surplus > 0, "No surplus");

        Address.functionCall(
            token,
            abi.encodeWithSelector(IERC20.transfer.selector, guardian, surplus)
        );

        emit SurplusRecovered(token, surplus);
    }

    /// @notice Sweep a NON-LANE token (stray airdrops, mistakes) to the guardian.
    /// @dev Lane tokens are rejected, so this function can never touch anything a user
    ///      could have a claim on. Works in any state, including abandoned.
    function sweepForeign(address token) external onlyGuardian nonReentrant {
        require(!_isLane(token), "Lane token");
        require(token != address(0), "Invalid token");
        uint256 bal = IERC20(token).balanceOf(address(this));
        require(bal > 0, "Nothing to sweep");
        Address.functionCall(
            token,
            abi.encodeWithSelector(IERC20.transfer.selector, guardian, bal)
        );
        emit ForeignSwept(token, bal);
    }

    /// @notice Queue the ONE-TIME revive. Starts the 7-day public timelock.
    function queueRevive() external onlyGuardian nonReentrant {
        require(isAbandoned(), "Not abandoned");
        require(!revived, "Revive already spent");
        require(reviveEta == 0, "Revive already queued");
        reviveEta = block.timestamp + REVIVE_TIMELOCK;
        emit ReviveQueued(reviveEta);
    }

    /// @notice Execute the queued revive after the timelock. Resets the heartbeat window.
    ///         One-time only — a second abandonment is final (recoverSurplus still works,
    ///         and emergency exits remain eternal). Deliberately does NOT touch
    ///         lastLiveHeartbeat (V4.4): a guardian-only revive must never mature claim
    ///         addresses the first abandonment correctly ignored. V4.6: requires the
    ///         operator to be REVOKED — an unrevoked (possibly compromised) operator's first
    ///         post-revive action would itself re-arm the maturity clock. Only the trusted
    ///         admin can act after a revive (and re-appoint an operator). Runbook: void or
    ///         roll back hostile claim writes BEFORE reviving.
    function revive() external onlyGuardian nonReentrant {
        require(isAbandoned(), "Not abandoned");
        require(!revived, "Revive already spent");
        require(reviveEta != 0, "Revive not queued");
        require(block.timestamp >= reviveEta, "Revive timelock active");
        require(operator == address(0), "Revoke operator first");

        revived = true;
        reviveEta = 0;
        lastHeartbeat = block.timestamp; // NOT lastLiveHeartbeat: a revive never ages claims
        emit Revived(msg.sender, block.timestamp);
        emit Heartbeat(msg.sender, block.timestamp); // liveness reset, rebuildable from logs
    }

    /// @notice Emergency brake on a compromised operator: the guardian can revoke the
    ///         operator key at any time (including while paused). The admin appoints a
    ///         replacement later with setOperator. With operator == address(0), every
    ///         operator path is dead (msg.sender can never be zero).
    function revokeOperator() external onlyGuardian nonReentrant {
        require(operator != address(0), "Already revoked");
        emit OperatorRevoked(operator, msg.sender);
        operator = address(0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // BALANCE SEEDING (ONE-TIME MIGRATION — HONORS LEGACY V3 / V2.9 CLAIMS)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Seed userBalances + principalOf from prior-vault state. Admin only, pre-finalize,
    ///         and frozen while abandoned (no new claims can be born into an abandoned vault —
    ///         revive first). One event per account so the migration is auditable on Etherscan.
    ///         Enforces lane solvency inline, so an underfunded seed reverts immediately.
    ///         Legacy claims honored: 1,188.62 SAVE (V3 SAVE vault) + 49.03 FLAT (V2.9 vault).
    function seedBalances(address token, address[] calldata users, uint256[] calldata amounts)
        external
        onlyAdmin
        whenNotAbandoned
        nonReentrant
    {
        require(_isLane(token), "Unknown lane");
        require(!seedingComplete, "Seeding already complete");
        require(users.length == amounts.length, "Length mismatch");
        require(users.length <= MAX_BATCH, "Batch too large");

        Lane storage l = lanes[token];
        for (uint256 i = 0; i < users.length; i++) {
            require(users[i] != address(0), "Invalid address");
            require(amounts[i] > 0, "Zero amount");
            userBalances[token][users[i]] += amounts[i];
            l.totalUserBalances += amounts[i];
            principalOf[token][users[i]] += amounts[i];
            emit BalanceSeeded(token, users[i], amounts[i]);
            emit BalanceIncreased(token, users[i], amounts[i], userBalances[token][users[i]]);
            emit PrincipalChanged(token, users[i], principalOf[token][users[i]]);
        }
        require(
            l.totalUserBalances <= IERC20(token).balanceOf(address(this)),
            "Seed exceeds vault funding"
        );
        _touch();
    }

    /// @notice Seal the seed. Requires an EXACT match against the expected per-lane totals
    ///         (so a duplicated or missed batch fails loudly), and that the vault actually
    ///         holds the seeded tokens for EVERY lane. After this, seedBalances is dead forever.
    function finalizeSeed(
        uint256 expectedFlatTotal,
        uint256 expectedSaveTotal,
        uint256 expectedSflatTotal
    )
        external
        onlyAdmin
        whenNotAbandoned
        nonReentrant
    {
        require(!seedingComplete, "Already finalized");
        require(lanes[flatToken].totalUserBalances == expectedFlatTotal, "FLAT total mismatch");
        require(lanes[saveToken].totalUserBalances == expectedSaveTotal, "SAVE total mismatch");
        require(lanes[sflatVault].totalUserBalances == expectedSflatTotal, "sFLAT total mismatch");
        require(_solvent(flatToken), "FLAT lane underfunded");
        require(_solvent(saveToken), "SAVE lane underfunded");
        require(_solvent(sflatVault), "sFLAT lane underfunded");
        seedingComplete = true;
        emit SeedingCompleted();
        _touch();
    }

    // ═══════════════════════════════════════════════════════════════════
    // ADMIN SETTERS (FROZEN WHEN ABANDONED)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Two-step admin handover: step 1 proposes, step 2 the new key accepts.
    ///         A typo in step 1 is harmless — the current admin keeps control.
    ///         Proposals EXPIRE after PENDING_ADMIN_TTL so a forgotten proposal cannot be
    ///         accepted by a key that has since changed hands (or become operator/guardian).
    function proposeAdmin(address newAdmin) external onlyAdmin whenNotAbandoned nonReentrant {
        require(newAdmin != address(0), "Invalid address");
        require(newAdmin != operator && newAdmin != guardian, "Roles must be distinct");
        pendingAdmin = newAdmin;
        pendingAdminEta = block.timestamp + PENDING_ADMIN_TTL;
        emit AdminChangeProposed(admin, newAdmin);
        _touch();
    }

    function acceptAdmin() external nonReentrant {
        require(msg.sender == pendingAdmin, "Not pending admin");
        require(!isAbandoned(), "Vault is abandoned");
        require(block.timestamp <= pendingAdminEta, "Proposal expired");
        // re-check distinctness at ACCEPT time: operator/guardian may have changed since the proposal
        require(msg.sender != operator && msg.sender != guardian, "Roles must be distinct");
        emit AdminChanged(admin, pendingAdmin);
        admin = pendingAdmin;
        pendingAdmin = address(0);
        pendingAdminEta = 0;
        lastHeartbeat = block.timestamp; // the new key proves liveness
        lastLiveHeartbeat = block.timestamp;
        emit Heartbeat(msg.sender, block.timestamp);
    }

    function cancelAdminHandover() external onlyAdmin whenNotAbandoned nonReentrant {
        pendingAdmin = address(0);
        pendingAdminEta = 0;
        emit AdminChangeProposed(admin, address(0));
        _touch();
    }

    function setOperator(address newOperator) external onlyAdmin whenNotAbandoned nonReentrant {
        require(newOperator != address(0), "Invalid address");
        require(newOperator != admin && newOperator != guardian, "Roles must be distinct");
        require(newOperator != pendingAdmin, "Pending admin"); // would break handover distinctness
        emit OperatorChanged(operator, newOperator);
        operator = newOperator;
        _touch();
    }

    function setGuardian(address newGuardian) external onlyAdmin whenNotAbandoned nonReentrant {
        require(newGuardian != address(0), "Invalid address");
        require(newGuardian != admin && newGuardian != operator, "Roles must be distinct");
        require(newGuardian != pendingAdmin, "Pending admin"); // would break handover distinctness
        emit GuardianChanged(guardian, newGuardian);
        guardian = newGuardian;
        _touch();
    }

    /// @notice Point the sFLAT lane at a new ERC-4626 vault (e.g. sFLAT upgrade).
    /// @dev The lane token key changes: the OLD lane must carry zero user claims
    ///      (convert all users back to FLAT first). Enforced on-chain. The new vault is
    ///      validated (has code, asset is FLAT, distinct from other lanes) and INHERITS
    ///      the old lane's caps so the operator can never gain an uncapped lane.
    function setSflatVault(address newVault) external onlyAdmin whenNotAbandoned nonReentrant {
        require(newVault != address(0), "Invalid vault");
        require(newVault.code.length > 0, "Vault has no code");
        require(newVault != flatToken && newVault != saveToken, "Lane tokens must be distinct");
        require(IERC4626(newVault).asset() == flatToken, "Vault asset is not FLAT");
        Lane storage oldLane = lanes[sflatVault];
        require(oldLane.totalUserBalances == 0, "Migrate sFLAT claims first");
        lanes[newVault].dailyWithdrawLimit = oldLane.dailyWithdrawLimit;
        lanes[newVault].dailyLedgerBudget = oldLane.dailyLedgerBudget;
        emit SflatVaultChanged(sflatVault, newVault);
        sflatVault = newVault;
        _touch();
    }

    /// @notice Set the operator's daily withdrawal cap for a lane. 0 == operator cannot withdraw.
    ///         Admin is exempt from the cap. Set at birth via the constructor.
    function setLaneWithdrawLimit(address token, uint256 newLimit) external onlyAdmin whenNotAbandoned nonReentrant {
        require(_isLane(token), "Unknown lane");
        emit LaneWithdrawLimitChanged(token, lanes[token].dailyWithdrawLimit, newLimit);
        lanes[token].dailyWithdrawLimit = newLimit;
        _touch();
    }

    /// @notice Set the operator's daily ledger-mutation budget for a lane (amount-counted).
    ///         0 == operator cannot mutate the ledger. Admin is exempt.
    function setLaneLedgerBudget(address token, uint256 newBudget) external onlyAdmin whenNotAbandoned nonReentrant {
        require(_isLane(token), "Unknown lane");
        emit LaneLedgerBudgetChanged(token, lanes[token].dailyLedgerBudget, newBudget);
        lanes[token].dailyLedgerBudget = newBudget;
        _touch();
    }

    function setMaxPauseDuration(uint256 newDuration) external onlyAdmin whenNotAbandoned nonReentrant {
        require(newDuration > 0, "Duration must be > 0");
        require(newDuration <= MAX_PAUSE_DURATION_CAP, "Exceeds max pause cap");
        emit MaxPauseDurationChanged(maxPauseDuration, newDuration);
        maxPauseDuration = newDuration;
        _touch();
    }

    /// @notice Set the operator's daily cap on claim-address writes (count per UTC day).
    ///         0 == operator cannot set claim addresses at all. Admin is exempt.
    ///         Set at birth via the constructor.
    function setDailyClaimWriteLimit(uint256 newLimit) external onlyAdmin whenNotAbandoned nonReentrant {
        emit ClaimWriteLimitChanged(dailyClaimWriteLimit, newLimit);
        dailyClaimWriteLimit = newLimit;
        _touch();
    }

    // ═══════════════════════════════════════════════════════════════════
    // PAUSE / UNPAUSE (GUARDIAN — BOUNDED, CANNOT BE EXTENDED WHILE ACTIVE)
    // ═══════════════════════════════════════════════════════════════════

    function pause() external onlyGuardian nonReentrant {
        _advancePauseExpiry();

        require(!paused, "Already paused"); // cannot extend an active pause
        require(
            lastPauseExpiredAt == 0 || block.timestamp >= lastPauseExpiredAt + REPAUSE_COOLDOWN,
            "Re-pause cooldown active"
        );

        paused = true;
        pauseExpiresAt = block.timestamp + maxPauseDuration;
        emit Paused(msg.sender, pauseExpiresAt);
    }

    function unpause() external onlyGuardian nonReentrant {
        _advancePauseExpiry(); // a naturally expired pause is already over — nothing to unpause
        require(paused, "Not paused"); // no silent re-arming of the re-pause cooldown
        paused = false;
        lastPauseExpiredAt = block.timestamp;
        pauseExpiresAt = 0;
        emit Unpaused(msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════

    function _isLane(address token) internal view returns (bool) {
        return token == flatToken || token == saveToken || token == sflatVault;
    }

    function _solvent(address token) internal view returns (bool) {
        return lanes[token].totalUserBalances <= IERC20(token).balanceOf(address(this));
    }

    /// @dev THE one claim-maturity reference (V4.5): the clock only admin/operator liveness
    ///      advances, plus one heartbeat interval (the projected abandonment start).
    ///      Shared by claimTarget() and the claim setter's promotion rule, so an address
    ///      can never be promoted to `previous` unless claimTarget would honor it —
    ///      closing the revive-then-rewrite promotion residual of the round-4 M1 finding.
    function _claimMaturityRef() internal view returns (uint256) {
        return lastLiveHeartbeat + heartbeatInterval;
    }

    /// @dev Promotion reference: an address becomes `previous` only once it is BOTH 30 days old
    ///      in wall-clock time AND matured against the live clock. While live (no revive) this is
    ///      block.timestamp (V4.3 semantics, no projection); after a guardian-only revive it is the
    ///      frozen live-clock projection (ChatGPT M1 stays closed).
    function _promotionRef() internal view returns (uint256) {
        uint256 ref = _claimMaturityRef();
        return block.timestamp < ref ? block.timestamp : ref;
    }

    /// @dev Heartbeat-as-a-side-effect: any successful admin/operator action proves liveness.
    ///      Advances BOTH clocks (abandonment and claim-aging). Emits Heartbeat so
    ///      lastHeartbeat is rebuildable from event logs alone.
    function _touch() internal {
        lastHeartbeat = block.timestamp;
        lastLiveHeartbeat = block.timestamp;
        emit Heartbeat(msg.sender, block.timestamp);
    }

    /// @dev Charge the operator's per-lane daily ledger budget. Admin is exempt.
    ///      0 budget == operator cannot mutate the ledger at all (0 is NOT unlimited).
    function _chargeLedgerBudget(address token, uint256 amount) internal {
        if (msg.sender == admin) return;
        Lane storage l = lanes[token];
        uint256 currentDay = block.timestamp / 1 days;
        if (currentDay > l.lastLedgerResetDay) {
            l.lastLedgerResetDay = currentDay;
            l.ledgerSpentToday = 0;
        }
        require(
            l.ledgerSpentToday + amount <= l.dailyLedgerBudget,
            "Exceeds daily ledger budget"
        );
        l.ledgerSpentToday += amount;
    }

    function _resetWithdrawAllowance(Lane storage l) internal {
        uint256 currentDay = block.timestamp / 1 days;
        if (currentDay > l.lastWithdrawResetDay) {
            l.lastWithdrawResetDay = currentDay;
            l.withdrawnToday = 0;
        }
    }

    function _advancePauseExpiry() internal {
        if (paused && block.timestamp >= pauseExpiresAt) {
            paused = false;
            lastPauseExpiredAt = pauseExpiresAt;
            pauseExpiresAt = 0;
        }
    }
}
