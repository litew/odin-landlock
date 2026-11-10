---
last_mapped_commit: ac37c876561f405d750f813af98acfd43d7ebfd9
last_mapped_at: 2026-11-09
---
# External Integrations

**Analysis Date:** 2026-11-09

## APIs & External Services

**Network/HTTP services:**
- None. The library is a self-contained kernel-syscall wrapper; it makes no network calls, has no SDK clients, and no auth providers.

## Kernel Interfaces (the real "integration" surface)

**Linux Landlock LSM** — driven through direct syscalls in `syscall/syscall_linux.odin`:
- `landlock_create_ruleset` — creates a ruleset fd (`create_ruleset`, arg: `Ruleset_Attr`, 24 bytes).
- `landlock_add_rule` — adds `Path_Beneath_Attr` (12 bytes, packed) and `Net_Port_Attr` (16 bytes) rules (`add_path_beneath_rule`, `add_net_port_rule`).
- `landlock_restrict_self` — applies the ruleset to the calling thread, with optional flags (`restrict_self`, `syscall.Restrict_Self_Flags`).
- `prctl(PR_SET_NO_NEW_PRIVS)` — prerequisite for non-privileged enforcement (`prctl`, constant `PR_SET_NO_NEW_PRIVS = 38` in `syscall/syscall.odin`).
- `openat2(RESOLVE_NO_SYMLINKS)` — hand-rolled wrapper (`Open_How` struct, `open_path`) because `core:sys/linux` has no openat2 binding yet; used for symlink-rejecting path opens (TOCTOU protection). Kernel ≥ 5.6, always available when Landlock is.
- ABI probe via `landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION)` (`get_abi_version`).
- Enforcement is **irreversible and cumulative** — every consumer of this package must fail closed on `!is_enforced(result)`.

**Abstracted for testing:** the apply path goes through an `Apply_Ops` function-pointer seam (`default_apply_ops`/`active_apply_ops` in `landlock.odin`), letting unit tests fake syscalls without touching the kernel. Only the integration test and the conformance tool use the real syscalls.

**File descriptors / filesystem:**
- `O_PATH` handles obtained via `openat2` are the currency for path rules (`apply_open_path`, `apply_add_path_rule`); raw fd close via `close_fd` because portable `core:os` has no raw-fd close.

## Data Storage

**Databases:**
- None.

**File Storage:**
- Local filesystem only, and only as *rule targets* (paths copied into the `Policy` builder). No files are read or written by the library itself.
- Test artifacts: `/tmp` probe files in `landlock_integration_test.odin` and `tools/abi-conformance/main.odin`, cleaned up by the parent process.

**Caching:**
- None.

## Authentication & Identity

**Auth Provider:**
- Not applicable. The only privilege-related operation is `prctl(PR_SET_NO_NEW_PRIVS)` before `landlock_restrict_self`; failure surfaces as `Policy_Error_Kind.No_New_Privs_Failed`.

## Monitoring & Observability

- Landlock audit-logging flags (ABI v7, kernel ≥ 6.15): `.Log_New_Exec_On`, `.Log_Same_Exec_Off`, `.Log_Subdomains_Off` requested via `landlock.handle_flags`; logs are emitted by the kernel itself, not by this package.
- `landlock.summary(result)` / `landlock.debug_summary(result)` return caller-owned human-readable status lines (`landlock.odin`); `Policy_Result` carries `abi_used`, `features_applied`/`features_omitted`, `flags_applied`/`flags_omitted`, `raw_errno`.
- Kernel-LSM presence check is manual/CI-side: `grep -q landlock /sys/kernel/security/lsm` (see `ci.yml` integration-test step).

## CI / Tooling Integrations

**GitHub Actions (`.github/workflows/ci.yml`):**
- `laytan/setup-odin@v2` installs the latest monthly Odin release.
- Steps: `odin check` (host + `darwin_amd64`/`freebsd_amd64` cross-targets), unit tests for root and `syscall/` packages, builds `examples/`, and compiles the README's first code block extracted with `awk` as a doc-accuracy gate.

**Kernel matrix (`.github/workflows/kernel-matrix.yml`):**
- Weekly conformance across real kernels: Ubuntu mainline kernel debs (5.10 "no-landlock" through 6.15 v7) fetched from `kernel.ubuntu.com/mainline`, booted with `virtme-ng` + QEMU with `lsm=landlock,capability,yama,apparmor,bpf` on the kernel command line.
- Runs the prebuilt standalone binary `tools/abi-conformance/main.odin` (`package abi_conformance`) inside each VM; the binary uses `fork()` per enforcement check (Landlock is irreversible) and exits with typed codes (0 ok, 1 enforcement misbehaved, 2 ABI mismatch, 3 setup error). `LANDLOCK_EXPECT_ABI` pins the expected version per job.

**Process-level integration contract for consumers:**
- Apply in a forked child or before spawning threads; otherwise sibling threads stay unsandboxed unless `.Tsync` (ABI v8) is requested — see the WARNING in `README.adoc` and the notes atop `landlock_integration_test.odin`.

---

*Integration audit: 2026-11-09*
