# Development and validation

The M1 candidate is tested with Emacs 30.2 and 31.1 on macOS arm64,
P4/P4D 2024.2/3084003, and diff-hl 1.10.0 at
`2d7d0714d9637f54af672987c65b6973b31e56a2`. The minimum requirement remains
Emacs 30.1; that exact patch release has not been run.
Validate other environments using the workspace smoke check.

## Checks

- Warning-free byte compilation.
- 34 backend/process tests; 37 total including three real diff-hl consumer tests
  with mocked P4 retrieval.
- 17 disposable-server tests covering actual metadata, byte retrieval, state,
  mappings, checkout models and seven gutter scenarios. Run against both
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

The asynchronous command runner has isolated tests for cancellation, deadlines,
bounded concurrency, raw output, environment capture and callback failures.
It is not yet wired into automatic VC or diff-hl paths. These tests do not
establish end-to-end input responsiveness.

## Compatibility and remaining scope

The diff-hl source is unchanged. Two P4-only advice functions recognize
`needs-merge` as locally modified and scope revision-cache filenames to P4
configuration/depot identity. A save hook invalidates VC state before diff-hl
runs, including edits to files previously marked `needs-update`.

Metadata has a short TTL. Pristine numeric revisions are cached in memory by
configuration, depot path and revision. P4CONFIG/P4ENVIRO attribute changes
alter the cache identity. Use `vc-p4-refresh` after external commands or changes
to server-side client views. There is no background server polling; cold queries
are synchronous and bounded by `vc-p4-command-timeout` (10 seconds per command).

Not yet covered: Windows line-ending translation, Unicode-mode servers and
P4CHARSET combinations, streams/complex overlays, TRAMP, asynchronous updates,
large-repository performance, other server builds and GUI appearance.
Binary differences produce no textual hunks. UTF-16 baselines are byte-correct,
but local diff treats them as binary. Editing/submission through VC belongs to
later milestones; use the P4 CLI in the meantime.

## Commit discipline

Keep each coherent, validated change in a separate commit. Use descriptive
messages that explain the behavior and verification. Keep private planning
references out of public files, commit messages, branch names and pull requests.
Use `git log --reverse --oneline` to follow the implementation and
`git show <sha>` to inspect a unit.

See [VALIDATION.md](VALIDATION.md) for workspace installation, smoke checks
and rollback.
