# Pitfalls Research: Odin Landlock ABI-Head Parity

**Domain:** Language-binding pitfalls for the Linux Landlock kernel ABI (extending a v1–v9 binding to the current ABI head)
**Researched:** 2026-11-09
**Confidence:** HIGH — all ABI/version claims grounded in live sources: kernel docs (docs.kernel.org, dated October 2026), man-pages 6.19 (2026-04/05/07), `include/uapi/linux/landlock.h` from torvalds/master (retrieved 2026-11-09), go-landlock security advisory GHSA-vv6c-69r6-chg9 (2024-10-14), Odin core:sys/linux docs (retrieved 2026-11-09).

**ABI head today (for reference throughout):** v1 5.13 → v2 REFER (5.19) → v3 TRUNCATE (6.2) → v4 TCP (6.7) → v5 IOCTL_DEV (6.10) → v6 scopes (6.12) → v7 LOG_* flags (6.15) → v8 TSYNC (7.0) → v9 RESOLVE_UNIX (7.1) (man-pages 6.19 `landlock(7)` VERSIONS table, 2026-07-18), **plus post-v9: v10 UDP + quiet_* audit fields, v11 `LANDLOCK_RESTRICT_SELF_NO_NEW_PRIVS`, v12 capability+namespace rules with new `handled_permissions` ruleset field** (docs.kernel.org landlock.html, Oct 2026; uapi header). The existing binding covers through v9; everything v10+ is the milestone surface.

---

## Critical Pitfalls

### Pitfall 1: Gating-table drift — new bits not threaded into the cumulative ABI chain, or assumed present on old kernels

**What goes wrong:**
Two failure directions. (a) A new right (e.g. `LANDLOCK_ACCESS_NET_BIND_UDP`, bit 2 of net flags; `LANDLOCK_ACCESS_FS_RESOLVE_UNIX`, bit 16) is added to `Access_Net_Flags`/`Access_FS_Flags` but not to the cumulative per-version tables (`ABI_NET_V10`, etc.). On any kernel the bit is never requested — feature silently dead. (b) The inverse: a table entry forgets that net bits are v10-only and the bit lands in `ABI_NET_V4`, so pre-7.2 kernels get an unknown bit passed to `landlock_create_ruleset` → `EINVAL` (man-pages 6.19 `landlock_create_ruleset(2)`: "EINVAL Unknown ... access") — the whole policy fails on exactly the old kernels the ≥5.13 floor targets.

**Why it happens:**
Each ABI adds bits in the *middle* of existing flag groups (FS bit 16 added at v9; net bits 2–3 added at v10), so a `#assert(ABI_FS_V9 == ABI_FS_ALL)`-style tripwire must be re-anchored every time, and the temptation is to write `abi >= 10` range checks instead of explicit cumulative masks. Range checks rot the moment a v13 adds another net bit in between.

**How to avoid:**
- Keep the cumulative-mask-chain pattern per dimension (`ABI_NET_V4`, then `ABI_NET_V10 = ABI_NET_V4 | {BIND_UDP, CONNECT_SEND_UDP}`) and move each dimension's head tripwire forward: `#assert(ABI_NET_V10 == ABI_NET_ALL)` must fail to compile until v10 bits are threaded. Add equivalent tripwires for the *new* dimensions (restrict flags, permissions).
- Mirror the kernel doc's canonical switch pattern (docs.kernel.org Oct 2026 example: `case 6 ... 8:` removes v9 FS bit; `case 9:` removes UDP; `case 10, 11:` removes permission bits) as a unit-test table: for every ABI 1..12, compute the gated handled set and assert it equals a literal expected mask.
- Clamp probed ABI > head to the highest known version ("kernel from the future" — gnoack best-effort article) and record `abi_requested > abi_used` in the result so an unknown-newer kernel is visible to callers instead of silently behaving like the max known version.

**Warning signs:**
A feature works on the newest CI kernel but `EINVAL`s (or never appears in ruleset dumps) on the oldest matrix kernel; conformance probe reports `ABI_MISMATCH` on v4–v9 kernels after a net-layer change; a new constant exists in `syscall` but no `ABI_*` table references it.

**Phase to address:**
Syscall/ABI-layer phase (tables + tripwires land with the bits); verified again in the conformance-probe phase via the per-ABI expected-mask unit table.

---

### Pitfall 2: Handled-set gaps — new access dimensions silently escape deny-by-default

**What goes wrong:**
Landlock only denies what the ruleset declares handled (`handled_access_fs`, `handled_access_net`, `scoped`, and now `handled_permissions` — uapi header, 7 `__u64` fields). A binding that extends its right enums but not its default handled set produces a ruleset that still *allows* UDP traffic, capability use, and namespace use on v10+/v12 kernels while reporting success. The canonical precedent: **GHSA-vv6c-69r6-chg9 (go-landlock, 2024-10-14) — in best-effort mode with `V4`/`V5` configs, TCP bind/connect were "not restricted ... any more when they were requested"** — a released, widely used binding shipped a silent sandbox hole exactly at the first ABI where a *new dimension* (network) appeared.

**Why it happens:**
`HANDLED_DEFAULT` was built as "all FS + net TCP + scopes" at v6–v9 design time. New dimensions arrive as separate fields (`handled_permissions`) or new bit groups (UDP), and the builder's `handle_features`/`handle_flags` plumbing must deliberately join them. It compiles fine without them — nothing fails until an enforcement test on a v12 kernel.

