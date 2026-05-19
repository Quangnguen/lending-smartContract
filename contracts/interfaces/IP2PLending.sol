// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IP2PLending {
    struct LoanRequest {
        address loanToken;
        address collateralToken;
        uint256 principal;
        uint256 interestRate;
        uint256 collateralAmount;
        uint256 duration;
    }

    struct UserInfo {
        uint256 totalBorrowed;
        uint256 totalLent;
        uint256 activeLoans;
        uint256 reputation; // điểm uy tín
        uint256 defaultedCount; // số lần vỡ nợ
    }

    event LoanRequestCreated(
        uint256 indexed requestId,
        address indexed borrower,
        uint256 principal
    );

    event LoanRequestCancelled(
        uint256 indexed requestId,
        address indexed borrower
    );

    event LoanMatched(
        uint256 indexed requestId,
        address indexed lender,
        address loanContract
    );

    event TokenWhitelisted(address indexed token, bool status);

    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);

    event CollateralRatioUpdated(uint256 oldRatio, uint256 newRatio);


    // FUNCTION
    function createLoanRequest(LoanRequest calldata request)
        external payable
        returns (uint256 requestId);

    function cancelLoanRequest(uint256 requestId)
        external;

    //fund một yêu cầu vay
    function fundLoanRequest(uint256 requestId)
        external
        returns (address loanContract);

    // VIEW FUNCTION
    function getPendingRequests()
        external
        view
        returns (uint256[] memory);

    function getLoanRequest(uint256 requestId)
        external
        view
        returns (LoanRequest memory);

    function getUserInfo(address user)
        external
        view
        returns (UserInfo memory);

    function getUserLoans(address user)
        external
        view
        returns (
            address[] memory borrowedLoans,
            address[] memory lentLoans
        );

    function isTokenWhitelisted(address token)
        external
        view
        returns (bool);

    function getPlatformFee()
        external
        view
        returns (uint256);

    function getMinCollateralRatio()
        external
        view
        returns (uint256);
}