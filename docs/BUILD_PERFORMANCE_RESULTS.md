# cmux build benchmark results

This ledger records measurements without mixing cold graph setup, warm tagged
reloads, and complete useful-result latency. A missing value means the arm has
not been measured under the controlled protocol in `BUILD_PERFORMANCE.md`.

## Current evidence

| Arm or observation | State | Samples | Result | Evidence and limits |
| --- | --- | ---: | --- | --- |
| PR #56 native Apple profile | warm tagged native builds | 3 | 29.11s, 31.87s median, 33.57s | PR body; includes Glaeda startup/admission; same-machine conditions were not published. |
| PR #56 separate warm sample | warm, uncontrolled | 1 | 46.56s | PR body; background and thermal conditions were uncontrolled. |
| PR #60 keep-running | behavior-only | 0 | unmeasured | Changes post-build app lifecycle; no timing receipt in the PR. |
| PR #61 Diff Sidecar dependency analysis | behavior/build-graph | 0 | unmeasured | Declared inputs/output are present; phase-duration savings require an actual Xcode build. |
| composed (#56 + #60 + #61) | controlled | 0 | unmeasured | No valid additive estimate exists because the arms measure different parts of the loop. |
| Glaeda prior-art timestamp-only check | one active-Mac observation | 1 | 45.664s vs 57.683s earlier baseline | Context from Glaeda issue #1048; not attributable to a cmux PR. |
| Glaeda prior-art comment-only build | cache-retaining | 1 | 30.737s; zero SwiftCompile tasks | Context from Glaeda issue #1048; not a cmux build measurement. |
| Local cmux fresh DerivedData probe | fresh DerivedData, reused SwiftPM source cache | 1 | 9m04s, still compiling `cmux`; terminated after no progress | GhosttyKit was provisioned. This is a cold-ish full graph, not comparable to the warm tagged sample. |
| Local cmux resumed probe | same DerivedData, 300s bound | 1 | timed out at 300s while still compiling `cmux` | Confirms the full graph is too expensive to repeat locally for the matrix. |

## Interpretation

The only controlled-looking cmux timing currently available is PR #56's three
unchanged tagged builds. It is a useful warm-loop anchor, not a baseline for
the raw Xcode graph. PR #60 has no compile-path timing, and PR #61 has no
phase-duration receipt yet. The local fresh-graph probes demonstrate why the
benchmark must distinguish fresh DerivedData from small-scoped warm edits.

## Missing controlled run

The required baseline, #56, #60, #61, and composed matrix still needs one
machine, one pinned Xcode/SDK, five warm repetitions per workload, and one cold
setup sample per arm. It should report no-op, one Swift-file edit, and one
Diff Sidecar-input edit, plus p50/p95, `xcodebuild -showBuildTimingSummary`,
whether the sidecar phase ran, Glaeda admission, app relaunch, and first useful
test result.

The current machine cannot reach that fleet: Cloud Machines return
`cloud_disabled`, the Macfleet host manifest is absent, and no fleet lease
credentials are present. This is an infrastructure prerequisite, not a
benchmark result.

Prior art: [teamleaderleo/Glaeda](https://github.com/teamleaderleo/glaeda) and
[teamleaderleo/Tact](https://github.com/teamleaderleo/tact).
