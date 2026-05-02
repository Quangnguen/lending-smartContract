// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IP2PLending.sol";
import "../interfaces/ICreditScoreOracle.sol";
import "./Loan.sol";

/**
 * @title P2PLending
 * @dev Factory contract cho hệ thống cho vay P2P
 *
 * CORE CONCEPT: Dynamic Collateral Ratio dựa trên Credit Score
 * - Tích hợp CreditScoreOracle để đọc điểm tín dụng on-chain
 * - Borrower có score cao → cần ít thế chấp hơn (under-collateralized)
 * - Borrower không có score → yêu cầu 150% (giống DeFi thuần túy)
 *
 * Flow:
 * 1. Backend tính Credit Score từ Open Banking
 * 2. Backend đẩy score lên CreditScoreOracle.sol
 * 3. Borrower tạo loan request → P2PLending đọc collateral ratio từ Oracle
 * 4. Lender fund → deploy Loan contract → giải ngân
 */
contract P2PLending is IP2PLending, Ownable, ReentrancyGuard {
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public platformFee = 100; // 1%
    uint256 public minCollateralRatio = 15000; // 150% — fallback khi không có Oracle
    uint256 public lateFeeRate = 50; // 0.5% per day
    uint256 public nextRequestId = 1;

    /// @dev Credit Score Oracle — cho phép dynamic collateral ratio
    ICreditScoreOracle public creditScoreOracle;

    mapping(uint256 => LoanRequest) public loanRequests;
    mapping(uint256 => address) public requestBorrower;
    mapping(uint256 => bool) public requestActive;
    mapping(uint256 => address) public requestToLoan;
    mapping(uint256 => uint256) public requestCollateralRatio; // Lưu ratio tại thời điểm tạo request
    mapping(address => bool) public whitelistedTokens;
    mapping(address => UserInfo) public users;
    mapping(address => address[]) public userBorrowedLoans;
    mapping(address => address[]) public userLentLoans;
    uint256[] public pendingRequestIds;

    error TokenNotWhitelisted();
    error RequestNotActive();
    error NotRequestOwner();
    error InsufficientCollateral();

    // Events cho Oracle integration
    event CreditScoreOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event CollateralRatioApplied(uint256 indexed requestId, address indexed borrower, uint256 ratio, uint256 creditScore);

    constructor(address initialOwner) Ownable(initialOwner) {}

    /**
     * @dev Tạo yêu cầu vay — collateral ratio được tính dynamic từ Oracle
     *
     * Nếu có CreditScoreOracle:
     *   - Score >= 800 → chỉ cần 50% collateral
     *   - Score >= 600 → 100% collateral
     *   - Score < 400  → 150% collateral (full)
     *
     * Nếu không có Oracle hoặc score hết hạn:
     *   - Dùng minCollateralRatio (150%) — backward compatible
     */
    function createLoanRequest(LoanRequest calldata request) 
        external override returns (uint256 requestId) 
    {
        if (!whitelistedTokens[request.loanToken]) revert TokenNotWhitelisted();
        
        // Xác định collateral ratio cho borrower
        uint256 requiredRatio = _getCollateralRatioForBorrower(msg.sender);
        
        requestId = nextRequestId++;
        loanRequests[requestId] = request;
        requestBorrower[requestId] = msg.sender;
        requestActive[requestId] = true;
        requestCollateralRatio[requestId] = requiredRatio;
        pendingRequestIds.push(requestId);

        // Lấy credit score để emit event (0 nếu không có Oracle)
        uint256 creditScore = 0;
        if (address(creditScoreOracle) != address(0)) {
            (creditScore, , ) = creditScoreOracle.getCreditScore(msg.sender);
        }

        emit LoanRequestCreated(requestId, msg.sender, request.principal);
        emit CollateralRatioApplied(requestId, msg.sender, requiredRatio, creditScore);
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

    // ===== ORACLE FUNCTIONS =====

    /**
     * @dev Lấy collateral ratio cho một borrower cụ thể
     * Frontend/Backend có thể gọi trước khi tạo loan request
     */
    function getCollateralRatioForBorrower(address borrower)
        external view returns (uint256 ratio, uint256 creditScore, bool hasScore)
    {
        ratio = _getCollateralRatioForBorrower(borrower);
        if (address(creditScoreOracle) != address(0)) {
            (creditScore, , hasScore) = creditScoreOracle.getCreditScore(borrower);
        }
    }

    /**
     * @dev Lấy collateral ratio đã lưu cho một request
     */
    function getRequestCollateralRatio(uint256 requestId) external view returns (uint256) {
        return requestCollateralRatio[requestId];
    }

    // ===== VIEW FUNCTIONS =====

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

    // ===== ADMIN FUNCTIONS =====

    function setPlatformFee(uint256 newFee) external onlyOwner {
        uint256 oldFee = platformFee;
        platformFee = newFee;
        emit PlatformFeeUpdated(oldFee, newFee);
    }

    /**
     * @dev Set CreditScoreOracle address (admin only)
     * Có thể set về address(0) để disable Oracle (fallback về fixed ratio)
     */
    function setCreditScoreOracle(address _oracle) external onlyOwner {
        address oldOracle = address(creditScoreOracle);
        creditScoreOracle = ICreditScoreOracle(_oracle);
        emit CreditScoreOracleUpdated(oldOracle, _oracle);
    }

    /**
     * @dev Set minimum collateral ratio (fallback khi không có Oracle)
     */
    function setMinCollateralRatio(uint256 newRatio) external onlyOwner {
        uint256 oldRatio = minCollateralRatio;
        minCollateralRatio = newRatio;
        emit CollateralRatioUpdated(oldRatio, newRatio);
    }

    // ===== INTERNAL =====

    /**
     * @dev Tính collateral ratio cho borrower
     * Ưu tiên: Oracle score → fallback minCollateralRatio
     */
    function _getCollateralRatioForBorrower(address borrower) internal view returns (uint256) {
        // Nếu có Oracle và borrower có score hợp lệ
        if (address(creditScoreOracle) != address(0)) {
            if (creditScoreOracle.hasValidScore(borrower)) {
                return creditScoreOracle.getRequiredCollateralRatio(borrower);
            }
        }

        // Fallback: dùng minCollateralRatio (150%)
        return minCollateralRatio;
    }
}