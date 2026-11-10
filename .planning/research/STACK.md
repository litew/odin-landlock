# Stack Research — Toolchain & Kernel Surface for Landlock ABI-Head Parity

**Project:** odin-landlock (milestone: ABI-head parity beyond v9)
**Researched:** 2026-11-09
**Confidence:** HIGH (kernel ABI surface: HIGH; Odin toolchain: HIGH; CI tooling versions: MEDIUM-HIGH)

---

## Executive Summary

The existing repo covers Landlock ABI v1–v9. The mainline kernel ABI head is now **v12**, spread over three feature waves this repo does not yet wrap:

- **ABI v10** (kernel 7.2, current stable): UDP `bind`/`connect-send` network rights; `LANDLOCK_ADD_RULE_QUIET` plus three new `quiet_*` ruleset fields (per-object audit suppression).
- **ABI v11** (merged mainline, next kernel ≈ 7.3, not yet released as of 2026-11-09): `LANDLOCK_RESTRICT_SELF_NO_NEW_PRIVS` restrict flag (ties `no_new_privs` to successful enforcement, replacing the manual `prctl(PR_SET_NO_NEW_PRIVS)`).
- **ABI v12** (merged mainline, same next kernel): a new **permission** dimension — `handled_permissions` ruleset field, `LANDLOCK_PERMISSION_NAMESPACE_USE` / `LANDLOCK_PERMISSION_CAPABILITY_USE` flags, and two **new rule types**: `LANDLOCK_RULE_NAMESPACE` (restrict `CLONE_NEW*` use across unshare/clone/setns/open_tree/fsmount) and `LANDLOCK_RULE_CAPABILITY` (restrict `CAP_*` exercise). This is a genuinely new dimension, not an extension of FS/net/scopes — it must join `HANDLED_DEFAULT` deliberately.
- **Errata mechanism** (kernel-side, ABI-independent): `LANDLOCK_CREATE_RULESET_ERRATA` returns a bitmask of fixed kernel bugs (erratum 1 = TCP socket identification). Kernel docs explicitly advise most applications NOT to consult it; the library should at most expose it as an opt-in probe.

On the toolchain side: `core:sys/linux` (verified in the installed dev-2026-10 nightly and unchanged in dev-2026-11) exposes **only** the `SYS_landlock_*` syscall-number constants — no attr structs, no flags, no wrappers (`// TODO(flysand): landlock_create_ruleset|add_rule|restrict_self` still sit in `core/sys/linux/sys.odin:3408–3412`; `openat2` likewise, `sys.odin:3371`). **The hand-rolled `syscall/` package therefore remains the single source of ABI truth after the bump — nothing migrates to core, and the hand-rolled `Open_How`/openat2 wrapper must stay.** The dev-2026-05 → dev-2026-11 bump is low-risk: the two breaking changes (core:fmt padding, core:compress overhaul) touch neither path; the repo uses core:fmt but not compress.

---

## Recommended Stack

### Core Technologies

