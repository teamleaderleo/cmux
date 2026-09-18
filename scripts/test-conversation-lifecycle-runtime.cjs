// Production sidebar + reactive runtime; no providers, sockets, sleeps or native app.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const resources = path.join(__dirname, '../Packages/macOS/CmuxSwiftRenderUI/Sources/CmuxSwiftRenderUI/Resources');
function fixture(provider) {
  const nodes = new Map(), actions = [];
  let now = 1800000000000;
  const host = vm.createContext({
    Date: class extends Date { static now() { return now; } },
    __host_applyOps(raw) {
      for (const op of JSON.parse(raw)) {
        if (op.op === 'create') nodes.set(op.id, {id: op.id, type: op.type});
        if (op.op === 'update') nodes.get(op.id)[op.key] = op.value;
        if (op.op === 'remove') nodes.delete(op.id);
      }
    },
    __host_action: raw => actions.push(JSON.parse(raw)),
    __host_log: message => { throw new Error(message); }
  });
  vm.runInContext(fs.readFileSync(path.join(resources, 'SidebarRuntime.js'), 'utf8'), host);
  const set = (key, value) => host.__setData(key, JSON.stringify(value));
  const history = Array.from({length: 30}, (_, i) => ({provider, id: 'session'+i,
    title: 'Conversation '+i, cwd: '/project', group: '/project', updated: 30-i,
    command: 'fixture resume session'+i}));
  set('history', history); set('workspaces', []);
  set('launchFailureLabel', 'Could not open. Click to retry.');
  set('historyView', {provider: 'All', query: '', limit: 24});
  vm.runInContext(fs.readFileSync(path.join(resources, 'ConversationSidebar.js'), 'utf8'), host);
  const click = () => {
    const row = [...nodes.values()].find(n => n.type === 'button' && n.conversationID === 'session0');
    assert.ok(row); host.__dispatch(row.id, 'tap', '{}');
  };
  const owner = (workspace, panel) => ({id: workspace, selected: true,
    agents: [{id: 'session0', kind: provider.toLowerCase(), panelId: panel}],
    tabs: [{id: panel, surfaceId: 'internal-'+panel, title: 'Conversation 0', focused: true}]});
  return {actions, set, click, owner, failed: () => [...nodes.values()].some(n => n.text === 'Could not open. Click to retry.'), advance: ms => { now += ms; }};
}
for (const provider of ['Codex', 'Claude', 'OpenCode']) {
  test(provider+': another provider with the same session ID cannot own the conversation', () => {
    const f = fixture(provider);
    const other = f.owner('other-provider', 'wrong-panel');
    other.agents[0].kind = provider === 'Codex' ? 'claude' : 'codex';
    f.set('workspaces', [other]);
    f.click();
    assert.equal(f.actions.length, 1);
    assert.equal(f.actions[0].method, 'workspace.create');
    assert.equal(f.actions[0].params.description, 'tk-history:'+provider+':session0');
  });
  test(provider+': rejected launch retries immediately and stale failure cannot release the new request', () => {
    const f = fixture(provider); f.click();
    const first = f.actions[0].params.operation_id;
    f.set('actionResult', {operationID: first, accepted: false});
    assert.equal(f.failed(), true);
    f.click(); assert.equal(f.actions.length, 2);
    assert.equal(f.failed(), false);
    f.set('actionResult', {operationID: first, accepted: false});
    assert.equal(f.failed(), false, 'Stale rejection must not display a new failure');
    f.click(); assert.equal(f.actions.length, 2);
    assert.equal(f.failed(), false);
    f.set('actionResult', {operationID: f.actions[1].params.operation_id, accepted: true});
    f.click(); assert.equal(f.actions.length, 2, 'Accepted dispatch is not confirmed ownership');
  });
  test(provider+': history/filter/scroll updates never request launches', () => {
    const f = fixture(provider);
    for (const view of [
      {provider, query: '', limit: 24}, {provider: 'All', query: '', limit: 48},
      {provider: 'All', query: 'Conversation 29', limit: 24}
    ]) f.set('historyView', view);
    assert.deepEqual(f.actions, []);
  });
  test(provider+': repeated clicks coalesce; linked focus follows a moved panel', () => {
    const f = fixture(provider);
    for (let i=0; i<10; i++) f.click();
    assert.equal(f.actions.length, 1);
    assert.equal(f.actions[0].method, 'workspace.create');
    f.set('workspaces', [f.owner('original', 'panel-a')]);
    f.click();
    assert.deepEqual(f.actions.slice(-2).map(a => [a.method, a.params]), [
      ['workspace.select', {workspace_id: 'original'}],
      ['surface.focus', {workspace_id: 'original', surface_id: 'panel-a'}]
    ]);
    f.set('workspaces', [f.owner('moved', 'panel-b')]); f.click();
    assert.deepEqual(f.actions.at(-1).params, {workspace_id: 'moved', surface_id: 'panel-b'});
    assert.equal(f.actions.filter(a => a.method === 'workspace.create').length, 1);
  });
  test(provider+': ten immediate close/restore cycles each request exactly one new operation', () => {
    const f = fixture(provider);
    for (let i=0; i<10; i++) {
      f.click(); f.click();
      f.set('workspaces', [f.owner('work', 'panel-'+i)]);
      // Stale agent metadata cannot own a removed panel.
      f.set('workspaces', [{...f.owner('work', 'panel-'+i), tabs: []}]);
    }
    const creates = f.actions.filter(a => a.method === 'workspace.create');
    assert.equal(creates.length, 10);
    assert.equal(new Set(creates.map(a => a.params.operation_id)).size, 10);
    assert.ok(creates.every(a => a.params.initial_command === 'fixture resume session0'));
  });
  test(provider+': absent ownership suppresses retry until the existing 15-second timeout', () => {
    const f = fixture(provider); f.click();
    f.advance(14999); f.click(); assert.equal(f.actions.length, 1);
    f.advance(1); f.click(); assert.equal(f.actions.length, 2);
    // Characterizes current timeout; does not claim failure acknowledgements exist.
  });
}
