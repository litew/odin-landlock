# Architecture Research: ABI-Head Integration into the Existing Layering

**Domain:** Odin Landlock library — integrating kernel ABI v10–v12 surface into the existing strict-layered architecture
**Researched:** 2026-11-09
**Confidence:** HIGH for ABI head composition (verified against kernel master sources and a live kernel probe on 2026-11-09); MEDIUM for unreleased-kernel mappings (v11/v12 ship in the in-development 7.3)

## ABI Head Composition (grounding)

What the existing v1–v9 surface must be extended with, per the current kernel UAPI (`include/uapi/linux/landlock.h`, Linus master, fetched 2026-11-09) — each kind lands differently, which is what drives the boundaries below:

| New surface | ABI | Kernel | Kind |
|---|---|---|---|
| `LANDLOCK_ACCESS_NET_BIND_UDP`, `LANDLOCK_ACCESS_NET_CONNECT_SEND_UDP` | v10 | 7.2 (released) | new bits in existing net dimension |
| `quiet_access_fs` / `quiet_access_net` / `quiet_scoped` fields in `landlock_ruleset_attr`; per-rule `LANDLOCK_ADD_RULE_QUIET` flag for `landlock_add_rule(2)` | v10 | 7.2 | struct growth + new add-rule flag (cross-cutting audit knob) |
| `LANDLOCK_RESTRICT_SELF_NO_NEW_PRIVS` (1U<<4) — sets no_new_privs iff enforcement succeeds; removes the need for a prior `prctl(PR_SET_NO_NEW_PRIVS)` | v11 | 7.3 (in dev) | new bit in existing restrict-flags dimension |
| `handled_permissions` field (ruleset attr → 56 bytes); `LANDLOCK_PERMISSION_NAMESPACE_USE` / `LANDLOCK_PERMISSION_CAPABILITY_USE`; two new rule types `LANDLOCK_RULE_NAMESPACE` (`landlock_namespace_attr`, 24 bytes) and `LANDLOCK_RULE_CAPABILITY` (`landlock_capability_attr`, 24 bytes) | v12 | 7.3 (in dev) | **new access dimension** with two rule families |
| `LANDLOCK_CREATE_RULESET_ERRATA` flag + errata bitmask (4 errata so far) | since 6.15 (v7 era) | works on all current kernels | probe-only surface (docs: do not gate enforcement on errata) |

Verification trail (all 2026-11-09):
- **Live kernel probe** on this workstation (7.2.11-300.fc45.x86_64): `landlock_create_ruleset(NULL, 0, VERSION)` → **abi=10**; `ERRATA` → **errata=15** (errata 1–4 all fixed). This proves v10 = released kernel 7.2 and that the full v10 surface is testable today without VM work.
- Kernel master `security/landlock/syscalls.c`: `const int landlock_abi_version = 12;` — ABI head is v12. Its `build_check_abi()` pins `ruleset_attr` at 56 bytes, `path_beneath_attr` 12, `net_port_attr` 16, `namespace_attr` 24, `capability_attr` 24 — the exact values our `#assert`s must match.
- Commit dates in `security/landlock` history: UDP bind/send (2026-06-13) and quiet flags (2026-06-14) merged via tag `landlock-7.2-rc1` (2026-06-19) → v10 = 7.2. `LANDLOCK_RESTRICT_SELF_NO_NEW_PRIVS` committed 2026-08-15 and capability/namespace enforcement 2026-10-20, both after the 7.2 window → v11+v12 = in-development 7.3. Kernel docs (`docs.kernel.org/userspace-api/landlock.html`, dated October 2026) document the full v12 compatibility fallthrough chain (`case 10: case 11:` → strip `LANDLOCK_PERMISSION_*`; `case 8 ... 10:` → strip `NO_NEW_PRIVS`).
- **`core:sys/linux` has no Landlock surface at all**: Odin master `core/sys/linux/sys.odin` ends with `// TODO(flysand): landlock_create_ruleset / landlock_add_rule / landlock_restrict_self` (fetched 2026-11-09), and a grep for `CLONE_NEW*` / `CAP_*` constants in core finds nothing. The repo already hand-rolls all Landlock syscalls (openat2 precedent). **Implication: every new syscall-layer addition is fully local to `syscall/`; the toolchain bump does not unlock or block any syscall surface.** `CLONE_NEW*` and `1ULL << CAP_*` constants must be defined in the repo's syscall package.

