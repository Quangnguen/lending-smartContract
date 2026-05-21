/**
 * Deploy script cho Ganache Local
 * 
 * Cách chạy:
 * 1. Bật Ganache (GUI hoặc CLI: ganache --port 7545)
 * 2. npx hardhat run scripts/deploy-ganache.ts
 */

import { network } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

// ES module điều: __dirname không tồn tại, phải dùng import.meta.url
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Connect to Ganache network
const { ethers } = await network.connect({
  network: "ganache",
  chainType: "l1",
});

console.log("🚀 Bắt đầu deploy lên Ganache Local...\n");

const [deployer] = await ethers.getSigners();
console.log("📍 Deployer address:", deployer.address);

const balance = await ethers.provider.getBalance(deployer.address);
console.log("💰 Balance:", ethers.formatEther(balance), "ETH\n");

// ========== 1. Deploy MockUSDT ==========
console.log("1️⃣ Deploying MockUSDT...");
const mockUSDT = await ethers.deployContract("MockUSDT", [deployer.address]);
await mockUSDT.waitForDeployment();
const mockUSDTAddress = await mockUSDT.getAddress();
console.log("✅ MockUSDT deployed to:", mockUSDTAddress);

// ========== 2. Deploy MockPriceOracle ==========
console.log("\n2️⃣ Deploying MockPriceOracle...");
const priceOracle = await ethers.deployContract("MockPriceOracle", [deployer.address]);
await priceOracle.waitForDeployment();
const priceOracleAddress = await priceOracle.getAddress();
console.log("✅ MockPriceOracle deployed to:", priceOracleAddress);

// Set USDT price = $1
await priceOracle.setPrice(mockUSDTAddress, BigInt(1 * 10**8));
console.log("   ↳ Set USDT price to $1");

// ========== 3. Deploy CreditScoreOracle ==========
console.log("\n3️⃣ Deploying CreditScoreOracle...");
const creditScoreOracle = await ethers.deployContract("CreditScoreOracle", [
  deployer.address,   // owner
  deployer.address,   // oracleUpdater (demo: dùng chung deployer, production nên dùng ví riêng)
]);
await creditScoreOracle.waitForDeployment();
const creditScoreOracleAddress = await creditScoreOracle.getAddress();
console.log("✅ CreditScoreOracle deployed to:", creditScoreOracleAddress);
console.log("   ↳ Oracle Updater:", deployer.address);

// ========== 4. Deploy CollateralManager ==========
console.log("\n4️⃣ Deploying CollateralManager...");
const collateralManager = await ethers.deployContract("CollateralManager", [
  priceOracleAddress,
  deployer.address,
]);
await collateralManager.waitForDeployment();
const collateralManagerAddress = await collateralManager.getAddress();
console.log("✅ CollateralManager deployed to:", collateralManagerAddress);

// ========== 5. Deploy P2PLending ==========
console.log("\n5️⃣ Deploying P2PLending...");
// BUG FIX: constructor nay nhận 4 tham số: owner, collateralManager, priceOracle, debtToken
// DebtToken chưa deploy ở đây nên truyền address(0), set lại sau
const p2pLending = await ethers.deployContract("P2PLending", [
  deployer.address,
  collateralManagerAddress,
  priceOracleAddress,        // BUG 1 FIX: price oracle để validate collateral on-chain
  ethers.ZeroAddress,        // debtToken — set lại sau khi deploy DebtToken
]);
await p2pLending.waitForDeployment();
const p2pLendingAddress = await p2pLending.getAddress();
console.log("✅ P2PLending deployed to:", p2pLendingAddress);

// ── Setup P2PLending ──────────────────────────────────────────────────

// Whitelist USDT là loanToken (token cho vay)
await p2pLending.whitelistLoanToken(mockUSDTAddress, true);
console.log("   ↳ Whitelisted USDT as loanToken");

// Whitelist ETH (address(0)) là collateralToken
await p2pLending.whitelistCollateralToken(ethers.ZeroAddress, true);
console.log("   ↳ Whitelisted ETH as collateralToken");

// Set ETH price = $2000 trong MockPriceOracle (cần cho validate collateral)
await priceOracle.setPrice(ethers.ZeroAddress, BigInt(2000 * 10**8));
console.log("   ↳ Set ETH price to $2,000");

// Link CreditScoreOracle to P2PLending
await p2pLending.setCreditScoreOracle(creditScoreOracleAddress);
console.log("   ↳ Linked CreditScoreOracle to P2PLending");

// Thêm P2PLending làm authorized caller của CollateralManager TRƯỚC khi transfer ownership
// (Vì sau transferOwnership thì deployer không còn quyền gọi setAuthorizedCaller)
await collateralManager.setAuthorizedCaller(p2pLendingAddress, true);
console.log("   ↳ P2PLending added as authorized caller of CollateralManager");

// Transfer ownership của CollateralManager sang P2PLending
await collateralManager.transferOwnership(p2pLendingAddress);
console.log("   ↳ Transferred ownership of CollateralManager to P2PLending");


