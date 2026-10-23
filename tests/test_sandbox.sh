#!/usr/bin/env bash

# Checks tests/helpers/sandbox.sh, the state isolation every other test
# relies on to keep the harness away from real user state.
#
# Each case runs activate_test_sandbox in a fresh `bash -c` child whose
# HOME, XDG_* and TMUX_TMPDIR point at a separate scratch directory and
# whose TMUX, TMUX_PANE and shell startup variables carry fake values.
# Every assertion compares against those known outer values, so a
# sandbox that did nothing could not pass.
#
# This file activates the sandbox itself too, before anything else, so
# run_tests' teardown_helper (a bare `tmux kill-server` and
# `rm -rf ~/.tmux/`) and every scratch path stay inside a sandbox.

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPOSITORY_DIR="$( cd "$CURRENT_DIR/.." && pwd )"

# shellcheck source=tests/helpers/helpers.sh
source "$CURRENT_DIR/helpers/helpers.sh" || exit 1
# shellcheck source=tests/helpers/sandbox.sh
source "$CURRENT_DIR/helpers/sandbox.sh" || exit 1
activate_test_sandbox || exit 1

readonly SANDBOX_HELPER="$CURRENT_DIR/helpers/sandbox.sh"
readonly HARNESS_HELPER="$CURRENT_DIR/helpers/helpers.sh"
readonly RESURRECT_HELPER="$CURRENT_DIR/helpers/resurrect_helpers.sh"
readonly SANDBOX_MARKER=".tmux-resurrect-test-sandbox"
readonly RELOCATED_VARS=(
	HOME
	XDG_DATA_HOME
	XDG_CONFIG_HOME
	XDG_CACHE_HOME
	XDG_STATE_HOME
	TMUX_TMPDIR
)
readonly CLEARED_VARS=(
	TMUX
	TMUX_PANE
	HISTFILE
	BASH_ENV
	ENV
	ZDOTDIR
	INPUTRC
)

# Test files that never use the tmux-test harness or start tmux, so they
# need no sandbox: test_docker_runner.sh unit-tests the host-side Docker
# runner against a stubbed docker() function and touches no user state.
readonly SANDBOX_EXEMPT_TEST_FILES=(test_docker_runner.sh)

# The scratch "real login" the children start from. It lives inside this
# file's own sandbox, so the sandbox's EXIT trap removes it.
OUTER_DIR="$HOME/outer"
OUTER_HOME="$OUTER_DIR/home"
readonly OUTER_SENTINEL="outer-home-sentinel"
# BASH_ENV must name a real (empty) file: the `bash -c` children source
# it at startup.
OUTER_ENV=(
	"HOME=$OUTER_HOME"
	"XDG_DATA_HOME=$OUTER_DIR/xdg-data"
	"XDG_CONFIG_HOME=$OUTER_DIR/xdg-config"
	"XDG_CACHE_HOME=$OUTER_DIR/xdg-cache"
	"XDG_STATE_HOME=$OUTER_DIR/xdg-state"
	"TMUX_TMPDIR=$OUTER_DIR/tmux-tmpdir"
	"TMUX=/outer/fake/tmux-socket,4242,0"
	"TMUX_PANE=%4242"
	"HISTFILE=$OUTER_DIR/histfile"
	"BASH_ENV=$OUTER_DIR/bash-env"
	"ENV=$OUTER_DIR/sh-env"
	"ZDOTDIR=$OUTER_DIR/zdotdir"
	"INPUTRC=$OUTER_DIR/inputrc"
)

# Child scripts. Each is run as `bash -c <script> _ <sandbox.sh> ...`, so
# $1 is the helper to source. Single quotes are intended: the child
# expands them.
# shellcheck disable=SC2016
readonly CHILD_REPORT_RELOCATION='
source "$1" || exit 1
activate_test_sandbox || exit 1
printf "root=%s\n" "$_RESURRECT_TEST_SANDBOX_ROOT"
for name in HOME XDG_DATA_HOME XDG_CONFIG_HOME XDG_CACHE_HOME \
	XDG_STATE_HOME TMUX_TMPDIR; do
	printf "%s=%s\n" "$name" "${!name}"
