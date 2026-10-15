#!/usr/bin/env node
// Capability tests for the actual generated FP-RISC program; no browser/device access.
const assert = require('node:assert/strict');
const vm = require('node:vm');
const {execFileSync} = require('node:child_process');
const path = require('node:path');
const source = execFileSync(path.resolve(process.argv[2]), {encoding:'utf8'});

function fixture(permission='default') {
 const handlers = new Map(), storage = new Map(), shown = [], inputs = {};
 const clientStatus = {textContent:''}, notificationStatus = {textContent:''};
 let live = 'live';
 for (const [name,value] of Object.entries({careTitle:'Check',careDays:'30',
   careNote:'squeak | <script> é 🔧',careFile:'part|one.3mf',careProfile:'PLA | 0.4',
   careCategory:'Noise / squeaking',careOutcome:'Failed',carePayload:''})) {
  inputs[name] = {value,dispatchEvent(){this.inputs=(this.inputs||0)+1;}};
 }
 function listen(name,fn) { if(!handlers.has(name))handlers.set(name,[]);handlers.get(name).push(fn); }
 async function event(name, value={}) { for(const fn of handlers.get(name)||[])await fn(value); }
 class Notification {
  static permission = permission;
  static async requestPermission(){Notification.permission='granted';return 'granted';}
  constructor(title,opts){shown.push({title,opts});}
  close(){}
 }
 const due = [{getAttribute(){return 'demo-carbon:1000';}}];
 const document = {
  addEventListener:listen,
  getElementById(){return {textContent:live};},
  querySelector(selector) {
   if(selector==='[data-care-client-status]')return clientStatus;
   const match=selector.match(/^\[data-input="([^"]+)"\]$/);
   return match?inputs[match[1]]:null;
  },
  querySelectorAll(selector) {
   if(selector==='[data-care-due]')return due;
   if(selector==='[data-care-notification-status]')return [notificationStatus];
   return [];
  },
 };
 const context={document,Notification,JSON,Map,
  localStorage:{getItem:k=>storage.get(k)||null,setItem:(k,v)=>storage.set(k,v)},
  window:{isSecureContext:true,addEventListener:listen,focus(){}},
  Event:class {constructor(type,opts){this.type=type;Object.assign(this,opts);}},
  setInterval:()=>1,
 };
 vm.runInNewContext(source,context);
 function click(selector,detail=1){return {target:{closest:s=>s===selector?{}:null},detail,
  preventDefault(){this.prevented=true;},stopImmediatePropagation(){this.stopped=true;}};}
 return {inputs,storage,shown,clientStatus,notificationStatus,event,click,due,setLive:value=>live=value,context};
}

(async()=>{
 const f=fixture();
 await f.event('click',f.click('[data-care-submit]'));
 const packed=JSON.parse(f.inputs.carePayload.value);
 assert.equal(packed.note,'squeak | <script> é 🔧');
 assert.equal(packed.file,'part|one.3mf');
 assert.equal(packed.profile,'PLA | 0.4');
 // An acknowledgement must not erase a new draft typed during the save.
 f.inputs.careNote.value='new draft while saving';
 await f.event('live:care-saved',{detail:JSON.stringify(packed)});
 assert.equal(f.inputs.careNote.value,'new draft while saving');
 f.inputs.careNote.value=packed.note;
 await f.event('live:care-saved',{detail:JSON.stringify(packed)});
 assert.equal(f.inputs.careNote.value,'');
 f.setLive('offline');
 const blocked=f.click('[data-care-submit]');
 await f.event('click',blocked);
 assert(blocked.stopped && blocked.prevented);
 assert.match(f.clientStatus.textContent,/Disconnected/);
 f.setLive('live');
 const duplicate=f.click('[data-care-submit]',2);
 await f.event('click',duplicate);
 assert(duplicate.stopped && duplicate.prevented);
 assert.equal(f.shown.length,0,'no notification or permission request before opt-in');
 await f.event('click',f.click('[data-care-notify]'));
 assert.equal(f.shown.length,1);
 assert.equal(f.storage.get('print-room-reminders'),'on');
 await f.event('live:frame');await f.event('live:frame');
 assert.equal(f.shown.length,1,'deduplicate repeated ticks');
 f.due[0]={getAttribute(){return 'demo-carbon:2000';}};
 await f.event('live:frame');
 assert.equal(f.shown.length,2,'new due occurrence gets a new alert');
 await f.event('click',f.click('[data-care-notify]'));
 await f.event('live:frame');
 assert.equal(f.shown.length,2,'opt-out takes effect');
 const unsupported=fixture();
 delete unsupported.context.Notification;
 await unsupported.event('click',unsupported.click('[data-care-notify]'));
 assert.match(unsupported.notificationStatus.textContent,/cannot show notifications/);
 const denied=fixture('denied');
 denied.storage.set('print-room-reminders','on');
 await denied.event('live:frame');
 assert.equal(denied.shown.length,0);
 assert.match(denied.notificationStatus.textContent,/permission is off/);
 console.log('printer care browser capabilities: form packing, draft race, offline, dedup and permission fallbacks passed');
})().catch(error=>{console.error(error);process.exitCode=1;});
