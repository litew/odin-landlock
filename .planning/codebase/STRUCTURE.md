---
last_mapped_commit: ac37c876561f405d750f813af98acfd43d7ebfd9
last_mapped_at: 2026-11-09
---
# Codebase Structure

**Analysis Date:** 2026-11-09

## Directory Layout

```
odin-landlock/
├── landlock.odin                      # Main package: policy builder, ABI tables, apply orchestration (~1000 lines, single file)
├── landlock_test_linux.odin           # Unit tests (fake Apply_Ops seam; runs on Linux)
├── landlock_test_unsupported.odin     # Unit-test subset for non-Linux targets
├── landlock_integration_test.odin     # Opt-in real-kernel enforcement test (forked child)
├── syscall/                           # Local package: raw Landlock syscall interface
│   ├── syscall.odin                   # Shared constants, bit sets, attr structs (all targets)
│   ├── syscall_linux.odin             # Linux syscall implementations
│   ├── syscall_unsupported.odin       # Non-Linux stubs (#+build !linux)
│   └── syscall_test_linux.odin        # Tests for the syscall package (Linux)
├── examples/                          # Runnable usage examples
│   ├── main.odin                      # Primary demo: build + apply a policy, fail closed
│   └── rules-demo/
│       └── demo.odin                  # Rule-construction options demo (symlink/missing-path)
├── tools/
│   └── abi-conformance/
│       └── main.odin                  # Standalone real-kernel conformance probe for CI VMs
├── .github/
│   └── workflows/
│       ├── ci.yml                     # Build + test pipeline
│       └── kernel-matrix.yml          # Per-kernel VM matrix running abi-conformance (virtme-ng)
├── README.adoc                        # Full API documentation + ABI compatibility matrix
├── LICENSE
└── .gitignore
```

## Directory Purposes

**Root (package `landlock`):**
- Purpose: the entire public policy library lives in one file, `landlock.odin`; tests sit alongside it at the root as Odin convention requires (`odin test .` picks up `*_test*.odin` in the package dir).
- Contains: `landlock.odin` (types + all procs), three test files.
- Key files: `landlock.odin`, `landlock_test_linux.odin`, `landlock_integration_test.odin`

**`syscall/` (package `syscall`):**
- Purpose: low-level, no-policy Landlock kernel interface — the only code that touches `core:sys/linux` directly (aside from the conformance tool).
- Contains: platform-shared definitions (`syscall.odin`), Linux impls (`syscall_linux.odin`), `#+build !linux` stubs (`syscall_unsupported.odin`), tests.
- Key files: `syscall/syscall.odin` (constants + `#assert` layout checks), `syscall/syscall_linux.odin` (`create_ruleset`, `add_path_beneath_rule`, `add_net_port_rule`, `restrict_self`, `prctl`, `open_path`, `close_fd`)

**`examples/`:**
- Purpose: runnable, documented usage; the canonical import pattern (`import landlock ".."` — relative, since the example lives inside the repo).
- Contains: one demo per subdirectory; each subdirectory is its own `package main`.
- Key files: `examples/main.odin`, `examples/rules-demo/demo.odin`

**`tools/abi-conformance/`:**
- Purpose: plain binary (no Odin toolchain needed in the VM) probing the running kernel's Landlock ABI and running an enforcement battery; each check forks its own child because enforcement is irreversible/cumulative.
- Key files: `tools/abi-conformance/main.odin` (`package abi_conformance`)

**`.github/workflows/`:**
- Purpose: CI — `ci.yml` (build/test) and `kernel-matrix.yml` (boots per-kernel VMs via virtme-ng and runs the conformance binary, honoring `LANDLOCK_EXPECT_ABI`).

## Key File Locations

**Entry points:**
- `examples/main.odin`: demo binary entry (`main :: proc()`) — start here to learn the API flow.
- `examples/rules-demo/demo.odin`: secondary demo binary.
- `tools/abi-conformance/main.odin`: conformance binary entry (`package abi_conformance`, `main :: proc()`).
- `landlock.odin`: library entry — no `main`; consumers begin at `landlock.init`.

**Configuration:**
- `README.adoc`: install/vendor instructions, full API docs, ABI v1–v9 kernel compatibility matrix.
- `.github/workflows/ci.yml`, `.github/workflows/kernel-matrix.yml`: CI definitions.
- No build config files — builds are plain `odin build/test` invocations; Odin version pinned by documentation (dev-2026-05 nightly).

