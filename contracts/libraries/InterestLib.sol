// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library InterestLib {
    
    // 100% = 10000 basis points
    uint256 public constant BASIS_POINTS = 10000;

    uint256 public constant SECONDS_PER_YEAR = 365 days;

    uint256 public constant PRECISION = 1e18;

    /**
     * @notice Tính lãi đơn: Interest = Principal × Rate × Time
     * @param principal Số tiền gốc (wei)
     * @param rateInBasisPoints Lãi suất năm (basis points)
     * @param durationInSeconds Thời gian vay (giây)
     * @return interest Số tiền lãi (wei)
     */
    function calculateSimpleInterest(
        uint256 principal,
        uint256 rateInBasisPoints,
        uint256 durationInSeconds
    ) internal pure returns (uint256 interest) {
        // Formula: I = P × R × T
        // I = principal × (rate/10000) × (duration/31536000)
        interest = (principal * rateInBasisPoints * durationInSeconds) / (BASIS_POINTS * SECONDS_PER_YEAR);
        return interest;
    }

    /**
     * @notice Tính tổng số tiền cần trả
     * @param principal Số tiền gốc
     * @param interest Số tiền lãi
     * @return Tổng = Gốc + Lãi
     */
    function calculateTotalRepayment(
        uint256 principal,
        uint256 interest
    ) internal pure returns (uint256) {
        return principal + interest;
    }

    /**
     * @notice Tính lãi đã tích lũy từ lúc bắt đầu đến hiện tại
     * @param principal Số tiền gốc
     * @param rateInBasisPoints Lãi suất năm
     * @param startTime Thời điểm bắt đầu
     * @param currentTime Thời điểm hiện tại
     * @return Lãi đã tích lũy
     */
    function calculateAccruedInterest(
        uint256 principal,
        uint256 rateInBasisPoints,
        uint256 startTime,
        uint256 currentTime
    ) internal pure returns (uint256) {
        if(currentTime <= startTime) return 0;

        uint256 elapsed = currentTime - startTime;
        return calculateSimpleInterest(principal, rateInBasisPoints, elapsed);   
    }

    /**
     * @notice Tính phí trễ hạn
     * @param principal Số tiền gốc
     * @param lateFeeRatePerDay Phí trễ mỗi ngày (basis points)
     * @param daysLate Số ngày trễ
     * @return Phí trễ hạn
     */
    function calculateLateFee(
        uint256 principal,
        uint256 lateFeeRatePerDay,
        uint256 daysLate
    ) internal pure returns (uint256) {
        return (principal * lateFeeRatePerDay * daysLate) / BASIS_POINTS;
    }
}