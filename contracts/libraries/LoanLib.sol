// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title LoanLib
 * @dev Pure/view library cho validation và tính toán khoản vay
 *
 * ─── Interest Model ────────────────────────────────────────────────────────
 *
 * Dùng Simple Interest (lãi đơn), không phải Compound (lãi kép):
 *   Interest = Principal × Rate × Time / (10000 × 365days)
 *
 * Lý do chọn Simple Interest:
 *   • Dễ audit và verify bởi borrower
 *   • Phù hợp fixed-term P2P lending (không có rollover)
 *   • Aave dùng compound (continuously), Compound dùng per-block accrual
 *   • P2P fixed-term loans (Morpho isolated, Maple Finance) dùng simple
 *
 * ─── Interest Cap (Quan trọng!) ─────────────────────────────────────────
 *
 * Interest được tính đến MIN(block.timestamp, endTime):
 *   • Nếu trả đúng hạn: interest = P × R × duration
 *   • Nếu trả trễ: interest = P × R × duration (không tăng thêm)
 *                  lateFee  = P × dailyRate × daysLate (tính riêng)
 *
 * Tại sao cap tại endTime?
 *   • Tránh double-counting: interest + lateFee không overlap
 *   • Borrower biết trước tổng interest tối đa (predictable)
 *   • Standard của Maple Finance, TrueFi, Centrifuge
 *
 * ─── Late Fee Model ─────────────────────────────────────────────────────
 *
 *   LateFee = Principal × dailyRate × daysLate
 *   dailyRate: basis points/ngày (50 = 0.5%/ngày)
 *   MAX_LATE_FEE_RATE: 20%/ngày (để chặn cài đặt vô lý)
 *
 * So sánh:
 *   Aave: không có late fee (chỉ có liquidation)
 *   MakerDAO: stability fee continues, penalty rate tăng khi liquidation
 *   Maple: late fee + default fee riêng biệt
 *   Dự án này: late fee đơn giản, không compounding
 */
