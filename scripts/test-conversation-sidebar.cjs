const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
let history = [], workspaces = [], calls = [];
const context = vm.createContext({
  signal: value => [()=>value, next=>{value=next;}], computed:f=>f, effect:()=>{},
  data:{history:()=>history, workspaces:()=>workspaces, providerFilter:()=> 'All'}, sidebar:()=>{},
  cmux:(method,params)=>calls.push({method,params})
});
vm.runInContext(fs.readFileSync(path.join(__dirname,'../Packages/macOS/CmuxSwiftRenderUI/Sources/CmuxSwiftRenderUI/Resources/ConversationSidebar.js'),'utf8'),context);
const run=code=>vm.runInContext(code,context);
function row(id,provider,cwd,updated,pinned=false) {return {id,provider,cwd,canonical_folder:cwd,updated,pinned,title:id,group:'Folder · '+cwd,command:provider+' resume '+id,operation:'op'};}
history=[row('pin2','Codex','/a',0,true),row('pin1','Claude','/b',1,true),row('old','Codex','/a',2),row('fresh','OpenCode','/a',10),row('middle','Claude','/b',5)];
assert.equal(run("conversationGroups(history(),'All','',true).map(g=>g.name).join('|')"),'Pinned|/a|/b');
assert.equal(run("conversationGroups(history(),'All','',true)[0].rows.map(r=>r.id).join('|')"),'pin2|pin1');
assert.equal(run("conversationGroups(history(),'All','',true)[1].rows.map(r=>r.id).join('|')"),'fresh|old');
assert.equal(run("conversationGroups(history(),'Codex','',true)[1].rows.length"),1);
assert.equal(run("conversationGroups(history(),'All','middle',true)[0].rows[0].id"),'middle');
run('focus(history()[3])'); assert.equal(calls.length,0);
workspaces=[{id:'w',agents:[{id:'fresh',kind:'opencode',panelId:'p'}],tabs:[{id:'p'}]}];
run('focus(history()[3])'); assert.equal(calls[0].method,'workspace.select'); assert.equal(calls[1].params.surface_id,'p');
workspaces=[]; calls=[];
run('resume(history()[3]);resume(history()[3])'); assert.equal(calls.length,1); assert.match(calls[0].params.operation_id,/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
console.log('Conversation grouping, search, pin order, OpenCode focus, and explicit resume passed');
