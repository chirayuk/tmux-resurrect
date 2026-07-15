#!/usr/bin/env bash

# Versioned snapshot codec and normalization boundary. This file defines
# functions only; callers decide whether parsing leads to I/O or tmux actions.

SNAPSHOT_FORMAT_NAME="tmux-resurrect"
SNAPSHOT_FORMAT_VERSION="2"
SNAPSHOT_RECORD_SEPARATOR=$'\t'

snapshot_error() {
	local record_number="$1"
	local reason="$2"
	printf 'snapshot record %s: %s\n' "$record_number" "$reason" >&2
}

snapshot_encode_string() {
	printf '%s' "$1" | base64 | tr -d '\r\n'
}

snapshot_string_token() {
	printf 's:%s' "$(snapshot_encode_string "$1")"
}

snapshot_unsigned_token() {
	printf 'u:%s' "$1"
}

snapshot_boolean_token() {
	printf 'b:%s' "$1"
}

snapshot_nullable_unsigned_token() {
	local value="$1"
	if [ -z "$value" ]; then
		printf 'n:'
	else
		snapshot_unsigned_token "$value"
	fi
}

snapshot_write_header() {
	printf '%s\t%s\n' "$SNAPSHOT_FORMAT_NAME" \
		"$SNAPSHOT_FORMAT_VERSION"
}

snapshot_write_pane() {
	local session_name="$1"
	local window_index="$2"
	local window_active="$3"
	local window_flags="$4"
	local pane_index="$5"
	local pane_title="$6"
	local pane_dir="$7"
	local pane_active="$8"
	local pane_command="$9"
	shift 9
	local pane_full_command="$1"

	printf '%s\t%s\t%s' "record" "$SNAPSHOT_FORMAT_VERSION" "pane"
	printf '\tsession_name=%s' "$(snapshot_string_token "$session_name")"
	printf '\twindow_index=%s' "$(snapshot_unsigned_token "$window_index")"
	printf '\twindow_active=%s' \
		"$(snapshot_boolean_token "$window_active")"
	printf '\twindow_flags=%s' "$(snapshot_string_token "$window_flags")"
	printf '\tpane_index=%s' "$(snapshot_unsigned_token "$pane_index")"
	printf '\tpane_title=%s' "$(snapshot_string_token "$pane_title")"
	printf '\tpane_dir=%s' "$(snapshot_string_token "$pane_dir")"
	printf '\tpane_active=%s' \
		"$(snapshot_boolean_token "$pane_active")"
	printf '\tpane_command=%s' "$(snapshot_string_token "$pane_command")"
	printf '\tpane_full_command=%s\n' \
		"$(snapshot_string_token "$pane_full_command")"
}

snapshot_write_window() {
	local session_name="$1"
	local window_index="$2"
	local window_name="$3"
	local window_active="$4"
	local window_flags="$5"
	local window_layout="$6"
	local automatic_rename="$7"

	printf '%s\t%s\t%s' "record" "$SNAPSHOT_FORMAT_VERSION" "window"
	printf '\tsession_name=%s' "$(snapshot_string_token "$session_name")"
	printf '\twindow_index=%s' "$(snapshot_unsigned_token "$window_index")"
	printf '\twindow_name=%s' "$(snapshot_string_token "$window_name")"
	printf '\twindow_active=%s' \
		"$(snapshot_boolean_token "$window_active")"
	printf '\twindow_flags=%s' "$(snapshot_string_token "$window_flags")"
	printf '\twindow_layout=%s' "$(snapshot_string_token "$window_layout")"
	printf '\tautomatic_rename=%s\n' \
		"$(snapshot_string_token "$automatic_rename")"
}

snapshot_write_state() {
	local session_name="$1"
	local last_session_name="$2"

	printf '%s\t%s\t%s' "record" "$SNAPSHOT_FORMAT_VERSION" "state"
	printf '\tsession_name=%s' "$(snapshot_string_token "$session_name")"
	printf '\tlast_session_name=%s\n' \
		"$(snapshot_string_token "$last_session_name")"
}

snapshot_write_grouped_session() {
	local session_name="$1"
	local original_session_name="$2"
	local alternate_window_index="$3"
	local active_window_index="$4"

	printf '%s\t%s\t%s' \
		"record" "$SNAPSHOT_FORMAT_VERSION" "grouped_session"
	printf '\tsession_name=%s' "$(snapshot_string_token "$session_name")"
	printf '\toriginal_session_name=%s' \
		"$(snapshot_string_token "$original_session_name")"
	printf '\talternate_window_index=%s' \
		"$(snapshot_nullable_unsigned_token "$alternate_window_index")"
	printf '\tactive_window_index=%s\n' \
		"$(snapshot_nullable_unsigned_token "$active_window_index")"
}

