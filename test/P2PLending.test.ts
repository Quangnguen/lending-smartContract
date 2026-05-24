import { ethers } from "hardhat";
import { expect } from "chai";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

// ─── Deploy helper ────────────────────────────────────────────────────────────

async function deployAll() {
  const [owner, borrower, lender, liquidator, attacker] = await ethers.getSigners();

  // MockUSDT (6 decimals)
  const MockUSDT = await ethers.getContractFactory("MockUSDT");
  const usdt = await MockUSDT.deploy("Mock USDT", "USDT", 6);

  // PriceOracle
  const PriceOracle = await ethers.getContractFactory("PriceOracle");
  const oracle = await PriceOracle.deploy();
  // ETH price = $2000 (8 decimals)
  await oracle.setManualPrice(ethers.ZeroAddress, 200_000_000_00n);

  // CreditScoreOracle
  const CreditScoreOracle = await ethers.getContractFactory("CreditScoreOracle");
  const creditOracle = await CreditScoreOracle.deploy(owner.address);

  // DebtToken
  const DebtToken = await ethers.getContractFactory("DebtToken");
  const debtToken = await DebtToken.deploy();

  // CollateralManager
  const CollateralManager = await ethers.getContractFactory("CollateralManager");
  const collateralMgr = await CollateralManager.deploy(await oracle.getAddress());

  // Loan implementation (EIP-1167 target)
  const Loan = await ethers.getContractFactory("Loan");
  const loanImpl = await Loan.deploy();

  // P2PLending factory
  const P2PLending = await ethers.getContractFactory("P2PLending");
  const p2p = await P2PLending.deploy(
    await creditOracle.getAddress(),
    await collateralMgr.getAddress(),
    await oracle.getAddress(),
    await debtToken.getAddress(),
    await loanImpl.getAddress(),
    owner.address,   // feeRecipient
    owner.address,   // initialOwner
  );

  // Whitelist tokens
  await p2p.whitelistLoanToken(await usdt.getAddress(), true);
  await p2p.whitelistCollateralToken(ethers.ZeroAddress, true); // ETH

  // Authorise
  await collateralMgr.setAuthorizedCaller(await p2p.getAddress(), true);
  await debtToken.setAuthorizedMinter(await p2p.getAddress(), true);

  // Fund lender with 100k USDT
  await usdt.mint(lender.address, ethers.parseUnits("100000", 6));
  // Fund attacker with 10k USDT
  await usdt.mint(attacker.address, ethers.parseUnits("10000", 6));

  const usdtAddr = await usdt.getAddress();
  const p2pAddr  = await p2p.getAddress();

  // Helper: build a default LoanRequest struct
  const SEVEN_DAYS = 7 * 24 * 3600;
  const buildRequest = (overrides: any = {}) => ({
    loanToken: usdtAddr,
    collateralToken: ethers.ZeroAddress, // ETH
    principal: ethers.parseUnits("1000", 6), // 1000 USDT
    interestRate: 1200n,                   // 12% (basis points)
    collateralAmount: ethers.parseEther("0.8"),
    duration: BigInt(30 * 24 * 3600),      // 30 days
    loanTokenDecimals: 6,
    collateralDecimals: 18,
    deadline: BigInt(Math.floor(Date.now() / 1000) + SEVEN_DAYS),
    ...overrides,
  });

  return { p2p, usdt, oracle, creditOracle, debtToken, collateralMgr, loanImpl,
           owner, borrower, lender, liquidator, attacker,
           usdtAddr, p2pAddr, buildRequest };
}

// ─── Tests ────────────────────────────────────────────────────────────────────

