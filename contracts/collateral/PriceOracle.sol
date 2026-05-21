// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "../interfaces/IPriceOracle.sol";

/**
 * @title PriceOracle
 * @dev Oracle giá hỗ trợ cả manual feed (testnet) và Chainlink-ready (production)
 *
 * Kiến trúc 2 lớp:
 *   1. Chainlink AggregatorV3 (production) — đọc qua priceFeed address
 *   2. Manual price (testnet/fallback) — owner set thủ công
 *
 * Price format: 8 decimals (chuẩn Chainlink)
 *   VD: ETH = 2000 USD → price = 2_000_00_000_000 = 2000 * 1e8
 *
 * Staleness protection:
 *   - maxPriceAge: Thời gian tối đa giá được coi là valid (mặc định 3600s = 1h)
 *   - getPriceSafe(): revert nếu price stale quá maxPriceAge
 *   - Chainlink round data tự động có timestamp
 *
 * Production upgrade path:
 *   → setChainlinkFeed(token, feedAddress) để dùng Chainlink thay manual price
 *   → Chainlink ưu tiên hơn manual price nếu cả 2 đều set
 *
 * Bảo mật:
 *   - Pausable: owner có thể pause khi phát hiện oracle manipulation
 *   - Manual prices chỉ fallback khi không có Chainlink feed
 */
