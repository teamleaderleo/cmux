const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const nodes = new Map(), actions = [];
const host = vm.createContext({
  __host_applyOps: raw => { for (const op of JSON.parse(raw)) {
    if (op.op==='create') nodes.set(op.id,{id:op.id,type:op.type,children:[]});
    if (op.op==='update') nodes.get(op.id)[op.key]=op.value;
    if (op.op==='append') nodes.get(op.id).children.push(op.child);
    if (op.op==='children') nodes.get(op.id).children=op.children;
    if (op.op==='remove') nodes.delete(op.id);
  } },
  __host_action: raw => actions.push(JSON.parse(raw)),
  __host_log: text => { throw new Error(text); }
});
const root=path.join(__dirname,'../Packages/macOS/CmuxSwiftRenderUI/Sources/CmuxSwiftRenderUI/Resources');
vm.runInContext(fs.readFileSync(path.join(root,'SidebarRuntime.js'),'utf8'),host);
const set=(k,v)=>host.__setData(k,JSON.stringify(v));
const history=Array.from({length:200},(_,i)=>({provider:'Codex',id:'chat'+i,title:'Chat '+i,cwd:'/p',group:'/p',updated:200-i,command:'codex resume chat'+i}));
const workspace={id:'w',title:'Work',selected:true,agents:[0,1].map(i=>({id:'chat'+i,kind:'codex',panelId:'p'+i,surfaceId:'tab'+i})),tabs:[0,1].map(i=>({id:'p'+i,surfaceId:'tab'+i,title:'Chat '+i,focused:i===0}))};
set('history',history);set('workspaces',[workspace]);set('providerFilter','All');set('searchQuery','');set('visibleCount',24);set('historyView',{provider:'All',query:'',limit:24});
vm.runInContext(fs.readFileSync(path.join(root,'ConversationSidebar.js'),'utf8'),host);
const rows=()=>[...nodes.values()].filter(n=>n.type==='button'&&n.conversationID);
const selected=n=>n.background==='#80808030'||(n.children||[]).some(id=>nodes.has(id)&&selected(nodes.get(id)));
const selection=()=>rows().filter(selected).map(n=>n.conversationID);
let failed=0;
function check(name,fn){try{fn();console.log('PASS',name);}catch(e){failed++;console.error('FAIL',name,e.message);}}
check('only the actually focused chat is highlighted',()=>assert.deepEqual(selection(),['chat0']));
const first=rows().find(n=>n.conversationID==='chat0');
host.__dispatch(first.id,'tap','{}');
workspace.tabs[0].focused=false;workspace.tabs[1].focused=true;set('workspaces',[workspace]);
check('highlight follows native focus after returning through tabs',()=>assert.deepEqual(selection(),['chat1']));
check('All providers mounts only the first batch',()=>assert.equal(rows().length,24));
set('historyView',{provider:'All',query:'',limit:48});
check('scroll demand adds only one batch',()=>assert.equal(rows().length,48));
const before=actions.length;
set('historyView',{provider:'All',query:'Chat 199',limit:24});
check('search reaches history outside the initial batch',()=>assert.equal(rows()[0]?.conversationID,'chat199'));
check('view updates do not launch providers',()=>assert.equal(actions.length,before));
if(failed) process.exitCode=1;
