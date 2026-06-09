/*
    Package landlock builds and applies Linux Landlock policies.

    A policy is deny-by-default over a handled set (the go-landlock model): once
    applied, every access right the running kernel supports is denied unless an
    allow_* rule grants it. policy_init defaults the handled set to all three
    access dimensions (Filesystem, Network, Scope), best-effort to the kernel's
    ABI; narrow it with handle_features (e.g. {.Filesystem} for FS-only).
    Dimensions left out of the handled set are not restricted. Logging and
    thread-sync are opt-in landlock_restrict_self flags, not access dimensions;
    request them with handle_flags (syscall.Restrict_Self_Flags) and read them
    back from Policy_Result.flags_*.

    Typical flow: init, then the allow/scope builder procs (+ handle_flags), then
    apply_strict or apply_best_effort, inspect Policy_Result, then cleanup. apply_strict requires
    the full requested policy; apply_best_effort tolerates older kernels and
    reports the gap via Policy_Result (status, abi_used, features_applied/features_omitted). apply_strict
    returns Enforced or Unsupported_Feature; Partially_Enforced is exclusive to apply_best_effort.
    apply never aborts the process: fail closed by checking is_enforced(result)
    (or the status) — ignoring it leaves the process unsandboxed.
    Landlock enforcement is irreversible; policy_cleanup only frees builder memory.

    Memory: the builder owns its rules/strings with the allocator passed to
    policy_init and frees them in policy_cleanup. Transient buffers used during
    apply (path handles, cstrings, stat info) are freed immediately within the
    procs that create them, so the library leaves nothing for the caller to clean
    up beyond policy_cleanup — no reliance on resetting context.temp_allocator.
    The summary procs return caller-owned strings; free them with the allocator
    passed to the summary proc.

    Feature is a coarse access-dimension view for reporting (Filesystem, Network,
    Scope). Individual filesystem rights (Refer, Truncate, Ioctl_Dev,
    Resolve_Unix, ...) are requested via Path_Access and reported under
    .Filesystem. Restrict_self flags are reported separately in flags_*.
*/
package landlock

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "syscall"

@(private)
ABI_Version :: struct {
	version:              int,
	supported_access_fs:  syscall.Access_FS_Flags,
	supported_access_net: syscall.Access_Net_Flags,
	supported_scoped:     syscall.Scope_Flags,
	supported_restrict:   syscall.Restrict_Self_Flags,
}

@(private)
ABI_Error :: enum int {
	Not_Supported = -1,
	None          = 0,
}

@(private)
ABI_FS_V1 :: syscall.Access_FS_Flags {
	.Execute,
	.Write_File,
	.Read_File,
	.Read_Dir,
	.Remove_Dir,
	.Remove_File,
	.Make_Char,
	.Make_Dir,
	.Make_Reg,
	.Make_Sock,
	.Make_Fifo,
	.Make_Block,
	.Make_Sym,
}
@(private)
ABI_FS_V2 :: ABI_FS_V1 + syscall.Access_FS_Flags{.Refer}
@(private)
ABI_FS_V3 :: ABI_FS_V2 + syscall.Access_FS_Flags{.Truncate}
@(private)
ABI_NET_V4 :: syscall.Access_Net_Flags{.Bind_TCP, .Connect_TCP}
@(private)
ABI_FS_V5 :: ABI_FS_V3 + syscall.Access_FS_Flags{.Ioctl_Dev}
@(private)
ABI_SCOPE_V6 :: syscall.Scope_Flags{.Abstract_Unix_Socket, .Signal}
@(private)
ABI_RESTRICT_V7 :: syscall.Restrict_Self_Flags {
	.Log_Same_Exec_Off,
	.Log_New_Exec_On,
	.Log_Subdomains_Off,
}
@(private)
ABI_RESTRICT_V8 :: ABI_RESTRICT_V7 + syscall.Restrict_Self_Flags{.Tsync}
@(private)
ABI_FS_V9 :: ABI_FS_V5 + syscall.Access_FS_Flags{.Resolve_Unix}

// ABI_FS_ALL is every filesystem right the library knows. It is the complement
// of the empty set, which Odin masks to the Access_FS_Flag enum's range — so it
// is exactly all enum members and auto-tracks new rights at compile time,
// without chasing the latest ABI_FS_V*. Used to validate masks (reject unknown
// bits), not for kernel-ABI gating.
@(private)
ABI_FS_ALL :: ~syscall.Access_FS_Flags{}

// Drift tripwire: the hand-maintained cumulative chain (ABI_FS_V9) must cover
// every filesystem right the enum defines (ABI_FS_ALL). If a new Access_FS_Flag
// is added but not threaded into the ABI_FS_V* chain, this fails to compile.
#assert(ABI_FS_V9 == ABI_FS_ALL)

@(private)
abi_versions := [10]ABI_Version {
	{version = 0},
	{version = 1, supported_access_fs = ABI_FS_V1},
	{version = 2, supported_access_fs = ABI_FS_V2},
	{version = 3, supported_access_fs = ABI_FS_V3},
	{version = 4, supported_access_fs = ABI_FS_V3, supported_access_net = ABI_NET_V4},
	{version = 5, supported_access_fs = ABI_FS_V5, supported_access_net = ABI_NET_V4},
	{
		version = 6,
		supported_access_fs = ABI_FS_V5,
		supported_access_net = ABI_NET_V4,
		supported_scoped = ABI_SCOPE_V6,
	},
	{
		version = 7,
		supported_access_fs = ABI_FS_V5,
		supported_access_net = ABI_NET_V4,
		supported_scoped = ABI_SCOPE_V6,
		supported_restrict = ABI_RESTRICT_V7,
	},
	{
		version = 8,
		supported_access_fs = ABI_FS_V5,
		supported_access_net = ABI_NET_V4,
		supported_scoped = ABI_SCOPE_V6,
		supported_restrict = ABI_RESTRICT_V8,
	},
	{
		version = 9,
		supported_access_fs = ABI_FS_V9,
		supported_access_net = ABI_NET_V4,
		supported_scoped = ABI_SCOPE_V6,
		supported_restrict = ABI_RESTRICT_V8,
	},
}

Path_Kind :: enum {
	Directory,
	File,
}

Path_Missing_Behavior :: enum {
	// Missing paths are invalid unless the caller explicitly records an omission.
	Require,
	Ignore,
}

