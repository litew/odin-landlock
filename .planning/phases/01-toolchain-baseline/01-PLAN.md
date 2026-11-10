---
phase: 1
plan: 1
title: Pin Odin dev-2026-11a and prove the full gate on it
type: implementation
wave: 1
depends_on: []
files_modified:
  - Containerfile
  - README.adoc
  - .github/workflows/ci.yml
  - .github/workflows/kernel-matrix.yml
  - .planning/ROADMAP.md
autonomous: true
requirements: [TOOL-01]
must_haves:
  truths:
    - Every gate command in D-08 (check, both unit suites, example build, tools/abi-conformance build, README doc probe, darwin_amd64 + freebsd_amd64 cross-targets) passes with the pinned dev-2026-11a compiler, verified locally inside the podman image.
    - Both CI workflows pin `release: dev-2026-11a` exactly; `release: latest` appears nowhere in .github/workflows/.
    - README.adoc documents the pin per D-02: tag, exact `odin version` string recorded from the first pinned run, artifact name, and sha256 65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618.
    - D-04 is satisfied by documented evidence, not edits — core:sys/linux at dev-2026-11 ships only Landlock syscall numbers (444–446), no openat2/Open_How wrapper, no O_PATH in core:os File_Flag; syscall/syscall_linux.odin stays unchanged.
    - Phase 1 success criterion 3 is met by the existing suite + #assert chain passing on the pinned nightly (per D-07; literal bit-value truth tests deferred to Phase 2) — the roadmap text already mirrors D-07 wording and needs no further edit.
    - The local integration test is best-effort per D-09: it runs in-container with default seccomp (verified to allow landlock syscalls); if it fails on LSM visibility, a host run or a documented skip is acceptable phase exit.
  artifacts:
    - Containerfile (new, repo root, git-tracked once committed)
    - localhost/odin-dev-2026-11a podman image (local, reusable by Phases 2–4; not a repo artifact)
    - .github/workflows/ci.yml — `release: dev-2026-11a` pin (modified)
    - .github/workflows/kernel-matrix.yml — `release: dev-2026-11a` pin (modified)
    - README.adoc — pinned toolchain identity block replacing the dev-2026-05 note at ~line 19 (modified)
    - Recorded `odin version` string of the pinned binary (into README block)
  prohibitions:
    - statement: Gate commands must never gain opt-out or vet flags (-no-escape-analysis, -no-atomic-analysis, -vet-*) and container runs must never weaken seccomp (--security-opt seccomp=unconfined); D-05/D-06/D-09 fix at call sites and use the D-09 fallback instead.
      status: unverified
      verification: flagged — verifier should grep gate command lists in PLAN, ci.yml, and the gate task for these flags/opts
      flagged: true
    - statement: The README edit must not touch the first [source,odin] block or its ---- fences — the ci.yml doc-probe awk/sed pipeline extracts that block verbatim and breaks independently of the build if it is restructured.
      status: unverified
      verification: flagged — verified if the ci.yml "README example compiles" step still passes on the pinned nightly
      flagged: true
    - statement: Hand-rolled Landlock/openat2 wrappers in syscall/syscall_linux.odin must not be deleted or rewritten in this phase — research documented core ships nothing to adopt (D-04 no-op), and any failing #assert after the bump is a stop-and-investigate, never an assert "fix".
      status: unverified
      verification: flagged — verified if git diff shows syscall/ unchanged at phase close and all #asserts compile
      flagged: true
  flagged_assumptions:
    - TOOL-01 probe row is unclassified/unresolved — never auto-resolved. Surfaced: TOOL-01 has no named verification command in any spec; this plan treats the D-08 gate command list (from CONTEXT.md D-08, mirrored from ci.yml) as its verification. If wrong, the phase verifier should say which command TOOL-01 actually requires.
    - The `odin version` string of the pinned binary is unknown until first run (assumed shape `dev-2026-11a:<hash>`, research assumption A1). The plan records whatever the binary actually prints; the README hash placeholder is filled from the tracer run.
    - Optional chore (default skip, requires explicit user nod, never committed silently) — `git rm --cached examples/examples`: a tracked stale ELF binary now covered by the uncommitted .gitignore edit. Flagged for the user; no task implements it.
