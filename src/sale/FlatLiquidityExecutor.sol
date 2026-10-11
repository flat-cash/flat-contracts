// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Minimal} from "../../interfaces/IERC20Minimal.sol";
import {IFlatPriceSource} from "../../interfaces/IFlatPriceSource.sol";
import {IAggregatorV3} from "../../interfaces/IAggregatorV3.sol";
import {IUniswapV2Pair} from "../../interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Router02} from "../../interfaces/IUniswapV2Router02.sol";

/// @title FlatLiquidityExecutor
/// @notice Operator-exclusive executor for adding FLAT/WETH liquidity on Uniswap V2,
///         with LP tokens minted directly to the protocol Safe. The operator funds each
///         call (FLAT via approve + transferFrom, ETH via msg.value); the contract holds
///         no standing balances and resets the router allowance to zero after every call.
///
///         Safety design (mirrors FlatSaleV6):
///           - Built-in oracle guard: the pool's implied FLAT/USD price (reserves valued
///             with a validated Chainlink ETH/USD read) must sit within an
///             operator-chosen deviation of the FlatSaleV6 CPI oracle price, otherwise
///             the call reverts. Liquidity can therefore never be added at a
///             manipulated or badly distorted ratio.
///           - Exact-delta accounting on FLAT in, LP to Safe, ETH/FLAT refunds out.
///           - Oracle-derived min amounts bound rounding; the guard and the router call
///             are atomic within one transaction, so reserves cannot move in between.
///           - Privileged surface is minimal: the operator can only add liquidity under
///             the guard and pause; the Safe can pause, unpause, rotate the operator,
///             and recover stuck funds (paused-only). LP tokens never touch this
///             contract or the operator: they are minted straight to the Safe.
contract FlatLiquidityExecutor {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error ContractPaused();
    error ContractNotPaused();
    error NotOperator();
    error Unauthorized();
    error Reentrancy();
    error DeadlineExpired();
    error DeviationOutOfBounds();
    error PoolDeviated(uint256 poolFlatUsd, uint256 oracleFlatUsd);
    error ReservesEmpty();
    error InvalidEthPrice();
    error StaleEthPrice();
    error FlatPriceOutOfBounds();
    error DeltaMismatch();
    error TransferFailed();
    error EthRefundFailed();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event LiquidityAdded(
        address indexed operator,
        uint256 flatAmount,
        uint256 ethAmount,
        uint256 liquidity,
        uint256 poolFlatUsd,
        uint256 oracleFlatUsd
    );
    event OperatorUpdated(address indexed previousOperator, address indexed newOperator);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event Recovered(address indexed token, uint256 amount);
    event RecoveredETH(uint256 amount);

    // ---------------------------------------------------------------------
    // Constants and immutables
    // ---------------------------------------------------------------------

    uint256 internal constant REENTRANCY_NOT_ENTERED = 1;
    uint256 internal constant REENTRANCY_ENTERED = 2;

    /// @dev Bounds applied to the V6 FLAT/USD oracle read (18 decimals).
    uint256 public constant MIN_FLAT_USD = 0.5e18;
    uint256 public constant MAX_FLAT_USD = 3e18;

    /// @dev Chainlink ETH/USD read must be at most this old.
    uint256 public constant ETH_USD_STALENESS_SECONDS = 3600;

    /// @dev Hard ceiling for the operator-chosen guard tolerance (10%).
    uint256 public constant MAX_DEVIATION_BPS_CEILING = 1000;

    uint256 internal constant BPS = 10_000;

    IERC20Minimal public immutable flat;
    IFlatPriceSource public immutable priceSource;
    IAggregatorV3 public immutable ethUsdFeed;
    IUniswapV2Pair public immutable pair;
    IUniswapV2Router02 public immutable router;
    address public immutable protocolSafe;

    // ---------------------------------------------------------------------
    // Mutable state
    // ---------------------------------------------------------------------

    address public operator;
    bool public paused;
    uint256 internal reentrancyStatus;

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    modifier onlyOperatorOrSafe() {
        if (msg.sender != operator && msg.sender != protocolSafe) revert Unauthorized();
        _;
    }

    modifier onlySafe() {
        if (msg.sender != protocolSafe) revert Unauthorized();
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

    /// @param flatToken         FLAT token.
    /// @param flatPriceSource   FlatSaleV6 (CPI price authority).
    /// @param ethUsdFeed_       Chainlink ETH/USD feed (8 decimals).
    /// @param flatWethPair      Uniswap V2 FLAT/WETH pair (also the LP token).
    /// @param uniswapRouter     Uniswap V2 Router02.
    /// @param safe              Protocol Safe: receives all LP tokens, can pause /
    ///                          unpause / rotate the operator / recover stuck funds.
    /// @param initialOperator   The only EOA allowed to call addLiquidity.
    constructor(
        address flatToken,
        address flatPriceSource,
        address ethUsdFeed_,
        address flatWethPair,
        address uniswapRouter,
        address safe,
        address initialOperator
    ) {
        if (
            flatToken == address(0) || flatPriceSource == address(0) || ethUsdFeed_ == address(0)
                || flatWethPair == address(0) || uniswapRouter == address(0) || safe == address(0)
                || initialOperator == address(0)
        ) revert ZeroAddress();

        flat = IERC20Minimal(flatToken);
        priceSource = IFlatPriceSource(flatPriceSource);
        ethUsdFeed = IAggregatorV3(ethUsdFeed_);
        pair = IUniswapV2Pair(flatWethPair);
        router = IUniswapV2Router02(uniswapRouter);
        protocolSafe = safe;
        operator = initialOperator;

        paused = true; // starts paused; Safe unpauses explicitly after verification
        reentrancyStatus = REENTRANCY_NOT_ENTERED;

        emit OperatorUpdated(address(0), initialOperator);
        emit Paused(address(0));
    }

    /// @dev Accepts ETH: router refunds of unused ETH, and nothing else in normal flow.
    receive() external payable {}

    // ---------------------------------------------------------------------
    // Operator flow: add FLAT/WETH liquidity, LP directly to the Safe
    // ---------------------------------------------------------------------

    /// @notice Add FLAT/WETH liquidity through the Uniswap V2 router. Only callable by
    ///         the operator. Reverts unless the pool's implied FLAT/USD price is within
    ///         `maxDeviationBps` of the V6 CPI oracle price.
    /// @param flatAmount       FLAT to pull from the operator (operator must have
    ///                         approved this contract for at least this amount).
    /// @param maxDeviationBps  Guard tolerance in basis points (1..1000). Also scales
    ///                         the oracle-derived min amounts for the router call.
    /// @param deadline         Unix timestamp after which the transaction reverts
    ///                         (forwarded to the router).
    function addLiquidity(uint256 flatAmount, uint256 maxDeviationBps, uint256 deadline)
        external
        payable
        onlyOperator
        nonReentrant
        whenNotPaused
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (flatAmount == 0 || msg.value == 0) revert ZeroAmount();
        if (maxDeviationBps == 0 || maxDeviationBps > MAX_DEVIATION_BPS_CEILING) revert DeviationOutOfBounds();

        // --- oracle guard (both reads validated inside) ---
        (uint256 poolFlatUsd, uint256 oracleFlatUsd) = _assertPoolWithinDeviation(maxDeviationBps);

        // --- pull, approve, add, verify, reset (all exact-delta) ---
        uint256 ethBefore = address(this).balance - msg.value;
        (uint256 amountToken, uint256 amountETH, uint256 liquidity) =
            _addLiquidity(flatAmount, maxDeviationBps, deadline);

        // --- refund unused ETH to the operator (router sends it back to us) ---
        uint256 ethRefund = address(this).balance - ethBefore;
        if (ethRefund != msg.value - amountETH) revert DeltaMismatch();
        if (ethRefund > 0) {
            _sendEth(msg.sender, ethRefund);
        }

        emit LiquidityAdded(msg.sender, amountToken, amountETH, liquidity, poolFlatUsd, oracleFlatUsd);
    }

    /// @dev Reverts unless the pool's implied FLAT/USD is within `maxDeviationBps` of
    ///      the V6 CPI oracle price. Returns both prices for the event.
    function _assertPoolWithinDeviation(uint256 maxDeviationBps)
        internal
        view
        returns (uint256 poolFlatUsd, uint256 oracleFlatUsd)
    {
        oracleFlatUsd = priceSource.getFlatPriceUSD();
        if (oracleFlatUsd < MIN_FLAT_USD || oracleFlatUsd > MAX_FLAT_USD) revert FlatPriceOutOfBounds();

        uint256 ethUsd = _readEthUsd();
        (uint256 flatReserve, uint256 wethReserve) = _poolReserves();
        if (flatReserve == 0 || wethReserve == 0) revert ReservesEmpty();
        poolFlatUsd = (wethReserve * ethUsd) / flatReserve;

        uint256 diff =
            poolFlatUsd > oracleFlatUsd ? poolFlatUsd - oracleFlatUsd : oracleFlatUsd - poolFlatUsd;
        if (diff * BPS > maxDeviationBps * oracleFlatUsd) revert PoolDeviated(poolFlatUsd, oracleFlatUsd);
    }

    /// @dev Pulls FLAT from the operator, approves the router for exactly that amount,
    ///      adds liquidity with LP minted directly to the Safe, then resets the
    ///      allowance and returns FLAT dust to the operator. Exact-delta throughout.
    function _addLiquidity(uint256 flatAmount, uint256 maxDeviationBps, uint256 deadline)
        internal
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity)
    {
        uint256 flatBefore = flat.balanceOf(address(this));
        _callTransferFrom(address(flat), msg.sender, address(this), flatAmount);
        if (flat.balanceOf(address(this)) - flatBefore != flatAmount) revert DeltaMismatch();

        _callApprove(address(flat), address(router), flatAmount);

        uint256 safeLpBefore = pair.balanceOf(protocolSafe);
        (amountToken, amountETH, liquidity) = router.addLiquidityETH{value: msg.value}(
            address(flat),
            flatAmount,
            (flatAmount * (BPS - maxDeviationBps)) / BPS, // amountTokenMin (oracle-scaled)
            (msg.value * (BPS - maxDeviationBps)) / BPS, // amountETHMin (oracle-scaled)
            protocolSafe,
            deadline
        );
        if (pair.balanceOf(protocolSafe) - safeLpBefore != liquidity) revert DeltaMismatch();
        if (liquidity == 0) revert ZeroAmount();

        _callApprove(address(flat), address(router), 0);
        uint256 flatLeft = flat.balanceOf(address(this)) - flatBefore;
        if (flatLeft != flatAmount - amountToken) revert DeltaMismatch();
        if (flatLeft > 0) {
            _callTransfer(address(flat), msg.sender, flatLeft);
        }
    }

    // ---------------------------------------------------------------------
    // Role and pause administration
    // ---------------------------------------------------------------------

    /// @notice Rotate the operator. Callable by the current operator or by the Safe
    ///         (recovery path if the operator key is lost or compromised).
    function setOperator(address newOperator) external onlyOperatorOrSafe {
        if (newOperator == address(0)) revert ZeroAddress();
        address old = operator;
        operator = newOperator;
        emit OperatorUpdated(old, newOperator);
    }

    /// @notice Defensive pause. Callable by the operator or the Safe.
    function pause() external onlyOperatorOrSafe {
        if (paused) return;
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpause. Safe-only: a compromised operator cannot re-enable itself.
    function unpause() external onlySafe {
        if (!paused) return;
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Recover any stuck token to the Safe. Paused-only, Safe-only.
    function recoverToken(address token, uint256 amount) external onlySafe whenPaused {
        if (token == address(0)) revert ZeroAddress();
        _callTransfer(token, protocolSafe, amount);
        emit Recovered(token, amount);
    }

    /// @notice Recover ETH to the Safe (e.g. accidental direct sends). Paused-only.
    function recoverETH() external onlySafe whenPaused {
        uint256 bal = address(this).balance;
        if (bal == 0) revert ZeroAmount();
        (bool ok,) = protocolSafe.call{value: bal}("");
        if (!ok) revert TransferFailed();
        emit RecoveredETH(bal);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Current pool implied FLAT/USD, the V6 oracle price, and the live
    ///         deviation in bps. For the frontend and pre-flight checks.
    function currentPrices()
        external
        view
        returns (uint256 poolFlatUsd, uint256 oracleFlatUsd, uint256 deviationBps)
    {
        oracleFlatUsd = priceSource.getFlatPriceUSD();
        uint256 ethUsd = _readEthUsd();
        (uint256 flatReserve, uint256 wethReserve) = _poolReserves();
        if (flatReserve == 0 || wethReserve == 0) revert ReservesEmpty();
        poolFlatUsd = (wethReserve * ethUsd) / flatReserve;
        uint256 diff =
            poolFlatUsd > oracleFlatUsd ? poolFlatUsd - oracleFlatUsd : oracleFlatUsd - poolFlatUsd;
        deviationBps = (diff * BPS) / oracleFlatUsd;
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _readEthUsd() internal view returns (uint256 ethUsd) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            ethUsdFeed.latestRoundData();
        if (answer <= 0) revert InvalidEthPrice();
        if (updatedAt == 0 || block.timestamp - updatedAt > ETH_USD_STALENESS_SECONDS) revert StaleEthPrice();
        if (answeredInRound < roundId) revert StaleEthPrice();
        uint8 feedDecimals = ethUsdFeed.decimals();
        if (feedDecimals > 18) revert InvalidEthPrice();
        ethUsd = uint256(answer) * (10 ** (18 - feedDecimals));
    }

    function _poolReserves() internal view returns (uint256 flatReserve, uint256 wethReserve) {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        if (pair.token0() == address(flat)) {
            flatReserve = reserve0;
            wethReserve = reserve1;
        } else {
            flatReserve = reserve1;
            wethReserve = reserve0;
        }
    }

    function _callTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _callApprove(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20Minimal.approve.selector, spender, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _callTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthRefundFailed();
    }
}
