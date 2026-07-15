#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"
source "$CURRENT_DIR/process_restore_helpers.sh"
source "$CURRENT_DIR/spinner_helpers.sh"
source "$CURRENT_DIR/snapshot_format.sh"

RESTORING_FROM_SCRATCH="false"
RESTORE_PANE_CONTENTS="false"
RESTORED_SESSION_0="false"

snapshot_arrays_reset() {
	_RESTORE_PANE_SESSIONS=()
	_RESTORE_PANE_WINDOWS=()
	_RESTORE_PANE_WINDOW_ACTIVE=()
	_RESTORE_PANE_WINDOW_FLAGS=()
	_RESTORE_PANE_INDEXES=()
	_RESTORE_PANE_TITLES=()
	_RESTORE_PANE_DIRS=()
	_RESTORE_PANE_ACTIVE=()
	_RESTORE_PANE_COMMANDS=()
	_RESTORE_PANE_FULL_COMMANDS=()
	_RESTORE_WINDOW_SESSIONS=()
	_RESTORE_WINDOW_INDEXES=()
	_RESTORE_WINDOW_NAMES=()
	_RESTORE_WINDOW_ACTIVE=()
	_RESTORE_WINDOW_FLAGS=()
	_RESTORE_WINDOW_LAYOUTS=()
	_RESTORE_WINDOW_AUTOMATIC_RENAME=()
	_RESTORE_STATE_SESSIONS=()
	_RESTORE_STATE_LAST_SESSIONS=()
	_RESTORE_GROUP_SESSIONS=()
	_RESTORE_GROUP_ORIGINALS=()
	_RESTORE_GROUP_ALTERNATE_WINDOWS=()
	_RESTORE_GROUP_ACTIVE_WINDOWS=()
	_EXISTING_PANE_SESSIONS=()
	_EXISTING_PANE_WINDOWS=()
	_EXISTING_PANE_INDEXES=()
}

load_normalized_record() {
	case "$SNAPSHOT_RECORD_TYPE" in
		pane)
			_RESTORE_PANE_SESSIONS+=("$SNAPSHOT_SESSION_NAME")
			_RESTORE_PANE_WINDOWS+=("$SNAPSHOT_WINDOW_INDEX")
			_RESTORE_PANE_WINDOW_ACTIVE+=("$SNAPSHOT_WINDOW_ACTIVE")
			_RESTORE_PANE_WINDOW_FLAGS+=("$SNAPSHOT_WINDOW_FLAGS")
			_RESTORE_PANE_INDEXES+=("$SNAPSHOT_PANE_INDEX")
			_RESTORE_PANE_TITLES+=("$SNAPSHOT_PANE_TITLE")
			_RESTORE_PANE_DIRS+=("$SNAPSHOT_PANE_DIR")
			_RESTORE_PANE_ACTIVE+=("$SNAPSHOT_PANE_ACTIVE")
			_RESTORE_PANE_COMMANDS+=("$SNAPSHOT_PANE_COMMAND")
			_RESTORE_PANE_FULL_COMMANDS+=(
				"$SNAPSHOT_PANE_FULL_COMMAND"
			)
			;;
		window)
			_RESTORE_WINDOW_SESSIONS+=("$SNAPSHOT_SESSION_NAME")
			_RESTORE_WINDOW_INDEXES+=("$SNAPSHOT_WINDOW_INDEX")
			_RESTORE_WINDOW_NAMES+=("$SNAPSHOT_WINDOW_NAME")
			_RESTORE_WINDOW_ACTIVE+=("$SNAPSHOT_WINDOW_ACTIVE")
			_RESTORE_WINDOW_FLAGS+=("$SNAPSHOT_WINDOW_FLAGS")
			_RESTORE_WINDOW_LAYOUTS+=("$SNAPSHOT_WINDOW_LAYOUT")
			_RESTORE_WINDOW_AUTOMATIC_RENAME+=(
				"$SNAPSHOT_AUTOMATIC_RENAME"
			)
			;;
		state)
			_RESTORE_STATE_SESSIONS+=("$SNAPSHOT_SESSION_NAME")
			_RESTORE_STATE_LAST_SESSIONS+=(
				"$SNAPSHOT_LAST_SESSION_NAME"
			)
			;;
		grouped_session)
			_RESTORE_GROUP_SESSIONS+=("$SNAPSHOT_SESSION_NAME")
			_RESTORE_GROUP_ORIGINALS+=(
				"$SNAPSHOT_ORIGINAL_SESSION_NAME"
			)
			_RESTORE_GROUP_ALTERNATE_WINDOWS+=(
				"$SNAPSHOT_ALTERNATE_WINDOW_INDEX"
			)
			_RESTORE_GROUP_ACTIVE_WINDOWS+=(
				"$SNAPSHOT_ACTIVE_WINDOW_INDEX"
			)
			;;
		*)
			snapshot_error 0 \
				"internal unsupported record [$SNAPSHOT_RECORD_TYPE]"
			return 1
			;;
	esac
}

