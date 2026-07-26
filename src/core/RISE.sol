// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title RISE Token
 * @notice The base token of the FLAT Protocol.
 *
 * Key properties:
 *   - Fixed supply of 425,000,000 RISE minted at deployment.
 *   - No mint function exists — supply can never increase.
 *   - Burnable — any holder can burn their own tokens.
 *   - ERC-2612 Permit — supports gasless approvals.
 *   - No owner, no admin, no pause — fully immutable after deployment.
 *
 * @dev Inherits from OpenZeppelin v5 contracts:
 *   - ERC20: Core token logic
 *   - ERC20Burnable: Self-burn capability
 *   - ERC20Permit: EIP-2612 gasless approvals
 */
contract RISE is ERC20, ERC20Burnable, ERC20Permit {
    uint256 public constant TOTAL_SUPPLY = 425_000_000 * 10 ** 18;

    /**
     * @notice Deploys the RISE token and mints the entire fixed supply
     *         to the deployer's address.
     */
    constructor( ) ERC20("RISE", "RISE") ERC20Permit("RISE") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
