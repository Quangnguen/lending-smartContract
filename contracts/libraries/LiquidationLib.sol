// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title LiquidationLib
 * @dev Library tập trung toàn bộ liquidation math và validation
 *
 * ─── Liquidation Architecture ──────────────────────────────────────────
 *
 * Dự án (P2P Direct):
 *   Liquidator → repay USDT debt → nhận collateral + bonus
 *   Bonus = liquidationBonus% của phần collateral tương đương debt
 *
 * So sánh DeFi standards:
 *
 *   AAVE v3 (Partial Liquidation):
 *     • Chỉ liquidate tối đa 50% debt mỗi lần (CLOSE_FACTOR)
 *     • liquidationBonus = 5–15% tùy asset
 *     • Health Factor = collateralValue × LT / debtValue
 *     • Dùng liquidationBonus từ CollateralAssetConfig
 *     • Tổng liquidator nhận = debtPaid × (1 + liquidationBonus)
 *
 *   COMPOUND v3 (Absorption):
 *     • Khi position không khả ngoại (undercollateralized), protocol absorb
 *     • buyCollateral() — bất kỳ ai mua collateral với giá discount
 *     • Không có liquidator reward trực tiếp — reserve fund cover
 *
 *   MORPHO (Per-Market):
 *     • Mỗi market có LLTV (Liquidation Loan-To-Value) riêng
 *     • liquidationIncentive = 1 + (1/LLTV - 1) × 0.3
 *     • Flash loan-friendly: liquidator có thể dùng callback
 *
 *   MAKERDAO (Auction):
 *     • Dog.bark() → Clipper auction (Dutch auction giảm giá)
 *     • Liquidation penalty = liquidationPenalty% vào Surplus Buffer
 *     • Keeper takes any winning bid price
 *
 * ─── Model Hiện Tại (Fixed Discount) ──────────────────────────────────
 *
 *   Liquidator trả: totalDebt (USDT)
 *   Liquidator nhận: collateral tương đương debtValue + bonus%
 *   Borrower nhận: surplus collateral (nếu có)
 *
 *   Ví dụ:
 *     debt = 1000 USDT, ethPrice = 2000 USDT/ETH, bonus = 5%
 *     debtInETH    = 1000 / 2000 = 0.5 ETH
 *     bonusETH     = 0.5 × 5%   = 0.025 ETH
 *     liquidatorGets = 0.525 ETH (nếu collateral đủ)
 *     borrowerRefund = collateral - 0.525 ETH
 *
 * ─── Key Improvement: Single-source Oracle Read ────────────────────────
 *
 *   TRƯỚC (sai): P2PLending và CM đều gọi oracle riêng → 2 giá khác nhau
 *   SAU (đúng):  P2PLending tính LiquidationSnapshot 1 lần, pass xuống CM
 *
 * ─── Decimal Convention ────────────────────────────────────────────────
 *
 *   ETH price (Chainlink): 8 decimals
 *   USDT debt:             6 decimals
 *   ETH collateral:        18 decimals (wei)
 *   ERC-20 collateral:     varies (phải dùng decimals của token)
 *
 *   debtInETH (wei) = debt(6dec) * 1e18 * 1e2 / ethPrice(8dec)
 *                   = debt * 1e20 / ethPrice
 *
 *   debtInERC20 = debt(6dec) / tokenPriceUSD(8dec) * 10^tokenDecimals * 1e2
 *               = debt * 10^tokenDecimals * 1e2 / tokenPrice
 */