check_saved_session_exists() {
	local resurrect_file
	resurrect_file="$(last_resurrect_file)"
	if [ ! -f "$resurrect_file" ]; then
		display_message "Tmux resurrect file not found!"
		return 1
	fi
}

snapshot_is_v2() {
	local file="$1"
	local first_line
	IFS= read -r first_line < "$file" || return 1
	[ "$first_line" = \
		"${SNAPSHOT_FORMAT_NAME}${SNAPSHOT_RECORD_SEPARATOR}${SNAPSHOT_FORMAT_VERSION}" ]
}

normalize_restore_dir() {
	local dir="$1"
	case "$dir" in
		"~") SNAPSHOT_NORMALIZED_DIR="$HOME" ;;
		"~/"*) SNAPSHOT_NORMALIZED_DIR="$HOME/${dir#~/}" ;;
		*) SNAPSHOT_NORMALIZED_DIR="$dir" ;;
	esac
}

preflight_restore_dirs() {
	local index dir
	for ((index = 0; index < ${#_RESTORE_PANE_DIRS[@]}; index++)); do
		dir="${_RESTORE_PANE_DIRS[index]}"
		if [ -z "$dir" ]; then
			snapshot_error 0 \
				"pane ${_RESTORE_PANE_SESSIONS[index]}:"\
"${_RESTORE_PANE_WINDOWS[index]}.${_RESTORE_PANE_INDEXES[index]} "\
"has an empty directory"
			return 1
		fi
		normalize_restore_dir "$dir"
		if [ ! -d "$SNAPSHOT_NORMALIZED_DIR" ]; then
			snapshot_error 0 \
				"pane ${_RESTORE_PANE_SESSIONS[index]}:"\
"${_RESTORE_PANE_WINDOWS[index]}.${_RESTORE_PANE_INDEXES[index]} "\
"directory does not exist: [$SNAPSHOT_NORMALIZED_DIR]"
			return 1
		fi
		_RESTORE_PANE_DIRS[index]="$SNAPSHOT_NORMALIZED_DIR"
	done
}

prepare_restore_snapshot() {
	local source_file normalized_file warnings_file
	source_file="$(last_resurrect_file)"
	_RESTORE_TEMP_DIR="$(mktemp -d \
		"${TMPDIR:-/tmp}/resurrect-restore.XXXXXX")"
	normalized_file="$_RESTORE_TEMP_DIR/normalized.txt"
	warnings_file="$_RESTORE_TEMP_DIR/warnings.txt"
	if snapshot_is_v2 "$source_file"; then
		snapshot_validate_file "$source_file" || return 1
		_RESTORE_NORMALIZED_FILE="$source_file"
	else
		if ! snapshot_import_legacy \
			"$source_file" "$normalized_file" "$warnings_file"; then
			display_message \
				"Legacy snapshot is corrupt; run audit_snapshot.sh"
			return 1
		fi
		_RESTORE_NORMALIZED_FILE="$normalized_file"
	fi
	snapshot_arrays_reset
	snapshot_parse_file "$_RESTORE_NORMALIZED_FILE" \
		load_normalized_record || return 1
	preflight_restore_dirs
}

cleanup_restore_temp() {
	if [ -n "${_RESTORE_TEMP_DIR:-}" ]; then
		rm -rf "$_RESTORE_TEMP_DIR"
	fi
}

pane_exists() {
	local session_name="$1"
	local window_number="$2"
	local pane_index="$3"
	tmux list-panes -t "${session_name}:${window_number}" \
		-F "#{pane_index}" 2>/dev/null |
		grep -q "^${pane_index}$"
}

register_existing_pane() {
	_EXISTING_PANE_SESSIONS+=("$1")
	_EXISTING_PANE_WINDOWS+=("$2")
	_EXISTING_PANE_INDEXES+=("$3")
}

is_pane_registered_as_existing() {
	local session_name="$1"
	local window_number="$2"
	local pane_index="$3"
	local index
	for ((index = 0;
		index < ${#_EXISTING_PANE_SESSIONS[@]}; index++)); do
		if [ "${_EXISTING_PANE_SESSIONS[index]}" = "$session_name" ] &&
			[ "${_EXISTING_PANE_WINDOWS[index]}" = "$window_number" ] &&
			[ "${_EXISTING_PANE_INDEXES[index]}" = "$pane_index" ]; then
			return 0
		fi
	done
	return 1
}

is_restoring_from_scratch() {
	[ "$RESTORING_FROM_SCRATCH" = "true" ]
}

is_restoring_pane_contents() {
	[ "$RESTORE_PANE_CONTENTS" = "true" ]
}

has_restored_session_0() {
	[ "$RESTORED_SESSION_0" = "true" ]
}

window_exists() {
	local session_name="$1"
	local window_number="$2"
	tmux list-windows -t "$session_name" -F "#{window_index}" \
		2>/dev/null | grep -q "^${window_number}$"
}

session_exists() {
	tmux has-session -t "$1" 2>/dev/null
}

first_window_num() {
	tmux show -gv base-index
}

tmux_socket() {
	printf '%s\n' "$TMUX" | cut -d',' -f1
}

cache_tmux_default_command() {
	local default_shell opt=""
	default_shell="$(get_tmux_option "default-shell" "")"
	if [ "$(basename "$default_shell")" = "bash" ]; then
		opt="-l "
	fi
	TMUX_DEFAULT_COMMAND="$(get_tmux_option \
		"default-command" "$opt$default_shell")"
	export TMUX_DEFAULT_COMMAND
}

tmux_default_command() {
	printf '%s\n' "$TMUX_DEFAULT_COMMAND"
}

pane_creation_command() {
	local pane_file quoted_file
	pane_file="$(pane_contents_file "restore" "${1}:${2}.${3}")"
	printf -v quoted_file '%q' "$pane_file"
	printf 'cat %s; exec %s\n' "$quoted_file" "$(tmux_default_command)"
}

new_window() {
	local session_name="$1"
	local window_number="$2"
	local dir="$3"
	local pane_index="$4"
	local pane_id="${session_name}:${window_number}.${pane_index}"
	local creation_command
	if is_restoring_pane_contents && pane_contents_file_exists "$pane_id"; then
		creation_command="$(pane_creation_command \
			"$session_name" "$window_number" "$pane_index")"
		tmux new-window -d -t "${session_name}:${window_number}" \
			-c "$dir" "$creation_command"
	else
		tmux new-window -d -t "${session_name}:${window_number}" -c "$dir"
	fi
}

new_session() {
	local session_name="$1"
	local window_number="$2"
	local dir="$3"
	local pane_index="$4"
	local pane_id="${session_name}:${window_number}.${pane_index}"
	local creation_command created_window_num
	if is_restoring_pane_contents && pane_contents_file_exists "$pane_id"; then
		creation_command="$(pane_creation_command \
			"$session_name" "$window_number" "$pane_index")"
		TMUX="" tmux -S "$(tmux_socket)" new-session -d \
			-s "$session_name" -c "$dir" "$creation_command" || return 1
	else
		TMUX="" tmux -S "$(tmux_socket)" new-session -d \
			-s "$session_name" -c "$dir" || return 1
	fi
	created_window_num="$(first_window_num)"
	if [ "$created_window_num" -ne "$window_number" ]; then
		tmux move-window -s "${session_name}:${created_window_num}" \
			-t "${session_name}:${window_number}"
	fi
}

new_pane() {
	local session_name="$1"
	local window_number="$2"
	local dir="$3"
	local pane_index="$4"
	local pane_id="${session_name}:${window_number}.${pane_index}"
	local creation_command
	if is_restoring_pane_contents && pane_contents_file_exists "$pane_id"; then
		creation_command="$(pane_creation_command \
			"$session_name" "$window_number" "$pane_index")"
		tmux split-window -t "${session_name}:${window_number}" \
			-c "$dir" "$creation_command" || return 1
	else
		tmux split-window -t "${session_name}:${window_number}" \
			-c "$dir" || return 1
	fi
	tmux resize-pane -t "${session_name}:${window_number}" -U "999"
}

restore_pane_at_index() {
	local index="$1"
	local session_name="${_RESTORE_PANE_SESSIONS[index]}"
	local window_number="${_RESTORE_PANE_WINDOWS[index]}"
	local pane_index="${_RESTORE_PANE_INDEXES[index]}"
	local pane_title="${_RESTORE_PANE_TITLES[index]}"
	local dir="${_RESTORE_PANE_DIRS[index]}"
	local existing_pane_id
	[ "$session_name" = "0" ] && RESTORED_SESSION_0="true"
	if pane_exists "$session_name" "$window_number" "$pane_index"; then
		if ! is_restoring_from_scratch; then
			register_existing_pane \
				"$session_name" "$window_number" "$pane_index"
		elif existing_pane_id="$(tmux display-message -p \
			-F "#{pane_id}" -t "$session_name:$window_number")"; then
			new_pane "$session_name" "$window_number" "$dir" \
				"$pane_index" || return 1
			tmux kill-pane -t "$existing_pane_id" || return 1
		else
			return 1
		fi
	elif window_exists "$session_name" "$window_number"; then
		new_pane "$session_name" "$window_number" "$dir" \
			"$pane_index" || return 1
	elif session_exists "$session_name"; then
		new_window "$session_name" "$window_number" "$dir" \
			"$pane_index" || return 1
	else
		new_session "$session_name" "$window_number" "$dir" \
			"$pane_index" || return 1
	fi
	tmux select-pane -t \
		"$session_name:$window_number.$pane_index" -T "$pane_title"
}

never_ever_overwrite() {
	[ -n "$(get_tmux_option "$overwrite_option" "")" ]
}

detect_if_restoring_from_scratch() {
	local total_number_of_panes
	never_ever_overwrite && return 0
	total_number_of_panes="$(tmux list-panes -a | wc -l | sed 's/ //g')"
	if [ "$total_number_of_panes" -eq 1 ]; then
		RESTORING_FROM_SCRATCH="true"
	fi
}

detect_if_restoring_pane_contents() {
	if capture_pane_contents_option_on; then
		cache_tmux_default_command
		RESTORE_PANE_CONTENTS="true"
	fi
}

restore_all_panes() {
	local index
	detect_if_restoring_from_scratch
	detect_if_restoring_pane_contents
	if is_restoring_pane_contents; then
		pane_content_files_restore_from_archive || return 1
	fi
	for ((index = 0; index < ${#_RESTORE_PANE_SESSIONS[@]}; index++)); do
		restore_pane_at_index "$index" || return 1
	done
}

handle_session_0() {
	local current_session
	if ! is_restoring_from_scratch || has_restored_session_0; then
		return 0
	fi
	current_session="$(tmux display -p "#{client_session}")"
	if [ "$current_session" = "0" ]; then
		tmux switch-client -n || return 1
	fi
	tmux kill-session -t "0"
}

restore_window_properties() {
	local index target automatic_rename
	for ((index = 0;
		index < ${#_RESTORE_WINDOW_SESSIONS[@]}; index++)); do
		target="${_RESTORE_WINDOW_SESSIONS[index]}:"
		target+="${_RESTORE_WINDOW_INDEXES[index]}"
		tmux select-layout -t "$target" \
			"${_RESTORE_WINDOW_LAYOUTS[index]}" || return 1
		tmux rename-window -t "$target" \
			"${_RESTORE_WINDOW_NAMES[index]}" || return 1
		automatic_rename="${_RESTORE_WINDOW_AUTOMATIC_RENAME[index]}"
		if [ -z "$automatic_rename" ]; then
			tmux set-option -u -t "$target" automatic-rename || return 1
		else
			tmux set-option -t "$target" automatic-rename \
				"$automatic_rename" || return 1
		fi
	done
}

restore_all_pane_processes() {
	local index full_command
	restore_pane_processes_enabled || return 0
	for ((index = 0; index < ${#_RESTORE_PANE_SESSIONS[@]}; index++)); do
		full_command="${_RESTORE_PANE_FULL_COMMANDS[index]}"
		[ -n "$full_command" ] || continue
		if is_pane_registered_as_existing \
			"${_RESTORE_PANE_SESSIONS[index]}" \
			"${_RESTORE_PANE_WINDOWS[index]}" \
			"${_RESTORE_PANE_INDEXES[index]}"; then
			continue
		fi
		restore_pane_process "$full_command" \
			"${_RESTORE_PANE_SESSIONS[index]}" \
			"${_RESTORE_PANE_WINDOWS[index]}" \
			"${_RESTORE_PANE_INDEXES[index]}" \
			"${_RESTORE_PANE_DIRS[index]}" || return 1
	done
}

restore_active_panes() {
	local index
	for ((index = 0; index < ${#_RESTORE_PANE_SESSIONS[@]}; index++)); do
		[ "${_RESTORE_PANE_ACTIVE[index]}" = "1" ] || continue
		tmux switch-client -t \
			"${_RESTORE_PANE_SESSIONS[index]}:"\
"${_RESTORE_PANE_WINDOWS[index]}" || return 1
		tmux select-pane -t \
			"${_RESTORE_PANE_SESSIONS[index]}:"\
"${_RESTORE_PANE_WINDOWS[index]}."\
"${_RESTORE_PANE_INDEXES[index]}" || return 1
	done
}

restore_zoomed_windows() {
	local index
	for ((index = 0; index < ${#_RESTORE_PANE_SESSIONS[@]}; index++)); do
		case "${_RESTORE_PANE_WINDOW_FLAGS[index]}" in
			*Z*) ;;
			*) continue ;;
		esac
		[ "${_RESTORE_PANE_ACTIVE[index]}" = "1" ] || continue
		tmux resize-pane -t \
			"${_RESTORE_PANE_SESSIONS[index]}:"\
"${_RESTORE_PANE_WINDOWS[index]}" -Z || return 1
	done
}

restore_grouped_sessions() {
	local index session_name alternate active
	for ((index = 0; index < ${#_RESTORE_GROUP_SESSIONS[@]}; index++)); do
		session_name="${_RESTORE_GROUP_SESSIONS[index]}"
		TMUX="" tmux -S "$(tmux_socket)" new-session -d \
			-s "$session_name" \
			-t "${_RESTORE_GROUP_ORIGINALS[index]}" || return 1
		alternate="${_RESTORE_GROUP_ALTERNATE_WINDOWS[index]}"
		active="${_RESTORE_GROUP_ACTIVE_WINDOWS[index]}"
		if [ -n "$alternate" ]; then
			tmux switch-client -t \
				"${session_name}:${alternate}" || return 1
		fi
		if [ -n "$active" ]; then
			tmux switch-client -t "${session_name}:${active}" || return 1
		fi
	done
}

restore_active_and_alternate_windows() {
	local index flags
	for ((index = 0;
		index < ${#_RESTORE_WINDOW_SESSIONS[@]}; index++)); do
		flags="${_RESTORE_WINDOW_FLAGS[index]}"
		case "$flags" in
			*\**|*-*)
				tmux switch-client -t \
					"${_RESTORE_WINDOW_SESSIONS[index]}:"\
"${_RESTORE_WINDOW_INDEXES[index]}" || return 1
				;;
		esac
	done
}

restore_active_and_alternate_sessions() {
	local index session_name last_session_name
	for ((index = 0;
		index < ${#_RESTORE_STATE_SESSIONS[@]}; index++)); do
		session_name="${_RESTORE_STATE_SESSIONS[index]}"
		last_session_name="${_RESTORE_STATE_LAST_SESSIONS[index]}"
		if [ -n "$last_session_name" ]; then
			tmux switch-client -t "$last_session_name" || return 1
		fi
		tmux switch-client -t "$session_name" || return 1
	done
}

cleanup_restored_pane_contents() {
	if is_restoring_pane_contents; then
		rm -f "$(pane_contents_dir "restore")"/*
	fi
}

restore_normalized_snapshot() {
	execute_hook "pre-restore-all"
	restore_all_panes || return 1
	handle_session_0 || return 1
	restore_window_properties || return 1
	execute_hook "pre-restore-pane-processes"
	restore_all_pane_processes || return 1
	restore_active_panes || return 1
	restore_zoomed_windows || return 1
	restore_grouped_sessions || return 1
	restore_active_and_alternate_windows || return 1
	restore_active_and_alternate_sessions || return 1
	cleanup_restored_pane_contents || return 1
	execute_hook "post-restore-all"
}

main() {
	if ! supported_tmux_version_ok || ! check_saved_session_exists; then
		return 1
	fi
	if ! prepare_restore_snapshot; then
		cleanup_restore_temp
		return 1
	fi
	start_spinner "Restoring..." "Tmux restore complete!"
	if ! restore_normalized_snapshot; then
		stop_spinner
		cleanup_restore_temp
		display_message "Tmux restore failed; snapshot was rejected or incomplete"
		return 1
	fi
	stop_spinner
	cleanup_restore_temp
	display_message "Tmux restore complete!"
}

main "$@"
