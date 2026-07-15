#!/usr/bin/env bash

set -u

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=snapshot_format.sh
source "$CURRENT_DIR/snapshot_format.sh"

usage() {
	printf 'Usage: %s [--repair OUTPUT] SNAPSHOT\n' "$0" >&2
}

parse_args() {
	REPAIR_OUTPUT=""
	case "$#" in
		1) INPUT_FILE="$1" ;;
		3)
			if [ "$1" != "--repair" ]; then
				usage
				return 2
			fi
			REPAIR_OUTPUT="$2"
			INPUT_FILE="$3"
			;;
		*)
			usage
			return 2
			;;
	esac
}

canonical_parent() {
	local path="$1"
	local parent
	parent="$(dirname "$path")"
	(cd "$parent" && pwd -P)
}

assert_separate_output() {
	local input_parent output_parent
	[ -n "$REPAIR_OUTPUT" ] || return 0
	if [ -e "$REPAIR_OUTPUT" ] || [ -L "$REPAIR_OUTPUT" ]; then
		printf 'Refusing to replace existing output: %s\n' \
			"$REPAIR_OUTPUT" >&2
		return 1
	fi
	input_parent="$(canonical_parent "$INPUT_FILE")" || return 1
	output_parent="$(canonical_parent "$REPAIR_OUTPUT")" || return 1
	if [ "$input_parent/$(basename "$INPUT_FILE")" = \
		"$output_parent/$(basename "$REPAIR_OUTPUT")" ]; then
		printf 'Repair output must differ from the source snapshot\n' >&2
		return 1
	fi
}

audit_v2() {
	if [ -n "$REPAIR_OUTPUT" ]; then
		printf 'Snapshot is already v2; no repair artifact was written\n' >&2
		return 1
	fi
	snapshot_validate_file "$INPUT_FILE" || return 1
	printf 'Valid tmux-resurrect v2 snapshot: %s\n' "$INPUT_FILE"
}

audit_legacy() {
	local output_file="$1"
	local warnings_file="$2"
	snapshot_recover_legacy \
		"$INPUT_FILE" "$output_file" "$warnings_file" || return 1
	if [ -s "$warnings_file" ]; then
		printf 'Legacy corruption detected and recoverable:\n'
		while IFS= read -r warning; do
			printf '  %s\n' "$warning"
		done < "$warnings_file"
	else
		printf 'Legacy snapshot is structurally valid; no shift detected\n'
	fi
}

main() {
	local temp_dir audit_output warnings_file
	parse_args "$@" || return $?
	if [ ! -f "$INPUT_FILE" ]; then
		printf 'Snapshot not found: %s\n' "$INPUT_FILE" >&2
		return 1
	fi
	assert_separate_output || return 1
	if IFS= read -r first_line < "$INPUT_FILE" &&
		[ "$first_line" = \
		"${SNAPSHOT_FORMAT_NAME}${SNAPSHOT_RECORD_SEPARATOR}${SNAPSHOT_FORMAT_VERSION}" ]; then
		audit_v2
		return
	fi
	temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/resurrect-audit.XXXXXX")"
	warnings_file="$temp_dir/warnings.txt"
	if [ -n "$REPAIR_OUTPUT" ]; then
		audit_output="$REPAIR_OUTPUT"
	else
		audit_output="$temp_dir/repaired.txt"
	fi
	if ! audit_legacy "$audit_output" "$warnings_file"; then
		rm -rf "$temp_dir"
		return 1
	fi
	if [ -n "$REPAIR_OUTPUT" ]; then
		printf 'Wrote validated repaired artifact: %s\n' "$REPAIR_OUTPUT"
	else
		printf 'Dry run only; source snapshot was not modified\n'
	fi
	rm -rf "$temp_dir"
}

main "$@"
