// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;


interface IPriceOracle {

    // =========================================================
    // CONSTANTS
    // =========================================================

    /// @dev Staleness threshold mặc định: 1 giờ
    function maxPriceAge() external view returns (uint256);

    // =========================================================
    // EVENTS
    // =========================================================

    event PriceFeedUpdated(address indexed token, address indexed priceFeed);

    event PriceUpdated(address indexed token, uint256 price, uint256 timestamp);

    event MaxPriceAgeUpdated(uint256 oldAge, uint256 newAge);

    // =========================================================
    // READ FUNCTIONS
    // =========================================================

    
    function getPrice(address token)
        external
        view
        returns (uint256 price, uint256 timestamp);

    function getPriceSafe(address token)
        external
        view
        returns (uint256 price);

    function getValueInUSD(address token, uint256 amount, uint8 decimals)
        external
        view
        returns (uint256 valueUSD);

    
    function getRelativePrice(address baseToken, address quoteToken)
        external
        view
        returns (uint256);

    function isTokenSupported(address token) external view returns (bool);

    function getPriceFeed(address token) external view returns (address);
}
