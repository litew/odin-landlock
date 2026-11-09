---
last_mapped_commit: ac37c876561f405d750f813af98acfd43d7ebfd9
last_mapped_at: 2026-11-09
---
# Coding Conventions

**Analysis Date:** 2026-11-09

## Naming Patterns

**Files:**
- Package root file named after the package: `landlock.odin` (package `landlock`), `syscall/syscall.odin` (package `syscall`).
- Platform split via suffix + build tags: `syscall/syscall_linux.odin` (Linux implementations), `syscall/syscall_unsupported.odin` (stubs), `landlock_test_linux.odin` (Linux-only tests), `landlock_test_unsupported.odin` (`#+build !linux`). Platform files import the same package name.
- Tests colocated next to source at repo root or package dir, suffixed `_test` and platform-qualified (`landlock_integration_test.odin`).

**Procedures:**
- `snake_case` everywhere: `allow_ro_dirs`, `apply_best_effort`, `debug_summary`, `raw_errno_from_os_error`, `abi_info_for_version` (`landlock.odin`, `syscall/syscall_linux.odin`).
- Boolean helpers read as predicates: `is_ready`, `is_enforced`, `path_access_is_valid`, `path_access_is_writable_without_truncate`, `path_kind_matches_file_type` (`landlock.odin`).
- Constructors/factories are lowercase noun procs returning the struct: `path_beneath_attr`, `net_port_attr`, `fake_apply_ops`, `policy_error_none` (`syscall/syscall.odin`, `landlock.odin`).
- `init` / `cleanup` pair for handle-style lifecycles (`init :: proc(policy: ^Policy, allocator := context.allocator)`, `cleanup :: proc(policy: ^Policy)` in `landlock.odin`).

**Types:**
- Exported types use `Pascal_Case` with underscores: `Policy`, `Policy_Result`, `Policy_Error`, `Policy_Error_Kind`, `Path_Options`, `Ruleset_Attr`, `Path_Beneath_Attr`.
- Enums use `Pascal_Case` members: `Policy_Status :: enum { Enforced, Partially_Enforced, Not_Enforced }`, `Path_Kind :: enum { Directory, File }`.
- Constants use the same `Pascal_Case` style: `HANDLED_DEFAULT`, `DEBUG_SUMMARY_CAP`, `PR_SET_NO_NEW_PRIVS`, `RESOLVE_NO_SYMLINKS`.
- `bit_set` typedefs are named `<Flag>_Flags`: `Access_FS_Flags :: bit_set[Access_FS_Flag;u64]` (`syscall/syscall.odin`).

**Variables:**
- `snake_case` locals; error variables end in `_err`/`errno`: `alloc_err`, `stat_err`, `open_errno`, `create_errno`, `restrict_errno` (`landlock.odin`).
- File-scope fakes: `fake_state`, `fake_record`, `fake_reset` (`landlock_test_linux.odin`).

**Visibility attributes:**
- File-private declarations use `@(private)` (file scope): ABI tables, internal structs (`landlock.odin`).
- Package-private seams use `@(private)` on the field/proc; test-reachable procs are plain package-level (e.g. `debug_summary_with_cap` is `@(private)` but tests exercise it deliberately).
- Some leaf procs are marked `proc "contextless"` when they don't need the context allocator (error constructors, predicates).

## Code Style

**Formatting:**
- Odinols-style, tabs, Odin default orthodoxy; `ols.json` present at repo root for the language server.
- Struct literals with named fields, one field per line when large:
```odin
return Policy_Error {
    kind = .Allocation_Failed,
    cause = .Allocation,
    allocator_error = allocator_error,
}
```
- Multi-line proc signatures with grouped return values:
```odin
summary :: proc(
    result: Policy_Result,
    allocator := context.allocator,
) -> (
    summary: string,
    err: Policy_Error,
)
```
- No linter/formatter config beyond the toolchain; style enforced by review + CI `odin check`.

**Compile-time checks:**
- `#assert` used as drift tripwires for ABI/struct sizes: `#assert(ABI_FS_V9 == ABI_FS_ALL)` and `#assert(size_of(Path_Beneath_Attr) == 12)` (`landlock.odin`, `syscall/syscall.odin`). Add an `#assert` whenever a hand-maintained chain must track an enum or a C layout must not change.

## Import Organization

**Order:**
1. Package doc comment block first, then `package` line.
2. `core:` imports (`core:fmt`, `core:os`, `core:mem`, `core:strings`, `core:sys/linux`, `core:sys/posix`).
3. Local sibling package: `import "syscall"` (from `landlock.odin`), or relative-path import for examples: `import landlock ".."` (`examples/main.odin`).
4. `base:intrinsics` when needed (`landlock.odin`).

**Path Aliases:**
- Only the example aliases the parent package: `import landlock ".."`; internal code uses plain unqualified `import "syscall"`.

## Error Handling

**Strategy:** Odin idiom — `(value, os.Error)` at the syscall layer; a rich **typed error struct** (`Policy_Error`) at the library layer; **result struct** (`Policy_Result`) for apply outcomes. The library never panics or exits; callers fail closed by checking `is_enforced(result)`.

