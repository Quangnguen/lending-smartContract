// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../interfaces/IPriceOracle.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";


contract MockPriceOracle is IPriceOracle, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet; // FIX M-11

    // =========================================================
    // STRUCTS
    // =========================================================

    struct PriceData {
        uint256 price;      // 8 decimals (Chainlink standard)
        uint256 updatedAt;  // block.timestamp khi update
    }

    // =========================================================
    // STATE
    // =========================================================

    uint256 private _maxPriceAge = 3600; // 1 giờ mặc định (configurable)

    mapping(address => PriceData) private _priceData;
    mapping(address => address)   public  priceFeeds;
    mapping(address => bool)      private _supported;

    EnumerableSet.AddressSet private _tokenSet;

    error MockPriceOracle__PriceNotSet(address token);
    error MockPriceOracle__PriceStale(address token, uint256 age, uint256 maxAge);
    error MockPriceOracle__ZeroPrice();

    // =========================================================
    // CONSTRUCTOR
    // =========================================================

    constructor(address initialOwner) Ownable(initialOwner) {
        // ETH mặc định $2000 (8 decimals)
        _setPrice(address(0), 2_000 * 1e8);
    }

    // =========================================================
    // IPriceOracle IMPLEMENTATION
    // =========================================================

    /// @inheritdoc IPriceOracle
    function maxPriceAge() external view override returns (uint256) {
        return _maxPriceAge;
    }

    /// @inheritdoc IPriceOracle
    function getPrice(address token)
        external
        view
        override
        returns (uint256 price, uint256 timestamp)
    {
        PriceData memory data = _priceData[token];
        if (data.price == 0) revert MockPriceOracle__PriceNotSet(token);
        return (data.price, data.updatedAt);
    }

    /// @inheritdoc IPriceOracle
    /// @dev Revert nếu price stale hơn maxPriceAge giây
    function getPriceSafe(address token)
        external
        view
        override
        returns (uint256 price)
    {
        PriceData memory data = _priceData[token];
        if (data.price == 0) revert MockPriceOracle__PriceNotSet(token);

        uint256 age = block.timestamp - data.updatedAt;
        if (age > _maxPriceAge) {
            revert MockPriceOracle__PriceStale(token, age, _maxPriceAge);
        }

        return data.price;
    }

    /// @inheritdoc IPriceOracle
    /// @dev Tính giá trị USD (6 decimals) từ amount token
    function getValueInUSD(address token, uint256 amount, uint8 decimals)
        external
        view
        override
        returns (uint256 valueUSD)
    {
        PriceData memory data = _priceData[token];
        if (data.price == 0) revert MockPriceOracle__PriceNotSet(token);

        // amount (decimals) * price (8dec) / (10^decimals * 10^2) = USD (6dec)
        return (amount * data.price) / (10 ** uint256(decimals) * 1e2);
    }

    /// @inheritdoc IPriceOracle
    function getRelativePrice(address baseToken, address quoteToken)
        external
        view
        override
        returns (uint256)
    {
        PriceData memory base  = _priceData[baseToken];
        PriceData memory quote = _priceData[quoteToken];

        if (base.price == 0)  revert MockPriceOracle__PriceNotSet(baseToken);
        if (quote.price == 0) revert MockPriceOracle__PriceNotSet(quoteToken);

        return (base.price * 1e8) / quote.price;
    }

    /// @inheritdoc IPriceOracle
    function isTokenSupported(address token) external view override returns (bool) {
        return _supported[token];
    }

    /// @inheritdoc IPriceOracle
    function getPriceFeed(address token) external view override returns (address) {
        return priceFeeds[token];
    }

    // =========================================================
    // HELPER — tính giá trị collateral (dùng trong tests)
    // =========================================================

   
    function getCollateralValue(address token, uint256 amount)
        external
        view
        returns (uint256)
    {
        PriceData memory data = _priceData[token];
        if (data.price == 0) revert MockPriceOracle__PriceNotSet(token);
        return (amount * data.price) / 1e18;
    }

    // =========================================================
    // ADMIN — Testnet helpers
    // =========================================================

   
    function setPrice(address token, uint256 price) external onlyOwner {
        if (price == 0) revert MockPriceOracle__ZeroPrice();
        _setPrice(token, price);
    }

    /**
     * @dev Set mock price feed address
     */
    function setPriceFeed(address token, address feed) external onlyOwner {
        priceFeeds[token] = feed;
        emit PriceFeedUpdated(token, feed);
    }

    /**
     * @dev Cập nhật staleness threshold (cho tests)
     */
    function setMaxPriceAge(uint256 newAge) external onlyOwner {
        _maxPriceAge = newAge;
        emit MaxPriceAgeUpdated(0, newAge);
    }

    
    function getSupportedTokens() external view returns (address[] memory) {
        return _tokenSet.values();
    }

    // =========================================================
    // INTERNAL
    // =========================================================

    function _setPrice(address token, uint256 price) internal {
        _priceData[token] = PriceData({price: price, updatedAt: block.timestamp});

        if (!_supported[token]) {
            _supported[token] = true;
            _tokenSet.add(token); // FIX M-11: EnumerableSet thay vì push
        }

        emit PriceUpdated(token, price, block.timestamp);
    }
}
