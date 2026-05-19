/**
 * check-usdt.js — Kiểm tra số dư USDT (MockUSDT contract) trên Ganache
 * 
 * Cách dùng: node scripts/check-usdt.js
 * Ganache phải đang chạy trên port 7545
 */

import http from 'http';

// ⚠️ Cập nhật địa chỉ này sau mỗi lần re-deploy
const USDT_CONTRACT = '0x857e0F68a924683409BC508d7442aAC6abe0b762';

// ERC20 balanceOf + decimals — ABI selector (keccak256)
// balanceOf(address) = 0x70a08231
// decimals()         = 0x313ce567

function rpcCall(method, params = []) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify({ jsonrpc: '2.0', method, params, id: 1 });
    const req = http.request({
      hostname: '127.0.0.1',
      port: 7545,
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) }
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

// Gọi eth_call tới contract
function ethCall(to, data) {
  return rpcCall('eth_call', [{ to, data }, 'latest']);
}

// Encode địa chỉ Ethereum để dùng trong calldata
function encodeAddress(addr) {
  // Bỏ 0x, pad thành 32 bytes (64 hex chars)
  return addr.toLowerCase().replace('0x', '').padStart(64, '0');
}

// Decode số nguyên từ hex string
function decodeUint(hex) {
  return BigInt('0x' + hex.replace('0x', ''));
}

async function main() {
  try {
    console.log('=== USDT Balance Check ===');
    console.log(`Contract: ${USDT_CONTRACT}\n`);

    // 1. Lấy decimals
    const decimalsRes = await ethCall(USDT_CONTRACT, '0x313ce567');
    const decimals = Number(decodeUint(decimalsRes.result));
    console.log(`Decimals: ${decimals}`);

    // 2. Lấy danh sách accounts
    const accountsRes = await rpcCall('eth_accounts');
    const accounts = accountsRes.result;

    console.log(`\nAccounts (${accounts.length}):\n`);
    console.log('Index | Address                                    | ETH          | USDT');
    console.log('------|---------------------------------------------|--------------|------------------');

    // 3. Với mỗi account, lấy cả ETH và USDT
    for (let i = 0; i < accounts.length; i++) {
      const addr = accounts[i];

      // ETH balance
      const ethRes = await rpcCall('eth_getBalance', [addr, 'latest']);
      const ethBal = Number(decodeUint(ethRes.result)) / 1e18;

      // USDT balance: gọi balanceOf(addr)
      const calldata = '0x70a08231' + encodeAddress(addr);
      const usdtRes = await ethCall(USDT_CONTRACT, calldata);

      let usdtBal = '0';
      if (usdtRes.result && usdtRes.result !== '0x') {
        const rawBig = decodeUint(usdtRes.result);
        usdtBal = (Number(rawBig) / Math.pow(10, decimals)).toFixed(2);
      }

      const ethStr = ethBal.toFixed(2).padStart(12);
      const usdtStr = usdtBal.padStart(16);
      const marker = parseFloat(usdtBal) > 0 ? ' ✅' : '   ';
      console.log(`  [${i}]  ${addr}  ${ethStr}  ${usdtStr}${marker}`);
    }

    console.log('\n✅ = có USDT từ deploy script');
    console.log('❌ = không có USDT (không được mint)');
    console.log('\nNếu tất cả đều = 0, hãy chạy lại: npx hardhat run scripts/deploy-ganache.ts');

  } catch (error) {
    if (error.code === 'ECONNREFUSED') {
      console.error('\n❌ Không thể kết nối Ganache tại http://127.0.0.1:7545');
      console.error('→ Hãy khởi động Ganache trước!');
    } else {
      console.error('❌ Lỗi:', error.message);
    }
  }
}

main();
