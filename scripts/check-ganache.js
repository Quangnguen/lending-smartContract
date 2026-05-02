const http = require('http');

function rpcCall(method, params = []) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify({ jsonrpc: '2.0', method, params, id: 1 });
    const req = http.request({
      hostname: '127.0.0.1',
      port: 7545,
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': data.length }
    }, res => {
      let body = '';
      res.on('data', c => body += c);
      res.on('end', () => {
        try { resolve(JSON.parse(body)); } catch (e) { reject(e); }
      });
    });
    req.on('error', e => reject(e));
    req.write(data);
    req.end();
  });
}

async function main() {
  try {
    // 1. Check if Ganache is running
    console.log('=== Checking Ganache connection at http://127.0.0.1:7545 ===\n');
    
    // 2. Get accounts
    const accountsRes = await rpcCall('eth_accounts');
    const accounts = accountsRes.result;
    console.log(`Found ${accounts.length} accounts:\n`);
    
    // 3. Get balance for each account
    for (let i = 0; i < accounts.length; i++) {
      const balRes = await rpcCall('eth_getBalance', [accounts[i], 'latest']);
      const balWei = BigInt(balRes.result);
      const balEth = Number(balWei) / 1e18;
      console.log(`(${i}) ${accounts[i]} => ${balEth.toFixed(4)} ETH`);
    }
    
    // 4. Check chain ID
    const chainRes = await rpcCall('eth_chainId');
    console.log(`\nChain ID: ${parseInt(chainRes.result, 16)} (${chainRes.result})`);
    
    // 5. Check the specific private key from .env
    const privateKey = '0xb9d662998bd59ff88114d5e58d8fba55c2a0f089537de5ead8efe4f5378407b3';
    console.log(`\n=== Private key from .env ===`);
    console.log(`Key: ${privateKey}`);
    
    // Derive address from private key using basic crypto
    const crypto = require('crypto');
    // We can't easily derive ETH address without ethers, so just check if any account matches
    console.log(`\nNote: To verify which account this key belongs to, check Ganache UI.`);
    console.log(`If Ganache was restarted, the accounts and private keys have changed!`);
    console.log(`You need to copy the NEW private key from Ganache UI into .env`);
    
  } catch (error) {
    if (error.code === 'ECONNREFUSED') {
      console.error('ERROR: Cannot connect to Ganache at http://127.0.0.1:7545');
      console.error('Ganache is NOT running! Please start Ganache first.');
    } else {
      console.error('ERROR:', error.message);
    }
  }
}

main();
