# Feature Research

**Domain:** Odin bindings to the Linux Landlock kernel ABI — feature landscape beyond the mapped v1–v9 surface
**Researched:** 2026-11-09
**Confidence:** HIGH (all version claims verified against live kernel git tags and kernel.org docs dated October 2026)

## Headline Answer

**The ABI head is NOT still v9.** The ABI has advanced to **v12**:

| ABI | Linux release | New surface |
|-----|--------------|-------------|
| v9  | 7.1 | `LANDLOCK_ACCESS_FS_RESOLVE_UNIX` — already mapped by the library |
| v10 | 7.2 | UDP network rights + per-object/quiet audit suppression |
| v11 | 7.3 | `LANDLOCK_RESTRICT_SELF_NO_NEW_PRIVS` |
| v12 | master (≈7.4, unreleased as of 2026-11-09) | Namespace + capability permission rules |

Verification method: `include/uapi/linux/landlock.h` fetched from torvalds/linux tags v6.17…v7.3 and master on 2026-11-09; `RESOLVE_UNIX` first appears at v7.1, `LANDLOCK_ACCESS_NET_BIND_UDP` + `LANDLOCK_ADD_RULE_QUIET` at v7.2, `LANDLOCK_RESTRICT_SELF_NO_NEW_PRIVS` at v7.3, `LANDLOCK_PERMISSION_NAMESPACE_USE` only at master. Docs: docs.kernel.org "Landlock: unprivileged access control" (dated October 2026) shows the v12-era best-effort compatibility switch (`case 8 ... 10: ~NO_NEW_PRIVS`, "Removes LANDLOCK_PERMISSION_* for ABI < 12") and states "Network rules (since ABI v4 for TCP and v10 for UDP)", "Capability rules (since ABI v12)", "Namespace rules (since ABI v12)".

## Feature Landscape

### Already covered — explicitly out of this milestone's scope

- All filesystem access rights through bit 16 (`LANDLOCK_ACCESS_FS_RESOLVE_UNIX`, ABI v9, Linux 7.1). **No new FS access right exists at the ABI head** — the header's FS block (bits 0–16) is unchanged from v9 through master. The kernel docs' still-unrestricted-syscalls warning (chdir/stat/flock/chmod/chown/setxattr/utime/fcntl/access) remains; nothing merged wraps those.
- TCP bind/connect (v4), scopes (v6), restrict-self logging bits bit0–2 (v7), TSYNC (v8). Confirmed unchanged in the master header.

### Table Stakes (a binding claiming ABI-head parity must have these)

| Feature | ABI / Kernel | UAPI constants | Why Expected | Complexity | Notes |
|---------|--------------|----------------|--------------|------------|-------|
| UDP bind/connect-send network rights | v10 / **Linux 7.2** | `LANDLOCK_ACCESS_NET_BIND_UDP` (1ULL<<2), `LANDLOCK_ACCESS_NET_CONNECT_SEND_UDP` (1ULL<<3) | DNS and any UDP-using app is unsandboxable without them; they're in the shipped `handled_access_net` example | LOW | Reuse existing `LANDLOCK_RULE_NET_PORT` + `landlock_net_port_attr` — only two new bits in `Access_Net_Flags`. Semantics: `CONNECT_SEND_UDP` covers setting a socket's remote port or sending a datagram; `BIND_UDP` port 0 = ephemeral range; auto-bind on first send needs `BIND_UDP` on port 0 (or pre-bound socket). IPv6 `AF_UNSPEC` sendto unsupported (use NULL address). Gating: extends the compat chain after `case 9` ("Removes LANDLOCK_ACCESS_NET_*_UDP for ABI < 10") |
| `LANDLOCK_RESTRICT_SELF_NO_NEW_PRIVS` | v11 / **Linux 7.3** | `LANDLOCK_RESTRICT_SELF_NO_NEW_PRIVS` (1U<<4) | Removes the mandatory separate `prctl(PR_SET_NO_NEW_PRIVS)`; docs example uses it exclusively on ABI ≥ 11 | LOW | Semantics: no_new_privs set iff `landlock_restrict_self(2)` succeeds; requires a ruleset; composes with TSYNC (propagates to sibling threads). Binding support = new `Restrict_Flag`, builder option that suppresses the caller-side prctl when the flag is available (docs: `if (!(restrict_flags & LANDLOCK_RESTRICT_SELF_NO_NEW_PRIVS) && prctl(...))`) |

### Differentiators (advantage, optional relative to shipped kernels)

