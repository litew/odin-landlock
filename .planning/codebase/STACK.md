---
last_mapped_commit: ac37c876561f405d750f813af98acfd43d7ebfd9
last_mapped_at: 2026-11-09
---
# Technology Stack

**Analysis Date:** 2026-11-09

## Languages

**Primary:**
- Odin (`dev-2026-05` nightly) — the entire codebase. Tested against this specific nightly per `README.adoc`; pin the Odin version when vendoring because the package depends on `core:sys/linux` internals (including a hand-rolled `openat2` wrapper, see `syscall/syscall_linux.odin`).

**Secondary:**
- None. No C, no shell scripts; CI uses inline YAML shell only.

## Runtime

**Environment:**
- Compiled native binary via the Odin compiler (`odin build` / `odin check` / `odin test`). LLVM-backed toolchain; no managed runtime.
- Target kernel: Linux ≥ 5.13 (Landlock ABI v1). Package gracefully degrades to a typed `Unsupported_Platform` result on older kernels and non-Linux OSes via `#+build !linux` stubs (`syscall/syscall_unsupported.odin`, `landlock_test_unsupported.odin`).
- CI cross-compile-checks POSIX targets: `darwin_amd64`, `freebsd_amd64` (`.github/workflows/ci.yml`).

**Package Manager:**
- None. Odin has no package manager; the package is vendored by copying source files (see layout in `README.adoc`).

## Frameworks

**Core:**
- No frameworks. A plain Odin library package (`package landlock`) plus a low-level syscall package (`package syscall` in `syscall/`).

**Testing:**
- `core:testing` — Odin's built-in test framework; `@(test)` procedures. No third-party test framework.

**Build/Dev:**
- Odin compiler CLI: `odin check . -no-entry-point` (compile check), `odin test .`, `odin build examples`.
- GitHub Actions CI (`.github/workflows/ci.yml` — push/PR; `.github/workflows/kernel-matrix.yml` — weekly ABI conformance under real kernels via `virtme-ng` + QEMU).
- `laytan/setup-odin@v2` GitHub action installs the toolchain in CI.

## Key Dependencies

**Critical (all from Odin's standard distribution, no third-party vendor packages):**
- `core:sys/linux` — raw Landlock syscall wrappers, `prctl`, and the openat2 path used for TOCTOU-safe `O_PATH` opens (`syscall/syscall_linux.odin`). The load-bearing dependency; upstream additions (e.g. `O_PATH` in `core:os`) may obsolete the local wrappers.
- `core:sys/posix` — `fork`, `waitpid`, `getpid`, `bind` in tests and the conformance tool (`landlock_integration_test.odin`, `tools/abi-conformance/main.odin`).
- `core:os` — portable file I/O, `os.Error`, `os.File_Type` used for path-kind validation (`landlock.odin`).
- `core:sys/unix` — imported alongside `core:sys/linux` in the Linux syscall layer (`syscall/syscall_linux.odin`).
- `core:fmt`, `core:strings`, `core:mem`, `core:reflect`, `core:intrinsics` (`base:intrinsics`) — formatting, string building, allocator errors, enum name reflection (`enum_to_string`), size/enum intrinsics (`landlock.odin`).
- `base:intrinsics` — the only `base:` import; compile-time type introspection.

**Infrastructure:**
- Linux kernel Landlock LSM — the actual "runtime service" the package drives (`landlock_create_ruleset`, `landlock_add_rule`, `landlock_restrict_self` syscalls + `prctl(PR_SET_NO_NEW_PRIVS)`). Kernel ABI versions v1–v9 mapped in `landlock.odin` (`ABI_FS_V1` … `ABI_FS_V9`) and tabulated in `README.adoc`.

## Configuration

**Environment:**
- No `.env` files, no env vars required by the library itself.
- Compile-time configs (`#config`):
  - `LANDLOCK_INTEGRATION` (default `false`) — enables the real-kernel integration test (`landlock_integration_test.odin`); run with `-define:LANDLOCK_INTEGRATION=true -define:ODIN_TEST_THREADS=1`.
  - `ODIN_TEST_FANCY=false` and `ODIN_TEST_THREADS=1` are Odin test-runner settings used in CI, not project code.
- Runtime env var only in the conformance tool: `LANDLOCK_EXPECT_ABI` asserts the expected kernel ABI (`tools/abi-conformance/main.odin`).

**Build:**
- No build config files (`ols.json` and editor dirs are gitignored, see `.gitignore`). All build options are CLI flags recorded in `.github/workflows/ci.yml`.

## Platform Requirements

**Development:**
- Odin `dev-2026-05` nightly; any Linux dev box (tests beyond stubs need a Landlock-enabled kernel: check `/sys/kernel/security/lsm` contains `landlock`).
- For non-Linux development, only `odin check` cross-targets are expected to pass; syscall procs return `Unsupported` errors.

**Production:**
- Linux ≥ 5.13 with Landlock compiled into the kernel and present in the LSM list. Every feature beyond FS v1 is optional and reported via `Policy_Result` (`abi_used`, `features_omitted`, `flags_omitted`) so callers can target older kernels best-effort.

---

*Stack analysis: 2026-11-09*
