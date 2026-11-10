---
phase: 01-toolchain-baseline
verified: 2026-11-10T03:25:00Z
status: passed
score: 6/6 must-haves verified
covered_files:
  - ".github/workflows/ci.yml"
  - ".github/workflows/kernel-matrix.yml"
  - ".planning/phases/01-toolchain-baseline/01-PLAN.md"
  - ".planning/phases/01-toolchain-baseline/01-SUMMARY.md"
  - "Containerfile"
  - "README.adoc"
covered_digest: "v4:sha256:84d1810c63ea5dd2865f1815fa6a581dc635e65c4d6b3fb44e33bb209349c56f"
behavior_unverified: 0
overrides_applied: 0
prohibitions:
  - statement: "Gate commands must never gain opt-out or vet flags (-no-escape-analysis, -no-atomic-analysis, -vet-*) and container runs must never weaken seccomp (--security-opt seccomp=unconfined)"
    status: verified
    verification: test
    evidence: "Repo-wide grep: matches only inside planning-doc prose (01-PLAN/01-CONTEXT/01-PATTERNS/01-RESEARCH prohibition wording); zero matches in .github/workflows/*.yml and Containerfile. Gate commands in ci.yml unchanged (git diff 3a9f4cb..HEAD shows only the setup-odin block)."
  - statement: "The README edit must not touch the first [source,odin] block or its ---- fences"
    status: verified
    verification: test
    evidence: "git diff 3a9f4cb..HEAD -- README.adoc touches only the toolchain note lines (~19-27); the [source,odin] example block is outside the diff. Doc-probe compile of the extracted block passed in the pinned container (DOCPROBE_OK, re-verified independently 2026-11-10)."
  - statement: "Hand-rolled Landlock/openat2 wrappers in syscall/syscall_linux.odin must not be deleted or rewritten in this phase"
    status: verified
    verification: test
    evidence: "git diff --stat 3a9f4cb08616f7a5e19d372bceb03939145979f5..HEAD -- syscall/ landlock.odin is EMPTY (byte-identical). Full #assert tripwire chain compiled untouched on the pinned nightly (suite green, GATE_GREEN)."
human_verification:
  - test: "Produce one green CI run on the pinned nightly: push the phase branch to a PR or to main (or workflow_dispatch on ci.yml) on github.com/litew/odin-landlock, and confirm the run is green on the dev-2026-11a pin."
    expected: "ci.yml green on Odin dev-2026-11a (odin version step prints dev-2026-11-nightly:9a69916; all gate steps pass); kernel-matrix.yml pin visible in its next scheduled/dispatched run."
    why_human: "Requires push/PR/workflow_dispatch on the GitHub remote — branch 001-config-build pushes do not trigger ci.yml, and no workflow has run since 2026-08-10 (verified live via gh run list: last run 2026-08-10, kernel-matrix, on a June main HEAD). The verifier cannot and must not push."
---

# Phase 1: Toolchain Baseline Verification Report

**Phase Goal:** The project compiles and its entire test suite passes on the pinned Odin dev-2026-11 nightly, so all feature work starts from a verified toolchain with toolchain churn isolated from feature churn.
**Verified:** 2026-11-10T03:25:00Z
**Status:** human_needed
**Re-verification:** No — initial verification

## Verification Method

Goal-backward, adversarial: SUMMARY.md claims were treated as unproven. All pinned-compiler evidence was **independently re-executed** in the `localhost/odin-dev-2026-11a` container on 2026-11-10 (host odin is stale dev-2026-10 and was never used); file/CI-pin/prohibition evidence was checked from repo contents and git history (diff base `3a9f4cb` = SUMMARY `plan_head_before`).

## Goal Achievement

### Roadmap Success Criteria (Phase 1, ROADMAP.md)

| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|
| 1 | Library, examples, tools build clean with pinned dev-2026-11 nightly | ✓ VERIFIED | In-container re-run: `odin check . -no-entry-point` clean (zero output, D-06), `odin build examples` EXAMPLE_BUILD_OK, `odin build tools/abi-conformance` TOOLS_BUILD_OK |
| 2 | Full test suite passes on dev-2026-11 | ✓ VERIFIED | In-container re-run: root suite `Finished 73 tests … All tests were successful`, syscall suite `Finished 6 tests … All tests were successful`; zero findings (source diff empty as researched) |
| 3 | Existing suite + `#assert` chain pass, evidencing no representation churn (D-07 wording already in ROADMAP) | ✓ VERIFIED | `syscall/` + `landlock.odin` byte-identical across `3a9f4cb..HEAD` (empty diffstat); `#assert` chain compiled untouched on the pinned nightly; per D-07 the absence of new literal-value test files is expected, NOT a gap |
| 4 | README documents the dev-2026-11 pin | ✓ VERIFIED | README.adoc:19-27: tag `dev-2026-11a`, `odin version` string, artifact name, sha256 65c9f6e9…04f7618; `dev-2026-05` note gone (grep count 0) |

### Observable Truths (01-PLAN.md must_haves.truths)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Every D-08 gate command passes with the pinned dev-2026-11a compiler, verified locally inside the podman image | ✓ VERIFIED | Independently re-executed full chain in-container (2026-11-10): check clean → 73+6 tests → EXAMPLE_BUILD_OK → TOOLS_BUILD_OK → DARWIN_OK → FREEBSD_OK → DOCPROBE_OK → GATE_GREEN; wall time 3.3s, zero warnings/errors |
| 2 | Both CI workflows pin `release: dev-2026-11a` exactly; `release: latest` appears nowhere in .github/workflows/ | ✓ VERIFIED | grep: `release: dev-2026-11a` at ci.yml:26 and kernel-matrix.yml:48 (2 hits); `release: latest` has zero matches under .github/workflows/ (matches exist only in planning-doc prose). Diff shows exactly name+release changed per file |
| 3 | README.adoc documents the pin per D-02: tag, exact `odin version` string, artifact name, sha256 65c9f6e9…04f7618 | ✓ VERIFIED | README.adoc:19-27 carries all four identity fields; recorded string `dev-2026-11-nightly:9a69916` matches the live binary byte-for-byte (`podman run … odin version` re-run today) |
| 4 | D-04 satisfied by documented evidence, not edits — syscall/syscall_linux.odin stays unchanged | ✓ VERIFIED | Empty diff for `syscall/` and `landlock.odin` across the whole phase (`3a9f4cb..HEAD`); RESEARCH D-04 verdict (core ships only syscall numbers 444–446, no openat2/Open_How, no O_PATH) recorded in SUMMARY; nothing adopted |
| 5 | Phase 1 criterion 3 met by existing suite + `#assert` chain passing on the pinned nightly (per D-07; no new literal-value tests) | ✓ VERIFIED | No new test files in the phase diff; existing 73+6 suite green on the pinned nightly; ROADMAP criterion 3 already carries the D-07 deferral wording — no further edit needed |
| 6 | Integration test best-effort per D-09: runs in-container with default seccomp; fallback acceptable | ✓ VERIFIED (exceeds requirement) | Re-run `odin test . -define:LANDLOCK_INTEGRATION=true -define:ODIN_TEST_THREADS=1` in-container: `Finished 73 tests … All tests were successful`, no skip line — real-kernel enforcement exercised on host 7.2 |

**Score:** 6/6 truths verified (0 present-behavior-unverified); roadmap SCs 4/4; prohibitions 3/3 verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `Containerfile` | sha256-gated pinned toolchain image recipe, no repo COPY, no seccomp weakening | ✓ VERIFIED | Exists at repo root; exact release URL + `sha256sum --check` in the RUN; ARG default 65c9f6e9…04f7618; no `COPY` of repo source; no `security-opt`/seccomp options |
| `localhost/odin-dev-2026-11a` image | Local reusable image (not a repo artifact) | ✓ VERIFIED | Image present (`d43c82f4b69a`); `odin version` → `dev-2026-11-nightly:9a69916` |
| `.github/workflows/ci.yml` | `release: dev-2026-11a` pin | ✓ VERIFIED | Line 26, inside `laytan/setup-odin@v2`; only name+release lines changed |
| `.github/workflows/kernel-matrix.yml` | `release: dev-2026-11a` pin | ✓ VERIFIED | Line 48, inside `laytan/setup-odin@v2`; only name+release lines changed |
| `README.adoc` | Pinned identity block replacing dev-2026-05 note | ✓ VERIFIED | Lines 19-27; first `[source,odin]` block outside the diff (doc probe green) |
| Recorded `odin version` string | Into README block | ✓ VERIFIED | `dev-2026-11-nightly:9a69916` — identical to live pinned binary output |

