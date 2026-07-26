// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title FLAT
/// @notice The FLAT coin — a CPI-pegged stablecoin with fixed supply.
///
///         100 trillion tokens (100,000,000,000,000) are minted once at deployment
///         and sent to the deployer address. No further minting is possible.
///         No burn, no admin keys, no pause, no blacklist, no proxy.
///
///         ERC-2612 permit enables gasless approvals for FlatSale and other
///         integrations without requiring a separate approve transaction.
///
///         CROPS-compliant: Censorship Resistant, Capture Resistant, Open Source,
///         Private, Secure. This contract has zero admin surface — once deployed,
///         no one can modify its behavior. It is pure immutable bytecode.
///
/// @dev    Total supply: 100_000_000_000_000 * 1e18 = 1e32
///         uint256 max:  ~1.15e77
///         No overflow risk. Verified safe.
contract FLAT is ERC20, ERC20Permit {

    /// @notice Fixed total supply: 100 trillion FLAT (18 decimals).
    uint256 public constant TOTAL_SUPPLY = 100_000_000_000_000 * 1e18;

    /// @notice Deploys the FLAT token and mints the entire supply to the deployer.
    ///         After construction, no tokens can ever be minted again.
    constructor() ERC20("FLAT", "FLAT") ERC20Permit("FLAT") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    // No mint function.
    // No burn function.
    // No owner.
    // No pause.
    // No blacklist.
    // No admin keys.
    // No proxy.
    // Immutable forever.
}
