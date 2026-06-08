package landlock

import "core:testing"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "syscall"

failing_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		return nil, .Out_Of_Memory
	case .Free:
		return nil, .None
	case .Free_All, .Query_Features, .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, .None
}

failing_allocator :: proc "contextless" () -> mem.Allocator {
	return mem.Allocator{procedure = failing_allocator_proc}
}

@(test)
layout_basics :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(syscall.Ruleset_Attr), 24)
	testing.expect_value(t, size_of(syscall.Net_Port_Attr), 16)
	testing.expect_value(t, size_of(syscall.Path_Beneath_Attr), 12)
}

@(test)
abi_table_has_expected_shape :: proc(t: ^testing.T) {
	testing.expect_value(t, len(abi_versions), 10)
	testing.expect(t, .Refer in abi_versions[2].supported_access_fs, "abi v2 should include Refer")
	testing.expect(t, .Ioctl_Dev in abi_versions[5].supported_access_fs, "abi v5 should include Ioctl_Dev")
	testing.expect(t, .Signal in abi_versions[6].supported_scoped, "abi v6 should include Signal scope")
	testing.expect(t, .Log_New_Exec_On in abi_versions[7].supported_restrict, "abi v7 should include logging restrict flags")
	testing.expect(t, .Tsync in abi_versions[8].supported_restrict, "abi v8 should include TSYNC")
	testing.expect(t, .Resolve_Unix in abi_versions[9].supported_access_fs, "abi v9 should include Resolve_Unix")
}

@(test)
abi_status_values :: proc(t: ^testing.T) {
	testing.expect_value(t, int(ABI_Error.None), 0)
	testing.expect_value(t, int(ABI_Error.Not_Supported), -1)
}

@(test)
abi_matrix_clamps_future_to_known_v9 :: proc(t: ^testing.T) {
	for version in 1..=9 {
		info, err := abi_info_for_version(version)
		testing.expect_value(t, err, ABI_Error.None)
		testing.expect_value(t, info.version, version)
	}

	info, err := abi_info_for_version(999)
	testing.expect_value(t, err, ABI_Error.None)
	testing.expect_value(t, info.version, 9)
	testing.expect_value(t, info.supported_access_fs, abi_versions[9].supported_access_fs)
	testing.expect_value(t, info.supported_access_net, abi_versions[9].supported_access_net)
	testing.expect_value(t, info.supported_scoped, abi_versions[9].supported_scoped)
	testing.expect_value(t, info.supported_restrict, abi_versions[9].supported_restrict)
}

@(test)
abi_feature_boundaries :: proc(t: ^testing.T) {
	testing.expect(t, !(.Ioctl_Dev in abi_versions[4].supported_access_fs), "abi v4 should omit Ioctl_Dev")
	testing.expect(t, .Ioctl_Dev in abi_versions[5].supported_access_fs, "abi v5 should include Ioctl_Dev")
	testing.expect(t, .Log_Same_Exec_Off in abi_versions[7].supported_restrict, "abi v7 should include logging flags")
	testing.expect(t, !(.Tsync in abi_versions[7].supported_restrict), "abi v7 should omit TSYNC")
	testing.expect(t, .Tsync in abi_versions[8].supported_restrict, "abi v8 should include TSYNC")
	testing.expect(t, !(.Resolve_Unix in abi_versions[8].supported_access_fs), "abi v8 should omit Resolve_Unix")
	testing.expect(t, .Resolve_Unix in abi_versions[9].supported_access_fs, "abi v9 should include Resolve_Unix")
}

@(test)
test_abi1_omits_v8_v9_features :: proc(t: ^testing.T) {
	abi := abi_versions[1]
	testing.expect(t, !(.Tsync in abi.supported_restrict), "abi v1 should omit TSYNC")
	testing.expect(t, !(.Resolve_Unix in abi.supported_access_fs), "abi v1 should omit Resolve_Unix")
	testing.expect(t, !(.Ioctl_Dev in abi.supported_access_fs), "abi v1 should omit Ioctl_Dev")
	testing.expect(t, abi.supported_access_net == {}, "abi v1 should omit network access")
	testing.expect(t, abi.supported_scoped == {}, "abi v1 should omit scope flags")
}

@(test)
test_unavailable_syscall_preserves_errno :: proc(t: ^testing.T) {
	result := policy_result_unavailable(38)
	testing.expect_value(t, result.status, Policy_Status.Unavailable)
	testing.expect_value(t, result.error.kind, Policy_Error_Kind.Unavailable)
	testing.expect_value(t, result.error.cause, Policy_Error_Cause.ABI_Probe)
	testing.expect_value(t, result.error.raw_errno, i32(38))
}

@(test)
test_disabled_kernel_preserves_errno :: proc(t: ^testing.T) {
	result := policy_result_disabled(95)
	testing.expect_value(t, result.status, Policy_Status.Disabled)
	testing.expect_value(t, result.error.kind, Policy_Error_Kind.Disabled)
	testing.expect_value(t, result.error.raw_errno, i32(95))
}

@(test)
test_unsupported_platform_is_typed :: proc(t: ^testing.T) {
	result := policy_result_unsupported_platform()
	testing.expect_value(t, result.status, Policy_Status.Unsupported_Platform)
	testing.expect_value(t, result.error.kind, Policy_Error_Kind.Unsupported_Platform)
	testing.expect_value(t, result.error.cause, Policy_Error_Cause.Unsupported_Platform)
}

@(test)
test_unsupported_feature_is_omitted :: proc(t: ^testing.T) {
	result := policy_result_unsupported_feature(.Network)
	testing.expect_value(t, result.status, Policy_Status.Partially_Enforced)
	testing.expect_value(t, result.error.kind, Policy_Error_Kind.Unsupported_Feature)
	testing.expect(t, .Network in result.features_omitted, "unsupported feature should be recorded")
}

@(test)
test_invalid_policy_reports_structured_error :: proc(t: ^testing.T) {
	result := policy_result_invalid_policy()
	testing.expect_value(t, result.status, Policy_Status.Invalid_Policy)
	testing.expect(t, result.status != .Skipped_For_Test, "invalid policy must not be reported as a test skip")
	testing.expect_value(t, result.error.kind, Policy_Error_Kind.Invalid_Policy)
	testing.expect_value(t, result.error.cause, Policy_Error_Cause.Validation)
}

@(test)
test_permission_denied_preserves_errno :: proc(t: ^testing.T) {
	result := policy_result_permission_denied_for(.Restrict_Self, 1)
	testing.expect_value(t, result.error.kind, Policy_Error_Kind.Permission_Denied)
	testing.expect_value(t, result.error.cause, Policy_Error_Cause.Restrict_Self)
	testing.expect_value(t, result.error.raw_errno, i32(1))
}

@(test)
test_permission_denied_for_preserves_cause :: proc(t: ^testing.T) {
	result := policy_result_permission_denied_for(.Add_Rule, 1)
	testing.expect_value(t, result.error.kind, Policy_Error_Kind.Permission_Denied)
	testing.expect_value(t, result.error.cause, Policy_Error_Cause.Add_Rule)
	testing.expect_value(t, result.error.raw_errno, i32(1))
}

@(test)
test_no_new_privs_failure_preserves_errno :: proc(t: ^testing.T) {
	result := policy_result_no_new_privs_failed(1)
	testing.expect_value(t, result.error.kind, Policy_Error_Kind.No_New_Privs_Failed)
	testing.expect_value(t, result.error.cause, Policy_Error_Cause.Set_No_New_Privs)
	testing.expect_value(t, result.error.raw_errno, i32(1))
}

@(test)
test_generic_syscall_failure_preserves_errno :: proc(t: ^testing.T) {
	result := policy_result_syscall_failed(.Create_Ruleset, 7)
	testing.expect_value(t, result.error.kind, Policy_Error_Kind.Syscall_Failed)
	testing.expect_value(t, result.error.cause, Policy_Error_Cause.Create_Ruleset)
	testing.expect_value(t, result.error.raw_errno, i32(7))
}

@(test)
test_skipped_for_test_is_typed :: proc(t: ^testing.T) {
	result := policy_result_skipped_for_test()
	testing.expect_value(t, result.status, Policy_Status.Skipped_For_Test)
	testing.expect_value(t, result.error.kind, Policy_Error_Kind.Skipped_For_Test)
	testing.expect(t, result.error.kind != .Invalid_Policy, "test skip must remain distinct from invalid policy")
}

