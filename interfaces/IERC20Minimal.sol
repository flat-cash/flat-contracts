// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IERC20Minimal
/// @notice Minimal ERC-20 surface used by the sale/liquidity contracts. Callers wrap
///         these in low-level calls and enforce exact-delta accounting, so both
///         boolean-returning and non-returning ERC-20 implementations are supported.
interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