// ========== 6. Deploy DebtToken (ERC-721 Soulbound) ==========
console.log("\n6️⃣ Deploying DebtToken (Soulbound NFT)...");
const debtToken = await ethers.deployContract("DebtToken", [deployer.address]);
await debtToken.waitForDeployment();
const debtTokenAddress = await debtToken.getAddress();
console.log("✅ DebtToken deployed to:", debtTokenAddress);

// DEBT FIX: Set P2PLending là authorized minter (để mint khi liquidate)
await debtToken.setAuthorizedMinter(p2pLendingAddress, true);
console.log("   ↳ P2PLending set as authorized minter for DebtToken");

// DEBT FIX: Wire DebtToken vào P2PLending (đã deploy ở trên với address(0))
await p2pLending.setDebtToken(debtTokenAddress);
console.log("   ↳ DebtToken wired into P2PLending");

// ========== 7. Test: Set demo credit score ==========
console.log("\n7️⃣ Setting demo credit scores...");

// Set score 750 (VERY_GOOD → 80% collateral) cho deployer
await creditScoreOracle.updateCreditScore(deployer.address, 750);
console.log(`   ↳ Set score 750 (VERY_GOOD) for ${deployer.address}`);

// Verify score on-chain
const [score, , isValid] = await creditScoreOracle.getCreditScore(deployer.address);
const ratio = await creditScoreOracle.getRequiredCollateralRatio(deployer.address);
console.log(`   ↳ Verified on-chain: Score=${score}, Valid=${isValid}, CollateralRatio=${Number(ratio)/100}%`);

// Verify P2PLending reads from Oracle
const [p2pRatio, p2pScore, p2pHasScore] = await p2pLending.getCollateralRatioForBorrower(deployer.address);
console.log(`   ↳ P2PLending reads: Ratio=${Number(p2pRatio)/100}%, Score=${p2pScore}, HasScore=${p2pHasScore}`);

// ========== 8. Mint test USDT cho các account ==========
console.log("\n8️⃣ Minting test USDT...");
const signers = await ethers.getSigners();
const mintAmount = ethers.parseUnits("100000", 6); // 100k USDT (6 decimals)

// Mint cho 5 accounts đầu tiên
for (let i = 0; i < Math.min(5, signers.length); i++) {
  await mockUSDT.mint(signers[i].address, mintAmount);
  console.log(`   ↳ Minted 100,000 USDT to Account #${i}: ${signers[i].address}`);
}

// ========== Summary ==========
console.log("\n" + "=".repeat(55));
console.log("📋 GANACHE DEPLOYMENT SUMMARY");
console.log("=".repeat(55));
console.log(`Network:             Ganache Local (127.0.0.1:7545)`);
console.log(`Chain ID:            1337`);
console.log(`Deployer:            ${deployer.address}`);
console.log("-".repeat(55));
console.log(`MockUSDT:            ${mockUSDTAddress}`);
console.log(`MockPriceOracle:     ${priceOracleAddress}`);
console.log(`CreditScoreOracle:   ${creditScoreOracleAddress}`);
console.log(`DebtToken:           ${debtTokenAddress}`);
console.log(`CollateralManager:   ${collateralManagerAddress}`);
console.log(`P2PLending:          ${p2pLendingAddress}`);
console.log("=".repeat(55));

// ========== Auto-update .env files ==========
console.log("\n📝 Cập nhật .env files...");

// Update lending-contracts/.env
const contractsEnvPath = path.resolve(__dirname, "../.env");
let contractsEnv = fs.readFileSync(contractsEnvPath, "utf-8");
contractsEnv = contractsEnv
  .replace(/MOCKUSDT_ADDRESS=.*/,           `MOCKUSDT_ADDRESS=${mockUSDTAddress}`)
  .replace(/PRICE_ORACLE_ADDRESS=.*/,       `PRICE_ORACLE_ADDRESS=${priceOracleAddress}`)
  .replace(/COLLATERAL_MANAGER_ADDRESS=.*/,  `COLLATERAL_MANAGER_ADDRESS=${collateralManagerAddress}`)
  .replace(/P2P_LENDING_ADDRESS=.*/,        `P2P_LENDING_ADDRESS=${p2pLendingAddress}`);

// Thêm CreditScoreOracle nếu chưa có
if (contractsEnv.includes('CREDIT_SCORE_ORACLE_ADDRESS=')) {
  contractsEnv = contractsEnv.replace(/CREDIT_SCORE_ORACLE_ADDRESS=.*/, `CREDIT_SCORE_ORACLE_ADDRESS=${creditScoreOracleAddress}`);
} else {
  contractsEnv += `\nCREDIT_SCORE_ORACLE_ADDRESS=${creditScoreOracleAddress}\n`;
}
// Thêm DebtToken nếu chưa có
if (contractsEnv.includes('DEBT_TOKEN_ADDRESS=')) {
  contractsEnv = contractsEnv.replace(/DEBT_TOKEN_ADDRESS=.*/, `DEBT_TOKEN_ADDRESS=${debtTokenAddress}`);
} else {
  contractsEnv += `DEBT_TOKEN_ADDRESS=${debtTokenAddress}\n`;
}
fs.writeFileSync(contractsEnvPath, contractsEnv);
console.log("   ✅ Updated lending-contracts/.env");

