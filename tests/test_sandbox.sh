#!/usr/bin/env bash

# Checks tests/helpers/sandbox.sh, the state isolation every other test
# relies on to keep the harness away from real user state.
#
# Each case runs activate_test_sandbox in a fresh `bash -c` child whose
# HOME, XDG_* and TMUX_TMPDIR point at a separate scratch directory and
# whose TMUX and TMUX_PANE carry fake values. Every assertion compares
# against those known outer values, so a sandbox that did nothing could
# not pass.
#
# This file activates the sandbox itself too, before anything else, so
# run_tests' teardown_helper (a bare `tmux kill-server` and
# `rm -rf ~/.tmux/`) and every scratch path stay inside a sandbox.

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPOSITORY_DIR="$( cd "$CURRENT_DIR/.." && pwd )"

# shellcheck source=tests/helpers/helpers.sh
source "$CURRENT_DIR/helpers/helpers.sh"
# shellcheck source=tests/helpers/sandbox.sh
source "$CURRENT_DIR/helpers/sandbox.sh"
activate_test_sandbox

readonly SANDBOX_HELPER="$CURRENT_DIR/helpers/sandbox.sh"
readonly RELOCATED_VARS=(
	HOME
	XDG_DATA_HOME
	XDG_CONFIG_HOME
	XDG_CACHE_HOME
	XDG_STATE_HOME
	TMUX_TMPDIR
)

# The scratch "real login" the children start from. It lives inside this
# file's own sandbox, so the sandbox's EXIT trap removes it.
OUTER_DIR="$HOME/outer"
OUTER_HOME="$OUTER_DIR/home"
readonly OUTER_SENTINEL="outer-home-sentinel"
readonly FAKE_TMUX="/outer/fake/tmux-socket,4242,0"
readonly FAKE_TMUX_PANE="%4242"
OUTER_ENV=(
	"HOME=$OUTER_HOME"
	"XDG_DATA_HOME=$OUTER_DIR/xdg-data"
	"XDG_CONFIG_HOME=$OUTER_DIR/xdg-config"
	"XDG_CACHE_HOME=$OUTER_DIR/xdg-cache"
	"XDG_STATE_HOME=$OUTER_DIR/xdg-state"
	"TMUX_TMPDIR=$OUTER_DIR/tmux-tmpdir"
	"TMUX=$FAKE_TMUX"
	"TMUX_PANE=$FAKE_TMUX_PANE"
)

# Child scripts. Each is run as `bash -c <script> _ <sandbox.sh>`, so $1
# is the helper to source. Single quotes are intended: the child expands.
# shellcheck disable=SC2016
readonly CHILD_REPORT_RELOCATION='
source "$1"
activate_test_sandbox
printf "root=%s\n" "$_RESURRECT_TEST_SANDBOX_ROOT"
for name in HOME XDG_DATA_HOME XDG_CONFIG_HOME XDG_CACHE_HOME \
	XDG_STATE_HOME TMUX_TMPDIR; do
	printf "%s=%s\n" "$name" "${!name}"
done
printf "tmux_set=%s\n" "${TMUX+yes}"
printf "tmux_pane_set=%s\n" "${TMUX_PANE+yes}"
[ -d "$HOME/.tmux/resurrect" ] && printf "state_dir=yes\n"
printf "tmux_tmpdir_mode=%s\n" "$(ls -ld "$TMUX_TMPDIR" | cut -c1-10)"
'
# shellcheck disable=SC2016
readonly CHILD_OWN_EXIT_TRAP='
source "$1"
activate_test_sandbox
own_cleanup() {
	printf "own_trap=ran\n"
	cleanup_test_sandbox
}
trap own_cleanup EXIT
printf "root=%s\n" "$_RESURRECT_TEST_SANDBOX_ROOT"
'
# shellcheck disable=SC2016
readonly CHILD_ACTIVATE_ONLY='
source "$1"
activate_test_sandbox
printf "root=%s\n" "$_RESURRECT_TEST_SANDBOX_ROOT"
printf "reached=after-activate\n"
'
# shellcheck disable=SC2016
readonly CHILD_ACTIVATE_TWICE='
source "$1"
activate_test_sandbox
printf "first_root=%s\n" "$_RESURRECT_TEST_SANDBOX_ROOT"
printf "first_home=%s\n" "$HOME"
activate_test_sandbox
printf "second_root=%s\n" "$_RESURRECT_TEST_SANDBOX_ROOT"
printf "second_home=%s\n" "$HOME"
'
# shellcheck disable=SC2016
readonly CHILD_CLEANUP_ROOT='
source "$1"
_RESURRECT_TEST_SANDBOX_ROOT="$2"
cleanup_test_sandbox
'

