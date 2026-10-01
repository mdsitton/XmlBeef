#!/bin/bash
# SVG corpora through XmlTester: every *.svg under tests/suites/svg11 and tests/suites/resvg must be
# well-formed with namespaces on and no external entities (docs/test-suites.md §7.1, §9.3).
# Usage: ./test-svg-corpus.sh            (Debug binary)
#        BIN=./build/Release_Linux64/XmlTester/XmlTester ./test-svg-corpus.sh
#
# Per file: the document read must succeed; the reader's events must give the same suite form as the
# document; the canonical writer must keep it (XmlTester -rewrite) and be a fixed point (writing the
# written document again changes nothing). tests/corpus/expected-failures.txt lists deliberate
# exceptions (path under tests/suites<TAB>reason); a listed file that passes fails the run. Details go
# to test-svg-corpus.log. `*.svgz` files are gzip and skipped.
#
# Fetch the corpora first with tests/fetch-suites.sh.

BIN="${BIN:-./build/Debug_Linux64/XmlTester/XmlTester}"
SUITES="tests/suites"
EXPECTED="tests/corpus/expected-failures.txt"
LOGFILE="test-svg-corpus.log"

if [ ! -x "$BIN" ]; then
	echo "ERROR: $BIN not found or not executable. Build first with: beefbuild"
	exit 1
fi
if [ ! -d "$SUITES/svg11" ] || [ ! -d "$SUITES/resvg" ]; then
	echo "ERROR: $SUITES/svg11 or $SUITES/resvg not found. Fetch the corpora with: tests/fetch-suites.sh"
	exit 1
fi

declare -A expected_reason
if [ -f "$EXPECTED" ]; then
	while IFS=$'\t' read -r path reason; do
		[[ -z "$path" || "$path" == \#* ]] && continue
		expected_reason[$path]="$reason"
	done < "$EXPECTED"
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

{
	echo "=== SVG corpus log ==="
	echo "Date: $(date)"
	echo "Binary: $BIN"
	echo ""
} > "$LOGFILE"

total=0
passed=0
crashes=0
unexpected=()
fixed=()
while IFS= read -r -d '' file; do
	total=$((total + 1))
	key="${file#$SUITES/}"
	why=""
	timeout 10 "$BIN" "$file" > "$tmpdir/document" 2> "$tmpdir/err"
	status=$?
	if [ $status -ne 0 ]; then
		[ $status -gt 1 ] && crashes=$((crashes + 1))
		why="REJECTED (exit $status): $(head -1 "$tmpdir/err")"
	else
		timeout 10 "$BIN" -events "$file" > "$tmpdir/events" 2>&1
		timeout 10 "$BIN" -rewrite "$file" > "$tmpdir/rewrite" 2>&1
		status=$?
		timeout 10 "$BIN" -write "$file" > "$tmpdir/written" 2>&1
		timeout 10 "$BIN" -write "$tmpdir/written" > "$tmpdir/written2" 2>&1
		if [ $status -gt 1 ]; then
			[ $status -gt 3 ] && crashes=$((crashes + 1))
			why="REWRITE FAILED (exit $status)"
		elif ! cmp -s "$tmpdir/document" "$tmpdir/events"; then
			why="EVENTS DIFFER FROM THE DOCUMENT"
		elif ! cmp -s "$tmpdir/document" "$tmpdir/rewrite"; then
			why="REWRITE CHANGED THE CONTENT"
		elif ! cmp -s "$tmpdir/written" "$tmpdir/written2"; then
			why="CANONICAL FORM IS NOT A FIXED POINT"
		fi
	fi
	if [ -z "$why" ]; then
		passed=$((passed + 1))
		if [ -n "${expected_reason[$key]+x}" ]; then
			fixed+=("$key")
			echo "--- listed in $EXPECTED but passes: $key" >> "$LOGFILE"
		fi
	elif [ -n "${expected_reason[$key]+x}" ]; then
		echo "--- expected failure: $key: $why" >> "$LOGFILE"
	else
		unexpected+=("$key")
		echo "--- $why: $key" >> "$LOGFILE"
	fi
done < <(find "$SUITES/svg11" "$SUITES/resvg" -name '*.svg' -not -path '*/.git/*' -print0 | sort -z)

echo "SVG corpus: $passed/$total files pass (document, events, rewrite, fixed point)"
failed=0
if [ $crashes -gt 0 ]; then
	echo "crashes: $crashes"
	failed=1
fi
if [ ${#unexpected[@]} -gt 0 ]; then
	echo "unexpected failures (${#unexpected[@]}): ${unexpected[*]:0:10}$([ ${#unexpected[@]} -gt 10 ] && echo ' ...')"
	failed=1
fi
if [ ${#fixed[@]} -gt 0 ]; then
	echo "listed in $EXPECTED but passing (remove them): ${fixed[*]}"
	failed=1
fi
if [ $failed -ne 0 ]; then
	echo "FAIL: see $LOGFILE"
	exit 1
fi
echo "PASS"
