(() => {
  let checking = false;
  async function check() {
    if (checking || document.hidden) return;
    checking = true;
    try {
      const response = await fetch('/auth/session', {credentials:'same-origin', cache:'no-store'});
      if (response.status === 401) location.replace('/');
    } catch (_) { /* the live UI handles network outages */ }
    finally { checking = false; }
  }
  document.addEventListener('click', async event => {
    if (!event.target.closest('[data-sign-out]')) return;
    event.preventDefault();
    try {
      const response = await fetch('/auth/logout', {method:'POST', headers:{'Content-Type':'application/json'}, body:'{}', credentials:'same-origin'});
      if (response.ok) location.replace('/');
    } catch (_) { alert('Could not sign out. Please retry when connected.'); }
  });
  setInterval(check, 15000);
  document.addEventListener('visibilitychange', check);
  check();
})();