Note for sibling researchers: v10's kernel-mapping (`v10 = 7.2`) is live-verified; whether v9 landed in 7.1 or in the 7.2 window is not decidable from the landlock-only git log (no 7.1 merge tag appears); the `syscall.odin` per-version comments should be re-checked when writing ABI tables.

## Target Architecture (integration view)

The one-way layering is unchanged; new surface threads through it without adding layers or import edges:

```text
┌────────────────────────────────────────────────────────────────────────┐
│                     Consumers / Tools (unchanged role)                  │
│  examples/*    tools/abi-conformance  ← + new checks per feature kind   │
└────────┬───────────────────────────────────────────────────────────────┘
         │ import landlock "../.."
         ▼
┌────────────────────────────────────────────────────────────────────────┐
│                 landlock (policy layer) — root pkg                       │
│  Builder API (+UDP/quiet/NNP/permission knobs)                          │
│  ABI gating: cumulative chains V1..V12 per dimension + tripwires        │
│  apply orchestration: versioned attr sizing, conditional prctl          │
│  typed results: applied/omitted pairs per dimension incl. .Permission   │
└────────┬───────────────────────────────────────────────────────────────┘
         │ import "syscall" (local)  ← same seam, extended Apply_Ops
         ▼
┌────────────────────────────────────────────────────────────────────────┐
│                  syscall (raw Landlock interface)                        │
│  constants/enums: +UDP net bits, +Add_Rule_Quiet, +No_New_Privs,        │
│                   +Permission_Flag, +CLONE_NEW*, +CAP_*                 │
│  attr structs: Ruleset_Attr 24/48/56 (versioned size), +Namespace_Attr, │
│                +Capability_Attr (24 each) — all with #assert pins       │
│  wrappers: create_ruleset(+explicit size), add_rule generic already     │
│            takes flags; +add_namespace_rule, +add_capability_rule,      │
│            +probe_errata; stub twins for every new proc                 │
└────────┬───────────────────────────────────────────────────────────────┘
         │ import "core:sys/linux"  (unchanged boundary — core has NO
         │ landlock surface; only generic syscall/errno/fd plumbing)
         ▼
┌────────────────────────────────────────────────────────────────────────┐
│  Linux kernel — landlock ABI v1..v12 (5.13 → 7.3)                        │
└────────────────────────────────────────────────────────────────────────┘
```

**Boundary invariants that must survive the extension:**

1. `landlock` never touches raw syscalls; everything funnels through the local `syscall` package and the `Apply_Ops` proc-struct seam.
2. `syscall` never imports `landlock`; it depends only on `core:sys/linux`/`core:sys/unix`/`core:os`.
3. `core:sys/linux` gains no dependency for this milestone (verified: it ships no Landlock or CAP/CLONE_NEW constants).
4. Typed results everywhere: new failure sites (below) map into the existing `Policy_Error{kind, cause, raw_errno, validation}` taxonomy — never new return styles.

## Component Boundaries: where each feature kind lands

Ownership rule of thumb, matching the existing design: **constants and struct layout live in `syscall`; policy semantics, gating, and orchestration live in `landlock`; kernel interaction mechanics live in the Linux impl + stub twins; observability and irreversibility handling live in consumers.**

