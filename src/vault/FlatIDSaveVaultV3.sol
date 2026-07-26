// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title FlatIDSaveVaultV3
 * @notice Custodial vault for SAVE tokens. Logic-identical to FlatIDVaultV3.
 * @dev V3 = V2.9 + settleTransfer / batchSettleTransfer for P2P trade settlement,
 *      plus an optional operator daily principal-movement cap (dailySettlePrincipalLimit).
 *
 *      V2.9 left a P2P recovery gap: P2P trades settle only in the off-chain ledger,
 *      so after a trade the seller's principalOf was too high and the buyer's was too
 *      low. On abandonment, emergencyWithdraw paid the seller (who already sold) and
 *      not the buyer (who now owns the tokens).
 *
 *      V3 adds settleTransfer, which moves balance AND principal from seller to buyer,
 *      capped at the seller's available principal. This CONSERVES total principal
 *      (it is moved, never created), so it introduces no principal-inflation vector,
 *      and it makes the buyer's purchased balance recoverable via emergencyWithdraw
 *      using ONLY on-chain state (no Merkle proof / off-chain tree).
 *
 *      OPERATOR SAFETY LAYER (V3.1): a compromised operator could otherwise redistribute
 *      ALL existing principal to an attacker address via repeated settleTransfer calls
 *      (it can never *create* principal — total is conserved). dailySettlePrincipalLimit
 *      bounds the principal an operator can move per UTC day, capping the damage window
 *      of a compromised operator to one day. Admin is exempt; limit == 0 means unlimited
 *      (disabled), so default behavior is unchanged.
 *
 *      All nine V2.9 security properties are preserved unchanged. emergencyWithdraw,
 *      transferBalance, the role logic, the heartbeat dead-man's switch, the solvency
 *      invariant, and the pause mechanics are byte-for-byte the V2.9 versions.
 *
 *      CUSTODIAL BY DESIGN: the admin (Ledger cold wallet) has full control. That is
 *      intentional and is not a vulnerability. The security model defends against a
 *      compromised OPERATOR, a compromised GUARDIAN, and admin disappearance.
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

// Minimal SafeERC20 via low-level call
library Address {
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
        (bool success, bytes memory returndata) = target.call(data);
        require(success, "Address: low-level call failed");
        if (returndata.length > 0) {
            require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
        }
        return returndata;
    }
}