describe("P2P Lending Protocol — Full Test Suite", () => {

  // ══════════════════════════════════════════════════════
  // 1. LOAN REQUEST CREATION
  // ══════════════════════════════════════════════════════
  describe("1. Loan Request Creation", () => {

    it("TC-SC-001: Creates valid loan request, emits LoanRequestCreated", async () => {
      const { p2p, borrower, buildRequest } = await deployAll();
      const req = buildRequest();

      const tx = await p2p.connect(borrower).createLoanRequest(req, {
        value: req.collateralAmount,
      });
      const receipt = await tx.wait();

      // Find LoanRequestCreated event
      const iface = p2p.interface;
      const log = receipt!.logs.find(l => {
        try { iface.parseLog(l as any); return true; } catch { return false; }
      });
      expect(log).to.not.be.undefined;

      const pendingIds = await p2p.getPendingRequests();
      expect(pendingIds.length).to.equal(1);
    });

    it("TC-SC-002: Reverts InsufficientCollateral when ETH sent < required", async () => {
      const { p2p, borrower, buildRequest } = await deployAll();
      const req = buildRequest();

      await expect(
        p2p.connect(borrower).createLoanRequest(req, {
          value: ethers.parseEther("0.001"), // way too small
        })
      ).to.be.revertedWithCustomError(p2p, "InsufficientCollateral");
    });

    it("TC-SC-003: Reverts TokenNotWhitelisted for non-whitelisted loan token", async () => {
      const { p2p, borrower, buildRequest } = await deployAll();
      const req = buildRequest({ loanToken: ethers.ZeroAddress }); // ETH as loan token — not whitelisted

      await expect(
        p2p.connect(borrower).createLoanRequest(req, { value: req.collateralAmount })
      ).to.be.revertedWithCustomError(p2p, "TokenNotWhitelisted");
    });

    it("TC-SC-004: Reverts MaxPendingRequestsReached after 3 pending requests", async () => {
      const { p2p, borrower, buildRequest } = await deployAll();
      const req = buildRequest();

      // Create 3 requests
      for (let i = 0; i < 3; i++) {
        await p2p.connect(borrower).createLoanRequest(req, { value: req.collateralAmount });
      }

      // 4th should revert
      await expect(
        p2p.connect(borrower).createLoanRequest(req, { value: req.collateralAmount })
      ).to.be.revertedWithCustomError(p2p, "MaxPendingRequestsReached");
    });

    it("TC-SC-005: Reverts with InvalidLoanParams when deadline is in the past", async () => {
      const { p2p, borrower, buildRequest } = await deployAll();
      const req = buildRequest({ deadline: BigInt(Math.floor(Date.now() / 1000) - 1) });

      await expect(
        p2p.connect(borrower).createLoanRequest(req, { value: req.collateralAmount })
      ).to.be.revertedWithCustomError(p2p, "InvalidLoanParams");
    });
  });

  // ══════════════════════════════════════════════════════
  // 2. LOAN FUNDING
  // ══════════════════════════════════════════════════════
  describe("2. Loan Funding", () => {

    async function createRequest() {
      const ctx = await deployAll();
      const req = ctx.buildRequest();
      const tx = await ctx.p2p.connect(ctx.borrower).createLoanRequest(req, { value: req.collateralAmount });
      await tx.wait();
      const ids = await ctx.p2p.getPendingRequests();
      return { ...ctx, requestId: ids[0], req };
    }

    it("TC-SC-006: Reverts CannotFundOwnLoan when borrower tries to fund own request", async () => {
      const { p2p, borrower, usdt, requestId } = await createRequest();
      await usdt.connect(borrower).mint(borrower.address, ethers.parseUnits("10000", 6));
      await usdt.connect(borrower).approve(await p2p.getAddress(), ethers.parseUnits("10000", 6));

      await expect(
        p2p.connect(borrower).fundLoanRequest(requestId)
      ).to.be.revertedWithCustomError(p2p, "CannotFundOwnLoan");
    });

    it("TC-SC-007: Successful funding deploys a Loan clone contract", async () => {
      const { p2p, lender, usdt, requestId } = await createRequest();
      await usdt.connect(lender).approve(await p2p.getAddress(), ethers.parseUnits("10000", 6));

      const tx = await p2p.connect(lender).fundLoanRequest(requestId);
      await tx.wait();

      const loanAddress = await p2p.requestToLoan(requestId);
      expect(loanAddress).to.not.equal(ethers.ZeroAddress);
    });

    it("TC-SC-008: Borrower receives principal after funding (minus platform fee)", async () => {
      const { p2p, lender, borrower, usdt, requestId, req } = await createRequest();
      await usdt.connect(lender).approve(await p2p.getAddress(), ethers.parseUnits("10000", 6));

      const borrowerBefore = await usdt.balanceOf(borrower.address);
      await p2p.connect(lender).fundLoanRequest(requestId);
      const borrowerAfter = await usdt.balanceOf(borrower.address);

      // Borrower should receive principal minus 1% platform fee
      const platformFee = await p2p.getPlatformFee(); // 100 basis points = 1%
      const fee = req.principal * platformFee / 10000n;
      const expected = req.principal - fee;
      expect(borrowerAfter - borrowerBefore).to.equal(expected);
    });
  });

  // ══════════════════════════════════════════════════════
  // 3. LOAN REPAYMENT
  // ══════════════════════════════════════════════════════
  describe("3. Loan Repayment", () => {

    async function createFundedLoan() {
      const ctx = await deployAll();
      const req = ctx.buildRequest();
      await ctx.p2p.connect(ctx.borrower).createLoanRequest(req, { value: req.collateralAmount });
      const ids = await ctx.p2p.getPendingRequests();
      const requestId = ids[0];
      await ctx.usdt.connect(ctx.lender).approve(await ctx.p2p.getAddress(), ethers.parseUnits("10000", 6));
      await ctx.p2p.connect(ctx.lender).fundLoanRequest(requestId);
      const loanAddress = await ctx.p2p.requestToLoan(requestId);
      const Loan = await ethers.getContractFactory("Loan");
      const loanContract = Loan.attach(loanAddress) as any;
      // Give borrower USDT to repay
      await ctx.usdt.mint(ctx.borrower.address, ethers.parseUnits("2000", 6));
      return { ...ctx, requestId, loanAddress, loanContract };
    }

    it("TC-SC-009: Non-borrower calling repay() reverts with Loan__OnlyBorrower", async () => {
      const { loanContract, lender, usdt } = await createFundedLoan();
      await usdt.connect(lender).approve(await loanContract.getAddress(), ethers.parseUnits("2000", 6));

      await expect(
        loanContract.connect(lender).repay()
      ).to.be.revertedWithCustomError(loanContract, "Loan__OnlyBorrower");
    });

    it("TC-SC-010: Successful repay transfers principal+interest to lender", async () => {
      const { loanContract, borrower, lender, usdt } = await createFundedLoan();
      const total = await loanContract.getTotalRepaymentAmount();
      await usdt.connect(borrower).approve(await loanContract.getAddress(), total + ethers.parseUnits("10", 6));

      const lenderBefore = await usdt.balanceOf(lender.address);
      await loanContract.connect(borrower).repay();
      const lenderAfter = await usdt.balanceOf(lender.address);

      expect(lenderAfter).to.be.gt(lenderBefore);
    });

    it("TC-SC-011: ETH collateral returned to borrower after repay", async () => {
      const { loanContract, borrower, usdt } = await createFundedLoan();
      const total = await loanContract.getTotalRepaymentAmount();
      await usdt.connect(borrower).approve(await loanContract.getAddress(), total + ethers.parseUnits("10", 6));

      const ethBefore = await ethers.provider.getBalance(borrower.address);
      const tx = await loanContract.connect(borrower).repay();
      const receipt = await tx.wait();
      const gasUsed = receipt!.gasUsed * receipt!.gasPrice;
      const ethAfter = await ethers.provider.getBalance(borrower.address);

      // Borrower gets ETH back (collateral) minus gas
      expect(ethAfter + gasUsed).to.be.gt(ethBefore);
    });

    it("TC-SC-012: Interest calculation: principal × rate × elapsed / (10000 × 365days)", async () => {
      const { loanContract } = await createFundedLoan();
      const details = await loanContract.getLoanDetails();
      const principal = details.principal;
      const rate = details.interestRate;

      // Advance 30 days
      await time.increase(30 * 24 * 3600);

      const total = await loanContract.getTotalRepaymentAmount();
      const breakdown = await loanContract.getRepaymentBreakdown();

      // Expected interest = principal × rate × 30days / (10000 × 365days)
      const expectedInterest = principal * rate * BigInt(30 * 24 * 3600) / (10000n * BigInt(365 * 24 * 3600));
      // Allow small rounding delta (1 unit)
      expect(breakdown.interest).to.be.closeTo(expectedInterest, 1n);
    });
  });

  // ══════════════════════════════════════════════════════
  // 4. LIQUIDATION
  // ══════════════════════════════════════════════════════
  describe("4. Liquidation", () => {

    async function createActiveLoan() {
      const ctx = await deployAll();
      const req = ctx.buildRequest({ duration: BigInt(7 * 24 * 3600) }); // 7-day loan
      await ctx.p2p.connect(ctx.borrower).createLoanRequest(req, { value: req.collateralAmount });
      const ids = await ctx.p2p.getPendingRequests();
      const requestId = ids[0];
      await ctx.usdt.connect(ctx.lender).approve(await ctx.p2p.getAddress(), ethers.parseUnits("10000", 6));
      await ctx.p2p.connect(ctx.lender).fundLoanRequest(requestId);
      return { ...ctx, requestId };
    }

    it("TC-SC-013: Cannot liquidate an active (non-overdue) loan", async () => {
      const { p2p, requestId, liquidator } = await createActiveLoan();

      await expect(
        p2p.connect(liquidator).liquidateLoan(requestId)
      ).to.be.reverted; // LoanNotActive or similar
    });

    it("TC-SC-014: Liquidation succeeds after loan endTime has passed", async () => {
      const { p2p, requestId, liquidator } = await createActiveLoan();

      // Advance past the 7-day loan duration
      await time.increase(8 * 24 * 3600);

      const tx = await p2p.connect(liquidator).liquidateLoan(requestId);
      const receipt = await tx.wait();
      expect(receipt!.status).to.equal(1);
    });
  });

  // ══════════════════════════════════════════════════════
  // 5. SECURITY TESTS
  // ══════════════════════════════════════════════════════
  describe("5. Security Tests", () => {

    it("TC-SEC-001: Pause stops createLoanRequest (whenNotPaused)", async () => {
      const { p2p, owner, borrower, buildRequest } = await deployAll();
      await p2p.connect(owner).pause();

      await expect(
        p2p.connect(borrower).createLoanRequest(buildRequest(), { value: ethers.parseEther("1") })
      ).to.be.revertedWithCustomError(p2p, "EnforcedPause");
    });

    it("TC-SEC-002: Admin timelock — oracle change requires 2-day delay", async () => {
      const { p2p, owner, oracle } = await deployAll();

      // Queue the change
      await p2p.connect(owner).queueOracleChange(await oracle.getAddress());

      // Attempt to execute immediately — should fail
      await expect(
        p2p.connect(owner).executeOracleChange()
      ).to.be.revertedWithCustomError(p2p, "TimelockNotExpired");

      // Advance 2 days
      await time.increase(2 * 24 * 3600 + 1);

      // Now should succeed
      await expect(p2p.connect(owner).executeOracleChange()).to.not.be.reverted;
    });

    it("TC-SEC-003: DebtToken is soulbound — transfer reverts with SoulboundToken", async () => {
      const { debtToken, owner, borrower, lender, p2p } = await deployAll();

      // Mint a debt token directly (owner authorised)
      await debtToken.connect(owner).setAuthorizedMinter(owner.address, true);
      const tokenId = await debtToken.connect(owner).mintDebtToken.staticCall(
        borrower.address, 1n, lender.address,
        ethers.parseUnits("1000", 6), ethers.parseUnits("1100", 6),
        "Default", ethers.ZeroAddress,
      );
      await debtToken.connect(owner).mintDebtToken(
        borrower.address, 1n, lender.address,
        ethers.parseUnits("1000", 6), ethers.parseUnits("1100", 6),
        "Default", ethers.ZeroAddress,
      );

      await expect(
        debtToken.connect(borrower).transferFrom(borrower.address, lender.address, 1n)
      ).to.be.revertedWithCustomError(debtToken, "SoulboundToken");
    });

    it("TC-SEC-004: Non-oracle-updater cannot update credit score", async () => {
      const { creditOracle, attacker, borrower } = await deployAll();

      await expect(
        creditOracle.connect(attacker).updateCreditScore(borrower.address, 900n)
      ).to.be.revertedWithCustomError(creditOracle, "NotOracleUpdater");
    });

    it("TC-SEC-005: Only owner can whitelist loan tokens", async () => {
      const { p2p, attacker } = await deployAll();

      await expect(
        p2p.connect(attacker).whitelistLoanToken(ethers.ZeroAddress, true)
      ).to.be.reverted; // OwnableUnauthorizedAccount
    });
  });

  // ══════════════════════════════════════════════════════
  // 6. ORACLE & CREDIT SCORE
  // ══════════════════════════════════════════════════════
  describe("6. Oracle & Credit Score", () => {

    it("TC-ORC-001: Stale price reverts getPriceSafe()", async () => {
      const { oracle, owner } = await deployAll();
      // Set maxPriceAge to 1 second
      await oracle.connect(owner).setMaxPriceAge(1n);
      // Advance 10 seconds so price becomes stale
      await time.increase(10);

      await expect(
        oracle.getPriceSafe(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(oracle, "PriceOracle__PriceStale");
    });

    it("TC-ORC-002: Credit score ≥ 800 → collateral ratio = 135% (13500 basis pts)", async () => {
      const { creditOracle, owner, borrower } = await deployAll();
      await creditOracle.connect(owner).updateCreditScore(borrower.address, 850n);

      const ratio = await creditOracle.getRequiredCollateralRatio(borrower.address);
      expect(ratio).to.equal(13500n);
    });

    it("TC-ORC-003: Credit score < 400 → collateral ratio = 190% (19000 basis pts)", async () => {
      const { creditOracle, owner, borrower } = await deployAll();
      await creditOracle.connect(owner).updateCreditScore(borrower.address, 350n);

      const ratio = await creditOracle.getRequiredCollateralRatio(borrower.address);
      expect(ratio).to.equal(19000n);
    });

    it("TC-ORC-004: No credit score → P2PLending uses default 150% collateral ratio", async () => {
      const { p2p, borrower } = await deployAll();

      const { ratio, hasScore } = await p2p.getCollateralRatioForBorrower(borrower.address);
      expect(hasScore).to.equal(false);
      expect(ratio).to.equal(15000n); // 150% default
    });

    it("TC-ORC-005: Dynamic collateral ratio applied when credit score exists on-chain", async () => {
      const { p2p, creditOracle, owner, borrower } = await deployAll();
      await creditOracle.connect(owner).updateCreditScore(borrower.address, 720n); // → 145%

      const { ratio, hasScore, score } = await p2p.getCollateralRatioForBorrower(borrower.address);
      expect(hasScore).to.equal(true);
      expect(ratio).to.equal(14500n);
    });
  });

  // ══════════════════════════════════════════════════════
  // 7. CANCEL LOAN REQUEST
  // ══════════════════════════════════════════════════════
  describe("7. Cancel Loan Request", () => {

    it("TC-SC-015: Borrower can cancel pending request and ETH collateral is returned", async () => {
      const { p2p, borrower, buildRequest } = await deployAll();
      const req = buildRequest();
      await p2p.connect(borrower).createLoanRequest(req, { value: req.collateralAmount });
      const ids = await p2p.getPendingRequests();
      const requestId = ids[0];

      const ethBefore = await ethers.provider.getBalance(borrower.address);
      const tx = await p2p.connect(borrower).cancelLoanRequest(requestId);
      const receipt = await tx.wait();
      const gas = receipt!.gasUsed * receipt!.gasPrice;
      const ethAfter = await ethers.provider.getBalance(borrower.address);

      expect(ethAfter + gas).to.be.closeTo(ethBefore + req.collateralAmount, ethers.parseEther("0.001"));
    });

    it("TC-SC-016: Non-borrower cannot cancel another user's request", async () => {
      const { p2p, borrower, attacker, buildRequest } = await deployAll();
      const req = buildRequest();
      await p2p.connect(borrower).createLoanRequest(req, { value: req.collateralAmount });
      const ids = await p2p.getPendingRequests();

      await expect(
        p2p.connect(attacker).cancelLoanRequest(ids[0])
      ).to.be.revertedWithCustomError(p2p, "NotRequestOwnerOrExpired");
    });
  });

  // ══════════════════════════════════════════════════════
  // 8. COLLATERAL MANAGER
  // ══════════════════════════════════════════════════════
  describe("8. CollateralManager", () => {

    it("TC-CM-001: Only authorised callers can deposit collateral", async () => {
      const { collateralMgr, attacker, borrower } = await deployAll();

      await expect(
        collateralMgr.connect(attacker).depositCollateral(
          1n, borrower.address, ethers.ZeroAddress, ethers.parseEther("1"),
          { value: ethers.parseEther("1") }
        )
      ).to.be.revertedWithCustomError(collateralMgr, "CM__Unauthorized");
    });
  });
});
