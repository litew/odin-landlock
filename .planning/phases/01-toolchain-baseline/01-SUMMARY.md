---
phase: 01-toolchain-baseline
plan: 01
subsystem: infra
tags: [odin, toolchain-pin, podman, ci, supply-chain, landlock]

# Dependency graph
requires: []
provides:
  - Pinned Odin dev-2026-11a toolchain: CI (both workflows), README identity block, sha256-verified podman image recipe (Containerfile) reusable by Phases 2-4
  - Local gate substrate: `podman build -t localhost/odin-dev-2026-11a .` + bind-mounted `odin check/test/build` runs (D-03 recipe)
  - Green D-08 gate transcript on the pinned nightly (zero source edits)
affects: [phase-02 ABI Contract & Gating (builds on pinned nightly + container recipe), phase-03, phase-04]

# Tech tracking
tech-stack:
  added: [Containerfile (fedora:latest + pinned odin release tarball, sha256 gate), localhost/odin-dev-2026-11a image (local-only)]
  patterns:
    - "Pinned-toolchain verification: exact release tag in CI `release:`, sha256-verified tarball in container, `odin version` string + sha256 published in README"
    - "Container gate recipe (durable): podman run --rm -v \"$PWD:/src:Z\" -w /src localhost/odin-dev-2026-11a <odin cmd>"

key-files:
  created: [Containerfile]
  modified: [README.adoc, .github/workflows/ci.yml, .github/workflows/kernel-matrix.yml]

key-decisions:
  - "A1 resolved: pinned binary prints `odin version` as `dev-2026-11-nightly:9a69916` (not `dev-2026-11a:...`); dev-2026-11a is a release tag whose linux-amd64 artifact is byte-identical to dev-2026-11, so identity is proven by sha256sum --check inside the image build (65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618) and the README records the printed string verbatim"
  - "D-04 recorded as documented no-op: core:sys/linux at dev-2026-11 ships only Landlock syscall numbers 444-446 (no openat2/Open_How wrapper, no O_PATH in core:os) — syscall/ left byte-identical"
  - "Gate fully green with zero findings: no call-site fixes, no fmt fallout, no escape-analysis warnings — source diff is empty as researched"

patterns-established:
  - "Phase executor verification runs inside the pinned container image, never on the host compiler (read-only atomic host doctrine)"
  - "sha256 gate in the image build fails loudly on toolchain identity mismatch (T1 supply-chain control)"

requirements-completed: [TOOL-01]

# Coverage metadata (#1602)
coverage:
  - id: D1
    description: "Containerfile at repo root builds image localhost/odin-dev-2026-11a; release tarball fetched by exact URL and sha256-verified at build (fails loudly on mismatch)"
    requirement: TOOL-01
    verification:
      - kind: other
        ref: "podman build -t localhost/odin-dev-2026-11a . && echo IMAGE_OK (sha256sum --check: /tmp/odin.tar.gz: OK)"
        status: pass
    human_judgment: false
  - id: D2
    description: "README.adoc carries the full D-02 pinned toolchain identity block (tag dev-2026-11a, odin version string dev-2026-11-nightly:9a69916, artifact odin-linux-amd64-dev-2026-11a.tar.gz, sha256 65c9f6e9...) and the dev-2026-05 note is gone; first [source,odin] block untouched"
    requirement: TOOL-01
    verification:
      - kind: other
        ref: "grep -c dev-2026-11a README.adoc = 3; grep -c dev-2026-05 README.adoc = 0; doc-probe compile (D8) proves first block intact"
        status: pass
    human_judgment: false
  - id: D3
    description: "Both CI workflows pinned: laytan/setup-odin@v2 release: dev-2026-11a in ci.yml and kernel-matrix.yml; `release: latest` absent from .github/workflows/; exactly 2 changed lines per file"
    requirement: TOOL-01
    verification:
      - kind: other
        ref: "grep release: dev-2026-11a .github/workflows/ = 2 hits; grep release: latest = no matches; git diff --stat = 2 files, 4 insertions, 4 deletions"
        status: pass
    human_judgment: false
  - id: D4
    description: "Full D-08 gate green in-container on the pinned nightly with zero warnings and zero errors (D-06): odin check, both unit suites (73+6 tests), example build, tools/abi-conformance build, darwin_amd64 + freebsd_amd64 cross-target checks, README doc-snippet probe; syscall/ byte-identical (D-04 no-op, #assert chain compiled untouched)"
    requirement: TOOL-01
    verification:
      - kind: other
        ref: "container chain exit 0 + GATE_GREEN; DOCPROBE_OK; git diff --stat -- syscall/ empty"
        status: pass
    human_judgment: false
  - id: D5
    description: "Real-kernel integration test (D-09, best-effort) ran and passed inside the container with default seccomp: no skip line emitted, forked child enforced a real Landlock policy on host kernel 7.2 and the kernel denied the probe read"
    requirement: TOOL-01
    verification:
      - kind: integration
        ref: "odin test . -define:LANDLOCK_INTEGRATION=true -define:ODIN_TEST_THREADS=1 (in-container, 73 tests, all successful)"
        status: pass
    human_judgment: false
  - id: D6
    description: "One green CI run on the pinned nightly (new evidence — CI idle since 2026-08-10; requires push to main, a PR, or workflow_dispatch)"
    verification: []
    human_judgment: true
    rationale: "Branch 001-config-build pushes do not trigger ci.yml; producing the run requires pushing/publishing, which the orchestrator/user handles after this executor returns. All local evidence for the same gate list is green."

