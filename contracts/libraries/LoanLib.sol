// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/ILoan.sol";

library LoanLib {
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant DEFAULT_MIN_COLLATERAL_RATIO = 15000;
    uint256 public constant DEFAULT_LIQUIDATION_THRESHOLD = 12000;
    uint256 public constant MIN_LOAN_DURATION = 1 days;
    uint256 public constant MAX_LOAN_DURATION = 365 days;
    uint256 public constant MAX_INTEREST_RATE = 10000;

    error InvalidPrincipal();
    error InvalidInterestRate();
    error InvalidDuration();
    error InvalidCollateralAmount();
    error LoanNotActive();
    error LoanNotPending();

    /**
     * @notice Kiểm tra các thông số khoản vay có hợp lệ không
     * @param principal Số tiền gốc
     * @param interestRate Lãi suất (basis points)
     * @param duration Thời hạn (seconds)
     * @param collateralAmount Số lượng thế chấp
     */
    function validateLoanParams(
        uint256 principal,
        uint256 interestRate,
        uint256 duration,
        uint256 collateralAmount
    ) internal pure {
        if (principal == 0) revert InvalidPrincipal();
        if (interestRate == 0 || interestRate > MAX_INTEREST_RATE) revert InvalidInterestRate();
        if (duration < MIN_LOAN_DURATION || duration > MAX_LOAN_DURATION) revert InvalidDuration();
        if (collateralAmount == 0) revert InvalidCollateralAmount();
    }

    /**
     * @notice Tính tỷ lệ thế chấp
     * @param collateralValue Giá trị thế chấp (USD)
     * @param loanValue Giá trị khoản vay (USD)
     * @return Tỷ lệ theo basis points (15000 = 150%)
     */
    function calculateCollateralRatio(
        uint256 collateralValue,
        uint256 loanValue
    ) internal pure returns (uint256) {
        if (loanValue == 0) return type(uint256).max; // tránh chia cho 0
        return (collateralValue * BASIS_POINTS) / loanValue;
    }

    /**
     * @notice Kiểm tra có thể thanh lý không
     * @param collateralRatio Tỷ lệ thế chấp hiện tại
     * @param liquidationThreshold Ngưỡng thanh lý
     * @return true nếu có thể thanh lý
     */
    function isLiquidatable(
        uint256 collateralRatio,
        uint256 liquidationThreshold
    ) internal pure returns (bool) {
        return collateralRatio < liquidationThreshold;
    }

    /**
     * @notice Kiểm tra khoản vay có quá hạn không
     * @param endTime Thời điểm kết thúc
     * @param currentTime Thời điểm hiện tại
     * @return true nếu quá hạn
     */
    function isOverdue(
        uint256 endTime,
        uint256 currentTime
    ) internal pure returns (bool) {
        return currentTime > endTime;
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
}
