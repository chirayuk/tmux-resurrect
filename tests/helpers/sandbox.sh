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
# activate_test_sandbox installs `trap 'cleanup_test_sandbox || exit 1'
# EXIT` to remove the sandbox when the test exits (a refused or failed
# removal fails the test), and refuses to run if an EXIT trap is already
# set. A test that installs its own EXIT trap afterwards replaces the
# sandbox's, so its trap MUST end with `cleanup_test_sandbox || exit 1`,
# or the sandbox directory is left behind.
#
# The sandbox root is created directly in a fixed base, /tmp, rather
# than in TMPDIR: the tmux socket lives under the root, and a long base
# (macOS's /var/folders/... TMPDIR) pushes socket paths past the 104-byte
# sun_path limit. Where /tmp is not writable, activation fails closed
# with a loud mktemp error rather than falling back anywhere else.
#
# RESURRECT_TEST_SANDBOX_BASE (test-only): overrides that base. It must
# be an absolute path with no `.`, `..` or empty component (trailing
# slashes are stripped). Only tests/test_sandbox.sh sets it.

# Remembers the sandbox root so cleanup_test_sandbox can remove it.
# Preserved across re-sourcing, so a nested source keeps the guard; an
# inherited value that does not describe the live sandbox is rejected by
# activate_test_sandbox.
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
	local path="$1"
	case "$path" in
		/*) ;;
		*) return 1 ;;
	esac
	case "$path/" in
		*/../*|*/./*|*//*) return 1 ;;
	esac
	return 0
}

# Prints the base the sandbox root lives in, trailing slashes stripped.
# Not validated here: see _resurrect_test_sandbox_valid_base.
_resurrect_test_sandbox_base() {
	local base="${RESURRECT_TEST_SANDBOX_BASE:-/tmp}"
	while [ "$base" != "${base%/}" ]; do
		base="${base%/}"
	done
	printf '%s\n' "$base"
}

# Prints the normalized base, or fails loudly when it is not a plain
# absolute path (a relative base would put the root wherever cwd is).
_resurrect_test_sandbox_valid_base() {
	local base
	base="$(_resurrect_test_sandbox_base)"
	if ! _resurrect_test_sandbox_is_plain_absolute "$base"; then
		printf 'sandbox: sandbox base is not a plain absolute path: %s\n' \
			"${RESURRECT_TEST_SANDBOX_BASE-}" >&2
		return 1
	fi
	printf '%s\n' "$base"
}

# The root must sit directly in the (normalized) sandbox base.
_resurrect_test_sandbox_is_in_base() {
	local root="$1"
	[ "${root%/*}" = "$(_resurrect_test_sandbox_base)" ]
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
		_resurrect_test_sandbox_is_in_base "$root" &&
		_resurrect_test_sandbox_is_marked_dir "$root"
}

# True when the stored root is a genuine sandbox root AND this shell's
# HOME and TMUX_TMPDIR actually point into it, i.e. the sandbox is live
# here rather than a value inherited from some other process.
_resurrect_test_sandbox_is_live() {
	local root="$_RESURRECT_TEST_SANDBOX_ROOT"
	_resurrect_test_sandbox_is_removable_root "$root" &&
		[ "${HOME-}" = "$root/home" ] &&
		[ "${TMUX_TMPDIR-}" = "$root/tmux" ]
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

# Creates the sandbox root and its marker; fails loudly (non-zero) on
# any error. Run in a command substitution, so it returns, not exits.
_resurrect_test_sandbox_create_root() {
	local base sandbox_root
	base="$(_resurrect_test_sandbox_valid_base)" || return 1
	# Fail loudly on mktemp failure BEFORE deriving any path: the tests run
	# with neither `set -e` nor `set -u`, so an empty sandbox_root would
	# otherwise make HOME collapse to "/home".
	sandbox_root="$(mktemp -d "$base/tmux-resurrect-test.XXXXXX")"
	if [ ! -d "$sandbox_root" ]; then
		printf 'sandbox: mktemp -d failed to create a sandbox root\n' >&2
		return 1
	fi
	if ! : > "$sandbox_root/$_RESURRECT_TEST_SANDBOX_MARKER"; then
		printf 'sandbox: could not mark sandbox root %s\n' \
			"$sandbox_root" >&2
		# Still empty: mktemp just made it and the marker never landed.
		rmdir "$sandbox_root"
		return 1
	fi
	printf '%s\n' "$sandbox_root"
}

# Idempotent: a nested source must not create a second sandbox. But a
# root value alone is not proof of a sandbox (it may be inherited from
# the environment), so a set value that is not live here fails loudly.
# Returns 0 when this shell already has a live sandbox, 1 when it has
# none yet.
_resurrect_test_sandbox_is_already_active() {
	[ -n "$_RESURRECT_TEST_SANDBOX_ROOT" ] || return 1
	_resurrect_test_sandbox_is_live && return 0
	printf 'sandbox: stale/inherited sandbox root %s %s\n' \
		"$_RESURRECT_TEST_SANDBOX_ROOT" \
		"(HOME and TMUX_TMPDIR are not inside it); refusing to run" >&2
	exit 1
}

activate_test_sandbox() {
	_resurrect_test_sandbox_is_already_active && return 0
	_resurrect_test_sandbox_assert_no_exit_trap

	local outer_home="${HOME-}"
	local sandbox_root
	sandbox_root="$(_resurrect_test_sandbox_create_root)" || exit 1
	_RESURRECT_TEST_SANDBOX_ROOT="$sandbox_root"
	trap 'cleanup_test_sandbox || exit 1' EXIT

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
