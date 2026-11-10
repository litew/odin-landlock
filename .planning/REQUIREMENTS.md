# Requirements: odin-landlock ABI-Head Parity

**Defined:** 2026-11-09
**Core Value:** Odin code can restrict itself with kernel-enforced Landlock policies that adapt to the running kernel's ABI and never overstate what is actually enforced (fail-closed by contract).

## v1 Requirements

Requirements for this milestone. Each maps to roadmap phases.

### Network — UDP rights (ABI v10, kernel 7.2 — released)

- [ ] **NET-01**: Caller can allow UDP *bind* on selected ports via the builder API on ABI ≥ v10 (`LANDLOCK_ACCESS_NET_BIND_UDP`, reusing `LANDLOCK_RULE_NET_PORT`; port 0 = ephemeral range, auto-bind path covered)
- [ ] **NET-02**: Caller can allow UDP *connect/send* on selected ports via the builder API on ABI ≥ v10 (`LANDLOCK_ACCESS_NET_CONNECT_SEND_UDP`)

### Audit quieting (ABI v10, kernel 7.2 — released)

- [ ] **AUD-01**: Caller can mark individual rules quiet (`LANDLOCK_ADD_RULE_QUIET`), including quiet-only path rules with empty `allowed_access`
- [ ] **AUD-02**: Caller can set ruleset-wide quiet masks (`quiet_access_fs` / `quiet_access_net` / `quiet_scoped`), validated as subsets of the handled sets

### Privilege handling (ABI v11, kernel 7.3 — in dev)

- [ ] **NNP-01**: Caller can opt into eliding the caller-side `prctl(PR_SET_NO_NEW_PRIVS)` via `LANDLOCK_RESTRICT_SELF_NO_NEW_PRIVS` on ABI ≥ v11; on older kernels the flag degrades per strict/best-effort mode

### Gating correctness

- [ ] **GATE-01**: Cumulative gating chain extends v9→v11 in kernel compat order (UDP stripped below v10, NNP below v11); `#assert` tripwires updated (ruleset attr 24→48 bytes at v10); requested-vs-used and omission reporting stays truthful

### Toolchain

- [x] **TOOL-01**: Project builds and the full suite passes on Odin `dev-2026-11` nightly; README pin updated

### Validation

- [ ] **VAL-01**: Each v10/v11 feature has unit tests through the `Apply_Ops` fake seam, including errno and validation-failure paths
- [ ] **VAL-02**: Each v10/v11 feature has real-kernel integration coverage via the fork protocol (v10 provable on host kernel 7.2)
- [ ] **VAL-03**: Conformance probe gains v10 checks runnable on stable 7.2; a linux-next virtme-ng CI job covers v11 until 7.3 ships

## v2 Requirements

Deferred to a future milestone. Tracked but not in the current roadmap.

### Permission model (ABI v12, kernel master ≈7.4)

- **PERM-01**: Namespace-use permission rules (`LANDLOCK_RULE_NAMESPACE`, `LANDLOCK_PERMISSION_NAMESPACE_USE`, `handled_permissions` field)
- **PERM-02**: Capability-use permission rules (`LANDLOCK_RULE_CAPABILITY`, `LANDLOCK_PERMISSION_CAPABILITY_USE`)
- **PERM-03**: Ruleset attr 56-byte contract, `-ENOMSG` empty-rule semantics, forward-compat bit handling (unknown bits ignored, not masked)
- Design note deferred with the dimension: whether `.Permission` joins `HANDLED_DEFAULT` is a deliberate deny-by-default decision, not a mechanical extension

### Errata probe surface (kernel ≥ 6.15)

- **ERR-01**: `LANDLOCK_CREATE_RULESET_ERRATA` probe reporting of errata 1–4 (probe/CI only, never a gating input)

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| MPTCP network rights | Unmerged (Sept 2026 series); its "ABI 12" target was superseded by the v12 permission model — binding constants now guarantees wrong gating on release. Revisit when a tagged kernel carries them |
| Speculative FS rights (chdir/stat/chmod/…) | Nothing merged upstream; the existing `#assert(ABI_FS_V9 == ABI_FS_ALL)` tripwire fires loudly when the head actually moves |
| Errata gating in the builder API | Kernel docs warn gating on errata can *reduce* protection; probe-only surface if ever added |
| Raising the kernel floor | User decision: keep ≥ 5.13 best-effort compatibility |
| Non-Linux enforcement | Existing design: compile via stubs, `Unsupported_Platform` result |
| CLI sandbox wrapper / userland tooling | Library-only milestone |
| seccomp / cgroups / other LSM integration | Different mechanisms, unrelated to Landlock ABI parity |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| NET-01 | Phase 3 | Pending |
| NET-02 | Phase 3 | Pending |
| AUD-01 | Phase 3 | Pending |
| AUD-02 | Phase 3 | Pending |
| NNP-01 | Phase 3 | Pending |
| GATE-01 | Phase 2 | Pending |
| TOOL-01 | Phase 1 | Complete |
| VAL-01 | Phase 4 | Pending |
| VAL-02 | Phase 4 | Pending |
| VAL-03 | Phase 4 | Pending |

**Coverage:**
- v1 requirements: 10 total
- Mapped to phases: 10
- Unmapped: 0 ✓ (100% coverage)

---
*Requirements defined: 2026-11-09*
*Last updated: 2026-11-09 after roadmap creation*
