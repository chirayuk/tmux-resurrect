#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"
source "$CURRENT_DIR/spinner_helpers.sh"
source "$CURRENT_DIR/snapshot_format.sh"

SCRIPT_OUTPUT="$1"

_save_command_strategy_file() {
	local save_command_strategy strategy_file default_strategy_file
	save_command_strategy="$(get_tmux_option \
		"$save_command_strategy_option" \
		"$default_save_command_strategy")"
	strategy_file="$CURRENT_DIR/../save_command_strategies/"
	strategy_file="${strategy_file}${save_command_strategy}.sh"
	default_strategy_file="$CURRENT_DIR/../save_command_strategies/"
	default_strategy_file+="${default_save_command_strategy}.sh"
	if [ -e "$strategy_file" ]; then
		printf '%s\n' "$strategy_file"
	else
		printf '%s\n' "$default_strategy_file"
	fi
}

pane_full_command() {
	local pane_pid="$1"
	local strategy_file
	strategy_file="$(_save_command_strategy_file)"
	"$strategy_file" "$pane_pid"
}

number_nonempty_lines_on_screen() {
	local pane_id="$1"
	tmux capture-pane -pJ -t "$pane_id" |
		sed '/^$/d' |
		wc -l |
		sed 's/ //g'
}

pane_has_any_content() {
	local pane_id="$1"
	local history_size cursor_y
	history_size="$(tmux display -p -t "$pane_id" -F "#{history_size}")"
	cursor_y="$(tmux display -p -t "$pane_id" -F "#{cursor_y}")"
	[ "$history_size" -gt 0 ] ||
		[ "$cursor_y" -gt 0 ] ||
		[ "$(number_nonempty_lines_on_screen "$pane_id")" -gt 1 ]
}

capture_pane_contents() {
	local pane_id="$1"
	local history_size="$2"
	local pane_contents_area="$3"
	local start_line="-$history_size"
	if ! pane_has_any_content "$pane_id"; then
		return 0
	fi
	if [ "$pane_contents_area" = "visible" ]; then
		start_line="0"
	fi
	printf '%s\n' "$(tmux capture-pane -epJ -S "$start_line" \
		-t "$pane_id")" > "$(pane_contents_file "save" "$pane_id")"
}

get_active_window_index() {
	local session_name="$1"
	tmux list-windows -t "$session_name" \
		-F "#{window_flags} #{window_index}" |
		awk '$1 ~ /\*/ { print $2; }'
}

get_alternate_window_index() {
	local session_name="$1"
	tmux list-windows -t "$session_name" \
		-F "#{window_flags} #{window_index}" |
		awk '$1 ~ /-/ { print $2; }'
}

capture_output_file() {
	local marked
	marked="$(cat "$_SNAPSHOT_CAPTURE_FILE"; printf '\034')"
	marked="${marked%?}"
	SNAPSHOT_CAPTURED_VALUE="${marked%$'\n'}"
}

capture_tmux_value() {
	local target="$1"
	local format="$2"
	if ! tmux display-message -p -t "$target" -F "$format" \
		> "$_SNAPSHOT_CAPTURE_FILE"; then
		return 1
	fi
	capture_output_file
}

capture_tmux_global_value() {
	local format="$1"
	if ! tmux display-message -p -F "$format" \
		> "$_SNAPSHOT_CAPTURE_FILE"; then
		return 1
	fi
	capture_output_file
}

capture_process_value() {
	local pane_pid="$1"
	if ! pane_full_command "$pane_pid" > "$_SNAPSHOT_CAPTURE_FILE"; then
		return 1
	fi
	capture_output_file
}

capture_field() {
	local target="$1"
	local format="$2"
	capture_tmux_value "$target" "$format" || return 1
	SNAPSHOT_FIELD_VALUE="$SNAPSHOT_CAPTURED_VALUE"
}

