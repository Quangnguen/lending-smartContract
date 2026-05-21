// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./LoanLib.sol";

/**
 * @title RepaymentLib
 * @dev Library chuyên xử lý logic trả nợ (repayment)
 *
 * ─── Repayment Architecture ──────────────────────────────────────────────
 *
 * Dự án này dùng mô hình DIRECT REPAYMENT:
 *   Borrower → safeTransferFrom → Lender (trực tiếp)
 *   Không qua pool, không escrow trung gian
 *
 * So sánh với DeFi standards:
 *
 *   AAVE (Pool Model):
 *     Borrower → repay() → Pool → burn debtToken → cộng interest vào reserve
 *     Lender rút tiền từ pool bất cứ lúc nào (aToken)
 *
 *   COMPOUND (Pool Model):
 *     Borrower → repayBorrow() → Pool → giảm borrowIndex
 *     Lãi compound theo từng block (borrow rate = f(utilization))
 *
 *   MORPHO (P2P Matching):
 *     Tương tự Aave/Compound pool nhưng match P2P trước
 *     repay() → nếu có P2P match → trả trực tiếp cho matched lender
 *
 *   MAKERDAO (CDP):
 *     Owner repay DAI + stability fee (MKR burned)
 *     Không có lender — DAI được mint/burn
 *
 *   DỰ ÁN NÀY (P2P Direct):
 *     Borrower repay USDT → Lender nhận trực tiếp
 *     Lãi tính theo Simple Interest, cap tại endTime
 *     Late fee tính từ endTime đến block.timestamp
 *
 * ─── Repayment Distribution ──────────────────────────────────────────────
 *
 *  TotalAmount = principal + interest + lateFee
 *
 *  Lender nhận:    principal + interest  (= expectedReturn)
 *  Protocol nhận:  lateFee               (penalty revenue)
 *  OR:
 *  Lender nhận:    principal + interest + lateFee (toàn bộ)
 *
 *  Hiện tại: toàn bộ về lender (đơn giản, no fee split)
 *  Upgrade: lateFee → protocol treasury (cần thêm feeRecipient vào Loan)
 *
 * ─── Gas Optimization ─────────────────────────────────────────────────
 *
 *  1. Snapshot (cache) values từ storage trước EFFECTS
 *  2. RepaymentBreakdown struct giảm stack depth
 *  3. Tính allowance + balance trước state change (tránh revert muộn)
 *  4. Skip collateral release nếu CM address = 0 (gas saver)
 */