@(test)
test_policy_summary_allocation_failure :: proc(t: ^testing.T) {
	_, err := summary(enforced_result(9, {.Filesystem}), failing_allocator())
	testing.expect_value(t, err.kind, Policy_Error_Kind.Allocation_Failed)
	testing.expect_value(t, err.allocator_error, mem.Allocator_Error.Out_Of_Memory)
}

@(test)
test_policy_summary_allocates_and_caller_frees :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	allocator := mem.tracking_allocator(&track)
	summary, err := summary(enforced_result(9, {.Filesystem}), allocator)
	testing.expect_value(t, err.kind, Policy_Error_Kind.None)
	testing.expect(t, len(summary) > 0, "summary should be allocated")

	delete(summary, allocator)
	testing.expect_value(t, len(track.allocation_map), 0)
}

expect_debug_contains :: proc(t: ^testing.T, summary, needle: string) {
	testing.expectf(t, strings.contains(summary, needle), "debug summary missing %s in %s", needle, summary)
}

enforced_result :: proc(abi_used: int, applied: Feature_Set) -> Policy_Result {
	return Policy_Result {
		status = .Enforced,
		abi_requested = abi_used,
		abi_used = abi_used,
		features_handled = applied,
		features_requested = applied,
		features_applied = applied,
	}
}

@(test)
test_policy_debug_summary_allocates_and_caller_frees :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	allocator := mem.tracking_allocator(&track)
	result := Policy_Result {
		status = .Partially_Enforced,
		abi_requested = 999,
		abi_used = 9,
		features_handled = {.Filesystem, .Network, .Scope, .Logging, .Thread_Sync},
		features_requested = {.Filesystem, .Network},
		features_applied = {.Filesystem},
		features_omitted = {.Network},
		error = Policy_Error{kind = .Unsupported_Feature, cause = .Unsupported_Feature},
	}
	summary, err := debug_summary(result, allocator)
	testing.expect_value(t, err.kind, Policy_Error_Kind.None)
	expect_debug_contains(t, summary, "status=Partially_Enforced")
	expect_debug_contains(t, summary, "abi_requested=999")
	expect_debug_contains(t, summary, "abi_used=9")
	expect_debug_contains(t, summary, "handled=[Filesystem,Network,Scope,Logging,Thread_Sync]")
	expect_debug_contains(t, summary, "requested=[Filesystem,Network]")
	expect_debug_contains(t, summary, "applied=[Filesystem]")
	expect_debug_contains(t, summary, "omitted=[Network]")
	expect_debug_contains(t, summary, "error_kind=Unsupported_Feature")
	expect_debug_contains(t, summary, "error_cause=Unsupported_Feature")
	expect_debug_contains(t, summary, "raw_errno=0")
	expect_debug_contains(t, summary, "validation=None")

	delete(summary, allocator)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_policy_debug_summary_allocation_failure :: proc(t: ^testing.T) {
	_, err := debug_summary(enforced_result(9, {.Filesystem}), failing_allocator())
	testing.expect_value(t, err.kind, Policy_Error_Kind.Allocation_Failed)
	testing.expect_value(t, err.allocator_error, mem.Allocator_Error.Out_Of_Memory)
}


expect_policy_ok :: proc(t: ^testing.T, err: Policy_Error, msg: string) {
	testing.expectf(t, err.kind == .None, "%s: got %v", msg, err.kind)
}

make_test_temp_dir :: proc(t: ^testing.T) -> string {
	dir, err := os.make_directory_temp("", "odin-landlock-test-*", context.allocator)
	testing.expectf(t, err == nil, "make temp dir: %s", os.error_string(err))
	return dir
}

join_test_path :: proc(t: ^testing.T, dir, name: string) -> string {
	path, alloc_err := os.join_path({dir, name}, context.allocator)
	testing.expectf(t, alloc_err == nil, "join path: %v", alloc_err)
	return path
}

write_test_file :: proc(t: ^testing.T, path: string) {
	err := os.write_entire_file(path, "fixture")
	testing.expectf(t, err == nil, "write fixture file: %s", os.error_string(err))
}

@(test)
test_policy_builds_filesystem_helpers :: proc(t: ^testing.T) {
	temp_dir := make_test_temp_dir(t)
	defer delete(temp_dir)
	defer os.remove_all(temp_dir)
	file_path := join_test_path(t, temp_dir, "out.txt")
	defer delete(file_path)
	write_test_file(t, file_path)

	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)

	expect_policy_ok(t, allow_ro_dirs(&policy, "/usr", "/bin"), "allow_ro_dirs")
	expect_policy_ok(t, allow_rw_dirs(&policy, temp_dir), "allow_rw_dirs")
	expect_policy_ok(t, allow_ro_files(&policy, "/etc/passwd"), "allow_ro_files")
	expect_policy_ok(t, allow_rw_files(&policy, file_path), "allow_rw_files")

	testing.expect_value(t, len(policy.rules_path), 5)
	testing.expect_value(t, policy.rules_path[0].kind, Path_Kind.Directory)
	testing.expect_value(t, policy.rules_path[0].access, path_access_ro_dir)
	testing.expect_value(t, policy.rules_path[2].access, path_access_rw_dir)
	testing.expect_value(t, policy.rules_path[3].kind, Path_Kind.File)
	testing.expect_value(t, policy.rules_path[3].access, path_access_ro_file)
	testing.expect_value(t, policy.rules_path[4].access, path_access_rw_file)
	testing.expect(t, .Filesystem in policy.features_requested, "filesystem feature should be requested")
}

@(test)
test_policy_builds_custom_path_with_resolve_unix :: proc(t: ^testing.T) {
	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)

	access := Path_Access{.Read_Dir, .Resolve_Unix}
	expect_policy_ok(t, allow_path(&policy, .Directory, "/run", access), "allow_path")

	testing.expect_value(t, len(policy.rules_path), 1)
	testing.expect_value(t, policy.rules_path[0].access, access)
	testing.expect(t, .Resolve_Unix in policy.rules_path[0].access, "Resolve_Unix should be per-path access")
	testing.expect(t, .Filesystem in policy.features_requested, "filesystem feature should be recorded for the path rule")
}

@(test)
test_policy_builds_network_scope_logging_and_tsync :: proc(t: ^testing.T) {
	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)

	expect_policy_ok(t, allow_tcp_connect(&policy, 53), "allow_tcp_connect")
	expect_policy_ok(t, allow_tcp_bind(&policy, 0), "allow_tcp_bind")
	expect_policy_ok(t, scope_signal(&policy), "scope_signal")
	expect_policy_ok(t, scope_abstract_unix(&policy), "scope_abstract_unix")
	expect_policy_ok(t, enable_log_new_exec(&policy), "enable_log_new_exec")
	expect_policy_ok(t, disable_log_same_exec(&policy), "disable_log_same_exec")
	expect_policy_ok(t, disable_log_subdomains(&policy), "disable_log_subdomains")
	expect_policy_ok(t, enable_thread_sync(&policy), "enable_thread_sync")

	testing.expect_value(t, len(policy.rules_network), 2)
	testing.expect_value(t, policy.rules_network[0].access_net, syscall.Access_Net_Flags{.Connect_TCP})
	testing.expect_value(t, policy.rules_network[0].port, u16(53))
	testing.expect_value(t, policy.rules_network[1].access_net, syscall.Access_Net_Flags{.Bind_TCP})
	testing.expect_value(t, policy.rules_network[1].port, u16(0))
	testing.expect(t, .Signal in policy.rules_scoped, "signal scope should be set")
	testing.expect(t, .Abstract_Unix_Socket in policy.rules_scoped, "abstract unix scope should be set")
	testing.expect(t, .Log_New_Exec_On in policy.flags_restricted, "log new exec flag should be set")
	testing.expect(t, .Log_Same_Exec_Off in policy.flags_restricted, "same exec logging disable flag should be set")
	testing.expect(t, .Log_Subdomains_Off in policy.flags_restricted, "subdomain logging disable flag should be set")
	testing.expect(t, .Tsync in policy.flags_restricted, "TSYNC flag should be set")
	testing.expect(t, .Network in policy.features_requested, "network feature should be requested")
	testing.expect(t, .Scope in policy.features_requested, "scope feature should be requested")
	testing.expect(t, .Logging in policy.features_requested, "logging feature should be requested")
	testing.expect(t, .Thread_Sync in policy.features_requested, "thread sync feature should be requested")
}