session_is_grouped() {
	local session_name="$1"
	local index
	for ((index = 0; index < ${#_SAVE_GROUPED_NAMES[@]}; index++)); do
		if [ "${_SAVE_GROUPED_NAMES[index]}" = "$session_name" ]; then
			return 0
		fi
	done
	return 1
}

find_original_group_session() {
	local group_id="$1"
	local index
	for ((index = 0; index < ${#_SAVE_ORIGINAL_GROUP_IDS[@]}; index++)); do
		if [ "${_SAVE_ORIGINAL_GROUP_IDS[index]}" = "$group_id" ]; then
			SNAPSHOT_ORIGINAL_GROUP_NAME="${_SAVE_ORIGINAL_GROUP_NAMES[index]}"
			return 0
		fi
	done
	return 1
}

record_grouped_session() {
	local session_id="$1"
	local grouped group_id session_name alternate active
	capture_field "$session_id" "#{session_grouped}" || return 1
	grouped="$SNAPSHOT_FIELD_VALUE"
	[ "$grouped" = "1" ] || return 0
	capture_field "$session_id" "#{session_group}" || return 1
	group_id="$SNAPSHOT_FIELD_VALUE"
	capture_field "$session_id" "#{session_name}" || return 1
	session_name="$SNAPSHOT_FIELD_VALUE"
	_SAVE_GROUPED_NAMES+=("$session_name")
	if ! find_original_group_session "$group_id"; then
		_SAVE_ORIGINAL_GROUP_IDS+=("$group_id")
		_SAVE_ORIGINAL_GROUP_NAMES+=("$session_name")
		return 0
	fi
	alternate="$(get_alternate_window_index "$session_name")"
	active="$(get_active_window_index "$session_name")"
	_SAVE_GROUPED_SESSION_NAMES+=("$session_name")
	_SAVE_GROUPED_ORIGINAL_NAMES+=("$SNAPSHOT_ORIGINAL_GROUP_NAME")
	_SAVE_GROUPED_ALTERNATE_WINDOWS+=("$alternate")
	_SAVE_GROUPED_ACTIVE_WINDOWS+=("$active")
}

prepare_grouped_sessions() {
	local session_id
	_SAVE_GROUPED_NAMES=()
	_SAVE_ORIGINAL_GROUP_IDS=()
	_SAVE_ORIGINAL_GROUP_NAMES=()
	_SAVE_GROUPED_SESSION_NAMES=()
	_SAVE_GROUPED_ORIGINAL_NAMES=()
	_SAVE_GROUPED_ALTERNATE_WINDOWS=()
	_SAVE_GROUPED_ACTIVE_WINDOWS=()
	while IFS= read -r session_id; do
		[ -n "$session_id" ] || continue
		record_grouped_session "$session_id" || return 1
	done < <(tmux list-sessions -F '#{session_id}' | sort)
}

write_grouped_sessions() {
	local index
	for ((index = 0;
		index < ${#_SAVE_GROUPED_SESSION_NAMES[@]}; index++)); do
		snapshot_write_grouped_session \
			"${_SAVE_GROUPED_SESSION_NAMES[index]}" \
			"${_SAVE_GROUPED_ORIGINAL_NAMES[index]}" \
			"${_SAVE_GROUPED_ALTERNATE_WINDOWS[index]}" \
			"${_SAVE_GROUPED_ACTIVE_WINDOWS[index]}"
	done
}

write_pane() {
	local pane_id="$1"
	local session_name window_index window_active window_flags
	local pane_index pane_title pane_dir pane_active pane_command
	local pane_pid pane_full
	capture_field "$pane_id" "#{session_name}" || return 1
	session_name="$SNAPSHOT_FIELD_VALUE"
	if session_is_grouped "$session_name"; then
		return 0
	fi
	capture_field "$pane_id" "#{window_index}" || return 1
	window_index="$SNAPSHOT_FIELD_VALUE"
	capture_field "$pane_id" "#{window_active}" || return 1
	window_active="$SNAPSHOT_FIELD_VALUE"
	capture_field "$pane_id" "#{window_flags}" || return 1
	window_flags="$SNAPSHOT_FIELD_VALUE"
	capture_field "$pane_id" "#{pane_index}" || return 1
	pane_index="$SNAPSHOT_FIELD_VALUE"
	capture_field "$pane_id" "#{pane_title}" || return 1
	pane_title="$SNAPSHOT_FIELD_VALUE"
	capture_field "$pane_id" "#{pane_current_path}" || return 1
	pane_dir="$SNAPSHOT_FIELD_VALUE"
	capture_field "$pane_id" "#{pane_active}" || return 1
	pane_active="$SNAPSHOT_FIELD_VALUE"
	capture_field "$pane_id" "#{pane_current_command}" || return 1
	pane_command="$SNAPSHOT_FIELD_VALUE"
	capture_field "$pane_id" "#{pane_pid}" || return 1
	pane_pid="$SNAPSHOT_FIELD_VALUE"
	capture_process_value "$pane_pid" || return 1
	pane_full="$SNAPSHOT_CAPTURED_VALUE"
	snapshot_write_pane \
		"$session_name" "$window_index" "$window_active" \
		"$window_flags" "$pane_index" "$pane_title" "$pane_dir" \
		"$pane_active" "$pane_command" "$pane_full"
}

write_panes() {
	local pane_id
	if ! tmux list-panes -a -F '#{pane_id}' > "$_SNAPSHOT_ID_FILE"; then
		return 1
	fi
	while IFS= read -r pane_id; do
		[ -n "$pane_id" ] || continue
		write_pane "$pane_id" || return 1
	done < "$_SNAPSHOT_ID_FILE"
}

write_window() {
	local window_id="$1"
	local session_name window_index window_name window_active
	local window_flags window_layout automatic_rename
	capture_field "$window_id" "#{session_name}" || return 1
	session_name="$SNAPSHOT_FIELD_VALUE"
	if session_is_grouped "$session_name"; then
		return 0
	fi
	capture_field "$window_id" "#{window_index}" || return 1
	window_index="$SNAPSHOT_FIELD_VALUE"
	capture_field "$window_id" "#{window_name}" || return 1
	window_name="$SNAPSHOT_FIELD_VALUE"
	capture_field "$window_id" "#{window_active}" || return 1
	window_active="$SNAPSHOT_FIELD_VALUE"
	capture_field "$window_id" "#{window_flags}" || return 1
	window_flags="$SNAPSHOT_FIELD_VALUE"
	capture_field "$window_id" "#{window_layout}" || return 1
	window_layout="$SNAPSHOT_FIELD_VALUE"
	automatic_rename="$(tmux show-window-options -vt "$window_id" \
		automatic-rename)"
	snapshot_write_window \
		"$session_name" "$window_index" "$window_name" \
		"$window_active" "$window_flags" "$window_layout" \
		"$automatic_rename"
}

write_windows() {
	local window_id
	if ! tmux list-windows -a -F '#{window_id}' > "$_SNAPSHOT_ID_FILE"; then
		return 1
	fi
	while IFS= read -r window_id; do
		[ -n "$window_id" ] || continue
		write_window "$window_id" || return 1
	done < "$_SNAPSHOT_ID_FILE"
}

write_state() {
	local session_name last_session_name first_pane
	capture_tmux_global_value "#{client_session}" || return 1
	session_name="$SNAPSHOT_CAPTURED_VALUE"
	if [ -z "$session_name" ]; then
		first_pane="$(tmux list-panes -a -F '#{pane_id}' | head -n 1)"
		[ -n "$first_pane" ] || return 1
		capture_field "$first_pane" "#{session_name}" || return 1
		session_name="$SNAPSHOT_FIELD_VALUE"
	fi
	capture_tmux_global_value "#{client_last_session}" || return 1
	last_session_name="$SNAPSHOT_CAPTURED_VALUE"
	snapshot_write_state "$session_name" "$last_session_name"
}

write_snapshot() {
	prepare_grouped_sessions || return 1
	snapshot_write_header
	write_grouped_sessions || return 1
	write_panes || return 1
	write_windows || return 1
	write_state
}

dump_pane_contents() {
	local pane_contents_area pane_id history_size
	pane_contents_area="$(get_tmux_option \
		"$pane_contents_area_option" "$default_pane_contents_area")"
	if ! tmux list-panes -a -F '#{pane_id}' > "$_SNAPSHOT_ID_FILE"; then
		return 1
	fi
	while IFS= read -r pane_id; do
		[ -n "$pane_id" ] || continue
		capture_field "$pane_id" "#{history_size}" || return 1
		history_size="$SNAPSHOT_FIELD_VALUE"
		capture_pane_contents "$pane_id" "$history_size" \
			"$pane_contents_area" || return 1
	done < "$_SNAPSHOT_ID_FILE"
}

publish_pane_contents() {
	local archive_file archive_temp
	archive_file="$(pane_contents_archive_file)"
	archive_temp="${archive_file}.tmp.$$"
	mkdir -p "$(pane_contents_dir "save")"
	dump_pane_contents || return 1
	if ! (set -o pipefail
		tar cf - -C "$(resurrect_dir)/save/" ./pane_contents/ |
			gzip > "$archive_temp"); then
		rm -f "$archive_temp"
		return 1
	fi
	mv -f "$archive_temp" "$archive_file" || return 1
	sync
	rm -f "$(pane_contents_dir "save")"/*
}

remove_old_backups() {
	local delete_after
	local -a files
	delete_after="$(get_tmux_option \
		"$delete_backup_after_option" "$default_delete_backup_after")"
	# shellcheck disable=SC2207
	files=($(ls -t "$(resurrect_dir)"/${RESURRECT_FILE_PREFIX}_*."${RESURRECT_FILE_EXTENSION}" 2>/dev/null | tail -n +6))
	[[ ${#files[@]} -eq 0 ]] ||
		find "${files[@]}" -type f -mtime "+${delete_after}" \
			-exec rm -v "{}" \; >/dev/null
}

save_all() {
	local resurrect_file last_file candidate temp_dir
	resurrect_file="$(resurrect_file_path)"
	last_file="$(last_resurrect_file)"
	candidate="${resurrect_file}.tmp.$$"
	temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/resurrect-save.XXXXXX")"
	_SNAPSHOT_CAPTURE_FILE="$temp_dir/capture"
	_SNAPSHOT_ID_FILE="$temp_dir/ids"
	mkdir -p "$(resurrect_dir)"
	if ! write_snapshot > "$candidate"; then
		rm -f "$candidate"
		rm -rf "$temp_dir"
		return 1
	fi
	execute_hook "post-save-layout" "$candidate"
	if ! snapshot_validate_file "$candidate"; then
		rm -f "$candidate"
		rm -rf "$temp_dir"
		return 1
	fi
	if capture_pane_contents_option_on; then
		publish_pane_contents || return 1
	fi
	if files_differ "$candidate" "$last_file"; then
		snapshot_publish_file "$candidate" "$resurrect_file" \
			"$last_file" || return 1
	else
		rm -f "$candidate"
	fi
	rm -rf "$temp_dir"
	remove_old_backups
	execute_hook "post-save-all"
}

show_output() {
	[ "$SCRIPT_OUTPUT" != "quiet" ]
}

main() {
	if ! supported_tmux_version_ok; then
		return 1
	fi
	if show_output; then
		start_spinner "Saving..." "Tmux environment saved!"
	fi
	if ! save_all; then
		if show_output; then
			stop_spinner
			display_message "Tmux save failed; previous snapshot preserved"
		fi
		return 1
	fi
	if show_output; then
		stop_spinner
		display_message "Tmux environment saved!"
	fi
}

main "$@"
