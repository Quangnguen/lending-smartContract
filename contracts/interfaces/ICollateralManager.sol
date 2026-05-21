// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../libraries/LiquidationLib.sol";

/**
 * @title ICollateralManager
 * @dev Interface cho CollateralManager — Escrow layer của hệ thống
 *
 * ─── Vai trò trong hệ thống ───────────────────────────────────────────
 *
 *   P2PLending (factory) → CollateralManager (escrow)
 *
 *   1. depositCollateral(): Nhận và lock collateral khi createLoanRequest()
 *   2. registerLoan(): Link requestId ↔ Loan clone sau khi fund
 *   3. setAuthorizedCaller(): Cấp quyền Loan clone gọi withdrawCollateral()
 *   4. withdrawCollateral(): Borrower nhận lại khi repay/cancel
 *   5. liquidateCollateral(): Phân phối collateral khi liquidation
 *
 * ─── Liquidation Flow Update ──────────────────────────────────────────
 *
 *   TRƯỚC:
 *     P2PLending.liquidateLoan() → CM.liquidateCollateral()
 *     CM tự tính giá oracle trong liquidateCollateral() → risk của giá mới
 *
 *   SAU (production-ready):
 *     P2PLending tính LiquidationSnapshot (1 lần oracle read)
 *     P2PLending gọi CM.liquidateCollateralWithSnapshot(snapshot, liquidator)
 *     CM chỉ phân phối theo snapshot — không gọi oracle nữa
 *     → Giá nhất quán, audit trail rõ ràng
 */
interface ICollateralManager {

    // =========================================================
    // EVENTS
    // =========================================================

    event CollateralDeposited(
        uint256 indexed loanId,
        address indexed borrower,
        address token,
        uint256 amount
    );

    event CollateralWithdrawn(
        uint256 indexed loanId,
        address indexed recipient,
        address token,
        uint256 amount
    );

    /**
     * @dev Emit khi thanh lý collateral thành công
     *
     * Trường healthFactor: HF tại thời điểm liquidation (audit trail)
     * Trường isBadDebt: True nếu collateral < debt → protocol loss
     * Trường debtAmount: Tổng USDT liquidator đã trả (đồng bộ với LoanRepaid)
     */
    event CollateralLiquidated(
        uint256 indexed loanId,
        address indexed liquidator,
        address indexed borrower,
        address collateralToken,
        uint256 collateralSeized,   // Tổng collateral liquidator nhận
        uint256 bonusAmount,        // Phần bonus trong collateralSeized
        uint256 borrowerRefund,     // Surplus về borrower
        uint256 debtAmount,         // USDT debt đã được trả
        uint256 healthFactor,       // HF tại thời điểm liquidation
        bool    isBadDebt           // True nếu protocol lỗ
    );

    event LoanRegistered(
        uint256 indexed loanId,
        address indexed loanContract,
        address indexed registeredBy
    );

    event CallerAuthorized(
        address indexed caller,
        bool status,
        address indexed authorizedBy
    );

    event LiquidationThresholdUpdated(
        uint256 oldThreshold,
        uint256 newThreshold
    );

    event LiquidationBonusUpdated(
        uint256 oldBonus,
        uint256 newBonus
    );

    /// @dev Emit khi bad debt xảy ra — để insurance/reserve fund track
    event BadDebtRecorded(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 debtAmount,
        uint256 collateralSeized,
        uint256 deficit    // debtAmount - collateralValueUSD
    );

    // =========================================================
    // CORE FUNCTIONS
    // =========================================================

    /**
     * @dev Nhận và lock collateral từ borrower
     * ETH: msg.value = amount, token = address(0)
     * ERC-20: token != address(0), đã được transfer trước hoặc pull ở đây
     */
    function depositCollateral(
        uint256 loanId,
        address borrower,
        address token,
        uint256 amount
    ) external payable;

