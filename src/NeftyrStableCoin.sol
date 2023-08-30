// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title NeftyrStableCoin
 * @author Neftyr
 
 * Collateral: Exogenus (ETH & BTC)
 * Minting: Algorithmic
 * Relative Stability: Pegged to USD
 
 * This is the contract meant to be governed by DSCEngine.
 * This contract is just ERC20 implementation of our stablecoin system.
 */

contract NeftyrStableCoin is ERC20Burnable, Ownable {
    error NeftyrStableCoin__NotEnoughTokensAmount();
    error NeftyrStableCoin__BurnAmountExceedsBalance();
    error NeftyrStableCoin__ZeroAddress();

    constructor() ERC20("Neftyr", "NFR") {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) revert NeftyrStableCoin__NotEnoughTokensAmount();
        if (balance < _amount) revert NeftyrStableCoin__BurnAmountExceedsBalance();

        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) revert NeftyrStableCoin__ZeroAddress();
        if (_amount <= 0) revert NeftyrStableCoin__NotEnoughTokensAmount();

        _mint(_to, _amount);

        return true;
    }
}