@(test)
test_policy_builder_validation_errors_are_typed :: proc(t: ^testing.T) {
	policy: Policy
	err := allow_ro_dirs(&policy, "/tmp")
	testing.expect_value(t, err.kind, Policy_Error_Kind.Invalid_Policy)
	testing.expect_value(t, err.cause, Policy_Error_Cause.Validation)
	testing.expect_value(t, err.validation, Policy_Validation_Failure.Policy_Not_Initialized)

	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)

	err = allow_path(&policy, .Directory, "", Path_Access{.Read_Dir})
	testing.expect_value(t, err.kind, Policy_Error_Kind.Invalid_Policy)
	testing.expect_value(t, err.validation, Policy_Validation_Failure.Empty_Path)

	err = allow_path(&policy, .Directory, "/tmp", {})
	testing.expect_value(t, err.kind, Policy_Error_Kind.Invalid_Policy)
	testing.expect_value(t, err.validation, Policy_Validation_Failure.Empty_Access)

	err = allow_path(&policy, .Directory, "/tmp", Path_Access{.Write_File})
	testing.expect_value(t, err.kind, Policy_Error_Kind.Invalid_Policy)
	testing.expect_value(t, err.validation, Policy_Validation_Failure.Write_File_Without_Truncate)

	unsupported_access := transmute(Path_Access)(u64(1) << 63)
	err = allow_path(&policy, .Directory, "/tmp", unsupported_access)
	testing.expect_value(t, err.kind, Policy_Error_Kind.Unsupported_Feature)
	testing.expect_value(t, err.cause, Policy_Error_Cause.Unsupported_Feature)
	testing.expect_value(t, err.validation, Policy_Validation_Failure.Unsupported_Access_Mask)
}

access_excludes_write_like_rights :: proc "contextless" (access: Path_Access) -> bool {
	return !(.Write_File in access) && !(.Truncate in access) && !(.Remove_Dir in access) &&
	       !(.Remove_File in access) && !(.Make_Char in access) && !(.Make_Dir in access) &&
	       !(.Make_Reg in access) && !(.Make_Sock in access) && !(.Make_Fifo in access) &&
	       !(.Make_Block in access) && !(.Make_Sym in access) && !(.Refer in access) &&
	       !(.Ioctl_Dev in access)
}

@(test)
test_ro_helpers_exclude_write_like_rights :: proc(t: ^testing.T) {
	testing.expect(t, access_excludes_write_like_rights(path_access_ro_dir), "read-only dir helper must exclude write-like rights")
	testing.expect(t, access_excludes_write_like_rights(path_access_ro_file), "read-only file helper must exclude write-like rights")
	testing.expect(t, .Execute in path_access_ro_dir, "read-only dir helper should include execute")
	testing.expect(t, .Read_File in path_access_ro_dir, "read-only dir helper should include read file")
	testing.expect(t, .Read_Dir in path_access_ro_dir, "read-only dir helper should include read dir")
	testing.expect(t, .Execute in path_access_ro_file, "read-only file helper should include execute")
	testing.expect(t, .Read_File in path_access_ro_file, "read-only file helper should include read file")
}

@(test)
test_missing_path_default_and_ignore_option :: proc(t: ^testing.T) {
	temp_dir := make_test_temp_dir(t)
	defer delete(temp_dir)
	defer os.remove_all(temp_dir)
	missing_path := join_test_path(t, temp_dir, "missing.txt")
	defer delete(missing_path)

	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)

	err := allow_ro_files(&policy, missing_path)
	testing.expect_value(t, err.kind, Policy_Error_Kind.Invalid_Policy)
	testing.expect_value(t, err.validation, Policy_Validation_Failure.Missing_Path)
	testing.expect_value(t, len(policy.rules_path), 0)

	err = allow_path(
		&policy,
		.File,
		missing_path,
		path_access_ro_file,
		Path_Options{missing = .Ignore},
	)
	expect_policy_ok(t, err, "allow_path missing ignore")
	testing.expect_value(t, len(policy.rules_path), 0)
	testing.expect_value(t, len(policy.rules_path_omitted), 1)
	testing.expect_value(t, policy.rules_path_omitted[0].reason, Path_Omission_Reason.Missing)
	testing.expect(t, .Filesystem in policy.features_requested, "missing ignored path should still record filesystem intent")

	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	result := apply_best_effort(&policy)
	testing.expect_value(t, result.status, Policy_Status.Unsupported_Feature)
	testing.expect(t, .Filesystem in result.features_omitted, "missing ignored path should be reported as omitted")
	testing.expect_value(t, count_fake_calls(.Create), 0)
}

@(test)
test_path_type_validation_and_symlink_policy :: proc(t: ^testing.T) {
	temp_dir := make_test_temp_dir(t)
	defer delete(temp_dir)
	defer os.remove_all(temp_dir)
	file_path := join_test_path(t, temp_dir, "file.txt")
	defer delete(file_path)
	link_path := join_test_path(t, temp_dir, "link.txt")
	defer delete(link_path)
	write_test_file(t, file_path)

	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)

	err := allow_path(&policy, .Directory, file_path, path_access_ro_dir)
	testing.expect_value(t, err.kind, Policy_Error_Kind.Invalid_Policy)
	testing.expect_value(t, err.validation, Policy_Validation_Failure.Wrong_Path_Type)

	err = allow_path(&policy, .File, temp_dir, path_access_ro_file)
	testing.expect_value(t, err.kind, Policy_Error_Kind.Invalid_Policy)
	testing.expect_value(t, err.validation, Policy_Validation_Failure.Wrong_Path_Type)

	symlink_err := os.symlink(file_path, link_path)
	testing.expectf(t, symlink_err == nil, "create symlink: %s", os.error_string(symlink_err))

	err = allow_path(&policy, .File, link_path, path_access_ro_file)
	expect_policy_ok(t, err, "allow symlink with default follow policy")

	err = allow_path(
		&policy,
		.File,
		link_path,
		path_access_ro_file,
		Path_Options{symlink = .Reject},
	)
	testing.expect_value(t, err.kind, Policy_Error_Kind.Invalid_Policy)
	testing.expect_value(t, err.validation, Policy_Validation_Failure.Symlink_Rejected)
}

@(test)
test_duplicate_and_overlapping_path_rules_are_deterministic :: proc(t: ^testing.T) {
	temp_dir := make_test_temp_dir(t)
	defer delete(temp_dir)
	defer os.remove_all(temp_dir)
	child_dir := join_test_path(t, temp_dir, "child")
	defer delete(child_dir)
	testing.expect(t, os.make_directory(child_dir) == nil, "create child dir")

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	policy: Policy
	expect_policy_ok(t, init(&policy, mem.tracking_allocator(&track)), "policy_init")
	expect_policy_ok(t, allow_ro_dirs(&policy, temp_dir), "allow_ro_dirs")
	expect_policy_ok(t, allow_ro_dirs(&policy, temp_dir), "duplicate allow_ro_dirs")
	testing.expect_value(t, len(policy.rules_path), 1)
	testing.expect_value(t, policy.rules_path[0].access, path_access_ro_dir)

	expect_policy_ok(t, allow_rw_dirs(&policy, temp_dir), "overlapping allow_rw_dirs")
	testing.expect_value(t, len(policy.rules_path), 1)
	testing.expect_value(t, policy.rules_path[0].access, path_access_rw_dir)

	expect_policy_ok(t, allow_ro_dirs(&policy, child_dir), "overlapping child allow_ro_dirs")
	testing.expect_value(t, len(policy.rules_path), 2)
	testing.expect_value(t, policy.rules_path[0].path, temp_dir)
	testing.expect_value(t, policy.rules_path[1].path, child_dir)

	cleanup(&policy)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_refer_unsupported_abi_is_omitted :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.abi = 1

	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)
	expect_policy_ok(t, allow_path(&policy, .Directory, "/tmp", Path_Access{.Read_Dir, .Refer}), "allow_path refer")

	result := apply_best_effort(&policy)
	testing.expect_value(t, result.status, Policy_Status.Partially_Enforced)
	testing.expect(t, .Filesystem in result.features_applied, "read dir part should still apply")
	testing.expect(t, .Filesystem in result.features_omitted, "unsupported refer part should be omitted")
	testing.expect_value(t, count_fake_calls(.Add_Path), 1)
	testing.expect(t, .Read_Dir in fake_state.calls[3].fs_access, "read dir should be passed to fake add path")
	testing.expect(t, !(.Refer in fake_state.calls[3].fs_access), "refer must not be passed on abi v1")
}

