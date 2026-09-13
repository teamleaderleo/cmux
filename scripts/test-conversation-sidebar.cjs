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
history=[row('pin2','Codex','/a',0,true),row('pin1','Claude','/b',1,true),row('old','Codex','/a',2),row('ses_MixedCase','OpenCode','/a',10),row('middle','Claude','/b',5)];
assert.equal(run("conversationGroups(history(),'All','',true).map(g=>g.name).join('|')"),'Pinned|/a|/b');
assert.equal(run("conversationGroups(history(),'All','',true)[0].rows.map(r=>r.id).join('|')"),'pin2|pin1');
assert.equal(run("conversationGroups(history(),'All','',true)[1].rows.map(r=>r.id).join('|')"),'ses_MixedCase|old');
assert.equal(run("conversationGroups(history(),'Codex','',true)[1].rows.length"),1);
assert.equal(run("conversationGroups(history(),'All','middle',true)[0].rows[0].id"),'middle');
run('focus(history()[3])'); assert.equal(calls.length,0);
workspaces=[{id:'w',agents:[{id:'ses_MixedCase',kind:'opencode',panelId:'p'}],tabs:[{id:'p'}]}];
run('focus(history()[3])'); assert.equal(calls[0].method,'workspace.select'); assert.equal(calls[1].params.surface_id,'p');
workspaces=[]; calls=[];
run('resume(history()[3]);resume(history()[3])'); assert.equal(calls.length,1); assert.match(calls[0].params.operation_id,/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
console.log('Conversation grouping, search, pin order, OpenCode focus, and explicit resume passed');

workspaces=[{id:'resumed',description:'tk-history:OpenCode:ses_MixedCase',tabs:[]}];calls=[];
run('focus(history()[3])');assert.equal(calls[0].params.workspace_id,'resumed');
workspaces=[{id:'different',agents:[{id:'ses_mixedcase',kind:'opencode',panelId:'other'}],tabs:[{id:'other'}]}];calls=[];
run('focus(history()[3])');assert.equal(calls.length,0,'OpenCode IDs are case-sensitive');
console.log('Case-sensitive OpenCode resume linking passed');

// Continuous project history must not hide the sixth or later conversation.
history=Array.from({length:35},(_,i)=>row('chat'+i,'Codex','/large',i));
assert.equal(run("conversationGroups(history(),'All','')[0].rows.length"),35);
assert.equal(run("conversationGroups(history(),'All','')[0].rows[34].id"),'chat0');
console.log('Continuous project history includes every loaded conversation');

// A missing provider project label falls back to the working folder.
history=[row('ungrouped','Claude','/fallback',1)];delete history[0].group;
assert.equal(run("conversationGroups(history(),'Claude','')[0].name"),'/fallback');
assert.equal(run("groupLabel(history()[0])"),'/fallback');
console.log('Missing project labels fall back to folders');