done
for name in TMUX TMUX_PANE HISTFILE BASH_ENV ENV ZDOTDIR INPUTRC; do
	if [ -n "${!name+x}" ]; then
		printf "%s_state=set\n" "$name"
	else
		printf "%s_state=unset\n" "$name"
	fi
done
state_dir=no
[ -d "$HOME/.tmux/resurrect" ] && state_dir=yes
printf "state_dir=%s\n" "$state_dir"
printf "tmux_tmpdir_mode=%s\n" "$(ls -ld "$TMUX_TMPDIR" | cut -c1-10)"
'
# shellcheck disable=SC2016
readonly CHILD_OWN_EXIT_TRAP='
source "$1" || exit 1
activate_test_sandbox || exit 1
own_cleanup() {
	printf "own_trap=ran\n"
	cleanup_test_sandbox
}
trap own_cleanup EXIT
root="$_RESURRECT_TEST_SANDBOX_ROOT"
printf "root=%s\n" "$root"
[ -d "$root" ] && printf "root_existed=yes\n"
'
# shellcheck disable=SC2016
readonly CHILD_ACTIVATE_ONLY='
source "$1" || exit 1
activate_test_sandbox || exit 1
root="$_RESURRECT_TEST_SANDBOX_ROOT"
printf "root=%s\n" "$root"
[ -d "$root" ] && printf "root_existed=yes\n"
printf "reached=after-activate\n"
'
# shellcheck disable=SC2016
readonly CHILD_PRESET_EXIT_TRAP='
trap "printf \"preset_trap=ran\n\"" EXIT
source "$1" || exit 1
activate_test_sandbox || exit 1
printf "reached=after-activate\n"
'
# shellcheck disable=SC2016
readonly CHILD_ACTIVATE_TWICE='
source "$1" || exit 1
activate_test_sandbox || exit 1
printf "first_root=%s\n" "$_RESURRECT_TEST_SANDBOX_ROOT"
printf "first_home=%s\n" "$HOME"
activate_test_sandbox || exit 1
root="$_RESURRECT_TEST_SANDBOX_ROOT"
printf "second_root=%s\n" "$root"
printf "second_home=%s\n" "$HOME"
[ -d "$root" ] && printf "root_existed=yes\n"
'
# $2: resurrect_helpers.sh, which sources sandbox.sh again and
# auto-activates.
# shellcheck disable=SC2016
readonly CHILD_RESOURCE_VIA_HELPERS='
source "$1" || exit 1
activate_test_sandbox || exit 1
printf "first_root=%s\n" "$_RESURRECT_TEST_SANDBOX_ROOT"
source "$2" || exit 1
root="$_RESURRECT_TEST_SANDBOX_ROOT"
printf "second_root=%s\n" "$root"
[ -d "$root" ] && printf "root_existed=yes\n"
'
# $2: the tmux-test harness helpers.sh, whose teardown is destructive.
# shellcheck disable=SC2016
readonly CHILD_HARNESS_TEARDOWN='
source "$2" || exit 1
source "$1" || exit 1
activate_test_sandbox || exit 1
teardown_helper
set_tmux_conf_helper <<< "sandbox-conf-line"
printf "sandbox_tmux_conf=%s\n" "$(cat "$HOME/.tmux.conf")"
'
# $2: resurrect_helpers.sh; $3: the repository, for scripts/helpers.sh;
# $4: "drop-state-dir" removes $HOME/.tmux/resurrect first, so the
# plugin takes its XDG_DATA_HOME fallback.
# shellcheck disable=SC2016
readonly CHILD_PLUGIN_RESURRECT_DIR='
source "$2" || exit 1
printf "root=%s\n" "$_RESURRECT_TEST_SANDBOX_ROOT"
if [ "${4-}" = drop-state-dir ]; then
	rmdir "$HOME/.tmux/resurrect" || exit 1
fi
plugin_dir="$(cd "$3/scripts" &&
	{ source ./helpers.sh; resurrect_dir; } 2>/dev/null)"
