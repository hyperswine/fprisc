// The websocket half of tests/sol-checks/sol-live.sol for sol/examples/live-room.sol:
// two pages (sessions), joined/left events, a delayed message, structural
// patches applied as the std/livejs client applies them, and Quit.
const [port] = process.argv.slice(2);
const url = `ws://127.0.0.1:${port}/ws?lv=3`;
const log = [];
let patches = 0;
function page(name) {
  const ws = new WebSocket(url);
  const st = { s: [], d: [], ws, text: '' };
  const splice = (arr, [at, n, ins]) => arr.slice(0, at).concat(ins, arr.slice(at + n));
  ws.onmessage = (e) => {
    const f = JSON.parse(e.data);
    if (f.p === 2) { patches++; st.s = splice(st.s, f.s); st.d = splice(st.d, f.d); }
    else if (f.s) { st.s = f.s; st.d = f.d; }
    else return;
    let t = ''; for (let i = 0; i < st.s.length; i++) t += st.s[i] + (i < st.d.length ? st.d[i] : '');
    st.text = t.replace(/<[^>]*>/g, ' ');
  };
  return st;
}
const until = (cond, what) => new Promise((ok, no) => {
  const t0 = Date.now();
  const tick = () => cond() ? ok() : Date.now() - t0 > 8000 ? no(new Error('timeout: ' + what)) : setTimeout(tick, 20);
  tick();
});
const send = (st, wire) => st.ws.send(JSON.stringify({ msg: wire, arg: '' }));
(async () => {
  const a = page('a');
  await until(() => /session 1; 1 online/.test(a.text), 'a joins'); log.push('a joined');
  const b = page('b');
  await until(() => /session 2; 2 online/.test(b.text), 'b joins');
  await until(() => /session 1; 2 online/.test(a.text), 'a sees b'); log.push('a sees 2 online');
  send(a, '=["Bump",5]');
  await until(() => /Count 5\b/.test(b.text), 'bump reaches b'); log.push('count 5 on b');
  send(a, '=["Later"]');
  await until(() => /Count 105\b/.test(a.text), 'later'); log.push('count 105 later');
  send(a, '=["Toggle"]');
  await until(() => { const m = /(\d+) ticks/.exec(a.text); return m && +m[1] >= 2; }, 'ticks'); log.push('ticker ticks');
  send(a, '=["Toggle"]');
  await until(() => !/stop ticking/.test(a.text), 'ticker stops');
  { const m = /(\d+) ticks/.exec(a.text); const n = m ? +m[1] : -1;
    await new Promise((ok) => setTimeout(ok, 800));
    const m2 = /(\d+) ticks/.exec(a.text); if (!m2 || +m2[1] !== n) throw new Error('ticks went on after the subscription ended'); }
  log.push('ticker stopped');
  send(a, '=["Nope"]');
  b.ws.close();
  await until(() => /session 1; 1 online/.test(a.text), 'b leaves'); log.push('a sees 1 online');
  send(a, '=["Stop"]');
  await new Promise((ok) => { a.ws.onclose = ok; setTimeout(ok, 3000); });
  console.log(log.join(', ') + (patches > 0 ? ', patches used' : ', no patches'));
  process.exit(0);
})().catch((e) => { console.log('FAIL ' + e.message + ' after: ' + log.join(', ')); process.exit(1); });
