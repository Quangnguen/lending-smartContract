// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title FundingLib
 * @dev Library cho validation và tính toán liên quan đến luồng cấp vốn (funding)
 *
 * Tách ra khỏi P2PLending để:
 * 1. Code P2PLending gọn, dễ audit
 * 2. Test riêng biệt fee math và validation
 * 3. Tái sử dụng qua multi-lender hoặc pool-based upgrade
 *
 * ─── Fee Architecture ─────────────────────────────────────────────────
 *
 *  Lender approve: principal → P2PLending
 *
 *  P2PLending phân bổ:
 *    ├── borrower   ← principal - protocolFee - originationFee
 *    ├── feeRecipient ← protocolFee (platform revenue)
 *    └── (originationFee giữ lại trong contract cho future use)
 *
 *  Công thức:
 *    protocolFee    = principal × platformFeeRate / 10_000
 *    borrowerAmount = principal - protocolFee
 *
 *  Lender nhận lại: principal + interest khi borrower repay
 *
 * ─── Comparison với DeFi Standards ───────────────────────────────────
 *
 *  Aave:     Fee = 0.09% (originationFee) từ lender, pool model
 *  Compound: Không có origination fee, reserve factor từ interest
 *  Morpho:   P2P rate matching, không fee từ lender
 *  MakerDAO: Stability fee từ borrower, không phải lender
 *
 *  Dự án này: 1% platform fee từ principal (borrower chịu thiệt hơn lender)
 *  → Production recommendation: charge lender % APY instead of upfront
 */