**How to avoid:**
- Every new dimension gets a `HANDLED_DEFAULT` join *and* a dedicated enforcement test that proves denial on a real kernel: connect UDP → must fail with `BIND_UDP`+`CONNECT_SEND_UDP` handled; `unshare(CLONE_NEWUSER)` and `CAP_SYS_CHROOT` exercise → must fail with both permission bits handled.
- Kernel doc explicitly requires capability + namespace permissions to be handled *together*: user-namespace creation needs no capability and grants all capabilities inside it; "gating only one of the two leaves a kernel attack-surface widening path open" (docs.kernel.org, Oct 2026). Make the builder validate or warn when exactly one of `NAMESPACE_USE`/`CAPABILITY_USE` is handled.
- Keep the go-landlock rule: handled dimensions are opt-out via explicit `handle_*` calls, never inferred from whether rules exist.

**Warning signs:**
Enforcement tests that only check *allowed* paths pass while "must deny" checks are missing for a dimension; `Policy_Result.features_applied` lists a feature whose dimension is absent from `HANDLED_DEFAULT`; a grep for `handled_permissions` finds it only in the syscall layer.

**Phase to address:**
Policy-layer phase (handled-set model extension), with enforcement proof in the integration-test and conformance-probe phases.

---

### Pitfall 3: Ruleset-attr size drift — one `sizeof` cannot serve all ABIs

**What goes wrong:**
`landlock_create_ruleset` checks the size argument against the *running kernel's* known struct size: `E2BIG` "size is too big", `EINVAL` "too small size" (man-pages 6.19, 2026-04-21). The struct grew from 8 bytes (v1) → 16 (v4, net) → 24 (v6, scoped — the repo's current `#assert(size_of(Ruleset_Attr) == 24)`) → **48 at v10 (quiet_access_fs/net/scoped) → 56 at v12 (handled_permissions)** (uapi header). A binding that defines the full 56-byte struct and passes `size_of(Ruleset_Attr)` gets `E2BIG` on every kernel below v10; one that keeps passing 24 gets `EINVAL` on v10+ kernels and can never pass the new fields.

**Why it happens:**
The existing single-`#assert`-size pattern assumes one struct serves all supported kernels, which was true only while the milestone stayed within v1–v9.

**How to avoid:**
- Define the widest struct (all 7 fields) plus a per-ABI size table (`8, 8, 8, 16, 16, 24, 24, 24, 24, 48, 48, 56` for ABI 1..12) selected from the probed ABI at apply time; keep `#assert` checks for each historical size constant so layout regressions still trip at compile time.
- Same discipline if future rule attr structs ever gain size args; rule attrs (`path_beneath` 12 B packed, `net_port` 16 B, `namespace`/`capability` 24 B each) currently have no size argument (uapi header) but assert their sizes too.
- Add a unit test asserting the size table matches the ABI table, and a fake-ops assertion that the size passed to `create_ruleset` matches the probed ABI.

**Warning signs:**
CI's newest kernel or the mainline-kernel job reports `EINVAL` on `create_ruleset` while older jobs pass (or vice versa); `strace`-style fake call logs show one constant size for every ABI.

**Phase to address:**
Syscall/ABI-layer phase (attr struct + size table land together); asserted in unit-test phase.

---

### Pitfall 4: Best-effort downgrade path drops the new feature class (the GHSA class of bug)

**What goes wrong:**
Even when the handled set is right, the *rule-writing* path must be downgraded per ABI: mask each rule's `allowed_access` against the gated handled set and **skip the rule when the masked result is empty** — the kernel returns `ENOMSG` ("Empty accesses (rule_attr->allowed_access is 0)") rather than ignoring an empty rule (man-pages 6.19 `landlock_add_rule(2)`, 2026-05-04). The kernel doc demonstrates the pattern (`tcp_conn.allowed_access &= ruleset_attr.handled_access_net; if (tcp_conn.allowed_access) ...`). go-landlock's GHSA was precisely a downgrade-path bug where a new feature class stopped being restricted when downgrading from a V5 config. An Odin equivalent: UDP rules downgraded wrong → either empty rules crash with `ENOMSG`, or rights that should be per-rule-masked are dropped from the whole policy making it *stricter* than requested (e.g. masking all FS rights away because one v9-only bit was unsupported → everything else denied).

**Why it happens:**
Per-rule masking logic was written once for the FS dimension's shape (rights valid for all paths) and copied for dimensions with different shapes (net rules keyed by port; capability/namespace rules keyed by member bitmasks with no path object).

**How to avoid:**
- Implement masking + skip-empty as one shared helper exercised by unit tests per dimension, per ABI: every rule × every ABI 1..12 must yield either a masked non-empty rule or a recorded omission — never an empty rule sent to the kernel.
- Omissions must be visible: best-effort result reports the feature in `features_omitted` / `Partially_Enforced`, matching the existing fail-closed contract.

**Warning signs:**
`ENOMSG` surfacing as a `Policy_Error` in integration tests (it should be impossible by construction); a policy requesting only unsupported rights reports `Enforced` with an empty ruleset instead of `Not_Enforced`/omissions.

**Phase to address:**
Policy-layer phase (shared downgrade helper), verified in unit and conformance phases.

---

### Pitfall 5: Irreversible-enforcement test traps — shared-process tests, TSYNC blast radius, fork deadlocks

