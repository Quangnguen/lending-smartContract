// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/ICollateralManager.sol";
import "../interfaces/IPriceOracle.sol";

contract CollateralManager is ICollateralManager, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant DEFAULT_LIQUIDATION_THRESHOLD = 11000; // 110%
    uint256 public constant DEFAULT_LIQUIDATION_BONUS = 500; // 5%
    address public constant ETH_ADDRESS = address(0);
    IPriceOracle public priceOracle;
    uint256 public liquidationThreshold;
    uint256 public liquidationBonus;
    // Thông tin thế chấp của từng khoản vay
    struct CollateralInfo {
        address token;
        uint256 amount;
        address borrower;
        bool isActive;
    }
    mapping(uint256 => CollateralInfo) public collaterals;
    /// @dev Loan contracts được phép gọi withdrawCollateral thay mặt borrower
    mapping(address => bool) public authorizedCallers;

    error InvalidAmount();
    error CollateralNotActive();
    error NotLiquidatable();
    error Unauthorized();
    error TransferFailed();

    event CallerAuthorized(address indexed caller, bool status);

   constructor(
        address _priceOracle,
        address initialOwner
    ) Ownable(initialOwner) {
        priceOracle = IPriceOracle(_priceOracle);
        liquidationThreshold = DEFAULT_LIQUIDATION_THRESHOLD;
        liquidationBonus = DEFAULT_LIQUIDATION_BONUS;
    }

    function depositCollateral(
        uint256 loanId,
        address borrower,
        address token,
        uint256 amount
    ) external payable override nonReentrant {
        if (amount == 0 && msg.value == 0) revert InvalidAmount();
        uint256 depositAmount;
        
        if (token == ETH_ADDRESS) {
            // Nạp ETH
            depositAmount = msg.value;
        } else {
            // Nạp ERC20
            depositAmount = amount;
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }

        CollateralInfo storage info = collaterals[loanId];
        if (info.isActive) {
            if (info.borrower != borrower) revert("Borrower mismatch");
            info.amount += depositAmount;
        } else {
            collaterals[loanId] = CollateralInfo({
                token: token,
                amount: depositAmount,
                borrower: borrower,
                isActive: true
            });
        }
        emit CollateralDeposited(loanId, borrower, token, depositAmount);
    }

    function withdrawCollateral(uint256 loanId) external override nonReentrant {
        CollateralInfo storage info = collaterals[loanId];
        
        if (!info.isActive) revert CollateralNotActive();

        // Cho phép: borrower tự withdraw HOẶC Loan contract được ủy quyền
        bool isBorrower = msg.sender == info.borrower;
        bool isAuthorized = authorizedCallers[msg.sender];
        if (!isBorrower && !isAuthorized) revert Unauthorized();

        uint256 amount = info.amount;
        address token = info.token;
        address recipient = info.borrower; // Luôn trả về borrower, không phải caller
        
        info.isActive = false;
        info.amount = 0;
        if (token == ETH_ADDRESS) {
            (bool success,) = payable(recipient).call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(recipient, amount);
        }
        emit CollateralWithdrawn(loanId, recipient, token, amount);
    }

    function liquidate(uint256 loanId) external override nonReentrant {
        CollateralInfo storage info = collaterals[loanId];
        if (!info.isActive) revert CollateralNotActive();
        
        uint256 amount = info.amount;
        uint256 bonus = (amount * liquidationBonus) / BASIS_POINTS;
        
        info.isActive = false;
        info.amount = 0;
        // Transfer to liquidator
        if (info.token == ETH_ADDRESS) {
            (bool success,) = payable(msg.sender).call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(info.token).safeTransfer(msg.sender, amount);
        }
        emit CollateralLiquidated(loanId, msg.sender, amount, bonus);
    }
    function getCollateralValue(uint256 loanId) external view override returns (uint256) {
        CollateralInfo storage info = collaterals[loanId];
        if (!info.isActive) return 0;
        (uint256 price,) = priceOracle.getPrice(info.token);
        return (info.amount * price) / 1e18;
    }
    function getCollateralRatio(uint256 /* loanId */) external pure override returns (uint256) {
        // Simplified - sẽ cần loanValue từ Loan contract
        return BASIS_POINTS * 150 / 100; // Placeholder 150%
    }
    function isLiquidatable(uint256 loanId) external view override returns (bool) {
        return this.getCollateralRatio(loanId) < liquidationThreshold;
    }
    function getLiquidationThreshold() external view override returns (uint256) {
        return liquidationThreshold;
    }
    function getLiquidationBonus() external view override returns (uint256) {
        return liquidationBonus;
    }

    /**
     * @dev Admin cho phép/thu hồi quyền của Loan contract
     * Gọi sau khi deploy Loan contract để cho phép auto-release collateral khi repay
     */
    function setAuthorizedCaller(address caller, bool status) external onlyOwner {
        authorizedCallers[caller] = status;
        emit CallerAuthorized(caller, status);
    }

    receive() external payable {}
}