@(test)
test_policy_builder_allocation_failure_is_typed :: proc(t: ^testing.T) {
	policy: Policy
	expect_policy_ok(t, init(&policy, failing_allocator()), "policy_init")
	defer cleanup(&policy)

	err := allow_path(&policy, .Directory, "/tmp", Path_Access{.Read_Dir})
	testing.expect_value(t, err.kind, Policy_Error_Kind.Allocation_Failed)
	testing.expect_value(t, err.cause, Policy_Error_Cause.Allocation)
	testing.expect_value(t, err.allocator_error, mem.Allocator_Error.Out_Of_Memory)
}

@(test)
test_policy_allocator_copies_and_frees_paths :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	allocator := mem.tracking_allocator(&track)
	policy: Policy
	expect_policy_ok(t, init(&policy, allocator), "policy_init")

	caller_path := "/tmp"
	expect_policy_ok(t, allow_ro_dirs(&policy, caller_path), "allow_ro_dirs")
	testing.expect_value(t, policy.rules_path[0].path, caller_path)
	testing.expect(t, raw_data(policy.rules_path[0].path) != raw_data(caller_path), "policy should clone caller path storage")
	testing.expect(t, len(track.allocation_map) > 0, "tracking allocator should see owned policy storage")

	cleanup(&policy)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_policy_cleanup_reset_safe_and_double_cleanup_harmless :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	track.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	policy: Policy
	expect_policy_ok(t, init(&policy, mem.tracking_allocator(&track)), "policy_init")
	expect_policy_ok(t, allow_ro_dirs(&policy, "/tmp"), "allow_ro_dirs")
	cleanup(&policy)

	testing.expect(t, !policy.initialized, "policy should be reset after cleanup")
	testing.expect_value(t, len(policy.rules_path), 0)
	testing.expect_value(t, len(policy.rules_network), 0)
	testing.expect_value(t, len(track.allocation_map), 0)

	cleanup(&policy)
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}


Fake_Call_Kind :: enum {
	Probe,
	Create,
	Open_Path,
	Add_Path,
	Add_Net,
	Prctl,
	Restrict,
	Close,
}

Fake_Call :: struct {
	kind:       Fake_Call_Kind,
	fd:         int,
	arg2:       int,
	arg3:       int,
	arg4:       int,
	arg5:       int,
	path_kind:  Path_Kind,
	no_follow:  bool,
	fs_access:  syscall.Access_FS_Flags,
	net_access: syscall.Access_Net_Flags,
	scoped:     syscall.Scope_Flags,
	flags:      syscall.Restrict_Self_Flags,
}

Fake_Apply_State :: struct {
	calls:                  [128]Fake_Call,
	call_count:             int,
	abi:                    int,
	ruleset_fd:             int,
	next_path_fd:           int,
	probe_errno:            i32,
	create_errno:           i32,
	open_errno:             i32,
	add_path_errno:         i32,
	add_path_fail_on_call:  int,
	add_net_errno:          i32,
	prctl_errno:            i32,
	apply_errno:            i32,
	open_calls:             int,
	add_path_calls:         int,
}

@(thread_local)
fake_state: Fake_Apply_State

fake_record :: proc(call: Fake_Call) {
	if fake_state.call_count >= len(fake_state.calls) {
		return // guard the fixed-size buffer; a test exceeding it is a test bug
	}
	fake_state.calls[fake_state.call_count] = call
	fake_state.call_count += 1
}

fake_reset :: proc() {
	fake_state = Fake_Apply_State{abi = 9, ruleset_fd = 3, next_path_fd = 20, add_path_fail_on_call = 1}
}

fake_probe_abi :: proc() -> (int, i32) {
	fake_record(Fake_Call{kind = .Probe})
	return fake_state.abi, fake_state.probe_errno
}

fake_create_ruleset :: proc(attr: ^syscall.Ruleset_Attr) -> (int, i32) {
	fake_record(Fake_Call {
		kind = .Create,
		fs_access = attr.Handled_Access_FS,
		net_access = attr.Handled_Access_Net,
		scoped = attr.Scoped,
	})
	if fake_state.create_errno != 0 {
		return -1, fake_state.create_errno
	}
	return fake_state.ruleset_fd, 0
}

fake_open_path :: proc(path: string, kind: Path_Kind, no_follow: bool) -> (int, i32) {
	fake_state.open_calls += 1
	fd := fake_state.next_path_fd + fake_state.open_calls - 1
	fake_record(Fake_Call{kind = .Open_Path, fd = fd, path_kind = kind, no_follow = no_follow})
	if fake_state.open_errno != 0 {
		return -1, fake_state.open_errno
	}
	return fd, 0
}

fake_add_path_rule :: proc(ruleset_fd: int, path_fd: int, access: syscall.Access_FS_Flags) -> i32 {
	fake_state.add_path_calls += 1
	fake_record(Fake_Call{kind = .Add_Path, fd = path_fd, arg2 = ruleset_fd, fs_access = access})
	if fake_state.add_path_errno != 0 && fake_state.add_path_calls == fake_state.add_path_fail_on_call {
		return fake_state.add_path_errno
	}
	return 0
}

fake_add_net_rule :: proc(ruleset_fd: int, access: syscall.Access_Net_Flags, port: u16) -> i32 {
	fake_record(Fake_Call{kind = .Add_Net, fd = ruleset_fd, arg2 = int(port), net_access = access})
	return fake_state.add_net_errno
}

fake_prctl :: proc(option: int, arg2, arg3, arg4, arg5: uintptr) -> i32 {
	fake_record(Fake_Call {
		kind = .Prctl,
		fd = option,
		arg2 = int(arg2),
		arg3 = int(arg3),
		arg4 = int(arg4),
		arg5 = int(arg5),
	})
	return fake_state.prctl_errno
}

fake_apply_rule_set :: proc(ruleset_fd: int, flags: syscall.Restrict_Self_Flags) -> i32 {
	fake_record(Fake_Call{kind = .Restrict, fd = ruleset_fd, flags = flags})
	return fake_state.apply_errno
}

fake_close_fd :: proc(fd: int) -> i32 {
	fake_record(Fake_Call{kind = .Close, fd = fd})
	return 0
}

fake_apply_ops :: proc() -> Apply_Ops {
	return Apply_Ops {
		probe_abi = fake_probe_abi,
		create_ruleset = fake_create_ruleset,
		open_path = fake_open_path,
		add_path_rule = fake_add_path_rule,
		add_net_rule = fake_add_net_rule,
		prctl = fake_prctl,
		restrict = fake_apply_rule_set,
		close_fd = fake_close_fd,
	}
}

use_fake_apply_ops :: proc() -> Apply_Ops {
	saved := apply_ops
	fake_reset()
	apply_ops = fake_apply_ops()
	return saved
}

count_fake_calls :: proc(kind: Fake_Call_Kind, fd: int = -1) -> int {
	count := 0
	for call in fake_state.calls[:fake_state.call_count] {
		if call.kind == kind && (fd < 0 || call.fd == fd) {
			count += 1
		}
	}
	return count
}

expect_fake_order :: proc(t: ^testing.T, expected: []Fake_Call_Kind) {
	testing.expect_value(t, fake_state.call_count, len(expected))
	for kind, index in expected {
		if index < fake_state.call_count {
			testing.expect_value(t, fake_state.calls[index].kind, kind)
		}
	}
}

@(test)
test_apply_validate_invalid_policies :: proc(t: ^testing.T) {
	result := apply_strict(nil)
	testing.expect_value(t, result.status, Policy_Status.Invalid_Policy)
	testing.expect_value(t, result.error.kind, Policy_Error_Kind.Invalid_Policy)
	testing.expect_value(t, result.error.validation, Policy_Validation_Failure.Empty_Policy)

	policy: Policy
	result = apply_strict(&policy)
	testing.expect_value(t, result.status, Policy_Status.Invalid_Policy)
	testing.expect_value(t, result.error.kind, Policy_Error_Kind.Invalid_Policy)
	testing.expect_value(t, result.error.validation, Policy_Validation_Failure.Empty_Policy)

	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)

	result = apply_best_effort(&policy)
	testing.expect_value(t, result.status, Policy_Status.Invalid_Policy)
	testing.expect_value(t, result.error.kind, Policy_Error_Kind.Invalid_Policy)
	testing.expect_value(t, result.error.validation, Policy_Validation_Failure.Empty_Policy)
}