**What goes wrong:**
Landlock is cumulative and irreversible, and `restrict_self` binds to the *calling thread* unless `LANDLOCK_RESTRICT_SELF_TSYNC` (v8, bit 3; kernel 7.0). Concretely: (a) applying a new-feature policy in the shared test process poisons every later test (or hits `E2BIG` at 64 composed rulesets — man-pages 6.19 `landlock_restrict_self(2)`); (b) TSYNC "applies the new Landlock configuration atomically to **all threads** ... irrespective of previously established Landlock domains and logging configurations on those threads" and propagates `no_new_privs` to siblings — running a TSYNC test inside a multithreaded Odin test runner sandboxes the whole runner; (c) `fork()` from a multithreaded process can deadlock the child on allocator locks held at fork time (the existing suite already mandates `ODIN_TEST_THREADS=1`); (d) tests that log to freshly opened files *after* applying a restrictive policy fail with confusing EACCES from the test framework itself, not the code under test.

**Why it happens:**
New dimensions tempt teams into adding checks to the shared-process unit suite instead of the fork-per-check harness, and TSYNC looks like "just another flag" — its process-wide blast radius is invisible until a multithreaded runner.

**How to avoid:**
- Preserve the invariant: fake-ops unit tests never enforce; every real-kernel enforcement check forks one child per check (existing conformance pattern). New rule types (capability/namespace) and new flags (NO_NEW_PRIVS, quiet) get their own `fork_check`s in the probe.
- TSYNC gets a dedicated integration test that *is* deliberately multithreaded (spawn threads, apply with TSYNC, verify all threads restricted; verify without TSYNC siblings stay unsandboxed) — run as its own process, not inside the shared suite.
- Pre-open logging fds before fork/apply; communicate results via `waitpid` exit codes (existing `CHILD_*` protocol), never post-restrict file writes.

**Warning signs:**
Flaky tests that only fail when run with other tests; CI ordering-dependent failures; a test passing on the dev machine (single-threaded) but failing in CI (threaded runner); "address already in use"-style errors after an earlier test handled `BIND_TCP`/`BIND_UDP`.

**Phase to address:**
Test-harness decisions in the first implementation phase; TSYNC-specific test in the restrict-flags feature phase.

---

### Pitfall 6: errno/cause misclassification for new failure modes; conflating status with error kind

**What goes wrong:**
The existing `apply_result_for_errno` map (ENOSYS→`Unavailable`, EOPNOTSUPP→`Disabled`, EPERM→`Permission_Denied`) must be extended, and the new errnos have *different remediation semantics* that matter to callers: `EOPNOTSUPP` = "Landlock built in but disabled at boot (`lsm=`)" — user-fixable; `ENOSYS` = kernel < 5.13 — permanently unavailable; `ENOMSG` (create_ruleset, empty handled set) and `EINVAL` (unknown flag/access/scope; too-small size) = *binding bugs*, not environment problems — they should surface as internal/validation errors, never as "kernel too old"; `EAFNOSUPPORT` (net rule but TCP/UDP unsupported by kernel build) = per-feature unavailability (man-pages 6.19 errno tables, all three syscalls). A second trap: putting *why* into `status` (or *outcome* into `error.kind`) — e.g. returning `Not_Enforced` with no error for a best-effort omission, or `Enforced` with a dangling error field. The architecture doc's contract: reason lives in `Policy_Error.kind`, coarse outcome in `Policy_Status`.

**Why it happens:**
Copy-pasting the existing errno switch when adding v10–v12 call sites instead of consulting each syscall's errno table (they differ per syscall).

**How to avoid:**
- Maintain one errno→(kind, cause) table per syscall site, with a unit test per (errno, site) via the fake ops seam; every table entry cites the man-page errno.
- Classify *before* syscall where possible: ENOMSG (empty rule / empty handled set) and EINVAL (unknown bits, bad port >65535, non-dir fd for dir-only rights) should be caught by builder validation so the kernel only ever sees valid calls — kernel EINVAL then genuinely means a binding bug.
- Keep `raw_errno` verbatim alongside classification so callers can distinguish, and add the new cause strings (boot-config fix hint for EOPNOTSUPP).

**Warning signs:**
Integration tests see `EINVAL` from a real kernel (should be impossible post-validation); `Unsupported_Feature` reported for a kernel-support problem or `Unavailable` for an lsm-boot problem; an errno path in the fake ops with no corresponding classification test.

**Phase to address:**
Each feature phase adds its errnos; a dedicated pass in the conformance phase cross-checks the table against the man pages.

---

### Pitfall 7: Platform-stub leaks — new kernel surface breaks non-Linux cross-compiles

**What goes wrong:**
Every new syscall wrapper (`add_namespace_rule`, `add_capability_rule`, errata probe, `create_ruleset` variants) and every new `Apply_Ops` member must exist in both `syscall_linux.odin` and `syscall_unsupported.odin`. Miss the stub → `#build !linux` targets fail to compile. This breaks (a) the repo's cross-compile CI checks, (b) any consumer's multi-platform build, and (c) `landlock_test_unsupported.odin`, which validates the `Unsupported_Platform` result path. The leak surfaces only on non-Linux targets, so a Linux-only dev loop never sees it.

**Why it happens:**
Linux-only iteration; stubs feel like dead weight; new `Apply_Ops` members get default bindings but not stub bindings.

**How to avoid:**
- Rule: any PR touching `syscall_linux.odin` must touch the stub file in the same commit — enforce by review checklist and by CI cross-compiling *all* packages (root lib, examples, rules-demo, abi-conformance tool) for at least windows and mac before merge.
- Keep the fake ops and stub returns aligned: unsupported platforms still return `Unsupported_Platform` policy results, so unit tests on non-Linux keep passing without changes.

**Warning signs:**
Green local builds, red cross-compile CI; "undefined proc" link errors on `#build !linux`; the unsupported-platform test suite failing to compile.

**Phase to address:**
Every feature phase (same-commit rule); verified by the existing cross-compile CI job on every merge.

