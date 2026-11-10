# Phase 1: Toolchain Baseline - Context

**Gathered:** 2026-11-09
**Status:** Ready for planning

<domain>
## Phase Boundary

Phase 1 delivers a verified toolchain baseline: the library, examples, and tools compile clean and the entire existing test suite passes on the pinned Odin `dev-2026-11` nightly (exact release tag `dev-2026-11a`), with the pin enforced in CI, documented in README, and reproducible locally in a podman container. No feature work — this phase isolates toolchain churn (compiler + `core:*` behavior changes) from feature churn before Phase 2 touches the ABI surface. Scope = TOOL-01 only; fixes are limited to what the nightly bump breaks or obsoletes.

</domain>

<decisions>
## Implementation Decisions

### Toolchain pinning

- **D-01:** CI pins the exact Odin release tag `dev-2026-11a` (hotfix release published 2026-11-03; its linux-amd64 artifact is byte-identical, same sha256, to `dev-2026-11`) via `laytan/setup-odin@v2` `release:` input — replacing today's floating `release: latest` in **both** `.github/workflows/ci.yml` and `.github/workflows/kernel-matrix.yml`. Verified live: the `dev-2026-11` release exists with downloadable `odin-linux-amd64-dev-2026-11.tar.gz` artifacts, so the action's release-artifact path (no source build) works. — **Reversibility:** reversible — one-line change per workflow.
- **D-02:** README documents the pinned tag, the exact `odin version` string of the pinned binary, and the release artifact sha256, so vendoring users can verify bit-identical toolchains. — **Reversibility:** reversible.
- **D-03:** Local verification runs inside a **podman container** whose toolchain source is the pinned release tarball (sha256-verified at image build), NOT the host's `~/.local/bin/odin` (currently `dev-2026-10-nightly:84bc3fc`, one month stale). User explicitly chose the container route over downloading the tarball to a user dir (their standing rule: read-only atomic host, tooling in containers). — **Reversibility:** reversible — swapping to a host tarball is a local tooling change; but the container recipe becomes the standard way every phase's executor verifies, so plans should define it once and reuse it.

### Nightly-breakage policy

