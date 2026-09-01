# cmux nonlinear resource-collapse probes

These files belong to the owned-fork Fieldwork experiment rooted at upstream
`8ef183f1e5de765b183aec9d1799f17a0848ae84`.

They are investigation code. They deliberately avoid production changes until
a scaling knee and cleanup boundary execute on the owned fork.

## RPC write-admission probe

Test file:

`Packages/macOS/CmuxRemoteDaemon/Tests/CmuxRemoteDaemonTests/RemoteDaemonRPCClientWriteAdmissionScalingTests.swift`

Run on macOS:

```sh
swift test \
  --package-path Packages/macOS/CmuxRemoteDaemon \
  --filter RemoteDaemonRPCClientWriteAdmissionScalingTests
```

The suite has two halves:

1. **Negative control:** a fake SSH helper continuously reads stdin and answers
   every RPC. A 200-caller burst must finish and report zero call failures.
2. **Stalled physical write:** the helper answers initial `hello`, stays alive,
   then stops reading stdin. A direct 4 MiB physical write occupies
   `RemoteDaemonRPCClient.writeQueue`. Bursts of 1, 10, 50, and 200 calls use a
   50 ms response timeout and are required to settle within 750 ms.

Current source order registers a pending call before entering `writeQueue` and
starts `waitForCall` after the physical write. The stalled cases are therefore
intended as a red test against the pinned revision. The fake helper exits after
two seconds so a red run cleans itself up instead of leaving CI workers parked.

The interesting evidence is the scaling owner, not CPU usage: one physical
writer takes the global lane to zero service rate; every later caller can retain
its pending-call owner before its response timeout starts.

## Journal backlog model

Run:

```sh
python3 scripts/fieldwork/cmux-resource-collapse/journal_backlog_model.py
```

Optional recovery service-rate calculation:

```sh
python3 scripts/fieldwork/cmux-resource-collapse/journal_backlog_model.py \
  --recovery-service-records-per-second 2000
```

JSON output:

```sh
python3 scripts/fieldwork/cmux-resource-collapse/journal_backlog_model.py --json
```

The script reads the following constants directly from
`cmux-tui/crates/chatmux-relay/src/journal_forwarder.rs` before calculating:

- `MAX_BATCH_RECORDS`
- `MAX_BATCH_BODY_BYTES`
- `MAX_DISCOVERED_SESSIONS`
- `DEFAULT_REQUEST_TIMEOUT`
- `DEFAULT_MAX_BACKOFF`

Default scenario:

- requested sessions: 1, 10, 50, 128, 200
- 10 records/s/session
- 2 KiB encoded record
- 60 second POST outage
- the first 100-record batch is already in `post_with_retry`

The model is explicitly illustrative. It proves arithmetic and source-bound
limits; it does not claim measured RSS.

## macOS process sampler

Run alongside a real scaling harness:

```sh
scripts/fieldwork/cmux-resource-collapse/macos_process_sampler.sh \
  <pid> /tmp/cmux-resource-samples.csv 0.5
```

Columns:

- epoch timestamp
- RSS KiB
- thread count
- total open-file rows from `lsof`
- IPv4/IPv6 socket count
- Unix socket count
- direct child count
- recursive descendant count

For a meaningful teardown result, keep sampling after load generation stops and
through at least one full retry/timeout interval. A clean-shutdown control should
return owned descriptors, sockets, descendants, and memory close to the
pre-load baseline.

## Workflow

`.github/workflows/fieldwork-nonlinear-resource-collapse.yml` runs the journal
model on Linux and the Swift RPC probe on a GitHub-hosted macOS runner when the
owned experiment branch receives a push. If fork Actions policy prevents a
branch-only workflow from launching, run the commands above on a macOS checkout
or promote a verifier onto the fork's CI surface without placing verifier-only
changes into any future upstream candidate diff.

## Evidence boundary

- Source ownership and constants: observed on the pinned revision.
- Journal output from the Python script: modelled / illustrative.
- Swift responsive-control result: executed only after a macOS run completes.
- Swift stalled-write result: executed only after a macOS run completes.
- No result in this directory authorizes upstream contact or mutation.
