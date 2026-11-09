#+build !linux
#+private
package landlock

// The Unsupported_Platform reporting path only fires on non-Linux targets
// (the syscall stubs report ABI 0 without an errno), so this test lives behind
// a build tag instead of inside the Linux-only test file. It never runs in the
// Linux CI job; it type-checks in the darwin/freebsd cross-target checks and
// runs when the suite is tested on a non-Linux host.

import "core:testing"

@(test)
test_non_linux_apply_reports_unsupported_platform :: proc(t: ^testing.T) {
	policy: Policy
	if init(&policy).kind != .None {
		testing.fail_now(t, "init failed")
	}
	defer cleanup(&policy)
	if err := allow_ro_dirs(&policy, "/tmp"); err.kind != .None {
		testing.fail_now(t, "allow_ro_dirs failed")
	}

	result := apply_best_effort(&policy)
	testing.expect_value(t, result.status, Policy_Status.Not_Enforced)
	testing.expect_value(t, result.error.kind, Policy_Error_Kind.Unsupported_Platform)
	testing.expect_value(t, result.abi_requested, 0)
	testing.expect_value(t, result.abi_used, 0)
	testing.expect_value(t, result.features_applied, Feature_Set{})
	testing.expect_value(t, result.features_requested, policy.features_requested)
	testing.expect_value(t, result.features_omitted, policy.features_requested)
}
