// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/IPriceOracle.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockPriceOracle
 * @dev Oracle giá giả lập để test trên testnet
 */
contract MockPriceOracle is IPriceOracle, Ownable {
    // Lưu giá và timestamp cập nhật gần nhất
    struct PriceData {
        uint256 price;      // price * 1e8 (8 decimals)
        uint256 timestamp;  // block.timestamp lúc cập nhật
    }
    
    mapping(address => PriceData) public priceData;
    mapping(address => address) public priceFeeds; // Mock price feed addresses
    
    constructor(address initialOwner) Ownable(initialOwner) {
        // Set giá mặc định cho ETH = $2000
        priceData[address(0)] = PriceData({
            price: 2000 * 1e8,
            timestamp: block.timestamp
        });
    }
    
    /**
     * @dev Set giá cho token (chỉ owner)
     * @param token Địa chỉ token (address(0) = ETH)
     * @param price Giá * 1e8 (VD: 2000 USD = 2000 * 1e8)
     */
    function setPrice(address token, uint256 price) external onlyOwner {
        priceData[token] = PriceData({
            price: price,
            timestamp: block.timestamp
        });
        emit PriceUpdated(token, price, block.timestamp);
    }
    
    /**
     * @dev Set mock price feed address
     */
    function setPriceFeed(address token, address priceFeed) external onlyOwner {
        priceFeeds[token] = priceFeed;
        emit PriceFeedUpdated(token, priceFeed);
    }
    
    /**
     * @dev Lấy giá của token
     * @return price Giá (8 decimals)
     * @return timestamp Thời điểm cập nhật
     */
    function getPrice(address token) 
        external 
        view 
        override 
        returns (uint256 price, uint256 timestamp) 
    {
        PriceData memory data = priceData[token];
        require(data.price > 0, "Price not set");
        return (data.price, data.timestamp);
    }
    
    /**
     * @dev Lấy giá tương đối giữa 2 token
     * VD: ETH/USDT = bao nhiêu USDT cho 1 ETH
     */
    function getRelativePrice(
        address baseToken,
        address quoteToken
    ) external view override returns (uint256) {
        PriceData memory baseData = priceData[baseToken];
        PriceData memory quoteData = priceData[quoteToken];
        
        require(baseData.price > 0, "Base token price not set");
        require(quoteData.price > 0, "Quote token price not set");
        
        // basePrice / quotePrice * 1e8
        return (baseData.price * 1e8) / quoteData.price;
    }
    
    /**
     * @dev Kiểm tra token có được hỗ trợ không
     */
    function isTokenSupported(address token) 
        external 
        view 
        override 
        returns (bool) 
    {
        return priceData[token].price > 0;
    }
    
    /**
     * @dev Lấy địa chỉ price feed (mock)
     */
    function getPriceFeed(address token) 
        external 
        view 
        override 
        returns (address) 
    {
        return priceFeeds[token];
    }
    
    /**
     * @dev Tính giá trị collateral bằng USD
     * @param token Địa chỉ token
     * @param amount Số lượng token (18 decimals)
     * @return Giá trị USD (8 decimals)
     */
    function getCollateralValue(
        address token,
        uint256 amount
    ) external view returns (uint256) {
        PriceData memory data = priceData[token];
        require(data.price > 0, "Price not set");
        // amount (18 decimals) * price (8 decimals) / 1e18 = value (8 decimals)
        return (amount * data.price) / 1e18;
    }
}