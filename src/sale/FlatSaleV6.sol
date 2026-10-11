// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";

/**
 * @notice An oracle-priced, non-upgradeable ETH-to-FLAT sale; NEVER adds liquidity.
 * @dev The only fixed address in this source is the explicitly selected initial owner.
 *      FLAT, ETH/USD oracle and the sole proceeds/recovery recipient are supplied at deployment.
 *      All non-representational economic and delay parameters are supplied at deployment and
 *      may be tightened or queued for delayed relaxation by the current owner.
 */
contract FlatSaleV6 is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant INITIAL_OWNER = 0xdDf493752E2578f64dd78249D846E3C87A6936bC;
    uint256 private constant WAD = 1e18; // ETH, FLAT and FLAT/USD accounting units, not an economic parameter.
    uint256 private constant RAY = 1e27; // CPI rate representation.
    uint256 private constant BPS = 10_000; // Rate-tolerance representation.

    struct Config {
        uint256 buyerFlatCap;
        uint256 maxFlatPerTx;
        uint256 maxFlatPerWindow;
        uint256 minPurchaseEth;
        uint256 ethUsdStaleness;
    }

    struct Bounds {
        uint256 maxBuyerFlatCap;
        uint256 maxFlatPerTx;
        uint256 maxFlatPerWindow;
        uint256 minPurchaseEth;
        uint256 maxEthUsdStaleness;
        uint256 minFlatPriceUsd;
        uint256 maxFlatPriceUsd;
        uint256 minAnnualFactorRay;
        uint256 maxAnnualFactorRay;
        uint256 annualRateToleranceBps;
        uint256 annualizationSeconds;
        uint256 cpiPeriodsPerYear;
        uint256 salesWindowSeconds;
        uint256 configDelaySeconds;
        uint256 unpauseDelaySeconds;
    }

    struct DeployParams {
        address flat;
        address ethUsdFeed;
        address protocolSafe;
        uint256 baseCPI;
        uint256 initialCPI;
        uint256 initialRefCPI;
        uint256 initialRatePerSecond;
        uint256 initialBasePrice;
        Config initialConfig;
        Bounds limits;
    }

    IERC20 public immutable flat;
    IPriceFeed public immutable ethUsdFeed;
    address public immutable protocolSafe;
    uint256 public immutable baseCPI;
    Bounds public limits;
    Config public config;
    Config public pendingConfig;
    bytes32 public pendingConfigHash;
    uint256 public pendingConfigExecutableAt;
    uint256 public unpauseExecutableAt;

    uint256 public currentCPI;
    uint256 public refCPI;
    uint256 public ratePerSecond;
    uint256 public basePrice;
    uint256 public lastUpdateTime;
    bool public paused;
    uint256 public totalBuyerFlatSold;
    uint256 public totalEthSentToSafe;
    uint256 public currentWindowId;
    uint256 public windowFlatSold;

    event Purchased(address indexed buyer, address indexed recipient, uint256 ethIn, uint256 flatOut, uint256 flatPriceUsd, uint256 ethUsd);
    event CPIUpdated(uint256 newCPI, uint256 newRefCPI, uint256 newRate, uint256 newBasePrice, uint256 timestamp);
    event Paused(address indexed owner);
    event UnpauseQueued(address indexed owner, uint256 executableAt);
    event UnpauseCancelled(address indexed owner);
    event Unpaused(address indexed owner);
    event DefensiveConfigApplied(bytes32 indexed oldHash, bytes32 indexed newHash);
    event ConfigQueued(bytes32 indexed hash, uint256 executableAt);
    event ConfigCancelled(bytes32 indexed hash);
    event ConfigExecuted(bytes32 indexed oldHash, bytes32 indexed newHash);
    event PriceRebased(uint256 oldRawPrice, uint256 newBoundedPrice);
    event AssetRecovered(address indexed token, uint256 amount, address indexed recipient);

    error SalePaused();
    error SaleNotPaused();
    error DeadlineExpired();
    error PurchaseBelowMinimum();
    error BuyerCapExceeded();
    error PerTransactionCapExceeded();
    error WindowCapExceeded();
    error InsufficientInventory();
    error SlippageExceeded();
    error ChainlinkInvalid();
    error ChainlinkStale();
    error InvalidConfiguration();
    error NotDefensiveConfiguration();
    error ConfigurationAlreadyQueued();
    error NoConfigurationQueued();
    error ConfigurationTooEarly();
    error UnpauseAlreadyQueued();
    error UnpauseNotQueued();
    error UnpauseTooEarly();
    error InvalidDecimals();
    error BuyerDeliveryMismatch();
    error InventoryDeliveryMismatch();
    error SafeEthDeliveryMismatch();
    error UnexpectedEthBalance();
    error InvalidAddress();
    error ZeroValue();
    error PriceOutOfBounds();
    error AnnualFactorOutOfBounds();
    error RateMismatch();
    error MinimumPurchaseUnavailable();
    error EthTransferFailed();
    error DirectEthNotAccepted();
    error CoreAssetRecoveryForbidden();
    error RecoveryRequiresPause();
    error RenounceDisabled();
    error OwnershipOnlyToSafe();

    constructor(DeployParams memory p) Ownable(INITIAL_OWNER) {
        if (p.flat == address(0) || p.ethUsdFeed == address(0) || p.protocolSafe == address(0)) revert InvalidAddress();
        if (p.flat.code.length == 0 || p.ethUsdFeed.code.length == 0 || p.protocolSafe.code.length == 0) revert InvalidAddress();
        if (IERC20Metadata(p.flat).decimals() != 18 || IPriceFeed(p.ethUsdFeed).decimals() != 8) revert InvalidDecimals();
        if (p.baseCPI == 0 || p.initialBasePrice == 0) revert ZeroValue();
        _validateBounds(p.limits);
        limits = p.limits;
        _validateConfig(p.initialConfig, 0);
        flat = IERC20(p.flat);
        ethUsdFeed = IPriceFeed(p.ethUsdFeed);
        protocolSafe = p.protocolSafe;
        baseCPI = p.baseCPI;
        basePrice = p.initialBasePrice;
        config = p.initialConfig;
        paused = true;
        _setRate(p.initialCPI, p.initialRefCPI, p.initialRatePerSecond);
        _validatedPrice(p.initialBasePrice);
    }

    /** Buy at the oracle/CPI price. No pool, router, pair, LP, keeper or accrued ETH leg exists. */
    function buyTo(address recipient, uint256 minFlatOut, uint256 deadline)
        external payable nonReentrant returns (uint256 buyerFlatOut)
    {
        if (paused) revert SalePaused();
        if (recipient == address(0)) revert InvalidAddress();
        if (block.timestamp > deadline) revert DeadlineExpired();
        Config memory c = config;
        if (msg.value < c.minPurchaseEth) revert PurchaseBelowMinimum();
        uint256 oldEthBalance = address(this).balance - msg.value;
        (uint256 flatPriceUsd, uint256 ethUsd) = _validatedPrices(c.ethUsdStaleness);
        buyerFlatOut = Math.mulDiv(msg.value, ethUsd * 1e10, flatPriceUsd);
        if (buyerFlatOut == 0 || buyerFlatOut < minFlatOut) revert SlippageExceeded();
        if (buyerFlatOut > c.maxFlatPerTx) revert PerTransactionCapExceeded();
        uint256 newTotal = totalBuyerFlatSold + buyerFlatOut;
        if (newTotal > c.buyerFlatCap) revert BuyerCapExceeded();
        uint256 thisWindow = block.timestamp / limits.salesWindowSeconds;
        uint256 newWindowSold = (thisWindow == currentWindowId ? windowFlatSold : 0) + buyerFlatOut;
        if (newWindowSold > c.maxFlatPerWindow) revert WindowCapExceeded();

        uint256 inventoryBefore = flat.balanceOf(address(this));
        if (inventoryBefore < buyerFlatOut) revert InsufficientInventory();
        totalBuyerFlatSold = newTotal;
        currentWindowId = thisWindow;
        windowFlatSold = newWindowSold;
        totalEthSentToSafe += msg.value;

        uint256 buyerBefore = flat.balanceOf(recipient);
        flat.safeTransfer(recipient, buyerFlatOut);
        if (flat.balanceOf(recipient) - buyerBefore != buyerFlatOut) revert BuyerDeliveryMismatch();
        if (inventoryBefore - flat.balanceOf(address(this)) != buyerFlatOut) revert InventoryDeliveryMismatch();

        uint256 safeEthBefore = protocolSafe.balance;
        (bool delivered,) = protocolSafe.call{value: msg.value}("");
        if (!delivered) revert EthTransferFailed();
        if (protocolSafe.balance - safeEthBefore != msg.value) revert SafeEthDeliveryMismatch();
        if (address(this).balance != oldEthBalance) revert UnexpectedEthBalance();
        emit Purchased(msg.sender, recipient, msg.value, buyerFlatOut, flatPriceUsd, ethUsd);
    }

    function quote(uint256 ethAmount) external view returns (uint256 flatOut, uint256 flatPriceUsd, uint256 ethUsd) {
        if (ethAmount == 0) revert ZeroValue();
        (flatPriceUsd, ethUsd) = _validatedPrices(config.ethUsdStaleness);
        flatOut = Math.mulDiv(ethAmount, ethUsd * 1e10, flatPriceUsd);
    }

    function getFlatPriceUSD() public view returns (uint256) {
        return _validatedPrice(_rawFlatPriceUSD());
    }

    function _rawFlatPriceUSD() internal view returns (uint256) {
        uint256 elapsed = block.timestamp - lastUpdateTime;
        return elapsed == 0 ? basePrice : Math.mulDiv(basePrice, _rpow(ratePerSecond, elapsed), RAY);
    }

    function getETHPrice() public view returns (uint256) { return _validatedEthUsd(config.ethUsdStaleness); }
    function levelPrice() external view returns (uint256) { return Math.mulDiv(currentCPI, WAD, baseCPI); }
    function availableInventory() external view returns (uint256) { return flat.balanceOf(address(this)); }
    function remainingBuyerCapacity() external view returns (uint256) {
        return config.buyerFlatCap > totalBuyerFlatSold ? config.buyerFlatCap - totalBuyerFlatSold : 0;
    }
    function currentConfigHash() external view returns (bytes32) { return _configHash(config); }

    function updateCPI(uint256 newCPI, uint256 newRefCPI, uint256 newRate) external onlyOwner {
        uint256 raw = _rawFlatPriceUSD();
        uint256 livePrice = raw;
        if (raw < limits.minFlatPriceUsd || raw > limits.maxFlatPriceUsd) {
            if (!paused) revert PriceOutOfBounds();
            livePrice = raw < limits.minFlatPriceUsd ? limits.minFlatPriceUsd : limits.maxFlatPriceUsd;
            emit PriceRebased(raw, livePrice); // Explicit, paused-only continuity exception after bound breach.
        }
        basePrice = livePrice;
        _setRate(newCPI, newRefCPI, newRate);
        emit CPIUpdated(newCPI, newRefCPI, newRate, livePrice, block.timestamp);
    }

    function pause() external onlyOwner {
        bool alreadyPaused = paused;
        bool cancelled;
        if (unpauseExecutableAt != 0) { unpauseExecutableAt = 0; emit UnpauseCancelled(msg.sender); cancelled = true; }
        if (pendingConfigExecutableAt != 0) { _cancelPendingConfig(); cancelled = true; }
        if (alreadyPaused && !cancelled) revert SalePaused();
        if (!alreadyPaused) { paused = true; emit Paused(msg.sender); }
    }

    function queueUnpause() external onlyOwner {
        if (!paused) revert SaleNotPaused();
        if (unpauseExecutableAt != 0) revert UnpauseAlreadyQueued();
        unpauseExecutableAt = block.timestamp + limits.unpauseDelaySeconds;
        emit UnpauseQueued(msg.sender, unpauseExecutableAt);
    }

    function cancelUnpause() external onlyOwner {
        if (unpauseExecutableAt == 0) revert UnpauseNotQueued();
        unpauseExecutableAt = 0;
        emit UnpauseCancelled(msg.sender);
    }

    function executeUnpause() external onlyOwner {
        if (!paused) revert SaleNotPaused();
        uint256 executableAt = unpauseExecutableAt;
        if (executableAt == 0) revert UnpauseNotQueued();
        if (block.timestamp < executableAt) revert UnpauseTooEarly();
        _requirePurchasable(config);
        unpauseExecutableAt = 0;
        paused = false;
        emit Unpaused(msg.sender);
    }

    function applyDefensiveConfig(Config calldata next) external onlyOwner {
        Config memory previous = config;
        _validateConfig(next, totalBuyerFlatSold);
        if (next.buyerFlatCap > previous.buyerFlatCap || next.maxFlatPerTx > previous.maxFlatPerTx
            || next.maxFlatPerWindow > previous.maxFlatPerWindow || next.minPurchaseEth < previous.minPurchaseEth
            || next.ethUsdStaleness > previous.ethUsdStaleness) revert NotDefensiveConfiguration();
        if (pendingConfigExecutableAt != 0) _cancelPendingConfig();
        config = next;
        emit DefensiveConfigApplied(_configHash(previous), _configHash(next));
    }

    function queueConfig(Config calldata next) external onlyOwner {
        if (pendingConfigExecutableAt != 0) revert ConfigurationAlreadyQueued();
        _validateConfig(next, totalBuyerFlatSold);
        pendingConfig = next;
        pendingConfigHash = _configHash(next);
        pendingConfigExecutableAt = block.timestamp + limits.configDelaySeconds;
        emit ConfigQueued(pendingConfigHash, pendingConfigExecutableAt);
    }

    function cancelConfig() external onlyOwner {
        if (pendingConfigExecutableAt == 0) revert NoConfigurationQueued();
        _cancelPendingConfig();
    }

    function _cancelPendingConfig() internal {
        bytes32 oldHash = pendingConfigHash;
        delete pendingConfig;
        pendingConfigHash = bytes32(0);
        pendingConfigExecutableAt = 0;
        emit ConfigCancelled(oldHash);
    }

    function executeConfig() external onlyOwner {
        if (pendingConfigExecutableAt == 0) revert NoConfigurationQueued();
        if (block.timestamp < pendingConfigExecutableAt) revert ConfigurationTooEarly();
        Config memory next = pendingConfig;
        _validateConfig(next, totalBuyerFlatSold);
        if (!paused) _requirePurchasable(next);
        bytes32 previous = _configHash(config);
        bytes32 hash = pendingConfigHash;
        config = next;
        delete pendingConfig;
        pendingConfigHash = bytes32(0);
        pendingConfigExecutableAt = 0;
        emit ConfigExecuted(previous, hash);
    }

    function recoverFlatToSafe(uint256 amount) external onlyOwner nonReentrant {
        if (!paused) revert RecoveryRequiresPause();
        uint256 safeBefore = flat.balanceOf(protocolSafe);
        uint256 inventoryBefore = flat.balanceOf(address(this));
        flat.safeTransfer(protocolSafe, amount);
        if (flat.balanceOf(protocolSafe) - safeBefore != amount) revert BuyerDeliveryMismatch();
        if (inventoryBefore - flat.balanceOf(address(this)) != amount) revert InventoryDeliveryMismatch();
        emit AssetRecovered(address(flat), amount, protocolSafe);
    }

    function recoverEthToSafe() external onlyOwner nonReentrant {
        if (!paused) revert RecoveryRequiresPause();
        uint256 amount = address(this).balance;
        uint256 safeBefore = protocolSafe.balance;
        (bool sent,) = protocolSafe.call{value: amount}("");
        if (!sent) revert EthTransferFailed();
        if (protocolSafe.balance - safeBefore != amount) revert SafeEthDeliveryMismatch();
        if (address(this).balance != 0) revert UnexpectedEthBalance();
        emit AssetRecovered(address(0), amount, protocolSafe);
    }

    function recoverTokenToSafe(address token, uint256 amount) external onlyOwner nonReentrant {
        if (!paused) revert RecoveryRequiresPause();
        if (token == address(0)) revert InvalidAddress();
        if (token == address(flat)) revert CoreAssetRecoveryForbidden();
        uint256 safeBefore = IERC20(token).balanceOf(protocolSafe);
        IERC20(token).safeTransfer(protocolSafe, amount);
        uint256 received = IERC20(token).balanceOf(protocolSafe) - safeBefore;
        emit AssetRecovered(token, received, protocolSafe);
    }

    /** The already-specified Safe is the sole permissible successor; acceptance is a separate Safe transaction. */
    function transferOwnership(address newOwner) public override onlyOwner {
        if (newOwner != protocolSafe) revert OwnershipOnlyToSafe();
        super.transferOwnership(newOwner);
    }

    function renounceOwnership() public view override onlyOwner { revert RenounceDisabled(); }
    receive() external payable { revert DirectEthNotAccepted(); }
    fallback() external payable { revert DirectEthNotAccepted(); }

    function _validatedPrices(uint256 staleness) internal view returns (uint256 price, uint256 ethPrice) {
        price = getFlatPriceUSD();
        ethPrice = _validatedEthUsd(staleness);
    }

    function _validatedEthUsd(uint256 staleness) internal view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = ethUsdFeed.latestRoundData();
        if (roundId == 0 || answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp
            || answeredInRound < roundId || uint256(answer) > type(uint256).max / 1e10) revert ChainlinkInvalid();
        if (block.timestamp - updatedAt > staleness) revert ChainlinkStale();
        return uint256(answer);
    }

    function _requirePurchasable(Config memory c) internal view {
        (uint256 flatUsd, uint256 ethUsd) = _validatedPrices(c.ethUsdStaleness);
        uint256 minOutput = Math.mulDiv(c.minPurchaseEth, ethUsd * 1e10, flatUsd);
        uint256 thisWindow = block.timestamp / limits.salesWindowSeconds;
        uint256 alreadyInWindow = thisWindow == currentWindowId ? windowFlatSold : 0;
        if (minOutput == 0 || minOutput > c.maxFlatPerTx || minOutput > c.maxFlatPerWindow
            || alreadyInWindow + minOutput > c.maxFlatPerWindow
            || totalBuyerFlatSold + minOutput > c.buyerFlatCap
            || flat.balanceOf(address(this)) < minOutput) revert MinimumPurchaseUnavailable();
    }

    function _validatedPrice(uint256 price) internal view returns (uint256) {
        if (price < limits.minFlatPriceUsd || price > limits.maxFlatPriceUsd) revert PriceOutOfBounds();
        return price;
    }

    function _setRate(uint256 newCPI, uint256 newRefCPI, uint256 newRate) internal {
        if (newCPI == 0 || newRefCPI == 0 || newRate == 0) revert ZeroValue();
        uint256 ratio = Math.mulDiv(newCPI, RAY, newRefCPI);
        uint256 annualFactor = _rpow(ratio, limits.cpiPeriodsPerYear);
        if (annualFactor < limits.minAnnualFactorRay || annualFactor > limits.maxAnnualFactorRay) revert AnnualFactorOutOfBounds();
        uint256 compounded = _rpow(newRate, limits.annualizationSeconds);
        uint256 tolerance = Math.mulDiv(annualFactor, limits.annualRateToleranceBps, BPS);
        uint256 difference = compounded > annualFactor ? compounded - annualFactor : annualFactor - compounded;
        if (difference > tolerance) revert RateMismatch();
        currentCPI = newCPI;
        refCPI = newRefCPI;
        ratePerSecond = newRate;
        lastUpdateTime = block.timestamp;
    }

    function _rpow(uint256 base, uint256 exponent) internal pure returns (uint256 result) {
        result = RAY;
        while (exponent > 0) {
            if ((exponent & 1) == 1) result = Math.mulDiv(result, base, RAY);
            exponent >>= 1;
            if (exponent > 0) base = Math.mulDiv(base, base, RAY);
        }
    }

    function _configHash(Config memory candidate) internal pure returns (bytes32) { return keccak256(abi.encode(candidate)); }

    function _validateConfig(Config memory c, uint256 sold) internal view {
        Bounds memory b = limits;
        if (c.buyerFlatCap == 0 || c.buyerFlatCap < sold || c.buyerFlatCap > b.maxBuyerFlatCap
            || c.maxFlatPerTx == 0 || c.maxFlatPerTx > b.maxFlatPerTx
            || c.maxFlatPerWindow == 0 || c.maxFlatPerWindow > b.maxFlatPerWindow
            || c.minPurchaseEth < b.minPurchaseEth || c.ethUsdStaleness == 0
            || c.ethUsdStaleness > b.maxEthUsdStaleness) revert InvalidConfiguration();
    }

    function _validateBounds(Bounds memory b) internal pure {
        if (b.maxBuyerFlatCap == 0 || b.maxFlatPerTx == 0 || b.maxFlatPerWindow == 0
            || b.minPurchaseEth == 0 || b.maxEthUsdStaleness == 0
            || b.minFlatPriceUsd == 0 || b.maxFlatPriceUsd < b.minFlatPriceUsd
            || b.minAnnualFactorRay == 0 || b.minAnnualFactorRay > RAY
            || b.maxAnnualFactorRay < RAY || b.maxAnnualFactorRay < b.minAnnualFactorRay
            || b.annualRateToleranceBps > BPS || b.annualizationSeconds == 0
            || b.cpiPeriodsPerYear == 0 || b.salesWindowSeconds == 0 || b.configDelaySeconds == 0
            || b.unpauseDelaySeconds == 0) revert InvalidConfiguration();
    }
}
