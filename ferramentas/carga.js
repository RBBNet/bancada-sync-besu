// Carga leve e contínua: uma transação simples (valor 0, gasPrice 0) a cada <intervalo> segundos.
// Cada transação sai de uma conta aleatória nova, o que dispensa chaves no repositório e controle de nonce
// (a rede aceita gasPrice 0 e o Ingress do gênesis, sem Rules, permite qualquer conta).
// Uso: node carga.js <url-rpc> <intervalo-s> <arquivo-jsonl>
const fs = require('fs');
const { ethers } = require('ethers');

const [rpc, intervalo, arquivo] = process.argv.slice(2);
const provedor = new ethers.JsonRpcProvider(rpc, undefined, { staticNetwork: true });
const registrar = (o) => fs.appendFileSync(arquivo, JSON.stringify({ instante: new Date().toISOString(), ...o }) + '\n');

setInterval(async () => {
  const carteira = ethers.Wallet.createRandom().connect(provedor);
  try {
    const tx = await carteira.sendTransaction({
      to: '0x000000000000000000000000000000000000dEaD', value: 0, gasPrice: 0, gasLimit: 21000, type: 0, nonce: 0,
    });
    registrar({ resultado: 'ENVIADA', hash: tx.hash });
  } catch (e) {
    registrar({ resultado: 'ERRO', erro: e.shortMessage || e.message || String(e) });
  }
}, Number(intervalo) * 1000);