library LiquidationLib {

    // =========================================================
    // CONSTANTS
    // =========================================================

    uint256 public constant BASIS_POINTS              = 10_000;
    uint256 public constant MAX_LIQUIDATION_BONUS     = 2_000;   // 20% max
    uint256 public constant MIN_LIQUIDATION_THRESHOLD = 10_100;  // 101% min
    uint256 public constant MAX_LIQUIDATION_THRESHOLD = 20_000;  // 200% max
    uint256 public constant MAX_CLOSE_FACTOR          = 10_000;  // 100% (full)

    // =========================================================
    // STRUCTS
    // =========================================================

    /**
     * @dev Snapshot tất cả số liệu cần cho 1 liquidation transaction
     *
     * Tại sao snapshot?
     *   1. Oracle chỉ được gọi 1 lần → tránh inconsistency giữa P2PLending và CM
     *   2. Giá được lock tại thời điểm check → không bị manipulate giữa các bước
     *   3. Gas: tránh duplicate oracle calls
     *   4. Audit: snapshot là bằng chứng về trạng thái tại thời điểm liquidation
     */
    struct LiquidationSnapshot {
        uint256 loanId;
        address borrower;
        address lender;
        address loanToken;
        address collateralToken;
        uint8   collateralDecimals;
        uint256 collateralAmount;       // Tổng collateral đang giữ
        uint256 debtAmount;             // Tổng USDT debt (principal + interest + lateFee)
        uint256 collateralPrice;        // Giá oracle tại thời điểm liquidation (8 dec)
        uint256 collateralValueUSD;     // Giá trị USD của collateral (6 dec)
        uint256 healthFactor;           // collateralValueUSD / debtAmount × 10000
        uint256 liquidatorCollateral;   // Collateral liquidator nhận được
        uint256 bonusCollateral;        // Phần bonus trong liquidatorCollateral
        uint256 borrowerRefund;         // Surplus collateral về borrower
        bool    isBadDebt;              // collateralValue < debtValue
        bool    isOverdue;              // Quá hạn
    }

    // =========================================================
    // ERRORS
    // =========================================================

    error LiquidationLib__NotLiquidatable(
        uint256 loanId,
        uint256 healthFactor,
        uint256 threshold
    );
    error LiquidationLib__InvalidThreshold(uint256 threshold, uint256 min, uint256 max);
    error LiquidationLib__InvalidBonus(uint256 bonus, uint256 max);
    error LiquidationLib__ZeroPrice(address token);
    error LiquidationLib__OracleStale(address token, uint256 age, uint256 maxAge);
    error LiquidationLib__InsufficientAllowance(
        address token,
        address liquidator,
        uint256 allowance,
        uint256 required
    );
    error LiquidationLib__InsufficientBalance(
        address token,
        address liquidator,
        uint256 balance,
        uint256 required
    );
    error LiquidationLib__LoanNotActive(uint256 loanId);
    error LiquidationLib__ZeroDebt(uint256 loanId);
    error LiquidationLib__ZeroCollateral(uint256 loanId);
    error LiquidationLib__SelfLiquidation(uint256 loanId, address borrower);

    // =========================================================
    // HEALTH FACTOR
    // =========================================================

    /**
     * @notice Tính Health Factor của một khoản vay
     *
     * Health Factor (HF) = collateralValueUSD × liquidationThreshold / debtValueUSD
     *
     * So sánh với Aave:
     *   Aave: HF = Σ(collateral_i × LT_i) / totalDebt
     *             HF < 1.0 → liquidatable
     *   Dự án: HF = collateralValue × 10000 / debtValue (bps)
     *              HF < liquidationThreshold → liquidatable
     *
     * @param collateralValueUSD USD value of collateral (6 decimals)
     * @param debtValueUSD       USD value of debt (6 decimals)
     * @return hf                Health factor in basis points
     *                           > liquidationThreshold = healthy
     *                           < liquidationThreshold = liquidatable
     */
    function calculateHealthFactor(
        uint256 collateralValueUSD,
        uint256 debtValueUSD
    ) internal pure returns (uint256 hf) {
        if (debtValueUSD == 0) return type(uint256).max; // No debt → infinite HF
        if (collateralValueUSD == 0) return 0;
        return (collateralValueUSD * BASIS_POINTS) / debtValueUSD;
    }

    /**
     * @notice Kiểm tra loan có thể liquidate dựa trên HF và overdue status
     *
     * Liquidatable khi:
     *   (A) HF < liquidationThreshold (under-collateralized), HOẶC
     *   (B) isOverdue = true (quá hạn — bất kể HF)
     *
     * Tại sao overdue luôn liquidatable?
     *   Borrower đã vi phạm hợp đồng → lender có quyền reclaim
     *   Dù collateral vẫn đủ, vẫn cho phép liquidation (protect lender)
     *
     * @param healthFactor         Giá trị HF hiện tại (basis points)
     * @param liquidationThreshold Ngưỡng (basis points, 11000 = 110%)
     * @param isOverdue            Loan có đang quá hạn không
     */
    function isLiquidatable(
        uint256 healthFactor,
        uint256 liquidationThreshold,
        bool    isOverdue
    ) internal pure returns (bool) {
        if (isOverdue) return true;
        return healthFactor < liquidationThreshold;
    }

    // =========================================================
    // COLLATERAL DISTRIBUTION MATH
    // =========================================================

    /**
     * @notice Tính phân phối collateral cho liquidation
     *
     * ┌─ ETH Collateral ────────────────────────────────────────────────┐
     * │  debtInETH = debt(6dec) × 1e20 / ethPrice(8dec)               │
     * │  bonusETH  = debtInETH × bonus / 10000                         │
     * │  liquidatorGets = min(debtInETH + bonusETH, collateral)        │
     * │  borrowerRefund = collateral - liquidatorGets                   │
     * └─────────────────────────────────────────────────────────────────┘
     *
     * ┌─ ERC-20 Collateral ─────────────────────────────────────────────┐
     * │  debtInToken = debt(6dec) × 10^tokenDec × 1e2 / tokenPrice(8) │
     * │  bonusToken  = debtInToken × bonus / 10000                      │
     * │  liquidatorGets = min(debtInToken + bonusToken, collateral)     │
     * │  borrowerRefund = collateral - liquidatorGets                   │
     * └─────────────────────────────────────────────────────────────────┘
     *
     * ┌─ Bad Debt (collateral < debt value) ───────────────────────────┐
     * │  liquidatorGets = collateral (all)                              │
     * │  borrowerRefund = 0                                             │
     * │  Protocol absorbs deficit                                       │
     * └─────────────────────────────────────────────────────────────────┘
     *
     * @param debtUSD           Total debt in USD (6 decimals)
     * @param collateralAmount  Amount of collateral held (collateral native decimals)
     * @param collateralPrice   Oracle price of collateral (8 decimals)
     * @param collateralDecimals Decimals of collateral token (18 = ETH, 8 = WBTC)
     * @param liquidationBonus  Bonus in basis points (500 = 5%)
     * @return liquidatorGets   Collateral amount liquidator receives
     * @return bonusAmount      Bonus portion within liquidatorGets
     * @return borrowerRefund   Surplus returned to borrower
     * @return isBadDebt        True if protocol takes a loss
     */
    function calculateLiquidationAmounts(
        uint256 debtUSD,
        uint256 collateralAmount,
        uint256 collateralPrice,
        uint8   collateralDecimals,
        uint256 liquidationBonus
    ) internal pure returns (
        uint256 liquidatorGets,
        uint256 bonusAmount,
        uint256 borrowerRefund,
        bool    isBadDebt
    ) {
        if (collateralPrice == 0 || collateralAmount == 0) {
            return (collateralAmount, 0, 0, true);
        }

        // Chuyển debt USD sang collateral token units
        // debtInCollateral = debtUSD(6dec) × 10^collateralDec × 1e2 / collateralPrice(8dec)
        // Lý do × 1e2: collateralPrice(8dec) → cần 6dec USD output
        //   debtUSD(6) / (price(8) / 10^(collateralDec)) → (6 - 8 + collateralDec) = collateralDec - 2
        //   Nhân thêm 1e2 để đủ decimals
        uint256 debtInCollateral = (debtUSD * (10 ** uint256(collateralDecimals)) * 1e2)
            / collateralPrice;

        // Bonus = debtInCollateral × bonus / 10000
        bonusAmount  = (debtInCollateral * liquidationBonus) / BASIS_POINTS;
        liquidatorGets = debtInCollateral + bonusAmount;

        // Cap: liquidator không nhận quá collateral có sẵn
        if (liquidatorGets >= collateralAmount) {
            // Bad debt: collateral không đủ cover debt + bonus
            liquidatorGets = collateralAmount;
            bonusAmount    = 0;      // Không còn bonus trong bad debt
            borrowerRefund = 0;
            isBadDebt      = true;
        } else {
            borrowerRefund = collateralAmount - liquidatorGets;
            isBadDebt      = false;
        }
    }

    /**
     * @notice Tính collateral value theo USD
     *
     * @param amount            Số lượng collateral (native decimals)
     * @param price             Oracle price (8 decimals)
     * @param collateralDecimals Decimals của collateral token
     * @return valueUSD         USD value (6 decimals)
     */
    function calculateCollateralValueUSD(
        uint256 amount,
        uint256 price,
        uint8   collateralDecimals
    ) internal pure returns (uint256 valueUSD) {
        if (price == 0 || amount == 0) return 0;
        // amount(collateralDec) × price(8dec) / (10^collateralDec × 1e2) = USD(6dec)
        return (amount * price) / (10 ** uint256(collateralDecimals) * 1e2);
    }

    // =========================================================
    // VALIDATION
    // =========================================================

    /**
     * @notice Validate tất cả điều kiện cần thiết TRƯỚC khi thực hiện liquidation
     *
     * Checks (từ rẻ đến đắt gas):
     *   1. Loan đang ACTIVE
     *   2. Không tự liquidate chính mình (borrower == liquidator)
     *   3. Debt > 0
     *   4. Collateral > 0
     *   5. Health Factor < threshold HOẶC đang overdue
     *   6. Liquidator có đủ allowance
     *   7. Liquidator có đủ balance
     *
     * @param loanId              ID của loan
     * @param isActive            Loan đang ACTIVE?
     * @param isOverdue           Loan đang quá hạn?
     * @param borrower            Địa chỉ borrower
     * @param liquidator          Địa chỉ liquidator (msg.sender)
     * @param debtAmount          Tổng USDT cần trả
     * @param collateralAmount    Lượng collateral hiện có
     * @param healthFactor        HF đã tính
     * @param liquidationThreshold Ngưỡng
     * @param loanToken           Token phải approve
     * @param loanContract        Địa chỉ Loan clone (địa chỉ nhận allowance)
     */
    function validateLiquidation(
        uint256 loanId,
        bool    isActive,
        bool    isOverdue,
        address borrower,
        address liquidator,
        uint256 debtAmount,
        uint256 collateralAmount,
        uint256 healthFactor,
        uint256 liquidationThreshold,
        address loanToken,
        address loanContract
    ) internal view {
        // 1. Status
        if (!isActive) revert LiquidationLib__LoanNotActive(loanId);

        // 2. Self-liquidation
        if (liquidator == borrower) revert LiquidationLib__SelfLiquidation(loanId, borrower);

        // 3. Debt sanity
        if (debtAmount == 0) revert LiquidationLib__ZeroDebt(loanId);

        // 4. Collateral sanity
        if (collateralAmount == 0) revert LiquidationLib__ZeroCollateral(loanId);

        // 5. HF check + overdue
        if (!isLiquidatable(healthFactor, liquidationThreshold, isOverdue)) {
            revert LiquidationLib__NotLiquidatable(loanId, healthFactor, liquidationThreshold);
        }

        // 6. Allowance check (liquidator approve P2PLending)
        // Note: loanContract = P2PLending address ở đây (vì P2PLending pull USDT)
        uint256 allowance = _getAllowance(loanToken, liquidator, loanContract);
        if (allowance < debtAmount) {
            revert LiquidationLib__InsufficientAllowance(
                loanToken, liquidator, allowance, debtAmount
            );
        }

        // 7. Balance check
        uint256 balance = _getBalance(loanToken, liquidator);
        if (balance < debtAmount) {
            revert LiquidationLib__InsufficientBalance(
                loanToken, liquidator, balance, debtAmount
            );
        }
    }

    // =========================================================
    // THRESHOLD / BONUS VALIDATION
    // =========================================================

    function validateThreshold(uint256 threshold) internal pure {
        if (threshold < MIN_LIQUIDATION_THRESHOLD || threshold > MAX_LIQUIDATION_THRESHOLD) {
            revert LiquidationLib__InvalidThreshold(
                threshold, MIN_LIQUIDATION_THRESHOLD, MAX_LIQUIDATION_THRESHOLD
            );
        }
    }

    function validateBonus(uint256 bonus) internal pure {
        if (bonus > MAX_LIQUIDATION_BONUS) {
            revert LiquidationLib__InvalidBonus(bonus, MAX_LIQUIDATION_BONUS);
        }
    }

    // =========================================================
    // INTERNAL HELPERS (view, dùng assembly để giảm gas)
    // =========================================================

    function _getAllowance(
        address token,
        address owner,
        address spender
    ) internal view returns (uint256) {
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSelector(
                bytes4(keccak256("allowance(address,address)")),
                owner,
                spender
            )
        );
        if (!success || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    function _getBalance(
        address token,
        address account
    ) internal view returns (uint256) {
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSelector(
                bytes4(keccak256("balanceOf(address)")),
                account
            )
        );
        if (!success || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    // =========================================================
    // KEEPER / BOT HELPERS (view functions cho off-chain monitoring)
    // =========================================================

    /**
     * @notice Tính lợi nhuận ước tính cho liquidator trước khi thực hiện
     *
     * Keeper bot gọi hàm này để quyết định có nên liquidate không.
     * profitability = bonusAmount_in_USD - gasEstimate_in_USD
     *
     * @param debtUSD          Debt tính bằng USD (6 dec)
     * @param liquidationBonus Bonus (basis points)
     * @return bonusUSD        Estimated USD value của bonus (6 dec)
     */
    function estimateLiquidatorProfit(
        uint256 debtUSD,
        uint256 /* collateralPrice */,
        uint8   /* collateralDecimals */,
        uint256 liquidationBonus
    ) internal pure returns (uint256 bonusUSD) {
        // bonusUSD = debtUSD × liquidationBonus / 10000
        bonusUSD = (debtUSD * liquidationBonus) / BASIS_POINTS;
    }

    /**
     * @notice Tính ngưỡng giá oracle mà tại đó loan sẽ bị liquidate
     * Keeper dùng để watch price feed và trigger liquidation đúng lúc
     *
     * @param debtUSD              Debt tính bằng USD (6 dec)
     * @param collateralAmount     Số lượng collateral
     * @param collateralDecimals   Decimals collateral
     * @param liquidationThreshold Ngưỡng (basis points)
     * @return triggerPrice        Giá collateral mà dưới đó sẽ liquidatable (8 dec)
     */
    function calculateLiquidationTriggerPrice(
        uint256 debtUSD,
        uint256 collateralAmount,
        uint8   collateralDecimals,
        uint256 liquidationThreshold
    ) internal pure returns (uint256 triggerPrice) {
        if (collateralAmount == 0) return 0;
        // collateralValueUSD < debtUSD × threshold / 10000
        // (amount × price) / (10^dec × 1e2) < debtUSD × threshold / 10000
        // price < debtUSD × threshold × 10^dec × 1e2 / (10000 × amount)
        uint256 thresholdDebt = (debtUSD * liquidationThreshold) / BASIS_POINTS;
        triggerPrice = (thresholdDebt * (10 ** uint256(collateralDecimals)) * 1e2) / collateralAmount;
    }
}
