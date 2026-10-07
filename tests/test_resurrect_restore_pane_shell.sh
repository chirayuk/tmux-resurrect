#!/usr/bin/env bash

# Checks the shell a pane restored WITH pane contents ends up running.
#
# Each scenario starts its own tmux server on a dedicated socket
# (never the default one), writes a one-pane resurrect file plus a
# pane contents archive, runs scripts/restore.sh against that server
# and then probes the restored pane by typing a command into it.

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPOSITORY_DIR="$( cd "$CURRENT_DIR/.." && pwd )"

source "$CURRENT_DIR/helpers/helpers.sh"

# Every scenario gets a fresh socket name: kill-server returns before
# the server has exited, so reusing a name races the dying server.
SOCKET_PREFIX="resurrect-pane-shell-test-$$"
SERVER_COUNT=0
SOCKET_NAME=""
TEST_DIR="$(mktemp -d)"
RESURRECT_DIR="$TEST_DIR/resurrect"
PROBE_DIR="$TEST_DIR/probes"
CONTENTS_MARKER="restored-pane-contents-marker"
MARKER_DEFAULT_COMMAND="env RESURRECT_TEST_MARKER=custom /bin/bash --noprofile --norc"

# Login-shell tests, one per supported shell.
ZSH_LOGIN_TEST='[[ -o login ]]'
BASH_LOGIN_TEST='shopt -q login_shell'

isolated_tmux() {
	tmux -L "$SOCKET_NAME" "$@"
}

stop_test_server() {
	[ -n "$SOCKET_NAME" ] || return 0
	isolated_tmux kill-server >/dev/null 2>&1
}

cleanup() {
	stop_test_server
	rm -rf "${TEST_DIR:?}"
}
trap cleanup EXIT

# zsh startup files live in a private ZDOTDIR: an empty .zshrc keeps
# zsh-newuser-install quiet and skip_global_compinit avoids Ubuntu's
# compinit prompt about the world-writable test HOME.
write_zsh_startup_files() {
	mkdir -p "$TEST_DIR/zdotdir"
	echo 'skip_global_compinit=1' > "$TEST_DIR/zdotdir/.zshenv"
	: > "$TEST_DIR/zdotdir/.zshrc"
}

start_test_server() {
	local default_shell="$1"
	local default_command="$2"
	stop_test_server
	SERVER_COUNT=$((SERVER_COUNT + 1))
	SOCKET_NAME="${SOCKET_PREFIX}-${SERVER_COUNT}"
	rm -rf "$RESURRECT_DIR" "$PROBE_DIR"
	mkdir -p "$RESURRECT_DIR" "$PROBE_DIR"
	ZDOTDIR="$TEST_DIR/zdotdir" isolated_tmux -f /dev/null \
		new-session -d -s base -x 200 -y 50
	isolated_tmux set-option -g default-shell "$default_shell"
	isolated_tmux set-option -g default-command "$default_command"
	isolated_tmux set-option -g @resurrect-capture-pane-contents on
	isolated_tmux set-option -g @resurrect-dir "$RESURRECT_DIR"
}

# Writes a one-pane resurrect file and its pane contents archive, in
# the formats scripts/save.sh produces.
write_saved_session() {
	local session_name="$1"
	local shell_name="$2"
	local t=$'\t'
	local contents_dir="$RESURRECT_DIR/save/pane_contents"
	mkdir -p "$contents_dir"
	echo "$CONTENTS_MARKER" > "$contents_dir/pane-${session_name}:0.0"
	tar cf - -C "$RESURRECT_DIR/save/" ./pane_contents/ |
		gzip > "$RESURRECT_DIR/pane_contents.tar.gz"
	printf '%s\n' \
		"pane${t}${session_name}${t}0${t}1${t}:*${t}0${t}:${t}:${TEST_DIR}${t}1${t}${shell_name}${t}:" \
		> "$RESURRECT_DIR/saved.txt"
	ln -sf saved.txt "$RESURRECT_DIR/last"
}

run_restore() {
	local socket_path server_pid
	socket_path="$(isolated_tmux display-message -p '#{socket_path}')"
	server_pid="$(isolated_tmux display-message -p '#{pid}')"
	TMUX="${socket_path},${server_pid},0" \
		"$REPOSITORY_DIR/scripts/restore.sh" >/dev/null 2>&1
}

