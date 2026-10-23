# shellcheck shell=bash
# Test-harness state isolation.
#
# tmux-resurrect resolves its save directory from HOME and XDG_DATA_HOME
# (see scripts/helpers.sh), starts/kills a tmux server, and the tmux-test
# framework runs `rm -rf ~/.tmux/` plus `tmux kill-server` during teardown.
# Run against a real login, that silently overwrites the user's live
# recovery `last` pointer and kills their running tmux server.
#
# What `activate_test_sandbox` guarantees, before a test writes anything:
#   - relocated into a fresh sandbox root: HOME, XDG_DATA_HOME,
#     XDG_CONFIG_HOME, XDG_CACHE_HOME, XDG_STATE_HOME and TMUX_TMPDIR (so
#     the default tmux socket, and a bare `tmux kill-server`, are the
#     sandbox's own);
#   - cleared, so nothing inherited from an outer login steers the test
#     or its shells: TMUX, TMUX_PANE, HISTFILE, BASH_ENV, ENV, ZDOTDIR,
#     INPUTRC.
# It does not cover paths a test names explicitly: the expect scripts
# under tests/helpers write /tmp/foo.txt and use /tmp/bar, outside the
# sandbox.
#
# It is sourced and invoked by every resurrect test (via
# resurrect_helpers.sh, or directly by a test that does not use those
# helpers), so it holds however the test is launched: the Docker
# entrypoint, tests/run_tests_in_isolation on a host, or a test file run
# directly.
#
# activate_test_sandbox installs `trap cleanup_test_sandbox EXIT` to remove
# the sandbox when the test exits, and refuses to run if an EXIT trap is
# already set. A test that installs its own EXIT trap afterwards replaces
# the sandbox's, so its trap MUST call cleanup_test_sandbox (after its own
# steps), or the sandbox directory is left behind.
#
# RESURRECT_TEST_SANDBOX_BASE (test-only): the directory the sandbox root
# is created in; defaults to /tmp. A short fixed base keeps tmux socket
# paths under the sun_path limit. Only tests/test_sandbox.sh sets it, to
# simulate a mktemp failure.

# Remembers the sandbox root so cleanup_test_sandbox can remove it.
# Preserved across re-sourcing, so a nested source keeps the guard.
_RESURRECT_TEST_SANDBOX_ROOT="${_RESURRECT_TEST_SANDBOX_ROOT-}"

# Written into every sandbox root at activation; cleanup removes only a
# directory that carries it.
_RESURRECT_TEST_SANDBOX_MARKER=".tmux-resurrect-test-sandbox"

# The root's last component must be exactly what activation's mktemp
# template produces.
_resurrect_test_sandbox_has_root_name() {
	local root="$1"
	case "${root##*/}" in
		tmux-resurrect-test.??????) return 0 ;;
	esac
	return 1
}