printf "resurrect_dir=%s\n" "$plugin_dir"
'
# Removes the marker, so the sandbox's own EXIT cleanup must refuse.
# shellcheck disable=SC2016
readonly CHILD_ACTIVATE_UNMARK_ROOT='
source "$1" || exit 1
activate_test_sandbox || exit 1
root="$_RESURRECT_TEST_SANDBOX_ROOT"
printf "root=%s\n" "$root"
rm -f "$root/.tmux-resurrect-test-sandbox" || exit 1
printf "reached=after-unmark\n"
'
# $2: the root to hand to cleanup_test_sandbox.
# shellcheck disable=SC2016
readonly CHILD_CLEANUP_ROOT='
source "$1" || exit 1
_RESURRECT_TEST_SANDBOX_ROOT="$2"
cleanup_test_sandbox
'

# A fresh outer login holding one sentinel file, so a case can prove the
# sandbox never wrote into it.
reset_outer_dir() {
	rm -rf "${OUTER_DIR:?}"
	mkdir -p "$OUTER_HOME"
	: > "$OUTER_HOME/$OUTER_SENTINEL"
	: > "$OUTER_DIR/bash-env"
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

expect_contains() {
	local needle="$1"
	local haystack="$2"
	local message="$3"
	case "$haystack" in
		*"$needle"*) ;;
		*) fail_helper "$message: no [$needle] in [$haystack]" ;;
	esac
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

