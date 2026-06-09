// abi-conformance: a standalone real-kernel Landlock conformance probe.
//
// It probes the running kernel's Landlock ABI and runs an enforcement battery
// appropriate to that ABI, exiting 0 only if every applicable check passes. It is
// meant to be built on the host and executed inside per-kernel VMs (virtme-ng) by
// the kernel-matrix CI workflow — a plain binary, no Odin toolchain needed in the VM.
//
//   LANDLOCK_EXPECT_ABI=<n>   if set, assert the kernel reports exactly ABI <n>
//
// Each enforcement check runs in its own fork()ed child: Landlock is irreversible
// and cumulative, so checks must not share a sandboxed process. This binary is
// single-threaded, so fork() here is safe.
package abi_conformance

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sys/posix"
import landlock "../.."
import syscall "../../syscall"

EXIT_OK :: 0
EXIT_FAIL :: 1 // an enforcement check behaved wrong (e.g. sandbox escape)
EXIT_ABI_MISMATCH :: 2
EXIT_SETUP :: 3 // internal/setup error, not a Landlock conformance failure

// Inherited by fork()ed children (set once in main, before any fork).
g_abi: int
g_fs_probe: string // a readable file OUTSIDE the allowed tree

main :: proc() {
	abi, _ := syscall.get_abi_version()
	g_abi = abi
	fmt.printfln("abi=%d", abi)

	if exp, ok := expected_abi(); ok && abi != exp {
		fmt.eprintfln("ABI mismatch: expected %d, kernel reports %d", exp, abi)
		os.exit(EXIT_ABI_MISMATCH)
	}

	if abi <= 0 {
		// No Landlock (pre-5.13) or Landlock disabled in the LSM stack: apply must
		// fail closed with a typed Not_Enforced reason, never enforce.
		os.exit(check_unavailable())
	}

	// Probe file the sandbox must NOT be able to read (created unsandboxed here).
	g_fs_probe = fmt.tprintf("/tmp/ll_conf_probe_%d", posix.getpid())
	if os.write_entire_file(g_fs_probe, "x") != nil {
		fmt.eprintln("setup: could not create probe file")
		os.exit(EXIT_SETUP)
	}
	defer os.remove(g_fs_probe)

	run_check("fs-denial (v1+)", check_fs_denial)
	if abi >= 4 {
		run_check("net-bind-denial (v4+)", check_net_bind_denial)
	}
	run_check("best-effort-degradation", check_best_effort)

	fmt.println("PASS: all conformance checks")
}

expected_abi :: proc() -> (int, bool) {
	s := os.get_env("LANDLOCK_EXPECT_ABI", context.temp_allocator)
	if s == "" {
		return 0, false
	}
	return strconv.parse_int(s)
}

// fork_check runs child() in its own process and returns the child's exit code.
fork_check :: proc(child: proc() -> int) -> int {
	pid := posix.fork()
	if pid == 0 {
		os.exit(child())
	}
	status: c.int
	posix.waitpid(pid, &status, {})
	if !posix.WIFEXITED(status) {
		return EXIT_SETUP
	}
	return int(posix.WEXITSTATUS(status))
}

run_check :: proc(name: string, child: proc() -> int) {
	switch fork_check(child) {
	case 0:
		fmt.printfln("ok: %s", name)
	case EXIT_FAIL:
		fmt.eprintfln("FAIL: %s", name)
		os.exit(EXIT_FAIL)
	case:
		fmt.eprintfln("SETUP ERROR: %s", name)
		os.exit(EXIT_SETUP)
	}
}

