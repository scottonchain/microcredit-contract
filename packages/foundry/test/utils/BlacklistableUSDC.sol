// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { MockUSDC } from "../../contracts/MockUSDC.sol";

/// @dev MockUSDC that, like Circle's USDC, refuses transfers to or from a blacklisted address.
contract BlacklistableUSDC is MockUSDC {
    mapping(address => bool) public isBlacklisted;

    function setBlacklisted(address account, bool blacklisted) external {
        isBlacklisted[account] = blacklisted;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!isBlacklisted[from] && !isBlacklisted[to], "Blacklistable: account is blacklisted");
        super._update(from, to, value);
    }
}
