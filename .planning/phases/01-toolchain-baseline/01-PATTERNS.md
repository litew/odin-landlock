# Phase 1: Toolchain Baseline - Pattern Map

**Mapped:** 2026-11-09
**Files analyzed:** 6 (3 modify, 1 create, 2 conditional/expected-no-op)
**Analogs found:** 5 / 6 (1 research-sourced)

## Phase Shape (why the analog set is small)

Phase 1 is a toolchain-bump phase: pin CI to `dev-2026-11a` (D-01), document the pin in README (D-02), build a sha256-verified podman image as the local gate substrate (D-03), then run the D-08 gate. Research verdict: **expected source diff is empty** (every imported `core:*` API verified present at `dev-2026-11`; D-04 resolves to a documented no-op). The only *certain* edits are two workflow one-liners, one README block, and one new Containerfile. `syscall/syscall_linux.odin` and any call-site fixes are **conditional only** (D-04/D-05/D-06) — the planner should plan them as "run the gate, fix what it reports", not as designed changes.

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `.github/workflows/ci.yml` (modify :22-26) | config (CI pipeline) | batch (build/test pipeline) | itself — `laytan/setup-odin@v2` block at :22-26 | exact (2-line edit inside existing block) |
| `.github/workflows/kernel-matrix.yml` (modify :44-48) | config (CI pipeline) | batch | identical block in `ci.yml` :22-26 | exact (same edit, second site) |
| `README.adoc` (modify :19-20) | docs (vendoring/toolchain note) | static doc | its own toolchain note :19-20 + doc-probe contract in `ci.yml` "README example compiles" step | exact (in-place block replace) |
| `Containerfile` (create, repo root) | config (container image build) | batch + file-I/O (fetch/verify/extract tarball) | none in repo → RESEARCH.md Pattern 2 recipe (podman 6.1.3-verified) | none (research-sourced) |
| `syscall/syscall_linux.odin` (conditional, expected no-op) | service (syscall wrapper layer) | request-response (syscall → `os.Error`) | itself + guard rails in `syscall/syscall.odin` `#assert` chain | exact / no-op expected |
| call-site warning fixes (`landlock.odin`, `landlock_test_linux.odin`, ...) (conditional, expected empty) | library/test | n/a | `landlock_test_linux.odin:279-283` expectation style | role-match |

All analog paths above verified git-tracked via `git ls-files` (2026-11-09). No mirror/gitignored paths used.

---

## Pattern Assignments

### `.github/workflows/ci.yml` (config, batch)

**Analog:** itself — the pin lives in the existing setup-odin block; every other step is *unchanged* and constitutes the canonical D-08 gate list.

**Current block to edit** (lines 22-26, verbatim; grep-confirmed anchors — `release:` is line 26):
```yaml
      - name: Install Odin (latest monthly release)
        uses: laytan/setup-odin@v2
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          release: latest
```

**Target block** (D-01; RESEARCH.md "CI pin" example):
```yaml
      - name: Install Odin (pinned nightly)
        uses: laytan/setup-odin@v2
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          release: dev-2026-11a   # was: latest
```

**Edit discipline:** change only the step `name:` (optional cosmetic) and the `release:` value. Keep `token:` and indentation exactly as-is — the action's `release:` input semantics ("download a tagged GitHub release with this name") are what makes an exact tag work.

**Gate steps to keep verbatim** (these are the D-08 gate; whole-file read, verbatim):
```yaml
      - run: odin version
      - run: odin report   # toolchain/LLVM info for debugging CI failures

      - name: Compile check
        run: odin check . -no-entry-point

      - name: Unit tests (landlock)
        run: odin test . -define:ODIN_TEST_FANCY=false

      - name: Unit tests (syscall)
        run: odin test syscall -define:ODIN_TEST_FANCY=false

      - name: Build example
        run: odin build examples -out:/tmp/example

      - name: README example compiles
        run: |
          mkdir -p _docprobe
          awk '/^\[source,odin\]/{f=1;next} f&&/^----$/{c++; if(c==1)next; if(c==2)exit} c==1{print}' \
            README.adoc > _docprobe/main.odin
          sed -i 's#import landlock$#import landlock ".."#' _docprobe/main.odin
          odin build _docprobe -out:/tmp/docprobe
          rm -rf _docprobe

      - name: Integration test (real kernel, best-effort)
        run: |
          grep -q landlock /sys/kernel/security/lsm \
            && echo "landlock present in LSM stack" \
            || echo "landlock NOT in LSM stack -> integration test will skip"
          odin test . -define:LANDLOCK_INTEGRATION=true -define:ODIN_TEST_THREADS=1

      - name: Cross-target compile check (POSIX stubs)
        run: |
          odin check . -no-entry-point -target:darwin_amd64
          odin check . -no-entry-point -target:freebsd_amd64
```
Note the flag boundaries: `-no-entry-point` only on `check` steps (it is registered check-only in the compiler); `-define:` pairs on test steps; `-out:` on builds to `/tmp`.