Path_Symlink_Behavior :: enum {
	// Follow checks the target type; Reject treats the link itself as invalid.
	Follow,
	Reject,
}

Path_Options :: struct {
	missing: Path_Missing_Behavior,
	symlink: Path_Symlink_Behavior,
}

Path_Access_Flag :: distinct syscall.Access_FS_Flag
Path_Access :: bit_set[Path_Access_Flag;u64]

@(private)
Policy_Path_Rule :: struct {
	kind:      Path_Kind,
	access:    Path_Access,
	path:      string,
	// no_follow resolves the path with openat2(RESOLVE_NO_SYMLINKS) (set when
	// Path_Options.symlink is .Reject), so no path component may be a symlink at
	// apply time — defeating a post-validation symlink swap anywhere in the path.
	no_follow: bool,
}

@(private)
Path_Omission_Reason :: enum {
	Missing,
}

// Policy_Path_Omission records explicit caller-selected omissions, such as an
// ignore-if-missing path, so omitted rules are visible in best-effort results.
@(private)
Policy_Path_Omission :: struct {
	kind:   Path_Kind,
	access: Path_Access,
	path:   string,
	reason: Path_Omission_Reason,
}

@(private)
Policy_Net_Rule :: struct {
	access_net: syscall.Access_Net_Flags,
	port:       u16,
}

Policy :: struct {
	allocator:          mem.Allocator,
	rules_path:         [dynamic]Policy_Path_Rule,
	rules_path_omitted: [dynamic]Policy_Path_Omission,
	rules_network:      [dynamic]Policy_Net_Rule,
	rules_scoped:       syscall.Scope_Flags,
	flags_restricted:   syscall.Restrict_Self_Flags,
	features_requested: Feature_Set,
	features_handled:   Feature_Set,
	initialized:        bool,
}

// HANDLED_DEFAULT is the deny-by-default handled set applied by init:
// every access dimension the running kernel supports is restricted, and allow
// rules are exceptions within it (the go-landlock V<n>.BestEffort() posture).
// Only the three access dimensions are meaningful here; logging/thread-sync
// remain opt-in flags. Individual FS rights (incl. Resolve_Unix) are part of
// .Filesystem.
@(private)
HANDLED_DEFAULT :: Feature_Set{.Filesystem, .Network, .Scope}

path_access_ro_dir :: Path_Access{.Execute, .Read_File, .Read_Dir}
path_access_rw_dir ::
	path_access_ro_dir +
	Path_Access {
			.Write_File,
			.Remove_Dir,
			.Remove_File,
			.Make_Char,
			.Make_Dir,
			.Make_Reg,
			.Make_Sock,
			.Make_Fifo,
			.Make_Block,
			.Make_Sym,
			.Truncate,
		}
path_access_ro_file :: Path_Access{.Execute, .Read_File}
path_access_rw_file :: path_access_ro_file + Path_Access{.Write_File, .Truncate}

// Feature is a coarse access *dimension* — the deny-by-default knobs of a
// ruleset. Logging and thread-sync are NOT here: they are opt-in
// landlock_restrict_self flags (syscall.Restrict_Self_Flags) configured via
// handle_flags and reported in Policy_Result.flags_*.
Feature :: enum {
	Filesystem,
	Network,
	Scope,
}
Feature_Set :: bit_set[Feature;u64]

// Policy_Status is the coarse outcome of apply: did the requested policy take
// effect? The reason for a non-enforced outcome (unavailable kernel, invalid
// policy, unsupported feature, ...) lives in Policy_Result.error.kind.
Policy_Status :: enum {
	Enforced,
	Partially_Enforced,
	Not_Enforced,
}

Policy_Error_Kind :: enum {
	None,
	Unavailable,
	Disabled,
	Unsupported_Platform,
	Unsupported_Feature,
	Invalid_Policy,
	Permission_Denied,
	No_New_Privs_Failed,
	Syscall_Failed,
	Allocation_Failed,
	Skipped_For_Test,
}

Policy_Error_Cause :: enum {
	None,
	ABI_Probe,
	Create_Ruleset,
	Add_Rule,
	Restrict_Self,
	Set_No_New_Privs,
	Validation,
	Unsupported_Feature,
	Unsupported_Platform,
	Allocation,
	Test_Harness,
}

Policy_Validation_Failure :: enum {
	None,
	Policy_Not_Initialized,
	Empty_Path,
	Empty_Access,
	Unsupported_Access_Mask,
	Missing_Path,
	Wrong_Path_Type,
	Symlink_Rejected,
	Write_File_Without_Truncate,
	Empty_Policy,
	Empty_Handled_Set,
	Rule_For_Unhandled_Feature,
	Invalid_Path,
}

Policy_Error :: struct {
	kind:            Policy_Error_Kind,
	cause:           Policy_Error_Cause,
	raw_errno:       i32,
	allocator_error: mem.Allocator_Error,
	validation:      Policy_Validation_Failure,
}

Policy_Result :: struct {
	status:             Policy_Status,
	abi_requested:      int,
	abi_used:           int,
	features_handled:   Feature_Set,
	features_requested: Feature_Set,
	features_applied:   Feature_Set,
	features_omitted:   Feature_Set,
	// Restrict_self flags (logging control, thread-sync) are opt-in toggles, not
	// deny-by-default dimensions, so they are reported separately from features_*.
	flags_requested:    syscall.Restrict_Self_Flags,
	flags_applied:      syscall.Restrict_Self_Flags,
	flags_omitted:      syscall.Restrict_Self_Flags,
	error:              Policy_Error,
}

@(private)
policy_error_none :: proc "contextless" () -> Policy_Error {
	return Policy_Error{kind = .None}
}

@(private)
policy_error_errno :: proc "contextless" (
	kind: Policy_Error_Kind,
	cause: Policy_Error_Cause,
	raw_errno: i32,
) -> Policy_Error {
	return Policy_Error{kind = kind, cause = cause, raw_errno = raw_errno}
}

@(private)
policy_error_allocation :: proc "contextless" (
	allocator_error: mem.Allocator_Error,
) -> Policy_Error {
	return Policy_Error {
		kind = .Allocation_Failed,
		cause = .Allocation,
		allocator_error = allocator_error,
	}
}