# Metrics
duration: 10 min
completed: 2026-11-10
status: complete
commits: 2
plan_head_before: 3a9f4cb08616f7a5e19d372bceb03939145979f5
plan_head_after: 0b75e87fc1b707b2050152b63266a6d508ac8450
---

# Phase 1 Plan 1: Toolchain Baseline Summary

**Odin dev-2026-11a pinned everywhere (CI x2, README identity block, sha256-verified podman image) with the full D-08 gate green in-container and zero source edits**

## Performance

- **Duration:** 10 min
- **Started:** 2026-11-10T03:02:30Z
- **Completed:** 2026-11-10T03:12:52Z
- **Tasks:** 3
- **Files modified:** 4 (1 created, 3 modified)

## Accomplishments
- `Containerfile` at repo root: fedora base + pinned `odin-linux-amd64-dev-2026-11a.tar.gz` fetched by exact URL and sha256-verified inside the build (`65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618`); image `localhost/odin-dev-2026-11a` built and reusable by Phases 2-4 (D-03)
- README.adoc: `dev-2026-05` note replaced by the D-02 pinned toolchain identity block (tag, `odin version` string, artifact, sha256); first `[source,odin]` block untouched (doc probe green proves it)
- Both CI workflows pinned to `release: dev-2026-11a`; `release: latest` eliminated from `.github/workflows/` (D-01, T2 drift threat closed)
- Full D-08 gate green inside the pinned container, zero warnings / zero errors (D-06): `odin check . -no-entry-point` (clean), `odin test .` (73 tests), `odin test syscall` (6 tests), `odin build examples`, `odin build tools/abi-conformance`, README doc-snippet probe (`DOCPROBE_OK`), darwin_amd64 + freebsd_amd64 cross-target checks — `GATE_GREEN`
- D-09 integration run: executed **and passed** in-container with default seccomp (no `[integration] skipped` line; forked child enforced a real Landlock policy on the host 7.2 kernel and the disallowed `/tmp` read was denied)
- D-04 recorded as a documented no-op: `syscall/` byte-identical; `#assert` tripwire chain (bit_set sizes, attr layouts 24/12/16) compiled untouched — D-07 evidence = existing suite + `#assert` chain green on the pinned nightly

## Task Commits

1. **Task 1 (tracer): End-to-end pinned toolchain: sha256-verified image + first pinned compile** - `e1b0dba` (chore)
2. **Task 2 (auto): Pin both CI workflows to dev-2026-11a (D-01)** - `0b75e87` (chore)
3. **Task 3 (auto): Run the full D-08 gate in the container** - **no commit** — gate fully green with zero findings, so per the plan the listed source files end the phase unchanged and the deliverable is the recorded green gate transcript (above + command log in this file)

**Plan metadata:** committed together with the docs close-out (see final commit).

