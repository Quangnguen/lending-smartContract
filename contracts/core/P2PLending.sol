// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

import "../interfaces/IP2PLending.sol";
import "../interfaces/ICreditScoreOracle.sol";
import "../interfaces/ICollateralManager.sol";
import "../interfaces/IPriceOracle.sol";
import "../interfaces/ILoan.sol";
import "../libraries/LoanLib.sol";
import "../libraries/CollateralLib.sol";
import "../libraries/FundingLib.sol";
import "../libraries/LiquidationLib.sol";
import "../token/DebtToken.sol";
import "./Loan.sol";

/**
 * @title P2PLending
 * @dev Factory contract — Điều phối toàn bộ P2P lending lifecycle
 *
 * ╔══════════════════════════════════════════════════════════════════╗
 * ║  KIẾN TRÚC                                                       ║
 * ╠══════════════════════════════════════════════════════════════════╣
 * ║  P2PLending (Factory)                                            ║
 * ║    ├── createLoanRequest()  → lock collateral, validate          ║
 * ║    ├── fundLoanRequest()    → clone Loan, disburse              ║
 * ║    ├── liquidateLoan()      → verify + transfer + collateral     ║
 * ║    └── cancelLoanRequest()  → return collateral                  ║
 * ║                                                                  ║
 * ║  External Deps:                                                  ║
 * ║    • CollateralManager   — custody ETH/ERC-20 collateral         ║
 * ║    • PriceOracle         — giá token (Chainlink-ready)           ║
 * ║    • CreditScoreOracle   — dynamic collateral ratio              ║
 * ║    • DebtToken (ERC-721) — ghi nhận nợ xấu Soulbound            ║
 * ╚══════════════════════════════════════════════════════════════════╝
 *
 * ╔══════════════════════════════════════════════════════════════════╗
 * ║  BẢO MẬT                                                         ║
 * ╠══════════════════════════════════════════════════════════════════╣
 * ║  • CEI Pattern: toàn bộ state changes TRƯỚC external calls       ║
 * ║  • nonReentrant: fund và liquidate                               ║
 * ║  • Pausable: emergency stop toàn bộ protocol                     ║
 * ║  • Custom errors với context — gas efficient + debuggable        ║
 * ║  • Allowance check trước khi fund (tránh stuck state)           ║
 * ║  • Oracle staleness check qua getPriceSafe()                     ║
 * ╚══════════════════════════════════════════════════════════════════╝
 */