restored_pane_id() {
	local session_name="$1"
	isolated_tmux display-message -p -t "=${session_name}:0.0" '#{pane_id}' \
		2>/dev/null
}

wait_for_file() {
	local file="$1"
	local _
	for _ in $(seq 1 100); do
		[ -f "$file" ] && return 0
		sleep 0.1
	done
	return 1
}

# Types a probe into a pane; it records whether the shell is a login
# shell, its SHLVL and RESURRECT_TEST_MARKER. Prints that record.
probe_pane() {
	local pane_id="$1"
	local login_test="$2"
	local probe_file="$PROBE_DIR/probe-${pane_id#%}"
	local quoted_file
	printf -v quoted_file '%q' "$probe_file"
	# Expanded by the probed shell, not here.
	# shellcheck disable=SC2016
	local record='login=$l shlvl=$SHLVL marker=${RESURRECT_TEST_MARKER:-none}'
	isolated_tmux send-keys -t "$pane_id" \
		"if $login_test; then l=y; else l=n; fi; echo \"$record\" > $quoted_file.tmp && mv $quoted_file.tmp $quoted_file" \
		Enter
	if ! wait_for_file "$probe_file"; then
		echo "no probe output from pane $pane_id"
		return
	fi
	cat "$probe_file"
}

pane_shows_contents() {
	local pane_id="$1"
	isolated_tmux capture-pane -p -t "$pane_id" | \grep -qF "$CONTENTS_MARKER"
}

expect_equal() {
	local expected="$1"
	local actual="$2"
	local message="$3"
	if [ "$expected" != "$actual" ]; then
		fail_helper "$message: expected [$expected], got [$actual]"
	fi
}

# Restores a pane with contents and checks it is the default-shell
# started as a login shell, at the same SHLVL as an ordinary pane.
check_restored_pane_is_login_shell() {
	local default_shell="$1"
	local login_test="$2"
	local session_name="$3"
	local restored_pane ordinary_pane restored ordinary
	start_test_server "$default_shell" ""
	write_saved_session "$session_name" "$(basename "$default_shell")"
	run_restore
	restored_pane="$(restored_pane_id "$session_name")"
	if [ -z "$restored_pane" ]; then
		fail_helper "$default_shell: pane of [$session_name] not restored"
		return
	fi
	ordinary_pane="$(isolated_tmux new-window -d -P -F '#{pane_id}' \
		-t "=${session_name}:")"
	restored="$(probe_pane "$restored_pane" "$login_test")"
	ordinary="$(probe_pane "$ordinary_pane" "$login_test")"
	if ! pane_shows_contents "$restored_pane"; then
		fail_helper "$default_shell: pane contents not shown in [$session_name]"
	fi
	expect_equal "login=y" "${ordinary%% *}" \
		"$default_shell: ordinary pane login state"
	expect_equal "$ordinary" "$restored" \
		"$default_shell: restored pane vs ordinary pane"
}

test_zsh_pane_restored_with_contents_is_login_shell() {
	check_restored_pane_is_login_shell \
		/bin/zsh "$ZSH_LOGIN_TEST" "zsh-session"
}

test_bash_pane_restored_with_contents_is_login_shell() {
	check_restored_pane_is_login_shell \
		/bin/bash "$BASH_LOGIN_TEST" "bash-session"
}

test_session_name_with_quote_and_space_restores_contents() {
	check_restored_pane_is_login_shell \
		/bin/bash "$BASH_LOGIN_TEST" "it's a test"
}

test_non_empty_default_command_is_passed_through() {
	local session_name="command-session"
	local restored_pane restored
	start_test_server /bin/zsh "$MARKER_DEFAULT_COMMAND"
	write_saved_session "$session_name" "bash"
	run_restore
	restored_pane="$(restored_pane_id "$session_name")"
	if [ -z "$restored_pane" ]; then
		fail_helper "default-command: pane not restored"
		return
	fi
	restored="$(probe_pane "$restored_pane" "$BASH_LOGIN_TEST")"
	if ! pane_shows_contents "$restored_pane"; then
		fail_helper "default-command: pane contents not shown"
	fi
	# The marker proves default-command ran; login=n proves nothing
	# (such as -l) was added to it.
	expect_equal "login=n" "${restored%% *}" \
		"default-command: login state"
	expect_equal "marker=custom" "${restored##* }" \
		"default-command: marker"
}

main() {
	write_zsh_startup_files
	run_tests
}
main