library RepaymentLib {

    // =========================================================
    // CONSTANTS
    // =========================================================

    uint256 public constant BASIS_POINTS = 10_000;

    // =========================================================
    // STRUCTS
    // =========================================================

    /**
     * @dev Snapshot toàn bộ data cần cho repay()
     * Tính 1 lần để tránh multiple storage reads
     */
    struct RepaymentContext {
        uint256 loanId;
        address borrower;
        address lender;
        address loanToken;
        LoanLib.RepaymentBreakdown breakdown;
    }

    // =========================================================
    // ERRORS
    // =========================================================

    error RepaymentLib__NotActive();
    error RepaymentLib__NotBorrowerOrDelegate(address caller, address borrower);
    error RepaymentLib__InsufficientAllowance(
        address token,
        address payer,
        uint256 allowance,
        uint256 required
    );
    error RepaymentLib__InsufficientBalance(
        address token,
        address payer,
        uint256 balance,
        uint256 required
    );
    error RepaymentLib__ZeroTotal();
    error RepaymentLib__TransferFailed();

    // =========================================================
    // VALIDATION
    // =========================================================

    /**
     * @notice Validate điều kiện trước khi thực hiện repay
     *
     * Checks (theo thứ tự từ rẻ đến đắt gas):
     *   1. Loan đang ACTIVE (enum compare, 1 SLOAD)
     *   2. Caller là borrower hoặc delegate được phép
     *   3. Total > 0 (tránh edge case)
     *   4. Payer có đủ allowance (ERC-20 call)
     *   5. Payer có đủ balance (ERC-20 call)
     *
     * @param isActive     Loan có đang ACTIVE không
     * @param borrower     Địa chỉ borrower
     * @param caller       msg.sender
     * @param loanToken    Token cần approve
     * @param totalAmount  Tổng cần chuyển
     * @param loanContract Địa chỉ Loan contract (caller approve cho nó)
     */
    function validateRepayment(
        bool    isActive,
        address borrower,
        address caller,
        address loanToken,
        uint256 totalAmount,
        address loanContract
    ) internal view {
        // 1. Status check
        if (!isActive) revert RepaymentLib__NotActive();

        // 2. Caller validation — borrower hoặc không ai cả
        // (repayOnBehalf cho phép bất kỳ ai trả thay)
        // Function này validate borrower-only; repayOnBehalf validate riêng
        if (caller != borrower) {
            revert RepaymentLib__NotBorrowerOrDelegate(caller, borrower);
        }

        // 3. Total amount check
        if (totalAmount == 0) revert RepaymentLib__ZeroTotal();

        // 4. Allowance check (ERC-20 external call)
        uint256 allowance = IERC20(loanToken).allowance(caller, loanContract);
        if (allowance < totalAmount) {
            revert RepaymentLib__InsufficientAllowance(loanToken, caller, allowance, totalAmount);
        }

        // 5. Balance check (tránh revert sau state change)
        uint256 balance = IERC20(loanToken).balanceOf(caller);
        if (balance < totalAmount) {
            revert RepaymentLib__InsufficientBalance(loanToken, caller, balance, totalAmount);
        }
    }

    /**
     * @notice Validate repayOnBehalf — bất kỳ ai có thể trả thay
     *
     * Khác validateRepayment: không require caller == borrower.
     * Payer tự chịu cost, borrower nhận lại collateral.
     */
    function validateRepayOnBehalf(
        bool    isActive,
        address payer,
        address loanToken,
        uint256 totalAmount,
        address loanContract
    ) internal view {
        if (!isActive) revert RepaymentLib__NotActive();
        if (totalAmount == 0) revert RepaymentLib__ZeroTotal();

        uint256 allowance = IERC20(loanToken).allowance(payer, loanContract);
        if (allowance < totalAmount) {
            revert RepaymentLib__InsufficientAllowance(loanToken, payer, allowance, totalAmount);
        }

        uint256 balance = IERC20(loanToken).balanceOf(payer);
        if (balance < totalAmount) {
            revert RepaymentLib__InsufficientBalance(loanToken, payer, balance, totalAmount);
        }
    }

    // =========================================================
    // REPAYMENT CALCULATION HELPERS
    // =========================================================

    /**
     * @notice Build RepaymentContext từ loan data
     *
     * Single-call builder: đọc tất cả data cần thiết 1 lần,
     * pass struct đi thay vì load lại từ storage.
     */
    function buildRepaymentContext(
        uint256 loanId,
        address borrower,
        address lender,
        address loanToken,
        uint256 principal,
        uint256 interestRate,
        uint256 lateFeeRate,
        uint256 startTime,
        uint256 endTime
    ) internal view returns (RepaymentContext memory ctx) {
        ctx.loanId    = loanId;
        ctx.borrower  = borrower;
        ctx.lender    = lender;
        ctx.loanToken = loanToken;

        ctx.breakdown = LoanLib.calculateRepaymentBreakdown(
            principal,
            interestRate,
            lateFeeRate,
            startTime,
            endTime,
            block.timestamp
        );
    }

    /**
     * @notice Tính lãi tích lũy đã cap tại endTime
     * Wrapper để Loan.sol gọi mà không cần import trực tiếp LoanLib
     */
    function calculateInterest(
        uint256 principal,
        uint256 interestRate,
        uint256 startTime,
        uint256 endTime
    ) internal view returns (uint256) {
        return LoanLib.calculateAccruedInterestCapped(
            principal, interestRate, startTime, endTime, block.timestamp
        );
    }

    /**
     * @notice Tính late fee nếu đang quá hạn
     */
    function calculateLateFee(
        uint256 principal,
        uint256 lateFeeRate,
        uint256 endTime
    ) internal view returns (uint256 lateFee, uint256 daysLate) {
        daysLate = LoanLib.getDaysOverdue(endTime, block.timestamp);
        lateFee  = LoanLib.calculateLateFee(principal, lateFeeRate, daysLate);
    }

    // =========================================================
    // SECURITY ANALYSIS HELPERS (Read-only, dùng cho view functions)
    // =========================================================

    /**
     * @notice Kiểm tra có thể trả nợ không (tất cả điều kiện)
     * @return canRepay_ True nếu có thể trả
     * @return reason    Lý do nếu không thể (chuỗi rỗng nếu được)
     */
    function canRepay(
        bool    isActive,
        bool    isLiquidatable,
        uint256 totalAmount,
        address payer,
        address loanToken,
        address loanContract
    ) internal view returns (bool canRepay_, string memory reason) {
        if (!isActive) return (false, "Loan not active");
        if (isLiquidatable) return (false, "Loan should be liquidated first");
        if (totalAmount == 0) return (false, "Zero repayment amount");

        uint256 balance   = IERC20(loanToken).balanceOf(payer);
        uint256 allowance = IERC20(loanToken).allowance(payer, loanContract);

        if (balance < totalAmount) return (false, "Insufficient balance");
        if (allowance < totalAmount) return (false, "Insufficient allowance");

        return (true, "");
    }
}