# A fresh, empty outer login with one sentinel file, so a case can prove
# the sandbox never wrote into it.
reset_outer_dir() {
	rm -rf "${OUTER_DIR:?}"
	mkdir -p "$OUTER_HOME"
	: > "$OUTER_HOME/$OUTER_SENTINEL"
}

# Runs a child script against the outer login. Leading arguments are
# passed to env(1) first (e.g. `-u TMPDIR` or `TMPDIR=...`); the script
# follows `--`, then any extra positional arguments for it.
run_child() {
	local env_args=()
	while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
		env_args+=("$1")
		shift
	done
	shift
	local script="$1"
	shift
	env "${env_args[@]}" "${OUTER_ENV[@]}" \
		bash -c "$script" _ "$SANDBOX_HELPER" "$@"
}

# Prints the value of `key=value` in a child's report; fails if absent.
report_field() {
	local key="$1"
	local report="$2"
	local line
	while IFS= read -r line; do
		case "$line" in
			"$key="*)
				printf '%s\n' "${line#"$key="}"
				return 0
				;;
		esac
	done <<< "$report"
	return 1
}

expect_equal() {
	local expected="$1"
	local actual="$2"
	local message="$3"
	if [ "$expected" != "$actual" ]; then
		fail_helper "$message: expected [$expected], got [$actual]"
	fi
}

outer_value_of() {
	local name="$1"
	local entry
	for entry in "${OUTER_ENV[@]}"; do
		case "$entry" in
			"$name="*)
				printf '%s\n' "${entry#"$name="}"
				return 0
				;;
		esac
	done
	return 1
}

