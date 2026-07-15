#!/usr/bin/env bash

set -u

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$CURRENT_DIR/.." && pwd)"

# shellcheck source=../scripts/snapshot_format.sh
source "$ROOT_DIR/scripts/snapshot_format.sh"

TEST_COUNT=0
FAILURE_COUNT=0

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	FAILURE_COUNT=$((FAILURE_COUNT + 1))
}

assert_equal() {
	local expected="$1"
	local actual="$2"
	local message="$3"
	TEST_COUNT=$((TEST_COUNT + 1))
	if [ "$expected" != "$actual" ]; then
		fail "$message: expected [$expected], got [$actual]"
	fi
}

assert_file_contains() {
	local file="$1"
	local expected="$2"
	local message="$3"
	TEST_COUNT=$((TEST_COUNT + 1))
	if ! grep -Fq "$expected" "$file"; then
		fail "$message: missing [$expected]"
	fi
}

assert_success() {
	local message="$1"
	shift
	TEST_COUNT=$((TEST_COUNT + 1))
	if ! "$@"; then
		fail "$message"
	fi
}

assert_failure() {
	local message="$1"
	shift
	TEST_COUNT=$((TEST_COUNT + 1))
	if "$@"; then
		fail "$message"
	fi
}

capture_record() {
	if [ "$SNAPSHOT_RECORD_TYPE" = "grouped_session" ]; then
		CAPTURED_GROUP_SESSION="$SNAPSHOT_SESSION_NAME"
		CAPTURED_GROUP_ORIGINAL="$SNAPSHOT_ORIGINAL_SESSION_NAME"
		CAPTURED_GROUP_ALTERNATE="$SNAPSHOT_ALTERNATE_WINDOW_INDEX"
		CAPTURED_GROUP_ACTIVE="$SNAPSHOT_ACTIVE_WINDOW_INDEX"
		return 0
	fi
	if [ "$SNAPSHOT_RECORD_TYPE" != "pane" ]; then
		return 0
	fi
	CAPTURED_TYPE="$SNAPSHOT_RECORD_TYPE"
	CAPTURED_SESSION="$SNAPSHOT_SESSION_NAME"
	CAPTURED_TITLE="${SNAPSHOT_PANE_TITLE-}"
	CAPTURED_DIR="${SNAPSHOT_PANE_DIR-}"
	CAPTURED_COMMAND="${SNAPSHOT_PANE_COMMAND-}"
}

write_complete_snapshot() {
	local file="$1"
	local title="$2"
	local dir="$3"
	local command="$4"
	{
		snapshot_write_header
		snapshot_write_pane \
			"alpha" "7" "1" "*" "3" "$title" \
			"$dir" "1" "$command" ""
		snapshot_write_window \
			"alpha" "7" "main" "1" "*" \
			"layout-value" ""
		snapshot_write_state "alpha" ""
	} > "$file"
}

test_round_trip_arbitrary_strings() {
	local temp_dir file title dir command
	temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/resurrect-format.XXXXXX")"
	file="$temp_dir/snapshot"
	title=$'colon: tab\t Unicode ✓\ntrailing\n'
	dir='$HOME/a path/$(touch should-not-run);[x]'
	command=$'printf "hello"\nnext'

	write_complete_snapshot "$file" "$title" "$dir" "$command"
	assert_success "arbitrary strings should validate" \
		snapshot_validate_file "$file"
	assert_success "arbitrary strings should parse" \
		snapshot_parse_file "$file" capture_record
	assert_equal "pane" "$CAPTURED_TYPE" "pane type round trip"
	assert_equal "alpha" "$CAPTURED_SESSION" "session round trip"
	assert_equal "$title" "$CAPTURED_TITLE" "title round trip"
	assert_equal "$dir" "$CAPTURED_DIR" "directory round trip"
	assert_equal "$command" "$CAPTURED_COMMAND" "command round trip"

	rm -rf "$temp_dir"
}

test_empty_optional_fields() {
	local temp_dir file
	temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/resurrect-empty.XXXXXX")"
	file="$temp_dir/snapshot"
	write_complete_snapshot "$file" "" "/tmp" ""
	assert_success "empty optional fields should validate" \
		snapshot_validate_file "$file"
	assert_success "empty optional fields should parse" \
		snapshot_parse_file "$file" capture_record
	assert_equal "" "$CAPTURED_TITLE" "empty title round trip"
	assert_equal "" "$CAPTURED_COMMAND" "empty command round trip"
	rm -rf "$temp_dir"
}

test_grouped_session_nullable_fields() {
	local temp_dir file
	temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/resurrect-group.XXXXXX")"
	file="$temp_dir/snapshot"
	{
		snapshot_write_header
		snapshot_write_pane \
			"alpha" "0" "1" "*" "0" "" \
			"/tmp" "1" "bash" ""
		snapshot_write_window \
			"alpha" "0" "main" "1" "*" "layout" ""
		snapshot_write_grouped_session "beta" "alpha" "" "0"
		snapshot_write_state "beta" "alpha"
	} > "$file"
	assert_success "grouped session fields should validate" \
		snapshot_validate_file "$file"
	assert_success "grouped session fields should parse" \
		snapshot_parse_file "$file" capture_record
	assert_equal "beta" "$CAPTURED_GROUP_SESSION" \
		"grouped session name"
	assert_equal "alpha" "$CAPTURED_GROUP_ORIGINAL" \
		"grouped original name"
	assert_equal "" "$CAPTURED_GROUP_ALTERNATE" \
		"nullable alternate window"
	assert_equal "0" "$CAPTURED_GROUP_ACTIVE" \
		"zero active window is not null"
	rm -rf "$temp_dir"
}

