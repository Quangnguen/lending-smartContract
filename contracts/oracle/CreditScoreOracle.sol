// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/ICreditScoreOracle.sol";

/**
 * @title CreditScoreOracle
 * @dev Oracle nhận Credit Score từ backend và cung cấp cho P2PLending
 *
 * Kiến trúc:
 * - Backend (NestJS) tính credit score từ Open Banking data
 * - Backend dùng private key của `oracleUpdater` để gọi updateCreditScore()
 * - P2PLending.sol gọi getCreditScore() hoặc getRequiredCollateralRatio()
 *   để xác định mức thế chấp cho mỗi borrower
 *
 * Bảo mật:
 * - Chỉ `oracleUpdater` (backend wallet) mới được cập nhật score
 * - Owner có thể thay đổi oracleUpdater nếu cần rotate key
 * - Score có thời hạn (mặc định 30 ngày), quá hạn cần tính lại
 *
 * Dynamic Collateral Ratio (basis points):
 *   Score >= 800 → 13500 (135%) — EXCELLENT   (có thể vay với ít thế chấp nhất)
 *   Score >= 700 → 14500 (145%) — VERY_GOOD
 *   Score >= 600 → 15500 (155%) — GOOD
 *   Score >= 500 → 16500 (165%) — FAIR
 *   Score >= 400 → 17500 (175%) — BELOW_FAIR
 *   Score <  400 → 19000 (190%) — POOR (full collateral, ETH có thể giảm 47% trước khi lý ngưỡng 110%)
 */
