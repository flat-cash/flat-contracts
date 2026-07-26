// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  FlatSale V4
 * @notice Sells FLAT tokens for ETH at the CPI-pegged price using compound
 *         per-second growth derived from a 3-month CPI annualization.
 *         Merges the CPI oracle and sale into a single contract.
 *
 *         Admin inputs (monthly): two CPI-U values (current month + 3 months
 *         ago) from FRED series CPIAUCSL (seasonally adjusted), scaled x1000,
 *         plus the per-second compound rate precomputed off-chain.
 *
 *         The rate is UNTRUSTED: the contract verifies on-chain that
 *         rate^SECONDS_PER_YEAR lands within RATE_TOLERANCE_BPS of
 *         (newCPI/refCPI)^4, and that the annual factor is within
 *         [MIN_ANNUAL_FACTOR, MAX_ANNUAL_FACTOR] (12% circuit breaker,
 *         both directions). Deflationary rates (< RAY) are supported.
 *
 * @dev    Pricing math:
 *         ratePerSecond = (newCPI / refCPI)^(4 / SECONDS_PER_YEAR)   [off-chain]
 *         price(t)      = basePrice * ratePerSecond^(t - lastUpdateTime)  [rpow]
 *         flatOut       = msg.value * ethUsd * 1e10 / price(now)
 *
 *         Continuity: each update snapshots the live price as the new
 *         basePrice (no jumps). The price therefore extrapolates at the last
 *         verified rate indefinitely if updates stop — it never reverts and
 *         never freezes.
 *
 *         Ownership is two-step (Ownable2Step) and renunciation is disabled:
 *         this contract custodies sale inventory and serves as the protocol
 *         price oracle, so it must never become ownerless.
 *
 * @custom:version    FlatSale_v4
 * @custom:cpi-series CPIAUCSL (BLS, seasonally adjusted)
 * @custom:oz-version OpenZeppelin ^5.0
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface AggregatorV3Interface {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

contract FlatSaleV4 is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant VERSION_NUM = 4;
    uint256 public constant RAY = 1e27;
    uint256 public constant WAD = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 31_536_000;
    uint256 public constant MIN_ETH_STALENESS = 3_600;
    uint256 public constant MIN_ANNUAL_FACTOR = 880_000_000_000_000_000_000_000_000;
    uint256 public constant MAX_ANNUAL_FACTOR = 1_120_000_000_000_000_000_000_000_000;
    uint256 public constant RATE_TOLERANCE_BPS = 25;

    IERC20 public immutable flat;
    AggregatorV3Interface public immutable ethUsdFeed;
    address public immutable polRecipient;
    address public immutable treasury;
    uint256 public immutable baseCPI;
    uint256 public immutable polBps;

    uint256 public currentCPI;
    uint256 public refCPI;
    uint256 public ratePerSecond;
    uint256 public basePrice;
    uint256 public lastUpdateTime;
    uint256 public dailyCap;
    uint256 public soldToday;
    uint256 public lastResetDay;
    uint256 public ethUsdStaleness;
    bool    public paused;

    event Purchased(address indexed buyer, address indexed recipient, uint256 ethIn, uint256 flatOut, uint256 flatPriceUsd, uint256 ethUsd);
    event CPIUpdated(uint256 newCPI, uint256 refCPI, uint256 ratePerSecond, uint256 newBasePrice, uint256 timestamp);
    event DailyCapChanged(uint256 newCap);
    event Paused(bool state);
    event Swept(address token, uint256 amount);

    error SalePaused();
    error DailyCapExceeded(uint256 remaining);
    error InsufficientInventory(uint256 available);
    error SlippageExceeded(uint256 actual, uint256 minimum);
    error ZeroValue();
    error ZeroAddress();
    error ChainlinkStale(uint256 updatedAt, uint256 threshold);
    error ChainlinkInvalid();
    error AnnualFactorOutOfBounds(uint256 factorRay);
    error RateMismatch(uint256 compoundedRay, uint256 expectedRay);
    error EthStalenessFloor(uint256 provided, uint256 minimum);
    error EthTransferFailed();
    error RenounceDisabled();

    struct DeployParams {
        address flat;
        address ethUsdFeed;
        address polRecipient;
        address treasury;
        uint256 baseCPI;
        uint256 initialCPI;
        uint256 initialRefCPI;
        uint256 initialRate;
        uint256 initialBasePrice;
        uint256 dailyCap;
        uint256 ethUsdStale;
        uint256 polBps;
        address owner;
    }

    constructor(DeployParams memory p) Ownable(p.owner) {
        require(p.flat != address(0) && p.ethUsdFeed != address(0), "zero addr");
        require(p.polRecipient != address(0) && p.treasury != address(0), "zero addr");
        require(p.baseCPI > 0 && p.dailyCap > 0, "zero val");
        require(p.initialBasePrice > 0, "zero base price");
        require(p.ethUsdStale >= MIN_ETH_STALENESS, "staleness floor");
        require(p.polBps <= 10_000, "polBps > 100%");
        require(AggregatorV3Interface(p.ethUsdFeed).decimals() == 8, "feed must be 8 dec");
        flat = IERC20(p.flat);
        ethUsdFeed = AggregatorV3Interface(p.ethUsdFeed);
        polRecipient = p.polRecipient;
        treasury = p.treasury;
        baseCPI = p.baseCPI;
        polBps = p.polBps;
        basePrice = p.initialBasePrice;
        dailyCap = p.dailyCap;
        ethUsdStaleness = p.ethUsdStale;
        _setRate(p.initialCPI, p.initialRefCPI, p.initialRate);
    }

    function updateCPI(uint256 _newCPI, uint256 _refCPI, uint256 _newRate) external onlyOwner {
        uint256 livePrice = getFlatPriceUSD();
        if (livePrice == 0) revert ZeroValue();
        basePrice = livePrice;
        _setRate(_newCPI, _refCPI, _newRate);
        emit CPIUpdated(_newCPI, _refCPI, _newRate, livePrice, block.timestamp);
    }

    function setDailyCap(uint256 _cap) external onlyOwner { dailyCap = _cap; emit DailyCapChanged(_cap); }
    function setPaused(bool _paused) external onlyOwner { paused = _paused; emit Paused(_paused); }
    function setEthUsdStaleness(uint256 _seconds) external onlyOwner {
        if (_seconds < MIN_ETH_STALENESS) revert EthStalenessFloor(_seconds, MIN_ETH_STALENESS);
        ethUsdStaleness = _seconds;
    }
    function sweepFLAT(uint256 _amount) external onlyOwner { flat.safeTransfer(msg.sender, _amount); emit Swept(address(flat), _amount); }
    function sweepETH() external onlyOwner {
        uint256 bal = address(this).balance;
        (bool ok,) = msg.sender.call{value: bal}("");
        if (!ok) revert EthTransferFailed();
        emit Swept(address(0), bal);
    }
    function renounceOwnership() public view override onlyOwner { revert RenounceDisabled(); }

    function buy(uint256 minFlatOut) external payable nonReentrant { _buy(msg.sender, minFlatOut); }
    function buyTo(address recipient, uint256 minFlatOut) external payable nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        _buy(recipient, minFlatOut);
    }

    function getFlatPriceUSD() public view returns (uint256) {
        uint256 elapsed = block.timestamp - lastUpdateTime;
        if (elapsed == 0) return basePrice;
        return _rayMul(basePrice, _rpow(ratePerSecond, elapsed));
    }
    function getInterpolatedPrice() external view returns (uint256) { return getFlatPriceUSD(); }
    function levelPrice() external view returns (uint256) { return (currentCPI * WAD) / baseCPI; }
    function getETHPrice() public view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = ethUsdFeed.latestRoundData();
        if (answer <= 0) revert ChainlinkInvalid();
        if (block.timestamp - updatedAt > ethUsdStaleness) revert ChainlinkStale(updatedAt, ethUsdStaleness);
        return uint256(answer);
    }
    function quote(uint256 ethAmount) external view returns (uint256) { return (ethAmount * getETHPrice() * 1e10) / getFlatPriceUSD(); }
    function remainingToday() external view returns (uint256) {
        if (block.timestamp / 86_400 != lastResetDay) return dailyCap;
        return dailyCap > soldToday ? dailyCap - soldToday : 0;
    }

    function _setRate(uint256 _newCPI, uint256 _refCPI, uint256 _newRate) internal {
        if (_newCPI == 0 || _refCPI == 0 || _newRate == 0) revert ZeroValue();
        uint256 ratio = (_newCPI * RAY) / _refCPI;
        uint256 r4 = _rayMul(ratio, ratio);
        r4 = _rayMul(r4, r4);
        if (r4 < MIN_ANNUAL_FACTOR || r4 > MAX_ANNUAL_FACTOR) revert AnnualFactorOutOfBounds(r4);
        uint256 compounded = _rpow(_newRate, SECONDS_PER_YEAR);
        uint256 tol = (r4 * RATE_TOLERANCE_BPS) / 10_000;
        uint256 diff = compounded > r4 ? compounded - r4 : r4 - compounded;
        if (diff > tol) revert RateMismatch(compounded, r4);
        currentCPI = _newCPI;
        refCPI = _refCPI;
        ratePerSecond = _newRate;
        lastUpdateTime = block.timestamp;
    }

    function _buy(address recipient, uint256 minFlatOut) internal {
        if (paused) revert SalePaused();
        if (msg.value == 0) revert ZeroValue();
        uint256 today = block.timestamp / 86_400;
        if (today != lastResetDay) { soldToday = 0; lastResetDay = today; }
        uint256 flatPrice = getFlatPriceUSD();
        uint256 ethUsd = getETHPrice();
        uint256 flatOut = (msg.value * ethUsd * 1e10) / flatPrice;
        uint256 remaining = dailyCap > soldToday ? dailyCap - soldToday : 0;
        if (flatOut > remaining) revert DailyCapExceeded(remaining);
        uint256 inventory = flat.balanceOf(address(this));
        if (flatOut > inventory) revert InsufficientInventory(inventory);
        if (flatOut < minFlatOut) revert SlippageExceeded(flatOut, minFlatOut);
        soldToday += flatOut;
        emit Purchased(msg.sender, recipient, msg.value, flatOut, flatPrice, ethUsd);
        flat.safeTransfer(recipient, flatOut);
        uint256 polShare = (msg.value * polBps) / 10_000;
        (bool ok1,) = polRecipient.call{value: polShare}("");
        if (!ok1) revert EthTransferFailed();
        (bool ok2,) = treasury.call{value: msg.value - polShare}("");
        if (!ok2) revert EthTransferFailed();
    }

    function _rayMul(uint256 x, uint256 y) internal pure returns (uint256) { return (x * y + RAY / 2) / RAY; }
    function _rpow(uint256 base, uint256 exp) internal pure returns (uint256 result) {
        result = RAY;
        while (exp > 0) {
            if ((exp & 1) == 1) result = _rayMul(result, base);
            exp >>= 1;
            if (exp > 0) base = _rayMul(base, base);
        }
    }

    receive() external payable { revert("use buy()"); }
}