// Update Lending-BE/.env
const beEnvPath = path.resolve(__dirname, "../../Lending-BE/.env");
if (fs.existsSync(beEnvPath)) {
  let beEnv = fs.readFileSync(beEnvPath, "utf-8");
  beEnv = beEnv
    .replace(/P2P_LENDING_ADDRESS=.*/,        `P2P_LENDING_ADDRESS=${p2pLendingAddress}`)
    .replace(/MOCKUSDT_ADDRESS=.*/,           `MOCKUSDT_ADDRESS=${mockUSDTAddress}`)
    .replace(/PRICE_ORACLE_ADDRESS=.*/,       `PRICE_ORACLE_ADDRESS=${priceOracleAddress}`)
    .replace(/COLLATERAL_MANAGER_ADDRESS=.*/,  `COLLATERAL_MANAGER_ADDRESS=${collateralManagerAddress}`);

  // Thêm CreditScoreOracle + Oracle key nếu chưa có
  if (beEnv.includes('CREDIT_SCORE_ORACLE_ADDRESS=')) {
    beEnv = beEnv.replace(/CREDIT_SCORE_ORACLE_ADDRESS=.*/, `CREDIT_SCORE_ORACLE_ADDRESS=${creditScoreOracleAddress}`);
  } else {
    beEnv += `\n# Credit Score Oracle\nCREDIT_SCORE_ORACLE_ADDRESS=${creditScoreOracleAddress}\n`;
  }

  // Thêm DebtToken
  if (beEnv.includes('DEBT_TOKEN_ADDRESS=')) {
    beEnv = beEnv.replace(/DEBT_TOKEN_ADDRESS=.*/, `DEBT_TOKEN_ADDRESS=${debtTokenAddress}`);
  } else {
    beEnv += `DEBT_TOKEN_ADDRESS=${debtTokenAddress}\n`;
  }

  fs.writeFileSync(beEnvPath, beEnv);
  console.log("   ✅ Updated Lending-BE/.env");
}


// ========== Auto-update P2PLendingApp/src/config/walletconnect.ts ==========
console.log("\n📱 Cập nhật walletconnect.ts...");
const walletconnectPath = path.resolve(__dirname, "../../P2PLendingApp/src/config/walletconnect.ts");

if (fs.existsSync(walletconnectPath)) {
  let wcContent = fs.readFileSync(walletconnectPath, "utf-8");

  // Thay thế toàn bộ block CONTRACT_ADDRESSES bằng regex
  // Pattern này match từ "export const CONTRACT_ADDRESSES = {" đến closing "}"
  const contractAddressesBlock = `export const CONTRACT_ADDRESSES = {
  USDT:                '${mockUSDTAddress}',
  PRICE_ORACLE:        '${priceOracleAddress}',
  CREDIT_SCORE_ORACLE: '${creditScoreOracleAddress}',
  DEBT_TOKEN:          '${debtTokenAddress}',
  COLLATERAL_MANAGER:  '${collateralManagerAddress}',
  P2P_LENDING:         '${p2pLendingAddress}',
};`;

  // Regex: match từ "export const CONTRACT_ADDRESSES" đến "}" trên dòng riêng
  const contractAddressesRegex = /export const CONTRACT_ADDRESSES\s*=\s*\{[\s\S]*?\};/;

  if (contractAddressesRegex.test(wcContent)) {
    wcContent = wcContent.replace(contractAddressesRegex, contractAddressesBlock);
    fs.writeFileSync(walletconnectPath, wcContent, "utf-8");
    console.log("   ✅ Updated P2PLendingApp/src/config/walletconnect.ts");
  } else {
    // Không tìm thấy block → append ở cuối (fallback)
    wcContent += `\n${contractAddressesBlock}\n`;
    fs.writeFileSync(walletconnectPath, wcContent, "utf-8");
    console.log("   ✅ Appended CONTRACT_ADDRESSES to walletconnect.ts (block not found, appended)");
  }
} else {
  console.log("   ⚠️  walletconnect.ts not found at:", walletconnectPath);
  console.log("       Manually update CONTRACT_ADDRESSES with:");
  console.log(`       USDT: '${mockUSDTAddress}'`);
  console.log(`       PRICE_ORACLE: '${priceOracleAddress}'`);
  console.log(`       CREDIT_SCORE_ORACLE: '${creditScoreOracleAddress}'`);
  console.log(`       DEBT_TOKEN: '${debtTokenAddress}'`);
  console.log(`       COLLATERAL_MANAGER: '${collateralManagerAddress}'`);
  console.log(`       P2P_LENDING: '${p2pLendingAddress}'`);
}

console.log("\n🎉 Deploy hoàn tất! Ganache đã sẵn sàng.");
console.log("   ↳ CreditScoreOracle đã được link với P2PLending");
console.log("   ↳ DebtToken (Soulbound NFT) đã deploy cho ghi nhận nợ xấu");
console.log("   ↳ Demo score 750 (VERY_GOOD, 80% collateral) đã set cho deployer");
console.log("   ↳ walletconnect.ts đã được auto-update ✅");