test_malformed_records_are_rejected() {
	local temp_dir truncated unknown bad_version bad_base64
	temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/resurrect-bad.XXXXXX")"
	truncated="$temp_dir/truncated"
	unknown="$temp_dir/unknown"
	bad_version="$temp_dir/version"
	bad_base64="$temp_dir/base64"

	printf 'tmux-resurrect\t2\nrecord\t2\tpane\n' > "$truncated"
	printf 'tmux-resurrect\t2\nrecord\t2\tfuture\n' > "$unknown"
	printf 'tmux-resurrect\t99\n' > "$bad_version"
	printf '%s\n' \
		'tmux-resurrect	2' \
		'record	2	state	session_name=s:***	last_session_name=s:' \
		> "$bad_base64"

	assert_failure "truncated record must fail" \
		snapshot_validate_file "$truncated"
	assert_failure "unknown record type must fail" \
		snapshot_validate_file "$unknown"
	assert_failure "unknown format version must fail" \
		snapshot_validate_file "$bad_version"
	assert_failure "malformed Base64 must fail" \
		snapshot_validate_file "$bad_base64"
	rm -rf "$temp_dir"
}

test_cross_wired_identity_is_rejected() {
	local temp_dir file
	temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/resurrect-binding.XXXXXX")"
	file="$temp_dir/snapshot"
	{
		snapshot_write_header
		snapshot_write_pane \
			"pane-session" "4" "1" "*" "0" "" \
			"/tmp" "1" "bash" ""
		snapshot_write_window \
			"different-session" "9" "main" "1" "*" \
			"layout" ""
		snapshot_write_state "different-session" ""
	} > "$file"
	assert_failure "pane/window identity mismatch must fail" \
		snapshot_validate_file "$file"
	rm -rf "$temp_dir"
}

write_valid_legacy_snapshot() {
	local file="$1"
	printf '%s\n' \
		$'pane\talpha\t0\t1\t:*\t0\ttitle\t:/tmp/a\\ path\t1\tbash\t:' \
		$'window\talpha\t0\t:main\t1\t:*\tlayout\t:' \
		$'state\talpha\t' > "$file"
}

write_shifted_legacy_snapshot() {
	local file="$1"
	printf '%s\n' \
		$'pane\talpha\t0\t1\t:*\t0\t:/tmp/intended\t1\tbash\t1234\t:' \
		$'window\talpha\t0\t:main\t1\t:*\tlayout\t:' \
		$'state\talpha\t' > "$file"
}

test_legacy_import_and_shift_recovery() {
	local temp_dir valid shifted converted repaired warnings
	temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/resurrect-legacy.XXXXXX")"
	valid="$temp_dir/valid"
	shifted="$temp_dir/shifted"
	converted="$temp_dir/converted"
	repaired="$temp_dir/repaired"
	warnings="$temp_dir/warnings"
	write_valid_legacy_snapshot "$valid"
	write_shifted_legacy_snapshot "$shifted"

	assert_success "valid legacy snapshot should import" \
		snapshot_import_legacy "$valid" "$converted" "$warnings"
	assert_success "converted legacy snapshot should validate" \
		snapshot_validate_file "$converted"
	assert_failure "shifted legacy snapshot must not import silently" \
		snapshot_import_legacy "$shifted" "$converted" "$warnings"
	assert_success "explicit recovery should write a separate artifact" \
		snapshot_recover_legacy "$shifted" "$repaired" "$warnings"
	assert_success "recovered artifact should validate" \
		snapshot_validate_file "$repaired"
	assert_file_contains "$warnings" \
		"record 1: recovered empty pane title" \
		"shift recovery warning"
	assert_file_contains "$warnings" "/tmp/intended" \
		"shift recovery proposed directory"
	assert_file_contains "$shifted" $'\t1234\t:' \
		"source legacy snapshot remains unchanged"
	rm -rf "$temp_dir"
}

test_failed_publish_preserves_last() {
	local temp_dir previous candidate last target
	temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/resurrect-publish.XXXXXX")"
	previous="$temp_dir/previous.txt"
	candidate="$temp_dir/candidate.tmp"
	last="$temp_dir/last"
	write_complete_snapshot "$previous" "old" "/old" "bash"
	printf 'tmux-resurrect\t2\nrecord\t2\tpane\n' > "$candidate"
	ln -s "$(basename "$previous")" "$last"

	assert_failure "invalid candidate must not publish" \
		snapshot_publish_file "$candidate" \
		"$temp_dir/new.txt" "$last"
	target="$(readlink "$last")"
	assert_equal "previous.txt" "$target" \
		"failed publication must preserve last"
	assert_success "previous snapshot remains valid" \
		snapshot_validate_file "$previous"
	rm -rf "$temp_dir"
}

main() {
	test_round_trip_arbitrary_strings
	test_empty_optional_fields
	test_grouped_session_nullable_fields
	test_malformed_records_are_rejected
	test_cross_wired_identity_is_rejected
	test_legacy_import_and_shift_recovery
	test_failed_publish_preserves_last
	printf '%s assertions, %s failures\n' \
		"$TEST_COUNT" "$FAILURE_COUNT"
	[ "$FAILURE_COUNT" -eq 0 ]
}

main "$@"