snapshot_split_line() {
	local remainder="$1"
	local field
	SNAPSHOT_FIELDS=()
	while [[ "$remainder" == *"$SNAPSHOT_RECORD_SEPARATOR"* ]]; do
		field="${remainder%%"$SNAPSHOT_RECORD_SEPARATOR"*}"
		SNAPSHOT_FIELDS+=("$field")
		remainder="${remainder#*"$SNAPSHOT_RECORD_SEPARATOR"}"
	done
	SNAPSHOT_FIELDS+=("$remainder")
}

snapshot_base64_decoder() {
	if printf '' | base64 --decode >/dev/null 2>&1; then
		printf '%s' "--decode"
		return 0
	fi
	if printf '' | base64 -D >/dev/null 2>&1; then
		printf '%s' "-D"
		return 0
	fi
	if printf '' | base64 -d >/dev/null 2>&1; then
		printf '%s' "-d"
		return 0
	fi
	return 1
}

snapshot_base64_is_well_formed() {
	local payload="$1"
	local length="${#payload}"
	case "$payload" in
		*[!A-Za-z0-9+/=]*) return 1 ;;
	esac
	[ $((length % 4)) -eq 0 ] || return 1
	[[ "$payload" =~ ^[A-Za-z0-9+/]*={0,2}$ ]]
}

snapshot_decode_string() {
	local payload="$1"
	local record_number="$2"
	local field_name="$3"
	local decoder marked reencoded

	if ! snapshot_base64_is_well_formed "$payload"; then
		snapshot_error "$record_number" \
			"field $field_name contains malformed Base64"
		return 1
	fi
	if ! decoder="$(snapshot_base64_decoder)"; then
		snapshot_error "$record_number" \
			"no supported Base64 decoder is available"
		return 1
	fi
	if ! printf '%s' "$payload" | base64 "$decoder" \
		> "$_SNAPSHOT_DECODE_FILE" 2>/dev/null; then
		snapshot_error "$record_number" \
			"field $field_name cannot be decoded"
		return 1
	fi
	if od -An -tx1 "$_SNAPSHOT_DECODE_FILE" | \
		grep -Eq '(^|[[:space:]])00([[:space:]]|$)'; then
		snapshot_error "$record_number" \
			"field $field_name contains an unsupported NUL byte"
		return 1
	fi
	marked="$(cat "$_SNAPSHOT_DECODE_FILE"; printf '\034')"
	SNAPSHOT_PARSED_VALUE="${marked%?}"
	reencoded="$(snapshot_encode_string "$SNAPSHOT_PARSED_VALUE")"
	if [ "$reencoded" != "$payload" ]; then
		snapshot_error "$record_number" \
			"field $field_name has non-canonical Base64"
		return 1
	fi
}

snapshot_parse_string_field() {
	local token="$1"
	local expected_name="$2"
	local record_number="$3"
	local actual_name value

	actual_name="${token%%=*}"
	if [ "$actual_name" = "$token" ] || \
		[ "$actual_name" != "$expected_name" ]; then
		snapshot_error "$record_number" \
			"expected field $expected_name"
		return 1
	fi
	value="${token#*=}"
	case "$value" in
		s:*) value="${value#s:}" ;;
		*)
			snapshot_error "$record_number" \
				"field $expected_name must be a string"
			return 1
			;;
	esac
	snapshot_decode_string "$value" "$record_number" "$expected_name"
}

snapshot_parse_unsigned_field() {
	local token="$1"
	local expected_name="$2"
	local record_number="$3"
	local actual_name value

	actual_name="${token%%=*}"
	if [ "$actual_name" = "$token" ] || \
		[ "$actual_name" != "$expected_name" ]; then
		snapshot_error "$record_number" \
			"expected field $expected_name"
		return 1
	fi
	value="${token#*=}"
	case "$value" in
		u:*) value="${value#u:}" ;;
		*)
			snapshot_error "$record_number" \
				"field $expected_name must be unsigned"
			return 1
			;;
	esac
	case "$value" in
		''|*[!0-9]*)
			snapshot_error "$record_number" \
				"field $expected_name is not an unsigned integer"
			return 1
			;;
	esac
	SNAPSHOT_PARSED_VALUE="$value"
}

snapshot_parse_boolean_field() {
	local token="$1"
	local expected_name="$2"
	local record_number="$3"
	local value

	if ! snapshot_parse_unsigned_field \
		"${token/=b:/=u:}" "$expected_name" "$record_number"; then
		return 1
	fi
	value="$SNAPSHOT_PARSED_VALUE"
	case "$value" in
		0|1) return 0 ;;
		*)
			snapshot_error "$record_number" \
				"field $expected_name is not boolean"
			return 1
			;;
	esac
}

