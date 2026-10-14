// Exercise the exact browser signing code with WebCrypto and a real gateway.
const assert = require('node:assert/strict');
const {webcrypto, createPrivateKey, createPublicKey} = require('node:crypto');
const fs = require('node:fs');
const {importLoginKey, loginWithKey} = require('../tools/printer_login.js');
(async () => {
  const base = process.argv[2], pem = fs.readFileSync(process.argv[3], 'utf8');
  const privateKey = createPrivateKey(pem);
  const seed = Buffer.from(privateKey.export({format:'jwk'}).d, 'base64url').toString('hex');
  const pub = Buffer.from(createPublicKey(privateKey).export({format:'jwk'}).x, 'base64url').toString('hex');
  for (const input of [pem, seed, seed + pub]) {
    let cookie = '', network = [];
    const request = async (path, options) => {
      if (typeof options.body === 'string') {
        network.push(options.body);
        assert(!options.body.includes(seed));
        assert(!options.body.includes(pem));
      }
      const response = await fetch(base + path, {...options, headers:{...options.headers, Origin:base, Cookie:cookie}});
      for (const header of response.headers.getSetCookie()) {
        const [pair] = header.split(';'), name = pair.split('=')[0];
        const entries = cookie.split('; ').filter(v => v && !v.startsWith(name + '='));
        entries.push(pair); cookie = entries.join('; ');
      }
      return response;
    };
    const key = await importLoginKey(input, webcrypto.subtle);
    assert.equal(key.extractable, false);
    await loginWithKey(key, webcrypto.subtle, request);
    assert.equal(network.length, 2);
    assert.deepEqual(Object.keys(JSON.parse(network[1])).sort(), ['id', 'signature']);
    const status = await request('/api/status', {});
    assert.equal(status.status, 200);
    assert.equal((await status.json()).printers.length, 2);
    await request('/auth/logout', {method:'POST', headers:{'Content-Type':'application/json'}, body:'{}'});
    assert.equal((await request('/api/status', {})).status, 401);
  }
  await assert.rejects(importLoginKey('invalid', webcrypto.subtle));
  console.log('PASS browser WebCrypto: PEM/seed/seed+public, signature-only requests, session, logout');
})().catch(error => {console.error(error); process.exit(1);});
