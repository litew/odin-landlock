#+build !linux
package syscall

// Non-Linux stubs for the Landlock syscall wrappers: every procedure reports
// an "unsupported" error. Shared constants and data types live in syscall.odin;
// the Linux implementations live in syscall_linux.odin.

import "core:io"
import "core:os"

unsupported_platform_error :: proc "contextless" () -> os.Error {
	return os.Error(io.Error.Unsupported)
}

get_abi_version :: proc() -> (int, os.Error) {
	return 0, unsupported_platform_error()
}

create_ruleset :: proc(attr: ^Ruleset_Attr, flags: u32 = 0) -> (int, os.Error) {
	return -1, unsupported_platform_error()
}

add_path_beneath_rule :: proc(
	ruleset_fd: int,
	attr: ^Path_Beneath_Attr,
	flags: int,
) -> os.Error {
	return unsupported_platform_error()
}

add_net_port_rule :: proc(ruleset_fd: int, attr: ^Net_Port_Attr, flags: int) -> os.Error {
	return unsupported_platform_error()
}

add_rule_to_ruleset :: proc(
	ruleset_fd: int,
	rule_type: Rule_Type,
	rule_attr: rawptr,
	flags: int,
) -> os.Error {
	return unsupported_platform_error()
}

restrict_self :: proc(ruleset_fd: int, flags: int) -> os.Error {
	return unsupported_platform_error()
}

prctl :: proc(option: int, arg2, arg3, arg4, arg5: uintptr) -> os.Error {
	return unsupported_platform_error()
}

open_path :: proc(path: string, no_follow := false) -> (int, os.Error) {
	return -1, unsupported_platform_error()
}

close_fd :: proc(fd: int) -> os.Error {
	return unsupported_platform_error()
}