| Feature kind | syscall layer owns | landlock layer owns | New failure sites (typed) |
|---|---|---|---|
| **UDP net rights** (v10) | `Access_Net_Flag.Bind_UDP`, `.Connect_Send_UDP` enum members; `Net_Port_Attr` unchanged (16 bytes); reuse `add_net_port_rule` as-is | Extend `ABI_NET_V4` chain with `ABI_NET_V10`; builder procs `allow_udp_bind(port)` / `allow_udp_send(port)`; UDP auto-bind note: when both UDP rights are handled, an unbound socket's first send auto-binds an ephemeral port → the kernel docs' grant-`BIND_UDP`-on-port-0 pattern should be a builder convenience (e.g. `allow_udp_ephemeral_bind()`), not left to each caller | None new — existing `add_rule_to_ruleset` errno path (EINVAL/E2BIG/ENOMSG classification) covers it |
| **Quiet audit suppression** (v10) | `Ruleset_Attr` gains `Quiet_Access_FS/Net`, `Quiet_Scoped` (48-byte layout); `Add_Rule_Flag.Quiet` constant; `create_ruleset` must take an **explicit size** (today it hardcodes `size_of(Ruleset_Attr)`); the generic `add_rule_to_ruleset` already forwards `flags` — no signature change | Policy gains quiet sets; validation: quiet ⊆ handled **both dimensions**, per-kernel-masked (kernel also checks subset → EINVAL); builder knobs: per-rule option on `allow_*` procs (`.Quiet` in `Path_Options`-style) and ruleset-level quiet for scopes; result reporting: quiet must appear as an applied/omitted subset of handled — a quiet bit that the running ABI doesn't support is an **omission**, not an error (suppression is advisory) | EINVAL for non-subset quiet (strict: `Invalid_Policy`; classification entry for the subset check) |
| **Restrict flag NO_NEW_PRIVS** (v11) | `Restrict_Self_Flag.No_New_Privs` enum member; `restrict_self(ruleset_fd, flags)` needs **no signature change** | `ABI_RESTRICT_V11 = ABI_RESTRICT_V8 + {.No_New_Privs}`; `handle_flags` accepts it after gating; **apply pipeline change:** when the flag is applied (ABI ≥ 11), skip the separate `prctl(PR_SET_NO_NEW_PRIVS)` call — kernel sets NNP iff `restrict_self` succeeds. On ABI < 11, current prctl-then-restrict order is preserved. This is the only place apply *orchestration* changes shape | None new (flag masking pre-call is already the design; kernel now checks flags before privileges, 2026-08-15 commit, so unknown-flag EINVAL surfaces before NNP-related failures — order the errno classification accordingly) |
| **Permissions dimension** (v12) — namespace + capability | `Permission_Flag` enum (`Namespace_Use`, `Capability_Use`); `Ruleset_Attr.Handled_Permissions` (56-byte layout); `Rule_Type.Namespace`, `.Capability`; `Namespace_Attr`/`Capability_Attr` (24 bytes, `#assert`); `CLONE_NEW*` bitmask constants and `Cap_Bit` enum (`1ULL << CAP_*`) — **hand-rolled here, core has none**; thin `add_namespace_rule` / `add_capability_rule` over the existing generic `add_rule_to_ruleset`; stub twins for both | Model as **one new `Feature_Set` dimension** (`.Permission`), not two: the kernel handles them in one atomic `handled_permissions` field with a single ENOMSG emptiness check, and their composite semantics (non-user namespace requires both the namespace-type rule and the `CAP_SYS_ADMIN` capability rule) are policy-layer concerns. Builder: `allow_namespace_types(flags)` and `allow_capabilities(flags)` accumulate into per-category allow sets; **no rule = all denied** within a handled permission, mirroring deny-by-default FS posture; gating table `ABI_PERMISSION_V12`; `supported_permissions` column in `abi_versions`; `HANDLED_DEFAULT` gains `.Permission` (recommended, see Pattern 4) | New errno sites: **ENOMSG** (all-empty ruleset now includes permissions; map to `Invalid_Policy` — "policy handles nothing"), EINVAL for unknown permission bits, `-ENOMSG` from add-rule when both allowed and quiet member sets are empty (builder validation should reject this eagerly: a rule that allows and quiets nothing is a programming error — the kernel only surfaces it at add-rule time) |
| **Errata probe** (since 6.15, usable today) | `Create_Ruleset_Flag.Errata` constant; `probe_errata() -> (u32, os.Error)` sibling of `get_abi_version` | Surface as data (a field on the probe result / `ABI_Version` info or a `policy_probe()` API) — **explicitly not a gating input**. Kernel docs (Oct 2026) warn that gating enforcement on errata reduces protection; the conformance tool logs it, unit tests can assert the contract | EINVAL on pre-6.15 kernels → `Not_Supported`, swallowed as "no errata info" (probe-only, never fatal) |

Things that deliberately do **not** change layers:
- FS rights: no new FS bits exist at ABI head (RESOLVE_UNIX was v9, already covered). The FS machinery only needs its chain to stay extensible (Pattern 1) for future v13+.
- Scopes: no new `LANDLOCK_SCOPE_*` at head. Scope machinery unchanged except ruleset-level quiet (v10) touches the scoped field's audit behavior.
- Platform split: every new wrapper needs a `syscall_unsupported.odin` stub twin — mechanical, no design change.

## Recommended Project Structure (extension map)

No new files or packages are warranted — the two-package structure absorbs all of it. This is a strength of the existing design; resist any urge to add a `landlock/permissions/` split.

