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
 *      LESSONS FROM V3, FIXED HERE:
 *      1. HEARTBEAT REDUNDANCY — heartbeat() is callable by admin, operator, OR guardian
 *         (Safe). Abandonment now requires every keyholder to walk away, which is exactly
 *         when the abandoned-state protections should engage.
 *      2. ABANDONMENT IS SURVIVABLE — emergencyWithdraw(token) is permissionless and works
 *         forever (reads only on-chain state). After abandonment + RECOVERY_TIMELOCK the
 *         guardian may recoverSurplus(token) capped at (vault balance - totalUserBalances),
 *         so user claims are structurally untouchable. A ONE-TIME revive() (7-day public
 *         timelock) lets the Safe resurrect an accidentally-bricked vault; it can never
 *         be used twice.
 *      3. PER-LANE CAPS — V3's daily withdrawal cap and operator daily principal-movement
 *         cap are retained unchanged in structure, but applied PER LANE so a busy savings
 *         day cannot starve checking settlements.
 *      4. sFLAT LANE HOLDS REAL SHARES — the vault holds actual ERC-4626 shares of the
 *         sFLAT vault, so savings claims are backed on-chain (not a ledger promise) and
 *         yield accrues to users. convertFlatToSflat / convertSflatToFlat settle
 *         atomically through the live sFLAT vault.
 *
 *      CUSTODIAL BY DESIGN: the admin (Ledger cold wallet) has full control. That is
 *      intentional and is not a vulnerability. The security model defends against a
 *      compromised OPERATOR, and against admin/operator disappearance.
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
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
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

