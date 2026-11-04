# Development and validation

The backend is tested with Emacs 30.2 and 31.1 on macOS arm64,
P4/P4D 2024.2/3084003, and diff-hl 1.10.0 at
`2d7d0714d9637f54af672987c65b6973b31e56a2`. The minimum requirement remains
Emacs 30.1; that exact patch release has not been run.
Validate other environments using the workspace smoke check.

## Checks

- Warning-free byte compilation.
- 81 backend/process/operation tests; 105 total including three real diff-hl
  consumer tests, nine incremental-rendering tests and twelve fault/input tests.
- 25 disposable-server tests covering actual metadata, byte retrieval, state,
  mappings, native file operations and nine gutter scenarios. Run against both
  case-sensitive and case-insensitive servers; the alias-case assertion applies
  only to the latter.
- Fixture clients use LineEnd local, classic views with exclusions, noallwrite
  and allwrite. History includes mixed have/head revisions and a real conflict.
- Content cases: UTF-8, UTF-16, CRLF, no final newline, binary, spaces and P4
  special filename characters. Byte equality is tested separately from gutter
  rendering; UTF-16 textual gutter rendering is not currently supported.
- Saved/unsaved change markers, insertion/deletion, added files, behind-head
  edits, hunk navigation, external revert/submit/sync refresh, and warm-cache
  typing without P4 queries are covered.
- Native `vc-next-action`, registration, revert, delete and rename are exercised
  against the server. Lifecycle checks cover noallwrite/allwrite, exclusive locks,
  permissions, literal special-character paths, opened/unopened/add/delete/move
  reverts, partial move failures, buffer names and final VC state.

Run the tests without accessing a personal P4 server:

```sh
make check test-diff-hl EMACS=/path/to/emacs DIFF_HL_DIR=/path/to/diff-hl
python3 scripts/install_p4.py  # pinned, checksum-verified macOS arm64 tools
python3 scripts/p4_fixture.py --p4 .tools/p4 --p4d .tools/p4d \
  --emacs /path/to/emacs --diff-hl-dir /path/to/diff-hl
# Repeat with --case-handling sensitive for the alternate server mode.
```

The fixture uses a temporary server root, loopback port, isolated configuration,
users and clients. It verifies the server root and shuts down on exit. No private
history export is necessary.

The fault worker delays P4 and local diff by 600 ms, simulates a hung process,
and returns authentication/connection failures. Keyboard macros run an initiating
command followed by queued typing through Emacs command dispatch, asserting that
input executes while work is still pending (including an already-running worker).
The latency gate is 300 ms; a timer heartbeat alone does not pass it. Tests also
cover expired metadata, save/refresh, obsolete results, retry backoff, cancelled
buffers, process and temporary-file cleanup, and bounded/coalesced diff pipelines.
A real-server scenario overlaps external sync with a delayed diff and queued
input, then checks the new HAVE revision and preservation of unsaved text.
Operation regressions also exercise queued preparation, live-worker input,
timeout/cancellation, overlapping files, recovery copies, save guards, newer
buffer text, backend/configuration changes and fresh-process autoloading.

On macOS arm64, Emacs 30.2 and 31.1 passed these tests. Observed queued-command
latencies were below 10 ms in the local test runs with 600 ms worker delays.
These are small-file batch command-loop measurements, not a large-workspace or
GUI rendering benchmark. The GUI/private-workspace check remains in VALIDATION.md.

## Compatibility and remaining scope

The diff-hl source is unchanged. Backend acquisition remains in `vc-p4.el`;
`vc-p4-gutter.el` handles completed-result validation and incremental display.
`vc-p4-ops.el` contains the shared mutation lifecycle and P4-specific native VC
adapters. Emacs's mutation frontends assume synchronous completion: the adapters
defer buffer reload, permissions and renaming until a confirmed command result.
Other backends retain their original command path. Checkout-model accepts both
the single filename used by `vc-next-action` and fileset lists.

