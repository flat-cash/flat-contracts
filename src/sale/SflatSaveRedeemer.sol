// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Minimal} from "../../interfaces/IERC20Minimal.sol";
import {ISflatVault} from "../../interfaces/ISflatVault.sol";
import {IFlatPriceSource} from "../../interfaces/IFlatPriceSource.sol";

/// @title SflatSaveRedeemer
/// @notice Oracle-priced exit router letting sFLAT holders redeem vault shares for SAVE
///         instead of FLAT. The router redeems the shares at the sFLAT vault for FLAT,
///         values that FLAT at the FlatSaleV6 CPI oracle price, and pays out SAVE from a
///         protocol-funded inventory at an owner-maintained SAVE/USD rate. All FLAT
///         proceeds are forwarded to the protocol Safe.
///
///         Design invariants (mirrors FlatSaleV6):
///           - No DEX interaction of any kind. Pricing is purely oracle-based, so the
///             distorted thin FLAT/WETH pool cannot affect the conversion rate.
///           - Exact-delta checks on every token movement; fee-on-transfer or
///             non-standard ERC-20 behaviour reverts rather than being absorbed.
///           - The router never holds user funds at rest: sFLAT is burned by the vault
///             redeem in the same transaction, FLAT leaves to the Safe in the same
///             transaction, SAVE leaves to the user in the same transaction.
///           - Starts paused. Unpause requires the owner and never happens implicitly.
///           - Damage from a misconfigured SAVE rate is bounded by the immutable
///             per-transaction and per-window SAVE caps and by the funded inventory.
contract SflatSaveRedeemer {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error ContractPaused();
    error ContractNotPaused();
    error NotOwner();
    error NotPendingOwner();
    error OwnershipTransferRestricted();
    error RenounceDisabled();
    error Reentrancy();
    error DeadlineExpired();
    error InvalidRate();
    error StaleRate();
    error FlatPriceOutOfBounds();
    error SlippageExceeded();
    error PerTxCapExceeded();
    error WindowCapExceeded();
    error InventoryExceeded();
    error DeltaMismatch();
    error TransferFailed();
    error CapOutOfBounds();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event Redeemed(
        address indexed user,
        uint256 sharesIn,
        uint256 flatOut,
        uint256 saveOut,
        uint256 flatPriceUsd,
        uint256 saveUsdRate
    );
    event SaveUsdRateUpdated(uint256 oldRate, uint256 newRate, uint256 updatedAt);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event Recovered(address indexed token, uint256 amount);
    event RecoveredETH(uint256 amount);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ---------------------------------------------------------------------
    // Constants and immutables
    // ---------------------------------------------------------------------

    /// @notice Initial owner. Mirrors FlatSaleV6: deployment is performed by the
    ///         relayer, control starts with the operator EOA, and ownership is then
    ///         transferred (two-step) to the protocol Safe.
    address public constant INITIAL_OWNER = 0xdDf493752E2578f64dd78249D846E3C87A6936bC;

    uint256 internal constant REENTRANCY_NOT_ENTERED = 1;
    uint256 internal constant REENTRANCY_ENTERED = 2;

    /// @dev Bounds for the owner-maintained SAVE/USD rate (18 decimals).
    uint256 public constant MIN_SAVE_USD_RATE = 0.25e18;
    uint256 public constant MAX_SAVE_USD_RATE = 4e18;

    /// @dev Bounds applied to the V6 FLAT/USD oracle read (18 decimals).
    uint256 public constant MIN_FLAT_USD = 0.5e18;
    uint256 public constant MAX_FLAT_USD = 3e18;

    /// @dev SAVE/USD rate must be refreshed at least this often or redemption reverts.
    uint256 public constant RATE_STALENESS_SECONDS = 86400;

    /// @dev Rolling window length for the SAVE outflow cap.
    uint256 public constant WINDOW_SECONDS = 86400;

    /// @dev Hard ceilings for the constructor-supplied caps.
    uint256 public constant MAX_SAVE_PER_TX_CEILING = 100_000e18;
    uint256 public constant MAX_SAVE_PER_WINDOW_CEILING = 500_000e18;

    IERC20Minimal public immutable sflat;
    IERC20Minimal public immutable flat;
    IERC20Minimal public immutable save;
    ISflatVault public immutable vault;
    IFlatPriceSource public immutable priceSource;
    address public immutable protocolSafe;

    /// @dev Immutable outflow caps (damage bound for a bad rate, not a fair-value tool).
    uint256 public immutable maxSavePerTx;
    uint256 public immutable maxSavePerWindow;

    // ---------------------------------------------------------------------
    // Mutable state
    // ---------------------------------------------------------------------

    address public owner;
    address public pendingOwner;
    bool public paused;
    uint256 internal reentrancyStatus;

    /// @dev SAVE/USD rate, 18 decimals, maintained by the owner.
    uint256 public saveUsdRate;
    uint256 public rateUpdatedAt;

    /// @dev Rolling-window outflow accounting.
    uint256 public windowStart;
    uint256 public windowUsed;

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier whenPaused() {
        if (!paused) revert ContractNotPaused();
        _;
    }

    modifier nonReentrant() {
        if (reentrancyStatus == REENTRANCY_ENTERED) revert Reentrancy();
        reentrancyStatus = REENTRANCY_ENTERED;
        _;
        reentrancyStatus = REENTRANCY_NOT_ENTERED;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @param sflatToken          sFLAT vault share token.
    /// @param flatToken           FLAT (vault underlying).
    /// @param saveToken           SAVE (payout token).
    /// @param sflatVault          sFLAT vault (ERC-4626 style redeem).
    /// @param flatPriceSource     FlatSaleV6 (CPI price authority).
    /// @param safe                Protocol Safe: receives FLAT proceeds, is the only
    ///                            allowed ownership-transfer target and recovery sink.
    /// @param initialSaveUsdRate  Initial SAVE/USD rate (18 decimals), within bounds.
    /// @param maxSavePerTx_       Per-transaction SAVE outflow cap (<= ceiling).
    /// @param maxSavePerWindow_   Per-window SAVE outflow cap (<= ceiling).
    constructor(
        address sflatToken,
        address flatToken,
        address saveToken,
        address sflatVault,
        address flatPriceSource,
        address safe,
        uint256 initialSaveUsdRate,
        uint256 maxSavePerTx_,
        uint256 maxSavePerWindow_
    ) {
        if (
            sflatToken == address(0) || flatToken == address(0) || saveToken == address(0)
                || sflatVault == address(0) || flatPriceSource == address(0) || safe == address(0)
        ) revert ZeroAddress();
        if (initialSaveUsdRate < MIN_SAVE_USD_RATE || initialSaveUsdRate > MAX_SAVE_USD_RATE) {
            revert InvalidRate();
        }
        if (maxSavePerTx_ == 0 || maxSavePerTx_ > MAX_SAVE_PER_TX_CEILING) revert CapOutOfBounds();
        if (maxSavePerWindow_ == 0 || maxSavePerWindow_ > MAX_SAVE_PER_WINDOW_CEILING) revert CapOutOfBounds();
        if (maxSavePerWindow_ < maxSavePerTx_) revert CapOutOfBounds();

        sflat = IERC20Minimal(sflatToken);
        flat = IERC20Minimal(flatToken);
        save = IERC20Minimal(saveToken);
        vault = ISflatVault(sflatVault);
        priceSource = IFlatPriceSource(flatPriceSource);
        protocolSafe = safe;
        maxSavePerTx = maxSavePerTx_;
        maxSavePerWindow = maxSavePerWindow_;

        saveUsdRate = initialSaveUsdRate;
        rateUpdatedAt = block.timestamp;
        windowStart = block.timestamp;

        owner = INITIAL_OWNER;
        paused = true; // starts paused; owner unpauses explicitly after funding + checks
        reentrancyStatus = REENTRANCY_NOT_ENTERED;

        emit OwnershipTransferred(address(0), INITIAL_OWNER);
        emit Paused(address(0));
    }

    // ---------------------------------------------------------------------
    // Ownership (two-step; restricted to the Safe; renounce disabled)
    // ---------------------------------------------------------------------

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner != protocolSafe) revert OwnershipTransferRestricted();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address oldOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, msg.sender);
    }

    function renounceOwnership() external pure {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------------
    // User flow: sFLAT -> SAVE
    // ---------------------------------------------------------------------

    /// @notice Redeem `shares` of sFLAT for SAVE at the V6 oracle FLAT price and the
    ///         current owner-maintained SAVE rate. The user must have approved this
    ///         router to spend the shares.
    /// @param shares      Amount of sFLAT shares to redeem.
    /// @param minSaveOut  Minimum SAVE the user is willing to accept (rate-update
    ///                    and quote-race protection).
    /// @param deadline    Unix timestamp after which the transaction reverts.
    function redeemToSave(uint256 shares, uint256 minSaveOut, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (shares == 0) revert ZeroAmount();

        // --- pricing (both reads validated) ---
        uint256 flatPrice = priceSource.getFlatPriceUSD();
        if (flatPrice < MIN_FLAT_USD || flatPrice > MAX_FLAT_USD) revert FlatPriceOutOfBounds();
        uint256 saveRate = saveUsdRate;
        if (saveRate < MIN_SAVE_USD_RATE || saveRate > MAX_SAVE_USD_RATE) revert InvalidRate();
        if (block.timestamp - rateUpdatedAt > RATE_STALENESS_SECONDS) revert StaleRate();

        // --- pull sFLAT from the user (exact delta) ---
        uint256 sflatBefore = sflat.balanceOf(address(this));
        _callTransferFrom(address(sflat), msg.sender, address(this), shares);
        if (sflat.balanceOf(address(this)) - sflatBefore != shares) revert DeltaMismatch();

        // --- redeem at the vault: sFLAT burned, FLAT received (exact delta) ---
        uint256 flatBefore = flat.balanceOf(address(this));
        uint256 flatOut = vault.redeem(shares, address(this), address(this));
        if (flat.balanceOf(address(this)) - flatBefore != flatOut) revert DeltaMismatch();
        if (flatOut == 0) revert ZeroAmount();

        // --- value FLAT in SAVE ---
        uint256 saveOut = (flatOut * flatPrice) / saveRate;
        if (saveOut == 0) revert ZeroAmount();
        if (saveOut < minSaveOut) revert SlippageExceeded();
        if (saveOut > maxSavePerTx) revert PerTxCapExceeded();

        // --- rolling window cap ---
        if (block.timestamp >= windowStart + WINDOW_SECONDS) {
            windowStart = block.timestamp;
            windowUsed = 0;
        }
        if (windowUsed + saveOut > maxSavePerWindow) revert WindowCapExceeded();
        windowUsed += saveOut;

        // --- pay SAVE from inventory (exact delta on both sides) ---
        uint256 saveBefore = save.balanceOf(address(this));
        if (saveBefore < saveOut) revert InventoryExceeded();
        uint256 userSaveBefore = save.balanceOf(msg.sender);
        _callTransfer(address(save), msg.sender, saveOut);
        if (save.balanceOf(address(this)) != saveBefore - saveOut) revert DeltaMismatch();
        if (save.balanceOf(msg.sender) - userSaveBefore != saveOut) revert DeltaMismatch();

        // --- forward all FLAT proceeds to the Safe (exact delta on both sides) ---
        uint256 safeFlatBefore = flat.balanceOf(protocolSafe);
        _callTransfer(address(flat), protocolSafe, flatOut);
        if (flat.balanceOf(protocolSafe) - safeFlatBefore != flatOut) revert DeltaMismatch();
        if (flat.balanceOf(address(this)) != flatBefore) revert DeltaMismatch();

        emit Redeemed(msg.sender, shares, flatOut, saveOut, flatPrice, saveRate);
    }

    /// @notice Quote helper for the frontend: expected FLAT/SAVE out for `shares` sFLAT
    ///         at current rates. Applies the same pricing guards as redeemToSave.
    function previewRedeemToSave(uint256 shares) external view returns (uint256 saveOut, uint256 flatOut) {
        uint256 flatPrice = priceSource.getFlatPriceUSD();
        if (flatPrice < MIN_FLAT_USD || flatPrice > MAX_FLAT_USD) revert FlatPriceOutOfBounds();
        uint256 saveRate = saveUsdRate;
        if (saveRate < MIN_SAVE_USD_RATE || saveRate > MAX_SAVE_USD_RATE) revert InvalidRate();
        if (block.timestamp - rateUpdatedAt > RATE_STALENESS_SECONDS) revert StaleRate();
        flatOut = vault.previewRedeem(shares);
        saveOut = (flatOut * flatPrice) / saveRate;
    }

    // ---------------------------------------------------------------------
    // Owner / Safe administration
    // ---------------------------------------------------------------------

    /// @notice Update the SAVE/USD rate. Bounded, and stamps the freshness clock.
    function setSaveUsdRate(uint256 newRate) external onlyOwner {
        if (newRate < MIN_SAVE_USD_RATE || newRate > MAX_SAVE_USD_RATE) revert InvalidRate();
        uint256 old = saveUsdRate;
        saveUsdRate = newRate;
        rateUpdatedAt = block.timestamp;
        emit SaveUsdRateUpdated(old, newRate, block.timestamp);
    }

    function pause() external onlyOwner {
        if (paused) return;
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        if (!paused) return;
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Recover any stuck token (including SAVE inventory, sFLAT, FLAT) to the
    ///         Safe. Paused-only, Safe-only destination.
    function recoverToken(address token, uint256 amount) external onlyOwner whenPaused {
        if (token == address(0)) revert ZeroAddress();
        _callTransfer(token, protocolSafe, amount);
        emit Recovered(token, amount);
    }

    /// @notice Recover forced ETH (selfdestruct / coinbase) to the Safe. Paused-only.
    function recoverETH() external onlyOwner whenPaused {
        uint256 bal = address(this).balance;
        if (bal == 0) revert ZeroAmount();
        (bool ok,) = protocolSafe.call{value: bal}("");
        if (!ok) revert TransferFailed();
        emit RecoveredETH(bal);
    }

    // ---------------------------------------------------------------------
    // Internal ERC-20 plumbing (return-data tolerant, exact-delta enforced by callers)
    // ---------------------------------------------------------------------

    function _callTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _callTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
