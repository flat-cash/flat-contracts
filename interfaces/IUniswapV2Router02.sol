// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IUniswapV2Router02 {
    function addLiquidityETH(
        address token, uint amountTokenDesired, uint amountTokenMin,
        uint amountETHMin, address to, uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function removeLiquidityETH(
        address token, uint liquidity, uint amountTokenMin,
        uint amountETHMin, address to, uint deadline
    ) external returns (uint amountToken, uint amountETH);
    function swapExactTokensForETH(
        uint amountIn, uint amountOutMin, address[] calldata path,
        address to, uint deadline
    ) external returns (uint[] memory amounts);
    function swapExactETHForTokens(
        uint amountOutMin, address[] calldata path,
        address to, uint deadline
    ) external payable returns (uint[] memory amounts);
    function WETH() external pure returns (address);
}
