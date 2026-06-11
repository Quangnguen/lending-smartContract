// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/ILoan.sol";
import "../interfaces/ICollateralManager.sol";
import "../libraries/LoanLib.sol";
import "../libraries/RepaymentLib.sol";


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

    
    constructor() {
        _initialized = true;
    }

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

    function repay()
        external
        override
        nonReentrant
        onlyBorrower
        inStatus(LoanStatus.ACTIVE)
    {
        _executeRepayment(msg.sender);
    }

  
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

   
    function getCurrentCollateralRatio() external pure override returns (uint256) {
        return 0; // Caller dùng CollateralManager.getCollateralRatio(loanId)
    }

    
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
