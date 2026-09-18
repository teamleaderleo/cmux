// Shared live conversation sidebar. Metadata arrives as per-key context updates.
const history = computed(() => data.history() || []);
const [collapsed, setCollapsed] = signal({});
const [pending, setPending] = signal({});
const [failed, setFailed] = signal({});
// Filter, query and page size arrive atomically so a provider switch cannot
// briefly mount the previous provider's expanded page count.
function viewProvider() { return data.historyView?.()?.provider ?? data.providerFilter(); }
function viewQuery() { return data.historyView?.()?.query ?? (data.searchQuery?.() || ''); }
function viewLimit() { return data.historyView?.()?.limit ?? (data.visibleCount?.() || 24); }
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
function linked(r) {
  const target = liveLinks()[linkKey(r.provider, r.id)] || null;
  if (!target || target.panel) return target;
  // Old workspace-only markers predate panel bindings. Recover only an
  // unambiguous complete title segment; never guess from a truncated prefix.
  const matches = (target.w.tabs || []).filter(t => String(t.title || '').split(' | ').includes(r.title));
  return matches.length === 1 ? {...target, panel:matches[0].id} : null;
}

// Once a launched row is linked, its debounce has served its purpose. Do not
// keep a 15-second cooldown across closing and immediately reopening that tab.
effect(() => {
  const values = pending();
  const completed = history().filter(r => values[key(r)] && linked(r));
  if (!completed.length) return;
  const next = {...values};
  for (const r of completed) delete next[key(r)];
  setPending(next);
});

// A rejected host operation releases only its own pending request. Accepted
// dispatch still waits for a live binding; it does not mean the provider is ready.
effect(() => {
  const result = data.actionResult?.();
  if (!result || result.accepted !== false) return;
  const values = pending();
  const rowKey = Object.keys(values).find(k => values[k].operationID === result.operationID);
  if (!rowKey) return;
  setFailed({...failed(), [rowKey]: true});
  const next = {...values}; delete next[rowKey]; setPending(next);
});

function isSelected(r) {
  const target = linked(r);
  if (!target || !target.w.selected) return false;
  if (!target.panel) return (target.w.tabs || []).length === 1 && !!target.w.tabs[0].focused;
  return (target.w.tabs || []).some(t => t.id === target.panel && t.focused);
}
function newOperationID() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g,c=>{const n=Math.floor(Math.random()*16);return (c==='x'?n:(n&3)|8).toString(16);});
}
function providerCommand(provider) {
  return provider === 'Claude' ? 'claude' : provider === 'OpenCode' ? 'opencode' : 'codex';
}
// A group header's folder is a real directory, so a new chat can start there
// instead of inheriting whatever workspace happens to be selected.
function groupDirectory(g) {
  if (g.pinned) return null;
  if (g.name && g.name.startsWith('/')) return g.name;
  return g.rows.length ? g.rows[0].cwd || null : null;
}
function newChatInGroup(g) {
  const directory = groupDirectory(g);
  if (!directory) return;
  const provider = g.rows.length ? g.rows[0].provider : 'Codex';
  cmux('workspace.create', {title: 'New ' + provider + ' chat', working_directory: directory,
    initial_command: providerCommand(provider), conversation_placement: 'tab',
    operation_id: newOperationID(), focus: true});
}
function focus(r) {
  const target = linked(r);
  if (target) {
    cmux('workspace.select', {workspace_id: target.w.id});
    if (target.panel) cmux('surface.focus', {workspace_id: target.w.id, surface_id: target.panel});
  } else resume(r);
}
function resume(r) {
  if (linked(r)) return focus(r);
  if (Date.now() - (pending()[key(r)]?.started || 0) < 15000) return;
  const operationID = newOperationID();
  const failures = {...failed()}; delete failures[key(r)]; setFailed(failures);
  setPending({...pending(), [key(r)]: {started: Date.now(), operationID}});
  cmux('workspace.create', {title: r.title, working_directory: r.cwd,
    description: 'tk-history:' + key(r), initial_command: r.command, conversation_placement: 'tab',
    operation_id: operationID, focus: true});
}

