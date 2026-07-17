# shellcheck shell=bash
# Test-harness state isolation.
#
# tmux-resurrect resolves its save directory from HOME and XDG_DATA_HOME
# (see scripts/helpers.sh), starts/kills a tmux server, and the tmux-test
# framework runs `rm -rf ~/.tmux/` plus `tmux kill-server` during teardown.
# Run against a real login, that silently overwrites the user's live
# recovery `last` pointer and kills their running tmux server.
#
# `activate_test_sandbox` relocates every path the harness and the plugin
# can touch into a disposable temp directory, so a test run can NEVER reach
# real user state. It is sourced and invoked by every resurrect test (via
# resurrect_helpers.sh), which means the guarantee holds no matter how the
# test is launched: the Docker entrypoint, tests/run_tests_in_isolation on a
# host, or a test file run directly.

# Remembers the sandbox root so the EXIT trap can remove it.
_RESURRECT_TEST_SANDBOX_ROOT=""

_resurrect_test_sandbox_cleanup() {
	[ -n "$_RESURRECT_TEST_SANDBOX_ROOT" ] || return 0
	case "$_RESURRECT_TEST_SANDBOX_ROOT" in
		/tmp/*|/var/folders/*|"${TMPDIR%/}"/*)
			rm -rf "$_RESURRECT_TEST_SANDBOX_ROOT"
			;;
		*)
			# Never rm -rf a path that is not clearly a temp dir.
			printf 'sandbox: refusing to remove suspicious root: %s\n' \
				"$_RESURRECT_TEST_SANDBOX_ROOT" >&2
			;;
	esac
	_RESURRECT_TEST_SANDBOX_ROOT=""
}

# Fail loudly rather than run a state-mutating test against a HOME that was
# not successfully relocated into the sandbox.
_resurrect_test_sandbox_assert() {
	local expected_home="$1"
	if [ "$HOME" != "$expected_home" ]; then
		printf 'sandbox: HOME was not relocated (got %s, want %s)\n' \
			"$HOME" "$expected_home" >&2
		exit 1
	fi
	if [ ! -d "$HOME/.tmux/resurrect" ]; then
		printf 'sandbox: state directory missing: %s\n' \
			"$HOME/.tmux/resurrect" >&2
		exit 1
	fi
}

activate_test_sandbox() {
	# Idempotent: a nested source must not create a second sandbox.
	[ -n "$_RESURRECT_TEST_SANDBOX_ROOT" ] && return 0

	local sandbox_root
	sandbox_root="$(mktemp -d "${TMPDIR:-/tmp}/tmux-resurrect-test.XXXXXX")"
	_RESURRECT_TEST_SANDBOX_ROOT="$sandbox_root"
	trap _resurrect_test_sandbox_cleanup EXIT

	local sandbox_home="$sandbox_root/home"

	# Redirect every state-resolution path the harness and plugin use:
	#   HOME            -> ~/.tmux, ~/.tmux.conf, ~/.tmux/resurrect
	#   XDG_DATA_HOME   -> plugin's XDG fallback save directory
	#   XDG_CONFIG_HOME
	#   XDG_CACHE_HOME
	#   TMUX_TMPDIR     -> tmux socket dir (isolates `tmux kill-server`)
	export HOME="$sandbox_home"
	export XDG_DATA_HOME="$sandbox_home/.local/share"
	export XDG_CONFIG_HOME="$sandbox_home/.config"
	export XDG_CACHE_HOME="$sandbox_home/.cache"
	export XDG_STATE_HOME="$sandbox_home/.local/state"
	export TMUX_TMPDIR="$sandbox_root/tmux"
	# Never let a test attach to or inherit an outer tmux server.
	unset TMUX

	mkdir -p \
		"$HOME/.tmux/resurrect" \
		"$XDG_DATA_HOME" \
		"$XDG_CONFIG_HOME" \
		"$XDG_CACHE_HOME" \
		"$XDG_STATE_HOME" \
		"$TMUX_TMPDIR"
	chmod 700 "$TMUX_TMPDIR"

	_resurrect_test_sandbox_assert "$sandbox_home"
}
