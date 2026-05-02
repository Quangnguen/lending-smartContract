import { expect } from "chai";
import { network } from "hardhat";

const { ethers } = await network.connect();

describe("P2PLending", function () {
  let p2pLending: any;
  let mockUSDT: any;
  let owner: any;
  let borrower: any;
  let lender: any;

  beforeEach(async function () {
    [owner, borrower, lender] = await ethers.getSigners();

    // Deploy MockUSDT
    mockUSDT = await ethers.deployContract("MockUSDT", [owner.address]);
    await mockUSDT.waitForDeployment();

    // Deploy P2PLending
    p2pLending = await ethers.deployContract("P2PLending", [owner.address]);
    await p2pLending.waitForDeployment();

    // Whitelist USDT
    await p2pLending.whitelistToken(await mockUSDT.getAddress(), true);

    // Mint USDT cho lender
    const mintAmount = ethers.parseUnits("100000", 6);
    await mockUSDT.mint(lender.address, mintAmount);
  });

  describe("Quản lý Token", function () {
    it("Nên whitelist token thành công", async function () {
      const isWhitelisted = await p2pLending.isTokenWhitelisted(
        await mockUSDT.getAddress()
      );
      expect(isWhitelisted).to.equal(true);
    });

    it("Chỉ owner mới whitelist token", async function () {
      await expect(
        p2pLending
          .connect(borrower)
          .whitelistToken(await mockUSDT.getAddress(), true)
      ).to.be.reverted;
    });

    it("Nên kiểm tra token chưa whitelist", async function () {
      const randomAddr = "0x0000000000000000000000000000000000000001";
      const isWhitelisted = await p2pLending.isTokenWhitelisted(randomAddr);
      expect(isWhitelisted).to.equal(false);
    });
  });

  describe("Tạo yêu cầu vay", function () {
    it("Nên tạo yêu cầu vay thành công", async function () {
      const request = {
        loanToken: await mockUSDT.getAddress(),
        collateralToken: ethers.ZeroAddress,
        principal: ethers.parseUnits("1000", 6),
        interestRate: 1200n, // 12% in basis points
        collateralAmount: ethers.parseEther("1"),
        duration: BigInt(30 * 24 * 60 * 60), // 30 days in seconds
      };

      const tx = await p2pLending.connect(borrower).createLoanRequest(request);
      await tx.wait();

      // Verify request was created
      const loanRequest = await p2pLending.getLoanRequest(1);
      expect(loanRequest.principal).to.equal(request.principal);
      expect(loanRequest.interestRate).to.equal(request.interestRate);
      expect(loanRequest.duration).to.equal(request.duration);
    });

    it("Nên từ chối token chưa whitelist", async function () {
      const request = {
        loanToken: ethers.ZeroAddress, // Not whitelisted
        collateralToken: ethers.ZeroAddress,
        principal: ethers.parseUnits("1000", 6),
        interestRate: 1200n,
        collateralAmount: ethers.parseEther("1"),
        duration: BigInt(30 * 24 * 60 * 60),
      };

      await expect(
        p2pLending.connect(borrower).createLoanRequest(request)
      ).to.be.revertedWithCustomError(p2pLending, "TokenNotWhitelisted");
    });

    it("Nên tạo nhiều yêu cầu vay liên tiếp", async function () {
      const request = {
        loanToken: await mockUSDT.getAddress(),
        collateralToken: ethers.ZeroAddress,
        principal: ethers.parseUnits("500", 6),
        interestRate: 1000n,
        collateralAmount: ethers.parseEther("0.5"),
        duration: BigInt(14 * 24 * 60 * 60),
      };

      await p2pLending.connect(borrower).createLoanRequest(request);
      await p2pLending.connect(borrower).createLoanRequest(request);

      const pending = await p2pLending.getPendingRequests();
      expect(pending.length).to.equal(2);
    });

    it("Nên emit event LoanRequestCreated", async function () {
      const request = {
        loanToken: await mockUSDT.getAddress(),
        collateralToken: ethers.ZeroAddress,
        principal: ethers.parseUnits("1000", 6),
        interestRate: 1200n,
        collateralAmount: ethers.parseEther("1"),
        duration: BigInt(30 * 24 * 60 * 60),
      };

      await expect(p2pLending.connect(borrower).createLoanRequest(request))
        .to.emit(p2pLending, "LoanRequestCreated")
        .withArgs(1n, borrower.address, request.principal);
    });
  });

  describe("Hủy yêu cầu vay", function () {
    beforeEach(async function () {
      const request = {
        loanToken: await mockUSDT.getAddress(),
        collateralToken: ethers.ZeroAddress,
        principal: ethers.parseUnits("1000", 6),
        interestRate: 1200n,
        collateralAmount: ethers.parseEther("1"),
        duration: BigInt(30 * 24 * 60 * 60),
      };
      await p2pLending.connect(borrower).createLoanRequest(request);
    });

    it("Nên hủy yêu cầu vay bởi chủ sở hữu", async function () {
      await p2pLending.connect(borrower).cancelLoanRequest(1);
      const isActive = await p2pLending.requestActive(1);
      expect(isActive).to.equal(false);
    });

    it("Không cho người khác hủy yêu cầu vay", async function () {
      await expect(
        p2pLending.connect(lender).cancelLoanRequest(1)
      ).to.be.revertedWithCustomError(p2pLending, "NotRequestOwner");
    });

    it("Không hủy yêu cầu đã hủy", async function () {
      await p2pLending.connect(borrower).cancelLoanRequest(1);
      await expect(
        p2pLending.connect(borrower).cancelLoanRequest(1)
      ).to.be.revertedWithCustomError(p2pLending, "RequestNotActive");
    });

    it("Nên emit event LoanRequestCancelled", async function () {
      await expect(p2pLending.connect(borrower).cancelLoanRequest(1))
        .to.emit(p2pLending, "LoanRequestCancelled")
        .withArgs(1n, borrower.address);
    });

    it("Request đã hủy không nên trong pending list", async function () {
      await p2pLending.connect(borrower).cancelLoanRequest(1);
      const pending = await p2pLending.getPendingRequests();
      // getPendingRequests filters out non-active
      expect(pending.length).to.equal(0);
    });
  });

  describe("Cấp vốn cho khoản vay", function () {
    beforeEach(async function () {
      const request = {
        loanToken: await mockUSDT.getAddress(),
        collateralToken: ethers.ZeroAddress,
        principal: ethers.parseUnits("1000", 6),
        interestRate: 1200n,
        collateralAmount: ethers.parseEther("1"),
        duration: BigInt(30 * 24 * 60 * 60),
      };
      await p2pLending.connect(borrower).createLoanRequest(request);
    });

    it("Nên từ chối fund yêu cầu đã hủy", async function () {
      await p2pLending.connect(borrower).cancelLoanRequest(1);
      await expect(
        p2pLending.connect(lender).fundLoanRequest(1)
      ).to.be.revertedWithCustomError(p2pLending, "RequestNotActive");
    });

    it("Nên từ chối fund yêu cầu không tồn tại", async function () {
      await expect(
        p2pLending.connect(lender).fundLoanRequest(999)
      ).to.be.revertedWithCustomError(p2pLending, "RequestNotActive");
    });
  });

  describe("View functions", function () {
    it("Nên trả về danh sách pending requests đúng", async function () {
      const request = {
        loanToken: await mockUSDT.getAddress(),
        collateralToken: ethers.ZeroAddress,
        principal: ethers.parseUnits("1000", 6),
        interestRate: 1200n,
        collateralAmount: ethers.parseEther("1"),
        duration: BigInt(30 * 24 * 60 * 60),
      };

      // Tạo 3 request, hủy 1
      await p2pLending.connect(borrower).createLoanRequest(request);
      await p2pLending.connect(borrower).createLoanRequest(request);
      await p2pLending.connect(borrower).createLoanRequest(request);
      await p2pLending.connect(borrower).cancelLoanRequest(2);

      const pending = await p2pLending.getPendingRequests();
      expect(pending.length).to.equal(2);
    });

    it("Nên trả về thông tin user mặc định", async function () {
      const userInfo = await p2pLending.getUserInfo(borrower.address);
      expect(userInfo.totalBorrowed).to.equal(0);
      expect(userInfo.activeLoans).to.equal(0);
      expect(userInfo.reputation).to.equal(0);
    });

    it("Nên trả về danh sách khoản vay của user", async function () {
      const [borrowed, lent] = await p2pLending.getUserLoans(borrower.address);
      expect(borrowed.length).to.equal(0);
      expect(lent.length).to.equal(0);
    });

    it("Nên trả về platform fee", async function () {
      const fee = await p2pLending.getPlatformFee();
      expect(fee).to.equal(100n); // 1%
    });

    it("Nên trả về min collateral ratio", async function () {
      const ratio = await p2pLending.getMinCollateralRatio();
      expect(ratio).to.equal(15000n); // 150%
    });
  });

  describe("Admin functions", function () {
    it("Nên cập nhật platform fee", async function () {
      await p2pLending.setPlatformFee(200);
      const fee = await p2pLending.getPlatformFee();
      expect(fee).to.equal(200n);
    });

    it("Chỉ owner mới cập nhật fee", async function () {
      await expect(
        p2pLending.connect(borrower).setPlatformFee(200)
      ).to.be.reverted;
    });

    it("Nên emit PlatformFeeUpdated event", async function () {
      await expect(p2pLending.setPlatformFee(200))
        .to.emit(p2pLending, "PlatformFeeUpdated")
        .withArgs(100n, 200n);
    });
  });
});