**Core logic:**
- `landlock.odin`: policy types (`Policy`, `Policy_Result`, `Policy_Error`), ABI chain (`ABI_FS_V1`…`ABI_FS_V9`), builder procs, `apply_with_mode`, `Apply_Ops` seam.
- `syscall/syscall_linux.odin`: syscall wrappers incl. the hand-rolled `openat2`/O_PATH `open_path` wrapper.

**Testing:**
- `landlock_test_linux.odin`: main suite; drives apply through the fake `Apply_Ops` (`use_fake_apply_ops`, `fake_*` procs, `Fake_Call` recording).
- `landlock_test_unsupported.odin`: platform-independent subset.
- `syscall/syscall_test_linux.odin`: syscall package tests.
- `landlock_integration_test.odin`: real-kernel test, opt-in via `-define:LANDLOCK_INTEGRATION=true -define:ODIN_TEST_THREADS=1`.

## Naming Conventions

**Files:**
- Package-identical single file per package name: `landlock.odin` (package `landlock`), `syscall/syscall.odin` (package `syscall`).
- Platform suffix: `*_linux.odin` / `*_unsupported.odin` pairs (impl vs stub): `syscall_linux.odin` / `syscall_unsupported.odin`, same pattern for tests.
- Test files colocated in the package directory, name-matched: `landlock_test_linux.odin`, `landlock_integration_test.odin`.
- Odin default: one directory = one package; file name matches package name for the primary file.

**Directories:**
- Lowercase, hyphen/underscore separated: `syscall/`, `examples/`, `tools/abi-conformance/`.
- Examples group variants in subdirectories (`examples/rules-demo/`), tools under `tools/<tool-name>/`.

**Identifiers (observed, relevant for placement):**
- `Pascal_Snake_Case` types/enums (`Policy_Result`, `Policy_Error_Kind`, `Apply_Ops`, `Path_Beneath_Attr`); `snake_case` procs/vars (`apply_with_mode`, `handle_flags`, `get_abi_version`); SCREAMING_SNAKE constants (`HANDLED_DEFAULT`, `DEBUG_SUMMARY_CAP`, `PR_SET_NO_NEW_PRIVS`).
- Private/internal procs annotated `@(private)` / `@(private = "file")`; public API has none.

## Where to Add New Code

**New public builder proc (e.g. a new rule type):**
- Implementation: `landlock.odin` — follow the existing pattern of `allow_tcp_bind`/`scope_signal` (append a validated rule to `Policy`, return `Policy_Error`).
- Gate by ABI: extend the cumulative chain in `landlock.odin` (`ABI_FS_V*` / new `ABI_*_V*` constant) and register it in `abi_versions`; the `#assert(ABI_FS_V9 == ABI_FS_ALL)` tripwire must keep compiling.

**New syscall wrapper:**
- Shared constants/types: `syscall/syscall.odin` (with `#assert(size_of(...) == ...)` for any kernel struct).
- Linux impl: `syscall/syscall_linux.odin`; non-Linux stub: `syscall/syscall_unsupported.odin` (same signature returning `unsupported_platform_error()`).

**New kernel call used during apply:**
- Add a proc field to `Apply_Ops` in `landlock.odin`, wire it into `default_apply_ops`, and add a matching `fake_*` + `Fake_Call_Kind` entry in `landlock_test_linux.odin`.

**New test:**
- Unit (fake seam): `landlock_test_linux.odin` — `@(test)` proc taking `^testing.T`; non-platform-dependent cases go in `landlock_test_unsupported.odin`.
- Syscall-level: `syscall/syscall_test_linux.odin`.
- Real-kernel end-to-end: `landlock_integration_test.odin` (forked child; child exit-code protocol).
- Kernel-conformance check: `tools/abi-conformance/main.odin` — add a `check_*` proc run via `run_check`/`fork_check`.

**New example:**
- Create a new subdirectory under `examples/` containing a `package main` `.odin` file; import with a relative path (`import landlock ".."`).

**Utilities/shared helpers:**
- Private helpers stay in the same single-file package near their callers (`landlock.odin` bottom half; `@(private)`).

## Special Directories

**`.github/`:**
- Purpose: CI workflows (build/test, per-kernel VM conformance matrix).
- Generated: No; Committed: Yes.

**`.planning/`:**
- Purpose: GSD planning artifacts (this document). Excluded from source mapping.
- Generated: tooling; Committed: orchestrator decides.

**Note on single-file layout:** the entire policy library is deliberately one file (`landlock.odin`, ~1000 lines) — section order in that file is: package doc comment → types/enums/bit_sets → error constructors → public builder procs → private validation → apply machinery → summaries. Match this ordering when extending rather than splitting the file.
