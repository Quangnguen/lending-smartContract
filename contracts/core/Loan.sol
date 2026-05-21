// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/ILoan.sol";
import "../interfaces/ICollateralManager.sol";
import "../libraries/LoanLib.sol";
import "../libraries/RepaymentLib.sol";

/**
 * @title Loan
 * @dev Clone contract cho từng khoản vay — EIP-1167 Minimal Proxy Pattern
 *
 * ╔══════════════════════════════════════════════════════════════════════╗
 * ║  THIẾT KẾ BẢO MẬT                                                   ║
 * ╠══════════════════════════════════════════════════════════════════════╣
 * ║  • EIP-1167 Clone: tiết kiệm ~90% gas so với deploy đầy đủ          ║
 * ║  • Implementation lock: constructor set _initialized = true          ║
 * ║    → Ngăn attacker gọi initialize() trên implementation contract     ║
 * ║  • CEI Pattern: mọi state change TRƯỚC external calls                ║
 * ║  • nonReentrant: bảo vệ repay(), repayOnBehalf(), liquidate()        ║
 * ║  • Factory-only: fund(), liquidate() chỉ P2PLending                  ║
 * ║  • Interest cap: tính đến endTime, không tăng sau đáo hạn            ║
 * ║  • repayOnBehalf: bất kỳ ai trả thay, collateral về borrower         ║
 * ╚══════════════════════════════════════════════════════════════════════╝
 *
 * ─── Repayment Flow ─────────────────────────────────────────────────────
 *
 *  repay() / repayOnBehalf(payer):
 *    CHECKS  → validate status, payer allowance + balance
 *    EFFECTS → status = REPAID, ghi repaidAt, actualPayer, amountRepaid
 *              emit LoanRepaid (đầy đủ breakdown)
 *    INTERACT→ safeTransferFrom(payer → lender, totalAmount)
 *              collateralManager.withdrawCollateral() [try-catch]
 *              emit CollateralReleased / CollateralReleaseFailed
 *
 * ─── Interest Model ──────────────────────────────────────────────────────
 *
 *   interest = P × R × min(now, endTime) / (10000 × 365days)
 *   lateFee  = P × dailyRate × daysLate  (chỉ khi now > endTime)
 *   total    = principal + interest + lateFee
 *
 *   Lý do cap interest tại endTime:
 *   → Tránh double-counting: interest và lateFee không overlap
 *   → Borrower biết trước worst-case interest (predictable UX)
 *   → Chuẩn của Maple Finance, TrueFi, Goldfinch
 *
 * Lifecycle: PENDING → ACTIVE → REPAID
 *                          ↘ (overdue + grace) ACTIVE → LIQUIDATED
 *            PENDING → CANCELLED (chỉ qua P2PLending.cancelLoanRequest)
 */
