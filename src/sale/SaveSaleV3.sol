// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
}

interface IUniswapV2Router02 {
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function WETH() external pure returns (address);
}

interface IFlatReserve {
    function reserveDeficiency() external view returns (uint256);
    function depositSaveLP(uint256 amount) external;
}

/// @title ISaveReceiver
/// @notice Callback interface for contracts receiving SAVE from SaveSale V3.
interface ISaveReceiver {
    /// @notice Called on the recipient after SAVE is transferred via buyTo().
    /// @param buyer  The original buyer who paid ETH
    /// @param amount The amount of SAVE received
    /// @param data   Arbitrary data passed by the buyer
    /// @return selector Must return ISaveReceiver.onSaveReceived.selector to confirm handling
    function onSaveReceived(
        address buyer,
        uint256 amount,
        bytes calldata data
    ) external returns (bytes4);
}

/// @title ISaveSaleV3
/// @notice Interface for SaveSale V3 — used for EIP-165 discoverability
interface ISaveSaleV3 {
    function buy(uint256 minSaveOut) external payable;
    function buyTo(address recipient, uint256 minSaveOut) external payable;
    function buyToWithCallback(address recipient, uint256 minSaveOut, bytes calldata data) external payable;
    function buyWithToken(address token, uint256 tokenAmount, uint256 minSaveOut, address recipient) external;
    function buyWithTokenPermit(
        address token, uint256 tokenAmount, uint256 minSaveOut, address recipient,
        uint256 deadline, uint8 v, bytes32 r, bytes32 s
    ) external;
    function buyBatch(address[] calldata recipients, uint256[] calldata ethAmounts, uint256 minSaveOutTotal) external payable;
}

