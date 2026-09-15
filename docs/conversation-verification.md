# Conversation verification

Tracking: https://github.com/teamleaderleo/Tact/issues/43

## Deterministic sidebar contracts

Run from the cmux checkout; no installation, provider login, native build, or live session is required:

```sh
node scripts/test-conversation-sidebar.cjs
node --test scripts/test-conversation-lifecycle-runtime.cjs
```

The first command runs the existing grouping, selection, paging, focus and disposed-handler checks. The second adds 12 tests, using the production sidebar and reactive runtime with a controlled clock and captured host actions, parameterized across Codex, Claude and OpenCode:

- Rendering/filtering/paging 30 history entries emits no launch request.
- Ten repeated clicks emit one create request; a linked session emits exact workspace/panel focus actions, including after a move.
- Ten close/restore cycles at the same clock time each emit one fresh operation. A stale agent record with no corresponding panel is not a live owner.
- An unconfirmed launch suppresses retries for the current 15-second timeout.

The last item characterizes a limitation, not a desired latency target: there is no explicit launch-failure acknowledgement in this sidebar flow. Replace timeout-only recovery with authoritative operation completion/error handling in a future runtime change.

CI wiring is pending: GitHub rejected adding the workflow because the current OAuth credential lacks workflow scope. The draft is preserved locally at `/Users/leoli/Projects/recovery/conversation-sidebar-contracts.yml`. Run both commands manually meanwhile; local passage does not claim a remote CI result.

## Existing native coverage: present, not rerun in this test-only pass

`cmuxTests/SurfaceResumeRestoreClaimTests.swift` covers exact binding generations, conflicting claims and panel teardown release. `cmuxTests/AgentRestoreLiveOwnerAdmissionTests.swift` covers live/dead/stale owner admission and process identity revalidation. These complement the sidebar tests; their presence is not evidence that this candidate passed native tests.

## Still requires native integration evidence

Captured host actions do not establish OS keyboard focus, successful pane movement, drag-and-drop, actual process teardown, or provider readiness. Use an isolated tagged app for those checks. Measure preview-visible and interactive timing separately, and compare settled process/memory counts over repeated cycles. Do not interpret the JavaScript ten-cycle test as a memory or orphan-process test.

The earlier native build and focused checks remain historical evidence for their tested commit; no app/runtime code changed in this test-only increment, so it does not require another app build merely to run the Node contracts.

## Repository ownership

cmux owns these contracts because it owns the executed sidebar/runtime. terminal-kit should own future provider-adapter smoke tests and reproducible setup, linking here rather than copying cmux tests. Tact owns the interaction questions and trial results. Native behavior changes still need focused native validation and user dogfood.
