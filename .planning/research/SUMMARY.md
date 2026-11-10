# Project Research Summary

**Project:** odin-landlock — ABI-head parity milestone (v9 → v11 surface)
**Domain:** Odin language binding for the Linux Landlock LSM
**Researched:** 2026-11-09
**Confidence:** HIGH

## Executive Summary

odin-landlock already covers Landlock ABI v1–v9 (through `LANDLOCK_ACCESS_FS_RESOLVE_UNIX`, kernel 7.1). The ABI head has moved in three waves: **v10** (kernel 7.2, released — UDP `bind`/`connect-send` rights plus `LANDLOCK_ADD_RULE_QUIET` and three `quiet_*` ruleset fields), **v11** (merged mainline, ships in the in-development 7.3 — `LANDLOCK_RESTRICT_SELF_NO_NEW_PRIVS`, which ties `no_new_privs` to successful enforcement and replaces the manual `prctl(PR_SET_NO_NEW_PRIVS)`), and **v12** (same next kernel — a new permission dimension: `handled_permissions`, namespace/capability rules). Per user scoping, **this milestone targets v10 + v11 plus the toolchain bump; v12 and the errata probe are deferred to v2.** The target surface is fully testable today on the host kernel (7.2.11-300.fc45, live probe: abi=10, errata=15); v11 tests need a 7.3-rc/mainline kernel in CI via virtme-ng until 7.3.0 ships (≈ Dec 2026/Jan 2027).

The recommended approach is in-place extension of the existing strict two-layer design — **no new packages, layers, or files**. Crucially, `core:sys/linux` exposes only `SYS_landlock_*` syscall *numbers* (TODO stubs confirmed on master and in dev-2026-11); the hand-rolled `syscall/` package remains the single source of ABI truth after the Odin dev-2026-11 bump, and the hand-rolled `Open_How`/openat2 wrapper stays. The bump itself is low-risk: the two breaking changes (`core:fmt` pad-width, `core:compress` overhaul) touch code the repo doesn't load-bear, but it must land as its own phase first, whole suite green.

The dominant risks are all *gating and downgrade-path* risks, exemplified by go-landlock's GHSA-vv6c-69r6-chg9 (a released binding that silently stopped restricting TCP when downgrading configs): a new bit that isn't threaded into the cumulative per-dimension ABI chain either silently never gets requested, or gets requested on kernels that don't know it and EINVALs the whole ruleset. Prevention is mechanical: per-dimension `#assert` tripwires extended to every dimension (not just FS), versioned ruleset-attr sizing (struct grew 24 → 48 bytes at v10), shared mask-and-skip-empty downgrade helper (kernel returns `ENOMSG` on empty rules), and probe checks landing with every feature.

## Key Findings

### Recommended Stack

The toolchain bump (dev-2026-05 → dev-2026-11, released 2026-11-03) is isolated churn: no core:sys/linux Landlock surface appears or disappears; the hand-rolled `syscall/` package stays authoritative. Kernel ABI v10 is live-verified on the host; v11 needs a mainline VM.