```text
syscall/
├── syscall.odin                # EXTEND: Access_Net_Flag (+2), Restrict_Self_Flag (+1),
│                               #   Permission_Flag (new), Add_Rule_Flag (new),
│                               #   Create_Ruleset_Flag (+Errata), Rule_Type (+2),
│                               #   Ruleset_Attr (7 fields), Namespace_Attr, Capability_Attr,
│                               #   CLONE_NEW* / CAP_* constants, attr-builder procs,
│                               #   #assert pins: 12/16/24/24/24/48/56
├── syscall_linux.odin          # EXTEND: create_ruleset gains explicit size param;
│                               #   +add_namespace_rule, +add_capability_rule,
│                               #   +probe_errata; restrict_self/prctl unchanged
├── syscall_unsupported.odin    # EXTEND: stub twin for every new proc
└── syscall_test_linux.odin     # EXTEND: marshaling test vs real kernel (v10 host is live:
                                #   abi=10, errata=15 on this workstation)

landlock.odin                   # EXTEND: ABI chains ABI_NET_V10, ABI_RESTRICT_V11,
                                #   ABI_PERMISSION_V12 + generalized tripwires;
                                #   abi_versions [10]→[13] + supported_permissions;
                                #   Feature_Set += .Permission; HANDLED_DEFAULT += .Permission;
                                #   builder procs (UDP, quiet options, namespace/capability);
                                #   apply_with_mode: versioned attr size, quiet subset
                                #   validation, conditional prctl, ENOMSG mapping;
                                #   Policy_Result: quiet applied/omitted pair
landlock_test_linux.odin        # EXTEND: fakes for new Apply_Ops entries; per-feature
                                #   errno-path tests; failing-allocator paths for new sets
landlock_integration_test.odin  # EXTEND: one fork per new enforcement check
tools/abi-conformance/main.odin # EXTEND: checks for UDP, quiet, NNP, permissions;
                                #   errata logging; LANDLOCK_EXPECT_ABI accepts 10/11/12
```

Structure rationale: the kernel itself grew in-place (fields appended to `landlock_ruleset_attr`, new rule-type enum values, new flag bits) — mirroring the kernel's own growth axes in-place in our packages keeps the mapping syscall↔struct↔builder one-to-one and auditable, which is the property the `#assert` tripwire system exists to protect.

## Architectural Patterns

### Pattern 1: Cumulative ABI gating chain — generalize the tripwire per dimension (REQUIRED)

**What:** The existing `ABI_FS_V*` cumulative chain with `#assert(ABI_FS_V9 == ABI_FS_ALL)` is the right pattern; the milestone should **promote it from an FS-only assert to one tripwire per dimension**, because v10–v12 add bits in three other dimensions:

```odin
// Cumulative chains (extend, don't redesign):
ABI_NET_V4  :: syscall.Access_Net_Flags{.Bind_TCP, .Connect_TCP}
ABI_NET_V10 :: ABI_NET_V4 + syscall.Access_Net_Flags{.Bind_UDP, .Connect_Send_UDP}
ABI_RESTRICT_V8  :: ABI_RESTRICT_V7 + syscall.Restrict_Self_Flags{.Tsync}
ABI_RESTRICT_V11 :: ABI_RESTRICT_V8 + syscall.Restrict_Self_Flags{.No_New_Privs}
ABI_PERMISSION_V12 :: syscall.Permission_Flags{.Namespace_Use, .Capability_Use}

// Tripwires: a new bit in ANY dimension must be threaded into its chain,
// or compilation fails. This is the single most important scaling mechanism.
#assert(ABI_FS_V9         == ABI_FS_ALL)
#assert(ABI_NET_V10       == ABI_NET_ALL)
#assert(ABI_RESTRICT_V11  == ABI_RESTRICT_ALL)
#assert(ABI_PERMISSION_V12 == ABI_PERMISSION_ALL)
```

**Why per-dimension rather than one mega-assert:** each dimension's `*_ALL` is the enum's full range (Odin `bit_set` complement semantics), so the asserts are independent and each names exactly the chain that must be extended. The existing FS-only assert is asymmetric — a forgotten UDP bit today would compile silently; that is precisely the "adding a right without threading the chain" anti-pattern the ARCHITECTURE.md analysis warns about, so close the gap now while four dimensions exist, not later at eight.