# A relocated variable must have left its outer value and landed under
# the child's sandbox root.
expect_relocated() {
	local name="$1"
	local root="$2"
	local report="$3"
	local inner outer
	inner="$(report_field "$name" "$report")"
	outer="$(outer_value_of "$name")"
	if [ "$inner" = "$outer" ]; then
		fail_helper "relocation: $name kept its outer value [$outer]"
		return
	fi
	case "$inner" in
		"$root"/*) ;;
		*) fail_helper "relocation: $name=[$inner] not under [$root]" ;;
	esac
}

# Outer home must still hold exactly the sentinel and nothing else.
expect_outer_home_untouched() {
	local message="$1"
	local contents
	contents="$(ls -A "$OUTER_HOME" 2>&1)"
	expect_equal "$OUTER_SENTINEL" "$contents" "$message"
}

# The child's root must be a real path, and gone once the child exited.
expect_root_removed() {
	local root="$1"
	local message="$2"
	if [ -z "$root" ]; then
		fail_helper "$message: child reported no sandbox root"
		return
	fi
	if [ -e "$root" ]; then
		fail_helper "$message: sandbox root survived exit: $root"
	fi
}

test_activate_relocates_every_state_path() {
	local report root name
	reset_outer_dir
	if ! report="$(run_child -- "$CHILD_REPORT_RELOCATION")"; then
		fail_helper "relocation: child exited non-zero"
		return
	fi
	root="$(report_field root "$report")"
	case "$root" in
		/*) ;;
		*)
			fail_helper "relocation: no absolute sandbox root [$root]"
			return
			;;
	esac
	for name in "${RELOCATED_VARS[@]}"; do
		expect_relocated "$name" "$root" "$report"
	done
	expect_equal "" "$(report_field tmux_set "$report")" \
		"relocation: TMUX still set"
	expect_equal "" "$(report_field tmux_pane_set "$report")" \
		"relocation: TMUX_PANE still set"
	expect_equal "yes" "$(report_field state_dir "$report")" \
		"relocation: \$HOME/.tmux/resurrect exists"
	expect_equal "drwx------" "$(report_field tmux_tmpdir_mode "$report")" \
		"relocation: TMUX_TMPDIR mode"
	expect_outer_home_untouched "relocation: outer HOME contents"
}

test_exit_trap_removes_sandbox_root() {
	local report
	reset_outer_dir
	report="$(run_child -- "$CHILD_ACTIVATE_ONLY")"
	expect_root_removed "$(report_field root "$report")" "own EXIT trap"
}

test_chained_exit_trap_removes_sandbox_root() {
	local report
	reset_outer_dir
	report="$(run_child -- "$CHILD_OWN_EXIT_TRAP" 2>&1)"
	expect_equal "ran" "$(report_field own_trap "$report")" \
		"chained EXIT trap: test's own trap ran"
	expect_root_removed "$(report_field root "$report")" \
		"chained EXIT trap calling cleanup_test_sandbox"
}

test_mktemp_failure_exits_before_touching_home() {
	local missing_tmpdir="$OUTER_DIR/no-such-tmpdir"
	local output status
	reset_outer_dir
	output="$(run_child "TMPDIR=$missing_tmpdir" -- \
		"$CHILD_ACTIVATE_ONLY" 2>&1)"
	status=$?
	if [ "$status" -eq 0 ]; then
		fail_helper "mktemp failure: child exited 0"
	fi
	case "$output" in
		*"sandbox: mktemp"*) ;;
		*) fail_helper "mktemp failure: no mktemp message in [$output]" ;;
	esac
	if report_field reached "$output" >/dev/null; then
		fail_helper "mktemp failure: child ran past activate_test_sandbox"
	fi
	expect_outer_home_untouched "mktemp failure: outer HOME contents"
}

test_activate_twice_keeps_one_root() {
	local report first_root
	reset_outer_dir
	report="$(run_child -- "$CHILD_ACTIVATE_TWICE")"
	first_root="$(report_field first_root "$report")"
	if [ -z "$first_root" ]; then
		fail_helper "idempotency: first activation reported no root"
		return
	fi
	expect_equal "$first_root" "$(report_field second_root "$report")" \
		"idempotency: sandbox root"
	expect_equal "$(report_field first_home "$report")" \
		"$(report_field second_home "$report")" \
		"idempotency: HOME"
	expect_root_removed "$first_root" "idempotency"
}

# True when a path is inside one of cleanup's temp-dir allowlist arms
# (for the TMPDIR values these cases use).
is_in_temp_allowlist() {
	local path="$1"
	local tmpdir="$2"
	case "$path" in
		/tmp/*|/var/folders/*|"$tmpdir"/*) return 0 ;;
	esac
	return 1
}

# Calls cleanup_test_sandbox with the root pointing at a real directory
# outside every temp location; it must refuse and leave it in place.
expect_cleanup_refuses() {
	local message="$1"
	shift
	local keep_dir output
	if ! keep_dir="$(mktemp -d "$REPOSITORY_DIR/.sandbox-refuse.XXXXXX")"
	then
		fail_helper "$message: could not create a non-temp directory"
		return
	fi
	if is_in_temp_allowlist "$keep_dir" "$OUTER_DIR/tmpdir"; then
		fail_helper "$message: precondition: $keep_dir is a temp path"
		rmdir "$keep_dir"
		return
	fi
	output="$(run_child "$@" -- "$CHILD_CLEANUP_ROOT" "$keep_dir" 2>&1)"
	if [ ! -d "$keep_dir" ]; then
		fail_helper "$message: removed non-temp root $keep_dir"
	fi
	case "$output" in
		*"refusing"*) ;;
		*) fail_helper "$message: no refusing message in [$output]" ;;
	esac
	# Empty by construction; rmdir cannot remove anything else.
	rmdir "$keep_dir" 2>/dev/null
}

test_cleanup_refuses_non_temp_root() {
	reset_outer_dir
	mkdir -p "$OUTER_DIR/tmpdir"
	expect_cleanup_refuses "cleanup with TMPDIR set" \
		"TMPDIR=$OUTER_DIR/tmpdir"
}

test_cleanup_refuses_non_temp_root_with_tmpdir_unset() {
	reset_outer_dir
	expect_cleanup_refuses "cleanup with TMPDIR unset" -u TMPDIR
}

main() {
	run_tests
}
main
