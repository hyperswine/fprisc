#!/usr/bin/env node
// Exercise the shipped pure patch decoder without a browser dependency.
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const assert = require('node:assert/strict');
const src = fs.readFileSync(path.join(__dirname,'../std/livejs.fpr'),'utf8');
const code = src.slice(src.indexOf('  function spliced('),src.indexOf('  function apply(res)')).replace(/\\\{/g,'{');
const ctx = vm.createContext({});
vm.runInContext(code,ctx);
const apply = (old,p) => JSON.parse(JSON.stringify(ctx.spliced(old,p)));
assert.deepEqual(apply(['a','b','c'],[1,1,['x','y']]),['a','x','y','c']);
assert.deepEqual(apply(['a'],[0,1,[]]),[]);
assert.deepEqual(apply([],[0,0,['λ','<script>text</script>']]),['λ','<script>text</script>']);
assert.deepEqual(apply(['a'],[1,0,[]]),['a']);
for(const bad of [null,{},[],[-1,0,[]],[0,-1,[]],[2,0,[]],[0,2,[]],[.5,0,[]],[0,0,'x'],[0,0,[1]],[0,0,[],4]]) {
  const old=['a'];
  assert.throws(()=>ctx.spliced(old,bad));
  assert.deepEqual(old,['a']);
}
console.log('Client patch insert/replace/delete, empty arrays, escaping and invalid ranges/types: PASS');

// v3: a list of splices, applied in order, each against the array the previous left
const all = (old,ps) => JSON.parse(JSON.stringify(ctx.splicedAll(old,ps)));
assert.deepEqual(all(['h','c3','c2','c1','f'],[[1,0,['c4']],[4,1,[]]]),['h','c4','c3','c2','f']);
assert.deepEqual(all(['a','b'],[]),['a','b']);
assert.deepEqual(all([],[[0,0,['x']],[1,0,['y']]]),['x','y']);
for(const bad of [null,{},'x',[[0,2,[]]],[[0,0,[]],[5,0,[]]],[[0,0,[1]]]]) {
  const old=['a'];
  assert.throws(()=>ctx.splicedAll(old,bad));
  assert.deepEqual(old,['a']);
}
console.log('Client v3 splice lists: in-order application, empty lists, invalid entries rejected without touching the page: PASS');

// Browser close() permits 1000 or application codes 3000..4999. A protocol
// error code such as 1002 cannot be sent directly by browser JavaScript.
const handler = src.slice(src.indexOf('    ws.onmessage ='),src.indexOf('    ws.onclose =')).replace(/\\\{/g,'{');
let closed;
const events = vm.createContext({ws:{close:(code)=>{closed=code;}}, console:{error:()=>{}}, apply:()=>{throw new Error('bad patch');}});
vm.runInContext(handler,events);
events.ws.onmessage({data:'not json'});
assert.equal(closed,4002);
closed=undefined;
events.ws.onmessage({data:'{}'});
assert.equal(closed,4002);
console.log('Malformed frame/patch requests a browser-valid resync close: PASS');