**Version rows:** `abi_versions` grows `[10]` → `[13]`. The struct already carries per-dimension fields; add `supported_permissions`. Rows need no special "empty" handling — v11's row simply equals v10 plus the restrict set, exactly as v6 (scopes) and v7 (log flags) rows do today. Rows 11/12 are only reachable on 7.3+ kernels; on current releases the probe clamps to v10 and rows 11–12 are dormant (the clamp logic `v >= len → last` is already correct).

**When to use:** every future ABI bump = new chain segment + array row + (if a new dimension) a new tripwire. No other mechanism should exist.

### Pattern 2: Versioned ruleset-attr sizing (struct grew 24 → 48 → 56)

**What:** The kernel's `copy_min_struct_from_user` contract (verified in `security/landlock/syscalls.c`, 2026-11-09): size smaller than `offsetofend(handled_access_fs)` → EINVAL; larger than a page → E2BIG; otherwise `copy_struct_from_user` accepts sizes the kernel doesn't know **iff trailing bytes are zero**. The repo today hardcodes `size_of(Ruleset_Attr)` (24) inside `create_ruleset`. Recommendation: make the wrapper take an explicit size, and compute it in the policy layer from the probed ABI:

```odin
RULESET_ATTR_SIZE_V9  :: 24   // handled_fs + handled_net + scoped        (v1..v9)
RULESET_ATTR_SIZE_V10 :: 48   // + quiet_fs + quiet_net + quiet_scoped    (v10, v11)
RULESET_ATTR_SIZE_V12 :: 56   // + handled_permissions                    (v12+)
#assert(size_of(Ruleset_Attr) == RULESET_ATTR_SIZE_V12)   // full struct pin
```

**Trade-off:** the alternative — always pass the full 56-byte struct with ABI-gated fields zeroed — is kernel-legal under `copy_struct_from_user` zero-tail semantics and is one less moving part. It is rejected here because (a) the library's contract is *never to request what the kernel doesn't know* — requested-vs-used reporting is honest only if the syscall argument set matches the ABI table, and (b) with versioned sizing, an ungated field bug manifests as a deterministic E2BIG/EINVAL from the kernel in tests, which doubles as a runtime tripwire. The kernel docs' own example passes `sizeof(ruleset_attr)` with fields masked per-ABI, so both are defensible; pick versioned sizing and stay with it.

### Pattern 3: Seam-first extension of `Apply_Ops` (proc-struct growth)

**What:** New kernel calls enter the apply path only through `Apply_Ops`. Extend the proc-struct with the new operations (`add_namespace_rule`, `add_capability_rule`; `add_net_rule` and the rule-level quiet flag reuse existing entries — the quiet flag is a parameter change, not a new entry; `probe_errata` may stay outside the seam since it is a probe, not an apply step). The existing fakes then extend mechanically: one new `Fake_Call` kind per new op, existing `expect_fake_order` machinery unchanged.

**Why seam-first:** the `Apply_Ops` proc-struct is the shared contract between `landlock`, its default binding to `syscall`, and the test fakes. Extending it in one small change — before or alongside the builder work — is what allows the four feature slices to proceed in parallel afterward without merge conflicts in the seam.

### Pattern 4: New dimension joins `HANDLED_DEFAULT` deliberately (decision to record)

**What:** v12 adds the fourth handled dimension. The deny-by-default go-landlock posture ("handle everything the kernel supports; allow rules are exceptions") argues `.Permission` joins `HANDLED_DEFAULT` at `init`. **Consequence to document loudly:** handling permission use with zero allow rules denies *all* namespace use and *all* capability exercise in the domain — far more disruptive than an unhandled-FS default — and callers opt out via the existing `handle_features`. The alternative (leave `.Permission` out of the default, opt-in only) is defensible for ergonomics but breaks the posture that "old-kernel behavior is best-effort, not unsupported" symmetry and weakens the cap+namespace composite guarantee (kernel docs: gating only one of the two leaves the user-namespace attack path open). Recommended: join the default; note it as a Key Decision for PROJECT.md. `handle_features` validation (unknown dimension on old kernels → omission or strict error) already generalizes.

### Pattern 5: Requested-vs-used reporting scales by dimension, not by feature count