---

# Plan 01: Pin Odin dev-2026-11a and prove the full gate on it

**User story:** As an Odin developer vendoring this library, I want the project pinned, built, and fully green on the exact `dev-2026-11a` nightly — locally in a container and in CI — so that feature work starts from a verified toolchain with toolchain churn isolated.

**Scope:** TOOL-01 only. Expected source diff is empty (RESEARCH.md verdict); gate failures are fix-what-it-reports tasks, not designed changes (PATTERNS.md "Phase Shape").

**D-07 wording (mirrored):** Phase 1 evidence for "no representation churn" is the existing test suite plus the `#assert` tripwire chain passing on the pinned nightly. No new literal-value tests are authored in this phase; they land in Phase 2 alongside v10/v11 constants. The ROADMAP.md Phase 1 success criterion 3 already carries this wording — no roadmap edit task exists; `.planning/ROADMAP.md` appears in files_modified only if the executor finds stale criterion text contradicting D-07.

## Flagged source-audit items (no silent drops)

- TOOL-01 probe row (unclassified) → `must_haves.flagged_assumptions` above.
- `git rm --cached examples/examples` chore → flagged, default skip, user nod required.
- D-04 no-op verdict → recorded verbatim in `must_haves.truths` and Task 3 `read_first`.

## Artifacts this phase produces

- **New:** `Containerfile` (repo root) — sha256-verified pinned toolchain image recipe; image `localhost/odin-dev-2026-11a` (local only).
- **Modified:** `.github/workflows/ci.yml` — `release: latest` → `release: dev-2026-11a` in the `laytan/setup-odin@v2` block (~line 22); changed CI input.
- **Modified:** `.github/workflows/kernel-matrix.yml` — same pin in its setup-odin block (~line 44); changed CI input.
- **Modified:** `README.adoc` — pinned toolchain identity block (tag + `odin version` string + artifact + sha256) replacing the `dev-2026-05` note at ~line 19.
- **Evidence (not repo files):** one green local D-08 gate run in the container; one green CI run on push/PR (CI idle since 2026-08-10 — new evidence, not re-confirmation).

<threat_model>
scope: supply chain, CI drift, container isolation
security_asvs_level: 1
block_on: high

threats:
  - id: T1
    name: Supply-chain — unverified toolchain artifact
    severity: high
    mitigation: The Containerfile downloads the release tarball by exact URL and verifies sha256 65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618 with sha256sum --check inside the build; mismatch fails the image build loudly (D-02/D-03). README publishes the same digest. Status: mitigated.
  - id: T2
    name: CI drift — floating release silently re-pins the toolchain
    severity: medium
    mitigation: D-01 replaces `release: latest` with the exact tag `dev-2026-11a` in both workflows; the phase-out criterion forbids the string `release: latest` anywhere under .github/workflows/. Status: mitigated.
  - id: T3
    name: Container isolation weakened to make Landlock work
    severity: medium
    mitigation: Default podman seccomp already allowlists the three landlock syscalls (RESEARCH finding 5); D-09 fallback is host run or skip — never --security-opt seccomp=unconfined (see prohibitions). Status: mitigated by design + prohibition.
  - id: T4
    name: Library TOCTOU/symlink contract regression during the bump
    severity: low
    mitigation: Phase expects zero source edits; syscall/ unchanged, suite + #assert chain green. Status: accepted for this phase (no code churn planned).

No high-severity threat remains unmitigated; blocking threshold satisfied.
</threat_model>

<objective>
Deliver TOOL-01: the project compiles and the full suite passes on Odin dev-2026-11a, with the pin enforced in CI (D-01), documented in README (D-02), reproducible locally in a podman container (D-03), and the D-08 gate green locally. D-04 recorded as a documented no-op; D-05/D-06 applied only if the gate reports findings; D-09 keeps integration best-effort; D-07 wording mirrored.
</objective>

<tasks>

