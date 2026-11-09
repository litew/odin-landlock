---
last_mapped_commit: ac37c876561f405d750f813af98acfd43d7ebfd9
last_mapped_at: 2026-11-09
---
# Codebase Concerns

**Analysis Date:** 2026-11-09

Scope: full repo — `landlock.odin` (package `landlock`), `syscall/` package, tests, examples, tools, CI. Overall verdict: a small (~4.7k LOC), well-documented, defensively-coded library. Concerns are mostly hygiene and portability, not correctness.

## Tech Debt

**Hand-maintained ABI chain (`ABI_FS_V1..V9`, `abi_versions`):**
- Issue: The cumulative per-ABI feature constants are transcribed by hand from kernel docs. A compile-time tripwire exists (`#assert(ABI_FS_V9 == ABI_FS_ALL)` in `landlock.odin`) but only guards the FS chain; there is no equivalent assertion for the net/scope/restrict-flag chains, and `abi_versions := [10]ABI_Version{...}` is a magic-length array (index = ABI version, so ABI v10+ silently clamps via `abi_info_for_version`).
- Files: `landlock.odin` (ABI constants near top, `abi_versions`, `abi_info_for_version`), `syscall/syscall.odin`
- Impact: A future Landlock ABI (v10+) requires editing the array literal, the chain constants, and the `#assert` — three coordinated edits. Forgetting one yields wrong best-effort reporting, not a crash.
- Fix approach: When ABI v10 lands, add `#assert` tripwires for net/scope/flag chains mirroring the FS one, and derive `abi_versions` length from a named constant instead of a bare `[10]`.

**Manual rollback chains in `init` and `apply_with_mode`:**
- Issue: Every allocation-failure branch must manually delete everything allocated before it (see the cascading `delete(policy.rules_path)` / `policy^ = {}` ladder in `init`, and the repeated `close_opened_path_fds` + `close_ruleset_fd` pairs in `apply_with_mode`). This is correct today but is a classic place for a missed branch after refactoring.
- Files: `landlock.odin` (`init`, `apply_with_mode`)
- Impact: A future edit that adds one more allocation and forgets the rollback leaks fds or heap memory on an error path — silent, hard to notice in tests that don't inject allocation failure at that point.
- Fix approach: Prefer `defer`-guarded cleanup or consolidate the failure exit into a single labeled exit that frees everything conditionally.

**Linear scans for rule dedup:**
- Issue: `allow_path` scans `policy.rules_path` to merge duplicate paths; `record_omitted_path` scans `policy.rules_path_omitted` for exact duplicates. Both are O(n) per call → O(n²) policy construction.
- Files: `landlock.odin` (`allow_path`, `record_omitted_path`)
- Impact: Negligible at realistic policy sizes (tens of rules); only a concern if a caller builds policies with thousands of paths.
- Fix approach: Leave as-is unless a large-policy use case appears; a map keyed on `path+kind` would fix it.

**Test seam shipped in production code:**
- Issue: `apply_ops: Apply_Ops` (a `thread_local` injectable syscall-ops table) and `active_apply_ops` live in `landlock.odin` alongside production code. Every syscall in the apply path is indirected through it.
- Files: `landlock.odin` (`Apply_Ops`, `apply_ops`, `default_apply_ops`, `active_apply_ops`)
- Impact: Slight indirection cost and one extra way to misuse the API; but it is what makes the 1700-line unit suite possible without a kernel. Deliberate, documented trade-off.
- Fix approach: Keep. Document clearly if it ever moves to a `_test`-gated define.

**Vim swap / editor backup artifacts:**
- Issue: `.main.odin.swp` and `examples/main.odin~` exist in the working tree. Both are gitignored (`/.*.swp`, `examples/main.odin~`), but `/main.odin` is also gitignored — meaning a real `main.odin` at the repo root would be silently un-committable.
- Files: `.main.odin.swp`, `examples/main.odin~`, `.gitignore`
- Impact: Cosmetic; the `/main.odin` ignore entry could hide a legit file later.
- Fix approach: Delete the two artifacts; tighten `/main.odin` to a more specific pattern if it was for a scratch entry point.

## Known Bugs

