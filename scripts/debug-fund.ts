/**
 * Debug script: Mô phỏng luồng Fund Loan trực tiếp trên Hardhat v3
 * Chạy: npx hardhat run scripts/debug-fund.ts
 */

import { network } from 'hardhat';
import * as dotenv from 'dotenv';
dotenv.config();

// Connect Ganache
const { ethers } = await network.connect({
  network: 'ganache',
  chainType: 'l1',
});

const P2P_LENDING = process.env.P2P_LENDING_ADDRESS!;
const USDT = process.env.MOCKUSDT_ADDRESS!;  // <-- Fixed: MOCKUSDT_ADDRESS

if (!P2P_LENDING || !USDT) {
  console.error('❌ Thiếu biến môi trường P2P_LENDING_ADDRESS hoặc MOCKUSDT_ADDRESS trong .env');
  process.exit(1);
}

const signers = await ethers.getSigners();
console.log('🔍 DEBUG FUND LOAN');
console.log('P2PLending :', P2P_LENDING);
console.log('USDT       :', USDT);
console.log('Số signers :', signers.length);

const borrower = signers[0]; // Ví #0 - Borrower (deployer)
// Dùng ví #1 hoặc ví cuối làm Lender
const lender = signers[1] ?? signers[0];
console.log('Borrower (Ví#0):', borrower.address);
console.log('Lender   (Ví#1):', lender.address);
console.log('---');

const p2pAbi = [
  'function requestActive(uint256) view returns (bool)',
  'function requestBorrower(uint256) view returns (address)',
  'function loanRequests(uint256) view returns (address loanToken, address collateralToken, uint256 principal, uint256 interestRate, uint256 collateralAmount, uint256 duration)',
  'function fundLoanRequest(uint256 requestId) returns (address)',
  'function nextRequestId() view returns (uint256)',
];
const usdtAbi = [
  'function balanceOf(address) view returns (uint256)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function approve(address spender, uint256 amount) returns (bool)',
];

const p2pAsLender = new ethers.Contract(P2P_LENDING, p2pAbi, lender);
const usdtAsLender = new ethers.Contract(USDT, usdtAbi, lender);

// 1. Kiểm tra các requestId đang active
const nextId = await p2pAsLender.nextRequestId();
console.log('\n📊 nextRequestId (hợp đồng hiện tại):', nextId.toString());

let targetId = -1;
for (let id = 1; id < Number(nextId); id++) {
  const active = await p2pAsLender.requestActive(id);
  const reqBorrower = await p2pAsLender.requestBorrower(id);
  const req = await p2pAsLender.loanRequests(id);
  const principalFormatted = ethers.formatUnits(req.principal, 6);
  console.log(`\nRequest #${id}: active=${active}, borrower=${reqBorrower}`);
  console.log(`  loanToken : ${req.loanToken}`);
  console.log(`  principal : ${principalFormatted} USDT`);
  console.log(`  collateral: ${ethers.formatEther(req.collateralAmount)} ETH`);
  if (active && targetId === -1) targetId = id;
}

if (targetId === -1) {
  console.log('\n❌ Không có request nào đang active!');
  console.log('👉 Hãy tạo một yêu cầu vay mới từ App trước, rồi chạy lại script này.');
  process.exit(0);
}

console.log(`\n🎯 Fund Request #${targetId} | Lender: ${lender.address}`);
const req = await p2pAsLender.loanRequests(targetId);
const principal = req.principal;

// 2. Kiểm tra token match
console.log('\n--- Kiểm tra token match ---');
console.log('req.loanToken (stored in contract):', req.loanToken);
console.log('MOCKUSDT_ADDRESS (env)            :', USDT);
const tokenMatch = req.loanToken.toLowerCase() === USDT.toLowerCase();
console.log('Match?', tokenMatch ? '✅ YES' : '❌ NO - Dữ liệu cũ trên contract mới, cần tạo request mới!');

if (!tokenMatch) {
  console.log('\n❌ Token mismatch! Request này được tạo với USDT address CŨ.');
  console.log('Hãy tạo một yêu cầu vay MỚI HOÀN TOÀN từ App sau khi deploy lại.');
  process.exit(1);
}

// 3. Kiểm tra balance & allowance
const lenderBalance = await usdtAsLender.balanceOf(lender.address);
const currentAllowance = await usdtAsLender.allowance(lender.address, P2P_LENDING);
console.log('\n--- Kiểm tra balance & allowance ---');
console.log('Lender USDT Balance :', ethers.formatUnits(lenderBalance, 6));
console.log('Current Allowance   :', ethers.formatUnits(currentAllowance, 6));
console.log('Required (principal):', ethers.formatUnits(principal, 6));

if (lenderBalance < principal) {
  console.log('❌ Không đủ USDT!');
  process.exit(1);
}

// 4. Approve
console.log('\n⏳ Approving USDT...');
const approveTx = await usdtAsLender.approve(P2P_LENDING, principal);
await approveTx.wait();
const newAllowance = await usdtAsLender.allowance(lender.address, P2P_LENDING);
console.log('✅ Approved! New allowance:', ethers.formatUnits(newAllowance, 6));

// 5. Static call để lấy lý do revert
console.log('\n⏳ Static call fundLoanRequest để kiểm tra lỗi...');
try {
  const result = await p2pAsLender.fundLoanRequest.staticCall(targetId, { gasLimit: 2000000 });
  console.log('✅ Static call THÀNH CÔNG! Loan contract sẽ deploy tại:', result);
} catch (staticErr: any) {
  console.log('❌ Static call THẤT BẠI!');
  console.log('Reason:', staticErr.reason || staticErr.shortMessage || staticErr.message?.slice(0, 500));
  process.exit(1);
}

// 6. Gửi giao dịch thật
console.log('\n⏳ Sending real fundLoanRequest tx...');
try {
  const fundTx = await p2pAsLender.fundLoanRequest(targetId, { gasLimit: 2000000 });
  const receipt = await fundTx.wait();
  console.log('🎉 FUND SUCCESS! TX:', fundTx.hash);
  console.log('Gas used:', receipt.gasUsed.toString());
} catch (err: any) {
  console.log('❌ Fund FAILED:', err.reason || err.shortMessage || err.message?.slice(0, 300));
}