---

### Pitfall 8: TOCTOU and path-resolution bugs when opening rule paths

**What goes wrong:**
The builder validates paths eagerly with `stat` (`path_validation_stat`, symlink policy, kind match), but the O_PATH fd is opened at *apply* time — a window where the path can be swapped (symlink flip, file→dir change, replacement), so the enforced rule binds to a different inode than the caller approved. Kernel resolution has its own traps: `RESOLVE_NO_SYMLINKS` fails with `ELOOP` if *any* component is a symlink — on merged-/usr distros common paths like `/bin` → `/usr/bin` will spuriously fail (man-pages 6.19 `openat2(2)` explicitly advises making it configurable "unless used for a specific security purpose"); `RESOLVE_BENEATH`/`RESOLVE_IN_ROOT` can return `EAGAIN` on a suspected `..` escape race and the caller must retry; magic links (`/proc/pid/fd/*`) are only *incidentally* disabled by `RESOLVE_BENEATH`/`IN_ROOT` today ("this may change") — explicit `RESOLVE_NO_MAGICLINKS` is required; a path existing at validate time and vanishing at apply time must classify as an omission (`ENOENT` → `.Ignore` policy) rather than a fatal error.

**Why it happens:**
Validation-time checks (stat) are confused with enforcement-time identification (the fd); openat2's flag semantics are finer-grained than openat's (unknown flags are errors, not ignored).

**How to avoid:**
- Re-verify identity at open time: open O_PATH, then `fstat` the fd (type, dev/ino optionally) and compare with builder-time expectations; mismatch → typed error/omission. When the toolchain floor allows it, gate `OPENAT2_REGULAR` (new in Linux 7.2, openat2(2)) for regular-file rules so the kernel enforces file-type at resolution.
- Keep symlink policy explicit per rule (existing `Path_Options`), default `RESOLVE_NO_MAGICLINKS` always on, implement the `EAGAIN` retry loop for `RESOLVE_BENEATH`/`IN_ROOT` (bounded retries).
- Classify open failures: `ENOENT` → omission per missing-path policy; `ELOOP` under `RESOLVE_NO_SYMLINKS` → typed validation failure suggesting the symlink knob, not a raw errno.

**Warning signs:**
Tests that create paths, apply, then mutate the path before apply (none exist yet — add adversarial ones); user reports of `/bin`-style rules failing only on merged-usr systems; `ELOOP` surfacing as `Invalid_Policy` on legitimate setups.

**Phase to address:**
Path-handling feature phase; adversarial race tests in the integration phase.

---

### Pitfall 9: New-dimension semantic traps inside the kernel model (UDP ephemeral binds; RESOLVE_UNIX asymmetry)

**What goes wrong:**
Two post-v9 features have non-obvious semantics that break *correct-looking* policies:
- **UDP:** granting `CONNECT_SEND_UDP` to port 53 still fails for DNS clients, because sending a datagram auto-binds an ephemeral source port — you must also grant `BIND_UDP` on **port 0** ("any port in the ephemeral range") or the app must bind before sending (docs.kernel.org Oct 2026 note + uapi header). A naive `allow_udp_send(port)` helper produces policies that break the very clients they target.
- **`LANDLOCK_ACCESS_FS_RESOLVE_UNIX` (v9):** it is an FS right that behaves like a scope — it only restricts connections to UNIX servers created *outside* the new domain, returns `EACCES` (unlike abstract-socket scope denials), and, when handled by default, **denies connecting to host services** (`/var/run/docker.sock`, `ssh-agent`, D-Bus) for every sandboxed consumer. A binding that flips it into `HANDLED_DEFAULT` without flagging the behavior change breaks apps while reporting `Enforced`.

**Why it happens:**
The deny-by-default model says "handle everything you know" — correct for security completeness, but each newly handled dimension changes runtime behavior of previously-working consumers.

**How to avoid:**
- Ship convenience builders that encode kernel guidance: `allow_udp_dns`-style helpers emitting port-0 `BIND_UDP` + port-specific `CONNECT_SEND_UDP`; document port-0 semantics in the builder.
- Make each new dimension's default-handled status an explicit, documented decision in the handled-set phase; call out RESOLVE_UNIX's host-socket breakage and the `EACCES`-vs-scope asymmetry in the summary output so `Partially_Enforced`/`Enforced` results explain *what is now denied*.
- Enforcement tests must use realistic clients: DNS query over UDP through libc resolver; connect to a UNIX socket created by a parent process (cross-domain) vs one created in-domain (must keep working).

**Warning signs:**
Integration tests bind to port 0 and fail; DNS resolution fails only under sandbox; consumer bug reports of the form "worked on v9-binding, now ssh-agent fails"; summary output listing a dimension the user never asked about.

**Phase to address:**
The UDP and RESOLVE_UNIX/defaults decisions in their respective feature phases; behavior-change documentation in the docs phase.

---

### Pitfall 10: Errata misuse — probing errata bits and disabling the sandbox

**What goes wrong:**
New kernel surface: `LANDLOCK_CREATE_RULESET_ERRATA` (flag 2) returns a bitmask of fixed errata (4 documented: TCP-socket identification overreach; scoped-signal blocking same-process threads (libpsx); disconnected-directory REFER widening; whiteout creation now `MAKE_REG`). The kernel doc warns: "Most applications should NOT check errata ... disabling the sandbox when an erratum is not fixed could leave the system less secure than using Landlock's best-effort protection." A binding (or its conformance probe) that gates features or application support on errata bits either weakens protection or fails probes on older-but-fine kernels.