| Technology | Version | Purpose | Why Recommended | Confidence |
|---|---|---|---|---|
| Odin compiler | **dev-2026-11 nightly** (tag `dev-2026-11`, commit `e28f5d1`, released 2026-11-03, GPG-signed) | Compiler for all feature work | Latest tagged nightly at milestone start; bump isolates toolchain churn from feature churn per PROJECT.md. Workstation currently has `dev-2026-10-nightly:84bc3fc` installed — close enough to verify core surface today, but pin dev-2026-11 in CI. | HIGH |
| Kernel ABI target | **ABI v12** (uapi head, torvalds master) | Raw surface to bind | Everything below v12 is the milestone scope; v1–v9 already done. | HIGH |
| Kernel floor (runtime) | **5.13** (unchanged) | Compatibility floor | Standing user decision; all new bits degrade best-effort below their intro kernel. | HIGH |
| Kernel for conformance CI | **7.2.x stable** (host runs 7.2.11-300.fc45) + **linux-next / mainline build** until 7.3.0 releases | Real-kernel ABI 10 tests now; ABI 11/12 tests as soon as 7.3-rc1 exists | ABI v10 is testable today on stable 7.2; v11/v12 need a mainline/linux-next kernel built via virtme-ng until 7.3 ships (expected ≈ Dec 2026/Jan 2027 at normal cadence). | MEDIUM (7.3 release date inferred from cadence) |
| virtme-ng | **1.42** (PyPI, ~Oct 2026; Fedora 45 ships 1.41-5) | Boot per-kernel kernels in VM for conformance probe | Current release line; existing CI already uses virtme-ng, just bump the pin. `vng --build` handles mainline source builds for the 7.3-rc phase. | HIGH (version), MEDIUM (mainline-build workflow) |
| Kernel headers | **none needed** — no `linux/landlock.h` dependency | Binding constants | Odin has no C include path; every constant is hand-transcribed into `syscall/` from the uapi header. "Kernel headers" reduces to: transcribe from `include/uapi/linux/landlock.h` @ torvalds master and pin the commit in a comment. | HIGH |
| Compiler flags/defines | unchanged (`-define:LANDLOCK_INTEGRATION=true`, `-vet`, strict) | Build/test | Nothing in dev-2026-11 changes Landlock-relevant flags. New opt-in `-no-atomic-analysis` / `-vet-atomic-access` exist but this library does no atomics. | HIGH |

### Supporting Libraries

| Library | Version | Purpose | When to Use |
|---|---|---|---|
| `core:sys/linux` | dev-2026-11 | `SYS_landlock_*` (444–446) + `SYS_openat2` (437) syscall-number constants, `linux.syscall` trampoline | Already used via `syscall/`; continue using **only** the syscall numbers and `linux.syscall` — nothing else exists for Landlock/openat2. |
| `syscall/` (in-repo) | local | All Landlock flags, attr structs, wrappers, ABI gating inputs | Always — it is the only complete surface. New ABI 10–12 constants land here first. |
| `core:fmt`, `core:os`, `core:mem` | dev-2026-11 | Existing repo usage | Unchanged. |

### Development Tools

| Tool | Purpose | Notes |
|---|---|---|
| virtme-ng 1.42 (`vng`) | Kernel-matrix VM conformance | Pin via pip (`pip install virtme-ng==1.42`) or Fedora package ≥1.41; add a `linux-next`/`master` kernel target alongside the existing per-release matrix for ABI 11/12 testing. |
| QEMU (vng backend) | VM execution | No version-specific need; vng manages it. |
| kernel source | Transcription reference + CI kernels | Pin `torvalds/linux` master commit for constant transcription; document the commit hash in `syscall.odin` next to the new constants (repo already does per-bit commit links — extend this pattern to ABI 10–12 commits). |

---

## New Kernel Surface to Bind (the raw deliverable)

Everything below is verified from `torvalds/linux` `include/uapi/linux/landlock.h` @ master (2026-11-09) and `docs.kernel.org` latest Landlock doc:

### ABI v10 (kernel 7.2) — net + audit-quiet
| Item | Value | Notes |
|---|---|---|
| `LANDLOCK_ACCESS_NET_BIND_UDP` | `1ULL << 2` | UDP bind; port 0 = ephemeral-range semantics (documented) |
| `LANDLOCK_ACCESS_NET_CONNECT_SEND_UDP` | `1ULL << 3` | connect/send-to; AF_UNSPEC-send not supported on IPv6 UDP |
| `landlock_ruleset_attr` grows | +3 `__u64`: `quiet_access_fs`, `quiet_access_net`, `quiet_scoped` | struct 24 → 48 bytes; must be a subset of the handled/scoped masks |
| `LANDLOCK_ADD_RULE_QUIET` (add_rule flag) | `1U << 0` | per-object quiet bit; empty `allowed_access` allowed with it |