@(test)
test_apply_success_uses_fake_flow_and_closes_fds :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops

	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)

	expect_policy_ok(t, allow_ro_dirs(&policy, "/tmp"), "allow_ro_dirs")

	result := apply_strict(&policy)
	testing.expect_value(t, result.status, Policy_Status.Enforced)
	testing.expect_value(t, result.error.kind, Policy_Error_Kind.None)
	testing.expect(t, .Filesystem in result.features_applied, "filesystem feature should be applied")
	testing.expect_value(t, count_fake_calls(.Close, 20), 1)
	testing.expect_value(t, count_fake_calls(.Close, 3), 1)

	expected := [?]Fake_Call_Kind{.Probe, .Create, .Open_Path, .Add_Path, .Close, .Prctl, .Restrict, .Close}
	expect_fake_order(t, expected[:])
	testing.expect_value(t, fake_state.calls[5].fd, syscall.PR_SET_NO_NEW_PRIVS)
	testing.expect_value(t, fake_state.calls[5].arg2, 1)
	testing.expect_value(t, fake_state.calls[5].arg3, 0)
	testing.expect_value(t, fake_state.calls[5].arg4, 0)
	testing.expect_value(t, fake_state.calls[5].arg5, 0)
}

@(test)
test_apply_positive_ruleset_fd_is_not_error :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.ruleset_fd = 7

	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)
	expect_policy_ok(t, allow_ro_dirs(&policy, "/tmp"), "allow_ro_dirs")

	result := apply_strict(&policy)
	testing.expect_value(t, result.status, Policy_Status.Enforced)
	testing.expect_value(t, count_fake_calls(.Close, 7), 1)
}

@(test)
test_apply_probe_enosys_is_unavailable :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.probe_errno = 38

	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)
	expect_policy_ok(t, allow_ro_dirs(&policy, "/tmp"), "allow_ro_dirs")

	result := apply_strict(&policy)
	testing.expect_value(t, result.status, Policy_Status.Unavailable)
	testing.expect_value(t, result.error.kind, Policy_Error_Kind.Unavailable)
	testing.expect_value(t, result.error.raw_errno, i32(38))
	testing.expect_value(t, fake_state.call_count, 1)
}

@(test)
test_apply_probe_eopnotsupp_is_disabled :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.probe_errno = 95

	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)
	expect_policy_ok(t, allow_ro_dirs(&policy, "/tmp"), "allow_ro_dirs")

	result := apply_strict(&policy)
	testing.expect_value(t, result.status, Policy_Status.Disabled)
	testing.expect_value(t, result.error.kind, Policy_Error_Kind.Disabled)
	testing.expect_value(t, result.error.raw_errno, i32(95))
}

@(test)
test_non_linux_apply_reports_unsupported_platform :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux {
		policy: Policy
		expect_policy_ok(t, init(&policy), "policy_init")
		defer cleanup(&policy)
		expect_policy_ok(t, allow_ro_dirs(&policy, "/tmp"), "allow_ro_dirs")

		result := apply_best_effort(&policy)
		testing.expect_value(t, result.status, Policy_Status.Unsupported_Platform)
		testing.expect_value(t, result.error.kind, Policy_Error_Kind.Unsupported_Platform)
		testing.expect_value(t, result.abi_requested, 0)
		testing.expect_value(t, result.abi_used, 0)
		testing.expect_value(t, result.features_applied, Feature_Set{})
		testing.expect_value(t, result.features_requested, policy.features_requested)
		testing.expect_value(t, result.features_omitted, policy.features_requested)
	} else {
		testing.expect(t, true, "non-Linux unsupported-platform check is target-gated")
	}
}

@(test)
test_best_effort_enosys_reports_unavailable :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.probe_errno = 38

	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)
	expect_policy_ok(t, allow_ro_dirs(&policy, "/tmp"), "allow_ro_dirs")
	expect_policy_ok(t, allow_tcp_connect(&policy, 443), "allow_tcp_connect")

	result := apply_best_effort(&policy)
	testing.expect_value(t, result.status, Policy_Status.Unavailable)
	testing.expect(t, result.status != .Enforced, "no Landlock syscall must not be reported as enforced")
	testing.expect_value(t, result.error.kind, Policy_Error_Kind.Unavailable)
	testing.expect_value(t, result.error.cause, Policy_Error_Cause.ABI_Probe)
	testing.expect_value(t, result.error.raw_errno, i32(38))
	testing.expect(t, .Filesystem in result.features_omitted, "filesystem intent should be visibly omitted")
	testing.expect(t, .Network in result.features_omitted, "network intent should be visibly omitted")
	testing.expect_value(t, count_fake_calls(.Create), 0)

	summary, err := debug_summary(result)
	testing.expect_value(t, err.kind, Policy_Error_Kind.None)
	defer delete(summary)
	expect_debug_contains(t, summary, "status=Unavailable")
	expect_debug_contains(t, summary, "abi_requested=9")
	expect_debug_contains(t, summary, "abi_used=0")
	expect_debug_contains(t, summary, "requested=[Filesystem,Network]")
	expect_debug_contains(t, summary, "applied=[]")
	expect_debug_contains(t, summary, "omitted=[Filesystem,Network]")
	expect_debug_contains(t, summary, "error_kind=Unavailable")
	expect_debug_contains(t, summary, "error_cause=ABI_Probe")
	expect_debug_contains(t, summary, "raw_errno=38")
}

@(test)
test_best_effort_eopnotsupp_reports_disabled :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.probe_errno = 95

	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)
	expect_policy_ok(t, allow_ro_dirs(&policy, "/tmp"), "allow_ro_dirs")

	result := apply_best_effort(&policy)
	testing.expect_value(t, result.status, Policy_Status.Disabled)
	testing.expect(t, result.status != .Enforced, "disabled Landlock must not be reported as enforced")
	testing.expect_value(t, result.error.kind, Policy_Error_Kind.Disabled)
	testing.expect_value(t, result.error.raw_errno, i32(95))
	testing.expect(t, .Filesystem in result.features_omitted, "filesystem intent should be visibly omitted")
	testing.expect_value(t, count_fake_calls(.Create), 0)

	summary, err := debug_summary(result)
	testing.expect_value(t, err.kind, Policy_Error_Kind.None)
	defer delete(summary)
	expect_debug_contains(t, summary, "status=Disabled")
	expect_debug_contains(t, summary, "error_kind=Disabled")
	expect_debug_contains(t, summary, "raw_errno=95")
	expect_debug_contains(t, summary, "omitted=[Filesystem]")
}

@(test)
test_create_e2big_is_syscall_failure :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.create_errno = 7

	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)
	expect_policy_ok(t, allow_ro_dirs(&policy, "/tmp"), "allow_ro_dirs")

	result := apply_strict(&policy)
	testing.expect_value(t, result.error.kind, Policy_Error_Kind.Syscall_Failed)
	testing.expect_value(t, result.error.cause, Policy_Error_Cause.Create_Ruleset)
	testing.expect_value(t, result.error.raw_errno, i32(7))
}

@(test)
test_add_rule_failure_closes_open_fd :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.add_path_errno = 5

	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)
	expect_policy_ok(t, allow_ro_dirs(&policy, "/tmp"), "allow_ro_dirs")

	result := apply_strict(&policy)
	testing.expect_value(t, result.error.kind, Policy_Error_Kind.Syscall_Failed)
	testing.expect_value(t, result.error.cause, Policy_Error_Cause.Add_Rule)
	testing.expect_value(t, result.error.raw_errno, i32(5))
	testing.expect_value(t, count_fake_calls(.Close, 20), 1)
	testing.expect_value(t, count_fake_calls(.Close, 3), 1)
}

@(test)
test_add_rule_eperm_preserves_add_rule_cause :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.add_path_errno = 1

	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)
	expect_policy_ok(t, allow_ro_dirs(&policy, "/tmp"), "allow_ro_dirs")

	result := apply_strict(&policy)
	testing.expect_value(t, result.error.kind, Policy_Error_Kind.Permission_Denied)
	testing.expect_value(t, result.error.cause, Policy_Error_Cause.Add_Rule)
	testing.expect_value(t, result.error.raw_errno, i32(1))
	testing.expect_value(t, count_fake_calls(.Close, 20), 1)
	testing.expect_value(t, count_fake_calls(.Close, 3), 1)
}