contract FlatIDVaultV4 {
    // ═══════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════

    uint256 public constant MIN_HEARTBEAT_INTERVAL = 7 days;
    uint256 public constant MAX_PAUSE_DURATION_CAP = 30 days;
    uint256 public constant REPAUSE_COOLDOWN = 7 days;
    uint256 public constant MAX_BATCH = 200;
    uint256 public constant RECOVERY_TIMELOCK = 30 days; // after abandonment, before recoverSurplus
    uint256 public constant REVIVE_TIMELOCK = 7 days;    // public delay on the one-time revive

    // ═══════════════════════════════════════════════════════════════════
    // STATE VARIABLES
    // ═══════════════════════════════════════════════════════════════════

    address public admin;
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
    uint256 public heartbeatInterval;

    bool public seedingComplete;

    bool public revived;       // one-time revive spent
    uint256 public reviveEta;  // set by queueRevive()

    uint256 private _reentrancyLock; // 1 == unlocked, 2 == locked

    struct Lane {
        uint256 totalUserBalances;        // solvency denominator for this token
        uint256 dailyWithdrawLimit;       // operator daily withdrawal cap (0 == unlimited)
        uint256 lastWithdrawResetDay;
        uint256 withdrawnToday;
        uint256 dailySettlePrincipalLimit; // operator daily principal-movement cap (0 == unlimited)
        uint256 lastSettleResetDay;
        uint256 settledPrincipalToday;
    }

    mapping(address => Lane) public lanes;                        // token => lane
    mapping(address => mapping(address => uint256)) public userBalances; // token => user => balance
    mapping(address => mapping(address => uint256)) public principalOf;  // token => user => principal

    // ═══════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════

    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);
    event OperatorChanged(address indexed oldOperator, address indexed newOperator);
    event GuardianChanged(address indexed oldGuardian, address indexed newGuardian);
    event SflatVaultChanged(address indexed oldVault, address indexed newVault);
    event Heartbeat(address indexed caller, uint256 timestamp);
    event HeartbeatIntervalChanged(uint256 oldInterval, uint256 newInterval);
    event Paused(address indexed by, uint256 expiresAt);
    event Unpaused(address indexed by);
    event MaxPauseDurationChanged(uint256 oldDuration, uint256 newDuration);

    event LaneWithdrawLimitChanged(address indexed token, uint256 oldLimit, uint256 newLimit);
    event LaneSettlePrincipalLimitChanged(address indexed token, uint256 oldLimit, uint256 newLimit);

    event Deposit(address indexed token, address indexed user, uint256 amount);
    event BalanceIncreased(address indexed token, address indexed user, uint256 amount, uint256 newBalance);
    event BalanceDecreased(address indexed token, address indexed user, uint256 amount, uint256 newBalance);
    event Withdrawal(address indexed token, address indexed to, uint256 amount, address indexed calledBy);
    event SettleTransfer(address indexed token, address indexed from, address indexed to, uint256 amount, uint256 principalMoved);
    event Converted(address indexed user, address indexed fromToken, address indexed toToken, uint256 fromAmount, uint256 toAmount);

    event EmergencyWithdrawal(address indexed token, address indexed user, uint256 amount);
    event BalanceSeeded(address indexed token, address indexed user, uint256 amount);
    event SeedingCompleted();
    event SurplusRecovered(address indexed token, uint256 amount);
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

    modifier onlyHeartbeatCaller() {
        require(
            msg.sender == admin || msg.sender == operator || msg.sender == guardian,
            "Not heartbeat caller"
        );
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

    constructor(
        address _flatToken,
        address _saveToken,
        address _sflatVault,
        address _admin,
        address _operator,
        address _guardian,
        uint256 _heartbeatInterval,
        uint256 _maxPauseDuration
    ) {
        require(_flatToken != address(0), "Invalid FLAT token");
        require(_saveToken != address(0), "Invalid SAVE token");
        require(_sflatVault != address(0), "Invalid sFLAT vault");
        require(_admin != address(0), "Invalid admin");
        require(_operator != address(0), "Invalid operator");
        require(_guardian != address(0), "Invalid guardian");
        require(_heartbeatInterval >= MIN_HEARTBEAT_INTERVAL, "Interval below minimum");
        require(_maxPauseDuration > 0, "Pause duration must be > 0");
        require(_maxPauseDuration <= MAX_PAUSE_DURATION_CAP, "Pause duration exceeds cap");

        flatToken = _flatToken;
        saveToken = _saveToken;
        sflatVault = _sflatVault;
        admin = _admin;
        operator = _operator;
        guardian = _guardian;
        heartbeatInterval = _heartbeatInterval;
        maxPauseDuration = _maxPauseDuration;
        lastHeartbeat = block.timestamp;
        paused = false;
        seedingComplete = false;
        revived = false;
        reviveEta = 0;
        _reentrancyLock = 1;
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
    /// @dev Returns type(uint256).max when the lane cap is disabled (limit == 0). Admin exempt.
    function remainingDailyWithdrawAllowance(address token) public view returns (uint256) {
        Lane storage l = lanes[token];
        if (l.dailyWithdrawLimit == 0) return type(uint256).max;
        if (block.timestamp / 1 days > l.lastWithdrawResetDay) return l.dailyWithdrawLimit;
        if (l.withdrawnToday >= l.dailyWithdrawLimit) return 0;
        return l.dailyWithdrawLimit - l.withdrawnToday;
    }

    /// @notice Remaining principal the OPERATOR may still move via settleTransfer in this lane today.
    /// @dev Returns type(uint256).max when disabled (limit == 0). Admin exempt.
    function remainingDailySettleAllowance(address token) public view returns (uint256) {
        Lane storage l = lanes[token];
        if (l.dailySettlePrincipalLimit == 0) return type(uint256).max;
        if (block.timestamp / 1 days > l.lastSettleResetDay) return l.dailySettlePrincipalLimit;
        if (l.settledPrincipalToday >= l.dailySettlePrincipalLimit) return 0;
        return l.dailySettlePrincipalLimit - l.settledPrincipalToday;
    }

    // ═══════════════════════════════════════════════════════════════════
    // HEARTBEAT — ADMIN OR OPERATOR OR GUARDIAN (V3 single-caller fix)
    // ═══════════════════════════════════════════════════════════════════

    function heartbeat() external onlyHeartbeatCaller {
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
    // OPERATOR/ADMIN LANE OPERATIONS (FROZEN WHEN ABANDONED/PAUSED)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Record a real deposit for a user. Builds principal. Enforces lane solvency.
    function recordDeposit(address token, address user, uint256 amount)
        external
        onlyOperatorOrAdmin
        whenNotAbandoned
    {
        require(_isLane(token), "Unknown lane");
        require(user != address(0), "Invalid user");
        require(amount > 0, "Zero amount");
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
    }

    /// @notice Increase a user's balance without principal (operator-assigned, e.g. rewards).
    function increaseBalance(address token, address user, uint256 amount)
        external
        onlyOperatorOrAdmin
        whenNotAbandoned
    {
        require(_isLane(token), "Unknown lane");
        require(user != address(0), "Invalid user");
        require(amount > 0, "Zero amount");
        Lane storage l = lanes[token];
        require(
            l.totalUserBalances + amount <= IERC20(token).balanceOf(address(this)),
            "Exceeds vault solvency"
        );

        userBalances[token][user] += amount;
        l.totalUserBalances += amount;

        emit BalanceIncreased(token, user, amount, userBalances[token][user]);
    }

    /// @notice Decrease a user's balance. Principal preserved (user keeps emergency claim).
    function decreaseBalance(address token, address user, uint256 amount)
        external
        onlyOperatorOrAdmin
        whenNotPaused
        whenNotAbandoned
    {
        require(_isLane(token), "Unknown lane");
        require(userBalances[token][user] >= amount, "Insufficient user balance");

        userBalances[token][user] -= amount;
        lanes[token].totalUserBalances -= amount;

        emit BalanceDecreased(token, user, amount, userBalances[token][user]);
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

        if (msg.sender == operator && msg.sender != admin) {
            _resetWithdrawAllowance(l);
            require(amount <= remainingDailyWithdrawAllowance(token), "Exceeds daily allowance");
            l.withdrawnToday += amount;
        }

        userBalances[token][to] -= amount;
        l.totalUserBalances -= amount;

        uint256 p = principalOf[token][to];
        principalOf[token][to] = amount >= p ? 0 : p - amount;

        emit BalanceDecreased(token, to, amount, userBalances[token][to]);

        Address.functionCall(
            token,
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );

        emit Withdrawal(token, to, amount, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════
    // P2P SETTLEMENT (PER LANE) — MOVES BALANCE *AND* PRINCIPAL
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Settle a P2P trade within a lane: move balance AND principal seller -> buyer.
    /// @dev Principal moved = min(amount, principalOf[from]). CONSERVES total principal.
    ///      Operator is subject to the lane's dailySettlePrincipalLimit; admin is exempt.
    function settleTransfer(address token, address from, address to, uint256 amount)
        external
        onlyOperatorOrAdmin
        whenNotPaused
        whenNotAbandoned
    {
        _settleTransfer(token, from, to, amount);
    }

    /// @notice Batch settlement. ATOMIC: any invalid entry reverts the entire batch.
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
    {
        require(from.length == to.length && to.length == amounts.length, "Length mismatch");
        require(from.length <= MAX_BATCH, "Batch too large");
        for (uint256 i = 0; i < from.length; i++) {
            _settleTransfer(token, from[i], to[i], amounts[i]);
        }
    }

    function _settleTransfer(address token, address from, address to, uint256 amount) internal {
        require(_isLane(token), "Unknown lane");
        require(from != address(0), "Invalid from address");
        require(to != address(0), "Invalid to address");
        require(from != to, "Self settle");
        require(amount > 0, "Zero amount");
        require(userBalances[token][from] >= amount, "Insufficient sender balance");

        userBalances[token][from] -= amount;
        userBalances[token][to] += amount;

        uint256 pFrom = principalOf[token][from];
        uint256 principalMoved = amount < pFrom ? amount : pFrom;
        if (principalMoved > 0) {
            Lane storage l = lanes[token];
            if (l.dailySettlePrincipalLimit != 0 && msg.sender == operator && msg.sender != admin) {
                _resetSettleAllowance(l);
                require(
                    l.settledPrincipalToday + principalMoved <= l.dailySettlePrincipalLimit,
                    "Exceeds daily settle allowance"
                );
                l.settledPrincipalToday += principalMoved;
            }
            principalOf[token][from] = pFrom - principalMoved;
            principalOf[token][to] += principalMoved;
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
    ///      credits the user with the REAL shares received. Share principal is fully backed.
    ///      Lane solvency holds throughout: FLAT claims drop by exactly the deposited amount,
    ///      share claims rise by exactly the shares received.
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

        // effects: debit FLAT lane
        userBalances[flatToken][user] -= flatAmount;
        lanes[flatToken].totalUserBalances -= flatAmount;
        uint256 pFrom = principalOf[flatToken][user];
        uint256 pMoved = flatAmount < pFrom ? flatAmount : pFrom;
        principalOf[flatToken][user] = pFrom - pMoved;

        // interaction: deposit into the live sFLAT vault (vault holds the shares)
        Address.functionCall(
            flatToken,
            abi.encodeWithSelector(IERC20.approve.selector, sflatVault, flatAmount)
        );
        shares = IERC4626(sflatVault).deposit(flatAmount, address(this));
        require(shares >= minSharesOut, "Slippage");

        // effects: credit sFLAT lane (principal fully backed by the shares received)
        userBalances[sflatVault][user] += shares;
        lanes[sflatVault].totalUserBalances += shares;
        principalOf[sflatVault][user] += shares;

        emit BalanceDecreased(flatToken, user, flatAmount, userBalances[flatToken][user]);
        emit BalanceIncreased(sflatVault, user, shares, userBalances[sflatVault][user]);
        emit Converted(user, flatToken, sflatVault, flatAmount, shares);
    }

    /// @notice Convert a user's sFLAT lane shares back into FLAT, atomically, at the
    ///         then-current ERC-4626 factor. User always receives >= the displayed ticker
    ///         value because the sFLAT rate ratchets upward only.
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

        // effects: debit sFLAT lane
        userBalances[sflatVault][user] -= shareAmount;
        lanes[sflatVault].totalUserBalances -= shareAmount;
        uint256 pFrom = principalOf[sflatVault][user];
        uint256 pMoved = shareAmount < pFrom ? shareAmount : pFrom;
        principalOf[sflatVault][user] = pFrom - pMoved;

        // interaction: redeem from the live sFLAT vault
        assets = IERC4626(sflatVault).redeem(shareAmount, address(this), address(this));
        require(assets >= minFlatOut, "Slippage");

        // effects: credit FLAT lane (principal fully backed by the FLAT received)
        userBalances[flatToken][user] += assets;
        lanes[flatToken].totalUserBalances += assets;
        principalOf[flatToken][user] += assets;

        emit BalanceDecreased(sflatVault, user, shareAmount, userBalances[sflatVault][user]);
        emit BalanceIncreased(flatToken, user, assets, userBalances[flatToken][user]);
        emit Converted(user, sflatVault, flatToken, shareAmount, assets);
    }

    // ═══════════════════════════════════════════════════════════════════
    // EMERGENCY WITHDRAWAL — PERMISSIONLESS, ONLY WHEN ABANDONED, ETERNAL
    // ═══════════════════════════════════════════════════════════════════

    /// @notice After abandonment, any user withdraws min(balance, principal, available)
    ///         in ANY lane. Reads ONLY on-chain state — no backend, no Merkle proof.
    ///         This function has no role gate and no pause gate, and cannot be disabled.
    function emergencyWithdraw(address token) external nonReentrant {
        require(_isLane(token), "Unknown lane");
        require(isAbandoned(), "Vault is not abandoned");

        uint256 bal = userBalances[token][msg.sender];
        uint256 prin = principalOf[token][msg.sender];
        uint256 claim = bal < prin ? bal : prin;
        require(claim > 0, "No principal claim");

        uint256 available = IERC20(token).balanceOf(address(this));
        uint256 withdrawAmount = claim < available ? claim : available;
        require(withdrawAmount > 0, "Vault is empty, try again later");

        userBalances[token][msg.sender] -= withdrawAmount;
        lanes[token].totalUserBalances -= withdrawAmount;
        principalOf[token][msg.sender] -= withdrawAmount;

        Address.functionCall(
            token,
            abi.encodeWithSelector(IERC20.transfer.selector, msg.sender, withdrawAmount)
        );

        emit EmergencyWithdrawal(token, msg.sender, withdrawAmount);
    }

    // ═══════════════════════════════════════════════════════════════════
    // ABANDONED-STATE RECOVERY (GUARDIAN / SAFE ONLY)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Recover surplus (vault balance MINUS user claims) to the guardian, only after
    ///         abandonment + RECOVERY_TIMELOCK. Structurally cannot touch user claims.
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

    /// @notice Queue the ONE-TIME revive. Starts the 7-day public timelock.
    function queueRevive() external onlyGuardian {
        require(isAbandoned(), "Not abandoned");
        require(!revived, "Revive already spent");
        require(reviveEta == 0, "Revive already queued");
        reviveEta = block.timestamp + REVIVE_TIMELOCK;
        emit ReviveQueued(reviveEta);
    }

    /// @notice Execute the queued revive after the timelock. Resets the heartbeat window.
    ///         One-time only — a second abandonment is final (recoverSurplus still works,
    ///         and emergencyWithdraw remains eternal).
    function revive() external onlyGuardian {
        require(isAbandoned(), "Not abandoned");
        require(!revived, "Revive already spent");
        require(reviveEta != 0, "Revive not queued");
        require(block.timestamp >= reviveEta, "Revive timelock active");

        revived = true;
        reviveEta = 0;
        lastHeartbeat = block.timestamp;
        emit Revived(msg.sender, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════
    // BALANCE SEEDING (ONE-TIME MIGRATION — HONORS LEGACY V3 / V2.9 CLAIMS)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Seed userBalances + principalOf from prior-vault state. Admin only, pre-finalize.
    ///         One event per account so the migration is auditable on Etherscan.
    ///         Legacy claims honored: 1,188.62 SAVE (V3 SAVE vault) + 49.03 FLAT (V2.9 vault).
    function seedBalances(address token, address[] calldata users, uint256[] calldata amounts)
        external
        onlyAdmin
    {
        require(_isLane(token), "Unknown lane");
        require(!seedingComplete, "Seeding already complete");
        require(users.length == amounts.length, "Length mismatch");
        require(users.length <= MAX_BATCH, "Batch too large");

        Lane storage l = lanes[token];
        for (uint256 i = 0; i < users.length; i++) {
            require(users[i] != address(0), "Invalid address");
            userBalances[token][users[i]] += amounts[i];
            l.totalUserBalances += amounts[i];
            principalOf[token][users[i]] += amounts[i];
            emit BalanceSeeded(token, users[i], amounts[i]);
        }
    }

    /// @notice Seal the seed. Reverts unless the vault actually holds the seeded tokens
    ///         for EVERY lane that has claims. After this, seedBalances is dead forever.
    function finalizeSeed() external onlyAdmin {
        require(!seedingComplete, "Already finalized");
        require(_solvent(flatToken), "FLAT lane underfunded");
        require(_solvent(saveToken), "SAVE lane underfunded");
        require(_solvent(sflatVault), "sFLAT lane underfunded");
        seedingComplete = true;
        emit SeedingCompleted();
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

    /// @notice Point the sFLAT lane at a new ERC-4626 vault (e.g. sFLAT upgrade).
    /// @dev The lane token key changes: existing share claims under the OLD vault address
    ///      must be migrated off-chain (convert all users to FLAT first, or re-seed).
    ///      Deploy-time value is correct; change only with a migration plan.
    function setSflatVault(address newVault) external onlyAdmin whenNotAbandoned {
        require(newVault != address(0), "Invalid vault");
        emit SflatVaultChanged(sflatVault, newVault);
        sflatVault = newVault;
    }

    /// @notice Set the operator's daily withdrawal cap for a lane. 0 == unlimited. Admin exempt.
    function setLaneWithdrawLimit(address token, uint256 newLimit) external onlyAdmin whenNotAbandoned {
        require(_isLane(token), "Unknown lane");
        emit LaneWithdrawLimitChanged(token, lanes[token].dailyWithdrawLimit, newLimit);
        lanes[token].dailyWithdrawLimit = newLimit;
    }

    /// @notice Set the operator's daily principal-movement cap for a lane. 0 == unlimited. Admin exempt.
    function setLaneSettlePrincipalLimit(address token, uint256 newLimit) external onlyAdmin whenNotAbandoned {
        require(_isLane(token), "Unknown lane");
        emit LaneSettlePrincipalLimitChanged(token, lanes[token].dailySettlePrincipalLimit, newLimit);
        lanes[token].dailySettlePrincipalLimit = newLimit;
    }

    function setMaxPauseDuration(uint256 newDuration) external onlyAdmin whenNotAbandoned {
        require(newDuration > 0, "Duration must be > 0");
        require(newDuration <= MAX_PAUSE_DURATION_CAP, "Exceeds max pause cap");
        emit MaxPauseDurationChanged(maxPauseDuration, newDuration);
        maxPauseDuration = newDuration;
    }

    // ═══════════════════════════════════════════════════════════════════
    // PAUSE / UNPAUSE (GUARDIAN — BOUNDED, SNAPSHOTTED EXPIRY, V3 SEMANTICS)
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

    function _isLane(address token) internal view returns (bool) {
        return token == flatToken || token == saveToken || token == sflatVault;
    }

    function _solvent(address token) internal view returns (bool) {
        return lanes[token].totalUserBalances <= IERC20(token).balanceOf(address(this));
    }

    function _resetWithdrawAllowance(Lane storage l) internal {
        uint256 currentDay = block.timestamp / 1 days;
        if (currentDay > l.lastWithdrawResetDay) {
            l.lastWithdrawResetDay = currentDay;
            l.withdrawnToday = 0;
        }
    }

    function _resetSettleAllowance(Lane storage l) internal {
        uint256 currentDay = block.timestamp / 1 days;
        if (currentDay > l.lastSettleResetDay) {
            l.lastSettleResetDay = currentDay;
            l.settledPrincipalToday = 0;
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
