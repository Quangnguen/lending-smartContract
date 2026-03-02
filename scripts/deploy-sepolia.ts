import { network } from "hardhat";

// Connect to Sepolia network
const { ethers } = await network.connect({
  network: "sepolia",
  chainType: "l1",
});

console.log("🚀 Bắt đầu deploy lên Sepolia...\n");

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

// ========== 3. Deploy CollateralManager ==========
console.log("\n3️⃣ Deploying CollateralManager...");
const collateralManager = await ethers.deployContract("CollateralManager", [
  priceOracleAddress,
  deployer.address
]);
await collateralManager.waitForDeployment();
const collateralManagerAddress = await collateralManager.getAddress();
console.log("✅ CollateralManager deployed to:", collateralManagerAddress);

// ========== 4. Deploy P2PLending ==========
console.log("\n4️⃣ Deploying P2PLending...");
const p2pLending = await ethers.deployContract("P2PLending", [deployer.address]);
await p2pLending.waitForDeployment();
const p2pLendingAddress = await p2pLending.getAddress();
console.log("✅ P2PLending deployed to:", p2pLendingAddress);

// Whitelist USDT token
await p2pLending.whitelistToken(mockUSDTAddress, true);
console.log("   ↳ Whitelisted USDT token");

// ========== Summary ==========
console.log("\n" + "=".repeat(50));
console.log("📋 DEPLOYMENT SUMMARY");
console.log("=".repeat(50));
console.log(`MockUSDT:          ${mockUSDTAddress}`);
console.log(`MockPriceOracle:   ${priceOracleAddress}`);
console.log(`CollateralManager: ${collateralManagerAddress}`);
console.log(`P2PLending:        ${p2pLendingAddress}`);
console.log("=".repeat(50));

console.log("\n📝 Thêm vào file .env:");
console.log(`MOCKUSDT_ADDRESS=${mockUSDTAddress}`);
console.log(`PRICE_ORACLE_ADDRESS=${priceOracleAddress}`);
console.log(`COLLATERAL_MANAGER_ADDRESS=${collateralManagerAddress}`);
console.log(`P2P_LENDING_ADDRESS=${p2pLendingAddress}`);

console.log("\n🔍 Verify contracts trên Etherscan:");
console.log(`npx hardhat verify --network sepolia ${mockUSDTAddress} "${deployer.address}"`);
console.log(`npx hardhat verify --network sepolia ${priceOracleAddress} "${deployer.address}"`);
console.log(`npx hardhat verify --network sepolia ${collateralManagerAddress} "${priceOracleAddress}" "${deployer.address}"`);
console.log(`npx hardhat verify --network sepolia ${p2pLendingAddress} "${deployer.address}"`);