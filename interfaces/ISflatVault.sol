// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISflatVault
/// @notice Minimal ERC-4626 style surface of the sFLAT vault used by the SAVE exit
///         router: redeem burns `shares` from `owner` and sends FLAT to `receiver`,
///         previewRedeem quotes the FLAT returned for `shares`.
interface ISflatVault {
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
}
