# Conversation verification

Tracking: https://github.com/teamleaderleo/Tact/issues/43

## Deterministic sidebar contracts

Run from the cmux checkout; no installation, provider login, native build, or live session is required:

```sh
node scripts/test-conversation-sidebar.cjs
node --test scripts/test-conversation-lifecycle-runtime.cjs
```

The first command runs the existing grouping, selection, paging, focus and disposed-handler checks. The second adds 18 tests, using the production sidebar and reactive runtime with a controlled clock and captured host actions, parameterized across Codex, Claude and OpenCode:

- Rendering/filtering/paging 30 history entries emits no launch request.
- Matching session IDs from another provider do not claim this provider’s conversation.
- Ten repeated clicks emit one create request; a linked session emits exact workspace/panel focus actions, including after a move.
- Ten close/restore cycles at the same clock time each emit one fresh operation. A stale agent record with no corresponding panel is not a live owner.
- An explicit host rejection permits immediate retry; an old result cannot release a newer request. Accepted dispatch waits for a live binding.
- An unconfirmed launch without a rejection still suppresses retries for the current 15-second timeout.

The host now acknowledges action acceptance through the injected dispatch and JavaScript runtime. A rejected tab insertion or explicit socket rejection releases only the matching operation. Ambiguous replies retain the guard. This acknowledgement does not establish provider readiness or detect a provider that exits after its terminal was created; the 15-second fallback remains for unconfirmed ownership.

The Swift runtime suite exercises acknowledgement delivery with both accepted and rejected responses using an injected async sink and event stream, without providers or sleeps.

The `Conversation sidebar contracts` workflow runs both commands on relevant pushes and pull requests using Linux and Node 22. Pushes can use the configured GitHub SSH identity; the HTTPS OAuth credential used initially cannot update workflows. Local passage does not claim a remote CI result.

## Existing native coverage: present, not rerun in this pass

`cmuxTests/SurfaceResumeRestoreClaimTests.swift` covers exact binding generations, conflicting claims and panel teardown release. `cmuxTests/AgentRestoreLiveOwnerAdmissionTests.swift` covers live/dead/stale owner admission and process identity revalidation. These complement the sidebar tests; their presence is not evidence that this candidate passed native tests.

## Still requires native integration evidence

Captured host actions do not establish OS keyboard focus, successful pane movement, drag-and-drop, actual process teardown, or provider readiness. Use an isolated tagged app for those checks. Measure preview-visible and interactive timing separately, and compare settled process/memory counts over repeated cycles. Do not interpret the JavaScript ten-cycle test as a memory or orphan-process test.

The earlier native build and focused checks remain historical evidence for their tested commit. The acknowledgement change touches native runtime code and requires a new tagged build; Node results alone do not validate that bridge.

## Repository ownership

cmux owns these contracts because it owns the executed sidebar/runtime. terminal-kit should own future provider-adapter smoke tests and reproducible setup, linking here rather than copying cmux tests. Tact owns the interaction questions and trial results. Native behavior changes still need focused native validation and user dogfood.
