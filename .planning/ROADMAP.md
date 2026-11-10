# Roadmap: odin-landlock

## Overview

This milestone takes the library from complete Landlock ABI v1–v9 coverage to ABI-head parity: the v10 surface (UDP bind/connect-send network rights, per-rule and ruleset-wide audit quieting, 48-byte ruleset attr) and the v11 surface (`LANDLOCK_RESTRICT_SELF_NO_NEW_PRIVS`), built on the latest Odin nightly, with the repo's full validation stack behind every feature and the kernel floor staying at ≥ 5.13. The path is toolchain-first (isolate compiler churn), then the raw ABI contract and cumulative gating chain (the correctness substrate every feature consumes), then the builder-API feature surface, then the proof stack (unit + real-kernel integration + conformance CI). Every new capability degrades best-effort on older kernels and never overstates what is enforced — the fail-closed contract is the thread through all four phases.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Toolchain Baseline** - Build and pass the full suite on Odin dev-2026-11 before any feature work lands (completed 2026-11-09)
- [ ] **Phase 2: ABI Contract & Gating (v10–v11)** - Raw syscall surface, versioned attr sizing, and cumulative gating chain extended through v11
- [ ] **Phase 3: Feature Surface — UDP, Quiet, NNP** - Builder-API coverage of v10 UDP rights, audit quieting, and v11 NNP elision
- [ ] **Phase 4: Validation Stack & Kernel-Matrix CI** - Per-feature unit, real-kernel integration, and conformance-probe coverage through v11

## Phase Details

### Phase 1: Toolchain Baseline
**Goal**: The project compiles and its entire test suite passes on the pinned Odin dev-2026-11 nightly, so all feature work starts from a verified toolchain with toolchain churn isolated from feature churn.
**Mode:** mvp
**Depends on**: Nothing (first phase)
**Requirements**: TOOL-01
**Success Criteria** (what must be TRUE):
  1. Library, examples, and tools build clean with the pinned dev-2026-11 nightly (no regressions vs the dev-2026-05 baseline).
  2. The full test suite passes on dev-2026-11, including fixes for the `core:fmt` pad-width change wherever tests/tools rely on it.
  3. Existing suite and `#assert` tripwire chain pass on dev-2026-11, evidencing no representation churn in transmute-bridged masks. (Literal bit-value truth tests deferred to Phase 2 by decision D-07 in `phases/01-toolchain-baseline/01-CONTEXT.md`, 2026-11-09.)
  4. README documents the dev-2026-11 pin.
**Plans**: 1/1 plans complete
- [x] 01-PLAN.md

### Phase 2: ABI Contract & Gating (v10–v11)
**Goal**: The hand-rolled syscall layer exposes the complete v10/v11 ABI surface (UDP net bits, `Add_Rule_Flag.Quiet`, `No_New_Privs`, 48-byte `Ruleset_Attr` with quiet fields, explicit create size) and the cumulative gating chain extends v9→v11 in kernel compat order, so every later feature is requestable and gated to the right kernels.
**Mode:** mvp
**Depends on**: Phase 1 (verification needs the new toolchain; `syscall/` authoring may proceed in parallel)
**Requirements**: GATE-01
**Success Criteria** (what must be TRUE):
  1. Probing a v10 kernel (host 7.2) reports the UDP bits in the v10 gating rows; the same requested access on a pre-v10 kernel has UDP stripped from its requested masks.
  2. Ruleset creation passes the ABI-appropriate attr size — 24 bytes below v10, 48 at v10+ — asserted in fake `Apply_Ops` tests.
  3. Per-dimension `#assert` tripwires are in place: a new bit in any dimension (FS, net, scopes, restrict) that isn't threaded into its cumulative chain fails compilation. Literal bit-value truth tests (mask comparisons against kernel constants) cover existing v1–v9 constants, deferred here from Phase 1 (D-07).
  4. Requested-vs-used and omission reporting stays truthful: a feature unsupported on the running kernel surfaces as an omission, never as silently enforced.
  5. Stub twins exist for every new syscall-layer proc and cross-compile checks pass.
**Plans**: TBD

### Phase 3: Feature Surface — UDP, Quiet, NNP
**Goal**: Odin developers can express every v10/v11 capability through the builder API — UDP bind and connect/send rights (with the port-0 ephemeral path), per-rule quiet and ruleset-wide quiet masks, and NNP elision — with typed results that report exactly what was enforced.
**Mode:** mvp
**Depends on**: Phase 2
**Requirements**: NET-01, NET-02, AUD-01, AUD-02, NNP-01
**Success Criteria** (what must be TRUE):
  1. A policy allowing UDP bind on selected ports applies on ABI ≥ v10: a sandboxed process binds an allowed UDP port and is denied a non-allowed one; port 0 covers the ephemeral auto-bind path.
  2. A policy allowing UDP connect/send permits sending on allowed ports and denies others on ABI ≥ v10.
  3. Callers can mark individual rules quiet — including quiet-only rules with empty `allowed_access` — and set ruleset-wide quiet masks; a quiet mask that is not a subset of the handled set fails validation with a typed error before any syscall.
  4. Requesting NNP elision on ABI ≥ v11 skips the caller-side `prctl(PR_SET_NO_NEW_PRIVS)` and NNP is set iff `restrict_self` succeeds; below v11 the flag degrades per strict/best-effort mode and lands in omissions.
  5. Feature downgrades go through the shared mask-and-skip-empty helper: no `ENOMSG` reaches the kernel from builder output, and partially-enforced policies report `Partially_Enforced`/`features_omitted`, never `Enforced` with a feature silently dropped.
**Plans**: TBD

### Phase 4: Validation Stack & Kernel-Matrix CI
**Goal**: Every v10/v11 feature is provable on real kernels — fake-seam unit coverage, fork-based real-kernel enforcement tests, and conformance-probe checks in the per-kernel CI matrix — matching the repo's existing quality bar.
**Mode:** mvp
**Depends on**: Phase 3
**Requirements**: VAL-01, VAL-02, VAL-03
**Success Criteria** (what must be TRUE):
  1. Every v10/v11 feature has unit tests through the fake `Apply_Ops` seam covering success, errno, and validation-failure paths, all passing.
  2. Fork-protocol real-kernel integration tests demonstrate v10 enforcement on the host 7.2 kernel (UDP denial, quiet behavior) and NNP set-iff-success observable via `/proc/self/status` where ABI ≥ 11 is available.
  3. The conformance probe gains v10 checks that run and pass on stable 7.2 kernels and fail loudly when the kernel lacks Landlock or probes below the expected ABI (no silent skips).
  4. CI runs the kernel matrix: v10 checks on 7.2-stable VMs and v11 checks on a linux-next/mainline virtme-ng job with `LANDLOCK_EXPECT_ABI` 10/11, skipping loudly (not silently) if 7.3-rc is not yet available.
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Toolchain Baseline | 1/1 | Complete    | 2026-11-09 |
| 2. ABI Contract & Gating (v10–v11) | 0/TBD | Not started | - |
| 3. Feature Surface — UDP, Quiet, NNP | 0/TBD | Not started | - |
| 4. Validation Stack & Kernel-Matrix CI | 0/TBD | Not started | - |