**Why it happens:**
Errata look like a clean capability signal; it's actually a "this kernel had bug X, now fixed" notice for userspace *behavioral* workarounds.

**How to avoid:**
- Library: don't consult errata at all for enforcement decisions (surface it via the probe tool/debug output only).
- Conformance probe: assert *behavior* (e.g. SCTP socket not restricted by TCP rules on erratum-1-fixed kernels), never errata bits, so the probe passes on kernels without the flag/mechanism.
- The library documents known errata-affected behaviors only if a consumer-visible semantic depends on them.

**Warning signs:**
Probe failures on stable-series kernels; code paths reading errata to choose between policies; docs recommending sandbox disablement on un-fixed errata.

**Phase to address:**
Conformance-probe phase (decide errata policy once, centrally).

---

### Pitfall 11: CI kernel-matrix staleness — conformance probe not updated with features; ABI head untestable on shipped kernels

**What goes wrong:**
Three failure modes: (a) features land but the probe (tools/abi-conformance) isn't extended, so CI is green while the new surface is entirely untested on real kernels — the probe and the library drift; (b) the matrix's distro kernels simply don't have ABI v10–v12 yet (v9 is kernel 7.1, v10+ are newer; man-pages VERSIONS table 2026-07-18), so "we tested ABI head" is false — jobs either skip or report `LANDLOCK_EXPECT_ABI` mismatch treated as warning; (c) virtme-ng's minimal kernels "are lacking lots of features" (virtme-ng docs) — if `CONFIG_SECURITY_LANDLOCK` isn't in the build config or `lsm=` doesn't include landlock, `create_ruleset` returns `EOPNOTSUPP` and every probe check silently no-ops.

**Why it happens:**
Feature work and CI-harness work live in different phases; the matrix is a static list of distro kernels while the ABI head moves with mainline.

**How to avoid:**
- Probe-first discipline: every feature phase must add its `fork_check`s to the probe in the same merge train (acceptance criterion per feature), bump `LANDLOCK_EXPECT_ABI` usage deliberately, and keep `EXIT_ABI_MISMATCH` loud for jobs pinned to a version.
- Add a mainline job: build a mainline kernel in CI with virtme-ng (`vng --build` from a kernel tree, virtme-ng README/GitHub Actions support, retrieved 2026-11-09) with `CONFIG_SECURITY_LANDLOCK=y` and boot with `lsm=landlock`; that job is the only place ABI-head checks can actually run until distros ship the versions.
- Fail the probe hard if probed ABI < expected minimum for its checks — a probe that "passes" by skipping everything on an old kernel is worse than no probe (this is the same shape as the go-landlock GHSA: silence at the downgrade path).

**Warning signs:**
CI stays green across a feature burst; probe output shows fewer checks executed per kernel; a job's probed ABI is below the feature-introduction ABI; `dmesg` in the VM lacks "landlock: Up and running".

**Phase to address:**
CI/probe phase — but each feature phase must land probe checks (feature definition includes them).

---

### Pitfall 12: Toolchain-bump regressions — Odin nightly churn under the binding's load-bearing patterns

