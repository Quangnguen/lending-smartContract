// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IPriceOracle
 * @dev Interface chuẩn cho price oracle — hỗ trợ cả manual feed và Chainlink
 *
 * Thiết kế:
 * - getPrice()      — đọc giá + timestamp (không revert nếu stale)
 * - getPriceSafe()  — revert nếu price stale quá maxAge
 * - maxPriceAge     — configurable staleness threshold
 *
 * Production: implement bằng Chainlink AggregatorV3Interface
 * Testnet:    implement bằng MockPriceOracle (setPrice thủ công)
 */
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

    /**
     * @dev Lấy giá token — KHÔNG kiểm tra staleness
     * @param token Địa chỉ token (address(0) = ETH/native)
     * @return price   Giá tính bằng USD với 8 decimals (chuẩn Chainlink)
     * @return timestamp Thời điểm cập nhật giá (block.timestamp)
     */
    function getPrice(address token)
        external
        view
        returns (uint256 price, uint256 timestamp);

    /**
     * @dev Lấy giá token — REVERT nếu stale hơn maxPriceAge giây
     * Đây là hàm nên dùng trong createLoanRequest và liquidation
     *
     * @param token Địa chỉ token
     * @return price Giá (8 decimals, chuẩn Chainlink)
     */
    function getPriceSafe(address token)
        external
        view
        returns (uint256 price);

    /**
     * @dev Tính giá trị USD của một lượng token
     * @param token     Địa chỉ token (address(0) = ETH)
     * @param amount    Số lượng token (wei, 18 decimals với ETH; hoặc theo decimals token)
     * @param decimals  Số decimals của token (18 với ETH, 6 với USDT)
     * @return valueUSD Giá trị USD (6 decimals để khớp với USDT principal)
     */
    function getValueInUSD(address token, uint256 amount, uint8 decimals)
        external
        view
        returns (uint256 valueUSD);

    /**
     * @dev Giá tương đối: bao nhiêu quoteToken cho 1 baseToken
     * VD: getRelativePrice(ETH, USDT) = 2000_000000 (2000 USDT per ETH, 6 dec)
     */
    function getRelativePrice(address baseToken, address quoteToken)
        external
        view
        returns (uint256);

    function isTokenSupported(address token) external view returns (bool);

    function getPriceFeed(address token) external view returns (address);
}
