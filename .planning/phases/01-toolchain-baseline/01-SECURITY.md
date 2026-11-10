---
phase: "01"
slug: "toolchain-baseline"
status: verified
threats_open: 0
asvs_level: 1
created: "2026-11-10"
---

# Phase 01 — Security

> Per-phase security contract: threat register, accepted risks, and audit trail.

---

## Trust Boundaries

| Boundary | Description | Data Crossing |
|----------|-------------|---------------|
| Host ↔ build container | Toolchain provenance: the pinned release tarball enters the image build and must be identity-verified before use | Compiler binary (execution trust root for all gate evidence) |
| GitHub Actions ↔ toolchain | CI installs the compiler via `laytan/setup-odin` `release:` input; a floating value silently re-pins the toolchain | Workflow input (pinned tag) |
| Container ↔ host kernel | Landlock syscalls cross the container seccomp filter; weakening the filter to make tests pass is forbidden | Syscalls (landlock_create_ruleset/add_rule/restrict_self) |
| Phase work ↔ library source | Toolchain bump must not churn the hand-rolled syscall layer or its `#assert` layout tripwires | Source diff (expected empty; D-04 no-op) |

---

## Threat Register

| Threat ID | Category | Component | Severity | Disposition | Mitigation | Status |
|-----------|----------|-----------|----------|-------------|------------|--------|
| T-01-01 | Tampering (supply chain) — unverified toolchain artifact | `Containerfile` (local gate substrate) | high | mitigate | Release tarball downloaded by exact URL; `sha256sum --check -` inside the build against digest `65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618` (Containerfile:18-22); same digest published in README.adoc:27 (D-02/D-03). Verified in-repo; reviewer independently matched the upstream GitHub release asset. | closed |
| T-01-02 | Tampering (CI drift) — floating release re-pins toolchain | `.github/workflows/ci.yml:26`, `kernel-matrix.yml:48` | medium | mitigate | Exact tag `release: dev-2026-11a` in both workflows; string `release: latest` absent from `.github/workflows/` (verified by grep) (D-01). | closed |
| T-01-03 | Elevation of privilege — container isolation weakened for Landlock | container runtime (podman seccomp) | medium | mitigate | No seccomp overrides anywhere in the image definition; default containers-common allowlist already permits the three `landlock_*` syscalls (RESEARCH finding 5); D-09 fallback is host run or skip — never `seccomp=unconfined` (plan prohibition). Integration run passed under default seccomp. | closed |
| T-01-04 | Tampering — library contract regression during the bump | `syscall/`, `#assert` chain | low | accept | Phase planned zero source churn; evidence: `syscall/` byte-identical across `3a9f4cb..HEAD`, suite + `#assert` tripwire chain green on the pinned nightly (D-04/D-07). Recorded as accepted risk R-01. | closed |

*Status: open · closed · open — below high threshold (non-blocking)*
*Severity: critical > high > medium > low — only open threats at or above workflow.security_block_on count toward threats_open*
*Disposition: mitigate (implementation required) · accept (documented risk) · transfer (third-party)*

---

## Accepted Risks Log

| Risk ID | Threat Ref | Rationale | Accepted By | Date |
|---------|------------|-----------|-------------|------|
| R-01 | T-01-04 | Phase 1 is a toolchain bump with zero planned source edits; the byte-identical `syscall/` diff plus the green suite + `#assert` chain is the accepted evidence. Literal bit-value truth tests are deferred to Phase 2 (decision D-07). | verifier (Phase 1) + user (D-07, CONTEXT.md) | 2026-11-10 |

---

## Security Audit Trail

| Audit Date | Threats Total | Closed | Open | Run By |
|------------|---------------|--------|------|--------|
| 2026-11-10 | 4 | 4 | 0 | omp orchestrator (L1 grep-depth, ASVS 1; container + CI run evidence) |

---

## Sign-Off

- [x] All threats have a disposition (mitigate / accept / transfer)
- [x] Accepted risks documented in Accepted Risks Log
- [x] `threats_open: 0` confirmed
- [x] `status: verified` set in frontmatter

**Approval:** verified 2026-11-10

---

*Advisory cross-reference (non-security-blocking): code review WR-01 (pin base image by digest) and WR-02 (hardcode the sha256 instead of the overridable `ARG ODIN_SHA256`) are Containerfile hardening suggestions that would deepen T-01-01's mitigation; both are dispositioned `open` in `01-REVIEW-DISPOSITION.md` and tracked there, not here.*
