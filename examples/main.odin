package main

import "core:fmt"
import "core:os"
// This example lives inside the repo, so it imports the landlock package by
// relative path. An external program would import it by its module path, e.g.
//   import landlock "vendor/odin-landlock"
import landlock ".."
import "core:io"
import "core:text/table"

// Self-restrict this process's filesystem access using Landlock.
//
// After apply, the calling thread (and its descendants) can only touch the
// paths we explicitly allowed. Landlock restrictions are IRREVERSIBLE — you can
// only ever add more restrictions, never loosen them.
main :: proc() {
	policy: landlock.Policy
	if err := landlock.init(&policy); err.kind != .None {
		fmt.eprintln("init failed:", landlock.enum_to_string(err.kind))
		os.exit(1)
	}
	defer landlock.cleanup(&policy) // frees the copied path storage

	// A policy is deny-by-default over its handled set. The default handles all
	// restriction types (filesystem + network + scope); narrow it to filesystem +
	// network so this example restricts files and TCP while leaving IPC scope alone.
	if err := landlock.handle_features(&policy, {.Filesystem}); err.kind != .None {
		fmt.eprintln("handle_features:", landlock.enum_to_string(err.kind))
		os.exit(1)
	}

	// Read-only on system dirs; read-write only on a tmp dir.
	// Paths are copied into the policy, so the caller's strings can be freed.
	if err := landlock.allow_ro_dirs(&policy, "/usr", "/etc"); err.kind != .None {
		fmt.eprintln("allow_ro_dirs:", landlock.enum_to_string(err.kind))
		os.exit(1)
	}

	_, err := os.create("/tmp/secret")

	if err := landlock.allow_rw_dirs(&policy, "/tmp/work"); err.kind != .None {
		fmt.eprintln("allow_rw_dirs:", landlock.enum_to_string(err.kind))
		os.exit(1)
	}

	if err := landlock.allow_tcp_connect(&policy, 443); err.kind != .None {
		fmt.printf("tcp rule failed: %v\n", err.kind)
		return
	}
	// If precise control is needed other than the helpers, then build an explicit access mask.
	// Examples:
	// a single read-write log file that may also be truncated.
	//   rw := landlock.Path_Access{.Read_File, .Write_File, .Truncate}
	//   landlock.allow_path(&policy, .File, "/tmp/work/out.log", rw)
	// more examples of custom rules:
	//   landlock.allow_path(&policy, .Directory, "/dev", landlock.Path_Access{.Execute, .Read_File, .Read_Dir, .Ioctl_Dev})
	//   landlock.allow_path(&policy, .File, "/path/to/file", landlock.Path_Access{.Read_File, .Write_File, .Truncate})


	// apply_best_effort() degrades to the best Landlock ABI the running kernel supports,
	// which may be less restrictive than the one your policy targets.
	// use apply_strict() for strict "fail if unenforceable" behaviour.

	//	result := landlock.apply_best_effort(&policy)
	result := landlock.apply_strict(&policy)

	fmt.println("=== Landlock self-restriction result ===")
	stdout := table.stdio_writer()
	tbl := table.init(&table.Table{})
	table.caption(tbl, "=== Landlock self-restriction result ===")
	table.padding(tbl, 1, 0)
	table.row(tbl, "Status", ":", landlock.enum_to_string(result.status))
	table.row(tbl, "ABI requested, ver.", ":", result.abi_requested)
	table.row(tbl, "ABI used, ver.", ":", result.abi_used)
	table.row(tbl, "Features requested", ":", fmt.tprintf("%w", result.requested_features))
	table.row(tbl, "Features applied", ":", fmt.tprintf("%w", result.applied_features))
	table.row(tbl, "Features omitted", ":", fmt.tprintf("%w", result.omitted_features))
	table.build(tbl, table.unicode_width_proc)
	for row in 0 ..< tbl.nr_rows {
		for col in 0 ..< tbl.nr_cols {
			table.write_table_cell(stdout, tbl, row, col)
		}
		io.write_byte(stdout, '\n')
	}

	summary, summary_err := landlock.debug_summary(result)
	fmt.println("")
	if summary_err.kind == .None {
		defer delete(summary)
		fmt.println(summary)
	}

	#partial switch result.status {
	case .Enforced:
		fmt.printfln("sandboxed via Landlock ABI v%d", result.abi_used)
	case .Partially_Enforced:
		fmt.printfln(
			"partial sandbox (ABI v%d); omitted features = %v",
			result.abi_used,
			result.omitted_features,
		)
	case .Unavailable, .Disabled, .Unsupported_Platform:
		// Kernel has no/disabled Landlock.
		// fail immediately or continue unsandboxed.
		fmt.eprintln("landlock lsm not reachable:", landlock.enum_to_string(result.status))
	case .Invalid_Policy:
		fmt.eprintln("invalid landlock policy:", landlock.enum_to_string(result.error.validation))
		os.exit(1)
	case .Skipped_For_Test:
	// Only produced by the test cases; not reachable in normal use.
	}

	// Proof of restriction: when enforced, this read is denied
	// while /usr and /etc remain readable.
	if handle, err := os.open("/tmp/secret", os.O_RDONLY); err != nil {
		fmt.println("denied access to /tmp/secret as expected")
	} else {
		os.close(handle)
		fmt.println("WARNING: /tmp/secret still readable (landlock not enforcing)")
	}
}