## Files Created/Modified
- `Containerfile` (new) - sha256-verified pinned toolchain image recipe; never COPYs repo source; no seccomp weakening
- `README.adoc` - pinned toolchain identity block (D-02), vendoring rationale kept, example block untouched
- `.github/workflows/ci.yml` - setup-odin release pin + step rename only
- `.github/workflows/kernel-matrix.yml` - same pin in its setup-odin block

## Decisions Made
- **A1 resolved (flagged assumption):** the pinned binary prints `odin version dev-2026-11-nightly:9a69916`, which does **not** contain the literal substring `dev-2026-11a`. The plan's Task 1 verify #1 fails_when was written against the assumed string shape; per assumption A1 ("Cosmetic — README records whatever the binary actually prints"), identity is proven by the stronger sha256 gate (`/tmp/odin.tar.gz: OK` inside the build — the dev-2026-11a release asset is byte-identical to dev-2026-11's), and the printed string is recorded verbatim in README. No code or gate change.
- **D-04 no-op honored:** nothing adopted; `syscall/syscall_linux.odin` and `syscall/syscall.odin` untouched (core:sys/linux at dev-2026-11 ships only Landlock syscall numbers 444-446; no openat2/Open_How wrapper; no O_PATH in core:os).
- **No task-3 commit:** the researched zero-findings path materialized — `git diff --stat -- syscall/` empty, zero warnings/errors (D-06), so Task 3 produced no file changes to commit.

## Deviations from Plan

**1. [Flagged-assumption resolution — A1] Tracer verify #1 substring check**
- **Found during:** Task 1 (tracer gate re-run)
- **Issue:** `odin version` prints `dev-2026-11-nightly:9a69916`; the literal fails_when ("output does not contain the substring dev-2026-11a") cannot match because the hotfix tag's artifact is byte-identical to dev-2026-11 and the compiler reports its build branch, not the release tag name
- **Fix:** none required — identity verified by the sha256 gate in the image build (stronger than the substring check); string recorded verbatim per the plan's own instruction; documented in README + this SUMMARY
- **Files modified:** none (verification semantics only)
- **Verification:** `sha256sum --check` OK inside build; artifact URL names dev-2026-11a; README pin block lists both the tag and the printed version string
- **Committed in:** n/a (no change)

---

**Total deviations:** 1 (flagged-assumption resolution, zero code impact)
**Impact on plan:** None — all must_haves truths hold: every gate command green on the pinned compiler; `release: latest` absent; README identity block complete; syscall/ unchanged; D-09 integration ran locally.

## Issues Encountered
None — the researched zero-churn path was confirmed end-to-end.

## User Setup Required
None — no external service configuration required.

## Flagged Items Surfaced (per plan must_haves, not silently dropped)
- **TOOL-01 probe row unclassified:** TOOL-01 has no named verification command in REQUIREMENTS.md; this plan treats the D-08 gate command list (CONTEXT.md D-08, mirrored from ci.yml) as its verification. If the phase verifier believes TOOL-01 requires a different command, say which.
- **`git rm --cached examples/examples` chore:** still awaiting an explicit user nod (tracked stale ELF binary, now covered by the uncommitted `.gitignore` edit). Default skip; never bundled silently. If granted, it must be its own commit.
- **Green CI run (D6):** requires push to main / PR / workflow_dispatch — executor cannot trigger it from branch 001-config-build; orchestrator produces it at phase close (CI idle since 2026-08-10, so the run is new evidence, not re-confirmation).

## Next Phase Readiness
- Pinned nightly proven on the full gate with zero source churn — Phase 2 (ABI Contract & Gating) starts from a verified toolchain with toolchain churn isolated
- Container recipe durable: `podman build -t localhost/odin-dev-2026-11a .` once, then bind-mount runs (`-v "$PWD:/src:Z" -w /src`) for every Phase 2-4 verification; image already present locally
- D-07 literal bit-value truth tests land in Phase 2 alongside v10/v11 constants, as decided
- Blockers: none local; only the CI-run evidence item (D6) and the two flagged items above, all owned by orchestrator/user

## Self-Check: PASSED

---
*Phase: 01-toolchain-baseline*
*Completed: 2026-11-10*