Mutation dispatch captures the owning buffer's environment, rechecks file/config
identity and serializes overlapping paths. Move's edit and rename share one
operation and recovery snapshot. Each failure refreshes actual state without
retrying the mutation or pretending to undo server changes. Cleanup failures
still release pending-file guards. Recovery copies are outside the repository.
Mutations invalidate only affected metadata; a real gutter test verifies that
native revert converges while an unrelated cache entry remains untouched.

A complete current result is reconciled against existing line and hunk overlays
with redisplay inhibited during the commit. Identical results perform no overlay
creation, deletion, movement or property writes. Hunk navigation metadata is
updated separately, so editing one line does not destroy its neighbours' markers.
Older completions cannot repaint newer results. The old global advice on
`diff-hl--resolve` has been removed; Git and other backend updates are untouched.
Pending and error states retain the last display, with mode-line status. A clean
result removes obsolete markers. Mode disable and workspace changes invalidate
the old display. The save regression checks overlay identity through completion,
not merely during the pending interval, with flydiff both enabled and disabled.

Optional actual Flycheck coexistence test:

```sh
make test-flycheck EMACS=/path/to/emacs DIFF_HL_DIR=/path/to/diff-hl \
  FLYCHECK_DIR=/path/to/flycheck
```

Tested against Flycheck source `a76f054fd63333e6586e50a9a531ee6669b19758`.
Its real warning overlays are repeatedly created and removed on both fringe
sides; P4 line overlays and their display strings retain identity. Auto placement
uses the diagnostic mode's configured side, never individual diagnostic presence.
These tests inspect overlay operations and display specifications; final pixel
appearance in the user's GUI still needs the workspace smoke check.

Metadata has a short TTL. Pristine numeric revisions are cached in memory by
configuration, depot path and revision. P4CONFIG/P4ENVIRO attribute changes
alter the cache identity. Use `vc-p4-refresh` after external commands or changes
to server-side client views. There is no background server polling. Cold or
expired queries queue work,
return unknown/pending immediately, and refresh VC properties when results arrive.
The synchronous P4 adapter remains only for explicit batch/fixture tooling.
Synchronous `find-revision` cannot defer its caller, so it signals pending data
on a cache miss; the automatic flydiff path uses the asynchronous pipeline instead.
Explicit synchronous local diffs require cached bases. Background worker timeouts
are controlled by `vc-p4-command-timeout` (10 seconds per worker).

Not yet covered: Windows line-ending translation, Unicode-mode servers and
P4CHARSET combinations, streams/complex overlays, TRAMP,
large-repository performance, other server builds and GUI appearance.
Binary differences produce no textual hunks. UTF-16 baselines are byte-correct,
but local diff treats them as binary. Submit, changelist management, directory
operations and cross-workspace/revision-changing operations still use the CLI.

## Commit discipline

Keep each coherent, validated change in a separate commit. Use descriptive
messages that explain the behavior and verification. Keep private planning
references out of public files, commit messages, branch names and pull requests.
After each step, review whether the implementation can be simplified. Cover
affected contracts and regression cases before refactoring, then rerun the
relevant suites. Separate refactor commits when that makes review clearer.
Use `git log --reverse --oneline` to follow the implementation and
`git show <sha>` to inspect a unit.

See [VALIDATION.md](VALIDATION.md) for workspace installation, smoke checks
and rollback.

Metadata-dependent checkout, registration and interactive revert use one guarded
continuation. It waits only for preflight data, never retries a mutation, and
cancels on changed text, disk identity, configuration or buffer closure. Tests
cover inferred Git metadata versus real Git roots and automatic cold-cache
registration/revert through native commands.
Saved-file registration is exercised through both `vc-register` and
`vc-next-action`.  An inferred fileset from the latter still resolves the P4
mapping; an explicitly selected backend retains its normal registration path.
