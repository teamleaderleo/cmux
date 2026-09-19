# cmux build performance benchmark

This benchmark treats build speed as complete useful-result latency. It keeps setup, build, app lifecycle, and first useful test result separate so a faster command does not hide a slower handoff.

The benchmark is intentionally run on one machine, one checkout, and one pinned Xcode/SDK. Run each arm at least five times and publish every sample, median, and p95. Do not combine measurements from different machines or thermal states.

## Arms

Run the matrix against these exact revisions:

| Arm | Revision | Purpose |
| --- | --- | --- |
| baseline | fork `main` | Existing build graph. |
| Glaeda profile | `teamleaderleo/cmux#56` | Native Apple warm-state/admission path. |
| keep-running | isolated `reload.sh` commit from `#60` | Removes post-build app termination for build-only loops. |
| sidecar dependency analysis | `#61` | Skips Diff Sidecar when its declared inputs are unchanged. |
| composed | merge the three candidate changes | Measures interaction, not an arithmetic sum. |

## Workload states

1. **Cold:** fresh DerivedData and native helper state.
2. **Warm no-op:** same checkout, no source changes.
3. **Swift-only edit:** change one app-target Swift implementation and revert it after the run.
4. **Sidecar edit:** change one declared Diff Sidecar source input and revert it after the run.
5. **First useful result:** record when the built app is launchable and when the focused test command first returns a trustworthy result.

The cold state is run once per arm for setup context. Warm states use five repetitions. The sidecar edit is the critical discriminator for PR #61; a Swift-only edit should avoid entering the sidecar phase after that change.

## Harness

From the cmux checkout, with GhosttyKit provisioned:

```bash
python3 scripts/bench-reload-build.py \
  --tag build-bench-baseline \
  --profile baseline-warm-noop \
  --iterations 5 \
  --derived-data /tmp/cmux-build-bench/baseline \
  --output /tmp/cmux-build-bench/baseline.json
```

Run the same command at each arm and change only `--profile`, `--tag`, and the isolated DerivedData path. Keep the tag and DerivedData unique per concurrent run. A failed sample remains in the JSON receipt and makes the harness exit nonzero.

The harness records every sample, including failed builds, in a JSON receipt. Use `--timeout` to bound a cold-cache or package-resolution stall; timed-out samples are failures and retain the captured output tail.

The manual CI workflow passes `--prod-auth` so a hosted or leased runner can
measure the build without starting the private GCP/Tailscale development
backend. This changes runtime endpoint configuration, not the Xcode build graph.

For a controlled multi-arm run, dispatch `.github/workflows/build-performance.yml` on a macOS runner. It runs baseline, the exact #56/#60/#61 commits, and a composed cherry-pick with the same workflow and receipt format. The workflow is manual-only so ordinary pull requests do not consume five macOS build slots.

The workflow pins Ghostty to the same revision and verified GhosttyKit checksum
manifest for every arm. This keeps an older candidate ref from failing merely
because its historical submodule revision predates the current prebuilt cache.

## Existing evidence

- PR #56 reports three unchanged tagged native builds at 29.11–33.57 seconds, median 31.87 seconds including Glaeda startup/admission. Its separate 46.56-second sample was uncontrolled.
- PR #60 reports no timing data; it changes the lifecycle after a build rather than the compilation path.
- PR #61 reports no timing data yet; its local full-build validation was blocked by an unprovisioned `GhosttyKit.xcframework`.
- Glaeda prior-art issue #1048 records one uncontrolled cmux hashing observation of 45.664 seconds versus an earlier 57.683-second baseline and a cache-retaining comment-only build of 30.737 seconds with zero SwiftCompile tasks. These are context, not PR-specific speedup claims.

## Reporting

Publish one table with:

- every sample, median, and p95;
- Xcode timing summary;
- Diff Sidecar phase duration and whether it ran;
- Glaeda admission/setup duration;
- app termination/relaunch duration;
- first useful test result;
- cache state and machine/Xcode/SDK identity.

There is no valid composed number until these arms run under the same conditions. Credit the build-state model as prior art from [teamleaderleo/Glaeda](https://github.com/teamleaderleo/glaeda) and the hot-path measurement discipline from [teamleaderleo/Tact](https://github.com/teamleaderleo/tact).