@(private)
policy_result_error :: proc "contextless" (
	status: Policy_Status,
	error: Policy_Error,
	abi_requested: int = 0,
	abi_used: int = 0,
	features_handled: Feature_Set = {},
	features_requested: Feature_Set = {},
	features_omitted: Feature_Set = {},
	flags_requested: syscall.Restrict_Self_Flags = {},
	flags_omitted: syscall.Restrict_Self_Flags = {},
) -> Policy_Result {
	return Policy_Result {
		status = status,
		abi_requested = abi_requested,
		abi_used = abi_used,
		features_handled = features_handled,
		features_requested = features_requested,
		features_omitted = features_omitted,
		flags_requested = flags_requested,
		flags_omitted = flags_omitted,
		error = error,
	}
}

// is_enforced reports whether the full requested policy was applied. Use it to
// fail closed: `if !landlock.is_enforced(result) do os.exit(1)`. A
// Partially_Enforced result (some features dropped on an older kernel) is a
// deliberate caller decision, so it is NOT considered enforced here.
is_enforced :: proc "contextless" (result: Policy_Result) -> bool {
	return result.status == .Enforced
}

@(private)
summary_text :: proc "contextless" (result: Policy_Result) -> string {
	switch result.status {
	case .Enforced:
		return "landlock enforced"
	case .Partially_Enforced:
		return "landlock partially enforced"
	case .Not_Enforced:
		return "landlock not enforced"
	}
	return "landlock unknown status"
}

// summary returns an allocated string owned by the caller. Free it with
// delete(summary, allocator) using the same allocator passed here.
summary :: proc(
	result: Policy_Result,
	allocator := context.allocator,
) -> (
	summary: string,
	err: Policy_Error,
) {
	alloc_err: mem.Allocator_Error
	summary, alloc_err = strings.clone(summary_text(result), allocator)
	if alloc_err != nil {
		return "", policy_error_allocation(alloc_err)
	}
	return summary, policy_error_none()
}

// enum_to_string returns the field name of any enum value (e.g. "Enforced"), or
// "Unknown" for an out-of-range value. Used to stringify Policy_Status and error enums for logging.
enum_to_string :: proc(value: $T) -> string where intrinsics.type_is_enum(T) {
	name, ok := reflect.enum_name_from_value(value)
	return ok ? name : "Unknown"
}

// write_feature_set renders a Feature_Set as [Name,Name] in enum declaration
// order.
@(private)
write_feature_set :: proc(builder: ^strings.Builder, features: Feature_Set) {
	strings.write_byte(builder, '[')
	first := true
	for feature in Feature {
		if feature not_in features {
			continue
		}
		if !first {
			strings.write_byte(builder, ',')
		}
		first = false
		fmt.sbprint(builder, feature)
	}
	strings.write_byte(builder, ']')
}

// DEBUG_SUMMARY_CAP is the reserved capacity for debug_summary. The
// rendered line is bounded well under this (labels + a few enum names + four
// short feature-set lists + small integers, ~600 bytes max), so sbprintf never
// needs to grow the builder and cannot fail mid-write. If the output ever
// reaches the cap, the summary is treated as failed rather than returned
// truncated (a truncated security summary would be misleading).
@(private)
DEBUG_SUMMARY_CAP :: 1024

// debug_summary returns an allocated, caller-owned status line. Free it
// with delete(summary, allocator) using the same allocator passed here.
debug_summary :: proc(
	result: Policy_Result,
	allocator := context.allocator,
) -> (
	summary: string,
	err: Policy_Error,
) {
	builder, alloc_err := strings.builder_make_len_cap(0, DEBUG_SUMMARY_CAP, allocator)
	if alloc_err != nil {
		return "", policy_error_allocation(alloc_err)
	}

	fmt.sbprintf(
		&builder,
		"status=%v\nabi_requested=%d\nabi_used=%d\nfeatures_handled=",
		result.status,
		result.abi_requested,
		result.abi_used,
	)
	write_feature_set(&builder, result.features_handled)
	fmt.sbprint(&builder, "\nfeatures_requested=")
	write_feature_set(&builder, result.features_requested)
	fmt.sbprint(&builder, "\nfeatures_applied=")
	write_feature_set(&builder, result.features_applied)
	fmt.sbprint(&builder, "\nfeatures_omitted=")
	write_feature_set(&builder, result.features_omitted)
	fmt.sbprintf(
		&builder,
		"\nflags_requested=%w\nflags_applied=%w\nflags_omitted=%w",
		result.flags_requested,
		result.flags_applied,
		result.flags_omitted,
	)
	// tsync reflects whether the restriction was applied to ALL threads. When off,
	// only the calling thread (and its future children) is sandboxed — a footgun
	// for processes that spawned threads before apply.
	fmt.sbprint(&builder, .Tsync in result.flags_applied ? "\ntsync=on" : "\ntsync=off")
	fmt.sbprintf(
		&builder,
		"\nerror_kind=%v\nerror_cause=%v\nvalidation=%v\nraw_errno=%d\n",
		result.error.kind,
		result.error.cause,
		result.error.validation,
		result.error.raw_errno,
	)

	// The summary must fit within the reserved capacity. Reaching it means the
	// builder either grew (our bound was wrong) or sbprintf hit an allocation
	// failure and truncated — either way, fail rather than return a partial line.
	summary = strings.to_string(builder)
	if len(summary) >= DEBUG_SUMMARY_CAP {
		strings.builder_destroy(&builder)
		return "", policy_error_allocation(.Out_Of_Memory)
	}
	return summary, policy_error_none()
}

@(private)
policy_result_unavailable :: proc "contextless" (raw_errno: i32) -> Policy_Result {
	return policy_result_error(
		.Not_Enforced,
		policy_error_errno(.Unavailable, .ABI_Probe, raw_errno),
	)
}

@(private)
policy_result_disabled :: proc "contextless" (raw_errno: i32) -> Policy_Result {
	return policy_result_error(.Not_Enforced, policy_error_errno(.Disabled, .ABI_Probe, raw_errno))
}

@(private)
policy_result_unsupported_platform :: proc "contextless" () -> Policy_Result {
	return policy_result_error(
		.Not_Enforced,
		Policy_Error{kind = .Unsupported_Platform, cause = .Unsupported_Platform},
	)
}

@(private)
policy_result_unsupported_feature :: proc "contextless" (feature: Feature) -> Policy_Result {
	return policy_result_error(
		.Partially_Enforced,
		Policy_Error{kind = .Unsupported_Feature, cause = .Unsupported_Feature},
		features_omitted = Feature_Set{feature},
	)
}

