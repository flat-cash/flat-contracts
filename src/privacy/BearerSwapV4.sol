// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title  BearerSwapV4
 * @author Flat Protocol team
 * @notice DeFi-native private transfer and swap infrastructure.
 *
 *         "Send any token to any wallet, in any token they want. Privately. 0.1% fee."
 *
 *         Core operations:
 *         - Transfer: token A @ wallet X \u2192 token A @ wallet Y (private, no on-chain link)
 *         - Swap:     token A @ wallet X \u2192 token B @ wallet Y (private swap via Uniswap)
 *         - Convert:  deposit any token \u2192 stored as FLAT \u2192 withdraw in any token
 *
 *         Designed for contract-to-contract composability:
 *         - Operator pattern: authorize other contracts to act on your behalf
 *         - Hooks: receiving contracts get an \`onBearerReceived\` callback
 *         - Batch operations: deposit once, authorize N withdrawals
 *         - No fixed denominations, no ZK, no trusted setup
 *
 *         Two modes:
 *         - BEARER: Secret-based. Recipient bound at deposit time. One secret, one full reveal.
 *         - SIGNED: EIP-712 signed authorizations. Partial/split/swap reveals. For DeFi.
 *
 *         Fee: 0.1% on fungible withdrawals. 0.05% if output is FLAT.
 *         Accumulated fees \u2192 buy SAVE \u2192 treasury.
 *         NFTs: no fee.
 *
 *         Pause: Only gates new deposits. Withdrawals and reclaims are NEVER pausable.
 */
contract BearerSwapV4 is ReentrancyGuard, IERC721Receiver, ERC1155Holder, EIP712 {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // \u2500\u2500\u2500 Constants
    uint256 public constant FEE_BPS = 10;           // 0.1%
    uint256 public constant FEE_BPS_FLAT = 5;       // 0.05% when output is FLAT
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant RECLAIM_DELAY = 30 days;
    uint256 public constant GUARDIAN_PERIOD = 1095 days; // 3 years

    bytes32 public constant WITHDRAW_TYPEHASH = keccak256(
        "Withdraw(bytes32 vaultId,address recipient,uint256 amount,address tokenOut,uint256 minAmountOut,uint256 nonce,uint256 deadline)"
    );

    // \u2500\u2500\u2500 Immutables
    address public immutable guardian;
    address public immutable treasury;
    IUniswapV2Router02 public immutable uniRouter;
    address public immutable WETH;
    IERC20 public immutable saveToken;
    IERC20 public immutable flatToken;
    uint256 public immutable deployedAt;

    // \u2500\u2500\u2500 Enums & Structs
    enum AssetType { ETH, ERC20, ERC721, ERC1155 }
    enum VaultMode { BEARER, SIGNED }

    struct Vault {
        address issuer;
        VaultMode mode;
        AssetType assetType;
        address token;
        uint256 tokenId;
        uint256 deposited;
        uint256 remaining;
        uint256 createdAt;
        bool settled;
        bytes32 commitHash;  // BEARER mode: keccak256(secret, recipient, vaultKey)
    }

    // \u2500\u2500\u2500 State
    bool public paused;
    mapping(bytes32 => Vault) public vaults;
    mapping(address => mapping(address => bool)) public operators;
    mapping(bytes32 => mapping(uint256 => bool)) public usedNonces;
    mapping(address => uint256) public accumulatedFees;
    mapping(address => uint256) public totalReservedToken;
    uint256 public totalReservedETH;

    // \u2500\u2500\u2500 Events
    event VaultCreated(bytes32 indexed vaultKey, bytes32 vaultId, address indexed issuer, VaultMode mode, AssetType assetType, address token, uint256 amount, uint256 tokenId);
    event Withdrawn(bytes32 indexed vaultKey, address indexed recipient, address tokenOut, uint256 withdrawAmount, uint256 amountOut, uint256 fee);
    event Reclaimed(bytes32 indexed vaultKey, address indexed issuer, uint256 amount);
    event OperatorSet(address indexed issuer, address indexed operator, bool approved);
    event FeeSwept(address indexed token, uint256 amount, uint256 saveReceived);
    event DepositAndConverted(bytes32 indexed vaultKey, address tokenIn, uint256 amountIn, uint256 flatReceived);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    // \u2500\u2500\u2500 Public Functions (signatures)
    function computeVaultKey(address issuer, bytes32 vaultId) external pure returns (bytes32) { /* ... */ }

    // Deposit functions
    function depositETH(bytes32 vaultId, VaultMode mode, bytes32 commitHash) external payable nonReentrant whenNotPaused { /* ... */ }
    function depositERC20(bytes32 vaultId, address token, uint256 amount, VaultMode mode, bytes32 commitHash) external nonReentrant whenNotPaused { /* ... */ }
    function depositAndConvert(bytes32 vaultId, address tokenIn, uint256 amount, uint256 minFlatOut, VaultMode mode, bytes32 commitHash) external nonReentrant whenNotPaused { /* ... */ }
    function depositETHAndConvert(bytes32 vaultId, uint256 minFlatOut, VaultMode mode, bytes32 commitHash) external payable nonReentrant whenNotPaused { /* ... */ }
    function depositERC721(bytes32 vaultId, address token, uint256 tokenId, VaultMode mode, bytes32 commitHash) external nonReentrant whenNotPaused { /* ... */ }
    function depositERC1155(bytes32 vaultId, address token, uint256 tokenId, uint256 amount, VaultMode mode, bytes32 commitHash) external nonReentrant whenNotPaused { /* ... */ }

    // Withdraw functions (SIGNED mode) \u2014 NEVER pausable
    function withdraw(bytes32 vaultKey, address recipient, uint256 amount, address tokenOut, uint256 minAmountOut, uint256 nonce, uint256 deadline, bytes calldata signature) external nonReentrant { /* ... */ }
    function withdrawDirect(bytes32 vaultKey, address recipient, uint256 amount, address tokenOut, uint256 minAmountOut) external nonReentrant { /* ... */ }
    function withdrawBatch(bytes32 vaultKey, address[] calldata recipients, uint256[] calldata amounts, address tokenOut, uint256[] calldata minAmountsOut) external nonReentrant { /* ... */ }

    // Reveal (BEARER mode) \u2014 NEVER pausable
    function reveal(bytes32 vaultKey, bytes32 secret, address recipient) external nonReentrant { /* ... */ }

    // Reclaim \u2014 NEVER pausable (30-day delay)
    function reclaim(bytes32 vaultKey) external nonReentrant { /* ... */ }

    // Operator management
    function setOperator(address operator, bool approved) external { /* ... */ }

    // Fee management
    function sweepFees(address token, uint256 minSaveOut) external nonReentrant { /* ... */ }

    // Admin (guardian-only, expires after 3 years)
    function pause() external onlyGuardian { /* ... */ }
    function unpause() external onlyGuardian { /* ... */ }

    // ERC-721/1155 receiver hooks
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) { /* ... */ }

    // View helpers
    function getVault(bytes32 vaultKey) external view returns (Vault memory) { /* ... */ }

    receive() external payable {}
}

interface IUniswapV2Router02 {
    function WETH() external pure returns (address);
    function swapExactTokensForTokens(uint256, uint256, address[] calldata, address, uint256) external returns (uint256[] memory);
    function swapExactETHForTokens(uint256, address[] calldata, address, uint256) external payable returns (uint256[] memory);
    function swapExactTokensForETH(uint256, uint256, address[] calldata, address, uint256) external returns (uint256[] memory);
}