| Feature | ABI / Kernel | UAPI constants | Value Proposition | Complexity | Notes |
|---------|--------------|----------------|-------------------|------------|-------|
| Quiet / audit-suppression flags | v10 / **Linux 7.2** | `LANDLOCK_ADD_RULE_QUIET` (add_rule flags, 1U<<0); ruleset_attr fields `quiet_access_fs`, `quiet_access_net`, `quiet_scoped` (all `__u64`) | Lets callers silence expected denials (compat shims) without losing the audit trail for surprises. Unique among bindings if implemented | MEDIUM | Constraints: quiet_* must be a **subset** of handled_access_fs/net/scoped; per-object quiet works via `LANDLOCK_ADD_RULE_QUIET` on path rules (empty `allowed_access` permitted when the flag is set — a "mark quiet without granting" rule); `quiet_scoped` needs no object marking. Builder API: quiet set + per-rule quiet option + gating + validation error for subset violations |
| Namespace-use permission rules | v12 / **master (≈7.4)** | `LANDLOCK_PERMISSION_NAMESPACE_USE` (1ULL<<0); `LANDLOCK_RULE_NAMESPACE`; `struct landlock_namespace_attr { permissions; allowed_namespace_types; quiet_namespace_types }` | First per-category permission model — denies `unshare/clone/setns/open_tree/fsmount` namespace acquisition (incl. anonymous mount namespaces) | HIGH | New rule type + new attr struct + new `handled_permissions` ruleset field (extends the ruleset-attr size tripline). Semantics: unknown `CLONE_NEW*` bits silently ignored (forward compat); members already held are implicitly allowed; empty rule (no allowed and no quiet bits) → `-ENOMSG`, checked on raw input before masking. Interplay: non-user namespaces additionally need `CAP_SYS_ADMIN` allowed when capability permission is also handled; each handled permission must independently allow |
| Capability-use permission rules | v12 / **master (≈7.4)** | `LANDLOCK_PERMISSION_CAPABILITY_USE` (1ULL<<1); `LANDLOCK_RULE_CAPABILITY`; `struct landlock_capability_attr { permissions; allowed_capabilities; quiet_capabilities }` | Restricts *exercise* of `CAP_*` (even via `CLONE_NEWUSER` grants, which `PR_SET_NO_NEW_PRIVS` cannot block). Pairs with namespace rules to close the userns→CAP_SYS_ADMIN escalation path | HIGH | Same model as namespace rules; bits above `CAP_LAST_CAP` silently ignored; `-ENOMSG` on empty rule; purely restrictive (never grants). Gating: both v12 permissions removed for ABI < 12 in the compat switch |
| Errata query | no ABI bump / **Linux 6.15** (uapi flag present from v6.15; errata docs 1–4) | `LANDLOCK_CREATE_RULESET_ERRATA` (1U<<1) | Lets the probe/CI distinguish erratum-affected kernels (TCP mis-identification, scoped-signal same-process, disconnected dirs, whiteout creation) | LOW | Kernel docs warn most apps should NOT gate on errata — expose as probe/CI support, not builder API. Cheap since the syscall wrapper already exists |

### Anti-Features (deliberately do NOT wrap)

| Anti-Feature | Why Tempting | Why Problematic | Alternative |
|--------------|--------------|-----------------|-------------|
| MPTCP bind/connect rights (`LANDLOCK_ACCESS_NET_BIND_MPTCP` etc.) | Mailing-list series (Sept 2026, Günther Noack) bumps ABI to 12 | **Not merged** — absent from torvalds/master landlock.h on 2026-11-09; its "bump to 12" target was overtaken by the capability/namespace series (v12), so it will renumber (≥13). Binding constants for unmerged ABIs guarantees wrong gating on release | Revisit when the series lands in a tagged kernel; the repo's `#assert` tripline pattern makes later addition safe |
| Speculative FS rights for chdir/stat/chmod/… | Kernel docs list them as future evolutions | No patch series merged; constants don't exist | Keep the compile-time `ABI_FS_ALL == V9` assert; it will fail loudly when the head actually moves, which is the desired tripwire |
| Gating on errata bits in the builder | "Correctness" appeal | Docs explicitly warn misuse can *reduce* protection (disabling sandbox on unfixed erratum); errata are about relaxations | Surface errata via the conformance probe / CI matrix only |

## Feature Dependencies

```
[UDP rights (v10)] ──requires──> [LANDLOCK_RULE_NET_PORT layer (existing, v4)]
                                 (same rule type/attr; only new bits)

[Quiet flags (v10)] ──requires──> [handled_* sets in ruleset_attr]
    └──enhances──> [UDP rights] (quiet_access_net needs handled_access_net)
    └──enhances──> [capability/namespace rules v12] (quiet_* in their rule attrs)

[NO_NEW_PRIVS flag (v11)] ──requires──> [restrict-flag plumbing (existing v7/v8)]
    └──changes──> [apply() prctl path] (skip caller-side prctl when available)

[Capability/namespace (v12)] ──requires──> [new handled_permissions field]
    └──requires──> [two new rule types + attrs] (extends struct-size tripline)
    └──conflicts-with-idea──> [HANDLED_DEFAULT] (permissions are NOT access rights;
        adding them to the default handled set would deny-by-default all
        unshare/setns — a deliberate decision, not a mechanical extension)
```

