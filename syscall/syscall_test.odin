package syscall

import "core:os"
import "core:testing"

@(test)
test_syscall_error_negative_return_becomes_positive_errno :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		err := syscall_error(-1)
		raw, ok := os.is_platform_error(err)
		testing.expect(t, ok, "negative syscall return should become platform errno")
		testing.expect_value(t, raw, i32(1))
	}
}

@(test)
test_syscall_error_non_negative_return_is_success :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		err_zero := syscall_error(0)
		testing.expect(t, err_zero == nil, "zero syscall return should be nil error")

		err_fd := syscall_error(7)
		testing.expect(t, err_fd == nil, "positive syscall return should be nil error")
	}
}
