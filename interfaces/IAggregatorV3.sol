// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAggregatorV3
/// @notice Minimal Chainlink AggregatorV3Interface for reading price feeds.
///         Mainnet ETH/USD feed: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}