**What:** `Policy_Result` today carries `features_applied/omitted` (dimensions) and `flags_applied/omitted` (restrict flags). The v10–v12 surface maps onto this without new result shapes:
- UDP bits: inside `features_applied/omitted` for `.Network` (no new field).
- `NO_NEW_PRIVS`: inside `flags_applied/omitted` (no new field).
- Permissions: new `.Permission` member participates in `features_*` via the existing `requested_feature_support` intersection.
- Quiet: the one genuinely new reporting concept (it is a per-ruleset and per-rule *property*, not a dimension) — add a `quiet_applied/omitted` pair, reported as a subset of the handled set, omission (never strict-error) semantics because suppression is advisory.

The error taxonomy gains classification entries, not kinds: ENOMSG → `Invalid_Policy`, quiet-subset EINVAL → `Invalid_Policy`, unknown-permission EINVAL → `Invalid_Policy`; existing `apply_result_for_errno` is the single place errno→cause mapping lives.

## Data Flow

All flows keep the one direction: intent (`landlock`) → gated/sized args (`landlock`) → typed errors (`syscall`) → kernel. Backwards only as errno → typed cause.

### 1. UDP network rule (v10)

```text
allow_udp_send(53) ──validation (port range; bit in ABI_NET_ALL)──▶ Policy.rules
apply_with_mode:
  probe_abi → v10 (clamped ≤ known head)
  requested_feature_support: .Network ∩ ABI_NET_V10 → applied/omitted
  create_ruleset(attr 24/48 bytes, Handled_Access_Net gated to ABI_NET_V10)
  add_net_rule(Net_Port_Attr{Connect_Send_UDP, 53}, flags)   [unchanged wrapper]
  prctl(NNP) [+ restrict flags per ABI_RESTRICT chain]
  restrict_self → Policy_Result{features_applied ∋ UDP bits | omitted}
```

### 2. Quiet audit suppression (v10) — cross-cutting

```text
allow_path(p, opts={.Quiet}) / scope_quiet(...) ──▶ Policy.rules[.quiet], Policy.quiet_sets
apply_with_mode:
  validate quiet ⊆ handled (builder masks unknown-ABI bits → omissions)
  create_ruleset(size 48 on v10+, quiet fields populated; size 24 below v10
                 with quiet bits recorded as omitted)
  add_*_rule(..., flags = .Quiet where rule opted in)   [existing flags param]
  restrict_self → Policy_Result{quiet_applied/omitted}
```

### 3. NO_NEW_PRIVS flag (v11)

```text
handle_flags(.No_New_Privs) ──▶ Policy.restrict_requested
apply_with_mode:
  ABI ≥ 11: flags_applied ∋ NNP → SKIP prctl (kernel sets NNP iff restrict succeeds)
  ABI < 11: flags_omitted ∋ NNP → prctl(PR_SET_NO_NEW_PRIVS) as today
  restrict_self(ruleset_fd, gated flags)
  → Policy_Result{flags_applied/omitted}
```

### 4. Permission rule — namespace/capability (v12, new dimension)

```text
allow_namespace_types({.User}) / allow_capabilities({.Sys_Chroot})
  ──validation: bits ∈ known CLONE_NEW*/CAP_* sets; ≥1 member or quiet member──▶ Policy.permission_rules
apply_with_mode:
  probe_abi → v12 only on 7.3+; below: whole dimension omitted
    (strict: .Unsupported_Feature; best-effort: .Partially_Enforced)
  create_ruleset(size 56, Handled_Permissions gated to ABI_PERMISSION_V12)
  add_namespace_rule(Namespace_Attr{Namespace_Use, CLONE_NEWUSER})     [new wrapper]
  add_capability_rule(Capability_Attr{Capability_Use, 1<<CAP_SYS_CHROOT}) [new wrapper]
  restrict_self → Policy_Result{features_applied/omitted ∋ .Permission}
  caller note surfaced in summary: non-user ns needs BOTH the ns rule and the
  CAP_SYS_ADMIN capability rule (kernel composite check) — document in builder docs
```

### 5. Errata probe (adjacent, non-gating)

```text
probe: create_ruleset(NULL, 0, .Errata) → u32 bitmask | Not_Supported
       → surfaced as data on the probe result / conformance log; never gates apply
```

## ABI-Growth Scaling (the "scaling" section, domain-translated)