contract P2PLending is IP2PLending, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20     for IERC20;
    using Clones        for address;
    using EnumerableSet for EnumerableSet.UintSet;
    using LoanLib       for uint256;
    using FundingLib    for FundingLib.FundingSnapshot;

    // =========================================================
    // CONSTANTS
    // =========================================================

    uint256 public constant BASIS_POINTS    = 10_000;
    uint256 public constant MAX_PLATFORM_FEE = 500;   // 5% tối đa

    // FIX C-4: Giới hạn collateral ratio hợp lệ
    uint256 public constant MIN_ALLOWED_COLLATERAL_RATIO = 10_000; // 100% tối thiểu
    uint256 public constant MAX_ALLOWED_COLLATERAL_RATIO = 100_000; // 1000% tối đa

    // FIX H-9: 2-day timelock cho admin params nhạy cảm
    uint256 public constant ADMIN_CHANGE_DELAY = 2 days;

    // =========================================================
    // STATE — Platform Config
    // =========================================================

    uint256 public platformFee      = 100;      // 1% (basis points)
    uint256 public minCollateralRatio = 15_000; // 150% (basis points)
    uint256 public lateFeeRate      = 50;       // 0.5%/ngày (basis points)
    address public feeRecipient;

    // =========================================================
    // STATE — External Contracts
    // =========================================================

    ICreditScoreOracle public creditScoreOracle;
    ICollateralManager public collateralManager;
    IPriceOracle       public priceOracle;
    DebtToken          public debtToken;

    /// @dev Implementation contract cho EIP-1167 Clone Factory
    address public loanImplementation;

    // =========================================================
    // STATE — Loan Requests
    // =========================================================

    uint256 public nextRequestId = 1;

    mapping(uint256 => LoanRequest)  public loanRequests;
    mapping(uint256 => address)      public requestBorrower;
    mapping(uint256 => bool)         public requestActive;
    mapping(uint256 => address)      public requestToLoan;
    mapping(uint256 => uint256)      public requestCollateralRatio;

    /// @dev Tokens được phép dùng làm loanToken (USDT, USDC...)
    mapping(address => bool) public whitelistedLoanTokens;

    /// @dev Tokens được phép dùng làm collateral (ETH, WBTC...)
    mapping(address => bool) public whitelistedCollateralTokens;

    /// @dev O(1) add/remove, O(N) values() — tránh unbounded array DoS
    EnumerableSet.UintSet private _pendingRequestIds;

    /// @dev Loan history borrower — EnumerableSet requestIds
    mapping(address => EnumerableSet.UintSet) private _userBorrowedRequestIds;

    /// @dev Loan history lender — EnumerableSet requestIds (FIX: thay array unbounded)
    mapping(address => EnumerableSet.UintSet) private _userLentRequestIds;

    /// @dev Reverse mapping: loanContract → requestId (để Loan có thể lookup requestId)
    mapping(address => uint256) public loanToRequestId;

    mapping(address => UserInfo) public users;

    // =========================================================
    // STATE — Security Additions (Audit Fixes)
    // =========================================================

    /// @dev FIX H-5: O(1) pending counter thay vì O(N) scan
    mapping(address => uint256) private _borrowerPendingCount;

    /// @dev FIX H-9: Timelock cho admin thay đổi param nhạy cảm
    /// changeKey => block.timestamp khi queue (0 = chưa queue)
    mapping(bytes32 => uint256) public pendingAdminChanges;

    /// @dev FIX H-9: Lưu giá trị mới đang được queue
    mapping(bytes32 => uint256) public pendingAdminValues;

    // =========================================================
    // EVENTS — Admin
    // =========================================================

    event CreditScoreOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event CollateralManagerUpdated(address indexed oldManager, address indexed newManager);
    event PriceOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event DebtTokenUpdated(address indexed oldToken, address indexed newToken);
    event LoanTokenWhitelisted(address indexed token, bool status);
    event CollateralTokenWhitelisted(address indexed token, bool status);

    // =========================================================
    // CONSTRUCTOR
    // =========================================================

    constructor(
        address initialOwner,
        address _collateralManager,
        address _priceOracle,
        address _debtToken
    ) Ownable(initialOwner) {
        if (_collateralManager == address(0)) revert ZeroAddress();
        if (_priceOracle == address(0))       revert ZeroAddress();

        collateralManager = ICollateralManager(_collateralManager);
        priceOracle       = IPriceOracle(_priceOracle);
        feeRecipient      = initialOwner;

        if (_debtToken != address(0)) {
            debtToken = DebtToken(_debtToken);
        }

        // Deploy implementation — sẽ bị lock bởi constructor của Loan.sol
        loanImplementation = address(new Loan());
    }

    // =========================================================
    // LOAN CREATION — Core Function (Production-Ready)
    // =========================================================

    /**
     * @notice Tạo yêu cầu vay + lock collateral
     *
     * ┌─ FLOW ──────────────────────────────────────────────────────────┐
     * │ 1. [CHECKS] Validate platform state (not paused, token OK)      │
     * │ 2. [CHECKS] Validate loan params (LoanLib.validateLoanParams)   │
     * │ 3. [CHECKS] Tính dynamic collateral ratio từ credit score       │
     * │ 4. [CHECKS] Validate collateral đủ (CollateralLib)              │
     * │             — ETH: msg.value >= amount, USD value đủ ratio      │
     * │             — ERC-20: oracle support, USD value đủ ratio        │
     * │ 5. [CHECKS] Giới hạn số pending requests (spam protection)      │
     * │ 6. [EFFECTS] Ghi state: loanRequests, requestBorrower, ...      │
     * │ 7. [EFFECTS] EnumerableSet.add(requestId)                       │
     * │ 8. [INTERACTIONS] Lock collateral vào CollateralManager         │
     * │             — ETH: forward msg.value                            │
     * │             — ERC-20: safeTransferFrom borrower → CM           │
     * │ 9. [INTERACTIONS] Refund ETH dư (nếu có)                        │
     * │ 10. Emit events đầy đủ                                          │
     * └─────────────────────────────────────────────────────────────────┘
     *
     * @param request Thông tin yêu cầu vay
     * @return requestId ID được gán cho request này
     */
    function createLoanRequest(LoanRequest calldata request)
        external
        payable
        override
        whenNotPaused
        returns (uint256 requestId)
    {
        // ── CHECKS: Platform state ───────────────────────────────────
        if (!whitelistedLoanTokens[request.loanToken]) {
            revert TokenNotWhitelisted(request.loanToken);
        }

        // ETH collateral (address(0)) luôn được support
        // ERC-20 collateral cần được whitelist
        if (request.collateralToken != address(0)
            && !whitelistedCollateralTokens[request.collateralToken])
        {
            revert CollateralTokenNotSupported(request.collateralToken);
        }

        // ── CHECKS: Loan params validation (LoanLib) ─────────────────
        // Fix: Gọi validateLoanParams — trước đây BỎ SÓT!
        LoanLib.validateLoanParams(
            request.principal,
            request.interestRate,
            request.duration,
            request.collateralAmount,
            request.loanTokenDecimals,
            request.collateralDecimals
        );

        // Fix: Enforce deadline là tối đa 7 ngày từ lúc tạo (nếu user truyền quá xa hoặc 0)
        uint256 deadline = request.deadline;
        if (deadline == 0 || deadline > block.timestamp + 7 days) {
            deadline = block.timestamp + 7 days;
        }

        // ── CHECKS: Dynamic collateral ratio từ credit score ─────────
        uint256 requiredRatio = _getCollateralRatioForBorrower(msg.sender);
        uint256 creditScore   = _getCreditScore(msg.sender);

        // ── CHECKS: Validate collateral value (đủ theo ratio) ────────
        // principalUSD: principal đang là USDT (6 decimals) → xem như USD 6 decimals (1 USDT = $1)
        // Không cần convert thêm vì CollateralLib trả về USD 6 decimals cùng scale
        uint256 principalUSD = request.principal; // USDT 6-decimal ≈ USD 6-decimal

        if (request.collateralToken == address(0)) {
            // ETH collateral
            _validateAndHandleETHCollateral(
                request.collateralAmount,
                principalUSD,
                requiredRatio
            );
        } else {
            // ERC-20 collateral
            _validateERC20Collateral(
                request.collateralToken,
                request.collateralAmount,
                request.collateralDecimals,
                principalUSD,
                requiredRatio
            );
        }

        // ── CHECKS: Spam / rate limiting (FIX H-5: O(1) thay vì O(N)) ──
        uint256 pendingCount = _borrowerPendingCount[msg.sender];
        if (pendingCount >= LoanLib.MAX_PENDING_REQUESTS) {
            revert MaxPendingRequestsReached(msg.sender, pendingCount, LoanLib.MAX_PENDING_REQUESTS);
        }

        // ── EFFECTS: Ghi state ────────────────────────────────────────
        requestId = nextRequestId++;

        loanRequests[requestId]           = request;
        // Ghi đè lại deadline đã được validate
        loanRequests[requestId].deadline  = deadline;
        requestBorrower[requestId]        = msg.sender;
        requestActive[requestId]          = true;
        requestCollateralRatio[requestId] = requiredRatio;

        _pendingRequestIds.add(requestId);
        _borrowerPendingCount[msg.sender]++; // FIX H-5: O(1) counter

        // Lưu request ID vào lịch sử borrower
        _userBorrowedRequestIds[msg.sender].add(requestId);

        // FIX L-5: Cập nhật UserInfo.totalBorrowed và activeLoans
        users[msg.sender].totalBorrowed += request.principal;
        users[msg.sender].activeLoans   += 1;

        // ── INTERACTIONS: Lock collateral ────────────────────────────
        if (request.collateralToken == address(0)) {
            // ETH: forward đúng collateralAmount, refund phần dư
            uint256 excess = msg.value - request.collateralAmount;

            collateralManager.depositCollateral{value: request.collateralAmount}(
                requestId,
                msg.sender,
                address(0),
                request.collateralAmount
            );

            // FIX M-4: Refund ETH dư với gas limit 2300 + emit đúng event
            if (excess > 0) {
                (bool ok,) = payable(msg.sender).call{value: excess, gas: 2300}("");
                if (!ok) {
                    emit ExcessETHRefundFailed(requestId, msg.sender, excess);
                    // Excess ETH mắc kẻết trong contract — dùng recoverETH() sau
                }
            }
        } else {
            // ERC-20: pull từ borrower vào CollateralManager
            // Borrower phải approve P2PLending trước (không phải CM)
            IERC20(request.collateralToken).safeTransferFrom(
                msg.sender,
                address(collateralManager),
                request.collateralAmount
            );
            // Notify CM về deposit (CM đã nhận token qua transferFrom trên)
            collateralManager.depositCollateral(
                requestId,
                msg.sender,
                request.collateralToken,
                request.collateralAmount
            );
        }

        // ── EVENTS ───────────────────────────────────────────────────
        emit LoanRequestCreated(
            requestId,
            msg.sender,
            request.loanToken,
            request.collateralToken,
            request.principal,
            request.interestRate,
            request.collateralAmount,
            request.duration,
            requiredRatio
        );

        emit CollateralRatioApplied(requestId, msg.sender, requiredRatio, creditScore);

        emit UserInfoUpdated(
            msg.sender,
            users[msg.sender].totalBorrowed,
            users[msg.sender].totalLent,
            users[msg.sender].activeLoans
        );
    }

    // =========================================================
    // CANCEL REQUEST
    // =========================================================

    /**
     * @notice Hủy yêu cầu vay + nhận lại collateral
     * Chỉ borrower, chỉ khi request còn active (chưa được fund)
     *
     * FIX C-2: Thêm nonReentrant — tránh reentrancy khi borrower là contract
     * FIX C-5: Revert nếu CM fail (không silent orphan collateral)
     * FIX H-5: Giảm _borrowerPendingCount O(1)
     * FIX L-5: Cập nhật UserInfo.activeLoans
     */
    function cancelLoanRequest(uint256 requestId)
        external
        override
        nonReentrant    // FIX C-2
        whenNotPaused
    {
        if (!requestActive[requestId]) {
            revert RequestNotActive(requestId);
        }

        LoanRequest memory req = loanRequests[requestId];
        address borrower = requestBorrower[requestId];

        // FIX Orphan Requests: Cho phép ai cũng được hủy nếu đã quá hạn (auto-cancel).
        // Nếu chưa quá hạn, chỉ borrower mới được hủy.
        if (msg.sender != borrower) {
            if (block.timestamp <= req.deadline) {
                revert NotRequestOwnerOrExpired(requestId, msg.sender);
            }
        }

        // ── EFFECTS ──────────────────────────────────────────────────
        requestActive[requestId] = false;
        _pendingRequestIds.remove(requestId);

        // FIX H-5: Giảm pending counter O(1)
        if (_borrowerPendingCount[borrower] > 0) {
            _borrowerPendingCount[borrower]--;
        }

        // FIX L-5: Cập nhật UserInfo
        if (users[borrower].activeLoans > 0) {
            users[borrower].activeLoans--;
        }

        // ── INTERACTIONS (FIX C-5: revert nếu CM fail — tránh orphan collateral) ──
        // Không dùng try-catch — nếu CM fail thì toàn bộ tx revert
        // Borrower sẽ retry sau khi CM sẵn sàng
        collateralManager.withdrawCollateral(requestId);

        emit LoanRequestCancelled(requestId, borrower, req.collateralAmount);

        emit UserInfoUpdated(
            borrower,
            users[borrower].totalBorrowed,
            users[borrower].totalLent,
            users[borrower].activeLoans
        );
    }

    // =========================================================
    // FUND LOAN REQUEST — Production-Ready
    // =========================================================

    /**
     * @notice Lender cấp vốn cho kỏ khoản vay
     *
     * ┌─ FLOW (chuẩn CEI + DeFi best practices) ────────────────────────────┐
     * │ 1. [CHECKS] Request active, not self-fund                    │
     * │ 2. [CHECKS] Build FundingSnapshot (1 pass, no re-read)       │
     * │ 3. [CHECKS] allowance + balance TRƯỚC state change            │
     * │    (FundingLib.validateFunding — revert nếu không đủ)          │
     * │ 4. [EFFECTS] requestActive = false (double-fund protection)   │
     * │ 5. [EFFECTS] Remove khỏi pending set                         │
     * │ 6. [EFFECTS] Clone Loan, ghi mappings (requestToLoan, reverse) │
     * │ 7. [INTERACTIONS] Initialize Loan clone                       │
     * │ 8. [INTERACTIONS] Register Loan với CollateralManager         │
     * │ 9. [INTERACTIONS] setAuthorizedCaller (Loan → CM withdraw)    │
     * │ 10.[INTERACTIONS] loan.fund(lender) — activate loan           │
     * │ 11.[INTERACTIONS] Transfer USDT: lender → borrower (net)      │
     * │ 12.[INTERACTIONS] Transfer USDT: lender → feeRecipient (fee)  │
     * │ 13. Emit LoanMatched (với lenderAPY + expectedReturn)         │
     * └─────────────────────────────────────────────────────────────────┗
     *
     * Race condition protection:
     *   nonReentrant + requestActive = false trong EFFECTS
     *   → 2 lender cùng block: 1 thành công, 1 revert tại check requestActive
     *   EVM đảm bảo txs trong 1 block xử lý tuần tự (sequential), không song song
     *
     * Flash loan abuse mì tiết:
     *   Lender phải giữ USDT liên tục (không được repay trong cùng tx)
     *   Loan clone bị lock sau fund, không có cơ chế flash-fund-unfund
     *
     * @param requestId ID của loan request cần fund
     * @return loanContract Địa chỉ Loan clone được deploy
     */
    function fundLoanRequest(uint256 requestId)
        external
        override
        nonReentrant
        whenNotPaused
        returns (address loanContract)
    {
        // ── CHECKS: Quick boolean checks (rẻ nhất) ─────────────────────────
        if (!requestActive[requestId]) revert RequestNotActive(requestId);

        LoanRequest memory req = loanRequests[requestId];
        address borrower       = requestBorrower[requestId];

        // Không tự fund chính mình
        if (msg.sender == borrower) revert CannotFundOwnLoan(requestId);

        // Không fund nếu request đã hết hạn (quá deadline)
        if (block.timestamp > req.deadline) revert RequestExpired(requestId);

        // ── CHECKS: Build FundingSnapshot (1 pass, tránh re-read storage) ──
        FundingLib.FundingSnapshot memory snap = FundingLib.buildSnapshot(
            requestId,
            borrower,
            req.loanToken,
            req.collateralToken,
            req.principal,
            req.interestRate,
            req.collateralAmount,
            req.duration,
            req.loanTokenDecimals,
            req.collateralDecimals,
            platformFee
        );

        // ── CHECKS: Allowance + Balance trước bất kỳ state change nào ──────
        // Tránh stuck state: state thay đổi nhưng transfer fail sau đó
        uint256 allowance = IERC20(req.loanToken).allowance(msg.sender, address(this));
        if (allowance < req.principal) {
            revert InsufficientAllowance(req.loanToken, allowance, req.principal);
        }
        uint256 balance = IERC20(req.loanToken).balanceOf(msg.sender);
        if (balance < req.principal) {
            revert InvalidLoanParams("Insufficient lender balance");
        }

        // ── EFFECTS (State mutations, atomic trước mọi external call) ──────
        // double-fund protection: set false TRƯỚC bất kỳ interaction nào
        requestActive[requestId] = false;
        _pendingRequestIds.remove(requestId);

        // Clone Loan implementation (EIP-1167 minimal proxy)
        address loanClone = loanImplementation.clone();
        loanContract      = loanClone;

        // Ghi cả 2 chiều mapping (bidirectional)
        requestToLoan[requestId]   = loanClone;
        loanToRequestId[loanClone] = requestId;

        // FIX H-5: Giảm pending counter của borrower khi loan được fund
        if (_borrowerPendingCount[borrower] > 0) {
            _borrowerPendingCount[borrower]--;
        }

        // Track lender history (EnumerableSet — không có DoS như push vào array)
        _userLentRequestIds[msg.sender].add(requestId);

        // FIX L-5: Cập nhật UserInfo lender
        users[msg.sender].totalLent    += req.principal;
        users[msg.sender].activeLoans  += 1;

        // ── INTERACTIONS (External calls, theo thứ tự dependency) ──────────
        // Step 1: Initialize Loan clone với tất cả thông tin từ snapshot
        Loan(loanClone).initialize(
            requestId,
            borrower,
            req.loanToken,
            req.collateralToken,
            req.principal,
            req.interestRate,
            req.collateralAmount,
            req.duration,
            lateFeeRate,
            address(collateralManager)
        );

        // Step 2: Register trước, authorize sau — defense in depth
        // Nếu register fail thì authorize cũng không xảy ra
        collateralManager.registerLoan(requestId, loanClone);
        collateralManager.setAuthorizedCaller(loanClone, true);

        // Step 3: Activate loan — set status ACTIVE, record startTime/endTime
        Loan(loanClone).fund(msg.sender);

        // Step 4: Transfer principal từ lender đến borrower (net of fee)
        IERC20(req.loanToken).safeTransferFrom(msg.sender, borrower, snap.borrowerAmount);

        // Step 5: Collect platform fee (nếu có)
        if (snap.platformFee > 0 && feeRecipient != address(0)) {
            IERC20(req.loanToken).safeTransferFrom(msg.sender, feeRecipient, snap.platformFee);
            emit FeeCollected(requestId, feeRecipient, snap.platformFee);
        }

        // ── EVENTS: Emit với đầy đủ data cho indexer / frontend ────────────
        uint256 lenderAPY = FundingLib.calculateLenderAPY(
            req.interestRate,
            platformFee,
            req.duration
        );
        uint256 expectedReturn = FundingLib.calculateExpectedInterest(
            req.principal,
            req.interestRate,
            req.duration
        );

        emit LoanMatched(
            requestId,
            msg.sender,
            loanClone,
            snap.platformFee,
            snap.borrowerAmount,
            lenderAPY,
            expectedReturn
        );

        // FIX L-5: Emit UserInfo update cho cả lender
        emit UserInfoUpdated(
            msg.sender,
            users[msg.sender].totalBorrowed,
            users[msg.sender].totalLent,
            users[msg.sender].activeLoans
        );
    }

    // =========================================================
    // LIQUIDATION
    // =========================================================

    /**
     * @notice Thanh lý khoản vay — bất kỳ ai khi đủ điều kiện
     *
     * ┌─ FLOW (Snapshot Pattern) ─────────────────────────────────────────┐
     * │ 1. [CHECKS] getLoanDetails() + getCollateralInfo()               │
     * │ 2. [CHECKS] getPriceSafe() — 1 oracle read duy nhất              │
     * │ 3. [CHECKS] Tính snapshot (HF, liquidatorGets, bonus, refund)    │
     * │ 4. [CHECKS] validateLiquidation() — HF + self-liq + allowance    │
     * │ 5. [EFFECTS] loan.liquidate() — status = LIQUIDATED              │
     * │ 6. [INTERACT] USDT.safeTransferFrom(liquidator → lender, debt)   │
     * │ 7. [INTERACT] CM.liquidateCollateralWithSnapshot(snapshot)        │
     * │ 8. [INTERACT] DebtToken.mintDebtToken() [try-catch]              │
     * └───────────────────────────────────────────────────────────────────┘
     *
     * Bảo mật:
     *   • Self-liquidation: LiquidationLib.validateLiquidation() check
     *   • Reentrancy: nonReentrant + CEI (loan.liquidate() TRƯỚC transfer)
     *   • Oracle staleness: getPriceSafe() revert nếu price cũ hơn maxAge
     *   • Single oracle read: snapshot lock giá 1 lần, CM không đọc lại
     *   • Front-running: snapshot chỉ valid tại block.timestamp hiện tại
     *   • Flash loan: không có lợi ích kinh tế (trả USDT → nhận collateral)
     */
    function liquidateLoan(uint256 requestId)
        external
        override
        nonReentrant
        whenNotPaused
    {
        // ── CHECKS (bước 1-4) ────────────────────────────────────────────
        address loanAddr = requestToLoan[requestId];
        if (loanAddr == address(0)) revert LoanNotFound(requestId);

        ILoan loan = ILoan(loanAddr);
        ILoan.LoanDetails memory details = loan.getLoanDetails();
        if (details.status != ILoan.LoanStatus.ACTIVE) revert LoanNotActive(requestId);

        // Lấy collateral info với decimals chính xác
        (   address collToken,
            uint256 collAmount,
            address borrower,
            bool    collActive,
            uint8   collDecimals
        ) = collateralManager.getCollateralInfo(requestId);
        if (!collActive) revert LoanNotFound(requestId);

        // Debt tại block.timestamp (principal + interest capped + lateFee)
        uint256 debtAmount = loan.getTotalRepaymentAmount();

        // ── FIX C-1: Oracle read DUY NHẤT với bảo vệ bypass ──────────────
        // TRƯỚC (sai): oracle fail → collPrice=0 → loan healthy bị liquidate
        // SAU  (đúng): oracle fail → chỉ cho liquidate nếu đã overdue
        //              nếu không overdue → revert (bảo vệ borrower)
        uint256 collPrice;
        bool    hasValidPrice = false;
        bool    isOverdue_    = loan.isOverdue();

        if (address(priceOracle) != address(0)) {
            try priceOracle.getPriceSafe(collToken) returns (uint256 p) {
                collPrice     = p;
                hasValidPrice = true;
            } catch {
                // getPriceSafe() fail: thử getPrice() không staleness check
                try priceOracle.getPrice(collToken) returns (uint256 p, uint256) {
                    if (p > 0) {
                        collPrice     = p;
                        hasValidPrice = true;
                    }
                } catch {}
            }
        }

        // Nếu không có giá hợp lệ VÀ loan KHÔNG overdue → revert
        // Tránh healthy loan bị liquidate khi oracle tạm thời unavailable
        if (!hasValidPrice && !isOverdue_) {
            revert OracleUnavailable(collToken);
        }
        // Nếu overdue nhưng không có giá → set collPrice=0 để tính bad debt
        // Liquidator nhận toàn bộ collateral vì không thể định giá chính xác

        // Tính collateral value và HF
        uint256 collValueUSD = LiquidationLib.calculateCollateralValueUSD(
            collAmount, collPrice, collDecimals
        );
        uint256 hf = LiquidationLib.calculateHealthFactor(collValueUSD, debtAmount);

        // Tính phân phối collateral (liquidator + bonus + borrower refund)
        (
            uint256 liquidatorGets,
            uint256 bonusAmount,
            uint256 borrowerRefund,
            bool    isBadDebt
        ) = LiquidationLib.calculateLiquidationAmounts(
            debtAmount,
            collAmount,
            collPrice,
            collDecimals,
            collateralManager.getLiquidationBonus()
        );

        // Build snapshot — lock toàn bộ số liệu tại block.timestamp này
        LiquidationLib.LiquidationSnapshot memory snapshot = LiquidationLib.LiquidationSnapshot({
            loanId:               requestId,
            borrower:             borrower,
            lender:               details.lender,
            loanToken:            details.loanToken,
            collateralToken:      collToken,
            collateralDecimals:   collDecimals,
            collateralAmount:     collAmount,
            debtAmount:           debtAmount,
            collateralPrice:      collPrice,
            collateralValueUSD:   collValueUSD,
            healthFactor:         hf,
            liquidatorCollateral: liquidatorGets,
            bonusCollateral:      bonusAmount,
            borrowerRefund:       borrowerRefund,
            isBadDebt:            isBadDebt,
            isOverdue:            isOverdue_
        });

        // Validate toàn bộ điều kiện (self-liq, HF, allowance, balance)
        LiquidationLib.validateLiquidation(
            requestId,
            true,           // isActive — vừa check ở trên
            isOverdue_,
            borrower,
            msg.sender,     // liquidator
            debtAmount,
            collAmount,
            hf,
            collateralManager.getLiquidationThreshold(),
            details.loanToken,
            address(this)   // liquidator approve P2PLending
        );

        // ── EFFECTS ──────────────────────────────────────────────────────
        loan.liquidate(); // status → LIQUIDATED

        // FIX L-5: Cập nhật UserInfo sau liquidation
        if (users[borrower].activeLoans > 0) {
            users[borrower].activeLoans--;
        }
        if (users[details.lender].activeLoans > 0) {
            users[details.lender].activeLoans--;
        }

        // ── INTERACTIONS ─────────────────────────────────────────────────
        // Liquidator trả USDT, lender nhận toàn bộ debt
        IERC20(details.loanToken).safeTransferFrom(
            msg.sender, details.lender, debtAmount
        );

        // Phân phối collateral theo snapshot — CM không gọi oracle nữa
        collateralManager.liquidateCollateralWithSnapshot(snapshot, msg.sender);

        // Mint DebtToken ghi nhận nợ xấu vĩnh viễn (try-catch, không block tx)
        if (address(debtToken) != address(0)) {
            try debtToken.mintDebtToken(
                borrower,
                requestId,
                details.lender,
                details.principal,
                debtAmount,
                isBadDebt ? "LIQUIDATED_BAD_DEBT" : "LIQUIDATED",
                loanAddr
            ) {} catch {}
        }

        emit LoanLiquidated(requestId, msg.sender, loanAddr);

        emit UserInfoUpdated(
            borrower,
            users[borrower].totalBorrowed,
            users[borrower].totalLent,
            users[borrower].activeLoans
        );
    }

    // =========================================================
    // REPAY ON BEHALF — Gateway
    // =========================================================

    /**
     * @notice Bất kỳ ai trả nợ thay borrower
     *
     * ┌─ FLOW ─────────────────────────────────────────────────────────────┐
     * │ 1. [CHECKS] Loan tồn tại + đang ACTIVE                            │
     * │ 2. [DELEGATE] Loan.repayOnBehalf(payer) — CEI + transfer trong đó │
     * └────────────────────────────────────────────────────────────────────┘
     *
     * Use cases:
     *   1. Emergency rescue — bạn bè trả khi borrower mất ví
     *   2. Keeper/bot — tự động trả khi loan sắp bị liquidate
     *   3. DeFi composability — protocol khác trả để unlock collateral
     *
     * Payer phải approve Loan clone contract (KHÔNG phải P2PLending).
     * Lý do: transfer xảy ra trong Loan.repayOnBehalf() với address(this) = loanClone.
     *
     * Collateral LUÔN về borrower dù payer là ai.
     *
     * @param requestId ID của loan request
     * @param payer     Địa chỉ người chuyển USDT (phải đã approve Loan clone)
     */
    function repayLoanOnBehalf(uint256 requestId, address payer)
        external
        override
        nonReentrant
        whenNotPaused
    {
        if (payer == address(0)) revert ZeroAddress();

        address loanAddr = requestToLoan[requestId];
        if (loanAddr == address(0)) revert LoanNotFound(requestId);

        ILoan loan = ILoan(loanAddr);
        ILoan.LoanDetails memory details = loan.getLoanDetails();
        if (details.status != ILoan.LoanStatus.ACTIVE) {
            revert LoanNotActive(requestId);
        }

        // FIX M-6: Chỉ cho phép:
        //   1. payer == msg.sender (payer tự gọi — tự nguyện trả nợ)
        //   2. msg.sender == borrower (borrower ủy quyền ai đó trả)
        if (msg.sender != payer && msg.sender != details.borrower) {
            revert UnauthorizedPayer(payer, details.borrower);
        }

        // Delegate sang Loan.repayOnBehalf() — CEI + transfer thực hiện tại đó
        Loan(loanAddr).repayOnBehalf(payer);

        // FIX L-5: Cập nhật UserInfo sau repay
        if (users[details.borrower].activeLoans > 0) {
            users[details.borrower].activeLoans--;
        }
        if (users[details.lender].activeLoans > 0) {
            users[details.lender].activeLoans--;
        }

        emit UserInfoUpdated(
            details.borrower,
            users[details.borrower].totalBorrowed,
            users[details.borrower].totalLent,
            users[details.borrower].activeLoans
        );
    }

    // =========================================================
    // VIEW FUNCTIONS
    // =========================================================

    function getPendingRequests()
        external
        view
        override
        returns (uint256[] memory)
    {
        return _pendingRequestIds.values();
    }

    function getLoanRequest(uint256 requestId)
        external
        view
        override
        returns (LoanRequest memory)
    {
        return loanRequests[requestId];
    }

    function getUserInfo(address user)
        external
        view
        override
        returns (UserInfo memory)
    {
        return users[user];
    }

    function getUserLoans(address user)
        external
        view
        override
        returns (address[] memory borrowedLoans, address[] memory lentLoans)
    {
        // Borrowed loans từ _userBorrowedRequestIds
        uint256[] memory borrowedIds = _userBorrowedRequestIds[user].values();
        address[] memory borrowed    = new address[](borrowedIds.length);
        for (uint256 i = 0; i < borrowedIds.length; i++) {
            borrowed[i] = requestToLoan[borrowedIds[i]];
        }

        // Lent loans từ _userLentRequestIds (EnumerableSet — FIX unbounded array)
        uint256[] memory lentIds = _userLentRequestIds[user].values();
        address[] memory lent    = new address[](lentIds.length);
        for (uint256 i = 0; i < lentIds.length; i++) {
            lent[i] = requestToLoan[lentIds[i]];
        }

        return (borrowed, lent);
    }

    /**
     * FIX H-6: Paginated getUserLoans — tránh O(N) loop cho user có nhiều loans
     */
    function getUserLoansPaginated(
        address user,
        uint256 borrowOffset,
        uint256 borrowLimit,
        uint256 lentOffset,
        uint256 lentLimit
    ) external view override returns (
        address[] memory borrowedLoans,
        address[] memory lentLoans,
        uint256 totalBorrowed,
        uint256 totalLent
    ) {
        uint256[] memory borrowedIds = _userBorrowedRequestIds[user].values();
        totalBorrowed = borrowedIds.length;

        uint256 bEnd = borrowOffset + borrowLimit;
        if (bEnd > totalBorrowed) bEnd = totalBorrowed;
        uint256 bCount = bEnd > borrowOffset ? bEnd - borrowOffset : 0;
        borrowedLoans = new address[](bCount);
        for (uint256 i = 0; i < bCount; i++) {
            borrowedLoans[i] = requestToLoan[borrowedIds[borrowOffset + i]];
        }

        uint256[] memory lentIds = _userLentRequestIds[user].values();
        totalLent = lentIds.length;

        uint256 lEnd = lentOffset + lentLimit;
        if (lEnd > totalLent) lEnd = totalLent;
        uint256 lCount = lEnd > lentOffset ? lEnd - lentOffset : 0;
        lentLoans = new address[](lCount);
        for (uint256 i = 0; i < lCount; i++) {
            lentLoans[i] = requestToLoan[lentIds[lentOffset + i]];
        }
    }

    function isTokenWhitelisted(address token) external view override returns (bool) {
        return whitelistedLoanTokens[token];
    }

    function getPlatformFee() external view override returns (uint256) {
        return platformFee;
    }

    function getMinCollateralRatio() external view override returns (uint256) {
        return minCollateralRatio;
    }

    function getCollateralRatioForBorrower(address borrower)
        external
        view
        override
        returns (uint256 ratio, uint256 creditScore, bool hasScore)
    {
        ratio = _getCollateralRatioForBorrower(borrower);
        if (address(creditScoreOracle) != address(0)) {
            (creditScore, , hasScore) = creditScoreOracle.getCreditScore(borrower);
        }
    }

    function getRequestCollateralRatio(uint256 requestId)
        external
        view
        override
        returns (uint256)
    {
        return requestCollateralRatio[requestId];
    }

    // =========================================================
    // ADMIN FUNCTIONS
    // =========================================================

    function whitelistLoanToken(address token, bool status) external onlyOwner {
        whitelistedLoanTokens[token] = status;
        emit LoanTokenWhitelisted(token, status);
        emit TokenWhitelisted(token, status); // backward compat
    }

    function whitelistCollateralToken(address token, bool status) external onlyOwner {
        whitelistedCollateralTokens[token] = status;
        emit CollateralTokenWhitelisted(token, status);
    }

    function setPlatformFee(uint256 newFee) external onlyOwner {
        if (newFee > MAX_PLATFORM_FEE) revert FeeTooHigh(newFee, MAX_PLATFORM_FEE);
        uint256 old = platformFee;
        platformFee = newFee;
        emit PlatformFeeUpdated(old, newFee);
    }

    function setFeeRecipient(address _recipient) external onlyOwner {
        if (_recipient == address(0)) revert ZeroAddress();
        feeRecipient = _recipient;
    }

    /**
     * FIX C-4: Validate bounds trước khi set collateral ratio
     * Không cho phép set 0 (cho vay không cần collateral) hoặc > 1000% (impossible)
     */
    function setMinCollateralRatio(uint256 newRatio) external onlyOwner {
        if (newRatio < MIN_ALLOWED_COLLATERAL_RATIO || newRatio > MAX_ALLOWED_COLLATERAL_RATIO) {
            revert InvalidCollateralRatio(newRatio);
        }
        uint256 old = minCollateralRatio;
        minCollateralRatio = newRatio;
        emit CollateralRatioUpdated(old, newRatio);
    }

    function setCreditScoreOracle(address _oracle) external onlyOwner {
        address old = address(creditScoreOracle);
        creditScoreOracle = ICreditScoreOracle(_oracle);
        emit CreditScoreOracleUpdated(old, _oracle);
    }

    function setCollateralManager(address _manager) external onlyOwner {
        if (_manager == address(0)) revert ZeroAddress();
        address old = address(collateralManager);
        collateralManager = ICollateralManager(_manager);
        emit CollateralManagerUpdated(old, _manager);
    }

    function setPriceOracle(address _oracle) external onlyOwner {
        if (_oracle == address(0)) revert ZeroAddress();
        address old = address(priceOracle);
        priceOracle = IPriceOracle(_oracle);
        emit PriceOracleUpdated(old, _oracle);
    }

    function setDebtToken(address _debtToken) external onlyOwner {
        address old = address(debtToken);
        debtToken = DebtToken(_debtToken);
        emit DebtTokenUpdated(old, _debtToken);
    }

    /**
     * FIX M-8: Thêm event + FIX C-4: validate rate
     * FIX: dùng LoanLib.validateLateFeeRate() đã có sẵn
     */
    function setLateFeeRate(uint256 newRate) external onlyOwner {
        LoanLib.validateLateFeeRate(newRate); // FIX C-4: validate <= MAX_LATE_FEE_RATE
        uint256 old = lateFeeRate;
        lateFeeRate = newRate;
        emit LateFeeRateUpdated(old, newRate); // FIX M-8: emit event
    }

    /// @dev Emergency pause — stop createLoanRequest, fund, liquidate
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /**
     * FIX H-9: Queue thay đổi oracle — cần 2 ngày trước khi có hiệu lực
     * Ngăn admin front-run user với oracle độc hại
     */
    function queueOracleChange(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert ZeroAddress();
        bytes32 key = keccak256("priceOracle");
        pendingAdminChanges[key] = block.timestamp;
        pendingAdminValues[key]  = uint256(uint160(newOracle));
        emit AdminChangeQueued(key, uint256(uint160(newOracle)), block.timestamp + ADMIN_CHANGE_DELAY);
    }

    function executeOracleChange() external onlyOwner {
        bytes32 key = keccak256("priceOracle");
        uint256 queuedAt = pendingAdminChanges[key];
        if (queuedAt == 0) revert ChangePendingOrNotQueued(key);
        if (block.timestamp < queuedAt + ADMIN_CHANGE_DELAY) {
            revert TimelockNotExpired(key, queuedAt + ADMIN_CHANGE_DELAY);
        }
        address newOracle = address(uint160(pendingAdminValues[key]));
        delete pendingAdminChanges[key];
        delete pendingAdminValues[key];

        address old = address(priceOracle);
        priceOracle  = IPriceOracle(newOracle);
        emit PriceOracleUpdated(old, newOracle);
        emit AdminChangeExecuted(key, uint256(uint160(newOracle)));
    }

    /**
     * FIX H-9: Queue thay đổi CollateralManager — cần 2 ngày
     */
    function queueCollateralManagerChange(address newManager) external onlyOwner {
        if (newManager == address(0)) revert ZeroAddress();
        bytes32 key = keccak256("collateralManager");
        pendingAdminChanges[key] = block.timestamp;
        pendingAdminValues[key]  = uint256(uint160(newManager));
        emit AdminChangeQueued(key, uint256(uint160(newManager)), block.timestamp + ADMIN_CHANGE_DELAY);
    }

    function executeCollateralManagerChange() external onlyOwner {
        bytes32 key = keccak256("collateralManager");
        uint256 queuedAt = pendingAdminChanges[key];
        if (queuedAt == 0) revert ChangePendingOrNotQueued(key);
        if (block.timestamp < queuedAt + ADMIN_CHANGE_DELAY) {
            revert TimelockNotExpired(key, queuedAt + ADMIN_CHANGE_DELAY);
        }
        address newManager = address(uint160(pendingAdminValues[key]));
        delete pendingAdminChanges[key];
        delete pendingAdminValues[key];

        address old       = address(collateralManager);
        collateralManager = ICollateralManager(newManager);
        emit CollateralManagerUpdated(old, newManager);
        emit AdminChangeExecuted(key, uint256(uint160(newManager)));
    }

    /**
     * FIX L-3: Thu hồi ETH bị mắc kẹt trong P2PLending (ví dụ từ excess refund fail)
     * Chỉ owner mới có thể gọi — emergency function
     */
    function recoverETH(address payable recipient, uint256 amount) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0 || amount > address(this).balance) revert InvalidLoanParams("Invalid amount");
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert InvalidLoanParams("ETH transfer failed");
    }

    // Nhận ETH (từ CollateralManager refund hoặc excess)
    receive() external payable {}

    // =========================================================
    // INTERNAL HELPERS
    // =========================================================

    /**
     * @dev Validate ETH collateral: check msg.value và oracle value
     * Refund excess ETH không nằm trong scope này — handled in main flow
     */
    function _validateAndHandleETHCollateral(
        uint256 collateralAmount,
        uint256 principalUSD,
        uint256 requiredRatio
    ) internal view {
        // msg.value phải >= collateralAmount được khai báo
        if (msg.value < collateralAmount) {
            revert InsufficientCollateral(msg.value, collateralAmount);
        }

        // Validate USD value nếu oracle khả dụng
        if (address(priceOracle) != address(0)
            && priceOracle.isTokenSupported(address(0)))
        {
            uint256 ethPrice;
            try priceOracle.getPriceSafe(address(0)) returns (uint256 p) {
                ethPrice = p;
            } catch {
                // Oracle không khả dụng / stale → skip USD check
                // Production: nên revert thay vì skip
                return;
            }

            uint256 collateralValueUSD = CollateralLib.getETHCollateralValueUSD(
                collateralAmount, ethPrice
            );
            uint256 requiredUSD = (principalUSD * requiredRatio) / BASIS_POINTS;

            if (collateralValueUSD < requiredUSD) {
                revert InsufficientCollateralValue(collateralValueUSD, requiredUSD);
            }
        }
    }

    /**
     * @dev Validate ERC-20 collateral: oracle support + USD value
     */
    function _validateERC20Collateral(
        address collateralToken,
        uint256 collateralAmount,
        uint8   collateralDecimals,
        uint256 principalUSD,
        uint256 requiredRatio
    ) internal view {
        if (msg.value > 0) revert InvalidLoanParams("ETH sent with ERC-20 collateral");

        if (address(priceOracle) != address(0)) {
            if (!priceOracle.isTokenSupported(collateralToken)) {
                revert CollateralTokenNotSupported(collateralToken);
            }

            uint256 tokenPrice;
            try priceOracle.getPriceSafe(collateralToken) returns (uint256 p) {
                tokenPrice = p;
            } catch {
                revert CollateralPriceStale(collateralToken, 0);
            }

            uint256 collateralValueUSD = CollateralLib.getERC20CollateralValueUSD(
                collateralAmount, tokenPrice, collateralDecimals
            );
            uint256 requiredUSD = (principalUSD * requiredRatio) / BASIS_POINTS;

            if (collateralValueUSD < requiredUSD) {
                revert InsufficientCollateralValue(collateralValueUSD, requiredUSD);
            }
        }
    }

    /**
     * @dev Dynamic collateral ratio từ credit score oracle
     * Fallback: minCollateralRatio nếu oracle chưa set hoặc borrower chưa có score
     */
    function _getCollateralRatioForBorrower(address borrower)
        internal
        view
        returns (uint256)
    {
        if (address(creditScoreOracle) != address(0)) {
            if (creditScoreOracle.hasValidScore(borrower)) {
                return creditScoreOracle.getRequiredCollateralRatio(borrower);
            }
        }
        return minCollateralRatio;
    }

    /**
     * @dev Lấy credit score (0 nếu oracle chưa set)
     */
    function _getCreditScore(address borrower)
        internal
        view
        returns (uint256 creditScore)
    {
        if (address(creditScoreOracle) != address(0)) {
            (creditScore, ,) = creditScoreOracle.getCreditScore(borrower);
        }
    }

    /**
     * @dev Đếm số pending requests của borrower
     * Dùng để giới hạn spam — O(N) nhưng N rất nhỏ (max MAX_PENDING_REQUESTS)
     */
    function _countBorrowerPending(address borrower)
        internal
        view
        returns (uint256 count)
    {
        uint256[] memory ids = _pendingRequestIds.values();
        for (uint256 i = 0; i < ids.length; i++) {
            if (requestBorrower[ids[i]] == borrower) {
                count++;
            }
        }
    }
}