function visibleHistory() {
  return history().filter(r => viewProvider() === 'All' || r.provider === viewProvider());
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
const allGroups = computed(() => conversationGroups(history(), viewProvider(), viewQuery()));
function pageGroups(all, limit, hidden = {}, searching = false) {
  let remaining = limit;
  return all.flatMap(group => {
    if (remaining <= 0) return [];
    if (hidden[group.id] && !searching) return [{...group, rows:[]}];
    const rows = group.rows.slice(0, remaining);
    remaining -= rows.length;
    return [{...group, rows}];
  });
}
const groups = computed(() => pageGroups(allGroups(), viewLimit(), collapsed(), !!viewQuery().trim()));
function conversationList() { return VStack({spacing:2}, [
  ForEach({items:groups,key:g=>g.id},g=>VStack({spacing:2},[
    HStack({spacing:5},[
      HStack({spacing:5},[
        ForEach({items:()=>g().pinned?[]:[g().id],key:n=>n},n=>Image('folder').font(12).secondary()),
        Text(()=>g().name.startsWith('/')?g().name.split('/').filter(Boolean).pop():g().name)
          .font(()=>g().pinned?11:12).weight('regular').color(()=>g().pinned?'secondary':'primary').lineLimit(1), Spacer()
      ]).paddingLeading(10).paddingVertical(4).onTap(()=>setCollapsed({...collapsed(),[g().id]:!collapsed()[g().id]})),
      ForEach({items:()=>groupDirectory(g())?[g().id]:[],key:n=>n},n=>
        Button(()=>'New chat in '+(g().name.startsWith('/')?g().name.split('/').filter(Boolean).pop():g().name),
          ()=>newChatInGroup(g()),
          [Image('plus').font(11).secondary().paddingHorizontal(6).paddingVertical(4)]))
    ]).paddingTrailing(4),
    ForEach({items:()=>collapsed()[g().id] && !viewQuery().trim() ? [] : g().rows,key:key},r=>VStack({spacing:3},[
      Button(()=>r().title,()=>focus(r()),[HStack({spacing:7,directHover:true,hoverBackground:'#ffffff12',
        shortcutHint:()=>data.commandHeld()&&pinNumber(r())>0?'⌘'+pinNumber(r()):'',
        hoverDetails:()=>[r().title,r().provider+' · '+groupLabel(r()).replace(/^(Codex|Claude|Folder) · /,''),r().cwd,linked(r())?'Open in this window':'Click to resume in this window'].filter(Boolean).join('\n')},[
        ForEach({items:()=>viewProvider()==='All'?[r()]:[],key:key},p=>Image('',{provider:()=>p().provider}).frame({width:14,height:14})),
        Text(()=>r().title).nativeMarquee(0.04).font(12).lineLimit(1).truncation('tail')
      ]).paddingLeading(()=>g().pinned?10:28).paddingTrailing(1).paddingVertical(6).cornerRadius(7)
        .background(()=>isSelected(r()) ? '#80808030' : null)
      ]).conversationProvider(()=>r().provider).conversationID(()=>r().id)
        .conversationTitle(()=>r().title).conversationDirectory(()=>r().cwd),
      ForEach({items:()=>failed()[key(r())] && !linked(r())?[key(r())]:[],key:n=>n},()=>
        Button(()=>data.launchFailureLabel(),()=>focus(r()),[
          Text(()=>data.launchFailureLabel()).font(11).secondary()
        ]).paddingLeading(()=>g().pinned?10:28).paddingVertical(2)
      )
    ]))
  ])),
  ForEach({items:()=>groups().length ? [] : [0],key:n=>n},()=>Text('No conversations found').font(12).secondary().padding(10))
]).padding(0); }

function workspaceRows(workspaces, query) {
  const needle = String(query || '').trim().toLowerCase();
  return workspaces.filter(w => !needle || [w.title, w.directory, ...(w.tabs || []).map(t => t.title)].some(v => String(v || '').toLowerCase().includes(needle)));
}
function focusSurface(w, t) {
  cmux('workspace.select', {workspace_id:w.id});
  cmux('surface.focus', {workspace_id:w.id, surface_id:t.id});
}
function openList() {
  return VStack({spacing:2}, [
    ForEach({items:()=> (data.workspaces() || []).filter(w=>w.selected && data.showOpenTabs?.() !== false),key:w=>w.id},w=>
      VStack({spacing:2},[
        ForEach({items:()=>w().tabs || [],key:t=>t.id},t=>
          Button(()=>t().title,()=>focusSurface(w(),t()),[
            HStack({spacing:6,directHover:true,hoverBackground:'#ffffff12'},[
              Image('rectangle').font(11).secondary(),
              Text(()=>t().title).font(12).lineLimit(1).nativeMarquee(0.04)
            ]).paddingLeading(10).paddingTrailing(2).paddingVertical(5).cornerRadius(7)
              .background(()=>t().focused?'#80808030':null)
          ])
        )
      ])
    )
  ]);
}
sidebar(()=>VStack({spacing:3},[
  openList(), Divider().paddingVertical(4),
  Text(()=>data.historyLabel ? (data.historyLabel() || 'History') : 'History').font(11).secondary().paddingLeading(10).paddingVertical(3),
  conversationList()
]).padding(0));