// abi <= 0: assert a minimal policy refuses to enforce with a typed reason.
check_unavailable :: proc() -> int {
	policy: landlock.Policy
	if landlock.init(&policy).kind != .None {
		return EXIT_SETUP
	}
	defer landlock.cleanup(&policy)
	if landlock.allow_ro_dirs(&policy, "/usr").kind != .None {
		return EXIT_SETUP
	}
	result := landlock.apply_strict(&policy)
	#partial switch result.error.kind {
	case .Unavailable, .Disabled, .Unsupported_Platform:
		fmt.printfln("ok: landlock not enforced (error.kind=%v) as expected", result.error.kind)
		return EXIT_OK
	}
	fmt.eprintfln(
		"FAIL: expected Unavailable/Disabled, got status=%v error.kind=%v",
		result.status,
		result.error.kind,
	)
	return EXIT_FAIL
}

// v1+: allow /usr read-only; a read of the probe file (outside /usr) must be denied.
check_fs_denial :: proc() -> int {
	policy: landlock.Policy
	if landlock.init(&policy).kind != .None {return EXIT_SETUP}
	if landlock.handle_features(&policy, {.Filesystem}).kind != .None {return EXIT_SETUP}
	if landlock.allow_ro_dirs(&policy, "/usr").kind != .None {return EXIT_SETUP}
	if !landlock.is_enforced(landlock.apply_strict(&policy)) {return EXIT_SETUP}

	if fd, err := os.open(g_fs_probe, os.O_RDONLY); err == nil {
		os.close(fd)
		return EXIT_FAIL // sandbox escape: probe still readable
	}
	return EXIT_OK
}

// v4+: allow TCP bind on one port; binding a different port must be denied.
PORT_OK :: 38050
PORT_BAD :: 38051

check_net_bind_denial :: proc() -> int {
	policy: landlock.Policy
	if landlock.init(&policy).kind != .None {return EXIT_SETUP}
	if landlock.handle_features(&policy, {.Network}).kind != .None {return EXIT_SETUP}
	if landlock.allow_tcp_bind(&policy, PORT_OK).kind != .None {return EXIT_SETUP}
	if !landlock.is_enforced(landlock.apply_strict(&policy)) {return EXIT_SETUP}

	if try_bind(PORT_OK) != .OK {
		return EXIT_FAIL // allowed port should bind
	}
	if try_bind(PORT_BAD) == .OK {
		return EXIT_FAIL // disallowed port should be denied
	}
	return EXIT_OK
}

try_bind :: proc(port: u16) -> posix.result {
	fd := posix.socket(.INET, .STREAM)
	if i32(fd) < 0 {
		return .FAIL
	}
	defer posix.close(fd)
	addr := posix.sockaddr_in {
		sin_family = posix.sa_family_t(posix.AF.INET),
		sin_port   = u16be(port),
		sin_addr   = {s_addr = u32be(0)}, // INADDR_ANY
	}
	return posix.bind(fd, cast(^posix.sockaddr)&addr, posix.socklen_t(size_of(addr)))
}

// Best effort must never silently full-enforce: request a flag/right needing a
// higher ABI than present and confirm the gap is reported, not hidden.
check_best_effort :: proc() -> int {
	policy: landlock.Policy
	if landlock.init(&policy).kind != .None {return EXIT_SETUP}
	if landlock.handle_features(&policy, {.Filesystem}).kind != .None {return EXIT_SETUP}
	if landlock.allow_ro_dirs(&policy, "/usr").kind != .None {return EXIT_SETUP}
	// .Tsync requires ABI v8; on older kernels it must land in flags_omitted.
	if landlock.handle_flags(&policy, {.Tsync}).kind != .None {return EXIT_SETUP}

	result := landlock.apply_best_effort(&policy)
	if g_abi >= 8 {
		if .Tsync in result.flags_applied {return EXIT_OK}
		fmt.eprintfln("FAIL: ABI %d should apply Tsync, applied=%w", g_abi, result.flags_applied)
		return EXIT_FAIL
	}
	if result.status == .Partially_Enforced && .Tsync in result.flags_omitted {
		return EXIT_OK
	}
	fmt.eprintfln(
		"FAIL: ABI %d should omit Tsync (status=%v omitted=%w)",
		g_abi,
		result.status,
		result.flags_omitted,
	)
	return EXIT_FAIL
}
