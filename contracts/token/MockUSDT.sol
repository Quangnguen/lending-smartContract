// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
    * @title MockUSDT
    * @dev Token USDT giả để sử dụng trong môi trường test
 */

contract MockUSDT is ERC20, Ownable {
    uint8 private constant DECIMALS = 6;

    constructor(address initialOwner) 
        ERC20 ("Mock USDT", "mUSDT")
        Ownable(initialOwner)
    {
        // Mint 1000000 USDT cho chủ sở hữu ban đầu
        _mint(initialOwner, 1_000_000 * 10 ** DECIMALS);
    }

    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }

    /**
     * @dev Cho phép bất kỳ ai mint token để test
     * Chỉ dùng cho testnet!
     */
    function faucet(address to, uint256 amount) external {
        require(amount <= 10000*10 ** DECIMALS, "Max 10k mUSDT per faucet call");
        _mint(to, amount);
    }

    /**
     * @dev Owner có thể mint không giới hạn
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}