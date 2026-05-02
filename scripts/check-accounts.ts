import { ethers } from "hardhat";

async function main() {
  const signers = await ethers.getSigners();
  console.log("Available Accounts on Ganache:");
  for (let i = 0; i < Math.min(5, signers.length); i++) {
    const balance = await ethers.provider.getBalance(signers[i].address);
    console.log(`(${i}) ${signers[i].address} (${ethers.formatEther(balance)} ETH)`);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
