// Exercise the production reactive runtime, including native drag metadata.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const nodes = new Map(), actions = [];
const host = vm.createContext({
  __host_applyOps: raw => {
    for (const op of JSON.parse(raw)) {
      if (op.op === 'create') nodes.set(op.id, {id:op.id,type:op.type});
      if (op.op === 'update') nodes.get(op.id)[op.key] = op.value;
      if (op.op === 'remove') nodes.delete(op.id);
    }
  },
  __host_action: raw => actions.push(JSON.parse(raw)),
  __host_log: text => { throw new Error(text); }
});
const resources = path.join(__dirname,'../Packages/macOS/CmuxSwiftRenderUI/Sources/CmuxSwiftRenderUI/Resources');
vm.runInContext(fs.readFileSync(path.join(resources,'SidebarRuntime.js'),'utf8'),host);
const set=(key,value)=>host.__setData(key,JSON.stringify(value));
set('providerFilter','All');set('searchQuery','');set('navigationMode','chats');
set('history',[{provider:'OpenCode',id:'ses_Exact',title:'Saved chat',cwd:'/project',group:'/project',updated:1,command:'opencode --session ses_Exact'}]);
set('workspaces',[{id:'w',title:'Work',selected:true,tabs:[{id:'panel',surfaceId:'surface',title:'Base terminal',focused:true}],agents:[]}]);
vm.runInContext(fs.readFileSync(path.join(resources,'ConversationSidebar.js'),'utf8'),host);
const button=label=>[...nodes.values()].find(n=>n.type==='button'&&n.text===label);
const chat=button('Saved chat');
assert.ok(chat);
assert.equal(chat.conversationProvider,'OpenCode');
assert.equal(chat.conversationID,'ses_Exact');
assert.equal(chat.conversationDirectory,'/project');
assert.equal(actions.length,0,'Rendering history must not launch sessions');
assert.ok(button('Base terminal'), 'Open tabs stay available beside history');
host.__dispatch(button('Base terminal').id,'tap','{}');
assert.equal(actions[0].method,'workspace.select');
assert.equal(actions[1].method,'surface.focus');
assert.equal(actions[1].params.surface_id,'panel');
const oldTerminal = button('Base terminal');
set('workspaces',[{id:'other',title:'Other',selected:true,tabs:[{id:'other-panel',title:'Other terminal',focused:true}]}]);
assert.ok(button('Saved chat'));
assert.ok(button('Other terminal'));
assert.equal(button('Base terminal'),undefined,'Switching layouts disposes old open rows');
const count=actions.length;
host.__dispatch(oldTerminal.id,'tap','{}');
assert.equal(actions.length,count,'Disposed handlers cannot activate a stale surface');
console.log('Live scene exposes open tabs beside history and focuses exact control targets');

set('showOpenTabs',false);
assert.equal(button('Other terminal'),undefined,'Vertical tabs can be hidden without closing their surfaces');
assert.ok(button('Saved chat'),'History remains visible with vertical tabs hidden');
set('showOpenTabs',true);assert.ok(button('Other terminal'));
assert.equal(actions.length,count,'Revealing vertical tabs must not open sessions');

const beforeResume=actions.length;
host.__dispatch(button('Saved chat').id,'tap','{}');
set('workspaces',[{id:'w',selected:true,tabs:[{id:'p',title:'Saved chat',focused:true}],agents:[{id:'ses_Exact',kind:'opencode',panelId:'p'}]}]);
set('workspaces',[{id:'w',selected:true,tabs:[],agents:[]}]);
host.__dispatch(button('Saved chat').id,'tap','{}');
assert.equal(actions.length,beforeResume+2,'Closing a linked chat permits immediate reopening without a cooldown');