/// @title SaveSale V3
/// @notice Composable public sale contract for SAVE token with FlatReserve integration.
///
///         CHANGES FROM V2:
///         ✅ 5-year guardian (extendable to 10yr max) — replaces 3-year
///         ✅ ALL operational parameters are guardian-configurable with immutable safety bounds
///         ✅ FlatReserve integration: LP tokens route to reserve when deficient, then treasury
///         ✅ Operations split configurable (500-2000 bps, default 1000 = 10%)
///         ✅ LP slippage configurable (10-500 bps, default 200 = 2%)
///         ✅ Min buy configurable (0.0001-1 ETH, default 0.001 ETH)
///         ✅ Guardian extension function (max 10 years from deployment)
///
///         UNCHANGED FROM V2:
///         - NAV-based pricing from Uniswap V2 pool reserves
///         - Composable buy functions: buy(), buyTo(), buyToWithCallback(), buyWithToken(),
///           buyWithTokenPermit(), buyBatch(), buyBatchWithReferral()
///         - receive() fallback auto-buy
///         - Daily cap, price band, max per tx (all guardian-configurable)
///         - Referral tracking via events
///         - EIP-165 interface discoverability
///         - Immutable after deployment (no proxy, no upgradability)
///
///         CROPS-compliant: Censorship Resistant, Capture Resistant, Open Source,
///         Private, Secure. Guardian pattern expires — contract becomes fully immutable.
///         No proxy, no upgrade, no blacklist, no freeze capability.
///
/// @dev    North Star: FLAT as global reserve currency. SAVE is the locked, yield-bearing
///         form of FLAT. Making SAVE easy to acquire from any source accelerates absorption.
///         Self-healing reserve: every buy automatically refills FlatReserve when deficient.
contract SaveSaleV3 is Ownable, ReentrancyGuard, ERC165 {
    using SafeERC20 for IERC20;

    // ============ IMMUTABLES ============
    IERC20 public immutable SAVE;
    IUniswapV2Router02 public immutable router;
    IUniswapV2Pair public immutable pair;
    bool public immutable saveIsToken0;
    address public immutable treasury;
    address public immutable WETH;
    uint256 public immutable deploymentTime;

    // ============ IMMUTABLE SAFETY BOUNDS (cannot be changed, ever) ============
    uint256 public constant GUARDIAN_DURATION = 1825 days;              // 5 years per extension
    uint256 public constant MAX_GUARDIAN_LIFETIME = 3650 days;          // 10 years absolute max
    uint256 public constant MAX_BATCH_SIZE = 100;                       // Max recipients per batch
    // Operations split bounds
    uint256 public constant MIN_OPS_BPS = 500;                          // Min 5% to operations
    uint256 public constant MAX_OPS_BPS = 2000;                         // Max 20% to operations
    // LP slippage bounds
    uint256 public constant MIN_LP_SLIPPAGE_BPS = 10;                   // 0.1% minimum
    uint256 public constant MAX_LP_SLIPPAGE_BPS = 500;                  // 5% maximum
    // Min buy bounds
    uint256 public constant MIN_BUY_FLOOR = 0.0001 ether;              // Absolute min (can't go lower)
    uint256 public constant MIN_BUY_CEILING = 1 ether;                  // Absolute max for min buy

    // ============ MUTABLE STATE (guardian-configurable) ============
    IFlatReserve public flatReserve;
    uint256 public operationsBps;                // Default 1000 = 10%
    uint256 public lpSlippageBps;                // Default 200 = 2%
    uint256 public minBuyETH;                    // Default 0.001 ether
    uint256 public dailyCap;
    uint256 public maxBuyPerTx;
    uint256 public minNAV;
    uint256 public maxNAV;
    bool public paused;
    uint256 public guardianExpiry;

    // Accounting
    uint256 public soldToday;
    uint256 public totalSold;
    uint256 public totalPOL;
    uint256 public totalReserveLP;               // Total LP tokens sent to FlatReserve
    uint256 public lastReset;

    // ============ EVENTS ============
    event Bought(
        address indexed buyer,
        address indexed recipient,
        uint256 saveAmount,
        uint256 ethPaid,
        uint256 polEth,
        uint256 reserveLP,
        uint256 treasuryLP,
        uint256 nav,
        bytes32 indexed referralCode
    );
    event BatchBought(
        address indexed buyer,
        uint256 totalSave,
        uint256 totalEthPaid,
        uint256 recipientCount,
        bytes32 indexed referralCode
    );
    event TokenSwapped(
        address indexed token,
        uint256 tokenAmount,
        uint256 ethReceived
    );
    event DailyCapReset(uint256 timestamp);
    event PriceBandUpdated(uint256 minNAV, uint256 maxNAV);
    event DailyCapUpdated(uint256 newCap);
    event MaxBuyPerTxUpdated(uint256 newMax);
    event OperationsBpsUpdated(uint256 oldBps, uint256 newBps);
    event LpSlippageUpdated(uint256 oldBps, uint256 newBps);
    event MinBuyUpdated(uint256 oldAmount, uint256 newAmount);
    event FlatReserveUpdated(address indexed oldReserve, address indexed newReserve);
    event GuardianExtended(uint256 oldExpiry, uint256 newExpiry);
    event Paused();
    event Unpaused();

    // ============ CONSTRUCTOR ============
    constructor(
        address _save,
        address _router,
        address _pair,
        address _treasury,
        uint256 _dailyCap,
        uint256 _minNAV,
        uint256 _maxNAV,
        uint256 _operationsBps,
        uint256 _lpSlippageBps,
        uint256 _minBuyETH
    ) Ownable(msg.sender) {
        require(_save != address(0), "invalid save");
        require(_router != address(0), "invalid router");
        require(_pair != address(0), "invalid pair");
        require(_treasury != address(0), "invalid treasury");
        require(_minNAV > 0 && _maxNAV > _minNAV, "invalid price band");
        require(_operationsBps >= MIN_OPS_BPS && _operationsBps <= MAX_OPS_BPS, "ops bps out of range");
        require(_lpSlippageBps >= MIN_LP_SLIPPAGE_BPS && _lpSlippageBps <= MAX_LP_SLIPPAGE_BPS, "slippage out of range");
        require(_minBuyETH >= MIN_BUY_FLOOR && _minBuyETH <= MIN_BUY_CEILING, "min buy out of range");

        SAVE = IERC20(_save);
        router = IUniswapV2Router02(_router);
        pair = IUniswapV2Pair(_pair);
        treasury = _treasury;
        // flatReserve set post-deployment via setFlatReserve()
        WETH = router.WETH();

        saveIsToken0 = (pair.token0() == _save);

        operationsBps = _operationsBps;
        lpSlippageBps = _lpSlippageBps;
        minBuyETH = _minBuyETH;
        dailyCap = _dailyCap;
        minNAV = _minNAV;
        maxNAV = _maxNAV;
        lastReset = block.timestamp;
        maxBuyPerTx = 0;

        deploymentTime = block.timestamp;
        guardianExpiry = block.timestamp + GUARDIAN_DURATION;
    }

    // ============ MODIFIERS ============
    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    modifier onlyGuardian() {
        require(msg.sender == owner(), "not owner");
        require(block.timestamp <= guardianExpiry, "guardian expired");
        _;
    }

    // ============ EIP-165 ============

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(ISaveSaleV3).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // ============ INTERNAL HELPERS ============

    /// @dev Get current NAV (ETH per SAVE) from V2 pool reserves
    function _getCurrentNAV() internal view returns (uint256 nav) {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        require(reserve0 > 0 && reserve1 > 0, "empty pool");
        if (saveIsToken0) {
            nav = (uint256(reserve1) * 1e18) / uint256(reserve0);
        } else {
            nav = (uint256(reserve0) * 1e18) / uint256(reserve1);
        }
    }

    /// @dev Core buy logic. Returns the amount of SAVE purchased.
    ///
    ///      ETH Flow:
    ///      1. operationsBps% → treasury (non-negotiable operations budget)
    ///      2. Remainder → paired with SAVE as Uniswap LP
    ///      3. LP routing: if FlatReserve is deficient → fill reserve first → remainder to treasury
    ///                     if FlatReserve is sufficient → all LP to treasury
    function _executeBuy(
        address recipient,
        uint256 ethAmount,
        uint256 minSaveOut,
        bytes32 referralCode
    ) internal returns (uint256 saveAmount) {
        require(ethAmount >= minBuyETH, "below minimum buy");
        require(recipient != address(0), "zero recipient");

        // Daily cap reset
        if (block.timestamp >= lastReset + 1 days) {
            soldToday = 0;
            lastReset = block.timestamp;
            emit DailyCapReset(block.timestamp);
        }

        // Get current NAV from pool
        uint256 nav = _getCurrentNAV();
        require(nav >= minNAV && nav <= maxNAV, "price outside band");

        // Calculate SAVE amount at exact NAV (1.0x, no premium)
        saveAmount = (ethAmount * 1e18) / nav;

        // Slippage protection
        require(saveAmount >= minSaveOut, "slippage: insufficient output");

        // Per-tx limit
        if (maxBuyPerTx > 0) {
            require(saveAmount <= maxBuyPerTx, "exceeds max per tx");
        }

        // Daily cap
        require(soldToday + saveAmount <= dailyCap, "daily cap exceeded");

        // Revenue split: operationsBps% to treasury, remainder to LP
        uint256 treasuryEth = (ethAmount * operationsBps) / 10000;
        uint256 polEth = ethAmount - treasuryEth;

        // Matching SAVE for liquidity
        uint256 polSave = (polEth * 1e18) / nav;

        // Inventory check
        uint256 totalSaveNeeded = saveAmount + polSave;
        require(SAVE.balanceOf(address(this)) >= totalSaveNeeded, "inventory too low");

        // Update state
        soldToday += saveAmount;
        totalSold += saveAmount;
        totalPOL += polEth;

        // Transfer SAVE to recipient
        SAVE.safeTransfer(recipient, saveAmount);

        // Add liquidity: remainder ETH + matching SAVE → V2 pool
        uint256 amountTokenMin = polSave * (10000 - lpSlippageBps) / 10000;
        uint256 amountETHMin = polEth * (10000 - lpSlippageBps) / 10000;
        SAVE.safeIncreaseAllowance(address(router), polSave);
        (, , uint256 liquidity) = router.addLiquidityETH{value: polEth}(
            address(SAVE),
            polSave,
            amountTokenMin,
            amountETHMin,
            address(this),  // LP tokens come to this contract for routing
            block.timestamp
        );

        // Distribute LP tokens: reserve first (if deficient), then treasury
        uint256 reserveLP = 0;
        uint256 treasuryLP = liquidity;

        if (address(flatReserve) != address(0)) {
            uint256 deficiency = flatReserve.reserveDeficiency();
            if (deficiency > 0) {
                // Route all LP to reserve when deficient
                reserveLP = liquidity;
                treasuryLP = 0;

                IERC20(address(pair)).safeIncreaseAllowance(address(flatReserve), reserveLP);
                flatReserve.depositSaveLP(reserveLP);
                totalReserveLP += reserveLP;
            }
        }

        // Send remaining LP to treasury
        if (treasuryLP > 0) {
            IERC20(address(pair)).safeTransfer(treasury, treasuryLP);
        }

        // Send operations ETH to treasury
        (bool success, ) = payable(treasury).call{value: treasuryEth}("");
        require(success, "treasury transfer failed");

        // Emit rich event
        emit Bought(
            msg.sender,
            recipient,
            saveAmount,
            ethAmount,
            polEth,
            reserveLP,
            treasuryLP,
            nav,
            referralCode
        );
    }

    // ============ PUBLIC BUY FUNCTIONS ============

    /// @notice Buy SAVE with ETH at exact NAV. Tokens sent to msg.sender.
    /// @param minSaveOut Minimum SAVE to receive (sandwich protection)
    function buy(uint256 minSaveOut) external payable nonReentrant whenNotPaused {
        _executeBuy(msg.sender, msg.value, minSaveOut, bytes32(0));
    }

    /// @notice Buy SAVE and send to a specified recipient.
    ///         Enables: router contracts, FlatID vaults, gifting, payroll.
    /// @param recipient Address to receive the SAVE tokens
    /// @param minSaveOut Minimum SAVE to receive (sandwich protection)
    function buyTo(
        address recipient,
        uint256 minSaveOut
    ) external payable nonReentrant whenNotPaused {
        _executeBuy(recipient, msg.value, minSaveOut, bytes32(0));
    }

    /// @notice Buy SAVE, send to recipient, and trigger callback if recipient is a contract.
    ///         Enables: auto-compounding vaults, DAO treasuries, automated strategies.
    /// @param recipient Address to receive the SAVE tokens (may be a contract)
    /// @param minSaveOut Minimum SAVE to receive (sandwich protection)
    /// @param data Arbitrary bytes passed to recipient's onSaveReceived callback
    function buyToWithCallback(
        address recipient,
        uint256 minSaveOut,
        bytes calldata data
    ) external payable nonReentrant whenNotPaused {
        uint256 saveAmount = _executeBuy(recipient, msg.value, minSaveOut, bytes32(0));

        // If recipient is a contract, notify it
        if (recipient.code.length > 0) {
            bytes4 retval = ISaveReceiver(recipient).onSaveReceived(msg.sender, saveAmount, data);
            require(retval == ISaveReceiver.onSaveReceived.selector, "callback rejected");
        }
    }

    /// @notice Buy SAVE with referral tracking.
    /// @param recipient Address to receive the SAVE tokens
    /// @param minSaveOut Minimum SAVE to receive
    /// @param referralCode 32-byte referral identifier
    function buyToWithReferral(
        address recipient,
        uint256 minSaveOut,
        bytes32 referralCode
    ) external payable nonReentrant whenNotPaused {
        _executeBuy(recipient, msg.value, minSaveOut, referralCode);
    }

    /// @notice Buy SAVE with any ERC-20 token. Token is swapped to ETH via Uniswap first.
    /// @param token The ERC-20 token to sell (must have a WETH pair on Uniswap)
    /// @param tokenAmount Amount of token to spend
    /// @param minSaveOut Minimum SAVE to receive (covers both swap + buy slippage)
    /// @param recipient Address to receive the SAVE tokens
    function buyWithToken(
        address token,
        uint256 tokenAmount,
        uint256 minSaveOut,
        address recipient
    ) external nonReentrant whenNotPaused {
        require(token != address(0), "invalid token");
        require(tokenAmount > 0, "zero amount");
        require(token != address(SAVE), "use buy() for ETH");

        // Pull tokens from caller
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        // Swap token → ETH via Uniswap
        uint256 ethBefore = address(this).balance;
        IERC20(token).safeIncreaseAllowance(address(router), tokenAmount);
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = WETH;
        router.swapExactTokensForETH(
            tokenAmount,
            0, // minOut handled by minSaveOut at the end
            path,
            address(this),
            block.timestamp
        );
        uint256 ethReceived = address(this).balance - ethBefore;
        require(ethReceived > 0, "swap returned zero ETH");

        emit TokenSwapped(token, tokenAmount, ethReceived);

        // Execute buy with the received ETH
        _executeBuy(recipient, ethReceived, minSaveOut, bytes32(0));
    }

    /// @notice Buy SAVE with any ERC-20 token using ERC-2612 Permit (gasless approval).
    function buyWithTokenPermit(
        address token,
        uint256 tokenAmount,
        uint256 minSaveOut,
        address recipient,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused {
        // Execute permit (gasless approval)
        IERC20Permit(token).permit(msg.sender, address(this), tokenAmount, deadline, v, r, s);

        // Pull tokens
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        // Swap token → ETH
        uint256 ethBefore = address(this).balance;
        IERC20(token).safeIncreaseAllowance(address(router), tokenAmount);
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = WETH;
        router.swapExactTokensForETH(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
        uint256 ethReceived = address(this).balance - ethBefore;
        require(ethReceived > 0, "swap returned zero ETH");

        emit TokenSwapped(token, tokenAmount, ethReceived);

        // Execute buy
        _executeBuy(recipient, ethReceived, minSaveOut, bytes32(0));
    }

    /// @notice Buy SAVE for multiple recipients in one transaction.
    ///         Enables: payroll, rewards distribution, institutional allocation.
    /// @param recipients Array of addresses to receive SAVE
    /// @param ethAmounts Array of ETH amounts to spend per recipient (must sum to msg.value)
    /// @param minSaveOutTotal Minimum total SAVE across all recipients
    function buyBatch(
        address[] calldata recipients,
        uint256[] calldata ethAmounts,
        uint256 minSaveOutTotal
    ) external payable nonReentrant whenNotPaused {
        require(recipients.length == ethAmounts.length, "length mismatch");
        require(recipients.length > 0 && recipients.length <= MAX_BATCH_SIZE, "invalid batch size");

        // Verify ETH amounts sum to msg.value
        uint256 totalEth;
        for (uint256 i = 0; i < ethAmounts.length; i++) {
            totalEth += ethAmounts[i];
        }
        require(totalEth == msg.value, "ETH sum mismatch");

        // Execute individual buys
        uint256 totalSave;
        for (uint256 i = 0; i < recipients.length; i++) {
            uint256 saveOut = _executeBuy(recipients[i], ethAmounts[i], 0, bytes32(0));
            totalSave += saveOut;
        }

        // Aggregate slippage check
        require(totalSave >= minSaveOutTotal, "batch slippage: insufficient total output");

        emit BatchBought(msg.sender, totalSave, msg.value, recipients.length, bytes32(0));
    }

    /// @notice Buy SAVE for multiple recipients with referral tracking.
    function buyBatchWithReferral(
        address[] calldata recipients,
        uint256[] calldata ethAmounts,
        uint256 minSaveOutTotal,
        bytes32 referralCode
    ) external payable nonReentrant whenNotPaused {
        require(recipients.length == ethAmounts.length, "length mismatch");
        require(recipients.length > 0 && recipients.length <= MAX_BATCH_SIZE, "invalid batch size");

        uint256 totalEth;
        for (uint256 i = 0; i < ethAmounts.length; i++) {
            totalEth += ethAmounts[i];
        }
        require(totalEth == msg.value, "ETH sum mismatch");

        uint256 totalSave;
        for (uint256 i = 0; i < recipients.length; i++) {
            uint256 saveOut = _executeBuy(recipients[i], ethAmounts[i], 0, referralCode);
            totalSave += saveOut;
        }

        require(totalSave >= minSaveOutTotal, "batch slippage: insufficient total output");

        emit BatchBought(msg.sender, totalSave, msg.value, recipients.length, referralCode);
    }

    // ============ RECEIVE: RAW ETH → AUTO-BUY ============

    /// @notice Accept raw ETH transfers and automatically buy SAVE for the sender.
    ///         Enables: simple "send ETH to this address, get SAVE" flow.
    ///         Works from any wallet, any exchange withdrawal, any contract.
    receive() external payable {
        // Skip if called by the router during LP creation (refund ETH)
        if (msg.sender == address(router)) return;
        // Skip if called by treasury
        if (msg.sender == treasury) return;
        // Skip tiny amounts (dust from router refunds)
        if (msg.value < minBuyETH) return;

        // Auto-buy with no slippage protection (use buy() for that)
        if (!paused) {
            _executeBuy(msg.sender, msg.value, 0, bytes32(0));
        }
    }

    // ============ VIEW FUNCTIONS ============

    /// @notice Get current NAV (ETH per SAVE) from V2 pool reserves
    function getCurrentNAV() public view returns (uint256) {
        return _getCurrentNAV();
    }

    /// @notice Check how much SAVE the contract currently holds for sale
    function availableInventory() external view returns (uint256) {
        return SAVE.balanceOf(address(this));
    }

    /// @notice Estimate SAVE output for a given ETH input at current NAV.
    /// @param ethAmount The ETH amount to quote
    /// @return saveAmount The estimated SAVE output (before daily cap check)
    function quote(uint256 ethAmount) external view returns (uint256 saveAmount) {
        uint256 nav = _getCurrentNAV();
        saveAmount = (ethAmount * 1e18) / nav;
    }

    /// @notice Returns remaining daily capacity.
    function remainingDailyCap() external view returns (uint256) {
        if (block.timestamp >= lastReset + 1 days) {
            return dailyCap;
        }
        if (soldToday >= dailyCap) return 0;
        return dailyCap - soldToday;
    }

    function version() external pure returns (string memory) {
        return "SaveSale_v3";
    }

    // ============ GUARDIAN FUNCTIONS (5-year expiry, 10-year max lifetime) ============

    function setPaused(bool _paused) external onlyGuardian {
        paused = _paused;
        if (_paused) emit Paused();
        else emit Unpaused();
    }

    function setPriceBand(uint256 _minNAV, uint256 _maxNAV) external onlyGuardian {
        require(_minNAV > 0 && _maxNAV > _minNAV, "invalid band");
        minNAV = _minNAV;
        maxNAV = _maxNAV;
        emit PriceBandUpdated(_minNAV, _maxNAV);
    }

    function setDailyCap(uint256 _newCap) external onlyGuardian {
        dailyCap = _newCap;
        emit DailyCapUpdated(_newCap);
    }

    function setMaxBuyPerTx(uint256 _max) external onlyGuardian {
        maxBuyPerTx = _max;
        emit MaxBuyPerTxUpdated(_max);
    }

    /// @notice Update operations split (bounded: 5%-20%).
    function setOperationsBps(uint256 _newBps) external onlyGuardian {
        require(_newBps >= MIN_OPS_BPS && _newBps <= MAX_OPS_BPS, "out of range");
        uint256 old = operationsBps;
        operationsBps = _newBps;
        emit OperationsBpsUpdated(old, _newBps);
    }

    /// @notice Update LP slippage tolerance (bounded: 0.1%-5%).
    function setLpSlippage(uint256 _newBps) external onlyGuardian {
        require(_newBps >= MIN_LP_SLIPPAGE_BPS && _newBps <= MAX_LP_SLIPPAGE_BPS, "out of range");
        uint256 old = lpSlippageBps;
        lpSlippageBps = _newBps;
        emit LpSlippageUpdated(old, _newBps);
    }

    /// @notice Update minimum buy amount (bounded: 0.0001-1 ETH).
    function setMinBuy(uint256 _newAmount) external onlyGuardian {
        require(_newAmount >= MIN_BUY_FLOOR && _newAmount <= MIN_BUY_CEILING, "out of range");
        uint256 old = minBuyETH;
        minBuyETH = _newAmount;
        emit MinBuyUpdated(old, _newAmount);
    }

    /// @notice Update FlatReserve address (for future reserve upgrades).
    function setFlatReserve(address _newReserve) external onlyGuardian {
        require(_newReserve != address(0), "invalid address");
        address old = address(flatReserve);
        flatReserve = IFlatReserve(_newReserve);
        emit FlatReserveUpdated(old, _newReserve);
    }

    /// @notice Extend the guardian expiry. Cannot exceed 10 years from deployment.
    function extendGuardian(uint256 newExpiry) external onlyGuardian {
        require(newExpiry > guardianExpiry, "must extend");
        require(newExpiry <= deploymentTime + MAX_GUARDIAN_LIFETIME, "exceeds max lifetime");
        uint256 old = guardianExpiry;
        guardianExpiry = newExpiry;
        emit GuardianExtended(old, newExpiry);
    }

    /// @notice Sweep stuck ETH (from router refunds, etc.) to treasury.
    function sweepETH() external onlyGuardian {
        uint256 balance = address(this).balance;
        require(balance > 0, "no ETH");
        (bool success, ) = payable(treasury).call{value: balance}("");
        require(success, "sweep failed");
    }

    /// @notice Sweep SAVE inventory to treasury (for migration to v4, etc.).
    function sweepSAVE(uint256 _amount) external onlyGuardian {
        SAVE.safeTransfer(treasury, _amount);
    }

    /// @notice Sweep any ERC-20 token accidentally sent to this contract.
    function sweepToken(address token, uint256 amount) external onlyGuardian {
        require(token != address(SAVE), "use sweepSAVE");
        IERC20(token).safeTransfer(treasury, amount);
    }
}