@(private)
policy_result_invalid_policy :: proc "contextless" (
	validation: Policy_Validation_Failure = .None,
) -> Policy_Result {
	return policy_result_error(.Not_Enforced, policy_error_invalid_policy(validation))
}

@(private)
policy_result_permission_denied_for :: proc "contextless" (
	cause: Policy_Error_Cause,
	raw_errno: i32,
) -> Policy_Result {
	return policy_result_error(
		.Not_Enforced,
		policy_error_errno(.Permission_Denied, cause, raw_errno),
	)
}

@(private)
policy_result_no_new_privs_failed :: proc "contextless" (raw_errno: i32) -> Policy_Result {
	return policy_result_error(
		.Not_Enforced,
		policy_error_errno(.No_New_Privs_Failed, .Set_No_New_Privs, raw_errno),
	)
}

@(private)
policy_result_syscall_failed :: proc "contextless" (
	cause: Policy_Error_Cause,
	raw_errno: i32,
) -> Policy_Result {
	return policy_result_error(
		.Not_Enforced,
		policy_error_errno(.Syscall_Failed, cause, raw_errno),
	)
}

@(private)
policy_result_skipped_for_test :: proc "contextless" () -> Policy_Result {
	return policy_result_error(
		.Not_Enforced,
		Policy_Error{kind = .Skipped_For_Test, cause = .Test_Harness},
	)
}

@(private)
policy_error_invalid_policy :: proc "contextless" (
	validation: Policy_Validation_Failure = .None,
) -> Policy_Error {
	return Policy_Error{kind = .Invalid_Policy, cause = .Validation, validation = validation}
}

@(private)
policy_error_unsupported_builder_feature :: proc "contextless" (
	validation: Policy_Validation_Failure = .None,
) -> Policy_Error {
	return Policy_Error {
		kind = .Unsupported_Feature,
		cause = .Unsupported_Feature,
		validation = validation,
	}
}

@(private)
is_ready :: proc "contextless" (policy: ^Policy) -> bool {
	return policy != nil && policy.initialized
}

@(private)
path_access_to_syscall :: proc "contextless" (access: Path_Access) -> syscall.Access_FS_Flags {
	return transmute(syscall.Access_FS_Flags)access
}

// path_access_is_valid checks that the mask contains only rights this library
// knows about. ~ABI_FS_ALL is every bit that is NOT a known FS right; if access
// has none of those bits set, every requested right is recognized. This is a
// static validity check (rejects garbage/unknown bits), not a kernel/ABI support
// check — the running kernel's ABI is applied later via abi_versions.
@(private)
path_access_is_valid :: proc "contextless" (access: Path_Access) -> bool {
	return (transmute(u64)path_access_to_syscall(access) & ~transmute(u64)ABI_FS_ALL) == 0
}

@(private)
path_access_is_writable_without_truncate :: proc "contextless" (access: Path_Access) -> bool {
	return .Write_File in access && !(.Truncate in access)
}

@(private)
path_access_validate :: proc "contextless" (access: Path_Access) -> Policy_Error {
	if access == {} {
		return policy_error_invalid_policy(.Empty_Access)
	}
	if !path_access_is_valid(access) {
		return policy_error_unsupported_builder_feature(.Unsupported_Access_Mask)
	}
	if path_access_is_writable_without_truncate(access) {
		return policy_error_invalid_policy(.Write_File_Without_Truncate)
	}
	return policy_error_none()
}

@(private)
path_kind_matches_file_type :: proc "contextless" (
	kind: Path_Kind,
	file_type: os.File_Type,
) -> bool {
	switch kind {
	case .Directory:
		return file_type == .Directory
	case .File:
		return file_type == .Regular
	}
	return false
}

@(private)
path_validation_stat :: proc(
	path: string,
	kind: Path_Kind,
	options: Path_Options,
) -> (
	omit: bool,
	err: Policy_Error,
) {
	if options.symlink == .Reject {
		link_info, link_err := os.lstat(path, context.allocator)
		if link_err != nil {
			if link_err == .Not_Exist && options.missing == .Ignore {
				return true, policy_error_none()
			}
			if link_err == .Not_Exist {
				return false, policy_error_invalid_policy(.Missing_Path)
			}
			return false, policy_error_invalid_policy(.Wrong_Path_Type)
		}
		defer os.file_info_delete(link_info, context.allocator)
		if link_info.type == .Symlink {
			return false, policy_error_invalid_policy(.Symlink_Rejected)
		}
		if !path_kind_matches_file_type(kind, link_info.type) {
			return false, policy_error_invalid_policy(.Wrong_Path_Type)
		}
		return false, policy_error_none()
	}

	info, stat_err := os.stat(path, context.allocator)
	if stat_err != nil {
		if stat_err == .Not_Exist && options.missing == .Ignore {
			return true, policy_error_none()
		}
		if stat_err == .Not_Exist {
			return false, policy_error_invalid_policy(.Missing_Path)
		}
		return false, policy_error_invalid_policy(.Wrong_Path_Type)
	}
	defer os.file_info_delete(info, context.allocator)
	if !path_kind_matches_file_type(kind, info.type) {
		return false, policy_error_invalid_policy(.Wrong_Path_Type)
	}
	return false, policy_error_none()
}

@(private)
policy_note_path_features :: proc(policy: ^Policy) {
	policy.features_requested += Feature_Set{.Filesystem}
}

init :: proc(policy: ^Policy, allocator := context.allocator) -> Policy_Error {
	if policy == nil {
		return policy_error_invalid_policy()
	}

	policy^ = {}
	policy.allocator = allocator

	alloc_err: mem.Allocator_Error
	policy.rules_path, alloc_err = make([dynamic]Policy_Path_Rule, 0, 0, allocator)
	if alloc_err != nil {
		policy^ = {}
		return policy_error_allocation(alloc_err)
	}
	policy.rules_path_omitted, alloc_err = make([dynamic]Policy_Path_Omission, 0, 0, allocator)
	if alloc_err != nil {
		delete(policy.rules_path)
		policy^ = {}
		return policy_error_allocation(alloc_err)
	}

	policy.rules_network, alloc_err = make([dynamic]Policy_Net_Rule, 0, 0, allocator)
	if alloc_err != nil {
		delete(policy.rules_path_omitted)
		delete(policy.rules_path)
		policy^ = {}
		return policy_error_allocation(alloc_err)
	}

	policy.features_handled = HANDLED_DEFAULT
	policy.initialized = true
	return policy_error_none()
}

