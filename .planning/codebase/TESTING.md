---
last_mapped_commit: ac37c876561f405d750f813af98acfd43d7ebfd9
last_mapped_at: 2026-11-09
---
# Testing Patterns

**Analysis Date:** 2026-11-09

## Test Framework

**Runner:**
- Odin built-in `core:testing` (no external framework).
- Tests are ordinary package procs tagged `@(test)` taking `t: ^testing.T`.

**Assertion Library:**
- `testing.expect(t, cond, "msg")`, `testing.expectf(t, cond, "fmt %s", x)`, and — preferred for value comparison — `testing.expect_value(t, got, want)`.
- Early-abort pattern: `if !testing.expect(...) { return }` keeps failed setup from cascading.

**Run Commands:** (from `.github/workflows/ci.yml`)
```bash
odin check . -no-entry-point                      # compile check (no entry point)
odin test . -define:ODIN_TEST_FANCY=false         # unit tests, landlock package
odin test syscall -define:ODIN_TEST_FANCY=false   # unit tests, syscall package
odin build examples -out:/tmp/example             # example still builds
odin test . -define:LANDLOCK_INTEGRATION=true -define:ODIN_TEST_THREADS=1   # real-kernel integration
odin check . -no-entry-point -target:darwin_amd64 # cross-target stub type-check
odin check . -no-entry-point -target:freebsd_amd64
```
There is no coverage tooling; coverage is achieved structurally (fakes drive every branch).

## Test File Organization

**Location:** colocated with source.
- `landlock_test_linux.odin` (~1700 lines) — main unit suite, package `landlock`, `#+private`, Linux-only.
- `landlock_test_unsupported.odin` — `#+build !linux`; the non-Linux platform test, compiled in cross-target checks.
- `landlock_integration_test.odin` — real-kernel test, opt-in via `#config(LANDLOCK_INTEGRATION, false)`.
- `syscall/syscall_test_linux.odin` — syscall-layer tests incl. real-kernel marshaling.
- `tools/abi-conformance/main.odin` — standalone binary run inside VMs by `tests/qemu/run-landlock-abi-matrix.sh` / `.github/workflows/kernel-matrix.yml`.

**Naming:**
- `test_<subject>_<expected_behavior>`: `test_apply_probe_enosys_is_unavailable`, `test_no_follow_survives_reject_then_follow_merge`, `test_policy_summary_allocation_failure`.
- Unexported helper procs live alongside tests: `expect_policy_ok`, `make_test_temp_dir`, `join_test_path`, `write_test_file`, `expect_debug_contains`, `enforced_result`, `failing_allocator`.

## Test Structure

**Suite Organization:**
```odin
@(test)
test_apply_probe_enosys_is_unavailable :: proc(t: ^testing.T) {
    saved_ops := use_fake_apply_ops()      // swap in fakes
    defer apply_ops = saved_ops            // restore seam
    fake_state.probe_errno = 38            // arrange errno

    policy: Policy
    expect_policy_ok(t, init(&policy), "init")
    defer cleanup(&policy)                 // teardown
    expect_policy_ok(t, allow_ro_dirs(&policy, "/tmp"), "allow_ro_dirs")

    result := apply_strict(&policy)        // act
    testing.expect_value(t, result.status, Policy_Status.Not_Enforced)   // assert
    testing.expect_value(t, result.error.kind, Policy_Error_Kind.Unavailable)
    testing.expect_value(t, result.error.raw_errno, i32(38))
}
```

**Patterns:**
- Arrange → Act → Assert with one `@(test)` per behavior; ABI-version behavior pairs assert both sides of a boundary (`fake_state.abi = 7` then reset + `abi = 8` inside one test).
- Setup/teardown via `defer` (`defer cleanup(&policy)`, `defer delete(summary)`, `defer os.remove_all(temp_dir)`).
- Temp fixtures through helpers, always cleaned up (`make_test_temp_dir` → `defer os.remove_all`).
- Errno-exact assertions: expected syscall failure tested by its real errno number (`i32(38)` ENOSYS, `i32(95)` EOPNOTSUPP, `i32(40)` ELOOP, `i32(9)` EBADF).

## Mocking

**Framework:** none — hand-rolled fake layer behind the `Apply_Ops` proc-table seam (`landlock.odin` defines `@(private, thread_local) apply_ops`; tests replace it).

