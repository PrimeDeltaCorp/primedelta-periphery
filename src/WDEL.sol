// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    IWETH9
} from "@uniswap/v3-periphery/contracts/interfaces/external/IWETH9.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract WDEL is ERC20, IWETH9 {
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    constructor() ERC20("Wrapped DEL", "WDEL") {}

    receive() external payable {
        deposit();
    }

    function deposit() public payable override {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    function mint(address to, uint256 amount) public {
        require(block.chainid == 31337, "WDEL: mint only on local");
        _mint(to, amount);
    }

    /// @notice Wrap native DEL and approve spender in a single transaction
    /// @param spender Address to approve for spending the wrapped tokens
    function depositAndApprove(address spender) public payable {
        _mint(msg.sender, msg.value);
        _approve(msg.sender, spender, type(uint256).max);
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) public override {
        require(balanceOf(msg.sender) >= amount, "WDEL: insufficient balance");
        _burn(msg.sender, amount);
        emit Withdrawal(msg.sender, amount);
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "WDEL: DEL transfer failed");
    }
}
