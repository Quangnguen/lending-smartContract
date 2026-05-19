// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/ILoan.sol";
import "../interfaces/ICollateralManager.sol";
import "../libraries/InterestLib.sol";

/**
 * @title Loan
 * @dev Hợp đồng khoản vay — thiết kế theo EIP-1167 Clone Factory pattern
 *
 * THAY ĐỔI SO VỚI BẢN CŨ:
 *   - Bỏ constructor có tham số (không tương thích với Clones)
 *   - Thêm hàm initialize() để P2PLending gọi sau khi clone
 *   - Thêm _initialized guard để chống gọi initialize() 2 lần
 *
 * LÝ DO:
 *   Clones.clone() chỉ copy 45 bytes proxy code, KHÔNG chạy constructor.
 *   Vì vậy phải dùng initialize() thay thế (giống OpenZeppelin Upgradeable pattern).
 */
contract Loan is ILoan, ReentrancyGuard {
    using SafeERC20 for IERC20;

    LoanDetails public loanDetails;
    address public factory;
    uint256 public lateFeeRate;
    uint256 public constant BASIS_POINTS = 10000;
    bool private _initialized;

    /// @dev CollateralManager để hoàn trả ETH khi repay/cancel
    ICollateralManager public collateralManager;

    error OnlyBorrower();
    error OnlyLender();
    error OnlyFactory();
    error InvalidStatus();
    error AlreadyInitialized();

    /// @dev Emit khi auto-withdraw collateral thất bại
    event CollateralReleaseFailed(uint256 indexed loanId);

    modifier onlyBorrower() {
        if (msg.sender != loanDetails.borrower) revert OnlyBorrower();
        _;
    }
    modifier inStatus(LoanStatus status) {
        if (loanDetails.status != status) revert InvalidStatus();
        _;
    }

    /**
     * @dev Constructor rỗng — bắt buộc khi dùng Clones.
     *      State được khởi tạo qua initialize() bên dưới.
     */
    constructor() {}

    /**
     * @dev Thay thế constructor — được P2PLending gọi ngay sau clone().
     *      Chỉ được gọi 1 lần (được bảo vệ bởi _initialized).
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
    ) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        factory = msg.sender; // P2PLending contract
        lateFeeRate = _lateFeeRate;
        collateralManager = ICollateralManager(_collateralManager);
        loanDetails = LoanDetails({
            loanId: _loanId,
            borrower: _borrower,
            lender: address(0),
            loanToken: _loanToken,
            collateralToken: _collateralToken,
            principal: _principal,
            interestRate: _interestRate,
            collateralAmount: _collateralAmount,
            duration: _duration,
            startTime: 0,
            endTime: 0,
            status: LoanStatus.PENDING
        });
        emit LoanCreated(_loanId, _borrower, _principal);
    }

    function fund(address lender) external override nonReentrant inStatus(LoanStatus.PENDING) {
        if (msg.sender != factory) revert OnlyFactory();
        loanDetails.lender = lender;
        loanDetails.startTime = block.timestamp;
        loanDetails.endTime = block.timestamp + loanDetails.duration;
        loanDetails.status = LoanStatus.ACTIVE;
        emit LoanFunded(loanDetails.loanId, lender);
    }

    /**
     * @dev Trả nợ:
     *   1. Chuyển USDT (principal + interest + lateFee) từ Borrower → Lender
     *   2. Hoàn trả ETH collateral từ CollateralManager → Borrower
     */
    function repay() external override nonReentrant onlyBorrower inStatus(LoanStatus.ACTIVE) {
        uint256 totalAmount = getTotalRepaymentAmount();

        // 1. Trả USDT cho lender
        IERC20(loanDetails.loanToken).safeTransferFrom(
            msg.sender,
            loanDetails.lender,
            totalAmount
        );

        // 2. Cập nhật trạng thái TRƯỚC khi transfer ETH (CEI pattern)
        loanDetails.status = LoanStatus.REPAID;
        emit LoanRepaid(loanDetails.loanId, totalAmount);

        // 3. Hoàn ETH collateral về borrower
        if (address(collateralManager) != address(0)) {
            try collateralManager.withdrawCollateral(loanDetails.loanId) {
                // thành công — ETH đã về borrower
            } catch {
                // Không revert toàn bộ — borrower tự withdraw sau nếu cần
                emit CollateralReleaseFailed(loanDetails.loanId);
            }
        }
    }

    function liquidate() external override nonReentrant inStatus(LoanStatus.ACTIVE) {
        if (!isOverdue()) revert InvalidStatus();
        loanDetails.status = LoanStatus.LIQUIDATED;
        emit LoanLiquidated(loanDetails.loanId, msg.sender);
    }

    function cancel() external override onlyBorrower inStatus(LoanStatus.PENDING) {
        loanDetails.status = LoanStatus.CANCELLED;
        emit LoanCancelled(loanDetails.loanId);

        if (address(collateralManager) != address(0)) {
            try collateralManager.withdrawCollateral(loanDetails.loanId) {} catch {}
        }
    }

    function getLoanDetails() external view override returns (LoanDetails memory) {
        return loanDetails;
    }

    function getTotalRepaymentAmount() public view override returns (uint256) {
        if (loanDetails.status != LoanStatus.ACTIVE) return 0;
        uint256 interest = InterestLib.calculateAccruedInterest(
            loanDetails.principal,
            loanDetails.interestRate,
            loanDetails.startTime,
            block.timestamp
        );
        uint256 lateFee = 0;
        if (isOverdue()) {
            uint256 daysLate = (block.timestamp - loanDetails.endTime) / 1 days;
            lateFee = InterestLib.calculateLateFee(
                loanDetails.principal,
                lateFeeRate,
                daysLate
            );
        }
        return loanDetails.principal + interest + lateFee;
    }

    function isOverdue() public view override returns (bool) {
        return loanDetails.status == LoanStatus.ACTIVE
            && block.timestamp > loanDetails.endTime;
    }

    function getCollateralRatio() public pure override returns (uint256) {
        return 15000; // 150% — placeholder
    }
}