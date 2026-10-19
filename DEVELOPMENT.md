# Initial implementation handoff

## Validation

Tested with GNU Emacs 30.2 and the installed diff-hl checkout at
`2d7d0714d9637f54af672987c65b6973b31e56a2` (package header version 1.10.0):

- Warning-free byte compilation of vc-p4.el.
- 21 ERT backend/process/contract tests passed.
- 23 tests passed when including the two diff-hl overlay tests.
- Regression test reproduced stale diff output before the fix and passed after.
- Python fixture CLI and source syntax checked; real P4 execution is pending.

The consumer tests use the locally installed diff-hl source, with P4 retrieval
mocked. They exercise actual VC dispatch, local diff, parsing and overlay creation.
They do not establish real P4 metadata compatibility, GUI appearance, or all M1
acceptance cases.

Example commands (supply your installed tool paths):

```sh
make \
  check test-diff-hl \
  EMACS=/path/to/emacs \
  DIFF_HL_DIR=/path/to/diff-hl
```

## Commit discipline

Keep each coherent, validated change in a separate commit. Use descriptive
messages that explain the behavior and verification. Keep private planning
references out of public files, commit messages, branch names and pull requests.
Use `git log --reverse --oneline` to follow the implementation and
`git show <sha>` to inspect a unit.

## Next work

1. Obtain local p4/p4d executables and run the fixture.
2. Correct backend behavior against actual tagged JSON and workspace metadata.
3. Extend fixtures for additions/deletions/moves, special filenames, encoding,
   file types, multiple mappings and external refresh.
4. Expand gutter tests to insertion/deletion, refresh and hunk navigation.
5. Harden workspace/cache identity and async behavior before M1 acceptance.
