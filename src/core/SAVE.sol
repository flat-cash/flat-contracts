// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract SAVE is ERC20 {
    using SafeERC20 for IERC20;

    IERC20 public immutable RISE;

    event Deposited(address indexed depositor, uint256 amount);

    constructor(address _rise) ERC20("SAVE", "SAVE") {
        require(_rise != address(0), "RISE address cannot be zero");
        RISE = IERC20(_rise);
    }

    function deposit(uint256 amount) external {
        require(amount > 0, "Amount must be greater than zero");
        RISE.safeTransferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, amount);
        emit Deposited(msg.sender, amount);
    }

    function riseLockedInVault() external view returns (uint256) {
        return RISE.balanceOf(address(this));
    }

    function alpha() external view returns (uint256) {
        uint256 locked = RISE.balanceOf(address(this));
        uint256 total = RISE.totalSupply();
        if (total == 0) return 0;
        return (locked * 1e18) / total;
    }
}
