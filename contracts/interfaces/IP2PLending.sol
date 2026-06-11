// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;


interface IP2PLending {

    // =========================================================
    // STRUCTS
    // =========================================================

    
    struct LoanRequest {
        address loanToken;          // Token cho vay (phải được whitelist)
        address collateralToken;    // Token thế chấp (address(0) = ETH)
        uint256 principal;          // Số tiền vay (loanToken decimals)
        uint256 interestRate;       // Lãi suất năm (basis points)
        uint256 collateralAmount;   // Số lượng thế chấp
        uint256 duration;           // Thời hạn (giây)
        uint8   loanTokenDecimals;  // Decimals của loanToken (6 = USDT)
        uint8   collateralDecimals; // Decimals của collateralToken (18 = ETH)
        uint256 deadline;           // Hạn chót để fund trước khi bị auto-cancel
    }

    /**
     * @dev Thông tin user (tóm tắt tín dụng)
     */
    struct UserInfo {
        uint256 totalBorrowed;
        uint256 totalLent;
        uint256 activeLoans;
        uint256 reputation;
        uint256 defaultedCount;
    }

    // =========================================================
    // EVENTS
    // =========================================================

    event LoanRequestCreated(
        uint256 indexed requestId,
        address indexed borrower,
        address loanToken,
        address collateralToken,
        uint256 principal,
        uint256 interestRate,
        uint256 collateralAmount,
        uint256 duration,
        uint256 requiredCollateralRatio  // Dynamic ratio đã áp dụng
    );

    event LoanRequestCancelled(
        uint256 indexed requestId,
        address indexed borrower,
        uint256 collateralReturned
    );

    event LoanMatched(
        uint256 indexed requestId,
        address indexed lender,
        address indexed loanContract,
        uint256 platformFee,
        uint256 borrowerReceived,
        uint256 lenderAPY,        // Lãi thực lender nhận (basis points/năm)
        uint256 expectedReturn    // Lãi dự kiến (loanToken decimals)
    );

    event LoanLiquidated(
        uint256 indexed requestId,
        address indexed liquidator,
        address loanContract
    );

    event FeeCollected(
        uint256 indexed requestId,
        address indexed recipient,
        uint256 feeAmount
    );

    event TokenWhitelisted(address indexed token, bool status);

    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);

    event CollateralRatioUpdated(uint256 oldRatio, uint256 newRatio);

    event CollateralRatioApplied(
        uint256 indexed requestId,
        address indexed borrower,
        uint256 ratio,
        uint256 creditScore
    );

    /// @dev Emit khi admin thay đổi lateFeeRate (FIX M-8)
    event LateFeeRateUpdated(uint256 oldRate, uint256 newRate);

    /// @dev Emit khi refund ETH dư bị fail (FIX M-4)
    event ExcessETHRefundFailed(
        uint256 indexed requestId,
        address indexed borrower,
        uint256 amount
    );

    /// @dev Emit khi admin queue thay đổi param quan trọng (FIX H-9 Timelock)
    event AdminChangeQueued(
        bytes32 indexed changeKey,
        uint256 newValue,
        uint256 executeAfter
    );

    /// @dev Emit khi change được execute
    event AdminChangeExecuted(bytes32 indexed changeKey, uint256 newValue);

    /// @dev Emit khi UserInfo được cập nhật (FIX L-5)
    event UserInfoUpdated(
        address indexed user,
        uint256 totalBorrowed,
        uint256 totalLent,
        uint256 activeLoans
    );

    // =========================================================
    // ERRORS — Custom errors (gas < require + string)
    // =========================================================

    error TokenNotWhitelisted(address token);
    error CollateralTokenNotSupported(address token);
    error RequestNotActive(uint256 requestId);
    error NotRequestOwnerOrExpired(uint256 requestId, address caller);
    error RequestExpired(uint256 requestId);
    error InsufficientCollateral(uint256 sent, uint256 required);
    error InsufficientCollateralValue(uint256 valueUSD, uint256 requiredUSD);
    error CollateralPriceStale(address token, uint256 age);
    error CannotFundOwnLoan(uint256 requestId);
    error FeeTooHigh(uint256 fee, uint256 maxFee);
    error InvalidLoanParams(string reason);
    error InsufficientAllowance(address token, uint256 allowance, uint256 required);
    error ZeroAddress();
    error MaxPendingRequestsReached(address borrower, uint256 current, uint256 max);
    error LoanNotFound(uint256 requestId);
    error LoanNotActive(uint256 requestId);
    error NotLiquidatable(uint256 requestId);
    error RepayOnBehalfFailed(uint256 requestId, address payer);
    error OracleUnavailable(address token);
    error InvalidCollateralRatio(uint256 ratio);
    error InvalidLateFeeRate(uint256 rate, uint256 max);
    error UnauthorizedPayer(address payer, address borrower);
    error TimelockNotExpired(bytes32 changeKey, uint256 executeAfter);
    error ChangePendingOrNotQueued(bytes32 changeKey);

    // =========================================================
    // WRITE FUNCTIONS
    // =========================================================

    
    function createLoanRequest(LoanRequest calldata request)
        external
        payable
        returns (uint256 requestId);

    /**
     * @dev Hủy yêu cầu vay + nhận lại collateral (chỉ borrower)
     */
    function cancelLoanRequest(uint256 requestId) external;

    /**
     * @dev Lender cấp vốn cho request
     * @return loanContract Địa chỉ Loan clone contract được deploy
     */
    function fundLoanRequest(uint256 requestId)
        external
        returns (address loanContract);

    function liquidateLoan(uint256 requestId) external;

    function repayLoanOnBehalf(uint256 requestId, address payer) external;

    // =========================================================
    // VIEW FUNCTIONS
    // =========================================================

    function getPendingRequests() external view returns (uint256[] memory);

    function getLoanRequest(uint256 requestId) external view returns (LoanRequest memory);

    function getUserInfo(address user) external view returns (UserInfo memory);

    function getUserLoans(address user)
        external
        view
        returns (address[] memory borrowedLoans, address[] memory lentLoans);

    /// @dev Paginated version tối ưu gas cho user có nhiều loans (FIX H-6)
    function getUserLoansPaginated(
        address user,
        uint256 borrowOffset,
        uint256 borrowLimit,
        uint256 lentOffset,
        uint256 lentLimit
    ) external view returns (
        address[] memory borrowedLoans,
        address[] memory lentLoans,
        uint256 totalBorrowed,
        uint256 totalLent
    );

    function isTokenWhitelisted(address token) external view returns (bool);

    function getPlatformFee() external view returns (uint256);

    function getMinCollateralRatio() external view returns (uint256);

    function getCollateralRatioForBorrower(address borrower)
        external
        view
        returns (uint256 ratio, uint256 creditScore, bool hasScore);

    function getRequestCollateralRatio(uint256 requestId) external view returns (uint256);
}