---

### `.github/workflows/kernel-matrix.yml` (config, batch)

**Analog:** `ci.yml:22-26` (identical block).

**Current block to edit** (lines 44-48, verbatim; grep-confirmed anchors):
```yaml
      - name: Install Odin (latest monthly release)
        uses: laytan/setup-odin@v2
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          release: latest
```
Apply the same `release: dev-2026-11a` value (and optional same step rename). This workflow is *not* on the push path (`workflow_dispatch` + weekly cron + label-gated PR), so a green pin here is verified only when it runs; the conformance binary is built on the runner host immediately after the pin step (`Build conformance binary (host)` → `odin build tools/abi-conformance -out:abi-conformance`, lines 50-51), so the pin directly governs it.

---

### `README.adoc` (docs, static)

**Analog:** its own current toolchain note.

**Current note to replace** (lines 19-20, verbatim):
```adoc
Tested with Odin `dev-2026-05` nightly. The package depends on `core:sys/linux`
(including a hand-rolled `openat2` wrapper), so pin an Odin version when vendoring.
```

**Target structure** (D-02: tag + exact `odin version` string + artifact name + sha256; wording inside the block is Claude's discretion):
```adoc
Tested with Odin `dev-2026-11a` nightly (hotfix of dev-2026-11, 2026-11-03).
The package depends on `core:sys/linux` (including a hand-rolled `openat2`
wrapper), so pin an Odin version when vendoring.

Pinned toolchain identity:
* tag: `dev-2026-11a`
* `odin version`: dev-2026-11a:<hash recorded from first pinned run>
* linux-amd64 artifact: `odin-linux-amd64-dev-2026-11a.tar.gz`,
  sha256 `65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618`
```
The `<hash recorded from first pinned run>` placeholder is filled from `odin version` executed in the container (first D-08 run) — record whatever the binary actually prints.

**Hard constraint (Pitfall 7):** the doc-probe extracts the *first* `[source,odin]` block (the minimal-example block under `== Example`, currently starting ~line 28). Do not restructure that block or the `----` fences while editing the note at :19-20, or the CI "README example compiles" step breaks independently of the build. Keep the vendoring rationale sentence (`core:sys/linux` + hand-rolled openat2) — it is still true at `dev-2026-11` (D-4 verdict: nothing to adopt).

---

### `Containerfile` (new file, repo root — config, batch/file-I/O)

**Analog:** none — repo has zero container/image files. Use RESEARCH.md Pattern 2 verbatim (verified this session against podman 6.1.3, SELinux-enforcing host, default seccomp allowlist):

```dockerfile
# Containerfile (odin-dev-2026-11a)
FROM docker.io/library/fedora:latest
RUN dnf install -y curl clang && dnf clean all
ARG ODIN_SHA256=65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618
RUN curl -fsSL -o /tmp/odin.tar.gz \
      https://github.com/odin-lang/Odin/releases/download/dev-2026-11a/odin-linux-amd64-dev-2026-11a.tar.gz \
 && echo "${ODIN_SHA256}  /tmp/odin.tar.gz" | sha256sum --check - \
 && mkdir -p /opt/odin && tar -xzf /tmp/odin.tar.gz -C /opt/odin --strip-components=1 \
 && rm /tmp/odin.tar.gz
ENV PATH="/opt/odin:${PATH}"
```

**Build/run invocations** (the durable phase-2/3/4 verification recipe):
```bash
podman build -t localhost/odin-dev-2026-11a .
podman run --rm -v "$PWD:/src:Z" -w /src localhost/odin-dev-2026-11a odin version   # record for README (D-02)
podman run --rm -v "$PWD:/src:Z" -w /src localhost/odin-dev-2026-11a odin check . -no-entry-point
```

**Pattern notes for the planner:**
- Repo-root location follows the flat layout (`landlock.odin` at root; no `build/` or `container/` dirs exist).
- The image never `COPY`s repo source (bind-mount at run) → no `.containerignore` needed; build context stays trivial.
- glibc base required (release binary is a glibc-linked ELF); `clang` required for the link step of `odin build`/`odin test`.
- `--strip-components=1` puts `odin`, `core/`, `vendor/`, `base/` under `/opt/odin`; the compiler auto-detects its root from the executable location.
- `:Z` for SELinux relabeling (host LSM list includes `selinux`).
- Default podman seccomp already allowlists `landlock_create_ruleset`/`add_rule`/`restrict_self` → integration test (D-09, best-effort) runs normally in-container with `-define:ODIN_TEST_THREADS=1`; NEVER add `--security-opt seccomp=unconfined`.
- Build once; reuse across Phases 2-4 (D-03 "define once, reuse").
- Anti-pattern (standing user rule): never install the toolchain on the host; host `~/.local/bin/odin` (`dev-2026-10-nightly:84bc3fc`) is deliberately not the gate.

---

### `syscall/syscall_linux.odin` (conditional — D-04 documented NO-OP; D-06 call-site fixes only)

**Analog:** itself + guard rails. Research verdict (record in the plan verbatim): at `dev-2026-11`, `core:sys/linux` still ships only syscall *numbers* (444-446, 437), no Landlock flags/attrs/wrappers, no `openat2`/`Open_How` wrapper (upstream TODO stubs unchanged), and no `O_PATH`/`.Path` member in `core:os`'s `File_Flag`. **Nothing to adopt; keep this file unchanged.**

**What must NOT be deleted ( excerpts with anchors):**
`open_path` O_PATH/TOCTOU rationale, lines 108-117:
```odin
// open_path opens a path as an O_PATH handle (the form landlock_add_rule wants).
// TODO: O_PATH does not exist anywhere in core:os until upstream adds it
// explicitly, so this must go through core:sys/linux and stay in this file.
//
// It always resolves via openat2; when no_follow is set (Path_Options.symlink ==
// .Reject) it adds RESOLVE_NO_SYMLINKS so no path component may be a symlink —
// full TOCTOU-resistant resolution, where O_NOFOLLOW would only guard the final
// component. openat2 (kernel 5.6+) predates Landlock (5.13+), so it is always
// available when Landlock is.
open_path :: proc(path: string, no_follow := false) -> (int, os.Error) {
```
`close_fd` rationale, lines ~145-148 (`raw_errno_from_os_error`-style errno preservation):
```odin
// close_fd closes a raw kernel fd from open_path or create_ruleset. New core:os API has
// no portable raw-fd close (it operates on ^File[->fd]), so closing also goes through
// core:sys/linux and stays in here.
close_fd :: proc(fd: int) -> os.Error {
```
`Open_How` + `RESOLVE_NO_SYMLINKS`, lines 97-106 (`@(private)` file-scope struct mirroring `struct open_how`).

**Guard rails (if anything in this file changes, these must still hold):** `syscall/syscall.odin` `#assert` drift tripwires — `:41` `size_of(Restrict_Self_Flags) == size_of(u64)`, `:76` `Access_FS_Flags`, `:85` `Access_Net_Flags`, `:94` `Scope_Flags`, `:109` `size_of(Ruleset_Attr) == RULESET_ATTR_SIZE`, `:117` `size_of(Path_Beneath_Attr) == 12`, `:124` `size_of(Net_Port_Attr) == 16`. A failing `#assert` after the bump = stop and investigate; never "fix" the assert (Pitfall 2).

**If D-06 warnings surface here:** fix at the call site, no opt-out flags (`-no-escape-analysis`, `-no-atomic-analysis`, `-vet-*` must NOT be added to gate commands), no shims (D-05/D-06). Any signature change must be mirrored in the stub twin — see shared pattern below.

---

### Conditional call-site fixes: `landlock.odin`, `landlock_test_linux.odin` (expected empty diff)

**Analog:** `landlock_test_linux.odin:279-283` — the expectation-update style D-05 edits would follow (and proof the repo is already compliant with the new 3-arg `os.make_directory_temp`):
```odin
make_test_temp_dir :: proc(t: ^testing.T) -> string {
	dir, err := os.make_directory_temp("", "odin-landlock-test-*", context.allocator)
	testing.expectf(t, err == nil, "make temp dir: %s", os.error_string(err))
	return dir
}
```
Pattern: errno-exact asserts via `os.error_string`, `context.allocator` passed explicitly. D-05 scope if it ever materializes: update expectations to new `core:fmt` defaults — but research verified the repo has **zero** width/precision directives, so no edit is expected. Plan one explicit "run gate, fix what it reports (call-site fixes only)" task; zero findings is the expected path.

---

## Shared Patterns

### Exact-tag pinning (D-01)
**Source:** `ci.yml:22-26` (edit site), RESEARCH.md Standard Stack (action.yml `release:` semantics)
**Apply to:** both workflow files; identical 5-line block.
```yaml
          release: dev-2026-11a   # was: latest
```
Never `latest`, never a commit hash; the tag names the asset URL, so pinning the tag is unambiguous.

### Fail-closed verification chain
**Source:** Containerfile `sha256sum --check -` (fails image build loudly) + `ci.yml` integration step's `grep -q landlock /sys/kernel/security/lsm` probe + `syscall/syscall.odin` `#assert` chain
**Apply to:** every verification surface in this phase — identity checks fail the build, they never warn.

### Gate-list mirroring (D-08)
**Source:** `ci.yml` gate steps (canonical) ↔ `.planning/codebase/TESTING.md` ↔ container runs
**Apply to:** the container gate must run the same command set:
```bash
odin check . -no-entry-point
odin test . -define:ODIN_TEST_FANCY=false
odin test syscall -define:ODIN_TEST_FANCY=false
odin build examples -out:/tmp/example
# README doc-snippet probe (awk/sed pipeline, unchanged from ci.yml)
odin test . -define:LANDLOCK_INTEGRATION=true -define:ODIN_TEST_THREADS=1   # best-effort, D-09
odin check . -no-entry-point -target:darwin_amd64
odin check . -no-entry-point -target:freebsd_amd64
```
No new flags, no new targets, no `-vet`/`-no-atomic-analysis` additions.

### Stub-twin symmetry
**Source:** `syscall/syscall_unsupported.odin:11-17, 52-58` (every Linux proc has a same-signature `#+build !linux` stub returning `os.Error(io.Error.Unsupported)` via `unsupported_platform_error :: proc "contextless"`)
```odin
open_path :: proc(path: string, no_follow := false) -> (int, os.Error) {
	return -1, unsupported_platform_error()
}
```
**Apply to:** only if a D-06 fix changes a `syscall_linux.odin` signature — mirror it in the stub twin or the `darwin_amd64`/`freebsd_amd64` cross-target checks fail. Platform split stays `#+build !linux` (no new patterns).

### No-shims / no-opt-outs (D-05 + D-06)
**Apply to:** all conditional source work. New-default fallout → update call sites/expectations; warnings → fixed at call site; never compatibility shims, explicit-width pinning, or `-no-escape-analysis`-style opt-out flags in gate commands.

---

## No Analog Found

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| `Containerfile` | config (container image) | batch + file-I/O | No container/image build files exist anywhere in the repo. Use the RESEARCH.md Pattern 2 recipe (verified against podman 6.1.3, SELinux host, seccomp allowlist); base image is Claude's discretion (fedora-family glibc base). |

## Metadata

**Analog search scope:** repo root, `.github/workflows/`, `syscall/`, `README.adoc` (whole-file reads of both workflows, `syscall_linux.odin`, `syscall_unsupported.odin`; targeted reads/greps of `README.adoc`, `syscall/syscall.odin`, `landlock_test_linux.odin`)
**Files scanned:** ~12; stopped at strong matches per persona early-stopping rule
**Tracked-source gate:** every named analog confirmed via `git ls-files` (2026-11-09)
**Pattern extraction date:** 2026-11-09

**Planner notes:**
- Expected source diff is **empty** — the deliverables are the two workflow pins, the README block, the Containerfile (+ image build), one green local gate run, and one green CI run (CI has been idle since 2026-08-10; the green run is new evidence, not re-confirmation; `001-config-build` branch pushes don't trigger it — use PR or `workflow_dispatch`).
- Mirror D-07 wording: Phase 1 evidence = existing suite + `#assert` chain passing on the pinned nightly; literal bit-value truth tests are Phase 2 work.
- Research open question 2 (`git rm --cached examples/examples`): optional chore, default skip, requires explicit user nod — flag it in the plan; never commit it silently.