library FundingLib {

    // =========================================================
    // CONSTANTS
    // =========================================================

    uint256 public constant BASIS_POINTS     = 10_000;
    uint256 public constant MAX_FEE_RATE     = 500;    // 5% tối đa
    uint256 public constant MAX_BATCH_FUND   = 50;     // max loans per batch

    // =========================================================
    // STRUCTS
    // =========================================================

    /**
     * @dev Snapshot thông tin funding để tránh re-read state nhiều lần
     * Giảm số lần SLOAD (mỗi SLOAD = 100 gas sau EIP-2929)
     */
    struct FundingSnapshot {
        uint256 requestId;
        address borrower;
        address loanToken;
        uint256 principal;
        uint256 platformFee;       // Số tiền fee tuyệt đối
        uint256 borrowerAmount;    // principal - platformFee
        uint256 interestRate;
        uint256 collateralAmount;
        address collateralToken;
        uint256 duration;
        uint8   loanTokenDecimals;
        uint8   collateralDecimals;
    }

    // =========================================================
    // ERRORS
    // =========================================================

    error FundingLib__RequestNotActive(uint256 requestId);
    error FundingLib__SelfFunding(uint256 requestId, address lender);
    error FundingLib__InsufficientAllowance(
        address token,
        uint256 allowance,
        uint256 required
    );
    error FundingLib__InsufficientBalance(
        address token,
        uint256 balance,
        uint256 required
    );
    error FundingLib__ZeroAddress();
    error FundingLib__InvalidFeeRate(uint256 rate, uint256 max);
    error FundingLib__PlatformPaused();

    // =========================================================
    // VALIDATION
    // =========================================================

    /**
     * @notice Validate tất cả điều kiện cần thiết trước khi fund
     *
     * Checks (theo thứ tự gas-efficient nhất — cheap checks trước):
     *  1. Request đang active (bool check, rẻ nhất)
     *  2. Không tự fund chính mình
     *  3. Lender address hợp lệ
     *  4. Lender có đủ allowance (tránh stuck state)
     *  5. Lender có đủ balance (tránh revert muộn)
     *
     * @param requestActive  Trạng thái request
     * @param borrower       Địa chỉ borrower
     * @param lender         Địa chỉ lender (msg.sender)
     * @param loanToken      Token cần approve
     * @param totalNeeded    Tổng token lender cần chuyển (principal)
     * @param requestId      Để emit trong error
     */
    function validateFunding(
        bool    requestActive,
        address borrower,
        address lender,
        address loanToken,
        uint256 totalNeeded,
        uint256 requestId
    ) internal view {
        // 1. Request active? (boolean, 1 SLOAD)
        if (!requestActive) revert FundingLib__RequestNotActive(requestId);

        // 2. Không self-fund (address compare, cheap)
        if (lender == borrower) revert FundingLib__SelfFunding(requestId, lender);

        // 3. Lender address hợp lệ
        if (lender == address(0)) revert FundingLib__ZeroAddress();

        // 4. Allowance check TRƯỚC state change (tránh stuck state)
        uint256 allowance = IERC20(loanToken).allowance(lender, msg.sender);
        if (allowance < totalNeeded) {
            revert FundingLib__InsufficientAllowance(loanToken, allowance, totalNeeded);
        }

        // 5. Balance check (tránh revert muộn sau state thay đổi)
        uint256 balance = IERC20(loanToken).balanceOf(lender);
        if (balance < totalNeeded) {
            revert FundingLib__InsufficientBalance(loanToken, balance, totalNeeded);
        }
    }

    // =========================================================
    // FEE CALCULATION
    // =========================================================

    /**
     * @notice Tính phí platform và số tiền borrower nhận
     *
     * Fee model hiện tại: Lender trả principal, platform giữ fee, borrower nhận net
     *
     * @param principal     Số tiền gốc (loanToken decimals)
     * @param feeRateBps    Tỷ lệ fee (basis points, 100 = 1%)
     * @return fee          Phí tuyệt đối
     * @return netAmount    Số tiền borrower nhận được
     */
    function calculateFee(
        uint256 principal,
        uint256 feeRateBps
    ) internal pure returns (uint256 fee, uint256 netAmount) {
        if (feeRateBps == 0) return (0, principal);
        fee       = (principal * feeRateBps) / BASIS_POINTS;
        netAmount = principal - fee;
    }

    /**
     * @notice Build FundingSnapshot từ loan request data
     * Giảm số lần đọc storage trong hàm gọi chính
     *
     * @param requestId      ID của request
     * @param borrower       Địa chỉ borrower
     * @param loanToken      Token cho vay
     * @param collateralToken Token thế chấp
     * @param principal      Số tiền gốc
     * @param interestRate   Lãi suất (basis points)
     * @param collateralAmount Số lượng thế chấp
     * @param duration       Thời hạn (giây)
     * @param loanTokenDecimals Decimals của loanToken
     * @param collateralDecimals Decimals của collateralToken
     * @param platformFeeRate Tỷ lệ fee platform (basis points)
     */
    function buildSnapshot(
        uint256 requestId,
        address borrower,
        address loanToken,
        address collateralToken,
        uint256 principal,
        uint256 interestRate,
        uint256 collateralAmount,
        uint256 duration,
        uint8   loanTokenDecimals,
        uint8   collateralDecimals,
        uint256 platformFeeRate
    ) internal pure returns (FundingSnapshot memory snap) {
        (uint256 fee, uint256 net) = calculateFee(principal, platformFeeRate);

        snap = FundingSnapshot({
            requestId:         requestId,
            borrower:          borrower,
            loanToken:         loanToken,
            principal:         principal,
            platformFee:       fee,
            borrowerAmount:    net,
            interestRate:      interestRate,
            collateralAmount:  collateralAmount,
            collateralToken:   collateralToken,
            duration:          duration,
            loanTokenDecimals: loanTokenDecimals,
            collateralDecimals: collateralDecimals
        });
    }

    // =========================================================
    // SECURITY HELPERS
    // =========================================================

    /**
     * @notice Kiểm tra địa chỉ có phải contract không (dùng cho lender validation)
     * Flash loan abuse thường đến từ contract, không phải EOA.
     * Lưu ý: isContract() trả về false trong constructor của contract.
     *
     * @param addr Địa chỉ cần kiểm tra
     * @return bool True nếu là contract
     */
    function isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    /**
     * @notice Tính lãi dự kiến lender sẽ nhận khi repay (cho UI display)
     *
     * @param principal        Số tiền gốc
     * @param interestRateBps  Lãi suất năm (basis points)
     * @param durationSeconds  Thời hạn (giây)
     * @return expectedInterest Lãi dự kiến
     */
    function calculateExpectedInterest(
        uint256 principal,
        uint256 interestRateBps,
        uint256 durationSeconds
    ) internal pure returns (uint256 expectedInterest) {
        return (principal * interestRateBps * durationSeconds)
            / (BASIS_POINTS * 365 days);
    }

    /**
     * @notice Tính APY thực tế cho lender sau platform fee
     * @param interestRateBps  Lãi suất borrower trả (basis points/năm)
     * @param feeRateBps       Platform fee (basis points of principal)
     * @param durationSeconds  Thời hạn (giây)
     * @return lenderAPY       Lãi thực lender nhận (basis points/năm)
     */
    function calculateLenderAPY(
        uint256 interestRateBps,
        uint256 feeRateBps,
        uint256 durationSeconds
    ) internal pure returns (uint256 lenderAPY) {
        // Lender nhận toàn bộ interest (fee chỉ trừ vào principal ban đầu)
        // APY = interestRate vì lender nhận cả interest
        // Nhưng có trượt vốn do fee: net_principal < principal
        // Để đơn giản: lenderAPY = interestRate (lender nhận nguyên interest)
        // Fee ảnh hưởng effective return = interest / (principal - fee)
        if (durationSeconds == 0) return 0;
        uint256 effectivePrincipalBps = BASIS_POINTS - feeRateBps;
        if (effectivePrincipalBps == 0) return 0;
        lenderAPY = (interestRateBps * BASIS_POINTS) / effectivePrincipalBps;
    }
}
