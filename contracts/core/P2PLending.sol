// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IP2PLending.sol";
import "./Loan.sol";

contract P2PLending is IP2PLending, Ownable, ReentrancyGuard {
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public platformFee = 100; // 1%
    uint256 public minCollateralRatio = 15000; // 150%
    uint256 public lateFeeRate = 50; // 0.5% per day
    uint256 public nextRequestId = 1;
    mapping(uint256 => LoanRequest) public loanRequests;
    mapping(uint256 => address) public requestBorrower;
    mapping(uint256 => bool) public requestActive;
    mapping(uint256 => address) public requestToLoan;
    mapping(address => bool) public whitelistedTokens;
    mapping(address => UserInfo) public users;
    mapping(address => address[]) public userBorrowedLoans;
    mapping(address => address[]) public userLentLoans;
    uint256[] public pendingRequestIds;

    error TokenNotWhitelisted();
    error RequestNotActive();
    error NotRequestOwner();

    constructor(address initialOwner) Ownable(initialOwner) {}
    
    function createLoanRequest(LoanRequest calldata request) 
        external override returns (uint256 requestId) 
    {
        if (!whitelistedTokens[request.loanToken]) revert TokenNotWhitelisted();
        
        requestId = nextRequestId++;
        loanRequests[requestId] = request;
        requestBorrower[requestId] = msg.sender;
        requestActive[requestId] = true;
        pendingRequestIds.push(requestId);
        emit LoanRequestCreated(requestId, msg.sender, request.principal);
    }

    function cancelLoanRequest(uint256 requestId) external override {
        if (requestBorrower[requestId] != msg.sender) revert NotRequestOwner();
        if (!requestActive[requestId]) revert RequestNotActive();
        
        requestActive[requestId] = false;
        emit LoanRequestCancelled(requestId, msg.sender);
    }

    function fundLoanRequest(uint256 requestId) 
        external override nonReentrant returns (address loanContract) 
    {
        if (!requestActive[requestId]) revert RequestNotActive();
        
        LoanRequest memory req = loanRequests[requestId];
        address borrower = requestBorrower[requestId];
        // Deploy new Loan contract
        Loan loan = new Loan(
            requestId, borrower, req.loanToken, req.collateralToken,
            req.principal, req.interestRate, req.collateralAmount,
            req.duration, lateFeeRate
        );
        loanContract = address(loan);
        // Fund the loan
        loan.fund();
        requestActive[requestId] = false;
        requestToLoan[requestId] = loanContract;
        userBorrowedLoans[borrower].push(loanContract);
        userLentLoans[msg.sender].push(loanContract);
        emit LoanMatched(requestId, msg.sender, loanContract);
    }

    // View functions
    function getPendingRequests() external view override returns (uint256[] memory) {
        uint256 count = 0;
        for (uint i = 0; i < pendingRequestIds.length; i++) {
            if (requestActive[pendingRequestIds[i]]) count++;
        }
        uint256[] memory active = new uint256[](count);
        uint256 j = 0;
        for (uint i = 0; i < pendingRequestIds.length; i++) {
            if (requestActive[pendingRequestIds[i]]) {
                active[j++] = pendingRequestIds[i];
            }
        }
        return active;
    }

    function getLoanRequest(uint256 requestId) external view override returns (LoanRequest memory) {
        return loanRequests[requestId];
    }

    function getUserInfo(address user) external view override returns (UserInfo memory) {
        return users[user];
    }

    function getUserLoans(address user) external view override 
        returns (address[] memory, address[] memory) 
    {
        return (userBorrowedLoans[user], userLentLoans[user]);
    }

    function whitelistToken(address token, bool status) external onlyOwner {
        whitelistedTokens[token] = status;
        emit TokenWhitelisted(token, status);
    }

    function isTokenWhitelisted(address token) external view override returns (bool) {
        return whitelistedTokens[token];
    }

    function getPlatformFee() external view override returns (uint256) {
        return platformFee;
    }

    function getMinCollateralRatio() external view override returns (uint256) {
        return minCollateralRatio;
    }

    // Admin functions
    function setPlatformFee(uint256 newFee) external onlyOwner {
        uint256 oldFee = platformFee;
        platformFee = newFee;
        emit PlatformFeeUpdated(oldFee, newFee);
    }
}