package landlock

import "core:fmt"
import "syscall"

/*
    Configuration layer
*/

access_fs_file := syscall.Access_FS_Flags{.Execute, .Write_File, .Read_File, .Truncate, .Ioctl_Dev}

access_fs_read := syscall.Access_FS_Flags{.Execute, .Read_File, .Read_Dir}

access_fs_write := syscall.Access_FS_Flags {
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

access_fs_read_write := access_fs_read + access_fs_write

ABI_Info :: struct {
	version:              int,
	supported_access_fs:  syscall.Access_FS_Flags,
	supported_access_net: syscall.Access_Net_Flags,
	supported_scoped:     syscall.Scope_Flags,
}

ABI_Error :: enum int {
	Not_Supported = -1,
	None          = 0,
}

abi_infos := [7]ABI_Info {
	{version = 0, supported_access_fs = {}, supported_access_net = {}},
	{
		version = 1,
		supported_access_fs = {
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
		},
		supported_access_net = {},
	},
	{
		version = 2,
		supported_access_fs = {abi_infos[1].supported_access_fs + .Refer},
		supported_access_net = {},
	},
	{
		version = 3,
		supported_access_fs = {abi_infos[2].supported_access_fs + .Truncate},
		supported_access_net = {},
	},
	{
		version = 4,
		supported_access_fs = {abi_infos[3].supported_access_fs},
		supported_access_net = {.Bind_TCP, .Connect_TCP},
	},
	{
		version = 5,
		supported_access_fs = {abi_infos[4].supported_access_fs + .Ioctl_Dev},
		supported_access_net = {abi_infos[4].supported_access_net},
	},
	{
		version = 6,
		supported_access_fs = {abi_infos[5].supported_access_fs},
		supported_access_net = {abi_infos[5].supported_access_net},
		supported_scoped = {.Abstract_Unix_Socket, .Signal},
	},
}

// Config describes the desired set of landlockable operations to be restricted
// and the constraints on it (e.g. best effort mode).
Config :: struct {
	handled_access_fs:  syscall.Access_FS_Flags,
	handled_access_net: syscall.Access_Net_Flags,
	handled_scoped:     syscall.Scope_Flags,
	restrict_flags:     syscall.Restrict_Self_Flags,
	best_effort:        bool,
}

// v0 denotes "no Landlock support". Only used internally.
@(private = "file")
v0 := Config{}
// These are Landlock configurations for the currently supported
// Landlock ABI versions, configured to restrict the highest possible
// set of operations possible for each version.
v1 := Config {
	handled_access_fs  = abi_infos[1].supported_access_fs,
	handled_access_net = abi_infos[1].supported_access_net,
}
v2 := Config {
	handled_access_fs  = abi_infos[2].supported_access_fs,
	handled_access_net = abi_infos[2].supported_access_net,
}
v3 := Config {
	handled_access_fs  = abi_infos[3].supported_access_fs,
	handled_access_net = abi_infos[3].supported_access_net,
}
v4 := Config {
	handled_access_fs  = abi_infos[4].supported_access_fs,
	handled_access_net = abi_infos[4].supported_access_net,
}
v5 := Config {
	handled_access_fs  = abi_infos[5].supported_access_fs,
	handled_access_net = abi_infos[5].supported_access_net,
}
v6 := Config {
	handled_access_fs  = abi_infos[6].supported_access_fs,
	handled_access_net = abi_infos[6].supported_access_net,
	handled_scoped     = abi_infos[6].supported_scoped,
}

// NetRule is a Rule which permits network access.
when ODIN_ENDIAN == .Little {

	NetRule :: struct {
		access_net: syscall.Access_Net_Flags,
		port:       u16le,
	}
} else when ODIN_ENDIAN == .Big {
	NetRule :: struct {
		access_net: syscall.Access_Net_Flags,
		port:       u16be,
	}
}

// FSRule is a Rule which permits access to file system paths.
FSRule :: struct {
	access_fs:      syscall.Access_FS_Flags,
	paths:          []string,
	enforce_subset: bool, // enforce that access_fs is a subset of cfg.handled_access_fs
	ignore_missing: bool, // ignore missing paths
}

// Rule represents one or more Landlock rules which can be added to a Landlock ruleset.
// In Odin, we use a union type to represent different rule types.
Rule :: union #no_nil {
	FSRule,
	NetRule,
}