**Patterns:**

1. Syscall layer returns `(int, os.Error)` and converts negative returns to errno via a single choke point (`syscall/syscall_linux.odin`):
```odin
syscall_error :: proc "contextless" (ret: int) -> os.Error { … }
```

2. Structured, classified errors instead of bare errnos (`landlock.odin`):
```odin
Policy_Error :: struct {
    kind:            Policy_Error_Kind,   // Unavailable, Disabled, Invalid_Policy, Permission_Denied, ...
    cause:           Policy_Error_Cause,  // which syscall/stage failed
    raw_errno:       i32,                 // errno preserved verbatim
    allocator_error: mem.Allocator_Error,
    validation:      Policy_Validation_Failure,
}
```
Build errors through small `@(private)` factory procs: `policy_error_none()`, `policy_error_errno(kind, cause, raw_errno)`, `policy_error_allocation(alloc_err)`, `policy_error_invalid_policy(.Empty_Path)`.

3. Early-return guard clauses, checking `err.kind != .None` / `err == nil`; no exceptions, no unwinding:
```odin
if !is_ready(policy) {
    return policy_error_invalid_policy(.Policy_Not_Initialized)
}
```

4. errno preserved through every layer: `raw_errno_from_os_error` extracts `i32` from `os.Error` via `os.is_platform_error`; `apply_result_for_errno` maps errno → classification (`ENOSYS` → `Unavailable`, `EOPNOTSUPP` → `Disabled`, `EPERM` → `Permission_Denied`, else `Syscall_Failed`) (`landlock.odin`).

5. **Allocation errors are first-class:** every `make`/`append`/`strings.clone` return is checked and folded into `Policy_Error{kind = .Allocation_Failed, allocator_error = ...}`, with rollback of already-allocated siblings in `init` (`landlock.odin`).

6. **Resource cleanup on every error path:** fd leaks are explicitly closed before each early return in `apply_with_mode` (`close_opened_path_fds(opened[:])`, `close_ruleset_fd(ruleset_fd)`); `defer` used for scope-local cleanup (`defer os.file_info_delete(info, context.allocator)`).

7. **Caller-owned allocation documented in the doc comment:** `summary`/`debug_summary` return strings the caller frees with `delete(summary, allocator)` using the allocator passed in (`landlock.odin`).

8. Allocator passed as a defaulted parameter, `allocator := context.allocator`; the `Policy` stores its own allocator and `cleanup` frees everything from it.

## Validation Patterns

- Validate *before* side effects and before allocation: `allow_path` rejects empty/NUL-containing/over-`PATH_MAX` paths and invalid access masks before any stat or clone (`landlock.odin`).
- Validation failures get a `Policy_Validation_Failure` discriminant (`Empty_Path`, `Wrong_Path_Type`, `Symlink_Rejected`, `Write_File_Without_Truncate`, `Rule_For_Unhandled_Feature`, ...) so callers can branch precisely.
- Security-critical invariants get dedicated comments explaining the attack (e.g. interior-NUL truncation by cstring conversion; TOCTOU symlink swap; monotonic `no_follow` merge).

## Comments

**When to Comment:**
- Package-level doc comment block at top of file explaining the model, memory ownership, and typical flow (`landlock.odin`, `syscall/syscall.odin`).
- Every exported proc gets a doc comment stating contract, defaults, and caller obligations.
- Security rationale comments on non-obvious decisions (`// no_follow resolves the path with openat2(RESOLVE_NO_SYMLINKS) ...`).
- Tests carry intent comments (`// The contract is fail-loudly, never return a clipped security summary`).

## Function Design

**Size:** small, single-purpose; large flow (`apply_with_mode`, ~180 lines) is one ordered syscall sequence with per-step error returns, not decomposed artificially.

**Parameters:** receiver-first (`policy: ^Policy`), options via defaulted `options := Path_Options{}`, variadic path helpers (`allow_ro_dirs(policy, ..string)`).

**Return Values:** single `Policy_Error` for mutators; named multi-returns `(value, err)` / `(summary, err)`; `bool` predicates named `is_*`.

## Module Design

**Exports:** public API surface is deliberately narrow — `Policy`, `init/cleanup`, builder procs (`allow_*`, `scope_*`, `handle_*`, `allow_path`), `apply_strict`/`apply_best_effort`, `Policy_Result`, `is_enforced`, `summary`/`debug_summary`. Everything else `@(private)`.

**Seams for testing:** the apply path goes through an indirection vtable `Apply_Ops` (proc-field struct) so unit tests swap in fakes without a mocking framework (`landlock.odin` — `@(private) apply_ops: Apply_Ops`, `active_apply_ops()`).

**Platform split:** same package name across `#+build` files; non-Linux targets compile stubs returning typed "unsupported" errors, so the library type-checks everywhere (`syscall/syscall_unsupported.odin`).

---

*Convention analysis: 2026-11-09*
