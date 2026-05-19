// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ICollateralManager {
    // EVENT
    event CollateralDeposited(
        uint256 indexed loanId,
        address indexed borrower,
        address token,
        uint256 amount
    );

    event CollateralWithdrawn(
        uint256 indexed loanId,
        address indexed recipient,
        address token,
        uint256 amount
    );

    event CollateralLiquidated(
        uint256 indexed loanId,
        address indexed liquidator,
        uint256 collateralAmount,
        uint256 liquidationBonus
    );

    // Khi ngưỡng thanh lý thay đổi
    event LiquidationThresholdUpdated(
        uint256 oldThreshold,
        uint256 newThreshold
    );

    // CORE FUNCTION
    function depositCollateral(
        uint256 loanId,
        address borrower,
        address token,
        uint256 amount
    ) external payable;

    function withdrawCollateral(
        uint256 loanId
    ) external;

    function liquidate(
        uint256 loanId
    ) external;

   // VIEWS FUNCTION

    // lấy giá trị thế chấp theo USD
    function getCollateralValue(uint256 loanId)
        external
        view
        returns (uint256);

    function getCollateralRatio(uint256 loanId)
        external
        view
        returns (uint256);

    function isLiquidatable(uint256 loanId)
        external
        view
        returns (bool);
    
    // lấy ngưỡng thanh lý
    function getLiquidationThreshold()
        external
        view
        returns (uint256);

    function getLiquidationBonus()
        external
        view
        returns (uint256);

    /// @dev Admin function: cho phép Loan contract tự động withdraw collateral khi repay
    function setAuthorizedCaller(address caller, bool status) external;
}