contract Loan is ILoan, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using LoanLib   for uint256;

    // =========================================================
    // STATE
    // =========================================================

    LoanDetails public loanDetails;

    /// @dev Factory contract (P2PLending) — chỉ factory gọi fund()/liquidate()
    address public factory;

    /// @dev Phí trễ hạn mỗi ngày (basis points, 50 = 0.5%/ngày)
    uint256 public lateFeeRate;

    /// @dev Tổng số tiền đã trả (principal + interest + lateFee)
    uint256 public amountRepaid;

    /// @dev Timestamp khi repay thành công (0 = chưa trả)
    uint256 public override repaidAt;

    /// @dev Người thực sự chuyển tiền (khác borrower nếu repayOnBehalf)
    address public override actualPayer;

    ICollateralManager public collateralManager;

    /// @dev Guard cho initialize() — true = đã init
    bool private _initialized;

    // =========================================================
    // CONSTANTS
    // =========================================================

    uint256 public constant BASIS_POINTS = 10_000;

    // =========================================================
    // ERRORS
    // =========================================================

    error Loan__OnlyBorrower(address caller, address borrower);
    error Loan__OnlyFactory(address caller, address factory);
    error Loan__InvalidStatus(LoanStatus current, LoanStatus expected);
    error Loan__AlreadyInitialized();
    error Loan__ZeroAddress();
    error Loan__ZeroAmount();
    error Loan__InsufficientAllowance(address payer, uint256 allowance, uint256 required);
    error Loan__InsufficientBalance(address payer, uint256 balance, uint256 required);

    // =========================================================
    // MODIFIERS
    // =========================================================

    modifier onlyBorrower() {
        if (msg.sender != loanDetails.borrower) {
            revert Loan__OnlyBorrower(msg.sender, loanDetails.borrower);
        }
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) {
            revert Loan__OnlyFactory(msg.sender, factory);
        }
        _;
    }

    modifier inStatus(LoanStatus expected) {
        if (loanDetails.status != expected) {
            revert Loan__InvalidStatus(loanDetails.status, expected);
        }
        _;
    }

    // =========================================================
    // CONSTRUCTOR — Lock implementation contract
    // =========================================================

    /**
     * @dev Lock implementation contract ngay trong constructor.
     *
     * EIP-1167 Clones.clone() không chạy constructor của implementation.
     * Nhưng chính implementation này cần bị lock để ngăn attacker gọi
     * initialize() trên nó (dù không ảnh hưởng đến các clone đã deploy).
     *
     * Pattern chuẩn: OpenZeppelin Initializable._disableInitializers()
     */
    constructor() {
        _initialized = true;
    }

    // =========================================================
    // INITIALIZE — Thay thế constructor cho clone
    // =========================================================

    /**
     * @dev Khởi tạo clone — P2PLending gọi ngay sau Clones.clone()
     *
     * Chỉ được gọi 1 lần (guard _initialized).
     * msg.sender trở thành factory — chỉ factory gọi fund()/liquidate().
     */
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
    ) external override {
        if (_initialized) revert Loan__AlreadyInitialized();
        if (_borrower  == address(0)) revert Loan__ZeroAddress();
        if (_loanToken == address(0)) revert Loan__ZeroAddress();

        _initialized = true;
        factory      = msg.sender;
        lateFeeRate  = _lateFeeRate;

        if (_collateralManager != address(0)) {
            collateralManager = ICollateralManager(_collateralManager);
        }

        loanDetails = LoanDetails({
            loanId:           _loanId,
            borrower:         _borrower,
            lender:           address(0),
            loanToken:        _loanToken,
            collateralToken:  _collateralToken,
            principal:        _principal,
            interestRate:     _interestRate,
            collateralAmount: _collateralAmount,
            duration:         _duration,
            startTime:        0,
            endTime:          0,
            createdAt:        block.timestamp,
            status:           LoanStatus.PENDING
        });

        emit LoanCreated(
            _loanId, _borrower, _loanToken, _collateralToken,
            _principal, _interestRate, _collateralAmount, _duration
        );
    }

    // =========================================================
    // FUND — Chỉ factory
    // =========================================================

    /**
     * @dev Lender cấp vốn — P2PLending.fundLoanRequest() gọi hàm này
     * Chuyển trạng thái PENDING → ACTIVE, ghi lại startTime/endTime
     */
    function fund(address lender)
        external
        override
        onlyFactory
        nonReentrant
        inStatus(LoanStatus.PENDING)
    {
        if (lender == address(0)) revert Loan__ZeroAddress();

        // EFFECTS
        loanDetails.lender    = lender;
        loanDetails.startTime = block.timestamp;
        loanDetails.endTime   = block.timestamp + loanDetails.duration;
        loanDetails.status    = LoanStatus.ACTIVE;

        emit LoanFunded(
            loanDetails.loanId,
            lender,
            loanDetails.startTime,
            loanDetails.endTime
        );
    }

    // =========================================================
    // REPAY — Borrower tự trả
    // =========================================================

    /**
     * @notice Borrower trả nợ đầy đủ
     *
     * ┌─ CEI Pattern ───────────────────────────────────────────────────┐
     * │ CHECKS:                                                          │
     * │   1. status == ACTIVE                                            │
     * │   2. Tính breakdown (principal, interest capped, lateFee)        │
     * │   3. allowance >= totalAmount                                    │
     * │   4. balance >= totalAmount                                      │
     * │ EFFECTS:                                                         │
     * │   5. status = REPAID, amountRepaid, repaidAt, actualPayer        │
     * │   6. emit LoanRepaid (đầy đủ params)                            │
     * │ INTERACTIONS:                                                    │
     * │   7. safeTransferFrom(borrower → lender, totalAmount)           │
     * │   8. collateralManager.withdrawCollateral() [try-catch]          │
     * │   9. emit CollateralReleased / CollateralReleaseFailed           │
     * └─────────────────────────────────────────────────────────────────┘
     */
    function repay()
        external
        override
        nonReentrant
        onlyBorrower
        inStatus(LoanStatus.ACTIVE)
    {
        _executeRepayment(msg.sender);
    }

    // =========================================================
    // REPAY ON BEHALF — Bất kỳ ai trả thay
    // =========================================================

    /**
     * @notice Bất kỳ ai trả nợ thay cho borrower
     *
     * Use cases chính:
     *   1. Emergency rescue: bạn bè/gia đình trả khi borrower mất access
     *   2. Keeper/bot: tự động trả khi loan sắp bị liquidate (bảo vệ collateral)
     *   3. DeFi composability: protocol khác trả thay để mua loan position
     *
     * Security model:
     *   • Payer phải approve Loan contract trước
     *   • Collateral LUÔN về borrower (không phải payer)
     *   • Không ai được lợi ích trực tiếp từ việc trả thay
     *   • onlyBorrower không apply — bất kỳ ai đều được
     *
     * Flash loan abuse analysis:
     *   • Kẻ tấn công flash borrow USDT → repay thay borrower → nhận lại gì?
     *   • Không nhận được gì: collateral về borrower, không về payer
     *   • Tấn công vô nghĩa về kinh tế → safe
     *
     * @param payer Địa chỉ chuyển USDT (phải đã approve Loan contract)
     */
    function repayOnBehalf(address payer)
        external
        override
        nonReentrant
        inStatus(LoanStatus.ACTIVE)
    {
        if (payer == address(0)) revert Loan__ZeroAddress();

        // Note: Không require caller == borrower (đây là tính năng, không phải lỗi)
        // msg.sender có thể là bất kỳ ai (keeper, relayer, friend)
        // payer là người thực sự chuyển tiền (phải approve trước)
        _executeRepayment(payer);
    }

    // =========================================================
    // LIQUIDATE — Chỉ factory
    // =========================================================

    /**
     * @dev Thanh lý khoản vay — P2PLending.liquidateLoan() entry point duy nhất
     *
     * Factory đã verify isLiquidatable() và handle USDT transfer trước.
     * Hàm này chỉ update state (EFFECTS only — không có INTERACTIONS).
     */
    function liquidate()
        external
        override
        onlyFactory
        nonReentrant
        inStatus(LoanStatus.ACTIVE)
    {
        loanDetails.status = LoanStatus.LIQUIDATED;
        emit LoanLiquidated(loanDetails.loanId, msg.sender, loanDetails.collateralAmount);
    }

    // =========================================================
    // CANCEL — Chỉ borrower, chỉ khi PENDING
    // =========================================================

    /**
     * @dev Hủy request trước khi được fund
     *
     * FIX C-6: Chỉ factory (P2PLending) mới được gọi cancel.
     * Trước đây borrower gọi trực tiếp làm bypass P2PLending state update.
     *
     * Flow đúng:
     *   Borrower → P2PLending.cancelLoanRequest() → Loan.cancel()
     *   (P2PLending cập nhật requestActive + _pendingRequestIds trước)
     */
    function cancel()
        external
        override
        onlyFactory          // FIX: onlyBorrower → onlyFactory
        inStatus(LoanStatus.PENDING)
    {
        uint256 loanId = loanDetails.loanId;

        // EFFECTS
        loanDetails.status = LoanStatus.CANCELLED;
        emit LoanCancelled(loanId, loanDetails.borrower);

        // INTERACTIONS — try-catch không block cancel
        if (address(collateralManager) != address(0)) {
            try collateralManager.withdrawCollateral(loanId) {} catch {}
        }
    }

    // =========================================================
    // VIEW FUNCTIONS
    // =========================================================

    /// @inheritdoc ILoan
    function getLoanDetails() external view override returns (LoanDetails memory) {
        return loanDetails;
    }

    /**
     * @notice Breakdown số tiền cần trả tại block.timestamp
     *
     * KEY FIX: Interest được cap tại endTime.
     *
     * Ví dụ (principal=1000 USDT, rate=10%/năm, duration=30d):
     *   Trả đúng hạn (ngày 30):
     *     interest = 1000 × 10% × 30/365 = 8.22 USDT
     *     lateFee  = 0
     *     total    = 1008.22 USDT
     *
     *   Trả trễ 10 ngày (ngày 40):
     *     interest = 1000 × 10% × 30/365 = 8.22 USDT (KHÔNG tăng thêm)
     *     lateFee  = 1000 × 0.5% × 10 = 50 USDT
     *     total    = 1058.22 USDT
     */
    function getRepaymentBreakdown()
        public
        view
        override
        returns (uint256 principal, uint256 interest, uint256 lateFee)
    {
        if (loanDetails.status != LoanStatus.ACTIVE) return (0, 0, 0);

        LoanLib.RepaymentBreakdown memory bd = LoanLib.calculateRepaymentBreakdown(
            loanDetails.principal,
            loanDetails.interestRate,
            lateFeeRate,
            loanDetails.startTime,
            loanDetails.endTime,
            block.timestamp
        );

        return (bd.principal, bd.interest, bd.lateFee);
    }

    /// @inheritdoc ILoan
    function getTotalRepaymentAmount() external view override returns (uint256) {
        (uint256 p, uint256 i, uint256 f) = getRepaymentBreakdown();
        return p + i + f;
    }

    /// @inheritdoc ILoan
    function isOverdue() public view override returns (bool) {
        return loanDetails.status == LoanStatus.ACTIVE
            && loanDetails.endTime > 0
            && block.timestamp > loanDetails.endTime + LoanLib.GRACE_PERIOD;
        // FIX L-7: Dùng GRACE_PERIOD (1 ngày) — borrower có 1 ngày sau deadline trước khi bị liquidate
    }

    /**
     * @inheritdoc ILoan
     * @dev Dynamic ratio cần oracle — do CollateralManager.getCollateralRatio() tính
     * Loan clone không có oracle access để giữ contract nhẹ
     */
    function getCurrentCollateralRatio() external pure override returns (uint256) {
        return 0; // Caller dùng CollateralManager.getCollateralRatio(loanId)
    }

    // =========================================================
    // INTERNAL — Core repayment logic (shared by repay + repayOnBehalf)
    // =========================================================

    /**
     * @dev Execute repayment — dùng chung cho repay() và repayOnBehalf()
     *
     * @param payer Địa chỉ chuyển USDT (borrower khi tự trả, hoặc bên thứ 3)
     *
     * ─── CEI Pattern ───────────────────────────────────────────────────
     * CHECKS:
     *   Tính breakdown → validate allowance + balance của payer
     * EFFECTS:
     *   Cập nhật state hoàn toàn trước bất kỳ external call nào
     * INTERACTIONS:
     *   Transfer USDT → release collateral
     * ───────────────────────────────────────────────────────────────────
     */
    function _executeRepayment(address payer) internal {
        // ── CHECKS ──────────────────────────────────────────────────────────
        // Build full breakdown (interest capped tại endTime)
        LoanLib.RepaymentBreakdown memory bd = LoanLib.calculateRepaymentBreakdown(
            loanDetails.principal,
            loanDetails.interestRate,
            lateFeeRate,
            loanDetails.startTime,
            loanDetails.endTime,
            block.timestamp
        );

        if (bd.totalAmount == 0) revert Loan__ZeroAmount();

        // Cache storage reads để dùng sau EFFECTS (tránh re-read stale state)
        address lender    = loanDetails.lender;
        address loanToken = loanDetails.loanToken;
        uint256 loanId    = loanDetails.loanId;
        address borrower  = loanDetails.borrower;

        // Validate allowance và balance của payer TRƯỚC state change
        uint256 allowance = IERC20(loanToken).allowance(payer, address(this));
        if (allowance < bd.totalAmount) {
            revert Loan__InsufficientAllowance(payer, allowance, bd.totalAmount);
        }
        uint256 balance = IERC20(loanToken).balanceOf(payer);
        if (balance < bd.totalAmount) {
            revert Loan__InsufficientBalance(payer, balance, bd.totalAmount);
        }

        // ── EFFECTS ─────────────────────────────────────────────────────────
        // Cập nhật state TRƯỚC mọi external call (CEI)
        loanDetails.status = LoanStatus.REPAID;
        amountRepaid       = bd.totalAmount;
        repaidAt           = block.timestamp;
        actualPayer        = payer;

        emit LoanRepaid(
            loanId,
            borrower,
            payer,
            bd.principal,
            bd.interest,
            bd.lateFee,
            bd.totalAmount,
            block.timestamp,
            bd.isOverdue
        );

        // ── INTERACTIONS ─────────────────────────────────────────────────────
        // 1. Payer chuyển USDT cho lender
        //    Lender nhận: principal + interest + lateFee (toàn bộ)
        //    Upgrade path: split lateFee → protocol treasury
        IERC20(loanToken).safeTransferFrom(payer, lender, bd.totalAmount);

        // 2. Release collateral về borrower (try-catch — KHÔNG block repayment)
        //    Nếu fail, borrower tự gọi CollateralManager.withdrawCollateral()
        _releaseCollateral(loanId, borrower);
    }

    /**
     * @dev Release collateral sau khi repay thành công
     * Dùng try-catch để collateral fail không block việc trả nợ
     *
     * Tại sao try-catch?
     *   • Repayment đã completed (state = REPAID, transfer done)
     *   • Không nên revert toàn bộ tx vì CM có vấn đề
     *   • Borrower có thể tự withdraw thông qua CM sau đó
     *   • emit event đủ context để recover
     */
    function _releaseCollateral(uint256 loanId, address borrower) internal {
        if (address(collateralManager) == address(0)) return;

        uint256 collateralAmount = loanDetails.collateralAmount;
        address collateralToken  = loanDetails.collateralToken;

        try collateralManager.withdrawCollateral(loanId) {
            emit CollateralReleased(loanId, borrower, collateralToken, collateralAmount);
        } catch Error(string memory reason) {
            emit CollateralReleaseFailed(loanId, borrower, collateralAmount, reason);
        } catch {
            emit CollateralReleaseFailed(loanId, borrower, collateralAmount, "unknown error");
        }
    }
}