snapshot_parse_nullable_unsigned_field() {
	local token="$1"
	local expected_name="$2"
	local record_number="$3"
	local actual_name value

	actual_name="${token%%=*}"
	if [ "$actual_name" = "$token" ] || \
		[ "$actual_name" != "$expected_name" ]; then
		snapshot_error "$record_number" \
			"expected field $expected_name"
		return 1
	fi
	value="${token#*=}"
	if [ "$value" = "n:" ]; then
		SNAPSHOT_PARSED_VALUE=""
		return 0
	fi
	snapshot_parse_unsigned_field "$token" "$expected_name" \
		"$record_number"
}

snapshot_reset_record() {
	SNAPSHOT_RECORD_TYPE=""
	SNAPSHOT_SESSION_NAME=""
	SNAPSHOT_WINDOW_INDEX=""
	SNAPSHOT_WINDOW_ACTIVE=""
	SNAPSHOT_WINDOW_FLAGS=""
	SNAPSHOT_WINDOW_NAME=""
	SNAPSHOT_WINDOW_LAYOUT=""
	SNAPSHOT_AUTOMATIC_RENAME=""
	SNAPSHOT_PANE_INDEX=""
	SNAPSHOT_PANE_TITLE=""
	SNAPSHOT_PANE_DIR=""
	SNAPSHOT_PANE_ACTIVE=""
	SNAPSHOT_PANE_COMMAND=""
	SNAPSHOT_PANE_FULL_COMMAND=""
	SNAPSHOT_LAST_SESSION_NAME=""
	SNAPSHOT_ORIGINAL_SESSION_NAME=""
	SNAPSHOT_ALTERNATE_WINDOW_INDEX=""
	SNAPSHOT_ACTIVE_WINDOW_INDEX=""
}

snapshot_require_field_count() {
	local expected="$1"
	local record_number="$2"
	if [ "${#SNAPSHOT_FIELDS[@]}" -ne "$expected" ]; then
		snapshot_error "$record_number" \
			"expected $expected fields, found ${#SNAPSHOT_FIELDS[@]}"
		return 1
	fi
}

snapshot_parse_pane_record() {
	local record_number="$1"
	snapshot_require_field_count 13 "$record_number" || return 1
	snapshot_parse_string_field "${SNAPSHOT_FIELDS[3]}" \
		"session_name" "$record_number" || return 1
	SNAPSHOT_SESSION_NAME="$SNAPSHOT_PARSED_VALUE"
	snapshot_parse_unsigned_field "${SNAPSHOT_FIELDS[4]}" \
		"window_index" "$record_number" || return 1
	SNAPSHOT_WINDOW_INDEX="$SNAPSHOT_PARSED_VALUE"
	snapshot_parse_boolean_field "${SNAPSHOT_FIELDS[5]}" \
		"window_active" "$record_number" || return 1
	SNAPSHOT_WINDOW_ACTIVE="$SNAPSHOT_PARSED_VALUE"
	snapshot_parse_string_field "${SNAPSHOT_FIELDS[6]}" \
		"window_flags" "$record_number" || return 1
	SNAPSHOT_WINDOW_FLAGS="$SNAPSHOT_PARSED_VALUE"
	snapshot_parse_unsigned_field "${SNAPSHOT_FIELDS[7]}" \
		"pane_index" "$record_number" || return 1
	SNAPSHOT_PANE_INDEX="$SNAPSHOT_PARSED_VALUE"
	snapshot_parse_string_field "${SNAPSHOT_FIELDS[8]}" \
		"pane_title" "$record_number" || return 1
	SNAPSHOT_PANE_TITLE="$SNAPSHOT_PARSED_VALUE"
	snapshot_parse_string_field "${SNAPSHOT_FIELDS[9]}" \
		"pane_dir" "$record_number" || return 1
	SNAPSHOT_PANE_DIR="$SNAPSHOT_PARSED_VALUE"
	if [ -z "$SNAPSHOT_PANE_DIR" ]; then
		snapshot_error "$record_number" "field pane_dir must not be empty"
		return 1
	fi
	snapshot_parse_boolean_field "${SNAPSHOT_FIELDS[10]}" \
		"pane_active" "$record_number" || return 1
	SNAPSHOT_PANE_ACTIVE="$SNAPSHOT_PARSED_VALUE"
	snapshot_parse_string_field "${SNAPSHOT_FIELDS[11]}" \
		"pane_command" "$record_number" || return 1
	SNAPSHOT_PANE_COMMAND="$SNAPSHOT_PARSED_VALUE"
	snapshot_parse_string_field "${SNAPSHOT_FIELDS[12]}" \
		"pane_full_command" "$record_number" || return 1
	SNAPSHOT_PANE_FULL_COMMAND="$SNAPSHOT_PARSED_VALUE"
}