<task type="tracer">
  <name>End-to-end pinned toolchain: sha256-verified image + first pinned compile</name>
  <files>Containerfile, README.adoc</files>
  <read_first>
    .planning/phases/01-toolchain-baseline/01-CONTEXT.md (D-01..D-03, D-02 identity fields)
    .planning/phases/01-toolchain-baseline/01-RESEARCH.md (Pattern 2 container recipe, sha256, anti-patterns)
    .planning/phases/01-toolchain-baseline/01-PATTERNS.md (README.adoc section — current note at lines 19-20 and doc-probe constraint, Pitfall 7)
    README.adoc (the file being modified; note the first [source,odin] block that must stay intact)
    .claude/CLAUDE.md (project conventions; no non-Odin source files beyond config)
  </read_first>
  <action>
    Create `Containerfile` at repo root per RESEARCH.md Pattern 2, per D-03: base `docker.io/library/fedora:latest` (glibc base — the release binary is glibc-linked; clang installed for the user-code link step, curl for fetch); build ARG ODIN_SHA256 defaulting to 65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618; a single RUN that curls https://github.com/odin-lang/Odin/releases/download/dev-2026-11a/odin-linux-amd64-dev-2026-11a.tar.gz, pipes the ARG through sha256sum --check (build fails loudly on mismatch), extracts with tar --strip-components=1 into /opt/odin, and ENV PATH prepends /opt/odin. The image never COPYs repo source (bind-mount at run). No seccomp options, no security overrides.
    Build it: podman build -t localhost/odin-dev-2026-11a .
    Then run, with the repo bind-mounted -v "$PWD:/src:Z" -w /src (the :Z is required — SELinux-enforcing host): odin version (record the exact printed string for README, per assumption A1 record whatever it prints), then odin check . -no-entry-point as the first pinned compile. Per the standing user rule, never install anything on the host; host ~/.local/bin/odin is deliberately not the gate.
    Then edit README.adoc lines ~19-20 only, per D-02: replace the "Tested with Odin dev-2026-05 nightly..." sentence with the pinned identity block — tag dev-2026-11a (hotfix of dev-2026-11, 2026-11-03), the recorded `odin version` string, artifact name odin-linux-amd64-dev-2026-11a.tar.gz, sha256 as above, and keep the vendoring rationale sentence (core:sys/linux + hand-rolled openat2 — still true per the D-04 no-op). Do NOT restructure or re-fence the first [source,odin] block (doc-probe contract, PATTERNS Pitfall 7).
  </action>
  <verify>
    <automated>podman run --rm localhost/odin-dev-2026-11a odin version</automated>
    <fails_when>output does not contain the substring dev-2026-11a (a mismatched or unpinned toolchain prints a different release string)</fails_when>
    <automated>podman build -t localhost/odin-dev-2026-11a . && echo IMAGE_OK</automated>
    <fails_when>the build exits non-zero or IMAGE_OK is absent — this also re-proves the sha256 gate, since sha256sum --check runs inside the build</fails_when>
    <automated>podman run --rm -v "$PWD:/src:Z" -w /src localhost/odin-dev-2026-11a odin check . -no-entry-point</automated>
    <fails_when>non-zero exit, or any warning/error lines in output (D-06: zero warnings AND zero errors; findings are Task 3 work)</fails_when>
    <automated>grep -c "dev-2026-11a" README.adoc</automated>
    <fails_when>count is 0 — the pinned identity block was not written</fails_when>
    <automated>grep -c "dev-2026-05" README.adoc</automated>
    <fails_when>count is non-zero — the old unpinned note still remains</fails_when>
  </verify>
  <done>
    Containerfile exists at repo root and builds; image reports an odin version containing dev-2026-11a; first pinned odin check is warning-free (or findings are handed to Task 3); README carries the full D-02 identity block and no dev-2026-05 note; first [source,odin] block untouched.
  </done>
  <reversibility rating="reversible">Containerfile + README block are plain files; swapping the pin later is a rebuild, not a migration.</reversibility>
</task>

