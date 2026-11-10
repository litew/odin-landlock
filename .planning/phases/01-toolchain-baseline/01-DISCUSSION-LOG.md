# Phase 1: Toolchain Baseline - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-11-09
**Phase:** 1-Toolchain Baseline
**Areas discussed:** Pin enforcement, Wrapper migration policy, Bit-value truth tests, Suite-pass gate

---

## Pin enforcement

### Q1: Where does the dev-2026-11 pin live?

| Option | Description | Selected |
|--------|-------------|----------|
| Tag pin in CI + README prose | `release: dev-2026-11a` in both workflows, README documents same tag; two places, one commit, no new machinery | ✓ |
| Machine-readable pin file | `.odin-version` read by CI into the action input; single source of truth but extra file + CI glue | |
| README-only pin, CI stays `latest` | Status quo; local pinned, CI floats | |

**User's choice:** Tag pin in CI + README prose
**Notes:** Research showed CI currently floats (`release: latest`) while README pins prose — already drifted. `laytan/setup-odin@v2` `release:` input downloads the exact tagged release artifact.

### Q2: Local verification binary

| Option | Description | Selected |
|--------|-------------|----------|
| Download pinned release tarball | Unpack sha256-verified tarball to a user dir, run by explicit path; same pattern as existing `~/.local/bin` odin | |
| Podman container toolchain | Image with pinned compiler; strongest isolation per containerization rule | ✓ |
| Build from master in container | Clone+compile Odin master; only if release artifact insufficient | |

**User's choice:** Podman container toolchain
**Notes:** User's standing rule: read-only atomic host (rpm-ostree), tooling in containers. Container image source is the pinned release tarball (sha256-verified) — captured as Claude's discretion; user did not object to that refinement.

---

## Wrapper migration policy

### Q1: Policy when the nightly breaks or obsoletes hand-rolled wrappers

| Option | Description | Selected |
|--------|-------------|----------|
| Minimal fix-in-place | Touch wrappers only if dev-2026-11 breaks compilation/tests; replacement waits for Phase 2 | |
| Adopt new core surface now | Delete wrappers wherever the nightly ships equivalent core surface | ✓ |

**User's choice:** Adopt new core surface now
**Notes:** Bounded to what dev-2026-11 actually ships; Landlock syscalls stay hand-rolled where core lacks surface. Phase 2 rewrites this layer anyway.

### Q2: Intentional core behavior changes (core:fmt pad-width)

| Option | Description | Selected |
|--------|-------------|----------|
| Ride the new defaults | Update call sites + test expectations to dev-2026-11 behavior; no compat shims | ✓ |
| Explicit where output matters | Explicit padding in caller-facing renderers to survive future nightly changes | |

**User's choice:** Ride the new defaults

### Q3: Deprecation warnings from the new nightly

| Option | Description | Selected |
|--------|-------------|----------|
| Tolerate warnings in Phase 1 | Gate is zero errors + green suite; cleanup with Phase 2 rewrite | |
| Fix all warnings now | "Builds clean" = zero warnings and zero errors | ✓ |

**User's choice:** Fix all warnings now

---

## Bit-value truth tests

### Q1: Form and depth of literal mask comparisons

| Option | Description | Selected |
|--------|-------------|----------|
| Both: #assert + bridge test | Compile-time literal asserts + @(test) exercising the transmute bridge | |
| #assert only | Literal values locked at compile time | |
| Runtime @(test) only | Literal comparisons visible in suite output | |
| Defer to Phase 2 | Criterion 3 = existing tests pass; truth tests join Phase 2 tripwire work | ✓ |

**User's choice:** Defer to Phase 2
**Notes:** Recorded in CONTEXT.md D-07 with the explicit consequence: Phase 1 criterion-3 evidence = existing suite + `#assert` chain passing; planner should mirror wording (and may adjust roadmap criterion text) so the verifier isn't whipsawed.

---

## Suite-pass gate

### Q1: kernel-matrix.yml toolchain

| Option | Description | Selected |
|--------|-------------|----------|
| Pin it now too | Same `release: dev-2026-11a` tag; every CI surface on one toolchain | ✓ |
| Leave on `latest` | Matrix self-manages until Phase 4 rewrites its checks | |

**User's choice:** Pin it now too

### Q2: Local integration run in the phase gate

| Option | Description | Selected |
|--------|-------------|----------|
| Require the real-kernel run locally | Container must allow Landlock syscalls; enforcement on 7.2 kernel required for exit | |
| Keep integration best-effort | Gate = compile + unit + example + cross-targets; integration when environment permits | ✓ |

**User's choice:** Keep integration best-effort
**Notes:** Context given: GitHub runners lack Landlock, so CI integration skips today; real-kernel proof lives locally (7.2 host) and in kernel-matrix VMs (Phase 4).

---

## Claude's Discretion

- Container image internals (base image, sha256 verification in build, caching, reuse across phases)
- Phase 2 truth-test constant coverage (deferred with the tests)
- README pin wording details (tag + `odin version` string + sha256 structure kept)
- Obvious deprecation-fix mechanics

## Deferred Ideas

None — discussion stayed within phase scope.
