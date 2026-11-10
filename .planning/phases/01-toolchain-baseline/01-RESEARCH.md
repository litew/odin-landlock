# Phase 1: Toolchain Baseline - Research

**Researched:** 2026-11-09
**Domain:** Odin compiler nightly migration (dev-2026-05 → dev-2026-11a) with containerized local verification
**Confidence:** HIGH

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** CI pins the exact Odin release tag `dev-2026-11a` (hotfix release published 2026-11-03; its linux-amd64 artifact is byte-identical, same sha256, to `dev-2026-11`) via `laytan/setup-odin@v2` `release:` input — replacing today's floating `release: latest` in **both** `.github/workflows/ci.yml` and `.github/workflows/kernel-matrix.yml`. Verified live: the `dev-2026-11` release exists with downloadable `odin-linux-amd64-dev-2026-11.tar.gz` artifacts, so the action's release-artifact path (no source build) works.
- **D-02:** README documents the pinned tag, the exact `odin version` string of the pinned binary, and the release artifact sha256, so vendoring users can verify bit-identical toolchains.
- **D-03:** Local verification runs inside a **podman container** whose toolchain source is the pinned release tarball (sha256-verified at image build), NOT the host's `~/.local/bin/odin` (currently `dev-2026-10-nightly:84bc3fc`, one month stale). User explicitly chose the container route over downloading the tarball to a user dir (their standing rule: read-only atomic host, tooling in containers).
- **D-04:** **Adopt new `core:*` surface now** — wherever `dev-2026-11` ships what a hand-rolled wrapper covers (e.g. `O_PATH`/openat2 paths via `core:os`/`core:sys/linux`), delete the local wrapper and use core. Bounded by what the nightly actually ships: the Landlock syscalls themselves stay hand-rolled where core still lacks surface. — **Reversibility:** costly.
- **D-05:** **Ride new defaults** for intentional core behavior changes (notably the `core:fmt` pad-width change): update call sites and test expectations to the new behavior; no compatibility shims and no explicit-width pinning to preserve old output. The project pins one nightly; callers get what the pin produces.
- **D-06:** "Builds clean" means **zero warnings AND zero errors** — all deprecation warnings surfaced by `dev-2026-11` are fixed in this phase, not tolerated.
- **D-07:** Roadmap success criterion 3 ("numeric bit-value truth tests pass") is satisfied in Phase 1 by the **existing suite + `#assert` chain passing on the new nightly** — no new literal-value tests are authored in this phase. Literal bit-value truth tests for existing v1–v9 constants are **deferred to Phase 2**, joining the per-dimension `#assert` tripwire work (Phase 2 criterion 3) where v10/v11 constants land alongside. **Planner should mirror this wording** (and may update the roadmap criterion text) so the verifier accepts existing-coverage evidence instead of expecting new test files.
- **D-08:** Phase gate = locally (container) AND in CI: `odin check . -no-entry-point`, both unit suites (`odin test .`, `odin test syscall`), example build, README doc-snippet compile probe, darwin_amd64 + freebsd_amd64 cross-target checks — all green on the pinned nightly. Cross-target set stays as-is (no new targets).
- **D-09:** The real-kernel integration test stays **best-effort** in the gate: it runs where the environment permits (host kernel 7.2 has Landlock; CI runners don't, so CI skips as today) but a real-kernel run is not a hard phase-exit requirement. If the container blocks Landlock syscalls (seccomp), running it on the host binary or skipping locally is acceptable for phase exit.

### Claude's Discretion

- Container image internals: release tarball as image source, sha256 verification in the image build, image caching/reuse across phases, exact base image.
- Which specific constants the Phase 2 truth tests cover (deferred with the tests).
- README pin wording details (structure kept: tag + `odin version` string + sha256).
- Mechanics of warning fixes where the fix is obvious (deprecation → replacement API).

### Deferred Ideas (OUT OF SCOPE)

None — discussion stayed within phase scope. (D-07's truth-test deferral is a phase-boundary decision recorded under decisions, with Phase 2 as its landing place.)
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| TOOL-01 | Project builds and the full suite passes on Odin `dev-2026-11` nightly; README pin updated | Pinned artifact + sha256 verified (GitHub API); all gate commands verified valid against the `dev-2026-11` compiler source (`src/main.cpp`); every `core:*` API the repo imports verified present and signature-compatible at `dev-2026-11`; fmt pad-width change confirmed to have zero call sites in the repo; container recipe with sha256-verified tarball designed; default container seccomp verified to allow Landlock syscalls |
</phase_requirements>

## Summary

The bump dev-2026-05 → `dev-2026-11a` is **low-churn for this codebase, with zero expected code changes**. Every `core:*` API the repo imports (fmt, os, io, mem, reflect, strings, sys/linux, sys/unix, sys/posix, net, text/table, testing, c, strconv) was checked in the actual `dev-2026-11` tree and is present with compatible signatures. The two headline breaking changes — `core:fmt` width/pad semantics (PR #7724) and the `core:compress` overhaul — do not touch the repo: it uses no width/precision format directives at all (verified by grep over every `.odin` file) and does not import `core:compress`. The one new deprecation in imported packages (`os.write_encoded_rune`) is unused. So under D-05/D-06 the expected diff is **empty in source**; the phase is pin + container + README + a verified green run, with the existing suite and `#assert` tripwire chain as the evidence (D-07).

D-04 was researched with exact upstream evidence and **resolves to a documented no-op**: `core:sys/linux` at `dev-2026-11` still ships only the `SYS_landlock_*` syscall *numbers* (444–446) with no flags/attrs/wrappers, no `openat2`/`Open_How` wrapper (upstream TODO stubs unchanged), and `O_PATH` still does not exist in `core:os` (its `File_Flag` enum has no `.Path` member). Nothing in core covers what `syscall/syscall_linux.odin` hand-rolls, so nothing gets deleted. This avoids D-04's costly-reversibility branch entirely — record the no-op with citations rather than hunting for adoption points during execution.

One genuinely new fact changes the phase's evidence posture: **CI has not run since 2026-08-10** (last runs: kernel-matrix failure Aug 3, success Aug 10, both on a June main HEAD). No CI run has ever used any November nightly — `release: latest` will start resolving to `dev-2026-11a` on the next push anyway, which is exactly the drift D-01's pin exists to stop. The phase's green CI run is therefore *new* evidence, not re-confirmation, and should be produced before the phase closes.

**Primary recommendation:** Land D-01/D-02/D-03 as three small deliverables (workflow pins, README pin block, sha256-verified podman image), then run the D-08 gate inside the container locally and push to get the same gate green in CI. Expect zero source edits; if `odin check` surfaces escape-analysis warnings under D-06, fix them at the call site (no shims, per D-05).

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Compiler pin (exact tag, reproducible) | Build config (`.github/workflows/*.yml`) | Docs (README.adoc pin block) | Workflows own execution; README owns vendoring-user verification (D-02) |
| Local toolchain parity with the pin | Podman image (D-03) | — | Read-only atomic host: tools live in containers, never on host |
| Source compatibility with `dev-2026-11` | Source (repo `.odin` files) | — | Only touched if warnings/errors surface (D-06); research found none expected |
| Layout/representation stability evidence | `syscall/syscall.odin` `#assert` chain + existing suite | — | Compile-time tripwires + fake-seam suite are the D-07 evidence, no new tests |
| ABI conformance on real kernels | `.github/workflows/kernel-matrix.yml` | `tools/abi-conformance` | Same pin applied; binary built on runner host |

## Standard Stack

### Core

| Component | Version | Purpose | Why Standard |
|-----------|---------|---------|--------------|
| Odin compiler | tag `dev-2026-11a` (hotfix of `dev-2026-11`, published 2026-11-03) | All compile/test gates | Latest tagged nightly at milestone start; hotfix tag preferred over `dev-2026-11` for a stable asset URL [VERIFIED: GitHub API release id 432808814] |
| `odin-linux-amd64-dev-2026-11a.tar.gz` | 76,175,813 bytes, `sha256:65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618` | Container image toolchain source + README pin value | Exact artifact identity is the D-02 verification contract [VERIFIED: GitHub API asset digest field] |
| `laytan/setup-odin@v2` | v2 (current) | CI toolchain install | `release:` input: "if set, this will try to download a tagged GitHub release with this name instead of pulling/compiling, `latest` can be used to setup the latest release" (quoted verbatim from `action.yml`) [VERIFIED: raw.githubusercontent.com/laytan/setup-odin/main/action.yml] |
| podman | 6.1.3 (installed on host) | Local gate execution container | User doctrine: read-only atomic host, tooling in containers [VERIFIED: `podman --version`] |

### Supporting

| Component | Version | Purpose | When to Use |
|-----------|---------|---------|-------------|
| `docker.io/library/fedora` (or `quay.io/fedora/fedora`) container base | latest | Image base for the pinned toolchain | glibc base required — the release binary is a glibc-linked ELF (musl/alpine bases will not run it) [VERIFIED: `file` reports "ELF ... interpreter /lib64/ld-linux-x86-64.so.2"] |
| `clang` (or `gcc`) inside the image | distro version | Link step for `odin build`/`odin test` | The Odin release binary compiles but user programs are linked via a C compiler; install in image |
| containers-common default seccomp profile | podman 6.x default | Landlock syscalls allowed in container | Default allowlist includes `landlock_add_rule`, `landlock_create_ruleset`, `landlock_restrict_self` [VERIFIED: containers/common `pkg/seccomp/seccomp.json` ~lines 240–242] |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `dev-2026-11` tag | `dev-2026-11a` (chosen, per D-01) | `11a` is the hotfix; asset URL names carry the tag so pinning `11a` is unambiguous. Hotfix delta touches only `core/compress/lz4` + `core/image/bng` + core tests [VERIFIED: `git diff --stat dev-2026-11 dev-2026-11a`] — neither imported by this repo |
| Host tarball install | Container image (chosen, per D-03) | Violates the read-only-host doctrine; container recipe is reusable by Phases 2–4 |
| `release: latest` kept in CI | Exact tag pin (chosen) | `latest` already silently moved CI to the Nov nightly on next run without anyone deciding — the drift this phase removes |

**Version verification:** release tag, asset names, sizes, and sha256 digests were read from the GitHub API this session; action inputs from the action's own `action.yml`; compiler flags from `src/main.cpp` at tag `dev-2026-11`. No npm/pypi-style registry applies — Odin has no package manager; the "package" is the compiler release artifact.

**Package Legitimacy Audit:** No external packages are installed in this phase (Odin has no package manager; the repo is vendored by copying source files). The only externally-fetched artifact is the Odin release tarball, whose provenance is `github.com/odin-lang/Odin` releases with a verified sha256 digest — supply-chain control is the sha256 check itself (D-02/D-03). Nothing flagged.

## Architecture Patterns

### System Architecture Diagram

```text
                     D-03: local gate                       D-01: CI gate
  ┌───────────────────────────────────────────┐   ┌──────────────────────────────────────┐
  │ podman build                              │   │ laytan/setup-odin@v2                 │
  │   download tarball (exact URL)            │   │   release: dev-2026-11a  ← the pin   │
  │   sha256sum --check  ← D-02 identity      │   │        │                             │
  │   extract → /opt/odin (odin+core+vendor)  │   │        ▼                             │
  └──────────────┬────────────────────────────┘   │   odin check / test / build / cross  │
                 ▼                                │   (ci.yml gate steps, unchanged)     │
  podman run -v "$PWD:/src:Z" -w /src             └──────────────────┬───────────────────┘
     odin check . -no-entry-point      ┐                             │
     odin test . / odin test syscall   ├ D-08 gate (both legs)       ▼
     odin build examples + doc probe   │                   green run = phase evidence
     cross-target checks darwin/freebsd┘                   (new: CI idle since Aug 10)
                 │
                 ▼
     best-effort integration test (D-09) — default podman seccomp ALLOWS
     landlock_* syscalls; host kernel 7.2 has landlock in LSM → runs locally
```

### Pattern 1: Exact-tag pinning with artifact identity
**What:** Pin the release *tag* in CI (`release: dev-2026-11a`) and document tag + `odin version` string + sha256 in README.
**When to use:** Any project whose runtime floor depends on exact `core:*` behavior.
**Why:** `release: latest` re-resolves every run; the milestone depends on `core:*` stability, so the pin must be an exact tag (D-01), never a moving ref.

### Pattern 2: sha256-verified image build as the local gate substrate
**What:** The podman image downloads the release tarball by exact URL and verifies the digest at build time; all local gate commands run inside it with the repo bind-mounted `:Z`.
**Example:**
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
```bash
podman build -t localhost/odin-dev-2026-11a .
podman run --rm -v "$PWD:/src:Z" -w /src localhost/odin-dev-2026-11a odin version   # record for README (D-02)
podman run --rm -v "$PWD:/src:Z" -w /src localhost/odin-dev-2026-11a odin check . -no-entry-point
```
`--strip-components=1` places `odin`, `core/`, `vendor/`, `base/` under `/opt/odin`; the compiler auto-detects its root from the executable location. `:Z` relabels the mount for SELinux-enforcing hosts (this workstation is SELinux-enabled — `selinux` appears in the host LSM list [VERIFIED: `/sys/kernel/security/lsm`]). Build once; reuse the image across Phases 2–4 (per D-03's "define once, reuse").

### Anti-Patterns to Avoid
- **Installing the toolchain on the host** — standing user rule: read-only atomic host; container only (D-03).
- **Shimming old fmt output or pinning widths** — D-05 forbids; research shows there is nothing to shim anyway.
- **`odin test` with `-no-entry-point`** — the flag is registered check-only: `add_flag(... "no-entry-point" ..., Command__does_check &~ Command_test)` (quoted from `src/main.cpp:714`) [VERIFIED]; keep it only on `check` steps as CI already does.
- **`--security-opt seccomp=unconfined`** to "make Landlock work" — unnecessary: the default profile already allowlists the Landlock syscalls [VERIFIED]. Reach for D-09's fallback (host run or skip) instead of weakening container isolation.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| CI toolchain install | Download/extract scripts in workflow YAML | `laytan/setup-odin@v2` `release:` input | Action handles platform asset selection and caching semantics; already the repo pattern |
| Toolchain identity check | Hash comparison scripts | `sha256sum --check -` in the Containerfile `RUN` | Fails the build loudly on mismatch; zero glue code |
| fmt compatibility layer | Width/pad shims or explicit-width rewrites | D-05: ride the new defaults | Repo has zero width directives; shims would be dead weight contradicting the no-shims decision |
| Wrapper adoption audit | Guessing what core now covers | Cited upstream evidence (see D-04 verdict below) | The upstream TODOs have been static; re-checking at execution wastes plan time |

**Key insight:** the phase's risk is almost entirely *process* risk (pin, container, evidence), not *code* risk — the nightly diff analysis came back empty for every import this repo uses.

## Runtime State Inventory

> This is a toolchain-migration phase; all five categories answered explicitly.

| Category | Items Found | Action Required |
|----------|-------------|-----------------|
| Stored data | None — the repo has no databases/stores; policy state lives in caller-owned structs [VERIFIED: ARCHITECTURE.md ownership rules] | none |
| Live service config | GitHub Actions workflows are in-git and are the edit targets (D-01); no out-of-git service config found | none beyond the workflow edits |
| OS-registered state | None. Host `~/.local/bin/odin` (`dev-2026-10-nightly:84bc3fc`) remains but is *deliberately* not the gate toolchain (D-03); no cron/systemd/tmux registrations reference the repo [VERIFIED: no such units checked into repo; nothing found] | none — do not touch the host install |
| Secrets/env vars | `LANDLOCK_EXPECT_ABI` (kernel-matrix guest script, value stays `0/1/4/6/7` per matrix) and `LANDLOCK_INTEGRATION`/`ODIN_TEST_THREADS` defines — names unchanged by the bump; no secrets involved | none |
| Build artifacts | `examples/examples` is a **tracked compiled ELF binary** (added in commit 28eaa71); `.gitignore` (uncommitted modification) now lists `examples/examples` and `examples/main.odin~` as ignored; `examples/rules-demo/` is untracked; `/tests/` is gitignored entirely (local smoke/qemu harness; CI never sees it) | Optional chore for planner: `git rm --cached examples/examples` (repo hygiene, not required by TOOL-01). Not in scope otherwise. CI builds to `-out:/tmp/example`, so the stray binary does not affect gates |

## Common Pitfalls

### Pitfall 1: Assuming the fmt pad-width change requires repo edits
**What goes wrong:** Planner allocates tasks to "fix pad-width fallout" that cannot exist.
**Why it happens:** Roadmap criterion 2 mentions it; the change is real upstream.
**How to avoid:** The repo's fmt usage is `%v/%d/%s/%w` only — a grep for `%[-0-9]|\*s|\*d|\*x|%0[0-9.]` over all `.odin` files matches nothing outside `.specify` shell scripts [VERIFIED]. The change (old default zero-pad → spaces unless `0` flag; width bytes → runes) has **zero call sites** here. Test assertions that touch fmt output (`tsync=on/off`, feature-set text) come from repo-owned rendering, not fmt padding.
**Warning signs:** If a future task adds width directives, re-audit then.

### Pitfall 2: bit_set/transmute representation churn going unnoticed
**What goes wrong:** `bit_set[E;u64]` backing or RTTI changes silently alter masks bridged by `transmute` at the `Path_Access` ↔ `syscall.Access_FS_Flag` boundary.
**Why it happens:** dev-2026-10 shipped bit_set backing changes (#7664) and `bit_set[E; [4]u64]` support (b153d6071).
**How to avoid:** Nothing to do in this phase beyond running the suite: the explicit `;u64` backing keeps sizes fixed and the existing `#assert(size_of(Access_FS_Flags) == size_of(u64))` chain fails compilation on any drift — that is exactly the D-07 evidence. `%w` bit-set rendering shape is unchanged between the tags (diff shows only internal writer plumbing + a new array-backing path) [VERIFIED: fmt diff hunks, `fmt_bit_set`/`fmt_bit_set_array`].
**Warning signs:** any `#assert` failure at compile time = stop, investigate, do not "fix" the assert.

### Pitfall 3: Escape-analysis / vet tightening under D-06
**What goes wrong:** `dev-2026-11` tightens escape analysis; new diagnostics surface in `odin check` and D-06 forbids tolerating them.
**Why it happens:** language-level analysis tightened between the nightlies; repo has fork/pointer-heavy test code.
**How to avoid:** Expect the first container `odin check` run to be the source of any work in this phase. Fix at call sites per D-05/D-06 (no `-no-escape-analysis` opt-outs, no shims). New opt-out flags exist (`-no-atomic-analysis`, `-vet-atomic-access` [VERIFIED: `src/main.cpp:716`]) but the library does no atomics — do not add flags to gate commands.
**Warning signs:** warnings mentioning escape/aliasing in test helpers.

### Pitfall 4: `make_directory_temp` signature drift
**What goes wrong:** Tests fail to compile if call sites use the old 2-arg form.
**Why it happens:** dev-2026-11 `core:os` requires the allocator: `make_directory_temp :: proc(dir, pattern: string, allocator: runtime.Allocator)` (quoted from `core/os/temp_file.odin:49`).
**How to avoid:** Repo call sites already pass `context.allocator` (`landlock_test_linux.odin:280`, `tests/smoke/main.odin:63`) [VERIFIED] — nothing to do; this pitfall exists only so the planner doesn't "fix" anything or panic if grep surfaces the 3-arg signature.
**Warning signs:** none — compliant today.

### Pitfall 5: Assuming CI is already green on the new nightly
**What goes wrong:** Treating the bump as already-verified because CI "always runs latest".
**Why it happens:** `release: latest` does track the newest release — but no workflow run exists after 2026-08-10 (last runs: kernel-matrix #20 **failure** Aug 3, #21 success Aug 10, both on main `7902274`, a June merge) [VERIFIED: GitHub Actions API]. Recent GSD work lives on branch `001-config-build`, which does not trigger CI (triggers: push to main, PRs, dispatch).
**How to avoid:** Budget for the CI leg of the gate actually running (push/PR + `workflow_dispatch`); the local container leg is the first real evidence.
**Warning signs:** a stale "last successful run" date in the Actions tab.

### Pitfall 6: Integration test in the container assumed blocked
**What goes wrong:** Planner skips the local integration run unnecessarily or weakens seccomp "to make it work".
**Why it happens:** containers historically blocked exotic syscalls.
**How to avoid:** The default containers-common seccomp allowlist includes all three Landlock syscalls [VERIFIED: seccomp.json], and the host kernel 7.2 has landlock in the LSM stack (`/sys/kernel/security/lsm` = `lockdown,capability,yama,selinux,bpf,landlock,ipe,ima,evm`) [VERIFIED]. Run it normally with `-define:ODIN_TEST_THREADS=1`; keep D-09's "best-effort, not a gate blocker" stance.
**Warning signs:** `EOPNOTSUPP` from create_ruleset inside the container → LSM visibility issue, fall back per D-09.

### Pitfall 7: Forgetting the README doc-snippet probe depends on the example block
**What goes wrong:** The CI "README example compiles" step breaks if the README code block is restructured while re-pinning the toolchain note (D-02).
**Why it happens:** The probe awk-extracts the *first* `[source,odin]` block from README.adoc and edits its import line (`sed 's#import landlock$#import landlock ".."#'`) [VERIFIED: `.github/workflows/ci.yml` step].
**How to avoid:** Edit only the "Tested with Odin ..." toolchain note (~line 19); leave the first source block intact.
**Warning signs:** CI step failure on an otherwise-green build.

## D-04 Verdict (wrapper adoption): documented no-op

Researched so the planner does not spend a task hunting adoption points:

- `core:sys/linux` at `dev-2026-11`: only syscall numbers — `SYS_landlock_create_ruleset :: uintptr(444)`, `SYS_landlock_add_rule :: uintptr(445)`, `SYS_landlock_restrict_self :: uintptr(446)`, `SYS_openat2 :: uintptr(437)`, `SYS_prctl` (quoted from `core/sys/linux/syscall_amd64.odin:356-366`; mirrored in `core/sys/unix/syscalls_linux.odin:373-375`). No Landlock flags/attrs/wrapper procs; the upstream `TODO(flysand)` stubs for landlock/openat2 remain (previously verified at `core/sys/linux/sys.odin:3408-3412` and `:3371`, unchanged in the 05→11 sys log).
- `core:os` at `dev-2026-11`: `File_Flag` enum members are `Read, Write, Append, Create, Excl, Sync, Trunc, Sparse, Inheritable, Non_Blocking, Unbuffered_IO` (quoted from `core/os/file.odin:61-73`) — **no `Path`/O_PATH member**; the repo's `O_PATH` route stays `linux.Open_Flags{.PATH, .CLOEXEC}` via `core:sys/linux` (present, `Open_Flags :: bit_set[Open_Flags_Bits; u32]`, quoted from `core/sys/linux/types.odin:86`).
- `Open_How` still does not exist in core → the hand-rolled openat2 wrapper stays.

Conclusion: **keep `syscall/syscall_linux.odin` unchanged; mark D-04 satisfied by evidence** ("nightly ships nothing to adopt"). This is the cheap outcome of a costly-to-reverse decision — record it in the plan verbatim.

## Code Examples

### CI pin (both workflows) — the only workflow edit
```yaml
- name: Install Odin (pinned nightly)
  uses: laytan/setup-odin@v2
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
    release: dev-2026-11a   # was: latest
```
Current block to replace (quoted verbatim, `.github/workflows/ci.yml:15-19`; identical in `kernel-matrix.yml`):
```yaml
      - name: Install Odin (latest monthly release)
        uses: laytan/setup-odin@v2
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          release: latest
```

### README pin block (D-02; structure per D-02 discretion)
```adoc
Tested with Odin `dev-2026-11a` nightly (hotfix of dev-2026-11, 2026-11-03).
The package depends on `core:sys/linux` internals, so pin an Odin version when vendoring.

Pinned toolchain identity:
* tag: `dev-2026-11a`
* `odin version`: dev-2026-11a:<hash recorded from first pinned run>
* linux-amd64 artifact: `odin-linux-amd64-dev-2026-11a.tar.gz`,
  sha256 `65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618`
```

### Gate command list (D-08; all verified valid against `dev-2026-11` flag tables)
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
Flag registration evidence from `src/main.cpp` at `dev-2026-11`: `-out` (`:683`), `-define` (`:698`), `-target` (`:701`), `-vet` (`:733`), `-no-entry-point` check-only (`:714`), commands `check`/`build`/`test`/`report` (`:2937-2978`). [VERIFIED]

## State of the Art

| Old Approach (dev-2026-05) | Current Approach (dev-2026-11) | When Changed | Impact |
|------------------|------------------|--------------|--------|
| fmt: width pads numbers with `0` by default; width counted in bytes | Width pads with spaces unless `0` flag; width counted in runes (PR #7724) | within 05→11 window | None here — no width directives in repo [VERIFIED] |
| `io.Stage_Writer` exists | Removed from core:io (fmt switched to `bufio.Writer`) | 05→11 | Repo uses only `io.Error.Unsupported` + `io.write_byte` — both present [VERIFIED] |
| `core:os/old` deprecated | Deleted outright | 05→11 | Repo never imported it [VERIFIED] |
| No atomic analysis | `-vet-atomic-access` / `-no-atomic-analysis` flags exist | 05→11 | Not used; do not add to gate commands |
| `os.write_encoded_rune` plain | Deprecated (renamed semantics → `write_quoted_rune`) | 05→11 | Unused by repo — no warning can surface |

**Deprecated/outdated:** none of the repo's own surface; host `~/.local/bin/odin` is deliberately *not* the verification toolchain anymore (D-03).

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | The pinned binary reports `odin version` as `dev-2026-11a:<short-hash>` (exact hash unknown until first run) | Code Examples (README block) | Cosmetic — README records whatever the binary actually prints at execution |
| A2 | `laytan/setup-odin` selects the `linux-amd64` asset automatically for ubuntu runners (behavior exercised in prior runs with `release: latest`; input semantics quoted from `action.yml`) | Standard Stack | Low — if it mis-picked, the first CI run fails loudly; D-01's live check already validated the artifact path |
| A3 | Release binaries are self-contained (statically linked LLVM; only a C compiler needed for *linking user code*) | Standard Stack | Low — if the binary needs more runtime libs, the image `dnf install` line grows; failure is immediate and visible in image build |

## Open Questions (RESOLVED)

1. **What warnings will the first pinned `odin check` print (if any)?**
   - What we know: no deprecations touch imported APIs; escape analysis tightened upstream.
   - What's unclear: whether test/tool code trips the tightening (D-06 makes this in-scope work if it happens).
   - Recommendation: plan one explicit "run gate, fix what it reports (call-site fixes only)" task; treat zero findings as the expected path.
   - **RESOLVED:** by plan Task 3 — "fix only what it reports" discipline with zero findings as the expected path.

2. **Should `git rm --cached examples/examples` ride along?**
   - What we know: tracked ELF binary, now gitignored (uncommitted `.gitignore` edit), harmless to gates.
   - What's unclear: user preference on removing it from the index in this phase vs. never.
   - Recommendation: optional chore task, default skip; requires user nod since it rewrites tracked state (do not commit it silently).
   - **RESOLVED:** by plan — no task implements it; carried as a flagged assumption awaiting an explicit user nod.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| podman | D-03 container gate | ✓ | 6.1.3 | — |
| host odin | NOT the gate toolchain (D-03) | ✓ (wrong version by design) | dev-2026-10-nightly:84bc3fc | container image is authoritative |
| host Landlock kernel | D-09 integration run | ✓ | kernel 7.2.11, `landlock` in LSM list | skip per D-09 |
| gh/GitHub API access | CI green-run evidence | ✓ (API verified this session) | — | watch Actions UI |
| laytan/setup-odin@v2 | CI pin | ✓ (action.yml verified) | v2 | — |

**Missing dependencies with no fallback:** none.
**Missing dependencies with fallback:** host odin (fallback: container image — which is the chosen route anyway).

## Security Domain

### Applicable ASVS Categories (Level 1)

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V5 Input Validation | limited | sha256 digest verification of the fetched toolchain artifact (`sha256sum --check -` fails the image build on mismatch) |
| V14 Build & Deploy | yes | Exact-tag pin in CI (no `latest`); pinned identity published in README (D-02); no secrets or new env surface introduced |
| V2/V3/V4/V6… | no | No auth/session/access-control/crypto surface in a toolchain-bump phase |

### Known Threat Patterns for this stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Toolchain supply-chain tampering (swapped tarball/mirror) | Tampering | Exact release URL + published sha256 verified at image build; README publishes the digest (D-02/D-03) |
| Silent gating drift ("latest" resolves to a newer nightly mid-milestone) | Tampering (config) | Exact tag pin in both workflows (D-01) |
| Over-broad container isolation to "fix" Landlock in container | Elevation of exposure | Default seccomp already allows landlock syscalls [VERIFIED]; never `seccomp=unconfined`; D-09 fallback instead |
| Sandbox self-verification theater (integration "passing" without a kernel) | Repudiation | Integration test stays real-kernel best-effort with explicit skip messaging; CI skips only where `/sys/kernel/security/lsm` lacks landlock (existing behavior, D-09) |

## Sources

### Primary (HIGH confidence)
- GitHub API `repos/odin-lang/Odin/releases/tags/dev-2026-11a` — tag, publish timestamp, asset names/sizes/sha256 digests, release body ("dev-2026-11 release + hotfix addressing an enum clash between BNG + LZ4") (fetched 2026-11-09)
- Odin repo tag `dev-2026-11` source tree (blob-fetched via git this session): `core/fmt/fmt.odin` + `core/fmt/doc.odin` (pad/rune-width semantics, `%w` verb, fmt_bit_set), `core/os/*` (File_Flag enum, File_Flags, make_directory_temp, open, write_entire_file, remove_all, error_string, stat), `core/sys/linux/*` (SYS_landlock_*/SYS_openat2 numbers, Open_Flags), `core/sys/unix/syscalls_linux.odin`, `core/sys/posix/*` (fork/getpid/waitpid/bind/connect/listen/errno), `core/testing/*` (ODIN_TEST_THREADS/ODIN_TEST_FANCY, fail_now), `core/net/*`, `core/text/table/*`, `core/reflect/reflect.odin`, `src/main.cpp` (flag tables)
- `git diff dev-2026-05 dev-2026-11` — per-package change census: core:fmt pad hunks (`pad_byte`/`_zero_pad`/`rune_count`), io Stage_Writer removal, os/old deletion, sole new deprecation (`os.write_encoded_rune`), bit_set fmt internals; and `git diff dev-2026-11 dev-2026-11a` (lz4/bng-only hotfix)
- `raw.githubusercontent.com/laytan/setup-odin/main/action.yml` — `release:` input semantics
- `raw.githubusercontent.com/containers/common/main/pkg/seccomp/seccomp.json` — landlock syscall allowlist entries
- In-repo (read this session, quoted verbatim in sections above): `.github/workflows/ci.yml`, `.github/workflows/kernel-matrix.yml`, `README.adoc`, `syscall/syscall.odin`, `syscall/syscall_linux.odin`, `landlock.odin` (fmt call sites, enum_to_string, debug_summary), `landlock_test_linux.odin`, `landlock_integration_test.odin`, `tests/smoke/main.odin`, `.gitignore`, `.planning/config.json`
- Host probes: `podman --version` → 6.1.3; `odin version` → dev-2026-10-nightly:84bc3fc; `/sys/kernel/security/lsm`
- GitHub Actions API `repos/litew/odin-landlock/actions/runs` — last runs Aug 3 (failure) / Aug 10 (success), main `7902274`
- Prior milestone research (already-verified upstream facts reused): `.planning/research/STACK.md` (sys.odin TODO stub line numbers at dev-2026-11; PR numbers #7724/#8153; compiler-analysis changes), `SUMMARY.md`, `PITFALLS.md`

### Secondary (MEDIUM confidence)
- None needed — all load-bearing claims rest on primary sources above.

### Tertiary (LOW confidence)
- None.

## Metadata

**Confidence breakdown:**
- Toolchain stack (pin/artifact/action): HIGH — GitHub API + action.yml read directly
- Nightly-delta analysis ("zero expected source edits"): HIGH — actual tag trees diffed and every imported API checked; only D-06 warning surface is execution-time
- Container recipe: HIGH — podman verified on host; seccomp/SELinux facts verified; exact base-image choice is discretion
- Pitfalls: HIGH for compiled-in facts, MEDIUM for warning-surface (inherently discovered by first run)

**Research date:** 2026-11-09
**Valid until:** 2026-12-09 (pin makes the toolchain side frozen; re-check only if the milestone slips past the next monthly release and CI `latest` semantics matter again)

**Planner notes:**
- Mirror D-07 wording in plan/roadmap criterion 3 (existing suite + `#assert` chain = evidence; literal truth tests belong to Phase 2).
- Expected source diff for this phase is **empty**; the deliverables are the two workflow pins, the README block, the Containerfile (+ image build), and one green gate run (local) + one green CI run.
- If the first pinned `odin check` reports warnings (D-06), that is in-scope work: fix at call sites, no opt-out flags, no shims.
