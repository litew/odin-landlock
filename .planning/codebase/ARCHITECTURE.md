---
last_mapped_commit: ac37c876561f405d750f813af98acfd43d7ebfd9
last_mapped_at: 2026-11-09
---
<!-- refreshed: 2026-11-09 -->
# Architecture

**Analysis Date:** 2026-11-09

## System Overview

```text
┌──────────────────────────────────────────────────────────────────┐
│                        Consumers / Tools                         │
│  `examples/main.odin`   `examples/rules-demo/demo.odin`          │
│  `tools/abi-conformance/main.odin` (CI kernel probe)             │
└────────┬─────────────────────┬─────────────────────┬─────────────┘
         │ import landlock "../.."   import syscall "../../syscall"
         ▼                     ▼                     ▼
┌──────────────────────────────────────────────────────────────────┐
│                 landlock (policy layer) — root pkg                │
│  Builder API · ABI gating · apply orchestration · typed results   │
│  `landlock.odin` (+ tests at root)                                │
└────────┬─────────────────────────────────────────────────────────┘
         │ imports "syscall" (local package)
         ▼
┌──────────────────────────────────────────────────────────────────┐
│                  syscall (raw Landlock interface)                 │
│  `syscall/syscall.odin`          — constants, attr structs        │
│  `syscall/syscall_linux.odin`    — real syscalls (#build linux)   │
│  `syscall/syscall_unsupported.odin` — non-Linux stubs             │
└────────┬─────────────────────────────────────────────────────────┘
         │ imports "core:sys/linux"
         ▼
┌──────────────────────────────────────────────────────────────────┐
│  Linux kernel — landlock_create_ruleset / add_rule /              │
│  restrict_self / prctl(NO_NEW_PRIVS) / openat2                    │
└──────────────────────────────────────────────────────────────────┘
```

## Component Responsibilities

| Component | Responsibility | File |
|-----------|----------------|------|
| `landlock` (root) | Policy builder (allow/scope/handle procs), ABI gating (v1–v9), apply orchestration (strict/best-effort), typed `Policy_Result`/`Policy_Error`, summary rendering | `landlock.odin` |
| `syscall` | Raw Landlock ABI surface: constants, bit sets (`Access_FS_Flags`, `Access_Net_Flags`, `Scope_Flags`, `Restrict_Self_Flags`), packed attr structs, syscall wrappers | `syscall/syscall.odin` |
| `syscall` (Linux) | Real syscall implementations: `create_ruleset`, `add_path_beneath_rule`, `add_net_port_rule`, `restrict_self`, `prctl`, `open_path` (openat2 + O_PATH), `close_fd` | `syscall/syscall_linux.odin` |
| `syscall` (stubs) | Non-Linux platform: every proc returns an "unsupported" `os.Error` | `syscall/syscall_unsupported.odin` |
| `examples` | Runnable usage demo: build policy, allow `/usr` RO, apply, fail closed | `examples/main.odin` |
| `examples/rules-demo` | Secondary demo of rule construction options (symlink/missing-path behaviors) | `examples/rules-demo/demo.odin` |
| `abi-conformance` | Standalone real-kernel conformance probe run inside per-kernel VMs (virtme-ng) by CI; exits 0 only if every applicable enforcement check passes | `tools/abi-conformance/main.odin` |
| unit tests | Drive the apply path through the `Apply_Ops` fake seam; no real syscalls | `landlock_test_linux.odin`, `landlock_test_unsupported.odin` |
| integration test | Real-kernel enforcement test, opt-in via `-define:LANDLOCK_INTEGRATION=true`, forked child per policy | `landlock_integration_test.odin` |

## Pattern Overview

**Overall:** Layered library with a builder + facade over raw syscalls, plus a swappable-ops seam for testability.

**Key Characteristics:**
- **Two-package layering (Odin conventions):** `landlock` (policy/intent) never touches raw syscalls directly; all kernel interaction funnels through the local `syscall` package, which in turn uses `core:sys/linux`. Import paths follow `core:` / local-relative (`import landlock ".."` in examples).
- **Deny-by-default handled set (go-landlock model):** `init` defaults the handled set to all three access dimensions (`.Filesystem`, `.Network`, `.Scope`); allow rules are exceptions. See `HANDLED_DEFAULT` in `landlock.odin`.
- **Seam for testing via `Apply_Ops`:** all apply-path kernel calls go through a proc-struct (`apply_ops`, thread-local, `default_apply_ops`/`active_apply_ops` in `landlock.odin`). Tests substitute `fake_apply_ops` (`landlock_test_linux.odin`) — no kernel needed for the bulk of the suite.
- **Platform split by build tag:** shared constants in `syscall/syscall.odin`; `#+build !linux` stubs in `syscall/syscall_unsupported.odin`; Linux impls in `syscall/syscall_linux.odin`.
- **Typed results, no exceptions/panics:** every apply returns a `Policy_Result` with coarse `Policy_Status` + structured `Policy_Error{kind, cause, raw_errno, validation}`; builder procs return `Policy_Error`.

