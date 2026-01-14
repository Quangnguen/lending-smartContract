// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/ILoan.sol";
import "../libraries/InterestLib.sol";
contract Loan is ILoan, ReentrancyGuard {
    using SafeERC20 for IERC20;
    LoanDetails public loanDetails;
    address public factory;
    uint256 public lateFeeRate;
    uint256 public constant BASIS_POINTS = 10000;
    error OnlyBorrower();
    error OnlyLender();
    error OnlyFactory();
    error InvalidStatus();
    modifier onlyBorrower() {
        if (msg.sender != loanDetails.borrower) revert OnlyBorrower();
        _;
    }
    modifier inStatus(LoanStatus status) {
        if (loanDetails.status != status) revert InvalidStatus();
        _;
    }
    constructor(
        uint256 _loanId, address _borrower, address _loanToken,
        address _collateralToken, uint256 _principal, uint256 _interestRate,
        uint256 _collateralAmount, uint256 _duration, uint256 _lateFeeRate
    ) {
        factory = msg.sender;
        lateFeeRate = _lateFeeRate;
        loanDetails = LoanDetails({
            loanId: _loanId, borrower: _borrower, lender: address(0),
            loanToken: _loanToken, collateralToken: _collateralToken,
            principal: _principal, interestRate: _interestRate,
            collateralAmount: _collateralAmount, duration: _duration,
            startTime: 0, endTime: 0, status: LoanStatus.PENDING
        });
        emit LoanCreated(_loanId, _borrower, _principal);
    }
    function fund() external override nonReentrant inStatus(LoanStatus.PENDING) {
        loanDetails.lender = msg.sender;
        loanDetails.startTime = block.timestamp;
        loanDetails.endTime = block.timestamp + loanDetails.duration;
        loanDetails.status = LoanStatus.ACTIVE;
        IERC20(loanDetails.loanToken).safeTransferFrom(msg.sender, loanDetails.borrower, loanDetails.principal);
        emit LoanFunded(loanDetails.loanId, msg.sender);
    }
    function depositCollateral() external payable override {}
    function repay() external override nonReentrant onlyBorrower inStatus(LoanStatus.ACTIVE) {
        uint256 totalAmount = getTotalRepaymentAmount();
        IERC20(loanDetails.loanToken).safeTransferFrom(msg.sender, loanDetails.lender, totalAmount);
        loanDetails.status = LoanStatus.REPAID;
        emit LoanRepaid(loanDetails.loanId, totalAmount);
    }
    function liquidate() external override nonReentrant inStatus(LoanStatus.ACTIVE) {
        if (!isOverdue()) revert InvalidStatus();
        loanDetails.status = LoanStatus.LIQUIDATED;
        emit LoanLiquidated(loanDetails.loanId, msg.sender);
    }
    function cancel() external override onlyBorrower inStatus(LoanStatus.PENDING) {
        loanDetails.status = LoanStatus.CANCELLED;
        emit LoanCancelled(loanDetails.loanId);
    }
    function getLoanDetails() external view override returns (LoanDetails memory) {
        return loanDetails;
    }
    function getTotalRepaymentAmount() public view override returns (uint256) {
        if (loanDetails.status != LoanStatus.ACTIVE) return 0;
        uint256 interest = InterestLib.calculateAccruedInterest(
            loanDetails.principal, loanDetails.interestRate,
            loanDetails.startTime, block.timestamp
        );
        uint256 lateFee = 0;
        if (isOverdue()) {
            uint256 daysLate = (block.timestamp - loanDetails.endTime) / 1 days;
            lateFee = InterestLib.calculateLateFee(loanDetails.principal, lateFeeRate, daysLate);
        }
        return loanDetails.principal + interest + lateFee;
    }
    function isOverdue() public view override returns (bool) {
        return loanDetails.status == LoanStatus.ACTIVE && block.timestamp > loanDetails.endTime;
    }
    function getCollateralRatio() public view override returns (uint256) {
        return 15000;
    }
}