// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../interfaces/IPriceOracle.sol";

/**
 * @title CollateralLib
 * @dev Library xử lý logic collateral cho cả ETH và ERC-20
 *
 * Tách ra khỏi P2PLending để:
 * - Giữ P2PLending gọn, dễ audit
 * - Tái sử dụng qua nhiều contract
 * - Test riêng biệt collateral math
 *
 * Decimal convention trong library này:
 * - Tất cả giá trị USD dùng 6 decimals (khớp với USDT principal)
 * - Price feed dùng 8 decimals (chuẩn Chainlink) → scale về 6 decimals nội bộ
 */
library CollateralLib {

    uint256 internal constant USD_DECIMALS     = 6;
    uint256 internal constant PRICE_DECIMALS   = 8;  // Chainlink standard
    uint256 internal constant PRICE_SCALE      = 10 ** PRICE_DECIMALS;

    // =========================================================
    // ERRORS
    // =========================================================

    error CollateralLib__TokenNotSupported(address token);
    error CollateralLib__PriceStale(address token, uint256 age, uint256 maxAge);
    error CollateralLib__ZeroPrice(address token);
    error CollateralLib__ETHValueMismatch(uint256 msgValue, uint256 declared);
    error CollateralLib__ERC20CollateralETHSent();

    // =========================================================
    // COLLATERAL VALUE CALCULATION
    // =========================================================

    /**
     * @notice Tính giá trị USD của ETH collateral
     *
     * Formula: valueUSD = (ethAmount_wei * ethPrice_8dec) / 1e18 / 1e2
     *                   = (ethAmount_wei * ethPrice_8dec) / 1e20
     * → Result: USD với 6 decimals
     *
     * @param ethAmount  Số lượng ETH (wei, 18 decimals)
     * @param ethPrice   Giá ETH/USD (8 decimals, Chainlink format)
     * @return valueUSD  Giá trị USD (6 decimals)
     */
    function getETHCollateralValueUSD(
        uint256 ethAmount,
        uint256 ethPrice
    ) internal pure returns (uint256 valueUSD) {
        // ethAmount (1e18) * ethPrice (1e8) / 1e20 = USD (1e6)
        return (ethAmount * ethPrice) / (1e18 * 1e2);
    }

    /**
     * @notice Tính giá trị USD của ERC-20 collateral
     *
     * @param tokenAmount   Số lượng token
     * @param tokenPrice    Giá token/USD (8 decimals)
     * @param tokenDecimals Số decimals của token
     * @return valueUSD     Giá trị USD (6 decimals)
     */
    function getERC20CollateralValueUSD(
        uint256 tokenAmount,
        uint256 tokenPrice,
        uint8   tokenDecimals
    ) internal pure returns (uint256 valueUSD) {
        // tokenAmount (tokenDecimals) * tokenPrice (8 dec) / 10^tokenDecimals / 100 → USD (6 dec)
        return (tokenAmount * tokenPrice) / (10 ** tokenDecimals * 1e2);
    }

    /**
     * @notice Lấy giá trị USD của collateral bất kỳ (ETH hoặc ERC-20)
     * Dùng getPriceSafe() → revert nếu stale
     *
     * @param oracle            IPriceOracle instance
     * @param collateralToken   address(0) = ETH, khác = ERC-20
     * @param collateralAmount  Số lượng collateral
     * @param collateralDecimals Số decimals của collateral token
     * @return valueUSD         Giá trị USD (6 decimals)
     */
    function getCollateralValueUSD(
        IPriceOracle oracle,
        address collateralToken,
        uint256 collateralAmount,
        uint8   collateralDecimals
    ) internal view returns (uint256 valueUSD) {
        uint256 price = oracle.getPriceSafe(collateralToken);
        if (price == 0) revert CollateralLib__ZeroPrice(collateralToken);

        if (collateralToken == address(0)) {
            // ETH — 18 decimals
            return getETHCollateralValueUSD(collateralAmount, price);
        } else {
            // ERC-20
            return getERC20CollateralValueUSD(collateralAmount, price, collateralDecimals);
        }
    }

    // =========================================================
    // COLLATERAL VALIDATION
    // =========================================================

    /**
     * @notice Validate ETH collateral khi tạo loan request
     *
     * Kiểm tra:
     * 1. msg.value >= request.collateralAmount (đủ ETH)
     * 2. Giá trị USD đủ theo required ratio (nếu có oracle)
     * 3. Trả lại ETH dư (nếu user gửi thừa)
     *
     * @param msgValue          ETH được gửi (msg.value)
     * @param collateralAmount  ETH borrower khai báo
     * @param principalUSD      Giá trị khoản vay (USD, 6 dec)
     * @param requiredRatioBps  Tỷ lệ thế chấp yêu cầu (basis points)
     * @param oracle            Price oracle (có thể == address(0))
     * @return excessETH        ETH dư cần hoàn trả cho borrower
     */
    function validateETHCollateral(
        uint256       msgValue,
        uint256       collateralAmount,
        uint256       principalUSD,
        uint256       requiredRatioBps,
        IPriceOracle  oracle
    ) internal view returns (uint256 excessETH) {
        // Check 1: ETH gửi >= ETH khai báo
        if (msgValue < collateralAmount) {
            revert CollateralLib__ETHValueMismatch(msgValue, collateralAmount);
        }

        // Check 2: Giá trị USD đủ không (nếu oracle khả dụng)
        if (address(oracle) != address(0) && oracle.isTokenSupported(address(0))) {
            uint256 collateralValueUSD = getCollateralValueUSD(
                oracle, address(0), collateralAmount, 18
            );
            uint256 requiredUSD = (principalUSD * requiredRatioBps) / 10_000;
            if (collateralValueUSD < requiredUSD) {
                revert CollateralLib__ETHValueMismatch(collateralValueUSD, requiredUSD);
            }
        }

        // ETH dư (nếu có) → sẽ được refund
        excessETH = msgValue - collateralAmount;
    }

    /**
     * @notice Validate ERC-20 collateral khi tạo loan request
     * Borrower phải đã approve CollateralManager trước
     *
     * @param collateralToken   Địa chỉ ERC-20 token
     * @param collateralAmount  Số lượng token
     * @param collateralDecimals Decimals của token
     * @param principalUSD      Giá trị khoản vay (USD, 6 dec)
     * @param requiredRatioBps  Tỷ lệ thế chấp yêu cầu (basis points)
     * @param oracle            Price oracle
     * @param msgValue          msg.value — phải = 0 cho ERC-20 collateral
     */
    function validateERC20Collateral(
        address      collateralToken,
        uint256      collateralAmount,
        uint8        collateralDecimals,
        uint256      principalUSD,
        uint256      requiredRatioBps,
        IPriceOracle oracle,
        uint256      msgValue
    ) internal view {
        // Không chấp nhận ETH khi dùng ERC-20 collateral
        if (msgValue > 0) revert CollateralLib__ERC20CollateralETHSent();

        // Check oracle có support token này không
        if (address(oracle) != address(0) && !oracle.isTokenSupported(collateralToken)) {
            revert CollateralLib__TokenNotSupported(collateralToken);
        }

        // Check collateral value đủ
        if (address(oracle) != address(0)) {
            uint256 collateralValueUSD = getCollateralValueUSD(
                oracle, collateralToken, collateralAmount, collateralDecimals
            );
            uint256 requiredUSD = (principalUSD * requiredRatioBps) / 10_000;
            if (collateralValueUSD < requiredUSD) {
                revert CollateralLib__ETHValueMismatch(collateralValueUSD, requiredUSD);
            }
        }
    }
}
