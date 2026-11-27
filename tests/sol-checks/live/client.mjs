// The websocket half of tests/sol-checks/sol-live.sol: a page's frames, as the
// std/livejs client sends them, and the snapshots that come back.
const [port] = process.argv.slice(2);
const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?lv=3`);
const frames = [];
const sends = [
  { msg: '=["Bump",5]', arg: '' },
  { msg: '=["Nope"]', arg: '' },
  { msg: '=["Bump",10]', arg: '' },
  { msg: '=["Reset"]', arg: '' },
];
const count = (f) => { const m = /Count (\d+)/.exec(JSON.parse(f).s.join('') + JSON.parse(f).d.join('')); return m ? m[1] : '?'; };
const timer = setTimeout(() => { console.log('timeout after', frames.map(count).join(' ')); process.exit(1); }, 10000);
ws.onmessage = (e) => {
  frames.push(e.data);
  if (sends.length) ws.send(JSON.stringify(sends.shift()));
  else { clearTimeout(timer); console.log(frames.map(count).join(' ')); ws.close(); process.exit(0); }
};
ws.onerror = (e) => { console.log('error', e.message); process.exit(1); };
