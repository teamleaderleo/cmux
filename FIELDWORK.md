# Terminal input ACK: scope and follow-up notes

Context: fork PR #52 (`fix/terminal-input-owner-ack-current-main`), product head at time of note: `a55ddc3c9b3fc39988c8524f0eb85a5311e61d3b`.

This note is intentionally outside PR #52. It records what belongs in the core correctness change and what should be separate follow-up work, if we choose to do it at all.

## Core problem

The original bug is narrow:

CMUX must not durably report `terminal.input.*` success merely because it wrote an `Input` frame to the terminal-host socket. Success should require acknowledgement from the authoritative PTY owner after its `write_all + flush` completes.

That is the feature. Everything else should be justified against that boundary.

## What the core PR should contain

A slim upstreamable version of this work should contain only the pieces needed to establish and safely exercise that acknowledgement contract:

- additive `InputAck` protocol support;
- nonzero request IDs for receipted terminal API input;
- host ACK only after authoritative PTY `write_all + flush` succeeds;
- production Surface reader dispatch for targeted `InputAck`;
- split-phase hosted wait so the Surface runtime lock is released before waiting for the ACK;
- ordinary interactive input remains request-id `0`, fire-and-forget;
- legacy hosts reject effectful receipted input before sending bytes;
- conservative `Known` versus `Indeterminate` classification around the submission boundary;
- only the minimum receipt bookkeeping needed to keep concurrent/pipelined requests safe and bounded;
- resource-router integration for `terminal.input.write`, `.keys`, `.mouse`, and `.focus`.

No exactly-once guarantee should be implied. The ACK only certifies that the authoritative PTY writer completed the submitted write/flush. It does not certify shell read, parse, or execution.

## Tests worth keeping in the core PR

Tests are useful when they prove a contract or a race that could otherwise regress. The core PR should keep a small, high-value set rather than every adversarial case discovered during review.

Keep tests that prove:

1. the host does not ACK before both PTY write and flush complete;
2. a real `InputAck` traverses the production hosted-Surface reader and completes the caller;
3. receipted writes can pipeline while an earlier ACK is withheld, and request-id-zero interactive input still flows;
4. timeout/abort does not wait behind the socket-writer mutex;
5. a post-submit disconnect is `Indeterminate`, while capability/window/exited-host rejections that occur before transmission are `Known`;
6. legacy hosts never receive bytes from effectful receipted input.

Failure-path tests for partial write, flush failure, and post-delivery ACK enqueue rejection are defensible, but they should stay only if they remain compact and directly protect the success boundary. Do not grow a full failure-matrix test program inside the core patch.

## Work that should NOT be required for the ACK correctness PR

The following are useful ideas, but they are separate concerns and should not be bundled into the upstream ACK patch merely because they were discovered while reviewing it.

### Follow-up PR A: observability, only if production evidence justifies it

Possible scope:

- submission-duration versus ACK-wait-duration metrics;
- ACK timeout pressure / outstanding receipt counts and bytes;
- host-side last-failure diagnostics for PTY write, PTY flush, and ACK enqueue rejection;
- any `server-stats` schema change;
- private diagnostic sidecars.

Reason to separate: this adds API/schema and filesystem behavior without changing the receipt correctness contract. It can be reviewed, shipped, or dropped independently.

The current fork PR contains this work, but an upstream-focused ACK PR should strongly consider removing it and carrying it as its own follow-up only if there is a real operational need.

### Follow-up PR B: timeout / late-ACK availability policy, only if production evidence justifies it

Possible scope:

- tune the 2-second ACK observation deadline;
- replace whole-attachment poisoning with a bounded late-ACK drain state;
- retain abandoned request IDs and budgets long enough to consume late ACKs safely.

Reason to separate: this is availability/tuning behavior, not a correctness hole in the ACK boundary. The conservative current policy is acceptable unless measurements show it is materially harmful.

### Follow-up PR C: request-ID exhaustion hardening

Possible scope:

- shared exhaustion-latching `u64` request-ID allocator;
- explicit no-reuse behavior after wrap/exhaustion across targeted control requests.

Reason to separate: theoretical hardening. It is not needed to fix the original false-success bug.

### Follow-up PR D: split `terminal_host_runtime.rs`

`terminal_host_runtime.rs` has become a catch-all for too many responsibilities. A behavior-neutral refactor should be its own PR, ideally before more terminal-host features accumulate.

Suggested extraction boundaries:

- `terminal_host_runtime/attachment.rs`: `HostAttachment`, `ControlResponses`, receipt types, targeted control-response ownership;
- `terminal_host_runtime/service.rs`: host spawn/adoption, service lifecycle, client handling, termination;
- `terminal_host_runtime/stream.rs`: `HostTap`, output/state queueing, smart-renderer retention/parser broadcast machinery;
- `terminal_host_runtime/records.rs`: discovery/liveness/exit records and any diagnostic sidecars.

Move the associated tests next to the extracted modules instead of leaving another enormous test module behind.

Important constraint: do this as pure moves first, with essentially zero behavior changes. Re-run the same hosted differential after each extraction. Do not combine the structural refactor with the ACK correctness patch.

### Follow-up PR E: test organization / fixture cleanup

If terminal-host tests continue growing, move reusable hosted-socket fixtures and receipt-specific tests into dedicated test modules/files. The goal is not fewer tests; it is keeping production modules readable and making the contract tests easy to find.

Again, this is maintenance work, not part of the original bug fix.

## Scope rule for future review

When reviewing the ACK patch, distinguish these questions:

- Does this finding show that the implementation can still report success without authoritative PTY write/flush completion? If yes, it is a correctness blocker for the core PR.
- Does this finding show that the core implementation can deadlock, serialize all input, corrupt waiter ownership, send effectful bytes to an incapable legacy host, or misclassify a provably pre-submit failure? If yes, it is likely core.
- Does this finding improve diagnostics, tuning, ergonomics, theoretical hardening, code organization, or breadth of adversarial coverage without changing the receipt guarantee? Then record it here and make it a separate PR, or do not do it.

The intended stopping point is simple: implement the owner acknowledgement correctly, retain a compact set of tests proving the critical boundary and concurrency behavior, and stop.