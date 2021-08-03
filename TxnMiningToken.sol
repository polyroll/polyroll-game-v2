// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/token/ERC20/ERC20.sol";

contract TxnMiningToken is ERC20("Txn Mining Token", "TXNMINE"), Ownable { 
    function mint(address _to, uint256 _amount) public onlyOwner {
        _mint(_to, _amount);
    }
}