**What goes wrong:**
The milestone bumps dev-2026-05 → current nightly (dev-2026-11a, released ~2026-11-04; monthly releases carry BREAKING sections — e.g. dev-2026-11's `core:fmt` pad-width change). Specific hazards for this repo: (a) **bit_set internals churn** — dev-2026-10 changed bit_set backing (#7664, "Allow bit_set to be backed by arrays of integers"); the binding stores rights as `bit_set` and converts via `transmute` at the `Path_Access` ↔ `syscall.Access_FS_Flag` boundary (`path_access_to_syscall`) — a representation change silently requests wrong bits; (b) `core:sys/linux` surface moves: current master exposes only syscall *numbers* (`SYS_landlock_create_ruleset`=444, `SYS_landlock_add_rule`=445, `SYS_landlock_restrict_self`=446, `SYS_openat2`=437, pkg.odin-lang.org, retrieved 2026-11-09) and no typed landlock wrappers — the hand-rolled wrappers must stay; if a future nightly adds its own `openat2` proc, name collisions or duplicated semantics appear; (c) raw-syscall argument marshalling (packed structs, `uintptr` casts) breaks quietly if core internals change calling conventions.

**Why it happens:**
Odin core is a moving target by design (nightly pinning is the only stability contract); the repo's `transmute`-based distinct-type bridge is layout-sensitive and not checked by the type system.

**How to avoid:**
- Land the bump as its own phase before any feature work (per PROJECT.md decision) with the whole suite green; never mix toolchain churn into feature commits.
- Add bit-value truth tests: unit tests assert the *numeric* masks (e.g. `path_access_to_syscall(path_access_ro_dir) == 0b...` literal) so a representation change fails loudly rather than mis-requesting rights; keep the `#assert(size_of(...))` family for every attr struct.
- Pin the nightly in CI (and record the version in the probe output) so a silent toolchain drift in CI is visible; isolate any needed `core:sys/linux` usage behind the local `syscall` package (already the architecture).

**Warning signs:**
Suite failures after a purely toolchain PR; probe output ABI unchanged but enforcement behavior changed; `transmute` results differing between two nightlies in the bit-truth tests; compile errors mentioning duplicate openat2/landlock identifiers after a core update.

**Phase to address:**
Dedicated toolchain-bump phase at milestone start; bit-truth tests added there, kept forever.

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Passing one fixed ruleset-attr size for all ABIs | No size table needed | `E2BIG`/`EINVAL` per kernel version (Pitfall 3) | Never |
| `abi >= N` range checks instead of cumulative mask chain | Less code, looks simpler | Next inserted bit silently falls in the wrong version; no compile-time tripwire | Never (chain + `#assert` is the drift guard) |
| Masking capability/namespace rule members down to kernel-known bits (same as FS rights) | Symmetric-looking code | Breaks forward compatibility: rules that should allow future `CAP_*`/`CLONE_NEW*` members are stripped; permission bits are documented as silently-accepted-if-unknown (uapi header) | Never — this direction must NOT be masked |
| Testing new features only through fake `Apply_Ops` | Fast, no kernel needed | Enforcement semantics (handled-set denials, errno reality) never proven; GHSA-class bugs ship | Within a feature phase only; must not be the state at merge |
| Hardcoding `prctl(PR_SET_NO_NEW_PRIVS)` unconditionally after v11 support exists | Works everywhere | Loses the set-iff-success atomicity guarantee of `LANDLOCK_RESTRICT_SELF_NO_NEW_PRIVS`; NNP state can diverge from enforcement outcome (uapi header flag doc) | Only on ABI < 11 (gated), which is exactly the point of the flag |
| Skipping stub/cross-compile run "until the end" | Faster Linux iteration | Broken `!linux` targets discovered late across many commits | Never; cross-compile is the existing CI gate |
| Probe "passes" by skipping checks when ABI < expected | Green CI on old kernels | False conformance signal — same silence-shape as the go-landlock downgrade bug | Never; use explicit `EXIT_ABI_MISMATCH` |

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| `core:sys/linux` (Odin) | Assuming typed landlock/openat2 wrappers exist and waiting on upstream | Today only `SYS_*` numbers exist (pkg.odin-lang.org, 2026-11-09); keep hand-rolled wrappers in local `syscall` package; re-check each nightly for newly added wrappers (collision risk) |
| virtme-ng VMs | Booting minimal kernels without `CONFIG_SECURITY_LANDLOCK` or `lsm=landlock` → `EOPNOTSUPP` everywhere | Verify "landlock: Up and running" in dmesg before checks; build config with Landlock enabled (kernel doc NOTES: `lsm=` must contain landlock) |
| Kernel audit subsystem | Surprised by denied-access audit noise in VM tests; or setting `LOG_*` flags hardcoded (kernel doc: `LOG_SUBDOMAINS_OFF` "should be set according to runtime configuration, not hardcoded") | Flags are policy knobs surfaced through the builder; VM jobs expect audit records; consider `LOG_SAME_EXEC_OFF` for noisy probe domains deliberately |
| Merged-/usr distro roots | `RESOLVE_NO_SYMLINKS` policies break on `/bin → /usr/bin` | Symlink policy per-rule and configurable; document (openat2(2) advises configurability) |
| Runtime REFER constraints | Assuming add-rule-time success means renames/links will work | `EXDEV`/`EACCES` are *runtime* outcomes of REFER constraints (EACCES takes precedence); document in `allow_path` docs; tests must exercise cross-directory rename under REFER |
| Port >65535 / port 0 | Passing host-order port without range check | Builder validates ≤65535 (kernel EINVALs otherwise); port 0 = ephemeral-range meaning for `BIND_TCP`/`BIND_UDP` (landlock_add_rule(2), uapi header) |

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| One `add_rule` syscall per path/port for wide policies | Slow policy setup (each rule = syscall + O_PATH open/close); noticeable in VM probes and container-style usage | Aggregate sibling rights into parent-directory rules where semantics allow (kernel doc "Good practices": prefer leaves, self-sufficient hierarchies); tests don't need 1000s of rules | Policies with hundreds of rules; probe runtime in per-kernel jobs |
| Repeated `restrict_self` calls in one process | `E2BIG` at 64 composed rulesets (`landlock_restrict_self(2)`) | One ruleset per policy (kernel doc explicitly advises); test harness forks per check anyway | Long-lived processes applying repeatedly; accidental restrict-in-loop bugs |
| Per-apply ABI probe + size-table lookups | None (two cheap syscalls + table select) | Keep as-is; never cache the ABI across processes | N/A — listed to prevent premature "optimization" |

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Handling `NAMESPACE_USE` without `CAPABILITY_USE` (or vice versa) | User-ns creation grants all caps inside it; "gating only one of the two leaves a kernel attack-surface widening path open" (docs.kernel.org Oct 2026) | Builder validation warns/errors on half-handled permission pairs; enforcement tests cover `unshare(CLONE_NEWUSER)` + capability exercise |
| Trusting `capget(2)` to verify capability policy | Capabilities may be held but denied at exercise time; "any denied capability will fail with EPERM when exercised ... Do not rely on capget" (docs.kernel.org Oct 2026) | Enforcement tests exercise actual operations; summaries describe handled bits, not observed creds |
| Blanket quiet lists (`quiet_capabilities` etc. set to "all known members") | Hides surprising future denials from audit ("never a blanket set" — docs.kernel.org Oct 2026); `LANDLOCK_ADD_RULE_QUIET` must be subset of handled bits (uapi header) | Quiet only caller-specified members; validate quiet ⊆ handled at builder time |
| Leaving `no_new_privs` unset when running privileged (CAP_SYS_ADMIN path) | Sandboxed process can still exec setuid/file-cap binaries → confused deputy (docs.kernel.org Oct 2026) | Default to NNP-on (or v11 flag); document the CAP_SYS_ADMIN exception as discouraged |
| Assuming TRUNCATE coverage means no content-shortening | `fallocate(FALLOC_FL_COLLAPSE_RANGE)` shortens files without TRUNCATE right (docs.kernel.org Oct 2026) | Document known bypass surface; don't claim more than the kernel enforces (fail-closed honesty is the repo contract) |
| Binding itself stat-then-open on rule paths | The sandbox tool is its own TOCTOU victim; enforces rule on swapped inode (Pitfall 8) | fd-identity re-verification at open; `OPENAT2_REGULAR` when gated-available |
| Ignoring the always-denied REFER special case | Even "fully permissive" ABI v1 rulesets deny reparenting → apps break mysteriously with EXDEV | Gate REFER-dependent helpers on ABI ≥ 2 (gnoack article Case 2: give up or degrade); document in builder docs |

## UX Pitfalls

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| Best-effort omissions invisible in default output | User believes UDP/namespaces are sandboxed when they're not (GHSA-shaped outcome) | Default summary lists applied vs omitted dimensions explicitly; `is_enforced` remains the fail-closed gate; `Partially_Enforced` always carries omission detail |
| New handled dimensions silently change app behavior (host UNIX sockets, UDP ephemeral) | "It worked before the library update" bug reports | Changelog + summary note every dimension newly handled; opt-out knobs (`handle_*` subset) documented per dimension |
| Raw errno strings as diagnostics (`EOPNOTSUPP` printed bare) | User can't tell "too old kernel" from "boot config disabled Landlock" | Cause strings with remediation: EOPNOTSUPP → "enable lsm=landlock in boot config"; ENOSYS → "kernel < 5.13" |
| `debug_summary` growing past fixed cap silently truncated | Security report that omits omissions looks complete | Existing design already refuses to truncate (`DEBUG_SUMMARY_CAP`) — extend cap/fields when adding dimensions; never regress to clipping |

## "Looks Done But Isn't" Checklist

- [ ] **New FS/net/scoped/permission bit:** present in `HANDLED_DEFAULT` *and* in its cumulative `ABI_*_V{N}` table *and* has a must-deny enforcement test — verify bit-numeric truth test exists (transmute bridge), not just compile.
- [ ] **Ruleset attr:** per-ABI size table updated; `create_ruleset` fake records the size passed per probed ABI — verify E2BIG/EINVAL impossible per kernel doc errno table.
- [ ] **Restrict flags:** each new flag (NO_NEW_PRIVS bit 4) gated by ABI version, surfaced in `flags_applied`/`flags_omitted`, and classified in the errno table (`EINVAL` on unknown flag for old kernels) — verify a pre-v8 kernel test for flag masking.
- [ ] **New rule types (namespace/capability):** stubs for `!linux`, `Apply_Ops` members, fake coverage, builder validation (ENOMSG pre-check: allowed ∪ quiet ≠ 0; raw-input semantics documented), must-deny fork_check in probe — verify all five.
- [ ] **UDP helpers:** port-0 ephemeral-bind guidance encoded; DNS-style integration check passes — verify `connect()` after send-path fails without `BIND_UDP` port 0 rule.
- [ ] **RESOLVE_UNIX:** handled-set decision documented; in-domain vs cross-domain UNIX server tests both exist — verify cross-domain connect denied, in-domain connect allowed.
- [ ] **Conformance probe:** check count per kernel printed; probe fails if probed ABI < checks' minimum; `LANDLOCK_EXPECT_ABI` still meaningful; mainline-kernel CI job exists for ABI head — verify probe output lists every new check.
- [ ] **Cross-platform:** `odin build` for windows+darwin (or per existing matrix) of lib + examples + tools green on the feature branch — verify `syscall_unsupported.odin` diff parity in review.
- [ ] **Toolchain:** pinned nightly recorded in CI output; bit-truth and attr-size `#assert`s pass; no identifier collisions with `core:sys/linux` — verify on the exact nightly, not "whatever resolves".
- [ ] **Docs:** README coverage table updated past v9 (v10–v12), summary/errors docs mention new causes — verify docs claim only what enforcement tests prove.

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Gating drift found post-merge (feature dead on some kernels) | MEDIUM | Fix table + tripwire; add per-ABI expected-mask unit table; re-run full kernel matrix; audit sibling dimensions for same mistake |
| GHSA-class downgrade bug (dimension silently unhandled) shipped | HIGH | Fix; treat as security patch (advisory, version bump, disclosure precedent: GHSA-vv6c-69r6-chg9); add must-deny enforcement test for that dimension on real kernel; CI fails hard on probe-skip |
| Attr-size E2BIG/EINVAL in the field | LOW–MEDIUM | Ship per-ABI size table fix; add fake-ops size assertion so unit tests catch it forever; no user data affected (fail-closed error path) |
| Shared-process pollution / TSYNC blast radius in test suite | MEDIUM | Move offending checks to fork-per-check harness; add multithreaded TSYNC test as isolated process; enforce `ODIN_TEST_THREADS=1` scope for the shared suite |
| Misclassified errno (wrong cause/kind) | LOW | Correction is additive; add (errno, site) unit case; check consumers relying on old kind values (semver note) |
| TOCTOU swap discovered in path handling | MEDIUM | Add fd-identity re-verification; adversarial test (swap between validate and apply); consider `OPENAT2_REGULAR` gating; release note on the fix |
| CI matrix silently lacks ABI-head kernels | MEDIUM | Add vng `--build` mainline job with Landlock config; make probe exit loud on ABI below check minimum; publish which ABIs each job actually covers |
| Nightly bump broke bit-bridges silently | HIGH if found late | Bit-truth tests localize immediately; fix `transmute` boundary or replace with explicit mask construction; re-run enforcement matrix before any further feature work |

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| 1. Gating-table drift | Syscall/ABI layer | Per-ABI expected-mask unit table; `#assert` tripwires compile-fail |
| 2. Handled-set gaps | Policy layer | Must-deny enforcement tests per dimension on real kernels |
| 3. Attr size drift | Syscall/ABI layer | Fake-ops size assertion + size-table unit test |
| 4. Downgrade-path drops | Policy layer | Rule×ABI matrix unit test: masked-or-omitted, never empty-rule |
| 5. Irreversible test traps | Harness setup (early) + TSYNC feature phase | Single-threaded shared suite; fork-per-check; isolated multithreaded TSYNC test |
| 6. errno misclassification | Each feature phase | (errno, site) classification unit cases; builder pre-validation kills EINVAL/ENOMSG |
| 7. Platform-stub leaks | Every feature phase | Cross-compile CI job on every merge |
| 8. TOCTOU/path resolution | Path-handling phase | Adversarial swap tests; openat2 flag behavior tests; EAGAIN retry |
| 9. UDP/RESOLVE_UNIX semantics | UDP & FS-dimension phases | DNS-over-sandbox test; cross/in-domain UNIX socket tests |
| 10. Errata misuse | Conformance phase | Probe asserts behavior, not bits; grep gate: no errata in enforcement code |
| 11. CI matrix staleness | CI/probe phase | Mainline vng build job; probe prints per-kernel check count; loud ABI-mismatch exits |
| 12. Toolchain bump | Dedicated phase at milestone start | Whole suite green on pinned nightly; bit-truth + size asserts; nightly recorded in CI |

## Sources

- **docs.kernel.org — "Landlock: unprivileged access control"** (kernel doc, dated October 2026; retrieved 2026-11-09): post-v9 ABI switch example (v9 RESOLVE_UNIX, v10 UDP, v11 NO_NEW_PRIVS, v12 permission rules), handled_permissions/capability/namespace model, UDP port-0 note, errata 1–4 + "most applications should NOT check errata", TSYNC/NNP flag semantics, good practices, NNP rationale. https://docs.kernel.org/userspace-api/landlock.html
- **man-pages 6.19** (HTML rendered 2026-09-09): `landlock(7)` VERSIONS table v1–v9 with kernel versions (2026-07-18); `landlock_create_ruleset(2)` errno table incl. E2BIG/EINVAL size semantics, ENOMSG empty-accesses (2026-04-21); `landlock_add_rule(2)` errno table incl. ENOMSG empty rule, EINVAL subset/port/non-dir, EAFNOSUPPORT (2026-05-04); `landlock_restrict_self(2)` flag semantics v7/v8, E2BIG 64-layer limit (2026-05-04); `openat2(2)` RESOLVE_* flags, EAGAIN retry, ELOOP, OPENAT2_REGULAR since Linux 7.2 (2026 pages).
- **`include/uapi/linux/landlock.h`** (torvalds/linux master, retrieved 2026-11-09): exact bit positions (FS_RESOLVE_UNIX=1<<16; NET_BIND_UDP=1<<2, NET_CONNECT_SEND_UDP=1<<3; RESTRICT_SELF_* bits 0–4; PERMISSION_* bits 0–1), ruleset attr 7 fields (quiet_* since v10, handled_permissions v12), namespace/capability attr layouts with ENOMSG raw-input-check semantics and unknown-bit forward-compat rules, LANDLOCK_ADD_RULE_QUIET, LANDLOCK_CREATE_RULESET_ERRATA.
- **GHSA-vv6c-69r6-chg9** (go-landlock advisory, 2024-10-14): best-effort mode with V4/V5 "did not restrict TCP bind and connect operations"; fix commit fb3ad84.
- **gnoack, "ABI versions and matching access rights"** (blog.gnoack.org, retrieved 2026-11-09): clamp-to-highest-known pattern, rule masking `allowed_access &= handled`, REFER's divergent fallback (Case 1 vs 2), skip-empty-rule pattern.
- **go-landlock** README (retrieved 2026-11-09): `V11` versioned configs, BestEffort mode, dedicated kernel-matrix CI workflow (`kernels.yml`).
- **rust-landlock** CHANGELOG (docs.rs, retrieved 2026-11-09): per-ABI staged releases (v0.4.0 ABI 4 net, v0.4.1 ABI 5 IoctlDev, v0.4.2 ABI 6 scopes) — evidence that each ABI dimension required deliberate handled-set/API extension.
- **kernsec mailing list** (Feb 2025): "landlock: Multithreading support for landlock_restrict_self()" RFC — pre-TSYNC thread model discussion.
- **Odin** pkg.odin-lang.org/core/sys/linux (retrieved 2026-11-09): only `SYS_landlock_*` numbers (444/445/446 amd64) and `SYS_openat2` (437) exist; no typed landlock/openat2 wrappers. Odin releases dev-2026-06/-10/-11 (GitHub, retrieved 2026-11-09): monthly BREAKING sections; dev-2026-10 #7664 bit_set backing change; dev-2026-11a current nightly (~2026-11-04).
- **virtme-ng** README/PyPI (retrieved 2026-11-09): `vng --build` kernel building, GitHub Actions usage, "kernels produced with virtme-ng are lacking lots of features" caveat.
- **Existing repo safeguards** (context only, not re-researched): `.planning/codebase/ARCHITECTURE.md` (2026-11-09) — `#assert` tripwires, `Apply_Ops` seam, fork-per-check conformance, `HANDLED_DEFAULT` model.

---
*Pitfalls research for: Odin bindings to the Linux Landlock kernel ABI, extended to the current ABI head (v10–v12 + errata)*
*Researched: 2026-11-09*