// handle_features narrows the deny-by-default handled set to the given access
// dimensions (.Filesystem/.Network/.Scope); other dimensions are left
// unrestricted. By default init handles all three. Call e.g.
// handle_features(&p, {.Filesystem}) for filesystem-only sandboxing.
handle_features :: proc(policy: ^Policy, dimensions: Feature_Set) -> Policy_Error {
	if !is_ready(policy) {
		return policy_error_invalid_policy(.Policy_Not_Initialized)
	}
	policy.features_handled = dimensions & HANDLED_DEFAULT
	return policy_error_none()
}

// handle_flags sets the landlock_restrict_self flags to request: audit-logging
// control (.Log_New_Exec_On / .Log_Same_Exec_Off / .Log_Subdomains_Off) and
// thread-sync (.Tsync). Unlike the deny-by-default handled set these are opt-in
// toggles, defaulting to none; this replaces (not ORs) the set. Flags the running
// ABI does not support are dropped at apply and reported in
// Policy_Result.flags_omitted (and fail apply_strict).
handle_flags :: proc(policy: ^Policy, flags: syscall.Restrict_Self_Flags) -> Policy_Error {
	if !is_ready(policy) {
		return policy_error_invalid_policy(.Policy_Not_Initialized)
	}
	policy.flags_restricted = flags
	return policy_error_none()
}

// cleanup frees the builder's heap memory (cloned path strings and the
// owned rule arrays) and resets the struct. It does NOT undo an applied
// landlock restriction — kernel enforcement is irreversible. Safe to call on a
// zero or already-cleaned policy, and safe to call after apply.
cleanup :: proc(policy: ^Policy) {
	if policy == nil || !policy.initialized {
		return
	}

	allocator := policy.allocator
	for rule in policy.rules_path {
		if rule.path != "" {
			delete(rule.path, allocator)
		}
	}
	for omitted in policy.rules_path_omitted {
		if omitted.path != "" {
			delete(omitted.path, allocator)
		}
	}
	delete(policy.rules_path)
	delete(policy.rules_path_omitted)
	delete(policy.rules_network)
	policy^ = {}
}

@(private)
record_omitted_path :: proc(
	policy: ^Policy,
	kind: Path_Kind,
	path: string,
	access: Path_Access,
	reason: Path_Omission_Reason,
) -> Policy_Error {
	for omitted in policy.rules_path_omitted {
		if omitted.kind == kind &&
		   omitted.path == path &&
		   omitted.access == access &&
		   omitted.reason == reason {
			policy_note_path_features(policy)
			return policy_error_none()
		}
	}

	cloned_path, alloc_err := strings.clone(path, policy.allocator)
	if alloc_err != nil {
		return policy_error_allocation(alloc_err)
	}

	_, alloc_err = append(
		&policy.rules_path_omitted,
		Policy_Path_Omission{kind = kind, access = access, path = cloned_path, reason = reason},
	)
	if alloc_err != nil {
		delete(cloned_path, policy.allocator)
		return policy_error_allocation(alloc_err)
	}

	policy_note_path_features(policy)
	return policy_error_none()
}

allow_path :: proc(
	policy: ^Policy,
	kind: Path_Kind,
	path: string,
	access: Path_Access,
	options := Path_Options{},
) -> Policy_Error {
	if !is_ready(policy) {
		return policy_error_invalid_policy(.Policy_Not_Initialized)
	}
	if path == "" {
		return policy_error_invalid_policy(.Empty_Path)
	}
	// Reject ambiguous/oversized paths before any stat or clone: an interior NUL
	// would be silently truncated by the cstring conversion (sandboxing a path
	// other than the one named), and an over-PATH_MAX path would be rejected by
	// the kernel anyway after a needless large allocation.
	if len(path) >= posix.PATH_MAX || strings.index_byte(path, 0) >= 0 {
		return policy_error_invalid_policy(.Invalid_Path)
	}
	if err := path_access_validate(access); err.kind != .None {
		return err
	}

	omit, validation_err := path_validation_stat(path, kind, options)
	if validation_err.kind != .None {
		return validation_err
	}
	if omit {
		return record_omitted_path(policy, kind, path, access, .Missing)
	}

	no_follow := options.symlink == .Reject
	for &rule in policy.rules_path {
		if rule.kind == kind && rule.path == path {
			rule.access += access
			// Keep the stricter open: reject symlinks if any rule for this path did.
			rule.no_follow = rule.no_follow || no_follow
			policy_note_path_features(policy)
			return policy_error_none()
		}
	}

	cloned_path, alloc_err := strings.clone(path, policy.allocator)
	if alloc_err != nil {
		return policy_error_allocation(alloc_err)
	}

	_, alloc_err = append(
		&policy.rules_path,
		Policy_Path_Rule{kind = kind, access = access, path = cloned_path, no_follow = no_follow},
	)
	if alloc_err != nil {
		delete(cloned_path, policy.allocator)
		return policy_error_allocation(alloc_err)
	}

	policy_note_path_features(policy)
	return policy_error_none()
}

// allow_ro_dirs requests Execute, Read_File, and Read_Dir for existing directories.
allow_ro_dirs :: proc(policy: ^Policy, paths: ..string) -> Policy_Error {
	for path in paths {
		if err := allow_path(policy, .Directory, path, path_access_ro_dir); err.kind != .None {
			return err
		}
	}
	return policy_error_none()
}

// allow_rw_dirs requests read directory rights plus write, create, remove, and Truncate for existing directories.
allow_rw_dirs :: proc(policy: ^Policy, paths: ..string) -> Policy_Error {
	for path in paths {
		if err := allow_path(policy, .Directory, path, path_access_rw_dir); err.kind != .None {
			return err
		}
	}
	return policy_error_none()
}

// allow_ro_files requests Execute and Read_File for existing regular files.
allow_ro_files :: proc(policy: ^Policy, paths: ..string) -> Policy_Error {
	for path in paths {
		if err := allow_path(policy, .File, path, path_access_ro_file); err.kind != .None {
			return err
		}
	}
	return policy_error_none()
}

// allow_rw_files requests Execute, Read_File, Write_File, and Truncate for existing regular files.
allow_rw_files :: proc(policy: ^Policy, paths: ..string) -> Policy_Error {
	for path in paths {
		if err := allow_path(policy, .File, path, path_access_rw_file); err.kind != .None {
			return err
		}
	}
	return policy_error_none()
}