<task type="auto">
  <name>Pin both CI workflows to dev-2026-11a (D-01)</name>
  <files>.github/workflows/ci.yml, .github/workflows/kernel-matrix.yml</files>
  <read_first>
    .planning/phases/01-toolchain-baseline/01-CONTEXT.md (D-01 exact wording)
    .planning/phases/01-toolchain-baseline/01-PATTERNS.md (edit discipline — keep token and indentation exactly as-is)
    .github/workflows/ci.yml (file being modified; setup-odin block ~lines 22-26)
    .github/workflows/kernel-matrix.yml (file being modified; setup-odin block ~lines 44-48)
  </read_first>
  <action>
    Per D-01, in BOTH workflow files change only the setup-odin block: `release: latest` becomes `release: dev-2026-11a` (the action's release input downloads the tagged GitHub release — exact tag, never a commit hash). Optionally rename the step name from "Install Odin (latest monthly release)" to "Install Odin (pinned nightly)". Keep `uses: laytan/setup-odin@v2`, the `token:` line, and all indentation byte-identical. Touch nothing else in either workflow — the remaining steps are the canonical D-08 gate list.
    Note the CI evidence posture (RESEARCH Pitfall 5): no workflow has run since 2026-08-10 and branch 001-config-build pushes do not trigger ci.yml (push triggers main only); the green CI run comes from a PR, a push to main, or workflow_dispatch — the orchestrator handles pushing/committing, so this task is files-only.
    Conditional chore, NOT executed by this task: `git rm --cached examples/examples` requires an explicit user nod (flagged in must_haves); if the user grants it mid-phase, the orchestrator commits it separately — never bundled silently.
  </action>
  <verify>
    <automated>grep -rn "release: dev-2026-11a" .github/workflows/</automated>
    <fails_when>fewer than 2 matching lines — one or both workflows remain unpinned</fails_when>
    <automated>grep -rn "release: latest" .github/workflows/ ; test $? -eq 1</automated>
    <fails_when>any match found — the floating pin still exists somewhere under .github/workflows/</fails_when>
    <automated>git diff --stat .github/workflows/ci.yml .github/workflows/kernel-matrix.yml</automated>
    <fails_when>diffstat shows more than ~2 changed lines per file (name + release) — something outside the setup-odin block was touched</fails_when>
  </verify>
  <done>Both workflows carry release: dev-2026-11a inside their laytan/setup-odin@v2 blocks; the string release: latest is gone from .github/workflows/; no other workflow lines changed.</done>
</task>

<task type="auto">
  <name>Run the full D-08 gate in the container; fix only what it reports</name>
  <files>landlock.odin, landlock_test_linux.odin, syscall/syscall_linux.odin, tools/abi-conformance/main.odin</files>
  <read_first>
    .planning/phases/01-toolchain-baseline/01-CONTEXT.md (D-04..D-09)
    .planning/phases/01-toolchain-baseline/01-RESEARCH.md (gate command list, D-04 no-op verdict, Pitfalls 2/3/6, no-shims/no-opt-outs)
    .planning/phases/01-toolchain-baseline/01-PATTERNS.md (gate-list mirroring, stub-twin symmetry, #assert guard rails)
    .planning/codebase/TESTING.md (suite command list the gate mirrors)
    .claude/CLAUDE.md (conventions: #assert tripwires, platform splits, errno-exact test style)
    syscall/syscall.odin (the #assert chain that must compile untouched)
    syscall/syscall_linux.odin (conditional edit target; expected unchanged)
  </read_first>
  <action>
    Run the complete D-08 gate inside localhost/odin-dev-2026-11a with the repo bind-mounted -v "$PWD:/src:Z" -w /src (same command set as ci.yml, per D-08): odin check . -no-entry-point; odin test . -define:ODIN_TEST_FANCY=false; odin test syscall -define:ODIN_TEST_FANCY=false; odin build examples -out:/tmp/example; odin build tools/abi-conformance -out:/tmp/abi-conformance; the README doc-snippet probe (the same awk/sed pipeline as the ci.yml "README example compiles" step, run from /src); odin check . -no-entry-point -target:darwin_amd64 and -target:freebsd_amd64; then the best-effort integration run odin test . -define:LANDLOCK_INTEGRATION=true -define:ODIN_TEST_THREADS=1 (D-09 — default seccomp allows landlock syscalls, host kernel 7.2 has landlock in the LSM stack; if it fails on LSM visibility, record the host-run-or-skip fallback as acceptable phase exit; NEVER add --security-opt seccomp=unconfined).
    Fix-what-it-reports discipline (per D-04/D-05/D-06 — these are reports-driven call-site fixes, not designed changes): deprecation/escape-analysis warnings → fix at the call site with the replacement API; fmt-behavior expectations → update expectations to the new defaults (no shims, no explicit-width pinning); any signature change in syscall/syscall_linux.odin must be mirrored in syscall/syscall_unsupported.odin or the cross-target checks fail. A failing #assert in syscall/syscall.odin is STOP-AND-INVESTIGATE — report it, never edit the assert.
    If the gate is fully green with zero findings (the researched expectation), the source files listed above end the phase unchanged and this task's deliverable is the recorded green gate transcript.
    D-04 record-keeping: no adoption work exists — core:sys/linux at dev-2026-11 ships only Landlock syscall numbers 444-446, no openat2/Open_How wrapper, no O_PATH in core:os (RESEARCH "D-04 Verdict"). State this in the task output; syscall/ stays untouched unless the compiler itself demands a fix.
    D-07 reminder: no new truth tests in this phase; suite + #assert chain green IS the criterion-3 evidence.
  </action>
  <verify>
    <automated>podman run --rm -v "$PWD:/src:Z" -w /src localhost/odin-dev-2026-11a sh -c "odin check . -no-entry-point && odin test . -define:ODIN_TEST_FANCY=false && odin test syscall -define:ODIN_TEST_FANCY=false && odin build examples -out:/tmp/example && odin build tools/abi-conformance -out:/tmp/abi-conformance && odin check . -no-entry-point -target:darwin_amd64 && odin check . -no-entry-point -target:freebsd_amd64 && echo GATE_GREEN"</automated>
    <fails_when>non-zero exit from any chained command or GATE_GREEN absent from output</fails_when>
    <automated>podman run --rm -v "$PWD:/src:Z" -w /src localhost/odin-dev-2026-11a sh -c "mkdir -p _docprobe && awk '/^\\[source,odin\\]/{f=1;next} f&&/^----$/{c++; if(c==1)next; if(c==2)exit} c==1{print}' README.adoc > _docprobe/main.odin && sed -i 's#import landlock\$#import landlock \"..\"#' _docprobe/main.odin && odin build _docprobe -out:/tmp/docprobe && rm -rf _docprobe && echo DOCPROBE_OK"</automated>
    <fails_when>non-zero exit or DOCPROBE_OK absent — the README example no longer compiles standalone</fails_when>
    <automated>git diff --stat -- syscall/</automated>
    <fails_when>non-empty diffstat — syscall/ changed without a compiler-demanded reason (contradicts the D-04 no-op; only call-site warning fixes may justify it, mirrored in the stub twin)</fails_when>
  </verify>
  <done>Every D-08 command plus the tools build (`odin build tools/abi-conformance`) passes inside the pinned container with zero warnings and zero errors (D-06); integration test ran or its D-09 fallback is recorded; any fixes made are minimal call-site edits with stub-twin mirrors where signatures changed; syscall/ otherwise unchanged.</done>
  <precondition>The localhost/odin-dev-2026-11a image exists from Task 1; if the local build was pruned, rebuild it with podman build -t localhost/odin-dev-2026-11a . before running the gate.</precondition>
</task>

</tasks>

<verification>
Phase exit requires ALL of:
1. `podman run --rm localhost/odin-dev-2026-11a odin version` prints a string containing dev-2026-11a.
2. Full D-08 gate green in-container (Task 3 chain + doc probe, including `odin build tools/abi-conformance -out:/tmp/abi-conformance` — `odin check .` does not descend into the separate `abi_conformance` package, so the tools build is verified explicitly), zero warnings, zero errors.
3. `grep -rn "release: latest" .github/workflows/` returns nothing; `release: dev-2026-11a` present in both workflows.
4. README.adoc: dev-2026-11a identity block present (tag + odin version string + artifact + sha256), dev-2026-05 note gone, first [source,odin] block intact (doc probe green proves it).
5. syscall/ unchanged (or changed only by compiler-demanded call-site fixes with stub twins mirrored); all #asserts compiled.
6. D-09 outcome recorded: integration test ran locally, or host-run/skip fallback documented.
7. Flagged items surfaced, not silently dropped: TOOL-01 unclassified probe row, examples/examples chore awaiting user nod.
</verification>

