// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ILoan {
    enum LoanStatus {
        PENDING, // 0 - đang chờ người cho vay
        ACTIVE, // 1 - đang hoạt động (đã được fund)
        REPAID, // 2 - đã trả hết nợ
        DEFAULTED, // 3 - vỡ nợ/qua hạn không trả
        LIQUIDATED, // 4 - đã thanh lý tài sản thế chấp
        CANCELLED // 5 - đã hủy (trước khi được fund)
    }

    struct LoanDetails {
        uint256 loanId;
        address borrower;
        address lender; 
        address loanToken;
        address collateralToken;
        uint256 principal;
        uint256 interestRate;
        uint256 collateralAmount;
        uint256 duration;
        uint256 startTime;
        uint256 endTime;
        LoanStatus status;
    }

    event LoanCreated(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 principal
    );

    event LoanFunded(
        uint256 indexed loanId,
        address indexed lender
    );

    event LoanRepaid(
        uint256 indexed loanId,
        uint256 totalAmount
    );

    event LoanLiquidated(
        uint256 indexed loanId,
        address indexed liquidator
    );

    event LoanCancelled(
        uint256 indexed loanId
    );


    // Lấy thông tin khoản vay
    function getLoanDetails() external view returns (LoanDetails memory); 

    // Người cho vay chuyển tiền
    function fund(address lender) external;



    function repay() external;

    function liquidate() external;

    function cancel() external;

    function getTotalRepaymentAmount() external view returns (uint256);

    function isOverdue() external view returns (bool);

    function getCollateralRatio() external view returns (uint256);

    
}