### Behavioral Spot-Checks (independent, this verification)

| Behavior | Command (in `localhost/odin-dev-2026-11a`, repo bind-mounted) | Result | Status |
|----------|---------------------------------------------------------------|--------|--------|
| Pinned toolchain identity | `podman run --rm … odin version` | `dev-2026-11-nightly:9a69916` | ✓ PASS |
| Full D-08 gate | check + `odin test .` + `odin test syscall` + examples build + abi-conformance build + darwin/freebsd cross-checks | `GATE_GREEN`, 73+6 tests, zero warnings/errors | ✓ PASS |
| README doc probe | awk/sed extraction + `odin build _docprobe` | `DOCPROBE_OK` | ✓ PASS |
| Real-kernel integration (D-09) | `odin test . -define:LANDLOCK_INTEGRATION=true -define:ODIN_TEST_THREADS=1` | 73 tests successful, no skip line | ✓ PASS |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| TOOL-01 | 01-PLAN.md (`requirements: [TOOL-01]`) | Project builds and the full suite passes on Odin `dev-2026-11` nightly; README pin updated | ✓ SATISFIED | Full gate green on the pinned compiler (re-verified above); README pin block present. TOOL-01 has no named verification command in REQUIREMENTS.md (flagged assumption): the D-08 gate list is its verification — verified sound. REQUIREMENTS.md traceability already marks TOOL-01 Complete |
| (orphan check) | — | REQUIREMENTS.md maps only TOOL-01 to Phase 1 | ✓ NONE | No orphaned requirements |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| — | — | No TBD/FIXME/TODO/HACK/PLACEHOLDER debt markers in any phase-modified file (Containerfile, README.adoc, both workflows) | — | — |

### Advisory (not verification gaps)

Per assignment and REVIEW.md, the following code-review findings are **advisory Containerfile/CI hardening suggestions, deliberately dispositioned `open` in 01-REVIEW-DISPOSITION.md — none block the phase goal**:
- WR-01: floating `fedora:latest` base image (Containerfile:9)
- WR-02: sha256 gate overridable via `ARG ODIN_SHA256` (Containerfile:18-22)
- IN-01: GitHub Actions pinned by major tag, not SHA (pre-existing)
- IN-02: stale tracked ELF `examples/examples` (flagged chore — verified NOT done, `git ls-files examples/examples` still lists it, correctly awaiting an explicit user nod)
- IN-03: doc-probe pipeline duplicated inline in CI YAML (pre-existing pattern)

### Flagged Assumptions Resolved

- **TOOL-01 probe row:** unclassified in REQUIREMENTS.md; the D-08 gate command list is a sound verification (it mirrors ci.yml and exercises every part of the TOOL-01 wording). No alternative command exists.
- **A1 (`odin version` string shape):** resolved correctly — the binary prints `dev-2026-11-nightly:9a69916` (not the tag); identity rests on the sha256 gate in the image build, which is stronger than the plan's original substring fails_when. Recorded verbatim in README; re-confirmed live this session.

## Human Verification Required

### 1. Green CI run on the pinned nightly (D-08's "AND in CI" half; SUMMARY coverage item D6)

**Test:** Push the phase work to a PR or to main (or trigger `workflow_dispatch` on ci.yml) on `github.com/litew/odin-landlock`; open the run and confirm green on the pin.
**Expected:** ci.yml green; the `odin version` step prints `dev-2026-11-nightly:9a69916`; every gate step passes; kernel-matrix.yml picks up the same pin on its next scheduled/dispatched run.
**Why human:** Requires a push/PR/dispatch on the remote — branch `001-config-build` pushes do not trigger ci.yml, and `gh run list` confirms no workflow run since 2026-08-10. The verifier must not push. All local legs of the identical gate list are green (re-executed in the pinned container), so this is the single outstanding evidence item.

## Gaps Summary

No gaps. Every must-have truth, artifact, and prohibition is verified with independent in-container or on-disk evidence; the phase delivered the researched zero-source-churn outcome (syscall/ byte-identical, no new tests per D-07). One human verification item remains (the CI run), which by construction cannot be produced from the branch without a push/publish decision owned by the orchestrator/user — hence `human_needed`, not `gaps_found`.

---

_Verified: 2026-11-10T03:25:00Z_
_Verifier: Claude (gsd-verifier)_
