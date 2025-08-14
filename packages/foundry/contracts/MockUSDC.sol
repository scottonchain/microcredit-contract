// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title MockUSDC
/// @notice Lightweight 6-decimals mock USDC token for local testing/demo deployments
contract MockUSDC is ERC20, ERC20Permit {
    constructor() ERC20("USD Coin", "USDC") ERC20Permit("USD Coin") {}

    /// @dev Override decimals to return 6 (USDC uses 6 decimals)
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mint tokens to the given address (no access control – local/demo use only)
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
} 