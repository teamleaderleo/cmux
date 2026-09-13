// Shared live conversation sidebar. Metadata arrives as per-key context updates.
const history = computed(() => data.history() || []);
const [collapsed, setCollapsed] = signal({});
const [detail, setDetail] = signal('');
const [selectedRow, setSelectedRow] = signal('');
const [pending, setPending] = signal({});
const [showMore, setShowMore] = signal(false);
function key(r) { return r.provider + ':' + r.id; }
function buildLinks(workspaces) {
  const links = Object.create(null);
  const fallback = Object.create(null);
  for (const w of workspaces) {
    const panels = new Set((w.tabs || []).map(t => t.id));
    for (const a of w.agents || []) {
      const kind = String(a.kind).toLowerCase();
      const provider = kind.includes('claude') ? 'Claude' : kind.includes('codex') ? 'Codex' : kind.includes('opencode') ? 'OpenCode' : null;
      if (!provider || !panels.has(a.panelId)) continue;
      const id = provider + ':' + String(a.id).toLowerCase();
      if (!links[id]) links[id] = {w, panel:a.panelId};
    }
    if (String(w.description || '').startsWith('tk-history:')) {
      const id = w.description.slice('tk-history:'.length);
      if (!fallback[id]) fallback[id] = {w,panel:null};
    }
  }
  // A known hosting agent beats an old placeholder workspace anywhere in the window.
  return {...fallback,...links};
}
const liveLinks = computed(() => buildLinks(data.workspaces() || []));
function linked(r) { return liveLinks()[r.provider + ':' + r.id.toLowerCase()] || null; }

function focus(r) {
  setSelectedRow(key(r));
  const target = linked(r);
  if (target) {
    cmux('workspace.select', {workspace_id: target.w.id});
    if (target.panel) cmux('surface.focus', {workspace_id: target.w.id, surface_id: target.panel});
    setDetail('');
  } else setDetail(detail() === key(r) ? '' : key(r));
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
function conversationGroups(rows, provider, query, expanded) {
  const needle = query.trim().toLowerCase();
  const groups = new Map();
  for (const r of rows) {
    if (provider !== 'All' && r.provider !== provider) continue;
    if (needle && ![r.title,r.group,r.provider,r.cwd].join(' ').toLowerCase().includes(needle)) continue;
    const id = r.pinned ? 'pins' : provider === 'All' && r.canonical_folder ? 'folder:'+r.canonical_folder : 'group:'+r.group;
    const name = r.pinned ? 'Pinned' : provider === 'All' && r.canonical_folder ? r.canonical_folder : r.group.replace(/^(Codex|Claude|Folder) · /,'');
    if (!groups.has(id)) groups.set(id, {id, name, pinned:!!r.pinned, updated:0, rows:[]});
    const g = groups.get(id); g.updated = Math.max(g.updated, r.updated); g.rows.push(r);
  }
  const result = Array.from(groups.values()).sort((a,b) => Number(b.pinned)-Number(a.pinned) || b.updated-a.updated || a.id.localeCompare(b.id));
  for (const group of result) {
    if (!group.pinned) group.rows.sort((a,b) => b.updated-a.updated || key(a).localeCompare(key(b)));
    // Preserve inherited/manual pin order. Cap within projects, never drop whole projects.
    if (!expanded && !needle && !group.pinned) group.rows = group.rows.slice(0, 5);
  }
  return result;
}
const groups = computed(() => conversationGroups(history(), data.providerFilter(), data.searchQuery() || '', showMore()));
sidebar(() => VStack({spacing:2}, [
  ForEach({items:groups,key:g=>g.id},g=>VStack({spacing:2},[
    HStack({spacing:5},[
      ForEach({items:()=>g().pinned?[]:[g().id],key:n=>n},n=>Image('folder').font(12).secondary()),
      Text(()=>g().name.startsWith('/')?g().name.split('/').filter(Boolean).pop():g().name)
        .font(()=>g().pinned?11:12).weight('regular').color(()=>g().pinned?'secondary':'primary').lineLimit(1), Spacer()
    ]).paddingLeading(10).paddingVertical(4).onTap(()=>setCollapsed({...collapsed(),[g().id]:!collapsed()[g().id]})),
    ForEach({items:()=>collapsed()[g().id] && !(data.searchQuery()||'').trim() ? [] : g().rows,key:key},r=>VStack({spacing:3},[
      Button(()=>r().title,()=>focus(r()),[HStack({spacing:7,directHover:true,
        shortcutHint:()=>data.commandHeld()&&pinNumber(r())>0?'⌘'+pinNumber(r()):'',
        hoverDetails:()=>[r().title,r().provider+' · '+r().group.replace(/^(Codex|Claude|Folder) · /,''),r().cwd,linked(r())?'Linked in this window':'Not linked in this window'].filter(Boolean).join('\n')},[
        ForEach({items:()=>data.providerFilter()==='All'?[r()]:[],key:key},p=>Image('',{provider:()=>p().provider}).frame({width:14,height:14})),
        Text(()=>r().title).nativeMarquee(0.04).font(12).lineLimit(1).truncation('tail')
      ]).paddingLeading(()=>g().pinned?10:28).paddingTrailing(1).paddingVertical(6).cornerRadius(7)
        .background(()=>{const x=linked(r());return selectedRow()===key(r()) || (x && x.w.selected) ? '#80808030' : null;})
      ]),
      ForEach({items:()=>detail()===key(r()) && !linked(r()) ? [r()] : [],key:key},d=>VStack({spacing:5},[
        Text('Not linked in this window. It may be open in another app.').font(11).secondary().lineLimit(3),
        Text(()=>d().cwd).font(10).secondary().lineLimit(2),
        Button(()=>pending()[key(d())] ? 'Resume requested' : 'Resume in a new terminal',()=>resume(d()))
      ]).padding(8))
    ]))
  ])),
  Button(()=>showMore() ? 'Show fewer' : 'Show more',()=>setShowMore(!showMore())),
  ForEach({items:()=>groups().length ? [] : [0],key:n=>n},()=>Text('No conversations found').font(12).secondary().padding(10))
]).padding(0));
