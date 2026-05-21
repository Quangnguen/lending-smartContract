// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title ICreditScoreOracle
 * @dev Interface cho Oracle nhận Credit Score từ backend (off-chain → on-chain)
 *
 * Vai trò trong hệ thống:
 * - Backend tính Credit Score từ Open Banking data
 * - Backend gọi updateCreditScore() để đẩy score lên blockchain
 * - P2PLending.sol đọc score để tính dynamic collateral ratio
 *
 * Luồng: Open Banking → CreditScoringEngine (NestJS) → CreditScoreOracle.sol → P2PLending.sol
 */
interface ICreditScoreOracle {
    // ===== EVENTS =====

    event CreditScoreUpdated(
        address indexed borrower,
        uint256 oldScore,
        uint256 newScore,
        uint256 timestamp
    );

    event ScoreExpired(
        address indexed borrower,
        uint256 score,
        uint256 expiredAt
    );

    event OracleUpdaterChanged(
        address indexed oldUpdater,
        address indexed newUpdater
    );

    // ===== STRUCTS =====

    struct ScoreData {
        uint256 score;          // 0-1000
        uint256 timestamp;      // block.timestamp khi cập nhật
        uint256 expiresAt;      // Thời điểm hết hạn (score cần tính lại)
        bool isActive;          // Score còn hiệu lực
    }

    // ===== WRITE FUNCTIONS =====

    /**
     * @dev Cập nhật credit score cho borrower (chỉ oracle updater)
     * @param borrower Địa chỉ ví của người vay
     * @param score Điểm tín dụng (0-1000)
     */
    function updateCreditScore(address borrower, uint256 score) external;

    /**
     * @dev Cập nhật credit score hàng loạt
     * @param borrowers Danh sách địa chỉ
     * @param scores Danh sách điểm tương ứng
     */
    function batchUpdateScores(
        address[] calldata borrowers,
        uint256[] calldata scores
    ) external;

    // ===== VIEW FUNCTIONS =====

    /**
     * @dev Lấy credit score của borrower
     * @return score Điểm (0-1000)
     * @return timestamp Thời điểm cập nhật
     * @return isValid Score còn hiệu lực (chưa hết hạn)
     */
    function getCreditScore(address borrower)
        external
        view
        returns (uint256 score, uint256 timestamp, bool isValid);

    /**
     * @dev Tính collateral ratio dựa trên credit score
     * @param borrower Địa chỉ người vay
     * @return ratio Tỷ lệ thế chấp (basis points, VD: 5000 = 50%)
     */
    function getRequiredCollateralRatio(address borrower)
        external
        view
        returns (uint256 ratio);

    /**
     * @dev Kiểm tra borrower có score hợp lệ không
     */
    function hasValidScore(address borrower) external view returns (bool);
}