**`raw_errno_from_os_error` can drop the errno:**
- Symptoms: If the OS error from a syscall wrapper is a non-platform error (e.g. a core:os-level wrapper error, not an `Errno`), the function returns 0. Callers then record `Policy_Result.error.raw_errno = 0` for a real failure.
- Files: `landlock.odin` (`raw_errno_from_os_error` and all `apply_*` wrappers)
- Trigger: A syscall stub returning a wrapped/translated error rather than a raw `linux.Errno`.
- Workaround: None; diagnostics show `raw_errno=0`. Not a correctness bug (status/kind still say the syscall failed), only degraded diagnostics.
- Fix approach: Fall back to a synthetic value or a distinct "errno unavailable" sentinel instead of 0 (0 currently reads as "success" in the field).

No other bugs observed. The apply path's fd-cleanup ordering, the `ENOMSG` empty-handled-set guard, and the `openat2` symlink handling are all correct as written.

## Security Considerations

**TOCTOU between `stat` validation and `open_path`:**
- Risk: `path_validation_stat` (`os.stat`/`os.lstat`) validates kind/symlink at `allow_*` time, but the fd used for the rule is opened later at apply time via `openat2`. A path could be swapped between the two moments.
- Files: `landlock.odin` (`path_validation_stat`, `apply_with_mode`), `syscall/syscall_linux.odin` (`open_path`)
- Current mitigation: This is the kernel's model, not a defect — `openat2` with `RESOLVE_NO_SYMLINKS` fully re-resolves at apply time, and Landlock pins the *final* inode hierarchy, so a post-apply swap under an allowed directory is still governed. The validation stat is an ergonomics/early-error feature.
- Recommendations: None required; keep the `RESOLVE_NO_SYMLINKS` behavior — it is stronger than `O_NOFOLLOW` (guards every component, not just the last).

**`Write_File` without `Truncate` rejected (good, but non-obvious):**
- Risk: None — but callers might be surprised that `path_access_validate` rejects `{.Write_File}` without `.Truncate` (`landlock.odin`, `path_access_validate`).
- Current mitigation: Distinct `Policy_Validation_Failure` value (`.Write_File_Without_Truncate`) with a clear message path.
- Recommendations: Keep; document in README if not already.

**Integration test forks the process:**
- Risk: `fork()` in a multithreaded process can deadlock in the child (allocator locks). The test mitigates by requiring `ODIN_TEST_THREADS=1` and `os.exit` in the child.
- Files: `landlock_integration_test.odin`
- Recommendations: Keep the define-gated, single-threaded contract; anyone running `odin test .` without `-define:LANDLOCK_INTEGRATION=true` is unaffected (test self-skips).

**Secrets:** No env files, credentials, or network calls anywhere in the repo. Not applicable.

## Performance Bottlenecks

Nothing significant. The whole library is syscall-bound (probe, create_ruleset, one `open` + `add_rule` per path, `prctl`, `restrict_self`). Allocation is confined to policy construction and summary rendering; transient apply buffers are freed inside `apply_with_mode` via `defer`/explicit cleanup. The only theoretical hot spot is the O(n²) dedup noted under Tech Debt.

## Fragile Areas

**`apply_with_mode` — the single most complex proc:**
- Files: `landlock.odin` (`apply_with_mode`, ~200 lines)
- Why fragile: Interleaves fd lifecycle (ruleset fd + N path fds), three pre-flight validation gates, strict-vs-best-effort branching, and result-context assembly. Every early-return must close the right fds.
- Safe modification: Preserve the pattern: open → append to `opened` → on any failure `close_opened_path_fds(opened[:]); close_ruleset_fd(...)` before returning. Extend the unit suite's `Apply_Ops` fake (`landlock_test_linux.odin`) with failure injection at any new syscall introduced.
- Test coverage: Strong — `landlock_test_linux.odin` (1701 lines) drives this path through the fake seam, including failure injection. Real-kernel coverage only in the define-gated integration test.

**`syscall/` FFI boundary:**
- Files: `syscall/syscall_linux.odin`, `syscall/syscall.odin`
- Why fragile: Hand-rolled kernel structs (`Ruleset_Attr`, `Path_Beneath_Attr`, `Net_Port_Attr`) with `#assert` size checks against hard-coded byte sizes (`RULESET_ATTR_SIZE :: 24`, 12, 16). Correct today; breaks if the kernel UAPI grows (Landlock ABI additions have historically only *appended* access bits, not changed struct layouts, so risk is low but real on a major UAPI change).
- Safe modification: Never reorder these structs; update the `#assert`s in the same commit as any UAPI change and cross-check against `linux/landlock.h`.
- Test coverage: Size assertions are compile-time; `syscall/syscall_test_linux.odin` covers wrapper behavior.

