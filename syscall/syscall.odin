package syscall
import "core:io"
import "core:os"
/*
    Low-level interface to the Linux Landlock sandboxing feature.

    This package contains constants and syscall wrappers for Landlock.

    Landlock is Linux-only. The constants and data types below are shared by
    every target; the syscall procedures live in syscall_linux.odin (compiled
    only on Linux) and syscall_unsupported.odin (every other OS, where each
    procedure returns an "unsupported" error).

    The full documentation can be found at:
    https://www.kernel.org/doc/html/latest/userspace-api/landlock.html
*/

// PR_SET_NO_NEW_PRIVS from linux/prctl.h
PR_SET_NO_NEW_PRIVS :: 38

// Size of Ruleset_Attr in bytes
RULESET_ATTR_SIZE :: 24

// Landlock flags
@(private)
Create_Ruleset_Flag :: enum {
	Version = 1,
	Errata  = 2,
}

// Landlock flags for restricting the current process
Restrict_Self_Flag :: enum {
	// ABI v7, kernel 6.15+ (audit logging control)
	// https://github.com/torvalds/linux/commit/12bfcda73ac2
	Log_Same_Exec_Off  = 0,
	Log_New_Exec_On    = 1,
	Log_Subdomains_Off = 2,
	// ABI v8, kernel 7.0+ (TSYNC)
	// https://github.com/torvalds/linux/commit/42fc7e6543f6d17d2cf9ed3e5021f103a3d11182
	Tsync              = 3,
}
Restrict_Self_Flags :: bit_set[Restrict_Self_Flag;u64]
#assert(size_of(Restrict_Self_Flags) == size_of(u64))

// Landlock file system access rights.
// FS: https://www.kernel.org/doc/html/latest/userspace-api/landlock.html#filesystem-flags
// NET: https://www.kernel.org/doc/html/latest/userspace-api/landlock.html#network-flags
// ABI v1, kernel 5.13+:
// https://github.com/torvalds/linux/commit/265885daf3e5
Access_FS_Flag :: enum {
	Execute      = 0,
	Write_File   = 1,
	Read_File    = 2,
	Read_Dir     = 3,
	Remove_Dir   = 4,
	Remove_File  = 5,
	Make_Char    = 6,
	Make_Dir     = 7,
	Make_Reg     = 8,
	Make_Sock    = 9,
	Make_Fifo    = 10,
	Make_Block   = 11,
	Make_Sym     = 12,
	// ABI v2, kernel 5.19+
	// https://github.com/torvalds/linux/commit/b91c3e4ea756
	Refer        = 13,
	// ABI v3, kernel 6.2+
	// https://github.com/torvalds/linux/commit/b9f5ce27c8f8
	Truncate     = 14,
	// ABI v5, kernel 6.10+
	// https://github.com/torvalds/linux/commit/b25f7415eb41
	Ioctl_Dev    = 15,
	// ABI v9, kernel 7.1+
	// https://github.com/torvalds/linux/commit/d1b2ab221d37
	Resolve_Unix = 16,
}
Access_FS_Flags :: bit_set[Access_FS_Flag;u64]
#assert(size_of(Access_FS_Flags) == size_of(u64))

Access_Net_Flag :: enum {
	// ABI v4, kernel 6.7+
	// https://github.com/torvalds/linux/commit/fff69fb03dde
	Bind_TCP    = 0,
	Connect_TCP = 1,
}
Access_Net_Flags :: bit_set[Access_Net_Flag;u64]
#assert(size_of(Access_Net_Flags) == size_of(u64))

Scope_Flag :: enum {
	// ABI v6, kernel 6.12+
	// https://github.com/torvalds/linux/commit/21d52e295ad2
	Abstract_Unix_Socket = 0,
	Signal               = 1,
}
Scope_Flags :: bit_set[Scope_Flag;u64]
#assert(size_of(Scope_Flags) == size_of(u64))

// Landlock rule types
@(private)
Rule_Type :: enum {
	Path_Beneath = 1,
	Net_Port     = 2,
}

// Ruleset_Attr is the Landlock ruleset definition.
Ruleset_Attr :: struct {
	Handled_Access_FS:  Access_FS_Flags,
	Handled_Access_Net: Access_Net_Flags,
	Scoped:             Scope_Flags,
}
#assert(size_of(Ruleset_Attr) == RULESET_ATTR_SIZE)

// Path_Beneath_Attr references a file hierarchy and defines the desired
// extent to which it should be usable when the rule is enforced.
Path_Beneath_Attr :: struct #packed {
	Allowed_Access: Access_FS_Flags,
	Parent_Fd:      i32,
}
#assert(size_of(Path_Beneath_Attr) == 12)

// Net_Port_Attr specifies which ports can be used for what.
Net_Port_Attr :: struct {
	Allowed_Access: Access_Net_Flags,
	Port:           u64,
}
#assert(size_of(Net_Port_Attr) == 16)

path_beneath_attr :: proc "contextless" (
	access: Access_FS_Flags,
	parent_fd: int,
) -> Path_Beneath_Attr {
	return Path_Beneath_Attr{Allowed_Access = access, Parent_Fd = i32(parent_fd)}
}

net_port_attr :: proc "contextless" (access: Access_Net_Flags, port: u16) -> Net_Port_Attr {
	return Net_Port_Attr{Allowed_Access = access, Port = u64(port)}
}

when ODIN_OS != .Linux {
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
}
