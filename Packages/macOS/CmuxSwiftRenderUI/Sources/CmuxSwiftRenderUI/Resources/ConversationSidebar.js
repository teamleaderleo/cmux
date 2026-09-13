// Shared live conversation sidebar. Metadata arrives as per-key context updates.
const history = computed(() => data.history() || []);
const [collapsed, setCollapsed] = signal({});
const [selectedRow, setSelectedRow] = signal('');
const [pending, setPending] = signal({});
function groupLabel(r) { return typeof r.group === 'string' && r.group ? r.group : r.cwd; }
function key(r) { return r.provider + ':' + r.id; }
function linkKey(provider, id) { return provider + ':' + (provider === 'OpenCode' ? String(id) : String(id).toLowerCase()); }
function buildLinks(workspaces) {
  const links = Object.create(null);
  const fallback = Object.create(null);
  for (const w of workspaces) {
    const panels = new Set((w.tabs || []).map(t => t.id));
    for (const a of w.agents || []) {
      const kind = String(a.kind).toLowerCase();
      const provider = kind.includes('claude') ? 'Claude' : kind.includes('codex') ? 'Codex' : kind.includes('opencode') ? 'OpenCode' : null;
      if (!provider || !panels.has(a.panelId)) continue;
      const id = linkKey(provider, a.id);
      if (!links[id]) links[id] = {w, panel:a.panelId};
    }
    if (String(w.description || '').startsWith('tk-history:')) {
      const saved = w.description.slice('tk-history:'.length);
      const colon = saved.indexOf(':');
      const id = linkKey(saved.slice(0, colon), saved.slice(colon + 1));
      if (!fallback[id]) fallback[id] = {w,panel:null};
    }
  }
  // A known hosting agent beats an old placeholder workspace anywhere in the window.
  return {...fallback,...links};
}
const liveLinks = computed(() => buildLinks(data.workspaces() || []));
function linked(r) { return liveLinks()[linkKey(r.provider, r.id)] || null; }

function focus(r) {
  setSelectedRow(key(r));
  const target = linked(r);
  if (target) {
    cmux('workspace.select', {workspace_id: target.w.id});
    if (target.panel) cmux('surface.focus', {workspace_id: target.w.id, surface_id: target.panel});
  } else resume(r);
}
function resume(r) {
  if (linked(r)) return focus(r);
  if (Date.now() - (pending()[key(r)] || 0) < 15000) return;
  setPending({...pending(), [key(r)]: Date.now()});
  cmux('workspace.create', {title: r.title, working_directory: r.cwd,
    description: 'tk-history:' + key(r), initial_command: r.command,
    operation_id: 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g,c=>{const n=Math.floor(Math.random()*16);return (c==='x'?n:(n&3)|8).toString(16);}), focus: true});
}

function visibleHistory() {
  return history().filter(r => data.providerFilter() === 'All' || r.provider === data.providerFilter());
}
const shortcutPins = computed(() => visibleHistory().filter(r => r.pinned).slice(0, 9));
function pinNumber(r) { return shortcutPins().findIndex(p => key(p) === key(r)) + 1; }
let seenJump = 0;
effect(() => {
  const serial = data.jumpSerial(); const index = data.pinJump();
  if (serial && serial !== seenJump) {
    seenJump = serial;
    const row = shortcutPins()[index - 1]; if (row) focus(row);
  }
});
function conversationGroups(rows, provider, query) {
  const needle = query.trim().toLowerCase();
  const groups = new Map();
  for (const r of rows) {
    if (provider !== 'All' && r.provider !== provider) continue;
    if (needle && ![r.title,r.group,r.provider,r.cwd].join(' ').toLowerCase().includes(needle)) continue;
    const id = r.pinned ? 'pins' : provider === 'All' && r.canonical_folder ? 'folder:'+r.canonical_folder : 'group:'+groupLabel(r);
    const name = r.pinned ? 'Pinned' : provider === 'All' && r.canonical_folder ? r.canonical_folder : groupLabel(r).replace(/^(Codex|Claude|Folder) · /,'');
    if (!groups.has(id)) groups.set(id, {id, name, pinned:!!r.pinned, updated:0, rows:[]});
    const g = groups.get(id); g.updated = Math.max(g.updated, r.updated); g.rows.push(r);
  }
  const result = Array.from(groups.values()).sort((a,b) => Number(b.pinned)-Number(a.pinned) || b.updated-a.updated || a.id.localeCompare(b.id));
  for (const group of result) {
    if (!group.pinned) group.rows.sort((a,b) => b.updated-a.updated || key(a).localeCompare(key(b)));
    // Preserve inherited/manual pin order; projects scroll through all loaded chats.
  }
  return result;
}
const groups = computed(() => conversationGroups(history(), data.providerFilter(), data.searchQuery() || ''));
sidebar(() => VStack({spacing:2}, [
  ForEach({items:groups,key:g=>g.id},g=>VStack({spacing:2},[
    HStack({spacing:5},[
      ForEach({items:()=>g().pinned?[]:[g().id],key:n=>n},n=>Image('folder').font(12).secondary()),
      Text(()=>g().name.startsWith('/')?g().name.split('/').filter(Boolean).pop():g().name)
        .font(()=>g().pinned?11:12).weight('regular').color(()=>g().pinned?'secondary':'primary').lineLimit(1), Spacer()
    ]).paddingLeading(10).paddingVertical(4).onTap(()=>setCollapsed({...collapsed(),[g().id]:!collapsed()[g().id]})),
    ForEach({items:()=>collapsed()[g().id] && !(data.searchQuery()||'').trim() ? [] : g().rows,key:key},r=>VStack({spacing:3},[
      Button(()=>r().title,()=>focus(r()),[HStack({spacing:7,directHover:true,hoverBackground:'#ffffff12',
        shortcutHint:()=>data.commandHeld()&&pinNumber(r())>0?'⌘'+pinNumber(r()):'',
        hoverDetails:()=>[r().title,r().provider+' · '+groupLabel(r()).replace(/^(Codex|Claude|Folder) · /,''),r().cwd,linked(r())?'Open in this window':'Click to resume in this window'].filter(Boolean).join('\n')},[
        ForEach({items:()=>data.providerFilter()==='All'?[r()]:[],key:key},p=>Image('',{provider:()=>p().provider}).frame({width:14,height:14})),
        Text(()=>r().title).nativeMarquee(0.04).font(12).lineLimit(1).truncation('tail')
      ]).paddingLeading(()=>g().pinned?10:28).paddingTrailing(1).paddingVertical(6).cornerRadius(7)
        .background(()=>{const x=linked(r());return selectedRow()===key(r()) || (x && x.w.selected) ? '#80808030' : null;})
      ])
    ]))
  ])),
  ForEach({items:()=>groups().length ? [] : [0],key:n=>n},()=>Text('No conversations found').font(12).secondary().padding(10))
]).padding(0));