snapshot_parse_window_record() {
	local record_number="$1"
	snapshot_require_field_count 10 "$record_number" || return 1
	snapshot_parse_string_field "${SNAPSHOT_FIELDS[3]}" \
		"session_name" "$record_number" || return 1
	SNAPSHOT_SESSION_NAME="$SNAPSHOT_PARSED_VALUE"
	snapshot_parse_unsigned_field "${SNAPSHOT_FIELDS[4]}" \
		"window_index" "$record_number" || return 1
	SNAPSHOT_WINDOW_INDEX="$SNAPSHOT_PARSED_VALUE"
	snapshot_parse_string_field "${SNAPSHOT_FIELDS[5]}" \
		"window_name" "$record_number" || return 1
	SNAPSHOT_WINDOW_NAME="$SNAPSHOT_PARSED_VALUE"
	snapshot_parse_boolean_field "${SNAPSHOT_FIELDS[6]}" \
		"window_active" "$record_number" || return 1
	SNAPSHOT_WINDOW_ACTIVE="$SNAPSHOT_PARSED_VALUE"
	snapshot_parse_string_field "${SNAPSHOT_FIELDS[7]}" \
		"window_flags" "$record_number" || return 1
	SNAPSHOT_WINDOW_FLAGS="$SNAPSHOT_PARSED_VALUE"
	snapshot_parse_string_field "${SNAPSHOT_FIELDS[8]}" \
		"window_layout" "$record_number" || return 1
	SNAPSHOT_WINDOW_LAYOUT="$SNAPSHOT_PARSED_VALUE"
	snapshot_parse_string_field "${SNAPSHOT_FIELDS[9]}" \
		"automatic_rename" "$record_number" || return 1
	SNAPSHOT_AUTOMATIC_RENAME="$SNAPSHOT_PARSED_VALUE"
}

snapshot_parse_state_record() {
	local record_number="$1"
	snapshot_require_field_count 5 "$record_number" || return 1
	snapshot_parse_string_field "${SNAPSHOT_FIELDS[3]}" \
		"session_name" "$record_number" || return 1
	SNAPSHOT_SESSION_NAME="$SNAPSHOT_PARSED_VALUE"
	snapshot_parse_string_field "${SNAPSHOT_FIELDS[4]}" \
		"last_session_name" "$record_number" || return 1
	SNAPSHOT_LAST_SESSION_NAME="$SNAPSHOT_PARSED_VALUE"
}

snapshot_parse_grouped_session_record() {
	local record_number="$1"
	snapshot_require_field_count 7 "$record_number" || return 1
	snapshot_parse_string_field "${SNAPSHOT_FIELDS[3]}" \
		"session_name" "$record_number" || return 1
	SNAPSHOT_SESSION_NAME="$SNAPSHOT_PARSED_VALUE"
	snapshot_parse_string_field "${SNAPSHOT_FIELDS[4]}" \
		"original_session_name" "$record_number" || return 1
	SNAPSHOT_ORIGINAL_SESSION_NAME="$SNAPSHOT_PARSED_VALUE"
	snapshot_parse_nullable_unsigned_field "${SNAPSHOT_FIELDS[5]}" \
		"alternate_window_index" "$record_number" || return 1
	SNAPSHOT_ALTERNATE_WINDOW_INDEX="$SNAPSHOT_PARSED_VALUE"
	snapshot_parse_nullable_unsigned_field "${SNAPSHOT_FIELDS[6]}" \
		"active_window_index" "$record_number" || return 1
	SNAPSHOT_ACTIVE_WINDOW_INDEX="$SNAPSHOT_PARSED_VALUE"
}

snapshot_parse_record() {
	local record_number="$1"
	local record_type
	snapshot_reset_record
	if [ "${SNAPSHOT_FIELDS[0]-}" != "record" ]; then
		snapshot_error "$record_number" "unknown record marker"
		return 1
	fi
	if [ "${SNAPSHOT_FIELDS[1]-}" != "$SNAPSHOT_FORMAT_VERSION" ]; then
		snapshot_error "$record_number" "unsupported record version"
		return 1
	fi
	record_type="${SNAPSHOT_FIELDS[2]-}"
	SNAPSHOT_RECORD_TYPE="$record_type"
	case "$record_type" in
		pane) snapshot_parse_pane_record "$record_number" ;;
		window) snapshot_parse_window_record "$record_number" ;;
		state) snapshot_parse_state_record "$record_number" ;;
		grouped_session)
			snapshot_parse_grouped_session_record "$record_number"
			;;
		*)
			snapshot_error "$record_number" \
				"unsupported record type [$record_type]"
			return 1
			;;
	esac
}

snapshot_parse_header() {
	local record_number="$1"
	snapshot_require_field_count 2 "$record_number" || return 1
	if [ "${SNAPSHOT_FIELDS[0]}" != "$SNAPSHOT_FORMAT_NAME" ]; then
		snapshot_error "$record_number" "unknown snapshot format"
		return 1
	fi
	if [ "${SNAPSHOT_FIELDS[1]}" != "$SNAPSHOT_FORMAT_VERSION" ]; then
		snapshot_error "$record_number" \
			"unsupported snapshot version [${SNAPSHOT_FIELDS[1]}]"
		return 1
	fi
}

