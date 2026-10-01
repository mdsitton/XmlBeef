#!/bin/bash
# Collect-errors under random damage (XmlReadConfig.CollectErrors; docs/plan.md §6 phase 7): every case
# of the W3C suite's selection (valid, invalid, not-wf and error alike) and every corpus SVG, mutated
# ROUNDS times per seed for SEEDS seeds (XmlTester -fuzz: deleted bytes, inserted markup characters,
# duplicated slices), read from memory and through a 16-byte stream. Each read must finish (a timeout
# or a crash is a failure) and the two must agree: the same errors and the same document.
# Usage: ./test-collect.sh                       (Debug binary; SEEDS=2 ROUNDS=10)
#        BIN=./build/Release_Linux64/XmlTester/XmlTester ./test-collect.sh
# Details go to test-collect.log. Fetch the suites first with tests/fetch-suites.sh; needs python3.

BIN="${BIN:-./build/Debug_Linux64/XmlTester/XmlTester}"
SUITE="${SUITE:-tests/suites/xmlconf}"
SUITES="tests/suites"
SEEDS="${SEEDS:-2}"
ROUNDS="${ROUNDS:-10}"
LOGFILE="test-collect.log"

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
awk -F'\t' -v OFS=$'\x1f' '{ $1 = $1; print }' "$tmpdir/manifest.tsv" > "$tmpdir/manifest"

# The inputs: "path<TAB>flags"
: > "$tmpdir/inputs"
while IFS=$'\x1f' read -r id type entities namespace rec version edition uri output; do
	if [ "$rec" = XML1.1 ] || [ "$rec" = NS1.1 ] || { [ -n "$version" ] && [[ " $version " != *" 1.0 "* ]]; }; then
		continue
	fi
	[ -n "$edition" ] && [[ " $edition " != *" 5 "* ]] && continue
	flags=""
	[ "$namespace" = no ] && flags="-no-ns"
	printf '%s\t%s\n' "$uri" "$flags" >> "$tmpdir/inputs"
done < "$tmpdir/manifest"
while IFS= read -r -d '' file; do
	printf '%s\t\n' "$file" >> "$tmpdir/inputs"
done < <(find "$SUITES/svg11" "$SUITES/resvg" -name '*.svg' -not -path '*/.git/*' -print0 | sort -z)

{
	echo "=== Collect-errors fuzz log ==="
	echo "Date: $(date)"
	echo "Binary: $BIN (SEEDS=$SEEDS ROUNDS=$ROUNDS)"
	echo ""
} > "$LOGFILE"

total=0
passed=0
crashes=0
hangs=0
differ=0
while IFS=$'\t' read -r file flags; do
	for ((seed = 1; seed <= SEEDS; seed++)); do
		total=$((total + 1))
		timeout 20 "$BIN" $flags -fuzz $seed "$ROUNDS" "$file" > /dev/null 2> "$tmpdir/err"
		status=$?
		case $status in
		0) passed=$((passed + 1)) ;;
		4)
			differ=$((differ + 1))
			{ echo "--- MEMORY AND STREAM DIFFER (seed $seed): $file"; head -40 "$tmpdir/err"; } >> "$LOGFILE"
			;;
		124)
			hangs=$((hangs + 1))
			echo "--- TIMEOUT (seed $seed): $file" >> "$LOGFILE"
			;;
		*)
			crashes=$((crashes + 1))
			{ echo "--- CRASH (exit $status, seed $seed): $file"; head -20 "$tmpdir/err"; } >> "$LOGFILE"
			;;
		esac
	done
done < "$tmpdir/inputs"

echo "Fuzzed reads: $passed/$total runs of $ROUNDS mutations pass (crashes $crashes, timeouts $hangs, memory/stream differences $differ)"
if [ $passed -ne $total ]; then
	echo "FAIL: see $LOGFILE"
	exit 1
fi
echo "PASS"