@(test)
test_prctl_failure_closes_all_fds :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.prctl_errno = 1

	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)
	expect_policy_ok(t, allow_ro_dirs(&policy, "/tmp"), "allow_ro_dirs")

	result := apply_strict(&policy)
	testing.expect_value(t, result.error.kind, Policy_Error_Kind.No_New_Privs_Failed)
	testing.expect_value(t, result.error.cause, Policy_Error_Cause.Set_No_New_Privs)
	testing.expect_value(t, result.error.raw_errno, i32(1))
	testing.expect_value(t, count_fake_calls(.Close, 20), 1)
	testing.expect_value(t, count_fake_calls(.Close, 3), 1)
}

@(test)
test_apply_eperm_is_permission_denied_and_closes_ruleset :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.apply_errno = 1

	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)
	expect_policy_ok(t, allow_ro_dirs(&policy, "/tmp"), "allow_ro_dirs")

	result := apply_strict(&policy)
	testing.expect_value(t, result.error.kind, Policy_Error_Kind.Permission_Denied)
	testing.expect_value(t, result.error.cause, Policy_Error_Cause.Restrict_Self)
	testing.expect_value(t, result.error.raw_errno, i32(1))
	testing.expect_value(t, count_fake_calls(.Close, 20), 1)
	testing.expect_value(t, count_fake_calls(.Close, 3), 1)
}

@(test)
test_best_effort_omits_unsupported_feature_but_applies_supported_rules :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.abi = 1

	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)

	expect_policy_ok(t, allow_ro_dirs(&policy, "/tmp"), "allow_ro_dirs")
	expect_policy_ok(t, allow_tcp_bind(&policy, 0), "allow_tcp_bind")

	strict_result := apply_strict(&policy)
	testing.expect_value(t, strict_result.status, Policy_Status.Unsupported_Feature)
	testing.expect(t, .Network in strict_result.features_omitted, "strict apply should report unsupported network")

	fake_reset()
	fake_state.abi = 1
	apply_ops = fake_apply_ops()
	result := apply_best_effort(&policy)
	testing.expect_value(t, result.status, Policy_Status.Partially_Enforced)
	testing.expect(t, .Filesystem in result.features_applied, "best effort should apply supported filesystem")
	testing.expect(t, .Network in result.features_omitted, "best effort should report omitted network")
	testing.expect_value(t, count_fake_calls(.Add_Net), 0)
	testing.expect_value(t, count_fake_calls(.Close, 20), 1)
	testing.expect_value(t, count_fake_calls(.Close, 3), 1)
}

@(test)
test_best_effort_full_enforcement_debug_summary :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.abi = 9

	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)
	expect_policy_ok(t, allow_ro_dirs(&policy, "/tmp"), "allow_ro_dirs")

	result := apply_best_effort(&policy)
	testing.expect_value(t, result.status, Policy_Status.Enforced)
	testing.expect(t, .Filesystem in result.features_applied, "filesystem should apply")
	testing.expect_value(t, result.features_omitted, Feature_Set{})

	summary, err := debug_summary(result)
	testing.expect_value(t, err.kind, Policy_Error_Kind.None)
	defer delete(summary)
	expect_debug_contains(t, summary, "status=Enforced")
	expect_debug_contains(t, summary, "abi_requested=9")
	expect_debug_contains(t, summary, "abi_used=9")
	expect_debug_contains(t, summary, "requested=[Filesystem]")
	expect_debug_contains(t, summary, "applied=[Filesystem]")
	expect_debug_contains(t, summary, "omitted=[]")
	expect_debug_contains(t, summary, "error_kind=None")
}

@(test)
test_best_effort_future_abi_999_uses_known_max :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.abi = 999

	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)
	expect_policy_ok(t, allow_path(&policy, .Directory, "/tmp", Path_Access{.Read_Dir, .Resolve_Unix}), "allow_path resolve unix")
	expect_policy_ok(t, allow_tcp_bind(&policy, 0), "allow_tcp_bind")
	expect_policy_ok(t, allow_tcp_connect(&policy, 443), "allow_tcp_connect")
	expect_policy_ok(t, scope_signal(&policy), "scope_signal")
	expect_policy_ok(t, enable_log_new_exec(&policy), "enable_log_new_exec")
	expect_policy_ok(t, enable_thread_sync(&policy), "enable_thread_sync")

	result := apply_best_effort(&policy)
	testing.expect_value(t, result.status, Policy_Status.Enforced)
	testing.expect_value(t, result.abi_requested, 999)
	testing.expect_value(t, result.abi_used, 9)
	testing.expect(t, .Filesystem in result.features_applied, "filesystem should apply at clamped abi v9")
	testing.expect(t, .Network in result.features_applied, "network should apply at clamped abi v9")
	testing.expect(t, .Scope in result.features_applied, "scope should apply at clamped abi v9")
	testing.expect(t, .Logging in result.features_applied, "logging should apply at clamped abi v9")
	testing.expect(t, .Thread_Sync in result.features_applied, "TSYNC should apply at clamped abi v9")
	testing.expect_value(t, result.features_omitted, Feature_Set{})
	// Create call carries the full deny-by-default handled set for the ABI...
	testing.expect_value(t, fake_state.calls[1].fs_access, abi_versions[9].supported_access_fs)
	testing.expect_value(t, fake_state.calls[1].net_access, syscall.Access_Net_Flags{.Bind_TCP, .Connect_TCP})
	// ...while the per-path add carries the masked requested rights.
	testing.expect_value(t, fake_state.calls[3].fs_access, path_access_to_syscall(Path_Access{.Read_Dir, .Resolve_Unix}))
	testing.expect_value(t, fake_state.calls[fake_state.call_count - 2].flags, syscall.Restrict_Self_Flags{.Log_New_Exec_On, .Tsync})

	summary, err := debug_summary(result)
	testing.expect_value(t, err.kind, Policy_Error_Kind.None)
	defer delete(summary)
	expect_debug_contains(t, summary, "status=Enforced")
	expect_debug_contains(t, summary, "abi_requested=999")
	expect_debug_contains(t, summary, "abi_used=9")
	expect_debug_contains(t, summary, "applied=[Filesystem,Network,Scope,Logging,Thread_Sync]")
	expect_debug_contains(t, summary, "omitted=[]")
}

@(test)
test_best_effort_omitted_only_policy_is_not_enforced :: proc(t: ^testing.T) {
	temp_dir := make_test_temp_dir(t)
	defer delete(temp_dir)
	defer os.remove_all(temp_dir)
	missing_path := join_test_path(t, temp_dir, "missing.txt")
	defer delete(missing_path)

	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops

	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)
	expect_policy_ok(t, allow_path(&policy, .File, missing_path, path_access_ro_file, Path_Options{missing = .Ignore}), "allow missing ignore")

	result := apply_best_effort(&policy)
	testing.expect_value(t, result.status, Policy_Status.Unsupported_Feature)
	testing.expect(t, result.status != .Enforced, "omitted-only policy must not be reported as enforced")
	testing.expect_value(t, result.features_applied, Feature_Set{})
	testing.expect(t, .Filesystem in result.features_omitted, "omitted-only filesystem intent should be visible")
	testing.expect_value(t, count_fake_calls(.Create), 0)
}

@(test)
test_debug_summary_unsupported_platform_path :: proc(t: ^testing.T) {
	result := policy_result_unsupported_platform()
	summary, err := debug_summary(result)
	testing.expect_value(t, err.kind, Policy_Error_Kind.None)
	defer delete(summary)
	expect_debug_contains(t, summary, "status=Unsupported_Platform")
	expect_debug_contains(t, summary, "error_kind=Unsupported_Platform")
	expect_debug_contains(t, summary, "error_cause=Unsupported_Platform")
	expect_debug_contains(t, summary, "applied=[]")
	expect_debug_contains(t, summary, "omitted=[]")
}