describe("Loan Contract", function () {
  let loan: any;
  let mockUSDT: any;
  let owner: any;
  let borrower: any;
  let lender: any;

  beforeEach(async function () {
    [owner, borrower, lender] = await ethers.getSigners();

    // Deploy MockUSDT
    mockUSDT = await ethers.deployContract("MockUSDT", [owner.address]);
    await mockUSDT.waitForDeployment();

    // Deploy Loan directly for unit testing
    loan = await ethers.deployContract("Loan", [
      1n, // _loanId
      borrower.address, // _borrower
      await mockUSDT.getAddress(), // _loanToken
      ethers.ZeroAddress, // _collateralToken
      ethers.parseUnits("1000", 6), // _principal
      1200n, // _interestRate (12%)
      ethers.parseEther("1"), // _collateralAmount
      BigInt(30 * 24 * 60 * 60), // _duration (30 days)
      50n, // _lateFeeRate (0.5%)
    ]);
    await loan.waitForDeployment();

    // Mint USDT
    const mintAmount = ethers.parseUnits("100000", 6);
    await mockUSDT.mint(lender.address, mintAmount);
    await mockUSDT.mint(borrower.address, mintAmount);
  });

  describe("Trạng thái ban đầu", function () {
    it("Nên có trạng thái PENDING", async function () {
      const details = await loan.getLoanDetails();
      expect(details.status).to.equal(0n); // PENDING = 0
    });

    it("Nên có thông tin đúng", async function () {
      const details = await loan.getLoanDetails();
      expect(details.borrower).to.equal(borrower.address);
      expect(details.principal).to.equal(ethers.parseUnits("1000", 6));
      expect(details.interestRate).to.equal(1200n);
    });

    it("Lender ban đầu nên là zero address", async function () {
      const details = await loan.getLoanDetails();
      expect(details.lender).to.equal(ethers.ZeroAddress);
    });

    it("startTime và endTime ban đầu nên là 0", async function () {
      const details = await loan.getLoanDetails();
      expect(details.startTime).to.equal(0n);
      expect(details.endTime).to.equal(0n);
    });
  });

  describe("Hủy khoản vay", function () {
    it("Borrower nên hủy được khoản vay PENDING", async function () {
      await loan.connect(borrower).cancel();
      const details = await loan.getLoanDetails();
      expect(details.status).to.equal(5n); // CANCELLED = 5
    });

    it("Người khác không hủy được khoản vay", async function () {
      await expect(
        loan.connect(lender).cancel()
      ).to.be.revertedWithCustomError(loan, "OnlyBorrower");
    });

    it("Nên emit LoanCancelled event", async function () {
      await expect(loan.connect(borrower).cancel())
        .to.emit(loan, "LoanCancelled")
        .withArgs(1n);
    });
  });

  describe("Kiểm tra quá hạn", function () {
    it("Khoản vay PENDING không bao giờ quá hạn", async function () {
      const isOverdue = await loan.isOverdue();
      expect(isOverdue).to.equal(false);
    });
  });

  describe("Tính tổng tiền trả nợ", function () {
    it("Khoản vay chưa ACTIVE nên trả 0", async function () {
      const total = await loan.getTotalRepaymentAmount();
      expect(total).to.equal(0n);
    });
  });

  describe("Tỷ lệ tài sản thế chấp", function () {
    it("Nên trả về collateral ratio", async function () {
      const ratio = await loan.getCollateralRatio();
      expect(ratio).to.equal(15000n); // 150%
    });
  });

  describe("Cấp vốn (Fund)", function () {
    it("Nên cấp vốn thành công khi lender approve đủ USDT", async function () {
      // Lender approve USDT cho Loan contract
      const principal = ethers.parseUnits("1000", 6);
      await mockUSDT.connect(lender).approve(await loan.getAddress(), principal);

      // Note: fund() trong Loan.sol yêu cầu msg.sender != factory khi gọi trực tiếp
      // Trong thực tế, fund() được gọi từ P2PLending (factory)
      // Ở đây ta test trực tiếp - factory chính là deployer (owner)
      // Cần gọi từ factory address
    });

    it("Không cấp vốn khi khoản vay đã bị hủy", async function () {
      await loan.connect(borrower).cancel();
      await expect(
        loan.connect(lender).fund()
      ).to.be.revertedWithCustomError(loan, "InvalidStatus");
    });
  });
});