### Dependency Notes

- **Gating-table order is load-bearing:** the docs compat switch chains `case 9 → strip UDP`, `case 10 → strip NNP`, `case 11 → strip permissions`. The library's cumulative `ABI_FS_V1..V9` gating chain must extend in exactly this order; a wrong insertion point silently over-grants on mid-range kernels.
- **`handled_permissions` extends `landlock_ruleset_attr`** — the attr-size `#assert` tripline must be extended in the same commit, or `create_ruleset` passes the wrong size on v12 kernels.
- **TSYNC + NNP compose**: NNP propagates to siblings under TSYNC; `LOG_SUBDOMAINS_OFF` with `ruleset_fd=-1` + TSYNC propagates without creating a domain (existing v7/v8 surface interplay worth a test).

## MVP Definition

### Launch With (ABI-head parity, per milestone directive)

- [ ] UDP `BIND_UDP` / `CONNECT_SEND_UDP` bits + gating (v10, in shipped 7.2 kernels) — table stakes
- [ ] `LANDLOCK_RESTRICT_SELF_NO_NEW_PRIVS` + conditional prctl elision (v11, shipped 7.3) — table stakes
- [ ] Capability + namespace permission rules, `handled_permissions`, quiet_* in rule attrs (v12, master) — the milestone says "all of ABI head"; v12 kernels will ship within the milestone window
- [ ] Extend gating tables + `#assert` triplines through v12; update conformance probe ABI expectations in kernel-matrix CI

### Add After Validation (v1.x)

- [ ] Quiet audit-suppression builder surface (ruleset-level quiet_* subsets + `LANDLOCK_ADD_RULE_QUIET` per-rule quiet-only rules) — v10 kernels; medium complexity, distinct API surface
- [ ] `LANDLOCK_CREATE_RULESET_ERRATA` probe reporting in CI/VM matrix — cheap, kernel 6.15+

### Future Consideration (v2+)

- [ ] MPTCP network rights — blocked on upstream merge; re-scout the series at milestone end
- [ ] Bindings for future FS rights (chdir/stat family) — nothing merged; the existing compile-time tripline is the correct guard

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| UDP rights + gating | HIGH | LOW | P1 |
| `NO_NEW_PRIVS` restrict flag | HIGH | LOW | P1 |
| Capability/namespace permission rules | HIGH | HIGH | P1 |
| Gating/tripline extension to v12 | HIGH (correctness) | LOW | P1 |
| Quiet audit suppression | MEDIUM | MEDIUM | P2 |
| Errata probe | LOW | LOW | P2 |
| MPTCP rights | MEDIUM | MEDIUM | P3 (blocked upstream) |

## Competitor Feature Analysis

| Feature | rust-landlock | go-landlock | Our plan |
|---------|---------------|-------------|----------|
| UDP (v10) | in progress upstream | not yet | ship with v12 work |
| Quiet flags | not exposed | not exposed | differentiator |
| Capability/namespace (v12) | not exposed | not exposed | first-mover |
| Errata | not exposed | not exposed | probe-only |

*[INFERENCE on competitor status: based on the rust-landlock compat.rs source surfacing in search (still keyed to older ABI enums); not deeply audited — the Architecture researcher may confirm.]*

## Sources

- torvalds/linux `include/uapi/linux/landlock.h` at tags v6.17, v6.18, v6.19, v7.0, v7.1, v7.2, v7.3, master (fetched 2026-11-09 via raw.githubusercontent.com) — feature-presence probe
- docs.kernel.org/userspace-api/landlock.html (dated October 2026) — ABI switch example, UDP/permission semantics, errata 1–4, `NO_NEW_PRIVS` flag docs
- kernsec.org LSM-ML: UDP series v4–v5 (May–Jun 2026), quiet-flags series v10 (Jun 2026), capability/namespace docs v2 (May–Jul 2026), MPTCP series (Sept 2026, "Bump ABI to 12", unmerged)
- spinics/stable: errata interface backported to 6.13 stable (originally merged ≥ v6.15; uapi flag verified present at tag v6.15, absent at v6.14)
- wireguard-linux.git commit ae97330 (RESOLVE_UNIX, lore 2026-03-27)

---
*Feature research for: odin-landlock ABI-head parity milestone*
*Researched: 2026-11-09*