- **D-04:** **Adopt new `core:*` surface now** — wherever `dev-2026-11` ships what a hand-rolled wrapper covers (e.g. `O_PATH`/openat2 paths via `core:os`/`core:sys/linux`), delete the local wrapper and use core. Bounded by what the nightly actually ships: the Landlock syscalls themselves stay hand-rolled where core still lacks surface. — **Reversibility:** costly — deleting a wrapper discards working code; undoing means re-deriving it (incl. its security-rationale comments and TOCTOU semantics) if the core surface proves insufficient, and Phase 2 rewrites this layer with v10/v11 assumptions built on whatever survived.
- **D-05:** **Ride new defaults** for intentional core behavior changes (notably the `core:fmt` pad-width change): update call sites and test expectations to the new behavior; no compatibility shims and no explicit-width pinning to preserve old output. The project pins one nightly; callers get what the pin produces.
- **D-06:** "Builds clean" means **zero warnings AND zero errors** — all deprecation warnings surfaced by `dev-2026-11` are fixed in this phase, not tolerated. (User chose stricter-than-recommended here, deliberately mixed with D-05's no-shims stance.)

### Roadmap criterion adjustment

- **D-07:** Roadmap success criterion 3 ("numeric bit-value truth tests pass") is satisfied in Phase 1 by the **existing suite + `#assert` chain passing on the new nightly** — no new literal-value tests are authored in this phase. Literal bit-value truth tests for existing v1–v9 constants are **deferred to Phase 2**, joining the per-dimension `#assert` tripwire work (Phase 2 criterion 3) where v10/v11 constants land alongside. **Planner should mirror this wording** (and may update the roadmap criterion text) so the verifier accepts existing-coverage evidence instead of expecting new test files.

### Phase-exit gate

- **D-08:** Phase gate = locally (container) AND in CI: `odin check . -no-entry-point`, both unit suites (`odin test .`, `odin test syscall`), example build, README doc-snippet compile probe, darwin_amd64 + freebsd_amd64 cross-target checks — all green on the pinned nightly. Cross-target set stays as-is (no new targets).
- **D-09:** The real-kernel integration test stays **best-effort** in the gate: it runs where the environment permits (host kernel 7.2 has Landlock; CI runners don't, so CI skips as today) but a real-kernel run is not a hard phase-exit requirement. If the container blocks Landlock syscalls (seccomp), running it on the host binary or skipping locally is acceptable for phase exit.

### Claude's Discretion

- Container image internals: release tarball as image source, sha256 verification in the image build, image caching/reuse across phases, exact base image.
- Which specific constants the Phase 2 truth tests cover (deferred with the tests).
- README pin wording details (structure kept: tag + `odin version` string + sha256).
- Mechanics of warning fixes where the fix is obvious (deprecation → replacement API).

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

No external specs/ADRs exist for this project — requirements are fully captured in decisions above. Canonical references are the planning docs and the pinned release.

### Planning docs
- `.planning/ROADMAP.md` §Phase 1 — goal, mode (mvp), success criteria (read with D-07's adjustment in mind)
- `.planning/REQUIREMENTS.md` §Toolchain (TOOL-01) — the single requirement this phase delivers
- `.planning/PROJECT.md` §Constraints — nightly-bump-first rule, ≥ 5.13 kernel floor, fail-closed contract; §Key Decisions — nightly bump rationale

### Codebase maps
- `.planning/codebase/TESTING.md` — full suite command list (the phase gate in D-08 mirrors it), test layout, fake-seam patterns
- `.planning/codebase/STACK.md` — pinned-toolchain policy, load-bearing `core:sys/linux` dependency incl. hand-rolled openat2 precedent
- `.planning/codebase/ARCHITECTURE.md` — layering (examples → landlock → syscall → core:sys/linux) that D-04's wrapper adoption must not break

### Repo surfaces this phase edits
- `.github/workflows/ci.yml` — `laytan/setup-odin@v2` block (`release: latest` → `dev-2026-11a`), all gate steps
- `.github/workflows/kernel-matrix.yml` — same setup-odin block (D-01)
- `README.adoc` (~line 19) — toolchain note to re-pin (D-02)
- `syscall/syscall_linux.odin` — hand-rolled wrappers subject to D-04 adoption/deletion

### External
- `https://github.com/odin-lang/Odin/releases/tag/dev-2026-11a` — pinned release; linux-amd64 asset `odin-linux-amd64-dev-2026-11a.tar.gz`, sha256 `65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618` (identical to `dev-2026-11`'s linux-amd64 asset)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `Apply_Ops` fake seam (`landlock.odin` + `landlock_test_linux.odin`): the whole unit suite runs kernel-free — toolchain bump verification is not blocked by kernel/ABI questions.
- `#assert` tripwires (`syscall/syscall.odin`): cumulative chain + attr-size checks already prove layout/representation stability at compile time — the existing drift protection that D-07 leans on.
- Cross-target stub twins (`syscall/syscall_unsupported.odin`, `landlock_test_unsupported.odin`): darwin/freebsd checks keep proving portability during the bump.

### Established Patterns
- Platform split via build tags (`#+build !linux`): any wrapper deletion under D-04 must keep the stub twins compiling on all three targets.
- Test file conventions (colocated `*_test_linux.odin`, errno-exact asserts): expectation updates under D-05 follow existing style, no new patterns.
- CI gate list lives in `.github/workflows/ci.yml` and is mirrored in TESTING.md — gate changes must stay in sync with both.

### Integration Points
- `.github/workflows/ci.yml` `laytan/setup-odin@v2` step — the pin insertion point (D-01).
- `.github/workflows/kernel-matrix.yml` setup-odin step — same pin (D-01); conformance binary is built on the runner host, so the pin affects it directly.
- `README.adoc` vendoring note — user-facing pin documentation (D-02).
- `syscall/syscall_linux.odin` — `core:sys/linux`/`core:os` adoption points for D-04.

</code_context>

<specifics>
## Specific Ideas

- Pin semantics anchored to a live-verified fact: `dev-2026-11a` (hotfix, 2026-11-03) exists as a release tag with downloadable artifacts and a published sha256 — the pin is an exact tag, never `latest`, never a commit hash.
- Local verification container is user doctrine, not convenience: read-only atomic host, tools live in podman containers. Plans should treat the container recipe as durable infrastructure reused by Phases 2–4 executors.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope. (D-07's truth-test deferral is a phase-boundary decision recorded under decisions, with Phase 2 as its landing place.)

</deferred>

---

*Phase: 1-Toolchain Baseline*
*Context gathered: 2026-11-09*
