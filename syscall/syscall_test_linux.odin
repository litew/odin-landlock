package syscall

import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:testing"

@(test)
test_syscall_error_negative_return_becomes_positive_errno :: proc(t: ^testing.T) {
	err := syscall_error(-1)
	raw, ok := os.is_platform_error(err)
	testing.expect(t, ok, "negative syscall return should become platform errno")
	testing.expect_value(t, raw, i32(1))
}

@(test)
test_syscall_error_non_negative_return_is_success :: proc(t: ^testing.T) {
	err_zero := syscall_error(0)
	testing.expect(t, err_zero == nil, "zero syscall return should be nil error")

	err_fd := syscall_error(7)
	testing.expect(t, err_fd == nil, "positive syscall return should be nil error")
}

@(test)
test_open_path_opens_real_path_and_close_fd_releases_it :: proc(t: ^testing.T) {
	fd, err := open_path("/tmp", false)
	testing.expect(t, err == nil, "open_path should succeed on an existing directory")
	if err != nil {
		return
	}
	testing.expect(t, fd > 0, "open_path should return a valid fd")
	testing.expect(t, close_fd(fd) == nil, "close_fd should succeed on an open fd")
}

@(test)
test_open_path_no_follow_rejects_symlink_with_eloop :: proc(t: ^testing.T) {
	// The link resolves to a real file when followed, so only
	// RESOLVE_NO_SYMLINKS can reject it — distinguishing the flag's effect
	// from ordinary loop detection (which also yields ELOOP on a -> a loops).
	real := fmt.tprintf("/tmp/ll_symlink_real_%d", posix.getpid())
	link := fmt.tprintf("/tmp/ll_symlink_link_%d", posix.getpid())
	defer os.remove(link)
	defer os.remove(real)
	werr := os.write_entire_file(real, "x")
	if !testing.expectf(t, werr == nil, "could not create symlink target: %s", os.error_string(werr)) {
		return
	}
	serr := os.symlink(real, link)
	if !testing.expectf(t, serr == nil, "could not create symlink: %s", os.error_string(serr)) {
		return
	}

	fd, err := open_path(link, false)
	if !testing.expect(t, err == nil, "open_path without no_follow should follow the symlink") {
		return
	}
	close_fd(fd)

	_, err = open_path(link, true)
	if !testing.expect(t, err != nil, "RESOLVE_NO_SYMLINKS must reject a path with a symlink") {
		return
	}
	raw, ok := os.is_platform_error(err)
	testing.expect(t, ok, "ELOOP should surface as a platform error")
	testing.expect_value(t, raw, i32(40)) // ELOOP
}

@(test)
test_close_fd_bad_fd_is_ebadf :: proc(t: ^testing.T) {
	err := close_fd(-1)
	if !testing.expect(t, err != nil, "closing an invalid fd should fail") {
		return
	}
	raw, ok := os.is_platform_error(err)
	testing.expect(t, ok, "EBADF should surface as a platform error")
	testing.expect_value(t, raw, i32(9)) // EBADF
}

@(test)
test_create_ruleset_and_add_rule_marshaling :: proc(t: ^testing.T) {
	// Creating a ruleset and adding a path rule exercises the attr marshaling
	// against the real kernel without restricting the process: no
	// landlock_restrict_self call is involved anywhere here.
	attr := Ruleset_Attr{Handled_Access_FS = Access_FS_Flags{.Execute}}
	ruleset_fd, err := create_ruleset(&attr)
	if !testing.expect(t, err == nil, "create_ruleset should succeed") {
		return
	}
	testing.expect(t, ruleset_fd > 0, "create_ruleset should return a valid fd")

	path_fd, open_err := open_path("/tmp", false)
	if !testing.expect(t, open_err == nil, "open_path should succeed") {
		close_fd(ruleset_fd)
		return
	}

	pb := path_beneath_attr(Access_FS_Flags{.Execute}, path_fd)
	testing.expect(t, add_path_beneath_rule(ruleset_fd, &pb, 0) == nil, "add_path_beneath_rule should succeed")

	testing.expect(t, close_fd(path_fd) == nil, "close_fd should release the path fd")
	testing.expect(t, close_fd(ruleset_fd) == nil, "close_fd should release the ruleset fd")
}