@(test)
test_network_options_abi3_vs_abi4 :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.abi = 3

	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)
	expect_policy_ok(t, allow_tcp_bind(&policy, 0), "allow_tcp_bind zero")
	expect_policy_ok(t, allow_tcp_connect(&policy, 443), "allow_tcp_connect")

	strict_result := apply_strict(&policy)
	testing.expect_value(t, strict_result.status, Policy_Status.Unsupported_Feature)
	testing.expect(t, .Network in strict_result.features_omitted, "abi v3 strict apply should omit network")
	testing.expect_value(t, count_fake_calls(.Create), 0)
	testing.expect_value(t, count_fake_calls(.Add_Net), 0)

	fake_reset()
	fake_state.abi = 4
	apply_ops = fake_apply_ops()
	result := apply_strict(&policy)
	testing.expect_value(t, result.status, Policy_Status.Enforced)
	testing.expect(t, .Network in result.features_applied, "abi v4 should apply network")
	testing.expect_value(t, count_fake_calls(.Add_Net), 2)
	testing.expect_value(t, fake_state.calls[2].arg2, 0)
	testing.expect(t, .Bind_TCP in fake_state.calls[2].net_access, "bind rule should preserve port zero")
	testing.expect_value(t, fake_state.calls[3].arg2, 443)
	testing.expect(t, .Connect_TCP in fake_state.calls[3].net_access, "connect rule should be added at abi v4")
}

@(test)
test_scope_options_abi5_vs_abi6 :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.abi = 5

	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)
	expect_policy_ok(t, scope_signal(&policy), "scope_signal")
	expect_policy_ok(t, scope_abstract_unix(&policy), "scope_abstract_unix")

	strict_result := apply_strict(&policy)
	testing.expect_value(t, strict_result.status, Policy_Status.Unsupported_Feature)
	testing.expect(t, .Scope in strict_result.features_omitted, "abi v5 strict apply should omit scope")
	testing.expect_value(t, count_fake_calls(.Create), 0)

	fake_reset()
	fake_state.abi = 6
	apply_ops = fake_apply_ops()
	result := apply_strict(&policy)
	testing.expect_value(t, result.status, Policy_Status.Enforced)
	testing.expect(t, .Scope in result.features_applied, "abi v6 should apply scope")
	testing.expect(t, .Signal in fake_state.calls[1].scoped, "ruleset attr should include signal scope")
	testing.expect(t, .Abstract_Unix_Socket in fake_state.calls[1].scoped, "ruleset attr should include abstract unix scope")
}

@(test)
test_scope_rejects_exception_rule :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.abi = 6

	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)
	expect_policy_ok(t, scope_abstract_unix(&policy), "scope_abstract_unix")

	result := apply_strict(&policy)
	testing.expect_value(t, result.status, Policy_Status.Enforced)
	testing.expect_value(t, count_fake_calls(.Add_Path), 0)
	testing.expect_value(t, count_fake_calls(.Add_Net), 0)
	testing.expect(t, .Abstract_Unix_Socket in fake_state.calls[1].scoped, "scope is configured on ruleset attr, not add-rule exceptions")
}

@(test)
test_logging_options_abi6_vs_abi7 :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.abi = 6

	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)
	expect_policy_ok(t, allow_ro_dirs(&policy, "/tmp"), "allow_ro_dirs")
	expect_policy_ok(t, enable_log_new_exec(&policy), "enable_log_new_exec")
	expect_policy_ok(t, disable_log_same_exec(&policy), "disable_log_same_exec")
	expect_policy_ok(t, disable_log_subdomains(&policy), "disable_log_subdomains")

	result := apply_best_effort(&policy)
	testing.expect_value(t, result.status, Policy_Status.Partially_Enforced)
	testing.expect(t, .Filesystem in result.features_applied, "filesystem should still apply at abi v6")
	testing.expect(t, .Logging in result.features_omitted, "abi v6 should omit logging")
	testing.expect_value(t, fake_state.calls[fake_state.call_count - 2].flags, syscall.Restrict_Self_Flags{})

	fake_reset()
	fake_state.abi = 7
	apply_ops = fake_apply_ops()
	result = apply_strict(&policy)
	testing.expect_value(t, result.status, Policy_Status.Enforced)
	testing.expect(t, .Logging in result.features_applied, "abi v7 should apply logging")
	restrict_call := fake_state.calls[fake_state.call_count - 2]
	testing.expect(t, .Log_New_Exec_On in restrict_call.flags, "new exec logging flag should be passed")
	testing.expect(t, .Log_Same_Exec_Off in restrict_call.flags, "same exec logging flag should be passed")
	testing.expect(t, .Log_Subdomains_Off in restrict_call.flags, "subdomains logging flag should be passed")
}

@(test)
test_thread_sync_abi7_vs_abi8 :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.abi = 7

	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)
	expect_policy_ok(t, allow_ro_dirs(&policy, "/tmp"), "allow_ro_dirs")
	expect_policy_ok(t, enable_thread_sync(&policy), "enable_thread_sync")

	strict_result := apply_strict(&policy)
	testing.expect_value(t, strict_result.status, Policy_Status.Unsupported_Feature)
	testing.expect(t, .Thread_Sync in strict_result.features_omitted, "abi v7 strict apply should report omitted TSYNC")
	testing.expect_value(t, count_fake_calls(.Create), 0)

	fake_reset()
	fake_state.abi = 7
	apply_ops = fake_apply_ops()
	result := apply_best_effort(&policy)
	testing.expect_value(t, result.status, Policy_Status.Partially_Enforced)
	testing.expect(t, .Filesystem in result.features_applied, "filesystem should still apply at abi v7")
	testing.expect(t, .Thread_Sync in result.features_omitted, "abi v7 best effort should report omitted TSYNC")
	testing.expect(t, !(.Tsync in fake_state.calls[fake_state.call_count - 2].flags), "TSYNC must not be passed below abi v8")

	fake_reset()
	fake_state.abi = 8
	apply_ops = fake_apply_ops()
	result = apply_strict(&policy)
	testing.expect_value(t, result.status, Policy_Status.Enforced)
	testing.expect(t, .Thread_Sync in result.features_applied, "abi v8 should apply explicit TSYNC")
	testing.expect(t, .Tsync in fake_state.calls[fake_state.call_count - 2].flags, "TSYNC should be passed at abi v8")
}

@(test)
test_resolve_unix_path_access_abi8_vs_abi9 :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.abi = 8

	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)
	expect_policy_ok(t, allow_path(&policy, .Directory, "/tmp", Path_Access{.Read_Dir, .Resolve_Unix}), "allow_path resolve unix")

	result := apply_best_effort(&policy)
	testing.expect_value(t, result.status, Policy_Status.Partially_Enforced)
	testing.expect(t, .Filesystem in result.features_applied, "read dir should apply at abi v8")
	testing.expect(t, .Filesystem in result.features_omitted, "abi v8 should omit the unsupported FS right (Resolve_Unix)")
	testing.expect(t, .Read_Dir in fake_state.calls[3].fs_access, "supported access should be added")
	testing.expect(t, !(.Resolve_Unix in fake_state.calls[3].fs_access), "Resolve_Unix must not be passed at abi v8")

	fake_reset()
	fake_state.abi = 9
	apply_ops = fake_apply_ops()
	result = apply_strict(&policy)
	testing.expect_value(t, result.status, Policy_Status.Enforced)
	testing.expect(t, .Filesystem in result.features_applied, "abi v9 should apply filesystem (incl. Resolve_Unix)")
	testing.expect(t, .Resolve_Unix in fake_state.calls[3].fs_access, "Resolve_Unix should be passed per-path at abi v9")
}

@(test)
test_default_handles_all_dimensions_deny_by_default :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.abi = 9

	// Only a filesystem rule is added, but the default handled set is all three
	// dimensions, so the ruleset denies network + scope by default too.
	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)
	expect_policy_ok(t, allow_ro_dirs(&policy, "/usr"), "allow_ro_dirs")

	result := apply_strict(&policy)
	testing.expect_value(t, result.status, Policy_Status.Enforced)
	testing.expect_value(t, fake_state.calls[1].fs_access, abi_versions[9].supported_access_fs)
	testing.expect_value(t, fake_state.calls[1].net_access, abi_versions[9].supported_access_net)
	testing.expect_value(t, fake_state.calls[1].scoped, abi_versions[9].supported_scoped)
	testing.expect(t, .Network in result.features_handled, "network is denied by default even without a net rule")
	testing.expect(t, .Scope in result.features_handled, "scope is denied by default even without a scope rule")
}