### ABI v11 (mainline, next release)
| Item | Value | Notes |
|---|---|---|
| `LANDLOCK_RESTRICT_SELF_NO_NEW_PRIVS` | `1U << 4` | sets no_new_privs iff restrict succeeds; requires ruleset_fd; composes with `TSYNC` |

### ABI v12 (mainline, next release) — new permission dimension
| Item | Value | Notes |
|---|---|---|
| `handled_permissions` ruleset field | +1 `__u64` (struct → 56 bytes) | |
| `LANDLOCK_PERMISSION_NAMESPACE_USE` | `1ULL << 0` | gates unshare/clone/clone3/setns/open_tree/fsmount |
| `LANDLOCK_PERMISSION_CAPABILITY_USE` | `1ULL << 1` | gates CAP_* exercise; purely restrictive |
| `LANDLOCK_RULE_NAMESPACE` | rule type 3 | new `landlock_namespace_attr { permissions, allowed_namespace_types, quiet_namespace_types }` — `CLONE_NEW*` bitmask; unknown bits silently ignored; ENOMSG if both allowed+quiet are zero |
| `LANDLOCK_RULE_CAPABILITY` | rule type 4 | new `landlock_capability_attr { permissions, allowed_capabilities, quiet_capabilities }` — `1ULL << CAP_*`; bits above `CAP_LAST_CAP` silently ignored; ENOMSG if both zero |

### Errata (ABI-independent)
| Item | Value | Notes |
|---|---|---|
| `LANDLOCK_CREATE_RULESET_ERRATA` | `1U << 1` | create_ruleset returns errata bitmask (bit N = erratum N+1 fixed); erratum 1 = TCP socket identification. Kernel docs: "Most applications should NOT check errata" — expose as opt-in probe only, or skip entirely. |

**No new syscalls.** Landlock stays at syscall numbers 444–446; all growth is via flags/struct/rule-type extension. `core:sys/linux` numbers are already sufficient.

### Binding-design constraint that changes with ABI ≥ 10
`landlock_ruleset_attr` now grows twice (v10, v12). The binding must pass an **ABI-clipped attr size and bit set** (exactly the grow-logic ladder in the kernel doc: strip bits for ABI < N, pass `size` covering only fields the running kernel knows). The existing `#assert(ABI_FS_V9 == ABI_FS_ALL)` tripwire pattern extends naturally: extend the cumulative chain to v12 and assert on `sizeof(Ruleset_Attr)` growth. [INFERENCE on exact best encoding — kernel behavior for oversize attrs must be verified in `security/landlock/syscalls.c` during implementation.]

---

## Odin Nightly Bump Assessment (dev-2026-05 → dev-2026-11)