expect_under_root() {
	local path="$1"
	local root="$2"
	local message="$3"
	case "$path" in
		"$root"/*) ;;
		*) fail_helper "$message: [$path] not under [$root]" ;;
	esac
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
	expect_under_root "$inner" "$root" "relocation: $name"
}

expect_cleared() {
	local name="$1"
	local report="$2"
	expect_equal "unset" "$(report_field "${name}_state" "$report")" \
		"relocation: $name still inherited"
}

# Outer home must still hold exactly the sentinel and nothing else.
expect_outer_home_untouched() {
	local message="$1"
	local contents
	contents="$(ls -A "$OUTER_HOME" 2>&1)"
	expect_equal "$OUTER_SENTINEL" "$contents" "$message"
}

# The child's root must have existed while it ran, and be gone once the
# child exited.
expect_root_removed() {
	local report="$1"
	local root_key="$2"
	local message="$3"
	local root
	root="$(report_field "$root_key" "$report")"
	if [ -z "$root" ]; then
		fail_helper "$message: child reported no sandbox root"
		return
	fi
	expect_equal "yes" "$(report_field root_existed "$report")" \
		"$message: root existed while the child ran"
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
	for name in "${CLEARED_VARS[@]}"; do
		expect_cleared "$name" "$report"
	done
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
	expect_root_removed "$report" root "sandbox EXIT trap"
}

test_chained_exit_trap_removes_sandbox_root() {
	local report
	reset_outer_dir
	report="$(run_child -- "$CHILD_OWN_EXIT_TRAP" 2>&1)"
	expect_equal "ran" "$(report_field own_trap "$report")" \
		"chained EXIT trap: test's own trap ran"
	expect_root_removed "$report" root \
		"chained EXIT trap calling cleanup_test_sandbox"
}

# Runs a child expected to stop inside activate_test_sandbox; checks it
# exited non-zero with the message and never touched the outer HOME.
# Arguments after the first two are run_child's.
expect_activation_aborts() {
	local message="$1"
	local expected_error="$2"
	shift 2
	local output status
	reset_outer_dir
	output="$(run_child "$@" 2>&1)"
	status=$?
	if [ "$status" -eq 0 ]; then
		fail_helper "$message: child exited 0"
	fi
	expect_contains "$expected_error" "$output" "$message"
	if report_field reached "$output" >/dev/null; then
		fail_helper "$message: child ran past activate_test_sandbox"
	fi
	expect_outer_home_untouched "$message: outer HOME contents"
}

test_mktemp_failure_exits_before_touching_home() {
	expect_activation_aborts "mktemp failure" "sandbox: mktemp" \
		"RESURRECT_TEST_SANDBOX_BASE=$OUTER_DIR/no-such-base" -- \
		"$CHILD_ACTIVATE_ONLY"
}

test_activation_refuses_preexisting_exit_trap() {
	expect_activation_aborts "preset EXIT trap" "EXIT trap" -- \
		"$CHILD_PRESET_EXIT_TRAP"
}

# An exported root variable must not turn activation into a no-op that
# leaves the real HOME and TMUX in place.
test_inherited_root_variable_aborts_activation() {
	expect_activation_aborts "inherited bogus root" \
		"stale/inherited sandbox root" \
		"_RESURRECT_TEST_SANDBOX_ROOT=$OUTER_DIR/fake" -- \
		"$CHILD_ACTIVATE_ONLY"
}

# Even a genuine, marked root in the base is stale when HOME was never
# moved into it.
test_inherited_marked_root_with_outer_home_aborts_activation() {
	local marked_root
	reset_outer_dir
	if ! marked_root="$(make_marked_root)"; then
		fail_helper "inherited marked root: could not create a root"
		return
	fi
	expect_activation_aborts "inherited marked root" \
		"stale/inherited sandbox root" \
		"RESURRECT_TEST_SANDBOX_BASE=$OUTER_DIR" \
		"_RESURRECT_TEST_SANDBOX_ROOT=$marked_root" -- \
		"$CHILD_ACTIVATE_ONLY"
}

test_relative_sandbox_base_aborts_activation() {
	expect_activation_aborts "relative base" "sandbox base" \
		"RESURRECT_TEST_SANDBOX_BASE=relative-sandbox-base" -- \
		"$CHILD_ACTIVATE_ONLY"
}

# A trailing slash on the base is normalized away: the root lands
# directly in /tmp and the EXIT trap still removes it.
test_trailing_slash_base_activates_and_cleans_up() {
	local report root
	reset_outer_dir
	report="$(run_child "RESURRECT_TEST_SANDBOX_BASE=/tmp/" -- \
		"$CHILD_ACTIVATE_ONLY" 2>&1)"
	root="$(report_field root "$report")"
	expect_equal "/tmp" "${root%/*}" "trailing-slash base: root parent"
	expect_root_removed "$report" root "trailing-slash base"
}

# A cleanup refusal in the sandbox's own EXIT trap must fail the test.
# The base is this file's scratch dir, so the refused root stays inside
# this file's own sandbox.
test_refused_exit_cleanup_fails_the_exit_status() {
	local output status
	reset_outer_dir
	output="$(run_child "RESURRECT_TEST_SANDBOX_BASE=$OUTER_DIR" -- \
		"$CHILD_ACTIVATE_UNMARK_ROOT" 2>&1)"
	status=$?
	expect_equal "after-unmark" "$(report_field reached "$output")" \
		"refused cleanup: child reached its end"
	if [ "$status" -eq 0 ]; then
		fail_helper "refused cleanup: child exited 0 [$output]"
	fi
	expect_contains "refusing" "$output" "refused cleanup"
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
	expect_root_removed "$report" second_root "idempotency"
}

test_resourcing_via_resurrect_helpers_keeps_one_root() {
	local report first_root
	reset_outer_dir
	report="$(run_child -- "$CHILD_RESOURCE_VIA_HELPERS" \
		"$RESURRECT_HELPER" 2>&1)"
	first_root="$(report_field first_root "$report")"
	if [ -z "$first_root" ]; then
		fail_helper "re-source: first activation reported no root [$report]"
		return
	fi
	expect_equal "$first_root" "$(report_field second_root "$report")" \
		"re-source: sandbox root"
	expect_root_removed "$report" second_root "re-source"
}

# The harness teardown (`rm -f ~/.tmux.conf`, `rm -rf ~/.tmux/`,
# `tmux kill-server`) and set_tmux_conf_helper must hit the sandbox,
# leaving a seeded outer login byte-identical.
test_harness_teardown_leaves_outer_login_intact() {
	local expected_dir="$OUTER_DIR/expected"
	local report
	reset_outer_dir
	mkdir -p "$OUTER_HOME/.tmux/resurrect" "$expected_dir"
	printf 'outer last pointer\n' > "$expected_dir/last"
	printf 'set -g outer-option on\n' > "$expected_dir/tmux.conf"
	cp "$expected_dir/last" "$OUTER_HOME/.tmux/resurrect/last"
	cp "$expected_dir/tmux.conf" "$OUTER_HOME/.tmux.conf"
	report="$(run_child -- "$CHILD_HARNESS_TEARDOWN" \
		"$HARNESS_HELPER" 2>&1)"
	expect_equal "sandbox-conf-line" \
		"$(report_field sandbox_tmux_conf "$report")" \
		"teardown: sandbox .tmux.conf written"
	if ! cmp -s "$expected_dir/last" "$OUTER_HOME/.tmux/resurrect/last"
	then
		fail_helper "teardown: outer .tmux/resurrect/last changed"
	fi
	if ! cmp -s "$expected_dir/tmux.conf" "$OUTER_HOME/.tmux.conf"; then
		fail_helper "teardown: outer .tmux.conf changed"
	fi
}

# Resolves the plugin's resurrect dir (scripts/helpers.sh) inside a
# sandboxed child and checks it lands under the root and ends with the
# expected suffix. $3 is the child's mode ("" or "drop-state-dir").
expect_plugin_dir_inside_sandbox() {
	local message="$1"
	local expected_suffix="$2"
	local mode="$3"
	local report root resurrect_dir
	reset_outer_dir
	report="$(run_child -- "$CHILD_PLUGIN_RESURRECT_DIR" \
		"$RESURRECT_HELPER" "$REPOSITORY_DIR" "$mode" 2>&1)"
	root="$(report_field root "$report")"
	resurrect_dir="$(report_field resurrect_dir "$report")"
	if [ -z "$root" ] || [ -z "$resurrect_dir" ]; then
		fail_helper "$message: incomplete child report [$report]"
		return
	fi
	expect_under_root "$resurrect_dir" "$root" "$message"
	case "$resurrect_dir" in
		*"$expected_suffix") ;;
		*) fail_helper "$message: [$resurrect_dir] not *$expected_suffix" ;;
	esac
}

test_plugin_resurrect_dir_resolves_inside_sandbox() {
	expect_plugin_dir_inside_sandbox "plugin dir" "/.tmux/resurrect" ""
}

# The original incident: with no ~/.tmux/resurrect the plugin falls back
# to $XDG_DATA_HOME/tmux/resurrect, which must also be the sandbox's.
test_plugin_xdg_fallback_dir_resolves_inside_sandbox() {
	expect_plugin_dir_inside_sandbox "plugin XDG fallback dir" \
		"/.local/share/tmux/resurrect" "drop-state-dir"
}

# True when a path is inside a temp location (for the TMPDIR values
# these cases use).
is_in_temp_location() {
	local path="$1"
	local tmpdir="$2"
	case "$path" in
		/tmp/*|/var/folders/*|"$tmpdir"/*) return 0 ;;
	esac
	return 1
}

# Runs cleanup_test_sandbox in a child with the sandbox root set to
# $2. The path $3 must survive and the child must print the refusal.
# Any further arguments are env(1) arguments for the child.
expect_cleanup_refuses_root() {
	local message="$1"
	local root="$2"
	local survivor="$3"
	shift 3
	local output
	output="$(run_child "$@" -- "$CHILD_CLEANUP_ROOT" "$root" 2>&1)"
	if [ ! -e "$survivor" ] && [ ! -L "$survivor" ]; then
		fail_helper "$message: removed $survivor"
	fi
	expect_contains "refusing" "$output" "$message"
}

# Cleanup pointed at a real directory outside every temp location must
# refuse and leave it in place. The keep-dir is created under the
# repository work tree because that is a real, writable directory that
# lies outside /tmp, /var/folders and every TMPDIR these cases use, so a
# cleanup that went back to trusting location (or a TMPDIR of "/")
# could not pass. In Docker it is the disposable /work tmpfs.
expect_cleanup_refuses_work_tree_dir() {
	local message="$1"
	shift
	local keep_dir
	if ! keep_dir="$(mktemp -d "$REPOSITORY_DIR/.sandbox-refuse.XXXXXX")"
	then
		fail_helper "$message: could not create a non-temp directory"
		return
	fi
	if is_in_temp_location "$keep_dir" "$OUTER_DIR/tmpdir"; then
		fail_helper "$message: precondition: $keep_dir is a temp path"
		rmdir "$keep_dir"
		return
	fi
	expect_cleanup_refuses_root "$message" "$keep_dir" "$keep_dir" "$@"
	# Empty by construction; rmdir cannot remove anything else.
	rmdir "$keep_dir" 2>/dev/null
}

# A directory named and marked exactly like a sandbox root, created in
# $OUTER_DIR (inside this file's own sandbox). Cases that pass
# RESURRECT_TEST_SANDBOX_BASE=$OUTER_DIR make the location check pass,
# so only the identity check under test can refuse it.
make_marked_root() {
	local root
	root="$(mktemp -d "$OUTER_DIR/tmux-resurrect-test.XXXXXX")" || return 1
	: > "$root/$SANDBOX_MARKER" || return 1
	printf '%s\n' "$root"
}

# Positive control for the identity cases below: with the base set to
# $OUTER_DIR, a marked root there IS removed, so their refusals are down
# to the one property each breaks.
test_cleanup_removes_marked_root_in_base() {
	local marked_root output
	reset_outer_dir
	if ! marked_root="$(make_marked_root)"; then
		fail_helper "marked root in base: could not create a root"
		return
	fi
	output="$(run_child "RESURRECT_TEST_SANDBOX_BASE=$OUTER_DIR" -- \
		"$CHILD_CLEANUP_ROOT" "$marked_root" 2>&1)"
	if [ -e "$marked_root" ]; then
		fail_helper "marked root in base: not removed [$output]"
	fi
}

test_cleanup_refuses_marked_root_outside_base() {
	local marked_root
	reset_outer_dir
	if ! marked_root="$(make_marked_root)"; then
		fail_helper "root outside base: could not create a root"
		return
	fi
	# The default base (/tmp) is not $OUTER_DIR.
	expect_cleanup_refuses_root "root outside base" \
		"$marked_root" "$marked_root/$SANDBOX_MARKER" \
		-u RESURRECT_TEST_SANDBOX_BASE
}

# The TMPDIR variants are regression guards: cleanup no longer consults
# TMPDIR at all, but an earlier allowlist did, and TMPDIR=/ collapsed it
# to `/*` and removed this very directory.
test_cleanup_refuses_non_temp_root() {
	reset_outer_dir
	mkdir -p "$OUTER_DIR/tmpdir"
	expect_cleanup_refuses_work_tree_dir "cleanup with TMPDIR set" \
		"TMPDIR=$OUTER_DIR/tmpdir"
}

test_cleanup_refuses_non_temp_root_with_tmpdir_unset() {
	reset_outer_dir
	expect_cleanup_refuses_work_tree_dir "cleanup with TMPDIR unset" \
		-u TMPDIR
}

test_cleanup_refuses_non_temp_root_with_tmpdir_root() {
	reset_outer_dir
	expect_cleanup_refuses_work_tree_dir "cleanup with TMPDIR=/" \
		"TMPDIR=/"
}

test_cleanup_refuses_dot_dot_root() {
	local marked_root dotted_root
	reset_outer_dir
	if ! marked_root="$(make_marked_root)"; then
		fail_helper "dot-dot root: could not create a marked root"
		return
	fi
	# Resolves to the marked root, but spells it with a `..` component.
	dotted_root="$OUTER_DIR/../${OUTER_DIR##*/}/${marked_root##*/}"
	if [ ! -f "$dotted_root/$SANDBOX_MARKER" ]; then
		fail_helper "dot-dot root: precondition: $dotted_root unresolved"
		return
	fi
	# The base is spelt the same way, so only the `..` check refuses.
	expect_cleanup_refuses_root "dot-dot root" \
		"$dotted_root" "$marked_root/$SANDBOX_MARKER" \
		"RESURRECT_TEST_SANDBOX_BASE=${dotted_root%/*}"
}