| Growth event | What changes | What must NOT change |
|---|---|---|
| New bit in existing dimension (v13+) | enum member + chain segment + row + tests | attr struct, wrapper signatures, result shape |
| New attr field (kernel struct grows) | struct + size constant + `#assert` + versioned-size switch entry | create_ruleset semantics (already size-explicit) |
| New rule type | `Rule_Type` member + thin wrapper + stub twin + `Apply_Ops` entry + fake call kind | the generic `add_rule_to_ruleset` |
| New handled dimension | `Feature_Set` member + `ABI_*_V<n>` chain + tripwire + `supported_*` column + (decision) `HANDLED_DEFAULT` | `requested_feature_support` logic, result taxonomy |
| New restrict flag | enum member + `ABI_RESTRICT_V<n>` + row | prctl orchestration (only re-decide if kernel changes NNP semantics again) |

First bottleneck as ABI grows: `abi_versions` row literals get repetitive (12+ rows × 5 columns). If that hurts, the rows can be built as a chain-of-deltas table (each row = previous + that version's increments, mirroring the docs' fallthrough switch 1:1). Defer until it actually hurts — explicit literals are currently the most auditable form.

Second: the docs' kernel-ABI-version→feature mapping is authoritative but prose-distributed (per-flag "since version N" notes). Keep one comment block in `syscall.odin` mirroring the kernel compatibility switch verbatim, so reviewers diff our tables against the kernel's own example rather than re-deriving from man pages.

## Anti-Patterns (specific to this extension)

### Adding surface without the stub twin or the fake
**What:** new wrapper in `syscall_linux.odin`, forget `syscall_unsupported.odin` or the `Fake_Call` kind.
**Why it's wrong:** non-Linux build breaks silently until CI; apply-path tests can't assert order.
**Do instead:** every new wrapper lands with its stub twin + fake entry in the same change; `odin build` for a non-Linux target is the check.

### Requesting v10/v12 fields without ABI-gating the size
**What:** populating quiet/handled_permissions unconditionally, passing 48/56 bytes at an ABI-9 kernel.
**Why it's wrong:** nonzero unknown tail → E2BIG from kernels that don't know the field; a "works on my (7.2) machine" failure class on the ≥5.13 floor.
**Do instead:** Pattern 2 — versioned size + fields masked per the ABI table, exactly like bits are masked today.

### Using errata as a gating input
**What:** skipping enforcement because an erratum isn't fixed.
**Why it's wrong:** kernel docs (Oct 2026) state this explicitly reduces protection ("disabling the sandbox … could leave the system less secure than best-effort").
**Do instead:** expose errata as probe data; at most let the conformance tool annotate results.

### Treating `NO_NEW_PRIVS` as purely a flag (orchestration miss)
**What:** passing the flag but keeping the unconditional prctl call.
**Why it's wrong:** harmless-looking but changes semantics ordering (NNP set even when restrict later fails, on 7.3+), diverging from the flag's contract ("set if and only if enforcement succeeded").
**Do instead:** Pattern/Data-flow 3 — flag applied ⇒ prctl skipped; flag omitted ⇒ prctl as today.

### Splitting the permission dimension into two `Feature_Set` members
**What:** `.Namespace` and `.Capability` as separate dimensions.
**Why it's wrong:** the kernel's handled field is one atomic `handled_permissions` u64 with one ENOMSG emptiness rule; two dimensions would let callers "handle namespace but not capability", silently opening the user-ns→CAP_SYS_ADMIN path the kernel docs call out, and would double the omission bookkeeping for one kernel field.
**Do instead:** one `.Permission` dimension, two rule families under it; composite semantics documented at the builder.

## Integration Points

| Boundary | Communication | Notes for this milestone |
|---|---|---|
| `landlock` ↔ `syscall` | typed attrs + errno-preserving errors | only growth: explicit size param, 2 new add-rule procs, 1 probe; generic add-rule already forwards flags |
| `landlock` ↔ tests | `Apply_Ops` seam | extend seam before builder work (Pattern 3); fakes mirror wrapper-for-wrapper |
| `syscall` ↔ `core:sys/linux` | generic syscall/errno/fd only | no new core deps possible/needed (verified: no Landlock/CLONE_NEW/CAP surface in core master, 2026-11-09) |
| consumers ↔ kernel-matrix CI | `tools/abi-conformance` exit codes + `LANDLOCK_EXPECT_ABI` | v10 checks runnable **today** on released 7.2 (host probe: abi=10, errata=15); v11/v12 checks require a 7.3-rc/mainline VM added to the matrix; each check forks once (irreversibility) |
| policy ↔ caller contract | `Policy_Result` + `is_enforced` | fail-closed contract untouched; quiet/permission omissions flow through existing Partially_Enforced path |

