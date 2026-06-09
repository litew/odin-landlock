#+private
package landlock

// Real-kernel Landlock enforcement integration test.
//
// Unlike the rest of the suite (which drives the apply path through the Apply_Ops
// fake seam), this test applies a real policy via the actual syscalls and checks
// that the kernel denies a disallowed read. It is gated OFF by default:
//
//   odin test . -define:LANDLOCK_INTEGRATION=true -define:ODIN_TEST_THREADS=1
//
// landlock_restrict_self is IRREVERSIBLE and restricts only the calling thread, so
// the policy MUST be applied in a forked child — never the test thread (that would
// sandbox the rest of the runner). fork() in a multithreaded process is unsafe
// (the child may deadlock on an allocator lock held by another thread), so the
// test is meant to run single-threaded (ODIN_TEST_THREADS=1); the child also exits
// via os.exit and never returns to the test harness.

import "core:c"
import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:testing"

INTEGRATION :: #config(LANDLOCK_INTEGRATION, false)

when ODIN_OS == .Linux && INTEGRATION {

	// Child exit codes (the child cannot touch the parent's testing.T).
	CHILD_DENIED :: 0 // sandbox active and the disallowed read was denied  -> pass
	CHILD_ALLOWED :: 1 // sandbox active but the read still succeeded        -> fail
	CHILD_SKIP :: 2 // Landlock not enforced on this kernel                  -> skip
	CHILD_SETUP :: 3 // building the policy failed                           -> error

	@(test)
	test_real_kernel_denies_disallowed_read :: proc(t: ^testing.T) {
		// A probe file OUTSIDE the allowed hierarchy (/usr). Created by the parent
		// (unsandboxed); the forked child inherits the path and must be denied it.
		tmp := fmt.tprintf("/tmp/ll_integration_probe_%d", posix.getpid())
		if werr := os.write_entire_file(tmp, "x"); werr != nil {
			testing.fail_now(t, "could not create temp probe file")
		}
		defer os.remove(tmp)

		pid := posix.fork()
		if pid == 0 {
			os.exit(run_child(tmp))
		}
		if !testing.expect(t, pid > 0, "fork failed") {
			return
		}

		status: c.int
		posix.waitpid(pid, &status, {})
		if !testing.expect(t, posix.WIFEXITED(status), "child did not exit normally") {
			return
		}

		switch int(posix.WEXITSTATUS(status)) {
		case CHILD_DENIED:
		// pass: the kernel denied the disallowed read
		case CHILD_SKIP:
			fmt.eprintln("[integration] skipped: Landlock not enforced on this kernel/ABI")
		case CHILD_ALLOWED:
			testing.fail_now(
				t,
				"SANDBOX ESCAPE: a file outside the allowed hierarchy was still readable under Landlock",
			)
		case:
			testing.fail_now(t, "child failed to build the test policy")
		}
	}

	// run_child builds and applies a real FS-only policy in the forked child, then
	// returns one of the CHILD_* codes. It allows reading /usr but NOT /tmp, so
	// opening the parent's /tmp probe file must fail once Landlock is enforced.
	@(private = "file")
	run_child :: proc(tmp: string) -> int {
		policy: Policy
		if init(&policy).kind != .None {
			return CHILD_SETUP
		}
		if handle_features(&policy, {.Filesystem}).kind != .None {
			return CHILD_SETUP
		}
		if allow_ro_dirs(&policy, "/usr").kind != .None {
			return CHILD_SETUP
		}

		result := apply_strict(&policy)
		if !is_enforced(result) {
			return CHILD_SKIP
		}

		if fd, err := os.open(tmp, os.O_RDONLY); err == nil {
			os.close(fd)
			return CHILD_ALLOWED
		}
		return CHILD_DENIED
	}
}
