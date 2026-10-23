# shellcheck shell=bash
# Sourcing this file auto-activates the test sandbox (sandbox.sh): HOME,
# the XDG dirs and the tmux socket dir are relocated into a disposable
# temp directory before any resurrect test function runs. Tests that do
# not source this file must source sandbox.sh and call
# activate_test_sandbox themselves; tests/test_sandbox.sh checks that
# every test file does one or the other.
_resurrect_helpers_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=tests/helpers/sandbox.sh
source "$_resurrect_helpers_dir/sandbox.sh" || exit 1
activate_test_sandbox || exit 1

# we want "fixed" dimensions no matter the size of real display
set_screen_dimensions_helper() {
	# stty only makes sense against a real terminal. When the harness runs
	# without a controlling tty (a piped/CI invocation) these calls do
	# nothing but print an "ioctl for device" error twice per test.
	[ -t 0 ] || return 0
	stty cols 200
	stty rows 50
}

last_save_file_differs_helper() {
	local original_file="$1"
	# True when diff reports a difference (or fails), as before.
	! diff "$original_file" "${HOME}/.tmux/resurrect/last"
}

configure_tmux_test_environment_helper() {
	printf '%s\n' \
		'set-option -g automatic-rename off' \
		'set-option -g default-shell /bin/bash' \
		>> "${HOME}/.tmux.conf"
}
