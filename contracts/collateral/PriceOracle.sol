// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IPriceOracle.sol";

contract PriceOracle is IPriceOracle, Ownable {
    address public constant ETH_ADDRESS = address(0);
    uint256 public constant PRICE_PRECISION = 1e18;

    mapping(address => address) public priceFeeds;
    mapping(address => uint256) public manualPrices;
    mapping(address => uint256) public lastUpdateTime;
    address[] public supportedTokens;

    constructor(address initialOwner) Ownable(initialOwner) {}
    
    function setPrice(address token, uint256 price) external onlyOwner {
        if (manualPrices[token] == 0 && price > 0) {
            supportedTokens.push(token);
        }
        manualPrices[token] = price;
        lastUpdateTime[token] = block.timestamp;
        emit PriceUpdated(token, price, block.timestamp);
    }

    function setPriceFeed(address token, address priceFeed) external onlyOwner {
        if (priceFeeds[token] == address(0) && priceFeed != address(0)) {
            supportedTokens.push(token);
        }
        priceFeeds[token] = priceFeed;
        emit PriceFeedUpdated(token, priceFeed);
    }

    function getPrice(address token) 
        external view override 
        returns (uint256 price, uint256 timestamp) 
    {
        if (manualPrices[token] > 0) {
            return (manualPrices[token], lastUpdateTime[token]);
        }
        revert("Price not available");
    }

    function getRelativePrice(
        address baseToken,
        address quoteToken
    ) external view override returns (uint256) {
        (uint256 basePrice,) = this.getPrice(baseToken);
        (uint256 quotePrice,) = this.getPrice(quoteToken);
        if (quotePrice == 0) revert("Quote price is zero");
        return (basePrice * PRICE_PRECISION) / quotePrice;
    }

    function isTokenSupported(address token) external view override returns (bool) {
        return manualPrices[token] > 0 || priceFeeds[token] != address(0);
    }

    function getPriceFeed(address token) external view override returns (address) {
        return priceFeeds[token];
    }
    
    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }
}