snapshot_parse_file() {
	local file="$1"
	local callback="$2"
	local line record_number=0 temp_dir status=0

	if [ ! -f "$file" ]; then
		snapshot_error 0 "snapshot file not found: $file"
		return 1
	fi
	temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/resurrect-decode.XXXXXX")"
	_SNAPSHOT_DECODE_FILE="$temp_dir/decoded"
	while IFS= read -r line || [ -n "$line" ]; do
		record_number=$((record_number + 1))
		if [ -z "$line" ]; then
			snapshot_error "$record_number" "empty physical record"
			status=1
			break
		fi
		snapshot_split_line "$line"
		if [ "$record_number" -eq 1 ]; then
			snapshot_parse_header "$record_number" || status=1
		else
			snapshot_parse_record "$record_number" || status=1
			if [ "$status" -eq 0 ]; then
				"$callback" "$record_number" || status=1
			fi
		fi
		[ "$status" -eq 0 ] || break
	done < "$file"
	if [ "$record_number" -eq 0 ]; then
		snapshot_error 0 "snapshot file is empty"
		status=1
	fi
	rm -rf "$temp_dir"
	return "$status"
}

snapshot_collect_relationships() {
	case "$SNAPSHOT_RECORD_TYPE" in
		pane)
			_SNAPSHOT_PANE_SESSIONS+=("$SNAPSHOT_SESSION_NAME")
			_SNAPSHOT_PANE_WINDOWS+=("$SNAPSHOT_WINDOW_INDEX")
			_SNAPSHOT_PANE_INDEXES+=("$SNAPSHOT_PANE_INDEX")
			_SNAPSHOT_PANE_WINDOW_ACTIVE+=("$SNAPSHOT_WINDOW_ACTIVE")
			_SNAPSHOT_PANE_WINDOW_FLAGS+=("$SNAPSHOT_WINDOW_FLAGS")
			;;
		window)
			_SNAPSHOT_WINDOW_SESSIONS+=("$SNAPSHOT_SESSION_NAME")
			_SNAPSHOT_WINDOW_INDEXES+=("$SNAPSHOT_WINDOW_INDEX")
			_SNAPSHOT_WINDOW_ACTIVE+=("$SNAPSHOT_WINDOW_ACTIVE")
			_SNAPSHOT_WINDOW_FLAGS+=("$SNAPSHOT_WINDOW_FLAGS")
			;;
		state)
			_SNAPSHOT_STATE_RECORD_COUNT=$((
				_SNAPSHOT_STATE_RECORD_COUNT + 1
			))
			_SNAPSHOT_STATE_SESSIONS+=("$SNAPSHOT_SESSION_NAME")
			if [ -n "$SNAPSHOT_LAST_SESSION_NAME" ]; then
				_SNAPSHOT_STATE_SESSIONS+=("$SNAPSHOT_LAST_SESSION_NAME")
			fi
			;;
		grouped_session)
			_SNAPSHOT_GROUP_SESSIONS+=("$SNAPSHOT_SESSION_NAME")
			_SNAPSHOT_GROUP_ORIGINALS+=(
				"$SNAPSHOT_ORIGINAL_SESSION_NAME"
			)
			;;
		*)
			snapshot_error 0 \
				"internal unsupported record type [$SNAPSHOT_RECORD_TYPE]"
			return 1
			;;
	esac
}