## Layers

**Consumer layer (examples/tools):**
- Purpose: demonstrate usage; CI kernel conformance probe.
- Location: `examples/`, `tools/abi-conformance/`
- Depends on: `landlock` root package (relative import `".."` / `"../.."`), `syscall`
- Used by: users; `.github/workflows/kernel-matrix.yml`

**Policy layer (`landlock`):**
- Purpose: translate policy intent (RO dirs, TCP connect, scopes, flags) into an ABI-gated rule list and orchestrate apply.
- Location: `landlock.odin`
- Contains: `Policy`, `Policy_Result`/`Policy_Error` types, ABI tables (`ABI_FS_V1`..`ABI_FS_V9`, `abi_versions`), builder procs (`init`, `handle_features`, `handle_flags`, `allow_*`, `scope_*`), apply (`apply_strict`/`apply_best_effort` → `apply_with_mode`), summaries.
- Depends on: `syscall` package, `core:sys/linux`, `core:os`, `core:mem`, `core:strings`, `base:intrinsics`
- Used by: examples, tools, tests

**Syscall layer (`syscall`):**
- Purpose: exact kernel ABI surface — constants with `#assert` size/layout checks (e.g. `size_of(Path_Beneath_Attr) == 12`), thin wrappers returning `os.Error`.
- Location: `syscall/`
- Depends on: `core:sys/linux`, `core:sys/unix`, `core:os`
- Used by: `landlock` package and `tools/abi-conformance/main.odin`

**Kernel:**
- Landlock syscalls (ABI v1–v9, kernel 5.13 → 7.1), `prctl(PR_SET_NO_NEW_PRIVS)`, `openat2(RESOLVE_NO_SYMLINKS)`.

## Data Flow

### Primary apply path (apply_strict / apply_best_effort)

1. Caller builds policy: `init` → `handle_features`/`handle_flags` → `allow_path`/`allow_ro_dirs`/`allow_rw_files`/`allow_tcp_bind`/`scope_signal`/… (`landlock.odin`). Path strings are copied with the policy's allocator; rules validated eagerly (`path_access_validate`, existence/`stat` checks in `path_validation_stat`, symlink policy recorded).
2. `apply_strict`/`apply_best_effort` → `apply_with_mode` (`landlock.odin`).
3. Probe running kernel ABI: `apply_ops.probe_abi` → `syscall.get_abi_version`; clamp to known v1–v9 (`abi_versions`).
4. Compute supported set: `requested_feature_support` intersects requested features with the ABI table; unsupported features → error (strict: `.Unsupported_Feature`) or recorded omission (best-effort: `Partially_Enforced`).
5. `apply_ops.create_ruleset` (`syscall.create_ruleset` with `Ruleset_Attr`) → ruleset fd.
6. For each FS rule: `apply_ops.open_path` (openat2, O_PATH, optional `RESOLVE_NO_SYMLINKS`) → `apply_ops.add_path_rule` (`landlock_add_rule` with `Path_Beneath_Attr`). For each TCP rule: `apply_ops.add_net_rule` with `Net_Port_Attr`. All fds closed after (`close_opened_path_fds`, `close_ruleset_fd`).
7. `apply_ops.prctl(PR_SET_NO_NEW_PRIVS)` then `apply_ops.restrict_self(ruleset_fd, flags)` (`syscall/syscall_linux.odin`).
8. Return `Policy_Result{status, abi_requested, abi_used, features_applied/omitted, flags_applied/omitted, error}`; caller checks `is_enforced(result)` and fails closed (`examples/main.odin`).

### Builder-time validation flow