**Patterns:** (`landlock_test_linux.odin`)
```odin
use_fake_apply_ops :: proc() -> Apply_Ops {   // swap + reset, returns saved value
    saved := apply_ops
    fake_reset()
    apply_ops = fake_apply_ops()
    return saved
}
// call-site pattern:
saved_ops := use_fake_apply_ops()
defer apply_ops = saved_ops
```
- `Fake_Apply_State` is a `@(thread_local)` struct recording every call into a fixed `[128]Fake_Call` buffer (guard-checked), with per-syscall injected errnos (`create_errno`, `add_path_errno`, `apply_errno`, ...) and a configurable fake ABI.
- Assertions query the recording: `count_fake_calls(.Close, 20)` and an ordering check `expect_fake_order(t, {Probe, Create, Open_Path, Add_Path, Close, Prctl, Restrict, Close}[:])`.
- Allocation failure is tested with a purpose-built allocator:
```odin
failing_allocator :: proc "contextless" () -> mem.Allocator { ... returns .Out_Of_Memory ... }
```
- Leak checking via `mem.Tracking_Allocator`: init, run, `cleanup`, then `testing.expect_value(t, len(track.allocation_map), 0)` (used in `test_policy_allocator_copies_and_frees_paths`, `test_duplicate_and_overlapping_path_rules_are_deterministic`).

**What to Mock:** kernel syscalls (everything in `Apply_Ops`); allocation failures. **What NOT to Mock:** struct validation, ABI table logic, summary rendering — tested directly against real values. Real `os.stat`/temp dirs are used (not mocked) for path validation tests.

## Fixtures and Factories

**Test Data:**
- Struct factories: `enforced_result(abi, features)` builds a valid `Policy_Result` for summary tests.
- Filesystem fixtures created per-test under `os.make_directory_temp("", "odin-landlock-test-*")` plus real symlink targets under `/tmp` keyed by pid (`fmt.tprintf("/tmp/ll_symlink_real_%d", posix.getpid())`).

## Test Types

**Unit Tests:**
- Everything except integration: ABI table shape, builder validation, error classification, summary rendering, apply flow orderings — kernel faked.

**Integration Tests:**
- `landlock_integration_test.odin`: opt-in, real `landlock_restrict_self`. Key safety contract (documented in file header): restriction is irreversible and thread-local, so the policy applies in a `posix.fork()`ed child that exits via `os.exit` with `CHILD_*` codes; requires `ODIN_TEST_THREADS=1` because fork + threads can deadlock on allocator locks. Pass = child denied a `/tmp` read while `/usr` is allowed; skip = kernel lacks Landlock.
- `syscall/syscall_test_linux.odin`: real-kernel marshaling tests (create ruleset, add rule) that never restrict, so they're safe to run always.

**VM/Matrix Tests:**
- `.github/workflows/kernel-matrix.yml` (weekly/dispatch/label-gated): boots Ubuntu mainline kernels (5.10 → 6.15, ABI 0→7) under virtme-ng and runs `tools/abi-conformance` asserting the expected ABI and enforcement behavior per kernel version.

## CI Integration

- `.github/workflows/ci.yml` on push/PR: `odin check`, both unit suites, example build, README doc-snippet compile probe (awk-extracts the first `[source,odin]` block and builds it), integration test (skips gracefully if `/sys/kernel/security/lsm` lacks landlock), and darwin/freebsd cross-target checks proving the stub files compile.
- Unit suites run with `-define:ODIN_TEST_FANCY=false` for plain CI output.

## Common Patterns

**Error Testing:**
```odin
err := allow_path(&policy, .Directory, "", Path_Access{.Read_Dir})
testing.expect_value(t, err.kind, Policy_Error_Kind.Invalid_Policy)
testing.expect_value(t, err.validation, Policy_Validation_Failure.Empty_Path)
```
Assert the full discriminant chain (kind → cause → validation → raw_errno), never just `err != nil`.

**Negative-path Testing:** every error branch in `apply_with_mode` has a test that injects the matching errno and asserts fds were closed (`count_fake_calls(.Close, ...)`) — resource-leak regression coverage on failure paths.

**Cross-platform Testing:** `landlock_test_unsupported.odin` verifies the non-Linux stub path reports `Unsupported_Platform`; it type-checks in the darwin/freebsd CI jobs even though it only runs on non-Linux hosts.

---

*Testing analysis: 2026-11-09*
