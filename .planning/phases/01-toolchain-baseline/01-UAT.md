---
status: testing
phase: 01-toolchain-baseline
source: [01-VERIFICATION.md]
started: 2026-11-09T21:40:00Z
updated: 2026-11-10T03:45:00Z
---

## Current Test

number: 1
name: Green CI run on the pinned nightly
expected: |
  After pushing the phase work to a PR or main (or running ci.yml via workflow_dispatch) on
  github.com/litew/odin-landlock: the ci.yml run is green; the setup-odin step installs the
  pinned release (`release: dev-2026-11a`); `odin version` prints
  `dev-2026-11-nightly:9a69916`; all gate steps pass (check, both unit suites, example build,
  README doc-probe, darwin_amd64 + freebsd_amd64 cross-target checks).
awaiting: answered — see Tests item 1 (pass, evidence below)

## Tests

### 1. Green CI run on the pinned nightly (D-08's "AND in CI" half)
expected: ci.yml green on github.com/litew/odin-landlock after push to PR/main or
workflow_dispatch; `odin version` prints `dev-2026-11-nightly:9a69916`; all gate steps pass.
Why human: branch pushes do not trigger ci.yml and `gh run list` shows no run since 2026-08-10;
the verifier must not push on the user's behalf.
result: **pass** (2026-11-10, user-authorized push)
evidence:
- PR: https://github.com/litew/odin-landlock/pull/4 (branch 001-config-build, HEAD 344c2ad)
- Run: https://github.com/litew/odin-landlock/actions/runs/42750844201 — conclusion **success**
- `odin version dev-2026-11-nightly:9a69916` (expected string matched verbatim)
- 73 landlock unit tests passed; 6 syscall unit tests passed;
  integration suite (real kernel, best-effort): 73 tests passed on runner kernel 7.0

## Summary

total: 1
passed: 1
issues: 0
pending: 0
skipped: 0
blocked: 0

## Gaps