**Core technologies:**
- **Odin dev-2026-11** — compiler pin, bumped at milestone start before any feature merge; audit `core:fmt` users in tests/tools for the `0`-padding change (#7724); expect possible new vet warnings, fix once.
- **Hand-rolled `syscall/` package** — remains the ABI surface: `core:sys/linux` has no Landlock flags/attrs/wrappers and won't for the foreseeable future (upstream TODOs static). All v10/v11 constants hand-transcribed from `include/uapi/linux/landlock.h` with the pinned commit hash documented beside them.
- **Kernel floor 5.13 (unchanged)** — standing user decision; all new bits degrade best-effort below their introduction kernel via the existing probe + gating tables.
- **Kernel matrix: 7.2.x stable (host 7.2.11-300.fc45 probes abi=10) + mainline/7.3-rc via virtme-ng** — v10 testable today; v11 (`No_New_Privs` restrict flag) reachable only on 7.3-rc+; distro kernels will not ship v11 for a long time.
- **virtme-ng 1.42** (`vng --build` for mainline kernels) — with `CONFIG_SECURITY_LANDLOCK=y` and `lsm=landlock` verified (`dmesg` "landlock: Up and running") before any probe checks.

### Expected Features

**Must have (table stakes, this milestone per user scoping):**
- **v10 UDP network rights** — `LANDLOCK_ACCESS_NET_BIND_UDP` (1ULL<<2), `LANDLOCK_ACCESS_NET_CONNECT_SEND_UDP` (1ULL<<3); two new bits in `Access_Net_Flags`, reusing `LANDLOCK_RULE_NET_PORT` + existing wrapper unchanged. Kernel guidance: UDP auto-bind on first send needs `BIND_UDP` on port 0 — ship a builder convenience (e.g. ephemeral-bind / DNS helper), don't leave it to callers.
- **v10 quiet audit-suppression surface** — `Add_Rule_Flag.Quiet` (per-rule quiet-only rules, empty `allowed_access` permitted) plus ruleset fields `quiet_access_fs`/`quiet_access_net`/`quiet_scoped`. Constraints: quiet must be a **subset** of handled per dimension (kernel EINVALs otherwise); quiet is advisory — unsupported-ABI quiet bits are recorded **omissions**, never errors. Requires `create_ruleset` to take an explicit size (attr grows 24 → 48 bytes).
- **v11 `LANDLOCK_RESTRICT_SELF_NO_NEW_PRIVS` elision** (1U<<4) — new restrict flag; when applied (ABI ≥ 11) the apply pipeline **skips the caller-side `prctl(PR_SET_NO_NEW_PRIVS)`** (kernel sets NNP iff `restrict_self` succeeds); below v11, prctl-then-restrict order preserved unchanged. This is the only place apply *orchestration* changes shape. Composes with TSYNC (propagates NNP to siblings).
- **Gating/tripline extension through v11** — `ABI_NET_V10 = ABI_NET_V4 + {UDP bits}`, `ABI_RESTRICT_V11 = ABI_RESTRICT_V8 + {.No_New_Privs}` cumulative chains; `abi_versions` [10] → [12] rows; promote the single FS-only `#assert(ABI_FS_V9 == ABI_FS_ALL)` tripwire to **one tripwire per dimension** so a new bit in any dimension must be threaded into its chain or compilation fails.
- **Validation stack** — probe-first discipline: every feature lands its fork-per-check enforcement tests in `tools/abi-conformance` in the same merge train; per-ABI expected-mask unit table mirroring the kernel docs' compatibility switch verbatim; fake-seam unit tests per (errno, site); cross-compile (stub twins) on every merge; `LANDLOCK_EXPECT_ABI` bumped deliberately, `EXIT_ABI_MISMATCH` stays loud.

**Should have (differentiators, cheap adds):**
- Quiet flags are a genuine differentiator — no other binding exposes per-object audit suppression.
- Errata probe (`LANDLOCK_CREATE_RULESET_ERRATA`, works since 6.15): expose as **probe/CI data only** — kernel docs explicitly warn against gating enforcement on errata.

**Defer (v2+, per user scoping):**
- **v12 permission dimension** (`handled_permissions`, `LANDLOCK_PERMISSION_NAMESPACE_USE`/`CAPABILITY_USE`, `LANDLOCK_RULE_NAMESPACE`/`CAPABILITY`, attr → 56 bytes) — a genuinely new dimension requiring a deliberate `HANDLED_DEFAULT` decision; deferred whole. The per-dimension tripwire pattern makes later addition safe.
- MPTCP network rights — unmerged upstream; will renumber (≥13); revisit when tagged.
- Errata-based policy logic — never (anti-feature).

### Architecture Approach

The one-way layering (consumers → `landlock` policy → local `syscall` → `core:sys/linux` generic plumbing → kernel) absorbs everything in place, mirroring the kernel's own in-place growth axes. Ownership rule: constants/struct layout in `syscall`; semantics/gating/orchestration in `landlock`; kernel mechanics in the Linux impl + stub twins; observability in consumers.

**Major components:**
1. **`syscall/` (extended)** — `Access_Net_Flag` +2 UDP members; `Add_Rule_Flag.Quiet`; `Restrict_Self_Flag.No_New_Privs`; `Ruleset_Attr` grows to 48 bytes (3 quiet fields); `create_ruleset` gains an **explicit size param** (today it hardcodes `size_of`); `restrict_self` needs no signature change; `#assert` pins: 16 (net_port) / 48 (ruleset); stub twins for every new proc in the same commit.
2. **`landlock` policy layer (extended)** — new cumulative ABI chains + per-dimension tripwires; `abi_versions` rows; versioned attr-size table (24 below v10, 48 at v10+); quiet-set validation (⊆ handled, both dimensions); conditional-prctl orchestration; builder knobs (`allow_udp_bind/send`, per-rule `.Quiet` option, `handle_flags(.No_New_Privs)`); `Policy_Result` gains `quiet_applied/omitted` (UDP → existing `.Network` features pair; NNP → existing `flags_applied/omitted` pair — no new result shapes beyond quiet).
3. **`Apply_Ops` seam (extended first)** — extend the proc-struct + fake call kinds **before** builder work (the quiet flag is a parameter change, not a new entry); this unblocks parallel feature slices without merge conflicts.
4. **`tools/abi-conformance` + CI matrix (extended)** — v10 fork-checks on 7.2 VMs (available today), v11 checks gated on a 7.3-rc/mainline VM; errata logged, never gating.

### Critical Pitfalls

1. **Attr-size tripwire (24 → 48 bytes)** — passing the old hardcoded `size_of(Ruleset_Attr)` (24) on v10+ kernels EINVALs and makes the new fields unreachable; passing 48 on older kernels risks E2BIG on nonzero unknown tails. Fix: explicit size param + versioned size table (24/48) selected from the probed ABI, `#assert(size_of(Ruleset_Attr) == 48)`, plus a fake-ops assertion that the size passed matches the probed ABI.
2. **Per-dimension `#assert` generalization** — the existing tripwire is FS-only; a forgotten UDP bit today compiles silently. Generalize to one tripwire per dimension (`ABI_NET_V10 == ABI_NET_ALL`, `ABI_RESTRICT_V11 == ABI_RESTRICT_ALL`) in the same commit that adds the bits, and mirror the kernel docs' compatibility switch as a per-ABI expected-mask unit table (ABI 1..12).
3. **Gating insertion order is load-bearing** — the compat chain must strip in kernel order (`case 9 → UDP`, `case 10 → NNP`); a wrong insertion point silently over-grants on mid-range kernels. Cumulative mask chains, never `abi >= N` range checks.
4. **GHSA-vv6c-69r6-chg9 handled-set downgrade class** — go-landlock shipped a silent hole where requested TCP restrictions vanished on config downgrade. For this milestone: UDP bits must join the handled set deliberately, rule downgrades must go through one shared mask-and-skip-empty helper, and omissions must surface in `features_omitted`/`Partially_Enforced` — never `Enforced` with the feature silently dropped.
5. **ENOMSG empty-rule semantics** — the kernel rejects a rule whose masked `allowed_access` is 0 with `ENOMSG` rather than ignoring it. Mask + skip-empty at the builder so ENOMSG is impossible by construction; ENOMSG surfacing as a `Policy_Error` in tests means the downgrade helper is wrong.
6. **virtme-ng kernels lacking `CONFIG_SECURITY_LANDLOCK`** — minimal vng kernels can boot without Landlock (or without `lsm=landlock`), making `create_ruleset` return `EOPNOTSUPP` and every probe check silently no-op. Verify "landlock: Up and running" in dmesg before checks; fail the probe hard if probed ABI < the checks' expected minimum.
7. **Distro kernels not shipping v10+/v11** — v10 exists only in 7.2+ distro kernels; v11 in none. CI needs the 7.2 stable matrix plus a mainline `vng --build` job until 7.3.0; a probe that "passes" by skipping on old kernels is a false-conformance signal (same silence shape as the GHSA).
8. **Toolchain-bump regressions** — bit_set backing churn (#7664) could silently change `transmute`-bridged masks; land the bump alone with whole suite green and add numeric bit-value truth tests (literal mask comparisons) kept forever.

## Implications for Roadmap

Based on research, suggested phase structure (dependencies: toolchain bump serializes; syscall contract → gating; seam → builder; feature → probe checks):

### Phase 1: Toolchain bump to Odin dev-2026-11
**Rationale:** PROJECT.md decision — isolates toolchain churn from feature churn; serializes all merges.
**Delivers:** bumped pin, whole suite green, bit-value truth tests, `core:fmt` padding audit of tests/tools.
**Avoids:** Pitfall 8 (representation-change mis-requesting rights).

### Phase 2: Syscall contract + Apply_Ops seam (v10/v11 constants, 48-byte attr, explicit size param)
**Rationale:** every later phase consumes these types; the seam extension is one small change that unblocks parallel feature slices. (`syscall/` authoring can start in parallel with Phase 1; landing waits on it — content is not toolchain-dependent, only verification is.)
**Delivers:** UDP enum members, `Add_Rule_Flag.Quiet`, `No_New_Privs`, `Ruleset_Attr` (48 B) + quiet fields, `create_ruleset` size param, stub twins, fake call kinds, `#assert` size pins.
**Addresses:** v10 quiet surface groundwork, v10 UDP, v11 flag.
**Avoids:** Pitfall 1 (attr-size tripwire), platform-stub leaks.

### Phase 3: Gating + versioned sizing
**Rationale:** depends only on Phase 2 types; correctness infrastructure before features.
**Delivers:** `ABI_NET_V10`/`ABI_RESTRICT_V11` cumulative chains, per-dimension `#assert` tripwires, `abi_versions` rows through v11, versioned attr-size table (24/48), per-ABI expected-mask unit table mirroring the kernel compat switch.
**Addresses:** gating/tripline extension.
**Avoids:** Pitfall 3 (gating insertion order), range-check rot.

### Phase 4: Builder API + apply integration, per feature slice (parallelizable)
**Rationale:** four slices touch disjoint symbol sets: UDP rights | quiet sets + per-rule quiet | NNP flag + conditional prctl | (validation/reporting wiring). Shared downgrade helper lands here.
**Delivers:** `allow_udp_bind/send` (+ ephemeral/DNS convenience), quiet validation (⊆ handled) + `quiet_applied/omitted` reporting, NNP gating with prctl elision on ABI ≥ 11; UDP bits join handled set deliberately.
**Uses:** `Apply_Ops` seam, versioned sizing, ABI chains.
**Implements:** all table-stakes features.
**Avoids:** Pitfall 4 (GHSA downgrade class), Pitfall 5 (ENOMSG), NNP-as-pure-flag orchestration miss.

### Phase 5: Validation stack — unit, integration, conformance, CI matrix
**Rationale:** probe-first discipline: each feature's fork-checks land with it in Phase 4; this phase completes the harness and CI.
**Delivers:** fork-per-check enforcement tests (UDP connect must fail, quiet rule behavior, NNP set-iff-success via `/proc/self/status`), errno classification tests per site, 7.2-stable VM matrix + `vng --build` mainline job for v11 checks with Landlock-enabled config, `LANDLOCK_EXPECT_ABI` 10/11, errata logging (probe-only).
**Avoids:** Pitfalls 6–7 (silent no-op probes on Landlock-less vng kernels; old-kernel false conformance).

### Phase Ordering Rationale

- **S0-first dependency:** toolchain bump serializes everything; no feature merge before it.
- **Contract-before-consumer:** `syscall/` types and the `Apply_Ops` seam are shared prerequisites; landing them as one phase lets the four feature slices proceed in parallel without seam conflicts.
- **Gating before builders:** gating tables and versioned sizing are the correctness substrate; builders coded against them can't over-grant.
- **Probe checks are part of each feature's definition**, not a trailing phase — the only way to avoid CI-green-but-untested drift.

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 5 (CI kernel matrix):** 7.3-rc availability timing is inferred from kernel cadence (≈ Dec 2026/Jan 2027); the `vng --build` mainline workflow is the least-verified piece (MEDIUM confidence). Plan for v11 checks to be gated/skipped-loudly if 7.3-rc isn't ready.
- **Phase 4 (quiet surface):** quiet semantics (subset enforcement, per-rule quiet-only rules, omission-vs-error policy) have no binding precedent to copy — the design is our own; worth a focused plan-phase.

Phases with standard patterns (skip research-phase):
- **Phase 1 (toolchain bump):** fully assessed; two breaking changes identified, neither load-bearing.
- **Phase 2/3 (syscall contract + gating):** existing v1–v9 patterns extend mechanically; kernel structs/flags fully documented from the uapi header.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Kernel ABI surface verified from torvalds master + live host probe (abi=10); Odin dev-2026-11 core surface directly inspected; only CI tooling versions MEDIUM-HIGH |
| Features | HIGH | All v10/v11 constants verified in the uapi header at tagged kernels; semantics from October 2026 kernel docs |
| Architecture | HIGH | Extension map grounded in the mapped codebase baseline + direct `syscall/` inspection; no new layers needed |
| Pitfalls | HIGH | Every pitfall grounded in man-pages errno tables, kernel source, or the GHSA precedent; v11 CI timing MEDIUM (cadence inference) |

**Overall confidence:** HIGH

### Gaps to Address

- **7.3 release date** — inferred from cadence, not announced; Phase 5's v11 CI checks need a fallback (skip-loudly on absent 7.3-rc, per `LANDLOCK_EXPECT_ABI` semantics). Re-check at plan time.
- **Exact encoding of versioned attr sizing** — `copy_struct_from_user` zero-tail behavior verified in kernel source, but the chosen versioned-size scheme should be confirmed against `security/landlock/syscalls.c` during Phase 2 implementation.
- **v9's kernel mapping (7.1 vs 7.2 window)** — not fully decidable from landlock-only git history; re-check per-version comments when writing ABI tables in Phase 3.
- **Competitor status** (rust-landlock UDP progress) — based on partial source sighting, not audited; irrelevant to scope but noted for the differentiator claim.

## Sources

### Primary (HIGH confidence)
- torvalds/linux `include/uapi/linux/landlock.h` @ master + tags v6.14–v7.3 (fetched 2026-11-09) — all v10/v11 constants, struct layouts, sizes
- `security/landlock/syscalls.c` @ master — `landlock_abi_version = 12`, `build_check_abi` size pins, size/errno contract
- docs.kernel.org `userspace-api/landlock.html` (Oct 2026) — compat switch, UDP/quiet/NNP semantics, errata guidance
- man-pages 6.19 `landlock(2/7)`, `landlock_create_ruleset(2)`, `landlock_add_rule(2)`, `landlock_restrict_self(2)`, `openat2(2)` — errno tables, port-0 semantics, ABI VERSIONS table
- Live kernel probe on 7.2.11-300.fc45.x86_64 (2026-11-09): abi=10, errata=15
- Odin dev-2026-11 release (2026-11-03, e28f5d1, signed) + local dev-2026-10 install inspection (`sys.odin` Landlock/openat2 TODO stubs)
- github.com/go-landlock GHSA-vv6c-69r6-chg9 (2024-10-14) — handled-set downgrade precedent

### Secondary (MEDIUM confidence)
- kernsec LSM-ML series: UDP v4/v5 (May–Jun 2026), quiet flags (Jun 2026), NNP v2/v3 (Jul–Aug 2026) — provenance and merge dates
- Kernel git log merge tags (`landlock-7.2-rc1`) pinning v10 = 7.2; v11 = 7.3-in-dev (2026-08-15)
- PyPI/Fedora virtme-ng versions (1.42 / 1.41-5)

### Tertiary (LOW confidence)
- 7.3.0 release timing (≈ Dec 2026–Jan 2027) — cadence inference
- rust-landlock / go-landlock current feature status — partial source sighting

---
*Research completed: 2026-11-09*
*Ready for roadmap: yes*