allow_tcp_connect :: proc(policy: ^Policy, port: u16) -> Policy_Error {
	if !is_ready(policy) {
		return policy_error_invalid_policy()
	}
	_, alloc_err := append(
		&policy.rules_network,
		Policy_Net_Rule{access_net = {.Connect_TCP}, port = port},
	)
	if alloc_err != nil {
		return policy_error_allocation(alloc_err)
	}
	policy.features_requested += Feature_Set{.Network}
	return policy_error_none()
}

allow_tcp_bind :: proc(policy: ^Policy, port: u16) -> Policy_Error {
	if !is_ready(policy) {
		return policy_error_invalid_policy()
	}
	_, alloc_err := append(
		&policy.rules_network,
		Policy_Net_Rule{access_net = {.Bind_TCP}, port = port},
	)
	if alloc_err != nil {
		return policy_error_allocation(alloc_err)
	}
	policy.features_requested += Feature_Set{.Network}
	return policy_error_none()
}

scope_signal :: proc(policy: ^Policy) -> Policy_Error {
	if !is_ready(policy) {
		return policy_error_invalid_policy()
	}
	policy.rules_scoped += syscall.Scope_Flags{.Signal}
	policy.features_requested += Feature_Set{.Scope}
	return policy_error_none()
}

scope_abstract_unix_socket :: proc(policy: ^Policy) -> Policy_Error {
	if !is_ready(policy) {
		return policy_error_invalid_policy()
	}
	policy.rules_scoped += syscall.Scope_Flags{.Abstract_Unix_Socket}
	policy.features_requested += Feature_Set{.Scope}
	return policy_error_none()
}

@(private)
is_empty :: proc "contextless" (policy: ^Policy) -> bool {
	return(
		policy.features_requested == {} &&
		len(policy.rules_path) == 0 &&
		len(policy.rules_path_omitted) == 0 &&
		len(policy.rules_network) == 0 &&
		policy.rules_scoped == {} &&
		policy.flags_restricted == {} \
	)
}

@(private)
Apply_Path_Fd :: struct {
	rule_index: int,
	fd:         int,
	access:     syscall.Access_FS_Flags,
}

@(private)
Apply_Ops :: struct {
	probe_abi:      proc() -> (int, i32),
	create_ruleset: proc(attr: ^syscall.Ruleset_Attr) -> (int, i32),
	open_path:      proc(path: string, kind: Path_Kind, no_follow: bool) -> (int, i32),
	add_path_rule:  proc(ruleset_fd: int, path_fd: int, access: syscall.Access_FS_Flags) -> i32,
	add_net_rule:   proc(ruleset_fd: int, access: syscall.Access_Net_Flags, port: u16) -> i32,
	prctl:          proc(option: int, arg2, arg3, arg4, arg5: uintptr) -> i32,
	restrict:       proc(ruleset_fd: int, flags: syscall.Restrict_Self_Flags) -> i32,
	close_fd:       proc(fd: int) -> i32,
}

@(private)
raw_errno_from_os_error :: proc(err: os.Error) -> i32 {
	if err == nil {
		return 0
	}
	if raw, ok := os.is_platform_error(err); ok {
		return raw
	}
	return 0
}

@(private)
apply_probe_abi :: proc() -> (int, i32) {
	abi, err := syscall.get_abi_version()
	return abi, raw_errno_from_os_error(err)
}

@(private)
apply_create_ruleset :: proc(attr: ^syscall.Ruleset_Attr) -> (int, i32) {
	fd, err := syscall.create_ruleset(attr)
	return fd, raw_errno_from_os_error(err)
}

@(private)
apply_open_path :: proc(path: string, kind: Path_Kind, no_follow: bool) -> (int, i32) {
	fd, err := syscall.open_path(path, no_follow)
	return fd, raw_errno_from_os_error(err)
}

@(private)
apply_add_path_rule :: proc(
	ruleset_fd: int,
	path_fd: int,
	access: syscall.Access_FS_Flags,
) -> i32 {
	attr := syscall.path_beneath_attr(access, path_fd)
	return raw_errno_from_os_error(syscall.add_path_beneath_rule(ruleset_fd, &attr, 0))
}

@(private)
apply_add_net_rule :: proc(ruleset_fd: int, access: syscall.Access_Net_Flags, port: u16) -> i32 {
	attr := syscall.net_port_attr(access, port)
	return raw_errno_from_os_error(syscall.add_net_port_rule(ruleset_fd, &attr, 0))
}

@(private)
apply_prctl :: proc(option: int, arg2, arg3, arg4, arg5: uintptr) -> i32 {
	return raw_errno_from_os_error(syscall.prctl(option, arg2, arg3, arg4, arg5))
}

@(private)
apply_restrict :: proc(ruleset_fd: int, flags: syscall.Restrict_Self_Flags) -> i32 {
	return raw_errno_from_os_error(syscall.restrict_self(ruleset_fd, int(transmute(u64)flags)))
}

@(private)
apply_close_fd :: proc(fd: int) -> i32 {
	return raw_errno_from_os_error(syscall.close_fd(fd))
}

@(private, thread_local)
apply_ops: Apply_Ops

@(private)
default_apply_ops :: proc "contextless" () -> Apply_Ops {
	return Apply_Ops {
		probe_abi = apply_probe_abi,
		create_ruleset = apply_create_ruleset,
		open_path = apply_open_path,
		add_path_rule = apply_add_path_rule,
		add_net_rule = apply_add_net_rule,
		prctl = apply_prctl,
		restrict = apply_restrict,
		close_fd = apply_close_fd,
	}
}

@(private)
active_apply_ops :: proc "contextless" () -> Apply_Ops {
	if apply_ops.probe_abi == nil {
		return default_apply_ops()
	}
	return apply_ops
}

@(private)
apply_result_for_errno :: proc "contextless" (
	cause: Policy_Error_Cause,
	raw_errno: i32,
) -> Policy_Result {
	if cause == .ABI_Probe {
		if raw_errno == i32(linux.Errno.ENOSYS) {
			return policy_result_unavailable(raw_errno)
		}
		if raw_errno == i32(linux.Errno.EOPNOTSUPP) {
			return policy_result_disabled(raw_errno)
		}
	}
	if raw_errno == i32(linux.Errno.EPERM) {
		return policy_result_permission_denied_for(cause, raw_errno)
	}
	return policy_result_syscall_failed(cause, raw_errno)
}