test_cleanup_refuses_unmarked_root() {
	local unmarked_root
	reset_outer_dir
	if ! unmarked_root="$(mktemp -d \
		"$OUTER_DIR/tmux-resurrect-test.XXXXXX")"; then
		fail_helper "unmarked root: could not create a directory"
		return
	fi
	expect_cleanup_refuses_root "unmarked root" \
		"$unmarked_root" "$unmarked_root" \
		"RESURRECT_TEST_SANDBOX_BASE=$OUTER_DIR"
}

test_cleanup_refuses_symlinked_root() {
	local marked_root link_root
	reset_outer_dir
	if ! marked_root="$(make_marked_root)"; then
		fail_helper "symlinked root: could not create a marked root"
		return
	fi
	link_root="$(mktemp -u "$OUTER_DIR/tmux-resurrect-test.XXXXXX")"
	if ! ln -s "$marked_root" "$link_root"; then
		fail_helper "symlinked root: could not create $link_root"
		return
	fi
	expect_cleanup_refuses_root "symlinked root" "$link_root" "$link_root" \
		"RESURRECT_TEST_SANDBOX_BASE=$OUTER_DIR"
	if [ ! -f "$marked_root/$SANDBOX_MARKER" ]; then
		fail_helper "symlinked root: link target was emptied"
	fi
}