@(test)
test_policy_handle_narrows_handled_set :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.abi = 9

	// Narrow deny-by-default to filesystem only: network + scope stay free.
	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)
	expect_policy_ok(t, handle_features(&policy, {.Filesystem}), "policy_handle")
	expect_policy_ok(t, allow_ro_dirs(&policy, "/usr"), "allow_ro_dirs")

	result := apply_strict(&policy)
	testing.expect_value(t, result.status, Policy_Status.Enforced)
	testing.expect_value(t, fake_state.calls[1].fs_access, abi_versions[9].supported_access_fs)
	testing.expect_value(t, fake_state.calls[1].net_access, syscall.Access_Net_Flags{})
	testing.expect_value(t, fake_state.calls[1].scoped, syscall.Scope_Flags{})
	testing.expect(t, .Filesystem in result.features_handled, "filesystem stays handled")
	testing.expect(t, !(.Network in result.features_handled), "network left unrestricted when not handled")
	testing.expect(t, !(.Scope in result.features_handled), "scope left unrestricted when not handled")
}

@(test)
test_logging_thread_sync_not_handled_unless_enabled :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.abi = 9 // ABI supports logging + TSYNC

	// No enable_* calls: Logging/Thread_Sync must NOT appear in features_handled
	// even though the running ABI supports them (they are opt-in restrict flags).
	policy: Policy
	expect_policy_ok(t, init(&policy), "init")
	defer cleanup(&policy)
	expect_policy_ok(t, allow_ro_dirs(&policy, "/usr"), "allow_ro_dirs")

	result := apply_strict(&policy)
	testing.expect_value(t, result.status, Policy_Status.Enforced)
	testing.expect(t, !(.Logging in result.features_handled), "logging not handled unless enabled")
	testing.expect(t, !(.Thread_Sync in result.features_handled), "thread_sync not handled unless enabled")
}

@(test)
test_logging_thread_sync_handled_when_enabled :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.abi = 9

	// With enable_* calls and an ABI that supports them, both are reported handled.
	policy: Policy
	expect_policy_ok(t, init(&policy), "init")
	defer cleanup(&policy)
	expect_policy_ok(t, allow_ro_dirs(&policy, "/usr"), "allow_ro_dirs")
	expect_policy_ok(t, enable_log_new_exec(&policy), "enable_log_new_exec")
	expect_policy_ok(t, enable_thread_sync(&policy), "enable_thread_sync")

	result := apply_strict(&policy)
	testing.expect_value(t, result.status, Policy_Status.Enforced)
	testing.expect(t, .Logging in result.features_handled, "logging handled when enabled")
	testing.expect(t, .Thread_Sync in result.features_handled, "thread_sync handled when enabled")
}

@(test)
test_rule_for_unhandled_feature_rejected :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.abi = 9

	// Narrowing the handled set to Network but still adding a filesystem rule is a
	// construction contradiction: the FS rule can never take effect. It must be
	// rejected at apply (Invalid_Policy / Rule_For_Unhandled_Feature) in BOTH apply
	// modes, before any kernel call — not silently folded into features_omitted as
	// if it were an ABI gap.
	policy: Policy
	expect_policy_ok(t, init(&policy), "init")
	defer cleanup(&policy)
	expect_policy_ok(t, handle_features(&policy, {.Network}), "handle_features network only")
	expect_policy_ok(t, allow_ro_dirs(&policy, "/usr"), "allow_ro_dirs")
	expect_policy_ok(t, allow_tcp_bind(&policy, 80), "allow_tcp_bind")

	strict := apply_strict(&policy)
	testing.expect_value(t, strict.status, Policy_Status.Invalid_Policy)
	testing.expect_value(t, strict.error.validation, Policy_Validation_Failure.Rule_For_Unhandled_Feature)
	testing.expect(t, .Filesystem in strict.features_omitted, "offending unhandled dimension named in features_omitted")
	testing.expect(t, !(.Network in strict.features_omitted), "handled dimension is not flagged")
	testing.expect_value(t, count_fake_calls(.Create), 0)

	fake_reset()
	best := apply_best_effort(&policy)
	testing.expect_value(t, best.status, Policy_Status.Invalid_Policy)
	testing.expect_value(t, best.error.validation, Policy_Validation_Failure.Rule_For_Unhandled_Feature)
	testing.expect_value(t, count_fake_calls(.Create), 0)
}

@(test)
test_handled_dimensions_with_matching_rules_ok :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.abi = 9

	// Handling both dimensions that have rules is the correct shape: no
	// contradiction, full enforcement.
	policy: Policy
	expect_policy_ok(t, init(&policy), "init")
	defer cleanup(&policy)
	expect_policy_ok(t, handle_features(&policy, {.Filesystem, .Network}), "handle_features fs+net")
	expect_policy_ok(t, allow_ro_dirs(&policy, "/usr"), "allow_ro_dirs")
	expect_policy_ok(t, allow_tcp_connect(&policy, 443), "allow_tcp_connect")

	result := apply_strict(&policy)
	testing.expect_value(t, result.status, Policy_Status.Enforced)
	testing.expect(t, result.error.validation != .Rule_For_Unhandled_Feature, "no false contradiction")
	testing.expect(t, .Filesystem in result.features_applied, "fs applied")
	testing.expect(t, .Network in result.features_applied, "net applied")
}

@(test)
test_empty_handled_set_is_invalid_policy :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.abi = 9

	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)
	expect_policy_ok(t, handle_features(&policy, {}), "policy_handle empty")
	expect_policy_ok(t, allow_ro_dirs(&policy, "/usr"), "allow_ro_dirs")

	result := apply_strict(&policy)
	testing.expect_value(t, result.status, Policy_Status.Invalid_Policy)
	testing.expect_value(t, result.error.validation, Policy_Validation_Failure.Empty_Handled_Set)
	testing.expect_value(t, count_fake_calls(.Create), 0)
}

@(test)
test_is_enforced_helper :: proc(t: ^testing.T) {
	testing.expect(t, is_enforced(Policy_Result{status = .Enforced}), "Enforced is enforced")
	testing.expect(t, !is_enforced(Policy_Result{status = .Partially_Enforced}), "Partial is not enforced")
	testing.expect(t, !is_enforced(Policy_Result{status = .Unavailable}), "Unavailable is not enforced")
}

@(test)
test_reject_symlink_opens_with_nofollow :: proc(t: ^testing.T) {
	saved_ops := use_fake_apply_ops()
	defer apply_ops = saved_ops
	fake_state.abi = 9

	// A .Reject path must be opened with O_NOFOLLOW so a post-validation symlink
	// swap is not followed (FIND-002). A default (.Follow) path must not.
	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)
	expect_policy_ok(
		t,
		allow_path(&policy, .Directory, "/usr", path_access_ro_dir, Path_Options{symlink = .Reject}),
		"allow_path reject",
	)
	expect_policy_ok(t, allow_ro_dirs(&policy, "/etc"), "allow_ro_dirs follow")

	result := apply_strict(&policy)
	testing.expect_value(t, result.status, Policy_Status.Enforced)

	reject_seen, follow_seen := false, false
	for i in 0 ..< fake_state.call_count {
		c := fake_state.calls[i]
		if c.kind != .Open_Path do continue
		if c.no_follow do reject_seen = true
		else do follow_seen = true
	}
	testing.expect(t, reject_seen, ".Reject path must open with O_NOFOLLOW")
	testing.expect(t, follow_seen, "default .Follow path must open without O_NOFOLLOW")
}

@(test)
test_path_with_interior_nul_rejected :: proc(t: ^testing.T) {
	// An interior NUL would be truncated by the cstring conversion, silently
	// sandboxing a different path than named — reject it instead (FIND-F1).
	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)
	err := allow_path(&policy, .File, "/usr\x00.txt", path_access_ro_file)
	testing.expect_value(t, err.kind, Policy_Error_Kind.Invalid_Policy)
	testing.expect_value(t, err.validation, Policy_Validation_Failure.Invalid_Path)
	testing.expect_value(t, len(policy.rules_path), 0)
}

@(test)
test_oversized_path_rejected :: proc(t: ^testing.T) {
	// A path at/over PATH_MAX is rejected up front, before any stat/clone (FIND-F2).
	policy: Policy
	expect_policy_ok(t, init(&policy), "policy_init")
	defer cleanup(&policy)
	big := strings.repeat("a", posix.PATH_MAX, context.temp_allocator)
	err := allow_path(&policy, .Directory, big, path_access_ro_dir)
	testing.expect_value(t, err.kind, Policy_Error_Kind.Invalid_Policy)
	testing.expect_value(t, err.validation, Policy_Validation_Failure.Invalid_Path)
	testing.expect_value(t, len(policy.rules_path), 0)
}

