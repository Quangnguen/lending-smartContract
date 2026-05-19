/**
 * Mint USDT cho các ví Ganache
 * 
 * Cách chạy:
 *   npx hardhat run scripts/mint-usdt.ts
 * 
 * Chỉnh danh sách RECIPIENTS bên dưới để thêm/bớt địa chỉ cần mint
 */

import { network } from "hardhat";
import * as dotenv from "dotenv";
dotenv.config();

const { ethers } = await network.connect({
  network: "ganache",
  chainType: "l1",
});

// ============================================================
// ⚙️  CẤU HÌNH: Thêm/bớt địa chỉ tại đây
// ============================================================
const RECIPIENTS = [
  { address: "0x0BA0aF86A2D23e59D002c7084F77F4E4049F5D6C", label: "Account #0 — Deployer" },
  { address: "0x45a978d98f3DFC61b334DAd3ffb3c35b10E314A0", label: "Account #1" },
  { address: "0xC86196DD31B318477813e04D49AC3c301A138389", label: "Account #2" },
  { address: "0x61559dbF48ef6632FdDaA5bad982365b254f1639", label: "Account #3" },
  { address: "0xef81849927B8195D8626B743A88d1911Fc50575F", label: "Account #4" },
];

const MINT_AMOUNT_USDT = "100000"; // 100,000 USDT mỗi ví
// ============================================================

const MOCKUSDT_ADDRESS = process.env.MOCKUSDT_ADDRESS;
if (!MOCKUSDT_ADDRESS) {
  throw new Error("❌ MOCKUSDT_ADDRESS chưa được set trong .env");
}

// ABI tối thiểu cần dùng
const USDT_ABI = [
  "function mint(address to, uint256 amount) external",
  "function balanceOf(address account) external view returns (uint256)",
  "function decimals() external view returns (uint8)",
  "function symbol() external view returns (string)",
];

const [deployer] = await ethers.getSigners();
console.log("🚀 Mint USDT script");
console.log("📍 Deployer (minter):", deployer.address);
console.log("📋 MockUSDT:", MOCKUSDT_ADDRESS);
console.log("");

const usdt = new ethers.Contract(MOCKUSDT_ADDRESS, USDT_ABI, deployer);
const decimals = await usdt.decimals();
const symbol = await usdt.symbol();
const mintAmount = ethers.parseUnits(MINT_AMOUNT_USDT, decimals);

console.log(`💰 Mint ${MINT_AMOUNT_USDT} ${symbol} (${decimals} decimals) cho ${RECIPIENTS.length} ví:\n`);

for (const { address, label } of RECIPIENTS) {
  try {
    const balanceBefore = await usdt.balanceOf(address);
    
    // Chỉ mint nếu chưa đủ số dư
    if (balanceBefore >= mintAmount) {
      console.log(`⏭  ${label} (${address})`);
      console.log(`   Đã có ${ethers.formatUnits(balanceBefore, decimals)} ${symbol} — bỏ qua\n`);
      continue;
    }

    const tx = await usdt.mint(address, mintAmount);
    await tx.wait();

    const balanceAfter = await usdt.balanceOf(address);
    console.log(`✅ ${label}`);
    console.log(`   Address: ${address}`);
    console.log(`   Balance: ${ethers.formatUnits(balanceAfter, decimals)} ${symbol}\n`);
  } catch (err: any) {
    console.error(`❌ Lỗi mint cho ${label} (${address}): ${err.message}\n`);
  }
}

console.log("🎉 Mint USDT hoàn tất!");