# Prints the number of the first line of $2 matching the extended regex
# $1; prints nothing when no line matches.
first_matching_line() {
	local pattern="$1"
	local file="$2"
	local match
	match="$(\grep -En -m 1 "$pattern" "$file")" || return 0
	printf '%s\n' "${match%%:*}"
}

# Static guard: a test file activates the sandbox when it calls
# activate_test_sandbox or sources resurrect_helpers.sh (which does),
# before its first top-level `run_tests` or `main` call (where the
# harness teardown runs). Commented-out lines do not count.
file_activates_sandbox() {
	local file="$1"
	local activation='activate_test_sandbox([[:space:]]|$)'
	local helpers_source='source[[:space:]].*helpers/resurrect_helpers\.sh'
	local activation_line run_line
	activation_line="$(first_matching_line \
		"^[[:space:]]*(${activation}|${helpers_source})" "$file")"
	[ -n "$activation_line" ] || return 1
	run_line="$(first_matching_line \
		'^(run_tests|main)([[:space:]]|$)' "$file")"
	[ -z "$run_line" ] && return 0
	[ "$activation_line" -lt "$run_line" ]
}

is_sandbox_exempt() {
	local file_name="$1"
	local exempt
	for exempt in "${SANDBOX_EXEMPT_TEST_FILES[@]}"; do
		[ "$file_name" = "$exempt" ] && return 0
	done
	return 1
}