contract PriceOracle is IPriceOracle, Ownable, Pausable {

    // =========================================================
    // STRUCTS
    // =========================================================

    struct ManualPriceData {
        uint256 price;      // USD price × 1e8
        uint256 updatedAt;  // block.timestamp
    }

    // =========================================================
    // STATE
    // =========================================================

    /// @dev Thời gian tối đa giá còn valid (giây) — configurable
    uint256 private _maxPriceAge = 3600; // 1 giờ mặc định

    /// @dev Manual prices (testnet / fallback)
    mapping(address => ManualPriceData) private _manualPrices;

    /// @dev Chainlink AggregatorV3 feed addresses
    mapping(address => address) private _chainlinkFeeds;

    /// @dev Danh sách tokens được hỗ trợ (để iteration off-chain)
    address[] private _supportedTokens;
    mapping(address => bool) private _isSupported;

    // =========================================================
    // ERRORS
    // =========================================================

    error PriceOracle__PriceNotAvailable(address token);
    error PriceOracle__PriceStale(address token, uint256 age, uint256 maxAge);
    error PriceOracle__InvalidPrice(address token, int256 price);
    error PriceOracle__InvalidMaxAge(uint256 age);
    error PriceOracle__ZeroAddress();

    // =========================================================
    // ADDITIONAL EVENTS
    // =========================================================

    event ChainlinkFeedSet(address indexed token, address indexed feed);
    event ManualPriceSet(address indexed token, uint256 price, uint256 timestamp);

    // =========================================================
    // CONSTRUCTOR
    // =========================================================

    constructor(address initialOwner) Ownable(initialOwner) {
        // ETH default: $2000 cho testnet (owner nên update ngay sau deploy)
        _setManualPrice(address(0), 2_000 * 1e8);
    }

    // =========================================================
    // IPriceOracle IMPLEMENTATION
    // =========================================================

    /**
     * @inheritdoc IPriceOracle
     */
    function maxPriceAge() external view override returns (uint256) {
        return _maxPriceAge;
    }

    /**
     * @inheritdoc IPriceOracle
     * @dev Không revert nếu stale — caller tự kiểm tra timestamp
     */
    function getPrice(address token)
        external
        view
        override
        whenNotPaused
        returns (uint256 price, uint256 timestamp)
    {
        return _getPrice(token);
    }

    /**
     * @inheritdoc IPriceOracle
     * @dev REVERT nếu price stale > maxPriceAge
     * Dùng hàm này trong createLoanRequest và liquidation
     */
    function getPriceSafe(address token)
        external
        view
        override
        whenNotPaused
        returns (uint256 price)
    {
        (uint256 p, uint256 updatedAt) = _getPrice(token);
        uint256 age = block.timestamp - updatedAt;
        if (age > _maxPriceAge) {
            revert PriceOracle__PriceStale(token, age, _maxPriceAge);
        }
        return p;
    }

    /**
     * @inheritdoc IPriceOracle
     * @dev Tính giá trị USD của một lượng token
     *
     * USD output: 6 decimals (khớp với USDT principal)
     * Formula: valueUSD = amount * price / (10^tokenDecimals * 100)
     *   - price: 8 decimals (Chainlink)
     *   - tokenDecimals: decimals của token
     *   - /100 để down-scale từ 8dec → 6dec
     */
    function getValueInUSD(
        address token,
        uint256 amount,
        uint8   decimals
    )
        external
        view
        override
        whenNotPaused
        returns (uint256 valueUSD)
    {
        uint256 price = this.getPriceSafe(token);
        // amount (decimals) * price (8dec) / (10^decimals * 10^2) = USD (6dec)
        return (amount * price) / (10 ** decimals * 1e2);
    }

    /**
     * @inheritdoc IPriceOracle
     */
    function getRelativePrice(address baseToken, address quoteToken)
        external
        view
        override
        whenNotPaused
        returns (uint256)
    {
        (uint256 basePrice,)  = _getPrice(baseToken);
        (uint256 quotePrice,) = _getPrice(quoteToken);
        if (quotePrice == 0) revert PriceOracle__PriceNotAvailable(quoteToken);
        // Result: basePrice/quotePrice với 8 decimals precision
        return (basePrice * 1e8) / quotePrice;
    }

    /**
     * @inheritdoc IPriceOracle
     */
    function isTokenSupported(address token) external view override returns (bool) {
        return _isSupported[token];
    }

    /**
     * @inheritdoc IPriceOracle
     */
    function getPriceFeed(address token) external view override returns (address) {
        return _chainlinkFeeds[token];
    }

    // =========================================================
    // ADMIN FUNCTIONS
    // =========================================================

    /**
     * @dev Set giá thủ công (testnet / fallback)
     * @param token  Địa chỉ token (address(0) = ETH)
     * @param price  Giá × 1e8 (VD: 2000 USD = 200_000_000_000)
     */
    function setManualPrice(address token, uint256 price) external onlyOwner {
        if (price == 0) revert PriceOracle__InvalidPrice(token, 0);
        _setManualPrice(token, price);
    }

    /**
     * @dev Set Chainlink AggregatorV3 feed (production)
     * @param token    Token cần set feed
     * @param feed     Địa chỉ Chainlink AggregatorV3Interface
     */
    function setChainlinkFeed(address token, address feed) external onlyOwner {
        if (feed == address(0)) revert PriceOracle__ZeroAddress();
        _chainlinkFeeds[token] = feed;

        if (!_isSupported[token]) {
            _isSupported[token] = true;
            _supportedTokens.push(token);
        }

        emit ChainlinkFeedSet(token, feed);
        emit PriceFeedUpdated(token, feed);
    }

    /**
     * @dev Cập nhật staleness threshold
     * @param newAge Thời gian tối đa (giây). Min = 60s, Max = 86400s (1 ngày)
     */
    function setMaxPriceAge(uint256 newAge) external onlyOwner {
        if (newAge < 60 || newAge > 86_400) revert PriceOracle__InvalidMaxAge(newAge);
        uint256 old = _maxPriceAge;
        _maxPriceAge = newAge;
        emit MaxPriceAgeUpdated(old, newAge);
    }

    /**
     * @dev Pause oracle trong trường hợp khẩn cấp (oracle manipulation)
     */
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Lấy danh sách tokens được hỗ trợ
     */
    function getSupportedTokens() external view returns (address[] memory) {
        return _supportedTokens;
    }

    // =========================================================
    // INTERNAL
    // =========================================================

    /**
     * @dev Internal: Lấy giá từ Chainlink (nếu có feed) hoặc manual price
     *
     * Priority:
     *   1. Chainlink AggregatorV3 (nếu feed được set)
     *   2. Manual price (fallback / testnet)
     */
    function _getPrice(address token)
        internal
        view
        returns (uint256 price, uint256 updatedAt)
    {
        address feed = _chainlinkFeeds[token];

        if (feed != address(0)) {
            return _getChainlinkPrice(feed, token);
        }

        // Fallback: manual price
        ManualPriceData memory data = _manualPrices[token];
        if (data.price == 0) revert PriceOracle__PriceNotAvailable(token);
        return (data.price, data.updatedAt);
    }

    /**
     * @dev Đọc giá từ Chainlink AggregatorV3Interface
     *
     * Production note: Cần thêm Chainlink dependency và uncomment code bên dưới.
     * Hiện tại là stub để không phụ thuộc package ngoài.
     */
    function _getChainlinkPrice(address feed, address token)
        internal
        view
        returns (uint256 price, uint256 updatedAt)
    {
        AggregatorV3Interface aggregator = AggregatorV3Interface(feed);
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt_,
            uint80 answeredInRound
        ) = aggregator.latestRoundData();

        // Sanity checks chuẩn Chainlink để phòng ngừa Flash Loan / Oracle Manipulation
        if (answer <= 0)              revert PriceOracle__InvalidPrice(token, answer);
        if (updatedAt_ == 0)          revert PriceOracle__PriceStale(token, 0, 0);
        if (answeredInRound < roundId) revert PriceOracle__PriceStale(token, 0, 0);

        return (uint256(answer), updatedAt_);
    }

    function _setManualPrice(address token, uint256 price) internal {
        _manualPrices[token] = ManualPriceData({
            price: price,
            updatedAt: block.timestamp
        });

        if (!_isSupported[token]) {
            _isSupported[token] = true;
            _supportedTokens.push(token);
        }

        emit ManualPriceSet(token, price, block.timestamp);
        emit PriceUpdated(token, price, block.timestamp);
    }
}