    /**
     * @dev Trả collateral về borrower khi repay/cancel
     * Caller: borrower trực tiếp, hoặc Loan contract (đã được authorize)
     */
    function withdrawCollateral(uint256 loanId) external;

    /**
     * @dev Thanh lý collateral theo pre-computed snapshot (production path)
     *
     * P2PLending tính LiquidationSnapshot 1 lần:
     *   → Đọc oracle giá, tính health factor, tính phân phối
     * Rồi gọi hàm này với snapshot đã tính
     * CM chỉ execute distribution theo snapshot — không gọi oracle nữa
     *
     * Lợi ích:
     *   • Oracle chỉ được đọc 1 lần → không có inconsistency
     *   • Gas: tiết kiệm 1 oracle call (~5000 gas)
     *   • Audit: snapshot là bằng chứng irrefutable về trạng thái lúc liquidation
     *
     * @param snapshot Pre-computed liquidation snapshot từ P2PLending
     * @param liquidator Địa chỉ nhận collateral + bonus
     */
    function liquidateCollateralWithSnapshot(
        LiquidationLib.LiquidationSnapshot calldata snapshot,
        address liquidator
    ) external;

    // =========================================================
    // ADMIN FUNCTIONS
    // =========================================================

    /**
     * @dev Cấp quyền cho Loan clone gọi withdrawCollateral()
     * Chỉ owner (P2PLending) được gọi
     */
    function setAuthorizedCaller(address caller, bool status) external;

    /**
     * @dev Đăng ký Loan contract cho requestId
     * Chỉ owner (P2PLending) được gọi, không thể overwrite
     */
    function registerLoan(uint256 loanId, address loanContract) external;

    // =========================================================
    // VIEW FUNCTIONS
    // =========================================================

    /// @dev Giá trị collateral tính theo USD (6 decimals)
    function getCollateralValue(uint256 loanId) external view returns (uint256);

    /// @dev Tỷ lệ collateral hiện tại (basis points, 15000 = 150%)
    function getCollateralRatio(uint256 loanId) external view returns (uint256);

    /**
     * @dev Kiểm tra loan có đủ điều kiện thanh lý không
     *
     * Liquidatable khi:
     *   (A) HF < liquidationThreshold (dưới 110%), HOẶC
     *   (B) isOverdue = true (quá hạn)
     */
    function isLiquidatable(uint256 loanId) external view returns (bool);

    /**
     * @dev Lấy đầy đủ thông tin để tính liquidation snapshot
     * Dùng cho frontend/keeper để simulate trước khi liquidate
     *
     * @return healthFactor     HF hiện tại (basis points)
     * @return collateralValueUSD Giá trị USD của collateral (6 dec)
     * @return debtAmount       Tổng USDT debt (6 dec)
     * @return isLiquidatable_  Có thể liquidate không
     * @return triggerPrice     Giá collateral mà dưới đó sẽ liquidatable (8 dec)
     */
    function getLiquidationStatus(uint256 loanId)
        external
        view
        returns (
            uint256 healthFactor,
            uint256 collateralValueUSD,
            uint256 debtAmount,
            bool    isLiquidatable_,
            uint256 triggerPrice
        );

    /// @dev Ngưỡng liquidation (basis points, 11000 = 110%)
    function getLiquidationThreshold() external view returns (uint256);

    /// @dev Bonus cho liquidator (basis points, 500 = 5%)
    function getLiquidationBonus() external view returns (uint256);

    /// @dev Loan contract đã đăng ký cho loanId
    function getLoanContract(uint256 loanId) external view returns (address);

    /// @dev Thông tin collateral của một loan
    function getCollateralInfo(uint256 loanId)
        external
        view
        returns (
            address token,
            uint256 amount,
            address borrower,
            bool    isActive,
            uint8   decimals
        );

    /// @dev Tổng bad debt đã xảy ra (USD, 6 dec) — cho insurance/reserve tracking
    function totalBadDebt() external view returns (uint256);
}
