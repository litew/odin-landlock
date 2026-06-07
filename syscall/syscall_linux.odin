package syscall

import "core:os"
import "core:sys/linux"
import "core:sys/unix"

/*
    Low-level interface to the Linux Landlock sandboxing feature.

    This package contains constants and syscall wrappers for Landlock.
    The syscall wrappers whose names start with AllThreads will execute
    the syscall on all OS threads belonging to the current process.

    The full documentation can be found at:
    https://www.kernel.org/doc/html/latest/userspace-api/landlock.html
*/

// PR_SET_NO_NEW_PRIVS from linux/prctl.h
PR_SET_NO_NEW_PRIVS :: 38

// from include/uapi/linux/landlock.h

// Size of RulesetAttr in bytes
RULESET_ATTR_SIZE :: 16

// Landlock flags
Create_Ruleset :: enum {
	Version = 1,
	Errata  = 2,
}

// Landlock flags for restricting the current process
Restrict_Self_Flag :: enum {
	Log_Same_Exec_Off  = 0,
	Log_New_Exec_On    = 1,
	Log_Subdomains_Off = 2,
	Tsync              = 3,
}
Restrict_Self_Flags :: bit_set[Restrict_Self_Flag;u64]
#assert(size_of(Restrict_Self_Flags) == size_of(u64))

// Landlock file system access rights.
// FS: https://www.kernel.org/doc/html/latest/userspace-api/landlock.html#filesystem-flags
// NET: https://www.kernel.org/doc/html/latest/userspace-api/landlock.html#network-flags
// ABI v1, kernel v5.13+
Access_FS_Flag :: enum {
	Execute     = 0,
	Write_File  = 1,
	Read_File   = 2,
	Read_Dir    = 3,
	Remove_Dir  = 4,
	Remove_File = 5,
	Make_Char   = 6,
	Make_Dir    = 7,
	Make_Reg    = 8,
	Make_Sock   = 9,
	Make_Fifo   = 10,
	Make_Block  = 11,
	Make_Sym    = 12,
	// ABI v2, kernel 5.19+
	Refer       = 13,
	// ABI v3. kernel 6.2+
	Truncate    = 14,
	// ABI v5, kernel 6.10+
	Ioctl_Dev   = 15,
}
Access_FS_Flags :: bit_set[Access_FS_Flag;u64]
#assert(size_of(Access_FS_Flags) == size_of(u64))

Access_Net_Flag :: enum {
	// ABI v4, kernel 6.7+
	Bind_TCP    = 0,
	Connect_TCP = 1,
}
Access_Net_Flags :: bit_set[Access_Net_Flag;u64]
#assert(size_of(Access_Net_Flags) == size_of(u64))

Scope_Flag :: enum {
	// ABI v6, kernel 6.12+
	Abstract_Unix_Socket = 0,
	Signal               = 1,
}
Scope_Flags :: bit_set[Scope_Flag;u64]
#assert(size_of(Scope_Flags) == size_of(u64))

// Landlock rule types
Rule_Type :: enum {
	Path_Beneath = 1,
	Net_Port     = 2,
}
// RulesetAttr is the Landlock ruleset definition.
Ruleset_Attr :: struct {
	Handled_Access_FS:  Access_FS_Flags,
	Handled_Access_Net: Access_Net_Flags,
	Scoped:             Scope_Flags,
}

// PathBeneathAttr references a file hierarchy and defines the desired
// extent to which it should be usable when the rule is enforced.
Path_Beneath_Attr :: struct #max_field_align(16) {
	Allowed_Access: Access_FS_Flags,
	Parent_Fd:      linux.Fd,
}

// Net_Port_Attr specifies which ports can be used for what.
when ODIN_ENDIAN == .Little {
	Net_Port_Attr :: struct #max_field_align(16) {
		Allowed_Access: Access_Net_Flags,
		Port:           u64le,
	}
} else when ODIN_ENDIAN == .Big {
	Net_Port_Attr :: struct #max_field_align(16) {
		Allowed_Access: Access_Net_Flags,
		Port:           u64be,
	}
}

// landlock_get_abi_version returns the supported Landlock ABI version (starting at 1).
get_abi_version :: proc() -> (int, os.Error) {
	errno := linux.syscall(unix.SYS_landlock_create_ruleset, 0, 0, Create_Ruleset.Version)

	if errno < 0 {
		return errno, os.Platform_Error(i32(errno))
	} else {
		return errno, os.ERROR_NONE
	}

}

// LandlockCreateRuleset creates a ruleset file descriptor with the given attributes.
create_ruleset :: proc(attr: ^Ruleset_Attr, flags: u32 = 0) -> (int, os.Error) {
	fd := linux.syscall(
		unix.SYS_landlock_create_ruleset,
		uintptr(rawptr(attr)),
		uintptr(size_of(Ruleset_Attr)),
		uintptr(flags),
	)

	return fd, os.Platform_Error(i32(fd))
}

// LandlockAddPathBeneathRule adds a rule of type "path beneath" to the given ruleset fd.
add_path_beneath_rule :: proc(rulesetFd: int, attr: ^Path_Beneath_Attr, flags: int) -> os.Error {
	return add_rule_to_ruleset(rulesetFd, Rule_Type.Path_Beneath, attr, flags)
}

// LandlockAddNetPortRule adds a rule of type "net port" to the given ruleset FD.
add_net_port_rule :: proc(rulesetFd: int, attr: ^Net_Port_Attr, flags: int) -> os.Error {
	return add_rule_to_ruleset(rulesetFd, Rule_Type.Net_Port, attr, flags)
}

add_rule_to_ruleset :: proc(
	rulesetFd: int,
	ruleType: Rule_Type,
	ruleAttr: rawptr,
	flags: int,
) -> os.Error {
	ret := linux.syscall(
		unix.SYS_landlock_add_rule,
		uintptr(rulesetFd),
		uintptr(ruleType),
		rawptr(ruleAttr),
		uintptr(flags),
		0,
		0,
	)

	return os.Platform_Error(i32(ret))
}

restrict_self :: proc(rulesetFd: int, flags: int) -> os.Error {
	ret := linux.syscall(unix.SYS_landlock_restrict_self, uintptr(rulesetFd), uintptr(flags))

	return os.Platform_Error(i32(ret))
}

// AllThreadsPrctl is like prctl, but should be applied on all OS threads.
// Note: Simplified version without full psx support.
all_threads_prctl :: proc(option: int, arg2, arg3, arg4, arg5: uintptr) -> os.Error {
	ret := linux.syscall(
		unix.SYS_prctl,
		uintptr(arg2),
		uintptr(arg3),
		uintptr(arg4),
		uintptr(arg5),
		0,
	)

	return os.Platform_Error(i32(ret))
}