@(private)
requested_feature_support :: proc "contextless" (
	policy: ^Policy,
	info: ABI_Version,
) -> (
	applied, omitted: Feature_Set,
) {
	// A dimension can only be applied if it is in the handled set — deny-by-default
	// only covers handled dimensions, so rules for an unhandled dimension are not
	// enforced and are surfaced as omitted. This keeps applied ⊆ features_handled
	// and prevents reporting a dimension as enforced when it is not.
	fs_handled := .Filesystem in policy.features_handled
	net_handled := .Network in policy.features_handled
	scope_handled := .Scope in policy.features_handled

	for _ in policy.rules_path_omitted {
		omitted += Feature_Set{.Filesystem}
	}

	for rule in policy.rules_path {
		if !fs_handled {
			omitted += Feature_Set{.Filesystem}
			continue
		}
		access := path_access_to_syscall(rule.access)
		masked := access & info.supported_access_fs
		if masked != {} {
			applied += Feature_Set{.Filesystem}
		}
		if access != masked {
			omitted += Feature_Set{.Filesystem}
		}
	}

	for rule in policy.rules_network {
		if !net_handled {
			omitted += Feature_Set{.Network}
			continue
		}
		masked := rule.access_net & info.supported_access_net
		if masked != {} {
			applied += Feature_Set{.Network}
		}
		if rule.access_net != masked {
			omitted += Feature_Set{.Network}
		}
	}

	if policy.rules_scoped != {} {
		if !scope_handled {
			omitted += Feature_Set{.Scope}
		} else {
			if policy.rules_scoped & info.supported_scoped != {} {
				applied += Feature_Set{.Scope}
			}
			if policy.rules_scoped != policy.rules_scoped & info.supported_scoped {
				omitted += Feature_Set{.Scope}
			}
		}
	}

	return
}

// handled_features_for_abi reports the access dimensions actually denied by
// default: the policy's chosen handled set intersected with what the running
// ABI supports.
@(private)
handled_features_for_abi :: proc "contextless" (
	info: ABI_Version,
	handled: Feature_Set,
) -> Feature_Set {
	features: Feature_Set
	if .Filesystem in handled && info.supported_access_fs != {} {
		features += Feature_Set{.Filesystem}
	}
	if .Network in handled && info.supported_access_net != {} {
		features += Feature_Set{.Network}
	}
	if .Scope in handled && info.supported_scoped != {} {
		features += Feature_Set{.Scope}
	}
	return features
}

@(private)
policy_result_with_context :: proc "contextless" (
	result: Policy_Result,
	abi_requested: int,
	abi_used: int,
	features_handled: Feature_Set,
	features_requested: Feature_Set,
	features_applied: Feature_Set = {},
	features_omitted: Feature_Set = {},
	flags_requested: syscall.Restrict_Self_Flags = {},
	flags_applied: syscall.Restrict_Self_Flags = {},
	flags_omitted: syscall.Restrict_Self_Flags = {},
) -> Policy_Result {
	updated := result
	updated.abi_requested = abi_requested
	updated.abi_used = abi_used
	updated.features_handled = features_handled
	updated.features_requested = features_requested
	updated.features_applied = features_applied
	updated.features_omitted = features_omitted
	updated.flags_requested = flags_requested
	updated.flags_applied = flags_applied
	updated.flags_omitted = flags_omitted
	return updated
}

@(private)
close_opened_path_fds :: proc(opened: []Apply_Path_Fd) {
	ops := active_apply_ops()
	for item in opened {
		if item.fd >= 0 {
			ops.close_fd(item.fd)
		}
	}
}

@(private)
close_ruleset_fd :: proc(ruleset_fd: int) {
	if ruleset_fd >= 0 {
		ops := active_apply_ops()
		ops.close_fd(ruleset_fd)
	}
}

