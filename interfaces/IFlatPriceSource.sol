// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IFlatPriceSource
/// @notice CPI oracle price surface exposed by FlatSaleV6, which is the protocol's
///         single FLAT/USD price authority. 18 decimals USD.
interface IFlatPriceSource {
    function getFlatPriceUSD() external view returns (uint256);
}
