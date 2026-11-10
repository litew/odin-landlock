# odin-landlock

## What This Is

An Odin library binding for the Linux Landlock LSM: a builder-style policy API (`Policy`) over raw Landlock syscalls, with per-kernel ABI gating (v1–v9), strict/best-effort apply modes, and typed `Policy_Result`/`Policy_Error` reporting. For Odin developers who need kernel-enforced, deny-by-default sandboxing of their own process (or forked children) on Linux ≥ 5.13.

## Core Value

Odin code can restrict itself with kernel-enforced Landlock policies that adapt to the running kernel's ABI and never overstate what is actually enforced (fail-closed by contract).

## Requirements

### Validated

<!-- Shipped and confirmed valuable. Inferred from the codebase map (2026-11-09). -->

- ✓ Filesystem access-right rules covering ABI v1–v9 (all `Access_FS_Flags`, `#assert` tripwire) — existing
- ✓ TCP bind/connect network rules (ABI v4 `Access_Net_Flags`) — existing
- ✓ Scope handling: signals + abstract Unix sockets (ABI v6 `Scope_Flags`) — existing
- ✓ Restrict-self flags incl. audit-consent/logging bits (v7) and Tsync (v8) — existing
- ✓ Runtime ABI probe + cumulative per-version gating tables (`ABI_FS_V1`..`V9`) — existing
- ✓ Strict vs best-effort apply with typed results, errno preservation, omission reporting — existing
- ✓ `Apply_Ops` test seam + unit suite (fake kernel calls, errno paths, allocator-failure paths) — existing
- ✓ Fork-based real-kernel integration test (`-define:LANDLOCK_INTEGRATION=true`) — existing
- ✓ CI: cross-compile checks + weekly ABI conformance probe in per-kernel VMs (virtme-ng) — existing

### Active

<!-- Current scope: milestone "ABI-head parity". Hypotheses until shipped. -->

- [ ] Research produces a definitive list of Landlock features in the current kernel ABI head beyond the mapped v1–v9 surface (FS, network, scopes, restrict flags)
- [ ] New filesystem access rights / path-rule extensions covered (builder API + typed errors + ABI gating)
- [ ] New network operations/families beyond TCP bind/connect covered
- [ ] New scope domains beyond signals/abstract Unix sockets covered
- [ ] New `LANDLOCK_RESTRICT_SELF_*` / audit-consent bits covered
- [ ] Kernel floor stays ≥ 5.13: every new feature degrades best-effort on older kernels (requested vs `abi_used`, omission reporting)
- [ ] Toolchain moved to latest Odin nightly; whole suite re-verified before feature work lands
- [ ] Each new feature: unit tests (fake `Apply_Ops`), real-kernel integration test, conformance-probe checks in kernel-matrix CI

### Out of Scope

- Raising the kernel floor — user decision: keep ≥ 5.13 broad compatibility; old-kernel behavior is best-effort, not unsupported
- Non-Linux enforcement — existing design: compile via stubs, `Unsupported_Platform` result
- CLI sandbox wrapper / userland tooling — library-only milestone
- seccomp, cgroups, or other-LSM integration — different mechanism, unrelated to Landlock ABI parity

## Context

- Brownfield, library-only repo (no root main). Codebase map: `.planning/codebase/` (2026-11-09, commit ac37c87).
- Layering is strict one-way: examples → `landlock` (policy) → `syscall` (raw ABI) → `core:sys/linux` → kernel. New features must thread through all layers without breaking the import rule.
- ABI drift is guarded at compile time (`#assert(ABI_FS_V9 == ABI_FS_ALL)`, attr-struct size asserts); every new bit/struct must extend the cumulative chain or compilation fails.
- `core:sys/linux` is load-bearing; new kernel surface may need hand-rolled wrappers (precedent: existing openat2 wrapper) depending on what the latest Odin nightly ships.
- Kernel-matrix CI runs the conformance probe in per-kernel VMs; new-feature checks must respect irreversibility (one fork per check).
- Deny-by-default handled-set model (go-landlock style): `init` defaults the handled set to all three access dimensions; new dimensions must join `HANDLED_DEFAULT` deliberately.

## Constraints

- **Tech stack**: Odin; moving from dev-2026-05 nightly to latest nightly at milestone start — suite must pass before feature work proceeds.
- **Compatibility**: kernel ≥ 5.13 floor kept; all new features gated per-ABI-version and degrade best-effort below their introduction kernel.
- **Semantics**: Landlock enforcement is cumulative and irreversible; fail-closed contract preserved — apply never aborts, callers check `is_enforced`.
- **Dependencies**: `core:sys/linux` internals; hand-rolled syscall wrappers allowed where core lacks surface.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Milestone = ABI-head parity across all dimensions (FS, network, scopes, restrict flags) | User directive: deep-research new kernel features, implement support for all of them | — Pending |
| Keep ≥ 5.13 kernel floor | Broad compatibility; matches existing ABI-gating design | — Pending |
| Full validation stack per feature (unit + integration + conformance probe) | Match repo's existing quality pattern; enforcement is only provable on real kernels | — Pending |
| Bump Odin nightly up front, re-verify before features | New core:sys/linux surface may be required by new ABIs; isolate toolchain churn from feature churn | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd:complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-11-09 after initialization*