supported_access_fs :: syscall.Access_FS_Flags {
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
	.Refer,
	.Truncate,
	.Ioctl_Dev,
}
supported_access_net :: syscall.Access_Net_Flags{.Bind_TCP, .Connect_TCP}
supported_scoped :: syscall.Scope_Flags{.Abstract_Unix_Socket, .Signal}
is_subset :: proc(a, b: $T) -> bool {
	return T(a) < T(b)
}

intersect :: proc(a, b: $T) -> T {
	return a & b
}

unite :: proc(a, b: $T) -> T {
	return a | b
}

is_empty :: proc(a: $T) -> bool {
	return a == 0
}

is_valid :: proc(a: $T, f: T) -> bool {
	return is_subset(a, f)
}

as_config :: proc "contextless" (a: ABI_Info) -> Config {
	return Config {
		handled_access_fs = a.supported_access_fs,
		handled_access_net = a.supported_access_net,
		handled_scoped = a.supported_scoped,
	}
}

// get_supported_abi_version returns the kernel-supported ABI version.
// If the ABI version supported by the kernel is higher than the newest one
// known to landlock, the highest ABI version known to landlock is returned.
get_supported_abi_version :: proc() -> (ABI_Info, ABI_Error) {
	if v, ret := syscall.get_abi_version(); ret == .NONE {
		if v >= len(abi_infos) {
			v = len(abi_infos) - 1
		}
		return abi_infos[v], ABI_Error.None
	} else {
		return abi_infos[0], ABI_Error.Not_Supported
	}
}

// NewConfig creates a new Landlock configuration with the given parameters.
NewConfig :: proc(rules: []Rule) -> ^Config {
	c := new(Config)

	for _, arg in args {
		fmt.printf("arg is : %s", arg)
		argtype: typeid
		argtype = type_of(arg)
		switch argtype {
		case syscall.Access_FS_Flags:
			if c.handled_access_fs != {} {
				return nil, "only one AccessFSSet may be provided"
			}
			if !(cast(syscall.Access_FS_Flags)arg < supported_access_fs) {
				return nil, "unsupported AccessFSSet value; upgrade landlock?"
			}
			c.handled_access_fs = cast(syscall.Access_FS_Flags)arg
		case syscall.Access_Net_Flags:
			if c.handled_access_net != {} {
				return nil, "only one AccessNetSet may be provided"
			}
			if !(cast(syscall.Access_Net_Flags)arg < supported_access_net) {
				return nil, "unsupported AccessNetSet value; upgrade landlock?"
			}
			c.handled_access_net = cast(syscall.Access_Net_Flags)arg
		case:
			return nil, fmt.tprintf(
				"unknown argument %v; only AccessFSSet or AccessNetSet arguments are supported",
				arg,
			)
		}
	}

	return c
}

// MustConfig is like NewConfig but panics on error.
MustConfig :: proc(args: ..any) -> Config {
	c, err := NewConfig(args)

	if err != nil {
		panic(err.?)
	}

	return c^
}


// RestrictPaths restricts all goroutines to only "see" the files
// provided as inputs.
restrict_paths :: proc(c: Config, rules: ..Rule) -> Maybe(string) {
	cfg := c
	cfg.handled_access_net = 0 // clear out everything but file system access
	return restrict(cfg, ..rules)
}

// RestrictNet restricts network access.
restrict_net :: proc(c: Config, rules: ..Rule) -> Maybe(string) {
	cfg := c
	cfg.handled_access_fs = 0 // clear out everything but network access
	return restrict(cfg, ..rules)
}

// Restrict restricts all types of access which is restrictable with the Config.
restrict :: proc(c: Config, rules: ..Rule) -> Maybe(string) {
	return restrict(c, ..rules)
}

path_access :: proc() -> FSRule {
	cfg := c
	cfg.handledAccessFS = AccessFSSet(u64(cfg.handledAccessFS) & u64(AccessFS.PathAccess))
	return restrict(cfg, ..rules)
}
