// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IPriceOracle {
    // EVENT
    event PriceFeedUpdated(
        address indexed token,
        address indexed priceFeed
    );

    event PriceUpdated(
        address indexed token,
        uint256 price,
        uint256 timestamp
    );

    // FUNCTION
    function getPrice(address token)
        external
        view
        returns (uint256 price, uint256 timestamp);

    // Lấy giá tương đối giữa 2 token
    // VD: ETH/USDT = bao nhiêu USDT cho 1 ETH
    function getRelativePrice(
        address baseToken,
        address quoteToken
    )
        external
        view
        returns (uint256);

    function isTokenSupported(address token)
        external
        view
        returns (bool);

     // Lấy địa chỉ Chainlink price feed
    function getPriceFeed(address token)
        external
        view
        returns (address);
}