1. `allow_path` validates mask (`path_access_is_valid` rejects unknown bits vs `ABI_FS_ALL`), enforces `.Write_File` ⇒ `.Truncate`, path length/NUL checks, `stat` kind match (`Wrong_Path_Type`), symlink resolution policy.
2. Missing-path behavior: `.Ignore` records `Policy_Path_Omission` (surfaced in best-effort results).
3. Contradiction check at apply: rule for a dimension absent from the handled set → `Invalid_Policy` / `Rule_For_Unhandled_Feature`.

### Test flow (no kernel)

1. `use_fake_apply_ops()` swaps the thread-local `apply_ops` (`landlock_test_linux.odin`).
2. Fakes record `Fake_Call`s into `Fake_Apply_State`; tests assert call order (`expect_fake_order`) and typed results for every errno path.

### Real-kernel flows

- Integration test: parent creates /tmp probe file → `fork()` → child applies FS-only policy → child read of probe must fail → `waitpid` exit-code protocol (`CHILD_*` codes) (`landlock_integration_test.odin`).
- Conformance probe: `main` in `tools/abi-conformance/main.odin` probes ABI, runs one `fork_check` per enforcement check (irreversible + cumulative ⇒ no shared sandboxed process), exit codes `EXIT_OK/FAIL/ABI_MISMATCH/SETUP`; honors `LANDLOCK_EXPECT_ABI`.

**State Management:**
- All policy state lives in the caller-owned `Policy` struct (heap rules/strings owned by it, freed by `cleanup`).
- Apply-path transient buffers are freed inside the procs that create them; library leaves nothing behind beyond `cleanup`.
- Summaries (`summary`, `debug_summary`) return caller-owned strings — free with `delete(s, allocator)`.
- Only module-level mutable state: thread-local `apply_ops` (`landlock.odin`) and the test's thread-local `fake_state`; the conformance tool's `g_abi`/`g_fs_probe` set once before forking.

## Key Abstractions

**`Policy` (builder):**
- Purpose: accumulates validated rules + handled set + flags; owns its memory via the allocator given to `init`.
- Example: `landlock.odin`, constructed only through `init` + builder procs; `is_ready` guards use.

**`Apply_Ops` (kernel seam):**
- Purpose: proc-struct of every kernel call used during apply; default binds real `syscall` wrappers, tests bind fakes.
- Example: `landlock.odin` (`default_apply_ops`, `active_apply_ops`, `@(private, thread_local) apply_ops`), fakes in `landlock_test_linux.odin`.
- Pattern: dependency injection via Odin proc-struct + `thread_local` storage.

**`ABI_Version` / cumulative ABI chain:**
- Purpose: per-version feature tables (`ABI_FS_V1`..`ABI_FS_V9`, `ABI_NET_V4`, `ABI_SCOPE_V6`, `ABI_RESTRICT_V7/V8`) gating which bits are requested per kernel.
- Pattern: cumulative bit_set chain with compile-time drift tripwire `#assert(ABI_FS_V9 == ABI_FS_ALL)` so a new `Access_FS_Flag` must be threaded into the chain or compilation fails.

**Typed error taxonomy:**
- `Policy_Status` (coarse outcome: `Enforced`/`Partially_Enforced`/`Not_Enforced`) + `Policy_Error{kind, cause, raw_errno, validation}` — reason lives in `error.kind`, never conflated with status.
- Examples: `Policy_Error_Kind`, `Policy_Error_Cause`, `Policy_Validation_Failure` in `landlock.odin`; helper constructors `policy_error_errno`, `policy_result_error`, `apply_result_for_errno`.

**`Path_Access` / `Path_Options`:**
- Purpose: caller-facing FS-right mask (`distinct` re-typing of `syscall.Access_FS_Flag` with `transmute` at the boundary: `path_access_to_syscall`) and symlink/missing-path behavior knobs.
- Examples: `landlock.odin`; convenience masks `path_access_ro_dir`, `path_access_rw_file`.

## Entry Points

**Library consumers** (no main at root — this is a package, not an app):
- `landlock.init(&policy)` begins every usage flow; `landlock.apply_strict`/`apply_best_effort` completes it (see README.adoc minimal example).

**Example binary:**
- `examples/main.odin` — `odin run examples`; builds RO-dir + TCP policy, applies, prints `Policy_Result` status.

**Rules demo:**
- `examples/rules-demo/demo.odin` — rule-construction options demo.

**Conformance binary:**
- `tools/abi-conformance/main.odin` — `package abi_conformance`, built on host, executed inside per-kernel VMs by `.github/workflows/kernel-matrix.yml`.