expect_test_file_sandboxed() {
	local file="$1"
	local file_name="${file##*/}"
	is_sandbox_exempt "$file_name" && return 0
	if ! file_activates_sandbox "$file"; then
		fail_helper "static: $file_name does not activate the sandbox"
	fi
}

# Every test file must activate the sandbox, except the named exemptions.
# Same glob as the Docker entrypoint's default (tests/test*.sh).
test_every_test_file_activates_sandbox() {
	local file
	for file in "$CURRENT_DIR"/test*.sh; do
		expect_test_file_sandboxed "$file"
	done
}

expect_static_guard_verdict() {
	local expected="$1"
	local label="$2"
	local file="$3"
	local verdict=rejects
	file_activates_sandbox "$file" && verdict=accepts
	expect_equal "$expected" "$verdict" "static guard: $label"
}

# The static guard itself must flag a file that only sources the
# harness, one that activates only after run_tests (where teardown has
# already run), and must not be fooled by a commented-out activation.
test_static_guard_flags_missing_activation() {
	local commented="$OUTER_DIR/test_commented.sh"
	local late="$OUTER_DIR/test_late.sh"
	local complying="$OUTER_DIR/test_complying.sh"
	reset_outer_dir
	# Literal file content: nothing here is meant to expand.
	# shellcheck disable=SC2016
	printf '%s\n' \
		'source "$CURRENT_DIR/helpers/helpers.sh"' \
		'# activate_test_sandbox' \
		'run_tests' > "$commented"
	# shellcheck disable=SC2016
	printf '%s\n' \
		'source "$CURRENT_DIR/helpers/helpers.sh"' \
		'run_tests' \
		'activate_test_sandbox || exit 1' > "$late"
	# shellcheck disable=SC2016
	printf '%s\n' \
		'source "$CURRENT_DIR/helpers/helpers.sh"' \
		'activate_test_sandbox || exit 1' \
		'main() {' \
		'	run_tests' \
		'}' \
		'main' > "$complying"
	expect_static_guard_verdict rejects "commented-out activation" \
		"$commented"
	expect_static_guard_verdict rejects "activation after run_tests" \
		"$late"
	expect_static_guard_verdict accepts "activation before main" \
		"$complying"
}

main() {
	run_tests
}
main
