#!/bin/bash
# PreserveStyle round trips through XmlTester (docs/plan.md §4.9, §6 phase 5):
#   - every accepted case of the W3C suite's selection (the valid and invalid cases of
#     test-xml-conformance.sh) and every corpus SVG, read with PreserveStyle and written back
#     (XmlTester -roundtrip, in the document's own encoding), must equal the input byte for byte, from
#     memory and through a 16-byte stream buffer;
#   - random edits of each (XmlTester -mutate SEED for SEEDS seeds, 3 by default) must be written so
#     that the text reads back into the edited document.
# Usage: ./test-roundtrip.sh            (Debug binary)
#        BIN=./build/Release_Linux64/XmlTester/XmlTester ./test-roundtrip.sh
#        SEEDS=0 ./test-roundtrip.sh   (byte-exact round trips only)
# Details go to test-roundtrip.log. Fetch the suites first with tests/fetch-suites.sh; needs python3.

BIN="${BIN:-./build/Debug_Linux64/XmlTester/XmlTester}"
SUITE="${SUITE:-tests/suites/xmlconf}"
SUITES="tests/suites"
SKIP="tests/xmlconf/skip.txt"
SEEDS="${SEEDS:-3}"
LOGFILE="test-roundtrip.log"

if [ ! -x "$BIN" ]; then
	echo "ERROR: $BIN not found or not executable. Build first with: beefbuild"
	exit 1
fi
if [ ! -f "$SUITE/xmlconf.xml" ] || [ ! -d "$SUITES/svg11" ] || [ ! -d "$SUITES/resvg" ]; then
	echo "ERROR: the suites are missing. Fetch them with: tests/fetch-suites.sh"
	exit 1
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

if ! python3 tests/xmlconf/manifest.py "$SUITE/xmlconf.xml" > "$tmpdir/manifest.tsv"; then
	echo "ERROR: reading the catalogs failed"
	exit 1
fi
# A separator that is not whitespace, so empty fields are kept
awk -F'\t' -v OFS=$'\x1f' '{ $1 = $1; print }' "$tmpdir/manifest.tsv" > "$tmpdir/manifest"
declare -A skip_reason
if [ -f "$SKIP" ]; then
	while IFS=$'\t' read -r id reason; do
		[[ -z "$id" || "$id" == \#* ]] && continue
		skip_reason[$id]="$reason"
	done < "$SKIP"
fi

# The inputs: "path<TAB>flags" (the suite's NAMESPACE="no" cases are read with -no-ns)
: > "$tmpdir/inputs"
suite_count=0
while IFS=$'\x1f' read -r id type entities namespace rec version edition uri output; do
	[ "$type" = valid ] || [ "$type" = invalid ] || continue
	if [ "$rec" = XML1.1 ] || [ "$rec" = NS1.1 ] || { [ -n "$version" ] && [[ " $version " != *" 1.0 "* ]]; }; then
		continue
	fi
	[ -n "$edition" ] && [[ " $edition " != *" 5 "* ]] && continue
	[ -n "${skip_reason[$id]+x}" ] && continue
	flags=""
	[ "$namespace" = no ] && flags="-no-ns"
	printf '%s\t%s\n' "$uri" "$flags" >> "$tmpdir/inputs"
	suite_count=$((suite_count + 1))
done < "$tmpdir/manifest"
corpus_count=0
while IFS= read -r -d '' file; do
	printf '%s\t\n' "$file" >> "$tmpdir/inputs"
	corpus_count=$((corpus_count + 1))
done < <(find "$SUITES/svg11" "$SUITES/resvg" -name '*.svg' -not -path '*/.git/*' -print0 | sort -z)

{
	echo "=== PreserveStyle round-trip log ==="
	echo "Date: $(date)"
	echo "Binary: $BIN"
	echo ""
} > "$LOGFILE"

total=0
exact=0
streamed=0
mutated=0
mutations=0
crashes=0
failures=()
while IFS=$'\t' read -r file flags; do
	total=$((total + 1))
	ok=1
	timeout 10 "$BIN" $flags -roundtrip "$tmpdir/out" "$file" 2> "$tmpdir/err"
	status=$?
	if [ $status -eq 0 ] && cmp -s "$file" "$tmpdir/out"; then
		exact=$((exact + 1))
	else
		ok=0
		[ $status -gt 2 ] && crashes=$((crashes + 1))
		echo "--- NOT BYTE-EXACT (exit $status): $file $(head -1 "$tmpdir/err")" >> "$LOGFILE"
	fi
	rm -f "$tmpdir/out"
	timeout 10 "$BIN" $flags -stream 16 -roundtrip "$tmpdir/out" "$file" 2> "$tmpdir/err"
	status=$?
	if [ $status -eq 0 ] && cmp -s "$file" "$tmpdir/out"; then
		streamed=$((streamed + 1))
	else
		ok=0
		[ $status -gt 2 ] && crashes=$((crashes + 1))
		echo "--- NOT BYTE-EXACT FROM A STREAM (exit $status): $file $(head -1 "$tmpdir/err")" >> "$LOGFILE"
	fi
	rm -f "$tmpdir/out"
	for ((seed = 1; seed <= SEEDS; seed++)); do
		mutations=$((mutations + 1))
		timeout 10 "$BIN" $flags -mutate $seed "$file" > /dev/null 2> "$tmpdir/err"
		status=$?
		if [ $status -eq 0 ]; then
			mutated=$((mutated + 1))
		else
			ok=0
			[ $status -ne 3 ] && [ $status -ne 4 ] && crashes=$((crashes + 1))
			{
				echo "--- EDITS NOT KEPT (seed $seed, exit $status): $file"
				head -60 "$tmpdir/err"
			} >> "$LOGFILE"
		fi
	done
	[ $ok -eq 0 ] && failures+=("$file")
done < "$tmpdir/inputs"

echo "Inputs: $total ($suite_count accepted suite cases, $corpus_count corpus SVGs)"
echo "Byte-exact from memory: $exact/$total"
echo "Byte-exact from a 16-byte stream: $streamed/$total"
echo "Random edits kept: $mutated/$mutations ($SEEDS seeds each)"
failed=0
if [ $crashes -gt 0 ]; then
	echo "crashes: $crashes"
	failed=1
fi
if [ ${#failures[@]} -gt 0 ]; then
	echo "failures (${#failures[@]}): ${failures[*]:0:10}$([ ${#failures[@]} -gt 10 ] && echo ' ...')"
	failed=1
fi
if [ $failed -ne 0 ]; then
	echo "FAIL: see $LOGFILE"
	exit 1
fi
echo "PASS"