library LoanLib {

    // =========================================================
    // CONSTANTS — Loan Lifecycle
    // =========================================================

    uint256 public constant BASIS_POINTS        = 10_000;

    /// @dev Lãi suất tối đa 200%/năm (20_000 bps)
    uint256 public constant MAX_INTEREST_RATE   = 20_000;

    /// @dev Lãi suất tối thiểu 0.1%/năm (10 bps)
    uint256 public constant MIN_INTEREST_RATE   = 10;

    /// @dev Thời hạn tối thiểu 1 ngày
    uint256 public constant MIN_DURATION        = 1 days;

    /// @dev Thời hạn tối đa 2 năm
    uint256 public constant MAX_DURATION        = 730 days;

    /// @dev Số tiền vay tối thiểu (1 USDT = 1_000_000 với 6 decimals)
    uint256 public constant MIN_PRINCIPAL       = 1_000_000;

    /// @dev Collateral ratio tối thiểu mặc định (150%)
    uint256 public constant DEFAULT_MIN_COLLATERAL_RATIO   = 15_000;

    /// @dev Ngưỡng thanh lý mặc định (110%)
    uint256 public constant DEFAULT_LIQUIDATION_THRESHOLD  = 11_000;

    /// @dev Tối đa 5 pending requests mỗi borrower (anti-spam)
    uint256 public constant MAX_PENDING_REQUESTS = 5;

    /// @dev Seconds per year (365 ngày)
    uint256 public constant SECONDS_PER_YEAR    = 365 days;

    /// @dev Late fee tối đa 20%/ngày (2000 bps) — chống abuse
    uint256 public constant MAX_LATE_FEE_RATE   = 2_000;

    /// @dev Grace period sau overdue trước khi có thể liquidate (1 ngày)
    uint256 public constant GRACE_PERIOD        = 1 days;

    /// @dev Precision multiplier để tránh precision loss trong division
    uint256 public constant PRECISION           = 1e18;

    // =========================================================
    // STRUCTS
    // =========================================================

    /**
     * @dev Breakdown đầy đủ số tiền trả nợ — dùng để emit event và validate
     *
     * Tại sao struct thay vì tuple?
     * → Khi thêm field mới (e.g., protocolFee), không cần đổi signature
     * → Dễ pass qua internal functions
     */
    struct RepaymentBreakdown {
        uint256 principal;      // Số tiền gốc
        uint256 interest;       // Lãi (cap tại endTime)
        uint256 lateFee;        // Phí trễ hạn (chỉ khi overdue)
        uint256 totalAmount;    // Tổng phải trả
        uint256 calculatedAt;   // block.timestamp khi tính
        bool    isOverdue;      // Có đang quá hạn không
        uint256 daysLate;       // Số ngày trễ (0 nếu đúng hạn)
    }

    // =========================================================
    // ERRORS
    // =========================================================

    error LoanLib__InvalidPrincipal(uint256 principal, uint256 min);
    error LoanLib__InvalidInterestRate(uint256 rate, uint256 min, uint256 max);
    error LoanLib__InvalidDuration(uint256 duration, uint256 min, uint256 max);
    error LoanLib__InvalidCollateralAmount();
    error LoanLib__InvalidDecimals(uint8 decimals);
    error LoanLib__CollateralRatioTooLow(uint256 actual, uint256 required);
    error LoanLib__LateFeeRateTooHigh(uint256 rate, uint256 max);
    error LoanLib__InvalidTimestamp();

    // =========================================================
    // VALIDATION
    // =========================================================

    /**
     * @notice Validate đầy đủ tất cả tham số của LoanRequest
     */
    function validateLoanParams(
        uint256 principal,
        uint256 interestRate,
        uint256 duration,
        uint256 collateralAmount,
        uint8   loanTokenDecimals,
        uint8   collateralDecimals
    ) internal pure {
        // 1. Principal
        uint256 minPrincipal = loanTokenDecimals >= 6
            ? MIN_PRINCIPAL * (10 ** (loanTokenDecimals - 6))
            : MIN_PRINCIPAL;
        if (principal < minPrincipal) {
            revert LoanLib__InvalidPrincipal(principal, minPrincipal);
        }

        // 2. Interest rate
        if (interestRate < MIN_INTEREST_RATE || interestRate > MAX_INTEREST_RATE) {
            revert LoanLib__InvalidInterestRate(interestRate, MIN_INTEREST_RATE, MAX_INTEREST_RATE);
        }

        // 3. Duration
        if (duration < MIN_DURATION || duration > MAX_DURATION) {
            revert LoanLib__InvalidDuration(duration, MIN_DURATION, MAX_DURATION);
        }

        // 4. Collateral amount
        if (collateralAmount == 0) revert LoanLib__InvalidCollateralAmount();

        // 5. Decimals sanity (tránh overflow)
        if (loanTokenDecimals > 18) revert LoanLib__InvalidDecimals(loanTokenDecimals);
        if (collateralDecimals > 18) revert LoanLib__InvalidDecimals(collateralDecimals);
    }

    /**
     * @notice Validate late fee rate không quá cao
     */
    function validateLateFeeRate(uint256 lateFeeRate) internal pure {
        if (lateFeeRate > MAX_LATE_FEE_RATE) {
            revert LoanLib__LateFeeRateTooHigh(lateFeeRate, MAX_LATE_FEE_RATE);
        }
    }

    /**
     * @notice Kiểm tra collateral value đủ theo required ratio
     */
    function validateCollateralRatio(
        uint256 collateralValueUSD,
        uint256 principalUSD,
        uint256 requiredRatioBps
    ) internal pure {
        uint256 requiredCollateralUSD = (principalUSD * requiredRatioBps) / BASIS_POINTS;
        if (collateralValueUSD < requiredCollateralUSD) {
            revert LoanLib__CollateralRatioTooLow(
                (collateralValueUSD * BASIS_POINTS) / principalUSD,
                requiredRatioBps
            );
        }
    }

    // =========================================================
    // INTEREST CALCULATIONS (Production-Correct)
    // =========================================================

    /**
     * @notice Lãi đơn (Simple Interest): I = P × R × T
     *
     * FIX M-1: Tránh precision loss bằng cách multiply trước, divide sau.
     * Dùng scaling factor để giữ độ chính xác cao trước khi round.
     *
     * @param principal         Số tiền gốc
     * @param rateInBasisPoints Lãi suất năm (basis points)
     * @param durationInSeconds Thời gian (giây)
     * @return interest         Số tiền lãi
     */
    function calculateSimpleInterest(
        uint256 principal,
        uint256 rateInBasisPoints,
        uint256 durationInSeconds
    ) internal pure returns (uint256 interest) {
        // Multiply tất cả trước, rồi mới chia một lần (minimize precision loss)
        // interest = P * R * T / (BASIS_POINTS * SECONDS_PER_YEAR)
        return (principal * rateInBasisPoints * durationInSeconds)
            / (BASIS_POINTS * SECONDS_PER_YEAR);
    }

    /**
     * @notice Tính lãi tích lũy với CAP tại endTime
     *
     * CRITICAL FIX: Nếu đã quá hạn, interest chỉ tính đến endTime.
     * Late fee tính riêng từ endTime đến hiện tại.
     *
     * TRƯỚC (sai):
     *   interest = P × R × (now - startTime)  ← tăng vô hạn sau endTime
     *
     * SAU (đúng):
     *   effectiveTime = min(now, endTime)
     *   interest = P × R × (effectiveTime - startTime)
     *   lateFee  = P × dailyRate × daysLate   ← tính riêng biệt
     *
     * @param principal   Số tiền gốc
     * @param rate        Lãi suất năm (basis points)
     * @param startTime   Thời điểm bắt đầu (block.timestamp khi fund)
     * @param endTime     Thời điểm đáo hạn
     * @param currentTime Thời điểm tính (block.timestamp)
     */
    function calculateAccruedInterestCapped(
        uint256 principal,
        uint256 rate,
        uint256 startTime,
        uint256 endTime,
        uint256 currentTime
    ) internal pure returns (uint256 interest) {
        if (currentTime <= startTime) return 0;
        if (startTime == 0 || endTime == 0) return 0;

        // Cap thời gian tính lãi tại endTime (không tăng sau endTime)
        uint256 effectiveTime = currentTime < endTime ? currentTime : endTime;
        uint256 elapsed       = effectiveTime - startTime;

        return calculateSimpleInterest(principal, rate, elapsed);
    }

    /**
     * @notice Tính lãi tích lũy từ startTime đến currentTime (không cap)
     * @dev Legacy function — dùng calculateAccruedInterestCapped cho production
     */
    function calculateAccruedInterest(
        uint256 principal,
        uint256 rateInBasisPoints,
        uint256 startTime,
        uint256 currentTime
    ) internal pure returns (uint256) {
        if (currentTime <= startTime) return 0;
        uint256 elapsed = currentTime - startTime;
        return calculateSimpleInterest(principal, rateInBasisPoints, elapsed);
    }

    /**
     * @notice Phí trễ hạn: LateFee = P × dailyRate × daysLate
     *
     * @param principal          Số tiền gốc
     * @param lateFeeRatePerDay  Phí/ngày (basis points, 50 = 0.5%)
     * @param daysLate           Số ngày trễ
     */
    function calculateLateFee(
        uint256 principal,
        uint256 lateFeeRatePerDay,
        uint256 daysLate
    ) internal pure returns (uint256) {
        if (daysLate == 0 || lateFeeRatePerDay == 0) return 0;
        return (principal * lateFeeRatePerDay * daysLate) / BASIS_POINTS;
    }

    /**
     * @notice Tính toàn bộ breakdown trả nợ (Production-Correct với cap)
     *
     * Trả về RepaymentBreakdown struct để tránh tuple hell và dễ extend.
     *
     * @param principal         Số tiền gốc
     * @param interestRate      Lãi suất năm (basis points)
     * @param lateFeeRatePerDay Phí trễ/ngày (basis points)
     * @param startTime         Thời điểm bắt đầu
     * @param endTime           Thời điểm đáo hạn
     * @param currentTime       block.timestamp hiện tại
     */
    function calculateRepaymentBreakdown(
        uint256 principal,
        uint256 interestRate,
        uint256 lateFeeRatePerDay,
        uint256 startTime,
        uint256 endTime,
        uint256 currentTime
    ) internal pure returns (RepaymentBreakdown memory breakdown) {
        breakdown.principal    = principal;
        breakdown.calculatedAt = currentTime;
        breakdown.isOverdue    = (currentTime > endTime && endTime > 0);

        // Interest: cap tại endTime (key fix)
        breakdown.interest = calculateAccruedInterestCapped(
            principal, interestRate, startTime, endTime, currentTime
        );

        // Late fee: chỉ tính nếu quá hạn
        if (breakdown.isOverdue) {
            breakdown.daysLate = getDaysOverdue(endTime, currentTime);
            breakdown.lateFee  = calculateLateFee(
                principal, lateFeeRatePerDay, breakdown.daysLate
            );
        }

        breakdown.totalAmount = principal + breakdown.interest + breakdown.lateFee;
    }

    /**
     * @notice Tổng số tiền cần trả (simple version cho backward compat)
     */
    function calculateTotalRepayment(
        uint256 principal,
        uint256 interestRate,
        uint256 startTime,
        uint256 currentTime,
        uint256 endTime,
        uint256 lateFeeRatePerDay
    ) internal pure returns (uint256 interest, uint256 lateFee, uint256 total) {
        // Dùng capped version
        interest = calculateAccruedInterestCapped(
            principal, interestRate, startTime, endTime, currentTime
        );

        if (currentTime > endTime && endTime > 0) {
            uint256 daysLate = (currentTime - endTime) / 1 days;
            lateFee = calculateLateFee(principal, lateFeeRatePerDay, daysLate);
        }

        total = principal + interest + lateFee;
    }

    // =========================================================
    // STATE HELPERS
    // =========================================================

    /**
     * @notice Kiểm tra collateral ratio có dưới ngưỡng liquidation không
     */
    function isLiquidatable(
        uint256 collateralRatio,
        uint256 liquidationThreshold
    ) internal pure returns (bool) {
        return collateralRatio < liquidationThreshold;
    }

    /**
     * @notice Tính collateral ratio: (collateralValue / debtValue) × 10000
     * @return ratio basis points (15000 = 150%)
     */
    function calculateCollateralRatio(
        uint256 collateralValueUSD,
        uint256 debtValueUSD
    ) internal pure returns (uint256 ratio) {
        if (debtValueUSD == 0) return type(uint256).max;
        return (collateralValueUSD * BASIS_POINTS) / debtValueUSD;
    }

    /**
     * @notice Tính số ngày quá hạn
     */
    function getDaysOverdue(
        uint256 endTime,
        uint256 currentTime
    ) internal pure returns (uint256) {
        if (currentTime <= endTime) return 0;
        return (currentTime - endTime) / 1 days;
    }

    /**
     * @notice Tính lãi tối đa borrower sẽ phải trả (tại thời điểm endTime)
     * Dùng cho UI: hiển thị "worst case interest"
     */
    function calculateMaxInterest(
        uint256 principal,
        uint256 interestRate,
        uint256 duration
    ) internal pure returns (uint256) {
        return calculateSimpleInterest(principal, interestRate, duration);
    }

    /**
     * @notice Tính số tiền lender nhận được nếu borrower trả đúng hạn
     * Dùng cho UI: hiển thị expected return cho lender
     */
    function calculateLenderExpectedReturn(
        uint256 principal,
        uint256 interestRate,
        uint256 duration
    ) internal pure returns (uint256) {
        uint256 interest = calculateSimpleInterest(principal, interestRate, duration);
        return principal + interest;
    }
}