| Concern | Finding | Risk |
|---|---|---|
| core:sys/linux Landlock gains? | None. Syscall-number constants only (verified in dev-2026-10 install; dev-2026-11 changelog lists no sys/linux Landlock work; `TODO(flysand)` stubs remain). | None — and no payoff: `syscall/` stays authoritative. |
| Hand-rolled openat2 wrapper | Still required. Core has `SYS_openat2` constant but `// TODO(flysand): openat2` (sys.odin:3371); no `Open_How`. | None. Keep. |
| Breaking changes in dev-2026-11 | Two, neither load-bearing: `core:fmt` pads widths with spaces unless `0` flag (#7724); `core:compress` overhaul (#8153). Repo imports `core:fmt` (tests/tools) but **not** `core:compress`. | LOW: scan test/tools for width-padded format strings (`%0*x`-style expectations); otherwise re-run suite. |
| Language changes | New atomic-analysis (opt-out flag), escape analysis, `@(align=N)`, `#config` enums. Library does no atomics; escape-analysis tightening may surface new warnings. | LOW: expect possible new vet warnings; fix or disable per-flag once. |
| Android subtarget (#8006) | Irrelevant (Linux-only enforcement, stubs elsewhere). | None. |

**Recommendation:** bump to dev-2026-11 at milestone start, re-run full suite, then freeze the pin for the milestone. Do **not** wait for core:sys/linux to grow Landlock wrappers — the TODOs have been sitting upstream with no movement; the repo's hand-rolled layer is the deliberate, correct design. (Confidence: HIGH)

---

## What NOT to Use

| Avoid | Why | Use Instead |
|---|---|---|
| `core:sys/linux` for any Landlock flag/attr/wrapper | It does not exist — only syscall numbers. Waiting on it blocks the milestone indefinitely. | Hand-rolled `syscall/` package (existing precedent, existing import rule). |
| Raising kernel floor to 7.2 for ABI 10 | Standing user decision; breaks the best-effort contract. | Runtime ABI probe + per-version gating tables (existing pattern). |
| Checking errata by default in `Apply` | Kernel docs: most apps should not; risks turning "less protection" into "no protection". | At most an opt-in `Errata()` probe in `syscall/`; policy layer ignores it. |
| Vendoring liblandlock / C headers via c-bindings | Odin-native repo, no C toolchain in layering. | Continue `linux.syscall` trampoline + hand-transcribed constants. |
| Relying on distro kernel packages for ABI 11/12 CI | 7.3 not released; distro kernels lag. | virtme-ng + linux-next/mainline-built kernel until 7.3.0, then switch matrix to stable 7.3. |

---

## Version Compatibility

| Component | Compatible With | Notes |
|---|---|---|
| Odin dev-2026-11 | kernel 5.13–7.2+, all tested ABIs | Compiler change is kernel-agnostic. |
| ABI 10 features | kernel ≥ 7.2 | Testable today (host + CI stable matrix). |
| ABI 11/12 features | mainline only until 7.3.0 | CI needs linux-next kernel build; release expected ≈ Dec 2026–Jan 2027 [INFERENCE from cadence]. |
| virtme-ng 1.42 | mainline kernel sources via `vng --build` | Existing 1.40/1.41 pins work too; bump is cheap. |
| Hand-rolled `Open_How` (openat2) | all kernels ≥ 5.6 | Unaffected by bump; core still lacks wrapper. |
| `core:fmt` users in tests/tools | dev-2026-11 | Audit for `0`-padding format expectations (#7724). |

---

## Sources

- torvalds/linux `include/uapi/linux/landlock.h` @ master, fetched 2026-11-09 — all ABI 10–12 constants, structs, rule types, errata flag (HIGH)
- kernel.org `Documentation/userspace-api/landlock.html` (latest, fetched 2026-11-09) — ABI ladder, quiet/no_new_privs/permission sections, errata guidance (HIGH)
- docs.kernel.org/7.2 landlock doc — ABI 10 present in released 7.2 (HIGH); host `uname` 7.2.11-300.fc45 corroborates
- man7.org landlock(7), man-pages 6.19 (2026-07-18) — ABI v1–v9 table, confirms v9/7.1 baseline this repo already covers (HIGH)
- LWN 1087082 + kernsec patches Jul–Aug 2026 (`LANDLOCK_RESTRICT_SELF_NO_NEW_PRIVS` v2/v3 series by Justin Suess) — v11 provenance (HIGH)
- kernsec UDP series May–Jun 2026 (Buffet/Salaün, v4/v5) — v10 UDP provenance (HIGH)
- github.com/odin-lang/Odin release `dev-2026-11` (2026-11-03, commit e28f5d1, signed) — changelog, breaking changes (HIGH)
- Local install `/var/home/litew/.local/bin/core/sys/linux/` (dev-2026-10-nightly:84bc3fc): `sys.odin:3408–3412` Landlock TODO stubs, `sys.odin:3371` openat2 TODO, syscall-number tables (HIGH, direct inspection)
- PyPI virtme-ng 1.42 (~Oct 2026); Fedora 45 virtme-ng 1.41-5 (2026-07) (MEDIUM-HIGH)

---
*Stack research for: odin-landlock ABI-head parity*
*Researched: 2026-11-09*