**CI README-probe (awk/sed doc extraction):**
- Files: `.github/workflows/ci.yml` ("README example compiles" step)
- Why fragile: Extracts the first `[source,odin]` block from `README.adoc` with an awk one-liner and rewrites the import with sed. Any README restructure (second code block before the first, changed import syntax) breaks CI in a confusing way.
- Safe modification: When editing `README.adoc`, keep the first odin block as the compilable example with the bare `import landlock` line the sed expects.
- Test coverage: None locally; CI-only.

## Scaling Limits

Not applicable in the traditional sense (library, not a service). Practical bounds: policies are built in memory with per-path cloned strings — thousands of rules are fine; hundreds of thousands would stress the O(n²) dedup. Ruleset fds are closed before return; no fd accumulation across applies.

## Dependencies at Risk

**`core:sys/linux` Landlock coverage:**
- Risk: `open_path` and `close_fd` exist only because core:os lacks `O_PATH` and a portable raw-fd close (documented in `syscall/syscall_linux.odin` comments, including a TODO about `O_PATH` missing upstream). `Open_How` is hand-defined because core:sys/linux has no `openat2` wrapper.
- Impact: If core:os/core:sys/linux adds these APIs, the local duplicates should be retired; if core changes error-translations, `raw_errno_from_os_error` may start returning 0 more often (see Known Bugs).
- Migration plan: Track Odin upstream; swap hand-rolled wrappers for core APIs when they appear. Low urgency — behavior is fully local and asserted.

## Missing Critical Features

**No uid/`path_beneath` on non-directory kinds beyond `File`/`Directory`:**
- Problem: `Path_Kind` supports only `.Directory` and `.File`; no `Execute`-under-symlink variants, no fd-based (O_PATH pre-opened) rule input, no `LANDLOCK_ACCESS_FS_REFER`-style opt-in ergonomics beyond the raw mask.
- Blocks: Callers wanting to sandbox by pre-opened fd (useful in execve-style re-exec flows) must roll their own.
- Note: This matches the go-landlock feature scope; likely deliberate v1 scope, not debt.

**No `Refer` migration guidance:**
- `Refer` (ABI v2) is in the constants but the library offers no helper for the common "bind-mount/move between trees" setup that makes `Refer` usable. Documentation-level gap, not code.

## Test Coverage Gaps

**Cross-platform stubs (`syscall/syscall_unsupported.odin`, `landlock_test_unsupported.odin`):**
- What's not tested: Runtime behavior on darwin/freebsd — CI only does `odin check` (`ci.yml`, "Cross-target compile check").
- Files: `syscall/syscall_unsupported.odin`, `landlock_test_unsupported.odin`
- Risk: Low — stubs return "unsupported" errors and `apply_with_mode` maps them to `Unsupported_Platform`. Compile checks cover most drift.
- Priority: Low.

**QEMU ABI matrix is local-only:**
- What's not tested: `tests/qemu/run-landlock-abi-matrix.sh` + `matrix.json` are NOT in git — `/tests/` is in `.gitignore` (`.gitignore` line 3). CI has `kernel-matrix.yml`, but the local evidence-writing script (`.omo/evidence/...`) is tied to a specific machine's task tracker.
- Files: `tests/qemu/`, `.gitignore`, `tests/smoke/main.odin`
- Risk: New contributors can't run the kernel-version matrix; the matrix definition (`matrix.json`) lives only on this machine. This is the biggest reproducibility gap in the repo.
- Priority: Medium — consider un-ignoring `tests/qemu/` and `tests/smoke/` specifically.

**Best-effort partial-enforcement on real kernels:**
- What's not tested: Only `Partially_Enforced` via fake ops locally; the QEMU matrix covers real old-ABI kernels but is not committed (above).
- Files: `landlock_test_linux.odin`, `tests/qemu/`
- Risk: A real-kernel regression in ABI masking would ship unnoticed between manual QEMU runs.
- Priority: Medium.

**Allocation-failure injection breadth:**
- What's not tested: The custom test allocator (`landlock_test_linux.odin`, top of file) injects failures, but each new rollback branch added to `init`/`apply_with_mode` needs a matching injected-failure case; future edits should extend these, not assume coverage.
- Priority: Medium.

---

*Concerns audit: 2026-11-09*