contract FlatIDSaveVaultV3 {
    // ═══════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════

    uint256 public constant MIN_HEARTBEAT_INTERVAL = 7 days;
    uint256 public constant MAX_PAUSE_DURATION_CAP = 30 days;
    uint256 public constant REPAUSE_COOLDOWN = 7 days;
    uint256 public constant MAX_BATCH = 200;

    // ═══════════════════════════════════════════════════════════════════
    // STATE VARIABLES
    // ═══════════════════════════════════════════════════════════════════

    address public admin;
    address public operator;
    address public guardian;
    IERC20 public immutable token;

    uint256 public dailyLimit;
    uint256 public lastResetDay;
    uint256 public spentToday;

    bool public paused;
    uint256 public pauseExpiresAt;
    uint256 public maxPauseDuration;
    uint256 public lastPauseExpiredAt;

    uint256 public lastHeartbeat;
    uint256 public heartbeatInterval;

    mapping(address => uint256) public userBalances;
    uint256 public totalUserBalances;

    // FIX 9: Principal tracking — only real deposits count for emergency exit.
    // V3: total principal (sum across users) only grows via recordDeposit/seedBalances;
    //     settleTransfer MOVES principal between users but never increases the total.
    mapping(address => uint256) public principalOf;

    bool public seedingComplete;

    // V3.1: operator daily principal-movement cap (admin-exempt; 0 == unlimited/disabled).
    uint256 public dailySettlePrincipalLimit;
    uint256 public lastSettleResetDay;
    uint256 public settledPrincipalToday;

    // ═══════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════

    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);
    event OperatorChanged(address indexed oldOperator, address indexed newOperator);
    event GuardianChanged(address indexed oldGuardian, address indexed newGuardian);
    event DailyLimitChanged(uint256 oldLimit, uint256 newLimit);
    event HeartbeatIntervalChanged(uint256 oldInterval, uint256 newInterval);
    event MaxPauseDurationChanged(uint256 oldDuration, uint256 newDuration);
    event Heartbeat(address indexed caller, uint256 timestamp);
    event Paused(address indexed by, uint256 expiresAt);
    event Unpaused(address indexed by);
    event Withdrawal(address indexed to, uint256 amount, address indexed calledBy);
    event Deposit(address indexed user, uint256 amount);
    event BalanceIncreased(address indexed user, uint256 amount, uint256 newBalance);
    event BalanceDecreased(address indexed user, uint256 amount, uint256 newBalance);
    event BalanceTransferred(address indexed from, address indexed to, uint256 amount);
    event EmergencyWithdrawal(address indexed user, uint256 amount);
    event SeedingCompleted(uint256 totalSeeded, uint256 userCount);
    // V3: P2P settlement (balance + principal). principalMoved = min(amount, principalOf[from]).
    event SettleTransfer(address indexed from, address indexed to, uint256 amount, uint256 principalMoved);
    // V3.1: operator daily principal-movement cap changed.
    event DailySettlePrincipalLimitChanged(uint256 oldLimit, uint256 newLimit);

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

    // ═══════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════

    constructor(
        address _token,
        address _admin,
        address _operator,
        address _guardian,
        uint256 _dailyLimit,
        uint256 _heartbeatInterval,
        uint256 _maxPauseDuration
    ) {
        require(_token != address(0), "Invalid token");
        require(_admin != address(0), "Invalid admin");
        require(_operator != address(0), "Invalid operator");
        require(_guardian != address(0), "Invalid guardian");
        require(_heartbeatInterval >= MIN_HEARTBEAT_INTERVAL, "Interval below minimum");
        require(_maxPauseDuration > 0, "Pause duration must be > 0");
        require(_maxPauseDuration <= MAX_PAUSE_DURATION_CAP, "Pause duration exceeds cap");

        token = IERC20(_token);
        admin = _admin;
        operator = _operator;
        guardian = _guardian;
        dailyLimit = _dailyLimit;
        heartbeatInterval = _heartbeatInterval;
        maxPauseDuration = _maxPauseDuration;
        lastHeartbeat = block.timestamp;
        lastResetDay = block.timestamp / 1 days;
        spentToday = 0;
        paused = false;
        pauseExpiresAt = 0;
        lastPauseExpiredAt = 0;
        seedingComplete = false;

        // V3.1: default = unlimited (disabled). Daily settle counter aligned to today.
        dailySettlePrincipalLimit = 0;
        lastSettleResetDay = block.timestamp / 1 days;
        settledPrincipalToday = 0;
    }

    // ═══════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════

    function vaultBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function remainingDailyAllowance() public view returns (uint256) {
        if (block.timestamp / 1 days > lastResetDay) {
            return dailyLimit;
        }
        if (spentToday >= dailyLimit) {
            return 0;
        }
        return dailyLimit - spentToday;
    }

    /// @notice Remaining principal the OPERATOR may still move via settleTransfer today.
    /// @dev Returns type(uint256).max when the cap is disabled (dailySettlePrincipalLimit == 0).
    ///      Admin is not subject to the cap.
    function remainingDailySettleAllowance() public view returns (uint256) {
        if (dailySettlePrincipalLimit == 0) {
            return type(uint256).max;
        }
        if (block.timestamp / 1 days > lastSettleResetDay) {
            return dailySettlePrincipalLimit;
        }
        if (settledPrincipalToday >= dailySettlePrincipalLimit) {
            return 0;
        }
        return dailySettlePrincipalLimit - settledPrincipalToday;
    }

    function isAbandoned() public view returns (bool) {
        return block.timestamp > lastHeartbeat + heartbeatInterval;
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

    // ═══════════════════════════════════════════════════════════════════
    // HEARTBEAT (DEAD-MAN'S SWITCH) — ADMIN ONLY
    // ═══════════════════════════════════════════════════════════════════

    function heartbeat() external onlyAdmin {
        require(!isAbandoned(), "Vault is abandoned, heartbeat disabled");
        lastHeartbeat = block.timestamp;
        emit Heartbeat(msg.sender, block.timestamp);
    }

    function setHeartbeatInterval(uint256 newInterval) external onlyAdmin whenNotAbandoned {
        require(newInterval >= MIN_HEARTBEAT_INTERVAL, "Below minimum interval");
        require(newInterval < heartbeatInterval, "Can only decrease interval");
        emit HeartbeatIntervalChanged(heartbeatInterval, newInterval);
        heartbeatInterval = newInterval;
    }

    // ═══════════════════════════════════════════════════════════════════
    // OPERATOR FUNCTIONS (DAILY-LIMITED — FROZEN WHEN ABANDONED/PAUSED)
    // ═══════════════════════════════════════════════════════════════════

    function withdraw(address to, uint256 amount) external onlyOperatorOrAdmin whenNotPaused whenNotAbandoned {
        require(userBalances[to] >= amount, "Insufficient user balance");

        if (msg.sender == operator && msg.sender != admin) {
            _resetDailyAllowance();
            require(amount <= remainingDailyAllowance(), "Exceeds daily allowance");
            spentToday += amount;
        }

        userBalances[to] -= amount;
        totalUserBalances -= amount;

        // FIX 9: Reduce principal proportionally (capped at current principal)
        uint256 p = principalOf[to];
        principalOf[to] = amount >= p ? 0 : p - amount;

        emit BalanceDecreased(to, amount, userBalances[to]);

        Address.functionCall(
            address(token),
            abi.encodeWithSelector(token.transfer.selector, to, amount)
        );

        emit Withdrawal(to, amount, msg.sender);
    }

    /// @notice Record a deposit for a user. Enforces solvency invariant (FIX 8).
    function recordDeposit(address user, uint256 amount) external onlyOperatorOrAdmin whenNotAbandoned {
        require(user != address(0), "Invalid user");
        require(amount > 0, "Zero amount");
        require(
            totalUserBalances + amount <= token.balanceOf(address(this)),
            "Exceeds vault solvency"
        );

        userBalances[user] += amount;
        totalUserBalances += amount;
        principalOf[user] += amount; // FIX 9: Real deposit builds principal

        emit Deposit(user, amount);
        emit BalanceIncreased(user, amount, userBalances[user]);
    }

    /// @notice Increase a user's balance (operator-assigned, e.g. rewards). Enforces solvency (FIX 8).
    /// @dev Does NOT increase principalOf — operator-assigned balance has no emergency claim.
    function increaseBalance(address user, uint256 amount) external onlyOperatorOrAdmin whenNotAbandoned {
        require(user != address(0), "Invalid user");
        require(amount > 0, "Zero amount");
        require(
            totalUserBalances + amount <= token.balanceOf(address(this)),
            "Exceeds vault solvency"
        );

        userBalances[user] += amount;
        totalUserBalances += amount;
        // No principalOf increase — operator-assigned only

        emit BalanceIncreased(user, amount, userBalances[user]);
    }

    /// @notice Decrease a user's balance. Pause-gated (FIX 4).
    function decreaseBalance(address user, uint256 amount) external onlyOperatorOrAdmin whenNotPaused whenNotAbandoned {
        require(userBalances[user] >= amount, "Insufficient user balance");

        userBalances[user] -= amount;
        totalUserBalances -= amount;
        // No principalOf decrease — preserves user's emergency claim

        emit BalanceDecreased(user, amount, userBalances[user]);
    }

    /// @notice Atomic balance transfer between two users (rewards/rebalancing).
    /// @dev Does NOT change totalUserBalances or principalOf — use for non-P2P movements.
    ///      For P2P trade settlement use settleTransfer (which also moves principal).
    function transferBalance(address from, address to, uint256 amount) external onlyOperatorOrAdmin whenNotPaused whenNotAbandoned {
        require(from != address(0), "Invalid from address");
        require(to != address(0), "Invalid to address");
        require(amount > 0, "Zero amount");
        require(userBalances[from] >= amount, "Insufficient sender balance");

        userBalances[from] -= amount;
        userBalances[to] += amount;
        // principalOf unchanged for both — use settleTransfer for P2P trades

        emit BalanceDecreased(from, amount, userBalances[from]);
        emit BalanceIncreased(to, amount, userBalances[to]);
        emit BalanceTransferred(from, to, amount);
    }

    // ═══════════════════════════════════════════════════════════════════
    // P2P SETTLEMENT (V3) — MOVES BALANCE *AND* PRINCIPAL
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Settle a P2P trade: move balance AND principal from seller to buyer.
    /// @dev Principal moved = min(amount, principalOf[from]). Conserves TOTAL principal —
    ///      no new emergency claims are created. The buyer inherits the seller's
    ///      emergency-withdrawal rights for the transferred (principal-backed) amount.
    ///      totalUserBalances is unchanged (internal transfer), so solvency is preserved.
    ///      When called by the operator (not admin) and dailySettlePrincipalLimit != 0,
    ///      the cumulative principal moved this UTC day is capped by the limit.
    /// @param from   Seller's receive wallet address
    /// @param to     Buyer's receive wallet address
    /// @param amount Token amount being settled
    function settleTransfer(address from, address to, uint256 amount)
        external
        onlyOperatorOrAdmin
        whenNotPaused
        whenNotAbandoned
    {
        _settleTransfer(from, to, amount);
    }

    /// @notice Batch P2P settlement for the periodic sync job. One tx, many trades.
    /// @dev ATOMIC: reverts the ENTIRE batch if any single settlement is invalid, or if
    ///      the operator's cumulative daily principal cap would be exceeded mid-batch.
    ///      The sync job is expected to pre-validate off-chain; a revert is a signal, not
    ///      a silent skip.
    function batchSettleTransfer(
        address[] calldata from,
        address[] calldata to,
        uint256[] calldata amounts
    )
        external
        onlyOperatorOrAdmin
        whenNotPaused
        whenNotAbandoned
    {
        require(from.length == to.length && to.length == amounts.length, "Length mismatch");
        require(from.length <= MAX_BATCH, "Batch too large");
        for (uint256 i = 0; i < from.length; i++) {
            _settleTransfer(from[i], to[i], amounts[i]);
        }
    }

    /// @dev Shared settlement logic. Outer modifiers (role/pause/abandon) are enforced once
    ///      by the external wrappers; per-entry validation + the daily principal cap run here.
    function _settleTransfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "Invalid from address");
        require(to != address(0), "Invalid to address");
        require(from != to, "Self settle");
        require(amount > 0, "Zero amount");
        require(userBalances[from] >= amount, "Insufficient sender balance");

        // Move balance (internal transfer — totalUserBalances unchanged).
        userBalances[from] -= amount;
        userBalances[to] += amount;

        // Move principal, capped at the seller's available principal.
        // CONSERVATION: principalMoved is subtracted from \`from\` and added to \`to\`,
        // so sum(principalOf) is invariant. principalMoved <= principalOf[from], so
        // no underflow and no creation of principal.
        uint256 pFrom = principalOf[from];
        uint256 principalMoved = amount < pFrom ? amount : pFrom; // min(amount, principalOf[from])
        if (principalMoved > 0) {
            // V3.1: enforce the operator's daily principal-movement cap (admin exempt;
            // limit == 0 means unlimited, so the default path is unchanged).
            if (dailySettlePrincipalLimit != 0 && msg.sender == operator && msg.sender != admin) {
                _resetSettleAllowance();
                require(
                    settledPrincipalToday + principalMoved <= dailySettlePrincipalLimit,
                    "Exceeds daily settle allowance"
                );
                settledPrincipalToday += principalMoved;
            }
            principalOf[from] = pFrom - principalMoved;
            principalOf[to] += principalMoved;
        }

        emit BalanceDecreased(from, amount, userBalances[from]);
        emit BalanceIncreased(to, amount, userBalances[to]);
        emit SettleTransfer(from, to, amount, principalMoved);
    }

    // ═══════════════════════════════════════════════════════════════════
    // EMERGENCY WITHDRAWAL (DEAD-MAN'S SWITCH ACTIVATED) — UNCHANGED FROM V2.9
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Users can withdraw up to their PRINCIPAL if vault is abandoned.
    /// @dev FIX 9: Emergency claim = min(balance, principal, available). Reads ONLY
    ///      on-chain state — no Merkle proof or off-chain data required.
    function emergencyWithdraw() external {
        require(isAbandoned(), "Vault is not abandoned");

        uint256 bal = userBalances[msg.sender];
        uint256 prin = principalOf[msg.sender];
        uint256 claim = bal < prin ? bal : prin;
        require(claim > 0, "No principal claim");

        uint256 available = token.balanceOf(address(this));
        uint256 withdrawAmount = claim < available ? claim : available;

        require(withdrawAmount > 0, "Vault is empty, try again later");

        userBalances[msg.sender] -= withdrawAmount;
        totalUserBalances -= withdrawAmount;
        principalOf[msg.sender] -= withdrawAmount;

        Address.functionCall(
            address(token),
            abi.encodeWithSelector(token.transfer.selector, msg.sender, withdrawAmount)
        );

        emit EmergencyWithdrawal(msg.sender, withdrawAmount);
    }

    // ═══════════════════════════════════════════════════════════════════
    // BALANCE SEEDING (ONE-TIME MIGRATION FROM V1 / V2.9)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Seed userBalances + principalOf from prior-vault state. Admin only, pre-finalize.
    /// @dev For V2.9 -> V3 migration: seed each user with their V2.9 PRINCIPAL (= min(balance,
    ///      principal)); top up the non-principal remainder afterwards via increaseBalance.
    function seedBalances(address[] calldata users, uint256[] calldata amounts) external onlyAdmin {
        require(!seedingComplete, "Seeding already complete");
        require(users.length == amounts.length, "Length mismatch");
        require(users.length <= MAX_BATCH, "Batch too large");

        for (uint256 i = 0; i < users.length; i++) {
            require(users[i] != address(0), "Invalid address");
            userBalances[users[i]] += amounts[i];
            totalUserBalances += amounts[i];
            principalOf[users[i]] += amounts[i]; // FIX 9: Seeded = principal
        }
    }

    function finalizeSeed() external onlyAdmin {
        require(!seedingComplete, "Already finalized");
        require(
            totalUserBalances <= token.balanceOf(address(this)),
            "Insolvent: recorded balances exceed vault holdings"
        );
        seedingComplete = true;
        emit SeedingCompleted(totalUserBalances, 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // ADMIN SETTERS (FROZEN WHEN ABANDONED)
    // ═══════════════════════════════════════════════════════════════════

    function setAdmin(address newAdmin) external onlyAdmin whenNotAbandoned {
        require(newAdmin != address(0), "Invalid address");
        emit AdminChanged(admin, newAdmin);
        admin = newAdmin;
    }

    function setOperator(address newOperator) external onlyAdmin whenNotAbandoned {
        require(newOperator != address(0), "Invalid address");
        emit OperatorChanged(operator, newOperator);
        operator = newOperator;
    }

    function setGuardian(address newGuardian) external onlyAdmin whenNotAbandoned {
        require(newGuardian != address(0), "Invalid address");
        emit GuardianChanged(guardian, newGuardian);
        guardian = newGuardian;
    }

    function setDailyLimit(uint256 newLimit) external onlyAdmin whenNotAbandoned {
        emit DailyLimitChanged(dailyLimit, newLimit);
        dailyLimit = newLimit;
    }

    /// @notice Set the operator's daily principal-movement cap for settleTransfer.
    /// @dev 0 == unlimited (disabled). Admin is always exempt from the cap.
    function setDailySettlePrincipalLimit(uint256 newLimit) external onlyAdmin whenNotAbandoned {
        emit DailySettlePrincipalLimitChanged(dailySettlePrincipalLimit, newLimit);
        dailySettlePrincipalLimit = newLimit;
    }

    function setMaxPauseDuration(uint256 newDuration) external onlyAdmin whenNotAbandoned {
        require(newDuration > 0, "Duration must be > 0");
        require(newDuration <= MAX_PAUSE_DURATION_CAP, "Exceeds max pause cap");
        emit MaxPauseDurationChanged(maxPauseDuration, newDuration);
        maxPauseDuration = newDuration;
    }

    // ═══════════════════════════════════════════════════════════════════
    // PAUSE / UNPAUSE (BOUNDED — SNAPSHOTTED EXPIRY)
    // ═══════════════════════════════════════════════════════════════════

    function pause() external onlyGuardian {
        _advancePauseExpiry();

        require(
            lastPauseExpiredAt == 0 || block.timestamp >= lastPauseExpiredAt + REPAUSE_COOLDOWN,
            "Re-pause cooldown active"
        );

        paused = true;
        pauseExpiresAt = block.timestamp + maxPauseDuration;
        emit Paused(msg.sender, pauseExpiresAt);
    }

    function unpause() external onlyGuardian {
        paused = false;
        lastPauseExpiredAt = block.timestamp;
        pauseExpiresAt = 0;
        emit Unpaused(msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════

    function _resetDailyAllowance() internal {
        uint256 currentDay = block.timestamp / 1 days;
        if (currentDay > lastResetDay) {
            lastResetDay = currentDay;
            spentToday = 0;
        }
    }

    function _resetSettleAllowance() internal {
        uint256 currentDay = block.timestamp / 1 days;
        if (currentDay > lastSettleResetDay) {
            lastSettleResetDay = currentDay;
            settledPrincipalToday = 0;
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

