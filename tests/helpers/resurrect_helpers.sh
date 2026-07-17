# Relocate all real user state (HOME, XDG dirs, tmux socket) into a
# disposable sandbox before any resurrect test touches it. Sourcing this
# file is the single chokepoint every resurrect test passes through, so the
# isolation holds for the Docker harness, tests/run_tests_in_isolation, and
# a test file run directly.
_resurrect_helpers_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=tests/helpers/sandbox.sh
source "$_resurrect_helpers_dir/sandbox.sh"
# Sourcing this file auto-activates the sandbox: HOME/XDG/tmux socket are
# relocated below, before any resurrect test function runs.
activate_test_sandbox

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
	diff "$original_file" "${HOME}/.tmux/resurrect/last"
	[ $? -ne 0 ]
}

configure_tmux_test_environment_helper() {
	printf '%s\n' \
		'set-option -g automatic-rename off' \
		'set-option -g default-shell /bin/bash' \
		>> "${HOME}/.tmux.conf"
}