## Suggested Build Order

Dependency-shaped, honoring the PROJECT.md decision to bump the toolchain up front:

```text
S0  Odin nightly bump, whole suite green          SERIALIZES ALL MERGES
     │   (authoring of S1 items may proceed in parallel; landing waits on S0 —
     │    core:sys/linux has zero landlock surface, so S1 content is NOT
     │    toolchain-dependent, only its verification is)
     ▼
S1  syscall contract: constants, enums, attr structs, #assert pins,
     create_ruleset size param, new wrappers + stub twins      [4 slices parallel:
     │      UDP bits | quiet fields+flag | NNP bit | permission structs+consts]
     ▼
S2  Apply_Ops seam extension + fake call kinds + default bindings   [one change,
     │      the shared contract; unblocks all policy-side slices]
     ▼
S3  Gating: ABI_NET_V10 / ABI_RESTRICT_V11 / ABI_PERMISSION_V12 chains,
     │   per-dimension tripwires, abi_versions[13] + supported_permissions,
     │   versioned attr-size table                      [depends only on S1 types]
     ▼
S4  Builder API + apply integration, per feature slice [PARALLEL: UDP | quiet |
     │   NNP+conditional-prctl | permission dimension+HANDLED_DEFAULT decision]
     ▼
S5  Unit tests per slice (fake seam) — parallel WITH each S4 slice;
     integration tests after their slice lands          [fork-per-check discipline]
     ▼
S6  Conformance tool + CI kernel matrix: v10 checks on 7.2 VMs (proven available),
     add 7.3-rc VM for v11/v12 checks, LANDLOCK_EXPECT_ABI 10/11/12, errata logging
```

Serialization edges (the only true ones):
1. **S0 before any merge** — PROJECT.md decision; isolates toolchain churn from feature churn.
2. **S1 → S3** — gating tables consume the constants' types.
3. **S2 → S4** — builder/apply only through the seam.
4. **S4 → S6** — conformance checks encode final semantics.
Everything else (the four feature slices within S1/S4/S5, syscall-vs-policy authoring across S0) parallelizes cleanly because slices touch disjoint symbol sets: net-bits vs restrict-flags vs ruleset-fields vs new-dimension.

**Roadmap implication:** the natural phase boundaries are S0; (S1+S2) as one syscall/seam phase; (S3) as gating phase; (S4+S5-unit) possibly split per feature family; (S5-integration+S6) as the verification phase — with the v11/v12 CI-kernel dependency (7.3-rc availability) flagged as the phase needing deepest research.

## Sources

- Linux kernel UAPI `include/uapi/linux/landlock.h`, Linus master, fetched 2026-11-09 — full v10–v12 surface, struct layouts, flag values: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/include/uapi/linux/landlock.h
- Linux kernel `security/landlock/syscalls.c`, master, fetched 2026-11-09 — `landlock_abi_version = 12`, `build_check_abi` size pins (56/12/16/24/24), `copy_min_struct_from_user` size contract, ENOMSG/EINVAL rules: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/security/landlock/syscalls.c
- Kernel Landlock user docs (dated October 2026) — compatibility fallthrough switch (v10 UDP, v11 NNP, v12 permissions), capability/namespace model, quiet semantics, errata guidance: https://docs.kernel.org/userspace-api/landlock.html
- Kernel git log `security/landlock` (cgit, fetched 2026-11-09) — commit dates and merge tags pinning v10 = 7.2 (`landlock-7.2-rc1`, 2026-06-19) and v11/v12 = 7.3-in-dev (2026-08-15, 2026-10-20); errata interface landed 2025-03-21 (6.15)
- Live kernel probe on 7.2.11-300.fc45.x86_64 (2026-11-09): abi=10, errata=15
- Odin `core/sys/linux/sys.odin`, master, fetched 2026-11-09 — Landlock TODO stubs only, no CLONE_NEW*/CAP_* constants: https://github.com/odin-lang/Odin/blob/master/core/sys/linux/sys.odin
- Repo architecture baseline: `.planning/codebase/ARCHITECTURE.md` (mapped 2026-11-09, commit ac37c87) — not re-researched; extension points cited from it (`Apply_Ops`, `HANDLED_DEFAULT`, `abi_versions`, `#assert` tripwire, wrapper signatures verified directly in `syscall/`)

---
*Architecture research for: Odin Landlock ABI-head parity milestone*
*Researched: 2026-11-09*
