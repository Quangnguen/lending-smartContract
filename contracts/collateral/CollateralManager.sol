// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/ICollateralManager.sol";
import "../interfaces/IPriceOracle.sol";
import "../interfaces/ILoan.sol";
import "../libraries/LiquidationLib.sol";


contract CollateralManager is ICollateralManager, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using LiquidationLib for uint256;

    // =========================================================
    // CONSTANTS
    // =========================================================

    uint256 public constant BASIS_POINTS                 = 10_000;
    uint256 public constant DEFAULT_LIQUIDATION_THRESHOLD = 11_000; // 110%
    uint256 public constant DEFAULT_LIQUIDATION_BONUS    = 500;     // 5%
    address public constant ETH_ADDRESS                  = address(0);

    // =========================================================
    // STATE
    // =========================================================

    IPriceOracle public priceOracle;
    uint256 public liquidationThreshold;
    uint256 public liquidationBonus;

    /// @dev Tổng bad debt tích lũy (USD, 6 dec) — dùng cho reserve fund tracking
    uint256 public override totalBadDebt;

    struct CollateralInfo {
        address token;
        uint256 amount;
        address borrower;
        bool    isActive;
        uint8   decimals;   // Token decimals — PHẢI chính xác (không default)
    }

    mapping(uint256 => CollateralInfo) public collaterals;

    /// @dev Loan contracts được phép gọi withdrawCollateral()
    mapping(address => bool) public authorizedCallers;

    /// @dev loanId → Loan contract address (set khi fund, không thể overwrite)
    mapping(uint256 => address) private _loanRegistry;

    
    error CM__InvalidAmount();
    error CM__CollateralNotActive(uint256 loanId);
    error CM__Unauthorized(address caller);
    error CM__TransferFailed(address token, address recipient, uint256 amount);
    error CM__LoanAlreadyRegistered(uint256 loanId, address existing);
    error CM__InvalidLoanContract();
    error CM__InvalidThreshold(uint256 threshold);
    error CM__InvalidBonus(uint256 bonus);
    error CM__NotLiquidatable(uint256 loanId);
    error CM__PriceOracleRequired();
    error CM__SnapshotLoanIdMismatch(uint256 snapshotLoanId, uint256 loanId);
    error CM__InvalidDecimals(uint8 decimals);
    error CM__DirectETHNotAllowed(); // FIX L-2: chặn ETH gửi trực tiếp
    error CM__BalanceNotIncreased(uint256 loanId); // FIX C-6: verify balance increase

    // =========================================================
    // CONSTRUCTOR
    // =========================================================

    constructor(address _priceOracle, address initialOwner) Ownable(initialOwner) {
        priceOracle          = IPriceOracle(_priceOracle);
        liquidationThreshold = DEFAULT_LIQUIDATION_THRESHOLD;
        liquidationBonus     = DEFAULT_LIQUIDATION_BONUS;
    }

    // =========================================================
    // DEPOSIT
    // =========================================================

    
    function depositCollateral(
        uint256 loanId,
        address borrower,
        address token,
        uint256 amount
    ) external payable override nonReentrant {
        // FIX C-3: Restrict to owner or authorized callers
        if (msg.sender != owner() && !authorizedCallers[msg.sender]) {
            revert CM__Unauthorized(msg.sender);
        }
        // Fallback decimals — P2PLending nên gọi depositCollateralWithDecimals() để chính xác
        uint8 dec = (token == ETH_ADDRESS) ? 18 : 6;
        _depositCollateral(loanId, borrower, token, amount, dec);
    }

    
    function depositCollateralWithDecimals(
        uint256 loanId,
        address borrower,
        address token,
        uint256 amount,
        uint8   decimals_
    ) external payable nonReentrant {
        // FIX H-8: Cho phép cả owner và authorized callers (P2PLending là owner của CM)
        if (msg.sender != owner() && !authorizedCallers[msg.sender]) {
            revert CM__Unauthorized(msg.sender);
        }
        if (decimals_ > 18) revert CM__InvalidDecimals(decimals_);
        _depositCollateral(loanId, borrower, token, amount, decimals_);
    }

    function _depositCollateral(
        uint256 loanId,
        address borrower,
        address token,
        uint256 amount,
        uint8   decimals_
    ) internal {
        uint256 depositAmount;

        if (token == ETH_ADDRESS) {
            if (msg.value == 0) revert CM__InvalidAmount();
            depositAmount = msg.value;
        } else {
            if (amount == 0) revert CM__InvalidAmount();
            depositAmount = amount;
        }

        CollateralInfo storage info = collaterals[loanId];
        if (info.isActive) {
            // Top-up deposit
            if (info.borrower != borrower) revert CM__Unauthorized(msg.sender);
            if (info.token != token)       revert CM__InvalidAmount();
            info.amount += depositAmount;
        } else {
            collaterals[loanId] = CollateralInfo({
                token:    token,
                amount:   depositAmount,
                borrower: borrower,
                isActive: true,
                decimals: decimals_
            });
        }

        emit CollateralDeposited(loanId, borrower, token, depositAmount);
    }

    // =========================================================
    // WITHDRAW
    // =========================================================

    function withdrawCollateral(uint256 loanId) external override nonReentrant {
        CollateralInfo storage info = collaterals[loanId];
        if (!info.isActive) revert CM__CollateralNotActive(loanId);

        bool isBorrower   = msg.sender == info.borrower;
        bool isAuthorized = authorizedCallers[msg.sender];
        // FIX: Loan clone có thể tự rút collateral cho loanId của nó
        // _loanRegistry[loanId] được set bởi owner (P2PLending) khi fund → không thể spoof
        bool isRegisteredLoan = (_loanRegistry[loanId] != address(0) && msg.sender == _loanRegistry[loanId]);

        if (!isBorrower && !isAuthorized && !isRegisteredLoan) {
            revert CM__Unauthorized(msg.sender);
        }

        uint256 amount    = info.amount;
        address token     = info.token;
        address recipient = info.borrower;

        // ── EFFECTS ──────────────────────────────────────
        info.isActive = false;
        info.amount   = 0;

        // ── INTERACTIONS ──────────────────────────────────
        _transferOut(token, recipient, amount);

        emit CollateralWithdrawn(loanId, recipient, token, amount);
    }

    // =========================================================
    // LIQUIDATION — chỉ P2PLending (owner) được gọi
    // =========================================================

    
    function liquidateCollateralWithSnapshot(
        LiquidationLib.LiquidationSnapshot calldata snapshot,
        address liquidator
    ) external override onlyOwner nonReentrant {
        uint256 loanId = snapshot.loanId;
        CollateralInfo storage info = collaterals[loanId];

        if (!info.isActive) revert CM__CollateralNotActive(loanId);
        if (liquidator == address(0)) revert CM__InvalidLoanContract();

        // Verify snapshot khớp với stored collateral info
        if (snapshot.loanId != loanId) revert CM__SnapshotLoanIdMismatch(snapshot.loanId, loanId);

        address token    = info.token;
        address borrower = info.borrower;

        // ── EFFECTS (trước interactions) ─────────────────────────────
        info.isActive = false;
        info.amount   = 0;

        // Track bad debt
        if (snapshot.isBadDebt) {
            // deficit = debtAmount - collateralValueUSD (USD terms)
            // Đây là ước tính — collateral đã được dùng hết
            uint256 deficit = snapshot.debtAmount > snapshot.collateralValueUSD
                ? snapshot.debtAmount - snapshot.collateralValueUSD
                : 0;
            totalBadDebt += deficit;

            emit BadDebtRecorded(
                loanId,
                borrower,
                snapshot.debtAmount,
                snapshot.liquidatorCollateral,
                deficit
            );
        }

        // ── INTERACTIONS ─────────────────────────────────────────────
        // 1. Liquidator nhận: debtInCollateral + bonus
        _transferOut(token, liquidator, snapshot.liquidatorCollateral);

        // 2. Surplus về borrower (nếu có)
        if (snapshot.borrowerRefund > 0) {
            _transferOut(token, borrower, snapshot.borrowerRefund);
        }

        emit CollateralLiquidated(
            loanId,
            liquidator,
            borrower,
            token,
            snapshot.liquidatorCollateral,
            snapshot.bonusCollateral,
            snapshot.borrowerRefund,
            snapshot.debtAmount,
            snapshot.healthFactor,
            snapshot.isBadDebt
        );
    }

    // =========================================================
    // VIEW FUNCTIONS
    // =========================================================

    
    function getCollateralValue(uint256 loanId) external view override returns (uint256) {
        CollateralInfo storage info = collaterals[loanId];
        if (!info.isActive) return 0;
        if (address(priceOracle) == address(0)) return 0;

        (uint256 price,) = priceOracle.getPrice(info.token);
        if (price == 0) return 0;

        return LiquidationLib.calculateCollateralValueUSD(
            info.amount, price, info.decimals
        );
    }

    function getCollateralRatio(uint256 loanId) external view override returns (uint256) {
        CollateralInfo storage info = collaterals[loanId];
        if (!info.isActive) return 0;

        address loanAddr = _loanRegistry[loanId];
        if (loanAddr == address(0)) return type(uint256).max;

        ILoan loan       = ILoan(loanAddr);
        uint256 debtUSDT = loan.getTotalRepaymentAmount();
        if (debtUSDT == 0) return type(uint256).max;

        if (address(priceOracle) == address(0)) return 0;

        (uint256 price,) = priceOracle.getPrice(info.token);
        if (price == 0) return 0;

        uint256 collateralUSD = LiquidationLib.calculateCollateralValueUSD(
            info.amount, price, info.decimals
        );

        return LiquidationLib.calculateHealthFactor(collateralUSD, debtUSDT);
    }

    function isLiquidatable(uint256 loanId) external view override returns (bool) {
        CollateralInfo storage info = collaterals[loanId];
        if (!info.isActive) return false;

        address loanAddr = _loanRegistry[loanId];
        if (loanAddr == address(0)) return false;

        ILoan loan = ILoan(loanAddr);
        ILoan.LoanDetails memory details = loan.getLoanDetails();
        if (details.status != ILoan.LoanStatus.ACTIVE) return false;

        // Điều kiện A: quá hạn
        if (loan.isOverdue()) return true;

        // Điều kiện B: health factor (dùng getPrice không staleness check cho view)
        if (address(priceOracle) == address(0)) return false;

        (uint256 price,) = priceOracle.getPrice(info.token);
        if (price == 0) return false;

        uint256 collateralUSD = LiquidationLib.calculateCollateralValueUSD(
            info.amount, price, info.decimals
        );

        uint256 debtUSDT = loan.getTotalRepaymentAmount();
        if (debtUSDT == 0) return false;

        uint256 hf = LiquidationLib.calculateHealthFactor(collateralUSD, debtUSDT);
        return LiquidationLib.isLiquidatable(hf, liquidationThreshold, false);
    }

    
    function getLiquidationStatus(uint256 loanId)
        external
        view
        override
        returns (
            uint256 healthFactor,
            uint256 collateralValueUSD,
            uint256 debtAmount,
            bool    isLiquidatable_,
            uint256 triggerPrice
        )
    {
        CollateralInfo storage info = collaterals[loanId];
        if (!info.isActive) return (0, 0, 0, false, 0);

        address loanAddr = _loanRegistry[loanId];
        if (loanAddr == address(0)) return (type(uint256).max, 0, 0, false, 0);

        ILoan loan = ILoan(loanAddr);
        if (loan.getLoanDetails().status != ILoan.LoanStatus.ACTIVE) {
            return (0, 0, 0, false, 0);
        }

        debtAmount = loan.getTotalRepaymentAmount();

        if (address(priceOracle) != address(0)) {
            (uint256 price,) = priceOracle.getPrice(info.token);
            collateralValueUSD = LiquidationLib.calculateCollateralValueUSD(
                info.amount, price, info.decimals
            );
        }

        healthFactor = LiquidationLib.calculateHealthFactor(collateralValueUSD, debtAmount);
        isLiquidatable_ = LiquidationLib.isLiquidatable(
            healthFactor, liquidationThreshold, loan.isOverdue()
        );

        // Trigger price: giá tại đó HF = liquidationThreshold
        triggerPrice = LiquidationLib.calculateLiquidationTriggerPrice(
            debtAmount, info.amount, info.decimals, liquidationThreshold
        );
    }

    function getLiquidationThreshold() external view override returns (uint256) {
        return liquidationThreshold;
    }

    function getLiquidationBonus() external view override returns (uint256) {
        return liquidationBonus;
    }

    function getLoanContract(uint256 loanId) external view override returns (address) {
        return _loanRegistry[loanId];
    }

    /**
     * @dev Thông tin đầy đủ collateral (bao gồm decimals)
     */
    function getCollateralInfo(uint256 loanId)
        external
        view
        override
        returns (
            address token,
            uint256 amount,
            address borrower,
            bool    isActive,
            uint8   decimals
        )
    {
        CollateralInfo storage info = collaterals[loanId];
        return (info.token, info.amount, info.borrower, info.isActive, info.decimals);
    }

    // =========================================================
    // ADMIN FUNCTIONS
    // =========================================================

    function setAuthorizedCaller(address caller, bool status) external onlyOwner {
        if (caller == address(0)) revert CM__InvalidLoanContract();
        authorizedCallers[caller] = status;
        emit CallerAuthorized(caller, status, msg.sender);
    }

    function registerLoan(uint256 loanId, address loanContract) external onlyOwner {
        if (loanContract == address(0)) revert CM__InvalidLoanContract();
        if (_loanRegistry[loanId] != address(0)) {
            revert CM__LoanAlreadyRegistered(loanId, _loanRegistry[loanId]);
        }
        _loanRegistry[loanId] = loanContract;
        emit LoanRegistered(loanId, loanContract, msg.sender);
    }

    /**
     * @dev Cập nhật ngưỡng liquidation
     * Dùng LiquidationLib.validateThreshold() thay vì inline check
     */
    function setLiquidationThreshold(uint256 newThreshold) external onlyOwner {
        LiquidationLib.validateThreshold(newThreshold);
        uint256 old = liquidationThreshold;
        liquidationThreshold = newThreshold;
        emit LiquidationThresholdUpdated(old, newThreshold);
    }

    /**
     * @dev Cập nhật bonus liquidator
     */
    function setLiquidationBonus(uint256 newBonus) external onlyOwner {
        LiquidationLib.validateBonus(newBonus);
        uint256 old = liquidationBonus;
        liquidationBonus = newBonus;
        emit LiquidationBonusUpdated(old, newBonus);
    }

    function setPriceOracle(address _oracle) external onlyOwner {
        priceOracle = IPriceOracle(_oracle);
    }

    // =========================================================
    // INTERNAL
    // =========================================================

    function _transferOut(address token, address recipient, uint256 amount) internal {
        if (amount == 0 || recipient == address(0)) return;
        if (token == ETH_ADDRESS) {
            (bool success,) = payable(recipient).call{value: amount}("");
            if (!success) revert CM__TransferFailed(token, recipient, amount);
        } else {
            IERC20(token).safeTransfer(recipient, amount);
        }
    }

    receive() external payable {
        // ETH gửi trực tiếp bởi 3rd party sẽ gây accounting mismatch
        if (msg.sender != owner() && !authorizedCallers[msg.sender]) {
            revert CM__DirectETHNotAllowed();
        }
    }
}