contract CreditScoreOracle is ICreditScoreOracle, Ownable {
    // ===== STATE =====

    /// @dev Địa chỉ được phép cập nhật score (backend wallet)
    address public oracleUpdater;

    /// @dev Thời gian hiệu lực của score (mặc định 30 ngày)
    uint256 public scoreValidityPeriod = 30 days;

    /// @dev Collateral ratio mặc định khi không có score (150% = 15000 basis points)
    uint256 public constant DEFAULT_COLLATERAL_RATIO = 15000;

    /// @dev Max score
    uint256 public constant MAX_SCORE = 1000;

    /// @dev Basis points constant
    uint256 public constant BASIS_POINTS = 10000;

    /// @dev Lưu score của mỗi borrower
    mapping(address => ScoreData) public scores;

    /// @dev Tổng số borrowers đã có score
    uint256 public totalScored;

    // ===== ERRORS =====

    error NotOracleUpdater();
    error InvalidScore();
    error InvalidAddress();
    error ArrayLengthMismatch();

    // ===== MODIFIERS =====

    modifier onlyOracleUpdater() {
        if (msg.sender != oracleUpdater) revert NotOracleUpdater();
        _;
    }

    // ===== CONSTRUCTOR =====

    /**
     * @param initialOwner Owner của contract (admin)
     * @param _oracleUpdater Địa chỉ backend wallet được phép cập nhật score
     */
    constructor(
        address initialOwner,
        address _oracleUpdater
    ) Ownable(initialOwner) {
        if (_oracleUpdater == address(0)) revert InvalidAddress();
        oracleUpdater = _oracleUpdater;
    }

    // ===== WRITE FUNCTIONS =====

    /**
     * @dev Cập nhật credit score cho 1 borrower
     * Gọi bởi backend sau khi CreditScoringEngine tính xong
     */
    function updateCreditScore(
        address borrower,
        uint256 score
    ) external override onlyOracleUpdater {
        if (borrower == address(0)) revert InvalidAddress();
        if (score > MAX_SCORE) revert InvalidScore();

        uint256 oldScore = scores[borrower].score;

        // Nếu là borrower mới, tăng counter
        if (!scores[borrower].isActive) {
            totalScored++;
        }

        scores[borrower] = ScoreData({
            score: score,
            timestamp: block.timestamp,
            expiresAt: block.timestamp + scoreValidityPeriod,
            isActive: true
        });

        emit CreditScoreUpdated(borrower, oldScore, score, block.timestamp);
    }

    /**
     * @dev Cập nhật score cho nhiều borrowers cùng lúc
     * Tiết kiệm gas khi backend cần sync nhiều scores
     */
    function batchUpdateScores(
        address[] calldata borrowers,
        uint256[] calldata _scores
    ) external override onlyOracleUpdater {
        if (borrowers.length != _scores.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < borrowers.length; i++) {
            if (borrowers[i] == address(0)) revert InvalidAddress();
            if (_scores[i] > MAX_SCORE) revert InvalidScore();

            uint256 oldScore = scores[borrowers[i]].score;

            if (!scores[borrowers[i]].isActive) {
                totalScored++;
            }

            scores[borrowers[i]] = ScoreData({
                score: _scores[i],
                timestamp: block.timestamp,
                expiresAt: block.timestamp + scoreValidityPeriod,
                isActive: true
            });

            emit CreditScoreUpdated(borrowers[i], oldScore, _scores[i], block.timestamp);
        }
    }

    // ===== VIEW FUNCTIONS =====

    /**
     * @dev Lấy credit score + metadata
     */
    function getCreditScore(
        address borrower
    ) external view override returns (uint256 score, uint256 timestamp, bool isValid) {
        ScoreData memory data = scores[borrower];
        return (
            data.score,
            data.timestamp,
            data.isActive && block.timestamp <= data.expiresAt
        );
    }

    /**
     * @dev Core function: Tính collateral ratio dựa trên credit score
     * Đây là điểm khác biệt của hệ thống so với DeFi thuần túy
     *
     * Trả về basis points (VD: 5000 = 50%, 15000 = 150%)
     */
    function getRequiredCollateralRatio(
        address borrower
    ) external view override returns (uint256 ratio) {
        ScoreData memory data = scores[borrower];

        // Không có score hoặc score hết hạn → full collateral
        if (!data.isActive || block.timestamp > data.expiresAt) {
            return DEFAULT_COLLATERAL_RATIO; // 150%
        }

        return _scoreToCollateralRatio(data.score);
    }

    /**
     * @dev Kiểm tra borrower có score hợp lệ
     */
    function hasValidScore(address borrower) external view override returns (bool) {
        ScoreData memory data = scores[borrower];
        return data.isActive && block.timestamp <= data.expiresAt;
    }

    /**
     * @dev Lấy toàn bộ ScoreData cho borrower
     */
    function getScoreData(address borrower) external view returns (ScoreData memory) {
        return scores[borrower];
    }

    // ===== ADMIN FUNCTIONS =====

    /**
     * @dev Thay đổi oracle updater (rotate key khi cần)
     */
    function setOracleUpdater(address newUpdater) external onlyOwner {
        if (newUpdater == address(0)) revert InvalidAddress();
        address oldUpdater = oracleUpdater;
        oracleUpdater = newUpdater;
        emit OracleUpdaterChanged(oldUpdater, newUpdater);
    }

    /**
     * @dev Thay đổi thời gian hiệu lực score
     */
    function setScoreValidityPeriod(uint256 period) external onlyOwner {
        scoreValidityPeriod = period;
    }

    // ===== INTERNAL =====

    /**
     * @dev Chuyển đổi score (0-1000) → collateral ratio (basis points)
     *
     * Tiếu chí thiết kế:
     *   1. Floor = 13500 (135%): ETH có thể giảm 18% trước khi xuống ngưỡng 110% thanh lý
     *   2. Ceiling = 19000 (190%): Buffer 72% cho borrower có rủi ro cao
     *   3. Gradient đều: mỗi tier cách nhau 1000bps (10%)
     *
     * Score >= 800: 13500 (135%) — EXCELLENT   → ETH có thể giảm 18% an toàn
     * Score >= 700: 14500 (145%) — VERY_GOOD   → Buffer 28% trước liquidation
     * Score >= 600: 15500 (155%) — GOOD        → Buffer 38%
     * Score >= 500: 16500 (165%) — FAIR        → Buffer 48%
     * Score >= 400: 17500 (175%) — BELOW_FAIR  → Buffer 58%
     * Score <  400: 19000 (190%) — POOR        → Buffer 72%
     */
    function _scoreToCollateralRatio(uint256 score) internal pure returns (uint256) {
        if (score >= 800) return 13500;  // 135% — EXCELLENT
        if (score >= 700) return 14500;  // 145% — VERY_GOOD
        if (score >= 600) return 15500;  // 155% — GOOD
        if (score >= 500) return 16500;  // 165% — FAIR
        if (score >= 400) return 17500;  // 175% — BELOW_FAIR
        return 19000;                    // 190% — POOR
    }
}
