---
phase: 01-toolchain-baseline
reviewed: 2026-11-10T00:00:00Z
depth: standard
files_reviewed: 3
files_reviewed_list:
  - Containerfile
  - .github/workflows/ci.yml
  - .github/workflows/kernel-matrix.yml
findings:
  critical: 0
  warning: 2
  info: 3
  total: 5
status: issues_found
---

# Phase 01: Code Review Report

**Reviewed:** 2026-11-10
**Depth:** standard
**Files Reviewed:** 3 (Containerfile, ci.yml, kernel-matrix.yml — the phase's source changes in e1b0dba1e4 + 0b75e87fc1; 98c37270a3 is planning-doc close-out, excluded per scope rules)
**Status:** issues_found

## Summary

Phase 1 ships exactly what 01-PLAN.md scoped: a sha256-gated pinned-toolchain Containerfile, README identity block, and a 2-line-per-file CI pin to `release: dev-2026-11a`. No repo source (Odin files) was touched, matching the researched zero-findings expectation. The pinned artifact identity was independently verified against upstream: the GitHub release assets page for `dev-2026-11a` lists `odin-linux-amd64-dev-2026-11a.tar.gz` with sha256 `65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618` (72.6 MB, 2026-11-03) — identical to the digest in Containerfile, README.adoc, and SUMMARY. The A1 deviation (binary prints `dev-2026-11-nightly:9a69916`, not the tag) is correctly resolved by relying on the sha256 gate. `release: latest` is absent from `.github/workflows/`; both workflows pin the exact tag; token/indentation preserved as required.

The findings below are hygiene gaps in the Containerfile's supply-chain posture relative to the phase's own threat model (T1 rated high): a floating base image and an overridable digest ARG each leave a lane around the sha256 gate. Neither is exploitable as-shipped, and both are one-line fixes.

## Warnings

### WR-01: Floating base image undermines the pin (T1 lane)

**File:** `Containerfile:9`
**Issue:** `FROM docker.io/library/fedora:latest` floats. The whole phase's premise is a reproducible, identity-verified toolchain, yet every rebuild can pull a different Fedora (newer glibc, dnf changes). A glibc bump can break the glibc-linked Odin binary or shift `clang` behavior, silently changing gate results between Phase 2–4 rebuilds of the "same" image tag — the exact drift class the phase was created to eliminate, now on the base-image axis.
**Fix:**
```dockerfile
FROM docker.io/library/fedora@sha256:<digest-of-chosen-fedora>
```
Resolve the digest once (`podman pull docker.io/library/fedora && podman image inspect` / `skopeo inspect`) and pin it, mirroring the tarball sha256 discipline.

### WR-02: sha256 gate overridable via build ARG

**File:** `Containerfile:18-22`
**Issue:** `ARG ODIN_SHA256=...` makes the T1 gate advisory: `podman build --build-arg ODIN_SHA256=<attacker-digest>` legitimizes an arbitrary tarball through the same `sha256sum --check` that is supposed to fail loudly. The gate exists to be non-negotiable; a CLI flag that disables it weakens the threat-model claim "a digest mismatch fails this build loudly, never warns."
**Fix:**
```dockerfile
RUN curl -fsSL -o /tmp/odin.tar.gz <url> \
 && echo "65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618  /tmp/odin.tar.gz" | sha256sum --check - \
 ...
```
Hardcode the digest in the `RUN` (or `ENV`), dropping the `ARG`. For a local-only dev image, pinning is the point; if a parameterized variant is ever wanted, make the default refuse to differ from the committed constant.

## Info

### IN-01: GitHub Actions pinned by major tag, not SHA

**File:** `.github/workflows/ci.yml:19,23` and `.github/workflows/kernel-matrix.yml:41,45`
**Issue:** `actions/checkout@v5` and third-party `laytan/setup-odin@v2` float within their major tags — a compromised action update would run with `secrets.GITHUB_TOKEN` in scope. Out of this phase's changed-lines scope (pre-existing), noted for the supply-chain posture the phase establishes. The Odin *compiler* is now pinned; the actions that install it are not.
**Fix:** Pin both actions to full commit SHAs (`uses: laytan/setup-odin@<sha> # v2`). Candidate for a later phase or an out-of-band chore.

### IN-02: Stale tracked ELF `examples/examples` still tracked

**File:** `examples/examples` (git-tracked binary, still present in HEAD)
**Issue:** The flagged chore (`git rm --cached examples/examples`) was correctly surfaced in the plan/SUMMARY as "default skip, requires explicit user nod" — not silently dropped, which is the required behavior. Left open pending that nod; keeping it visible so it doesn't rot.
**Fix:** On explicit user approval: `git rm --cached examples/examples` in a standalone commit (already covered by the uncommitted `.gitignore` edit).

### IN-03: Doc-probe pipeline exists only inside CI YAML

**File:** `.github/workflows/ci.yml` (README doc-probe awk/sed step)
**Issue:** The README `[source,odin]` block now has two independent consumers (CI step and the plan's in-container probe), both as inline shell. Not a defect of this phase — the block was left untouched and the probe passed — but the contract is duplicated inline rather than scripted. Flag only if Phases 2–4 keep re-embedding it.
**Fix:** If reused again, factor into `tools/doc-probe.sh` called from both CI and the container gate.

## Verified-sound items (checked, no finding)

- **sha256 identity:** independently confirmed against `github.com/odin-lang/Odin/releases` assets for `dev-2026-11a` — digest matches Containerfile/README/SUMMARY exactly; release date 2026-11-03 matches the README "hotfix, 2026-11-03" claim.
- **CI pin (D-01):** `release: dev-2026-11a` in both workflows (ci.yml:26, kernel-matrix.yml:48); `release: latest` absent repo-wide under `.github/workflows/`; exactly 2 changed lines per file in 0b75e87fc1.
- **Prohibitions:** no `-no-escape-analysis`/`-vet-*`/`--security-opt seccomp=unconfined` anywhere in the phase diff; Containerfile adds no seccomp weakening; repo source never `COPY`'d into the image.
- **README doc-probe contract:** first `[source,odin]` block untouched (diff shows only lines ~19–27 replaced); probe evidence (`DOCPROBE_OK`) recorded in SUMMARY.
- **A1 deviation:** legitimately resolved — identity rests on the sha256 gate, stronger than the plan's original substring check; recorded verbatim in README.

---

_Reviewed: 2026-11-10_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
