/* No framework bindings, analytics, persistence or third-party code on this page. */
async function importLoginKey(input, subtle) {
  let bytes;
  if (/^-----BEGIN PRIVATE KEY-----[\s\S]+-----END PRIVATE KEY-----$/.test(input.trim())) {
    const raw = input.trim().replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, '');
    bytes = Uint8Array.from(atob(raw), c => c.charCodeAt(0));
  } else {
    const hex = input.trim();
    if (!/^(?:[0-9a-fA-F]{64}|[0-9a-fA-F]{128})$/.test(hex))
      throw new Error('Use an Ed25519 PKCS#8 PEM key or a 32-byte hex seed.');
    // RFC 8410 PKCS#8 wrapper for a raw 32-byte Ed25519 seed.
    bytes = Uint8Array.from(('302e020100300506032b657004220420' + hex.slice(0, 64)).match(/../g), b => parseInt(b, 16));
  }
  try { return await subtle.importKey('pkcs8', bytes, 'Ed25519', false, ['sign']); }
  finally { bytes.fill(0); }
}

async function loginWithKey(key, subtle, request) {
  const response = await request('/auth/challenge', {method:'POST', headers:{'Content-Type':'application/json'}, body:'{}', credentials:'same-origin', cache:'no-store'});
  const challenge = await response.json();
  if (!response.ok) throw new Error(challenge.error || 'Could not request a challenge.');
  const signature = new Uint8Array(await subtle.sign('Ed25519', key, new TextEncoder().encode(challenge.message)));
  try {
    const encoded = btoa(String.fromCharCode(...signature));
    const result = await request('/auth/verify', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({id:challenge.id, signature:encoded}), credentials:'same-origin', cache:'no-store'});
    const value = await result.json();
    if (!result.ok) throw new Error(value.error || 'Sign in failed.');
  } finally { signature.fill(0); }
}

if (typeof module !== 'undefined') module.exports = {importLoginKey, loginWithKey};
if (typeof document !== 'undefined') {
  const form = document.getElementById('login'), field = document.getElementById('private-key');
  const message = document.getElementById('message'), button = form.querySelector('button');
  form.addEventListener('submit', async event => {
    event.preventDefault(); button.disabled = true; message.textContent = 'Signing in…';
    let key;
    try {
      if (!globalThis.isSecureContext || !globalThis.crypto?.subtle)
        throw new Error('Open Print room over HTTPS, or on localhost.');
      const importing = importLoginKey(field.value, crypto.subtle);
      field.value = ''; // clear before any network request, including an import failure
      key = await importing;
      await loginWithKey(key, crypto.subtle, fetch);
      location.replace('/');
    } catch (error) {
      message.textContent = error.name === 'NotSupportedError'
        ? 'This browser does not support Ed25519. Please update your browser.'
        : error.name === 'DataError' ? 'That is not a valid Ed25519 private key.' : error.message;
    } finally { key = null; field.value = ''; button.disabled = false; }
  });
  window.addEventListener('pagehide', () => { field.value = ''; });
}