@(private)
apply_with_mode :: proc(policy: ^Policy, best_effort: bool) -> Policy_Result {
	if !is_ready(policy) || is_empty(policy) {
		return policy_result_invalid_policy(.Empty_Policy)
	}
	// An empty handled set would deny-by-default nothing: the kernel rejects an
	// all-zero ruleset (ENOMSG), so fail early with a clear configuration error
	// rather than an opaque syscall failure.
	if policy.features_handled == {} {
		return policy_result_invalid_policy(.Empty_Handled_Set)
	}
	// A rule targeting an access dimension that handle_features left unhandled is a
	// construction contradiction: the rule can never take effect. Reject it as an
	// Invalid_Policy before any kernel call, naming the offending dimension(s) in
	// features_omitted rather than silently folding them into an ABI-gap omission.
	if unhandled_with_rules :=
		   (policy.features_requested & HANDLED_DEFAULT) - policy.features_handled;
	   unhandled_with_rules != {} {
		return policy_result_error(
			.Not_Enforced,
			policy_error_invalid_policy(.Rule_For_Unhandled_Feature),
			features_requested = policy.features_requested,
			features_omitted = unhandled_with_rules,
		)
	}

	when ODIN_OS != .Linux {
		return policy_result_with_context(
			policy_result_unsupported_platform(),
			0,
			0,
			{},
			policy.features_requested,
			{},
			policy.features_requested,
		)
	}

	ops := active_apply_ops()
	abi, raw_errno := ops.probe_abi()
	if raw_errno != 0 {
		return policy_result_with_context(
			apply_result_for_errno(.ABI_Probe, raw_errno),
			abi,
			0,
			{},
			policy.features_requested,
			{},
			policy.features_requested,
		)
	}

	info, abi_err := abi_info_for_version(abi)
	if abi_err != .None {
		return policy_result_with_context(
			policy_result_disabled(0),
			abi,
			0,
			{},
			policy.features_requested,
			{},
			policy.features_requested,
		)
	}
	features_handled := handled_features_for_abi(info, policy.features_handled)
	features_applied, features_omitted := requested_feature_support(policy, info)
	// Restrict_self flags are best-effort by nature: unsupported bits are masked
	// off (never a syscall failure), so report applied/omitted and, in strict mode,
	// fail when any requested flag is unsupported by the running ABI.
	flags_requested := policy.flags_restricted
	flags_applied := flags_requested & info.supported_restrict
	flags_omitted := flags_requested - info.supported_restrict
	if (features_omitted != {} || flags_omitted != {}) && !best_effort {
		return policy_result_error(
			.Not_Enforced,
			Policy_Error{kind = .Unsupported_Feature, cause = .Unsupported_Feature},
			abi_requested = abi,
			abi_used = info.version,
			features_handled = features_handled,
			features_requested = policy.features_requested,
			features_omitted = features_omitted,
			flags_requested = flags_requested,
			flags_omitted = flags_omitted,
		)
	}
	if features_applied == {} && flags_applied == {} {
		return policy_result_error(
			.Not_Enforced,
			Policy_Error{kind = .Unsupported_Feature, cause = .Unsupported_Feature},
			abi_requested = abi,
			abi_used = info.version,
			features_handled = features_handled,
			features_requested = policy.features_requested,
			features_omitted = policy.features_requested + features_omitted,
			flags_requested = flags_requested,
			flags_omitted = flags_omitted,
		)
	}

	// Deny-by-default: handle every right the kernel's ABI supports for each
	// chosen dimension, then allow per-path/per-port within it (the go-landlock
	// V<n>.BestEffort() posture). Rights in unhandled dimensions stay free.
	ruleset_attr := syscall.Ruleset_Attr{}
	if .Filesystem in policy.features_handled {
		ruleset_attr.Handled_Access_FS = info.supported_access_fs
	}
	if .Network in policy.features_handled {
		ruleset_attr.Handled_Access_Net = info.supported_access_net
	}
	if .Scope in policy.features_handled {
		ruleset_attr.Scoped = info.supported_scoped
	}
	restrict_flags := flags_applied

	ruleset_fd, create_errno := ops.create_ruleset(&ruleset_attr)
	if create_errno != 0 {
		return policy_result_with_context(
			apply_result_for_errno(.Create_Ruleset, create_errno),
			abi,
			info.version,
			features_handled,
			policy.features_requested,
		)
	}

	opened: [dynamic]Apply_Path_Fd
	alloc_err: mem.Allocator_Error
	opened, alloc_err = make([dynamic]Apply_Path_Fd, 0, len(policy.rules_path), context.allocator)
	if alloc_err != nil {
		close_ruleset_fd(ruleset_fd)
		return policy_result_error(
			.Not_Enforced,
			policy_error_allocation(alloc_err),
			abi_requested = abi,
			abi_used = info.version,
			features_handled = features_handled,
			features_requested = policy.features_requested,
		)
	}
	defer delete(opened)

	for rule, index in policy.rules_path {
		access := path_access_to_syscall(rule.access) & ruleset_attr.Handled_Access_FS
		if access == {} {
			continue
		}
		path_fd, open_errno := ops.open_path(rule.path, rule.kind, rule.no_follow)
		if open_errno != 0 {
			close_opened_path_fds(opened[:])
			close_ruleset_fd(ruleset_fd)
			return policy_result_with_context(
				apply_result_for_errno(.Add_Rule, open_errno),
				abi,
				info.version,
				features_handled,
				policy.features_requested,
			)
		}
		_, alloc_err = append(
			&opened,
			Apply_Path_Fd{rule_index = index, fd = path_fd, access = access},
		)
		if alloc_err != nil {
			ops.close_fd(path_fd)
			close_opened_path_fds(opened[:])
			close_ruleset_fd(ruleset_fd)
			return policy_result_error(
				.Not_Enforced,
				policy_error_allocation(alloc_err),
				abi_requested = abi,
				abi_used = info.version,
				features_handled = features_handled,
				features_requested = policy.features_requested,
			)
		}
	}

	for item in opened {
		add_errno := ops.add_path_rule(ruleset_fd, item.fd, item.access)
		if add_errno != 0 {
			close_opened_path_fds(opened[:])
			close_ruleset_fd(ruleset_fd)
			return policy_result_with_context(
				apply_result_for_errno(.Add_Rule, add_errno),
				abi,
				info.version,
				features_handled,
				policy.features_requested,
			)
		}
	}
	close_opened_path_fds(opened[:])
	clear(&opened)

	for rule in policy.rules_network {
		access := rule.access_net & ruleset_attr.Handled_Access_Net
		if access == {} {
			continue
		}
		add_errno := ops.add_net_rule(ruleset_fd, access, rule.port)
		if add_errno != 0 {
			close_ruleset_fd(ruleset_fd)
			return policy_result_with_context(
				apply_result_for_errno(.Add_Rule, add_errno),
				abi,
				info.version,
				features_handled,
				policy.features_requested,
			)
		}
	}

	prctl_errno := ops.prctl(syscall.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)
	if prctl_errno != 0 {
		close_ruleset_fd(ruleset_fd)
		return policy_result_with_context(
			policy_result_no_new_privs_failed(prctl_errno),
			abi,
			info.version,
			features_handled,
			policy.features_requested,
		)
	}

	restrict_errno := ops.restrict(ruleset_fd, restrict_flags)
	if restrict_errno != 0 {
		close_ruleset_fd(ruleset_fd)
		return policy_result_with_context(
			apply_result_for_errno(.Restrict_Self, restrict_errno),
			abi,
			info.version,
			features_handled,
			policy.features_requested,
		)
	}

	close_ruleset_fd(ruleset_fd)
	if features_omitted != {} || flags_omitted != {} {
		return Policy_Result {
			status = .Partially_Enforced,
			abi_requested = abi,
			abi_used = info.version,
			features_handled = features_handled,
			features_requested = policy.features_requested,
			features_applied = features_applied,
			features_omitted = features_omitted,
			flags_requested = flags_requested,
			flags_applied = flags_applied,
			flags_omitted = flags_omitted,
			error = Policy_Error{kind = .Unsupported_Feature, cause = .Unsupported_Feature},
		}
	}
	return Policy_Result {
		status = .Enforced,
		abi_requested = abi,
		abi_used = info.version,
		features_handled = features_handled,
		features_requested = policy.features_requested,
		features_applied = features_applied,
		flags_requested = flags_requested,
		flags_applied = flags_applied,
	}
}

apply_strict :: proc(policy: ^Policy) -> Policy_Result {
	return apply_with_mode(policy, false)
}

apply_best_effort :: proc(policy: ^Policy) -> Policy_Result {
	return apply_with_mode(policy, true)
}

@(private)
abi_info_for_version :: proc "contextless" (version: int) -> (ABI_Version, ABI_Error) {
	if version <= 0 {
		return abi_versions[0], ABI_Error.Not_Supported
	}
	v := version
	if v >= len(abi_versions) {
		v = len(abi_versions) - 1
	}
	return abi_versions[v], ABI_Error.None
}