**Tests:**
- `odin test .` runs root suite (`landlock_test_linux.odin` on Linux; `landlock_test_unsupported.odin` elsewhere; `syscall/syscall_test_linux.odin` for the syscall package).
- Integration: `odin test . -define:LANDLOCK_INTEGRATION=true -define:ODIN_TEST_THREADS=1`.

## Architectural Constraints

- **Threading:** `landlock_restrict_self` restricts only the calling thread; sibling threads stay unsandboxed unless `.Tsync` (ABI v8+) is requested via `handle_flags`. `apply_ops` is `thread_local`. Tests using `fork()` must run single-threaded (`ODIN_TEST_THREADS=1`) because fork in a multithreaded process can deadlock on allocator locks.
- **Irreversibility:** Landlock enforcement is cumulative and irreversible; `cleanup` only frees builder memory. The conformance tool forks one child per check for this reason.
- **Fail-closed contract:** apply never aborts the process — callers must check `is_enforced(result)`. Best-effort never silently full-enforces; gaps are reported via `Partially_Enforced` + omission fields.
- **Platform:** Linux-only enforcement; non-Linux builds compile via stubs and report `Unsupported_Platform`. Depends on `core:sys/linux` including a hand-rolled `openat2` wrapper (`syscall/syscall_linux.odin`) — pin Odin version (tested with dev-2026-05 nightly).
- **ABI drift protection:** `#assert(ABI_FS_V9 == ABI_FS_ALL)` plus `#assert` size checks on every kernel attr struct (`Ruleset_Attr` 24 bytes, `Path_Beneath_Attr` 12, `Net_Port_Attr` 16) in `syscall/syscall.odin`.
- **No circular imports:** strict one-way layering examples → landlock → syscall → core:sys/linux. (`examples` also imports `syscall` directly for low-level checks.)

## Anti-Patterns

### Ignoring the Policy_Result

**What happens:** calling `apply_best_effort` and continuing on a `Not_Enforced` result leaves the process unsandboxed while the code assumes protection.
**Why it's wrong:** apply deliberately never aborts; silent failure defeats the sandbox.
**Do this instead:** fail closed — `if !landlock.is_enforced(result) do os.exit(1)` (documented in `landlock.odin` `is_enforced` and README.adoc).

### Adding a right without threading the ABI chain

**What happens:** adding an `Access_FS_Flag` member without extending `ABI_FS_V*`.
**Why it's wrong:** the right would never be requested on any kernel despite existing.
**Do this instead:** extend the cumulative chain in `landlock.odin`; the `#assert(ABI_FS_V9 == ABI_FS_ALL)` tripwire enforces this at compile time.

### Granting `.Write_File` without `.Truncate` in custom rules

**What happens:** `allow_path` mask with `.Write_File` only.
**Why it's wrong:** rejected with `Invalid_Policy`/`Write_File_Without_Truncate` — a runtime surprise when the helpers (`allow_rw_dirs`, `allow_rw_files`) would have included it.
**Do this instead:** include `.Truncate` explicitly or use the rw helpers (`landlock.odin`).

## Error Handling

**Strategy:** typed result unions everywhere; no exceptions, no silent swallowing, no process abort inside the library.

**Patterns:**
- Builder procs return `Policy_Error` (`err.kind != .None` checks in `examples/main.odin`).
- Apply returns a fully populated `Policy_Result`; errno preserved verbatim in `raw_errno` (`raw_errno_from_os_error`), cause classified per site (`apply_result_for_errno`: ENOSYS→`Unavailable`, EOPNOTSUPP→`Disabled`, EPERM→`Permission_Denied`…).
- Allocation failures get their own kind (`policy_error_allocation`), tested with `failing_allocator` in `landlock_test_linux.odin`.
- Debug summary refuses to truncate: over-cap render is treated as failure, not a clipped security report (`debug_summary_with_cap`, `DEBUG_SUMMARY_CAP`).

## Cross-Cutting Concerns

**Logging:** none inside the library — Landlock audit-logging flags (`Restrict_Self_Flags.Log_*`, ABI v7+) are policy knobs, not library logging; `debug_summary` is the diagnostic surface.
**Validation:** eager at builder time (mask validity, kind/stat match, symlink policy, NUL/length) and again at apply (handled-set contradictions); all typed via `Policy_Validation_Failure`.
**Authentication/Authorization:** not applicable — the library *is* the authorization mechanism (kernel-enforced, deny-by-default).

---

*Architecture analysis: 2026-11-09*
