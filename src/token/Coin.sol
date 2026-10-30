// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @notice The protocol coin. Fixed supply minted once at deployment; no mint, pause, owner or fee logic. Name and
///         ticker are deployment inputs: `BLACK` is only a development placeholder and the public identity must be
///         distinct from the existing Black Check / BLKCHK project (CLAUDE.md invariant 9).
/// @dev `burnFrom` lets the engine destroy a payer's coins in the same transaction as the action they pay for, using
///      the payer's allowance; anyone can burn their own.
contract Coin is ERC20 {
    string internal _name;
    string internal _symbol;

    constructor(string memory name_, string memory symbol_, uint256 supply, address to) {
        _name = name_;
        _symbol = symbol_;
        _mint(to, supply);
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
    }
}
