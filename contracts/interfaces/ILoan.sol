// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;


interface ILoan {

    // =========================================================
    // ENUMS
    // =========================================================

    enum LoanStatus {
        PENDING,    // 0 — Chờ lender cấp vốn
        ACTIVE,     // 1 — Đang hoạt động (đã funded)
        REPAID,     // 2 — Đã trả đầy đủ
        OVERDUE,    // 3 — Quá hạn (chưa vượt grace period)
        DEFAULTED,  // 4 — Vỡ nợ (> grace period, chưa liquidated)
        LIQUIDATED, // 5 — Đã thanh lý tài sản thế chấp
        CANCELLED   // 6 — Hủy trước khi được fund
    }

    // =========================================================
    // STRUCTS
    // =========================================================

    struct LoanDetails {
        uint256 loanId;
        address borrower;
        address lender;
        address loanToken;          // Token cho vay (e.g., USDT)
        address collateralToken;    // address(0) = ETH, khác = ERC-20
        uint256 principal;          // Số tiền gốc (loanToken decimals)
        uint256 interestRate;       // Lãi suất năm (basis points, 1000 = 10%)
        uint256 collateralAmount;   // Số lượng tài sản thế chấp
        uint256 duration;           // Thời hạn vay (giây)
        uint256 startTime;          // Thời điểm được fund (block.timestamp)
        uint256 endTime;            // Thời điểm đáo hạn
        uint256 createdAt;          // Thời điểm tạo request
        LoanStatus status;
    }

    // =========================================================
    // EVENTS — Đầy đủ cho indexer / subgraph
    // =========================================================

    event LoanCreated(
        uint256 indexed loanId,
        address indexed borrower,
        address loanToken,
        address collateralToken,
        uint256 principal,
        uint256 interestRate,
        uint256 collateralAmount,
        uint256 duration
    );

    event LoanFunded(
        uint256 indexed loanId,
        address indexed lender,
        uint256 startTime,
        uint256 endTime
    );

    
    event LoanRepaid(
        uint256 indexed loanId,
        address indexed borrower,
        address indexed payer,      // Người thực sự chuyển USDT (có thể != borrower)
        uint256 principal,
        uint256 interest,
        uint256 lateFee,
        uint256 totalAmount,
        uint256 repaidAt,           // block.timestamp khi trả
        bool    isOverdue           // Có trả trễ không
    );

    /**
     * @dev Emit khi collateral được trả về borrower thành công
     */
    event CollateralReleased(
        uint256 indexed loanId,
        address indexed borrower,
        address token,
        uint256 amount
    );

    /**
     * @dev Emit khi release collateral fail (try-catch)
     * Borrower cần gọi manual withdrawal sau đó
     */
    event CollateralReleaseFailed(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 collateralAmount,
        string  reason
    );

    event LoanLiquidated(
        uint256 indexed loanId,
        address indexed liquidator,
        uint256 collateralSeized
    );

    event LoanCancelled(
        uint256 indexed loanId,
        address indexed borrower
    );

    event LoanOverdue(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 overdueAt,
        uint256 daysOverdue
    );

    // =========================================================
    // WRITE FUNCTIONS
    // =========================================================

    function initialize(
        uint256 _loanId,
        address _borrower,
        address _loanToken,
        address _collateralToken,
        uint256 _principal,
        uint256 _interestRate,
        uint256 _collateralAmount,
        uint256 _duration,
        uint256 _lateFeeRate,
        address _collateralManager
    ) external;

    /// @dev Lender cấp vốn — chỉ factory được gọi
    function fund(address lender) external;

    
    function repay() external;

    
    function repayOnBehalf(address payer) external;

    /// @dev Thanh lý — chỉ factory được gọi
    function liquidate() external;

    /// @dev Hủy request — chỉ borrower, chỉ khi PENDING
    function cancel() external;

    // =========================================================
    // VIEW FUNCTIONS
    // =========================================================

    function getLoanDetails() external view returns (LoanDetails memory);

    /// @dev Tổng số tiền cần trả tại block.timestamp hiện tại
    function getTotalRepaymentAmount() external view returns (uint256);

    /**
     * @dev Breakdown số tiền cần trả: (principal, interest, lateFee)
     *
     * Interest được cap tại endTime (không tăng sau đáo hạn).
     * Late fee tính riêng từ endTime đến block.timestamp.
     */
    function getRepaymentBreakdown()
        external
        view
        returns (uint256 principal, uint256 interest, uint256 lateFee);

    /// @dev Kiểm tra loan có đang quá hạn không
    function isOverdue() external view returns (bool);

    /**
     * @dev Tỷ lệ thế chấp hiện tại
     * @return 0 nếu cần oracle (dùng CollateralManager.getCollateralRatio)
     */
    function getCurrentCollateralRatio() external view returns (uint256);

    /**
     * @dev Timestamp khi đã repaid (0 nếu chưa trả)
     * Dùng cho audit và indexer
     */
    function repaidAt() external view returns (uint256);

    /**
     * @dev Địa chỉ payer thực sự (khác borrower nếu repayOnBehalf)
     */
    function actualPayer() external view returns (address);
}