# Absolute, with no `..`, `.` or empty component, so the path names
# exactly the directory it appears to.
_resurrect_test_sandbox_is_plain_absolute() {
	local root="$1"
	case "$root" in
		/*) ;;
		*) return 1 ;;
	esac
	case "$root/" in
		*/../*|*/./*|*//*) return 1 ;;
	esac
	return 0
}

# A real directory (not a symlink to one) carrying the sandbox marker.
_resurrect_test_sandbox_is_marked_dir() {
	local root="$1"
	[ -d "$root" ] && [ ! -L "$root" ] &&
		[ -f "$root/$_RESURRECT_TEST_SANDBOX_MARKER" ]
}

# True only for a directory this file's activation created.
_resurrect_test_sandbox_is_removable_root() {
	local root="$1"
	_resurrect_test_sandbox_has_root_name "$root" &&
		_resurrect_test_sandbox_is_plain_absolute "$root" &&
		_resurrect_test_sandbox_is_marked_dir "$root"
}

# rm -rf can fail with ENOTEMPTY while a dying tmux pane still writes
# into the tree, so retry once after a short pause before reporting.
_resurrect_test_sandbox_remove_root() {
	local root="$1"
	rm -rf "$root" 2>/dev/null && return 0
	sleep 0.5
	rm -rf "$root"
	[ -e "$root" ] || return 0
	printf 'sandbox: could not remove sandbox root: %s\n' "$root" >&2
	return 1
}

# Removes the sandbox root, but only one that is provably a sandbox root
# (see _resurrect_test_sandbox_is_removable_root), and forgets it. Safe
# to call more than once and before activation. Public: call it from any
# EXIT trap a test installs over the sandbox's own.
cleanup_test_sandbox() {
	local root="$_RESURRECT_TEST_SANDBOX_ROOT"
	[ -n "$root" ] || return 0
	_RESURRECT_TEST_SANDBOX_ROOT=""
	if ! _resurrect_test_sandbox_is_removable_root "$root"; then
		printf 'sandbox: refusing to remove suspicious root: %s\n' \
			"$root" >&2
		return 1
	fi
	_resurrect_test_sandbox_remove_root "$root"
}

# An EXIT trap installed before activation would be silently replaced by
# the sandbox's, dropping that test's own cleanup.
_resurrect_test_sandbox_assert_no_exit_trap() {
	local existing_trap
	existing_trap="$(trap -p EXIT)"
	[ -z "$existing_trap" ] && return 0
	printf '%s\n' \
		"sandbox: an EXIT trap is already set: $existing_trap" \
		"sandbox: activate the sandbox before installing it, and call" \
		"sandbox: cleanup_test_sandbox from that trap" >&2
	exit 1
}

# Fail loudly rather than run a state-mutating test against a HOME that was
# not successfully relocated into the sandbox.
_resurrect_test_sandbox_assert() {
	local sandbox_root="$1"
	local outer_home="$2"
	case "$HOME" in
		"$sandbox_root"/*) ;;
		*)
			printf 'sandbox: HOME %s is not under the sandbox root %s\n' \
				"$HOME" "$sandbox_root" >&2
			exit 1
			;;
	esac
	if [ "$HOME" = "$outer_home" ]; then
		printf 'sandbox: HOME was not relocated (still %s)\n' "$HOME" >&2
		exit 1
	fi
	if [ ! -d "$HOME/.tmux/resurrect" ]; then
		printf 'sandbox: state directory missing: %s\n' \
			"$HOME/.tmux/resurrect" >&2
		exit 1
	fi
}

# Creates the sandbox root and its marker; exits loudly on failure.
_resurrect_test_sandbox_create_root() {
	local base="${RESURRECT_TEST_SANDBOX_BASE:-/tmp}"
	local sandbox_root
	# Fail loudly on mktemp failure BEFORE deriving any path: the tests run
	# with neither `set -e` nor `set -u`, so an empty sandbox_root would
	# otherwise make HOME collapse to "/home".
	sandbox_root="$(mktemp -d "$base/tmux-resurrect-test.XXXXXX")"
	if [ ! -d "$sandbox_root" ]; then
		printf 'sandbox: mktemp -d failed to create a sandbox root\n' >&2
		exit 1
	fi
	if ! : > "$sandbox_root/$_RESURRECT_TEST_SANDBOX_MARKER"; then
		printf 'sandbox: could not mark sandbox root %s\n' \
			"$sandbox_root" >&2
		exit 1
	fi
	printf '%s\n' "$sandbox_root"
}

activate_test_sandbox() {
	# Idempotent: a nested source must not create a second sandbox.
	[ -n "$_RESURRECT_TEST_SANDBOX_ROOT" ] && return 0
	_resurrect_test_sandbox_assert_no_exit_trap

	local outer_home="${HOME-}"
	local sandbox_root
	sandbox_root="$(_resurrect_test_sandbox_create_root)" || exit 1
	_RESURRECT_TEST_SANDBOX_ROOT="$sandbox_root"
	trap cleanup_test_sandbox EXIT

	local sandbox_home="$sandbox_root/home"

	# Redirect every state-resolution path the harness and plugin use:
	#   HOME            -> ~/.tmux, ~/.tmux.conf, ~/.tmux/resurrect
	#   XDG_DATA_HOME   -> plugin's XDG fallback save directory
	#   XDG_CONFIG_HOME -> shells' and tools' XDG config lookups
	#   XDG_CACHE_HOME  -> shells' and tools' XDG cache writes
	#   XDG_STATE_HOME  -> shells' and tools' XDG state writes
	#   TMUX_TMPDIR     -> tmux socket dir (isolates `tmux kill-server`)
	export HOME="$sandbox_home"
	export XDG_DATA_HOME="$sandbox_home/.local/share"
	export XDG_CONFIG_HOME="$sandbox_home/.config"
	export XDG_CACHE_HOME="$sandbox_home/.cache"
	export XDG_STATE_HOME="$sandbox_home/.local/state"
	export TMUX_TMPDIR="$sandbox_root/tmux"
	# Never attach to or inherit an outer tmux server, and never let an
	# outer login's history file or shell startup files steer the test.
	unset TMUX TMUX_PANE HISTFILE BASH_ENV ENV ZDOTDIR INPUTRC

	mkdir -p \
		"$HOME/.tmux/resurrect" \
		"$XDG_DATA_HOME" \
		"$XDG_CONFIG_HOME" \
		"$XDG_CACHE_HOME" \
		"$XDG_STATE_HOME" \
		"$TMUX_TMPDIR"
	chmod 700 "$TMUX_TMPDIR"

	_resurrect_test_sandbox_assert "$sandbox_root" "$outer_home"
}
