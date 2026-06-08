package syscall

import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:sys/unix"

// Landlock syscall wrappers for Linux.
// Shared constants and data types live in syscall.odin
// the non-Linux stubs live in syscall_unsupported.odin.

syscall_error :: proc "contextless" (ret: int) -> os.Error {
	if ret >= 0 {
		return os.ERROR_NONE
	}

	return os.Platform_Error(linux.Errno(-ret))
}

// get_abi_version returns the supported Landlock ABI version (starting at 1).
get_abi_version :: proc() -> (int, os.Error) {
	ret := linux.syscall(unix.SYS_landlock_create_ruleset, 0, 0, Create_Ruleset_Flag.Version)

	if ret < 0 {
		return 0, os.Platform_Error(linux.Errno(-ret))
	}

	return ret, os.ERROR_NONE
}

// create_ruleset creates a ruleset file descriptor with the given attributes.
create_ruleset :: proc(attr: ^Ruleset_Attr, flags: u32 = 0) -> (int, os.Error) {
	fd := linux.syscall(
		unix.SYS_landlock_create_ruleset,
		uintptr(rawptr(attr)),
		uintptr(size_of(Ruleset_Attr)),
		uintptr(flags),
	)

	if fd < 0 {
		return -1, os.Platform_Error(linux.Errno(-fd))
	}

	return fd, os.ERROR_NONE
}

// add_path_beneath_rule adds a rule of type "path beneath" to the given ruleset fd.
add_path_beneath_rule :: proc(ruleset_fd: int, attr: ^Path_Beneath_Attr, flags: int) -> os.Error {
	return add_rule_to_ruleset(ruleset_fd, Rule_Type.Path_Beneath, attr, flags)
}

// add_net_port_rule adds a rule of type "net port" to the given ruleset FD.
add_net_port_rule :: proc(ruleset_fd: int, attr: ^Net_Port_Attr, flags: int) -> os.Error {
	return add_rule_to_ruleset(ruleset_fd, Rule_Type.Net_Port, attr, flags)
}

add_rule_to_ruleset :: proc(
	ruleset_fd: int,
	rule_type: Rule_Type,
	rule_attr: rawptr,
	flags: int,
) -> os.Error {
	ret := linux.syscall(
		unix.SYS_landlock_add_rule,
		uintptr(ruleset_fd),
		uintptr(rule_type),
		rawptr(rule_attr),
		uintptr(flags),
		0,
		0,
	)

	return syscall_error(ret)
}

restrict_self :: proc(ruleset_fd: int, flags: int) -> os.Error {
	ret := linux.syscall(unix.SYS_landlock_restrict_self, uintptr(ruleset_fd), uintptr(flags))

	return syscall_error(ret)
}

prctl :: proc(option: int, arg2, arg3, arg4, arg5: uintptr) -> os.Error {
	ret := linux.syscall(
		unix.SYS_prctl,
		uintptr(option),
		uintptr(arg2),
		uintptr(arg3),
		uintptr(arg4),
		uintptr(arg5),
	)

	return syscall_error(ret)
}

// Open_How mirrors `struct open_how` from <linux/openat2.h>, the argument to the
// openat2(2) syscall. core:sys/linux has no wrapper for it yet.
Open_How :: struct {
	flags:   u64,
	mode:    u64,
	resolve: u64,
}

// RESOLVE_NO_SYMLINKS: openat2 fails (ELOOP) if ANY component of the path is a
// symbolic link, not just the final one.
RESOLVE_NO_SYMLINKS :: u64(0x04)

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
	// The cstring is only needed for the open syscall below; free it on return so
	// the wrapper leaves nothing behind (no reliance on the caller resetting temp).
	path_cstr, alloc_err := strings.clone_to_cstring(path, context.allocator)
	if alloc_err != nil {
		return -1, os.Error(alloc_err)
	}
	defer delete(path_cstr, context.allocator)

	how := Open_How {
		flags = u64(transmute(u32)linux.Open_Flags{.PATH, .CLOEXEC}),
	}
	if no_follow {
		how.resolve = RESOLVE_NO_SYMLINKS
	}
	ret := linux.syscall(
		linux.SYS_openat2,
		int(linux.AT_FDCWD),
		rawptr(path_cstr),
		&how,
		uint(size_of(Open_How)),
	)
	if ret < 0 {
		return -1, syscall_error(ret)
	}
	return int(ret), os.ERROR_NONE
}

// close_fd closes a raw kernel fd from open_path or create_ruleset. New core:os API has
// no portable raw-fd close (it operates on ^File[->fd]), so closing also goes through
// core:sys/linux and stays in here.
close_fd :: proc(fd: int) -> os.Error {
	errno := linux.close(linux.Fd(fd))
	if errno != .NONE {
		return os.Platform_Error(errno)
	}

	return os.ERROR_NONE
}