snapshot_window_exists() {
	local session_name="$1"
	local window_index="$2"
	local index
	for ((index = 0; index < ${#_SNAPSHOT_WINDOW_SESSIONS[@]}; index++)); do
		if [ "${_SNAPSHOT_WINDOW_SESSIONS[index]}" = "$session_name" ] &&
			[ "${_SNAPSHOT_WINDOW_INDEXES[index]}" = "$window_index" ]; then
			return 0
		fi
	done
	return 1
}

snapshot_session_exists() {
	local session_name="$1"
	local index
	for ((index = 0;
		index < ${#_SNAPSHOT_WINDOW_SESSIONS[@]}; index++)); do
		if [ "${_SNAPSHOT_WINDOW_SESSIONS[index]}" = "$session_name" ]; then
			return 0
		fi
	done
	for ((index = 0;
		index < ${#_SNAPSHOT_GROUP_SESSIONS[@]}; index++)); do
		if [ "${_SNAPSHOT_GROUP_SESSIONS[index]}" = "$session_name" ]; then
			return 0
		fi
	done
	return 1
}

snapshot_relationships_are_valid() {
	local index other window_index
	if [ "$_SNAPSHOT_STATE_RECORD_COUNT" -ne 1 ]; then
		snapshot_error 0 "snapshot must contain exactly one state record"
		return 1
	fi
	for ((index = 0; index < ${#_SNAPSHOT_PANE_SESSIONS[@]}; index++)); do
		if ! snapshot_window_exists \
			"${_SNAPSHOT_PANE_SESSIONS[index]}" \
			"${_SNAPSHOT_PANE_WINDOWS[index]}"; then
			snapshot_error 0 \
				"pane target ${_SNAPSHOT_PANE_SESSIONS[index]}:"\
"${_SNAPSHOT_PANE_WINDOWS[index]} has no matching window"
			return 1
		fi
		for ((window_index = 0;
			window_index < ${#_SNAPSHOT_WINDOW_SESSIONS[@]};
			window_index++)); do
			if [ "${_SNAPSHOT_WINDOW_SESSIONS[window_index]}" != \
				"${_SNAPSHOT_PANE_SESSIONS[index]}" ] ||
				[ "${_SNAPSHOT_WINDOW_INDEXES[window_index]}" != \
				"${_SNAPSHOT_PANE_WINDOWS[index]}" ]; then
				continue
			fi
			if [ "${_SNAPSHOT_WINDOW_ACTIVE[window_index]}" != \
				"${_SNAPSHOT_PANE_WINDOW_ACTIVE[index]}" ] ||
				[ "${_SNAPSHOT_WINDOW_FLAGS[window_index]}" != \
				"${_SNAPSHOT_PANE_WINDOW_FLAGS[index]}" ]; then
				snapshot_error 0 \
					"pane/window properties disagree for target"
				return 1
			fi
		done
		for ((other = index + 1;
			other < ${#_SNAPSHOT_PANE_SESSIONS[@]}; other++)); do
			if [ "${_SNAPSHOT_PANE_SESSIONS[index]}" = \
				"${_SNAPSHOT_PANE_SESSIONS[other]}" ] &&
				[ "${_SNAPSHOT_PANE_WINDOWS[index]}" = \
				"${_SNAPSHOT_PANE_WINDOWS[other]}" ] &&
				[ "${_SNAPSHOT_PANE_INDEXES[index]}" = \
				"${_SNAPSHOT_PANE_INDEXES[other]}" ]; then
				snapshot_error 0 "duplicate pane identity"
				return 1
			fi
		done
	done
	for ((index = 0; index < ${#_SNAPSHOT_WINDOW_SESSIONS[@]}; index++)); do
		for ((other = index + 1;
			other < ${#_SNAPSHOT_WINDOW_SESSIONS[@]}; other++)); do
			if [ "${_SNAPSHOT_WINDOW_SESSIONS[index]}" = \
				"${_SNAPSHOT_WINDOW_SESSIONS[other]}" ] &&
				[ "${_SNAPSHOT_WINDOW_INDEXES[index]}" = \
				"${_SNAPSHOT_WINDOW_INDEXES[other]}" ]; then
				snapshot_error 0 "duplicate window identity"
				return 1
			fi
		done
	done
	for ((index = 0; index < ${#_SNAPSHOT_STATE_SESSIONS[@]}; index++)); do
		if ! snapshot_session_exists \
			"${_SNAPSHOT_STATE_SESSIONS[index]}"; then
			snapshot_error 0 \
				"state references unknown session "\
"[${_SNAPSHOT_STATE_SESSIONS[index]}]"
			return 1
		fi
	done
	for ((index = 0; index < ${#_SNAPSHOT_GROUP_ORIGINALS[@]}; index++)); do
		if ! snapshot_session_exists \
			"${_SNAPSHOT_GROUP_ORIGINALS[index]}"; then
			snapshot_error 0 \
				"group references unknown original session "\
"[${_SNAPSHOT_GROUP_ORIGINALS[index]}]"
			return 1
		fi
	done
}

snapshot_validate_file() {
	local file="$1"
	_SNAPSHOT_PANE_SESSIONS=()
	_SNAPSHOT_PANE_WINDOWS=()
	_SNAPSHOT_PANE_INDEXES=()
	_SNAPSHOT_PANE_WINDOW_ACTIVE=()
	_SNAPSHOT_PANE_WINDOW_FLAGS=()
	_SNAPSHOT_WINDOW_SESSIONS=()
	_SNAPSHOT_WINDOW_INDEXES=()
	_SNAPSHOT_WINDOW_ACTIVE=()
	_SNAPSHOT_WINDOW_FLAGS=()
	_SNAPSHOT_STATE_SESSIONS=()
	_SNAPSHOT_STATE_RECORD_COUNT=0
	_SNAPSHOT_GROUP_SESSIONS=()
	_SNAPSHOT_GROUP_ORIGINALS=()
	snapshot_parse_file "$file" snapshot_collect_relationships || return 1
	snapshot_relationships_are_valid
}

snapshot_legacy_unprefix() {
	local value="$1"
	local record_number="$2"
	local field_name="$3"
	case "$value" in
		:*) SNAPSHOT_PARSED_VALUE="${value#:}" ;;
		*)
			snapshot_error "$record_number" \
				"legacy field $field_name is missing its prefix"
			return 1
			;;
	esac
}

snapshot_legacy_is_unsigned() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

snapshot_legacy_is_boolean() {
	case "$1" in
		0|1) return 0 ;;
		*) return 1 ;;
	esac
}

snapshot_legacy_is_shifted_pane() {
	[ "${#SNAPSHOT_FIELDS[@]}" -eq 11 ] || return 1
	case "${SNAPSHOT_FIELDS[6]}" in
		:*) ;;
		*) return 1 ;;
	esac
	snapshot_legacy_is_boolean "${SNAPSHOT_FIELDS[7]}" || return 1
	if snapshot_legacy_is_boolean "${SNAPSHOT_FIELDS[8]}"; then
		return 1
	fi
	snapshot_legacy_is_unsigned "${SNAPSHOT_FIELDS[9]}"
}

snapshot_import_legacy_pane() {
	local record_number="$1"
	local allow_recovery="$2"
	local warnings_file="$3"
	local title dir full_command

	snapshot_require_field_count 11 "$record_number" || return 1
	if snapshot_legacy_is_shifted_pane; then
		if [ "$allow_recovery" != "true" ]; then
			snapshot_error "$record_number" \
				"known empty-title field shift; run legacy audit/recovery"
			return 1
		fi
		snapshot_legacy_unprefix "${SNAPSHOT_FIELDS[6]}" \
			"$record_number" "pane_dir" || return 1
		dir="$SNAPSHOT_PARSED_VALUE"
		title=""
		snapshot_legacy_unprefix "${SNAPSHOT_FIELDS[10]}" \
			"$record_number" "pane_full_command" || return 1
		full_command="$SNAPSHOT_PARSED_VALUE"
		printf 'record %s: recovered empty pane title; dir=[%s]; ' \
			"$record_number" "$dir" >> "$warnings_file"
		printf 'active=[%s]; command=[%s]; discarded shifted pid=[%s]\n' \
			"${SNAPSHOT_FIELDS[7]}" "${SNAPSHOT_FIELDS[8]}" \
			"${SNAPSHOT_FIELDS[9]}" >> "$warnings_file"
		snapshot_write_pane \
			"${SNAPSHOT_FIELDS[1]}" "${SNAPSHOT_FIELDS[2]}" \
			"${SNAPSHOT_FIELDS[3]}" \
			"${SNAPSHOT_FIELDS[4]#:}" \
			"${SNAPSHOT_FIELDS[5]}" "$title" "$dir" \
			"${SNAPSHOT_FIELDS[7]}" "${SNAPSHOT_FIELDS[8]}" \
			"$full_command"
		return
	fi
	if ! snapshot_legacy_is_unsigned "${SNAPSHOT_FIELDS[2]}" ||
		! snapshot_legacy_is_boolean "${SNAPSHOT_FIELDS[3]}" ||
		! snapshot_legacy_is_unsigned "${SNAPSHOT_FIELDS[5]}" ||
		! snapshot_legacy_is_boolean "${SNAPSHOT_FIELDS[8]}"; then
		snapshot_error "$record_number" "invalid legacy pane number/boolean"
		return 1
	fi
	snapshot_legacy_unprefix "${SNAPSHOT_FIELDS[4]}" \
		"$record_number" "window_flags" || return 1
	local flags="$SNAPSHOT_PARSED_VALUE"
	snapshot_legacy_unprefix "${SNAPSHOT_FIELDS[7]}" \
		"$record_number" "pane_dir" || return 1
	dir="$SNAPSHOT_PARSED_VALUE"
	snapshot_legacy_unprefix "${SNAPSHOT_FIELDS[10]}" \
		"$record_number" "pane_full_command" || return 1
	full_command="$SNAPSHOT_PARSED_VALUE"
	snapshot_write_pane \
		"${SNAPSHOT_FIELDS[1]}" "${SNAPSHOT_FIELDS[2]}" \
		"${SNAPSHOT_FIELDS[3]}" "$flags" "${SNAPSHOT_FIELDS[5]}" \
		"${SNAPSHOT_FIELDS[6]}" "$dir" "${SNAPSHOT_FIELDS[8]}" \
		"${SNAPSHOT_FIELDS[9]}" "$full_command"
}

snapshot_import_legacy_window() {
	local record_number="$1"
	local name flags automatic_rename
	snapshot_require_field_count 8 "$record_number" || return 1
	if ! snapshot_legacy_is_unsigned "${SNAPSHOT_FIELDS[2]}" ||
		! snapshot_legacy_is_boolean "${SNAPSHOT_FIELDS[4]}"; then
		snapshot_error "$record_number" "invalid legacy window number/boolean"
		return 1
	fi
	snapshot_legacy_unprefix "${SNAPSHOT_FIELDS[3]}" \
		"$record_number" "window_name" || return 1
	name="$SNAPSHOT_PARSED_VALUE"
	snapshot_legacy_unprefix "${SNAPSHOT_FIELDS[5]}" \
		"$record_number" "window_flags" || return 1
	flags="$SNAPSHOT_PARSED_VALUE"
	automatic_rename="${SNAPSHOT_FIELDS[7]}"
	[ "$automatic_rename" = ":" ] && automatic_rename=""
	snapshot_write_window \
		"${SNAPSHOT_FIELDS[1]}" "${SNAPSHOT_FIELDS[2]}" "$name" \
		"${SNAPSHOT_FIELDS[4]}" "$flags" "${SNAPSHOT_FIELDS[6]}" \
		"$automatic_rename"
}

snapshot_import_legacy_state() {
	local record_number="$1"
	snapshot_require_field_count 3 "$record_number" || return 1
	snapshot_write_state "${SNAPSHOT_FIELDS[1]}" "${SNAPSHOT_FIELDS[2]}"
}

snapshot_import_legacy_group() {
	local record_number="$1"
	local alternate active
	snapshot_require_field_count 5 "$record_number" || return 1
	snapshot_legacy_unprefix "${SNAPSHOT_FIELDS[3]}" \
		"$record_number" "alternate_window_index" || return 1
	alternate="$SNAPSHOT_PARSED_VALUE"
	snapshot_legacy_unprefix "${SNAPSHOT_FIELDS[4]}" \
		"$record_number" "active_window_index" || return 1
	active="$SNAPSHOT_PARSED_VALUE"
	if [ -n "$alternate" ] && \
		! snapshot_legacy_is_unsigned "$alternate"; then
		snapshot_error "$record_number" "invalid alternate window index"
		return 1
	fi
	if [ -n "$active" ] && ! snapshot_legacy_is_unsigned "$active"; then
		snapshot_error "$record_number" "invalid active window index"
		return 1
	fi
	snapshot_write_grouped_session \
		"${SNAPSHOT_FIELDS[1]}" "${SNAPSHOT_FIELDS[2]}" \
		"$alternate" "$active"
}

snapshot_convert_legacy() {
	local input_file="$1"
	local output_file="$2"
	local warnings_file="$3"
	local allow_recovery="$4"
	local temp_file="${output_file}.tmp.$$"
	local line record_number=0 status=0

	: > "$warnings_file"
	if [ ! -f "$input_file" ]; then
		snapshot_error 0 "legacy snapshot not found: $input_file"
		return 1
	fi
	snapshot_write_header > "$temp_file"
	while IFS= read -r line || [ -n "$line" ]; do
		record_number=$((record_number + 1))
		snapshot_split_line "$line"
		case "${SNAPSHOT_FIELDS[0]-}" in
			pane)
				snapshot_import_legacy_pane "$record_number" \
					"$allow_recovery" "$warnings_file" \
					>> "$temp_file" || status=1
				;;
			window)
				snapshot_import_legacy_window "$record_number" \
					>> "$temp_file" || status=1
				;;
			state)
				snapshot_import_legacy_state "$record_number" \
					>> "$temp_file" || status=1
				;;
			grouped_session)
				snapshot_import_legacy_group "$record_number" \
					>> "$temp_file" || status=1
				;;
			*)
				snapshot_error "$record_number" \
					"unsupported legacy record type [${SNAPSHOT_FIELDS[0]-}]"
				status=1
				;;
		esac
		[ "$status" -eq 0 ] || break
	done < "$input_file"
	if [ "$record_number" -eq 0 ]; then
		snapshot_error 0 "legacy snapshot is empty"
		status=1
	fi
	if [ "$status" -eq 0 ]; then
		snapshot_validate_file "$temp_file" || status=1
	fi
	if [ "$status" -eq 0 ]; then
		mv -f "$temp_file" "$output_file"
	else
		rm -f "$temp_file"
	fi
	return "$status"
}

snapshot_import_legacy() {
	snapshot_convert_legacy "$1" "$2" "$3" "false"
}

snapshot_recover_legacy() {
	snapshot_convert_legacy "$1" "$2" "$3" "true"
}

snapshot_publish_file() {
	local candidate_file="$1"
	local final_file="$2"
	local last_file="$3"
	local final_dir last_dir link_temp

	snapshot_validate_file "$candidate_file" || return 1
	final_dir="$(cd "$(dirname "$final_file")" && pwd -P)" || return 1
	last_dir="$(cd "$(dirname "$last_file")" && pwd -P)" || return 1
	if [ "$final_dir" != "$last_dir" ]; then
		snapshot_error 0 "snapshot and last link must share a directory"
		return 1
	fi
	mv -f "$candidate_file" "$final_file" || return 1
	sync
	link_temp="${last_file}.tmp.$$"
	rm -f "$link_temp"
	if ! ln -s "$(basename "$final_file")" "$link_temp"; then
		return 1
	fi
	if ! mv -f "$link_temp" "$last_file"; then
		rm -f "$link_temp"
		return 1
	fi
	sync
}
