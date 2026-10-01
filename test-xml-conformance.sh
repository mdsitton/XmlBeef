#!/bin/bash
# W3C XML Conformance Test Suite (20130923) through XmlTester: the XML 1.0 Fifth Edition + Namespaces
# 1.0 selection, without reading external entities (docs/test-suites.md §5.3 column A, §6, §9.2).
# Usage: ./test-xml-conformance.sh            (Debug binary)
#        BIN=./build/Release_Linux64/XmlTester/XmlTester ./test-xml-conformance.sh
#
# Selection: XML 1.1 / NS 1.1 cases and other editions are skipped; NAMESPACE="no" cases run with
# -no-ns; tests/xmlconf/skip.txt lists deliberate skips (ID<TAB>reason). Judging by TYPE:
#   valid, invalid  must be accepted (exit 0); with an OUTPUT and ENTITIES="none", stdout must equal the
#                   OUTPUT file byte for byte (the canonical form, docs/test-suites.md §4)
#   not-wf          must be rejected (exit 1); with ENTITIES other than "none" the error may be in an
#                   external entity that is not read, so acceptance is tolerated (counted separately)
#   error           logged only
# A crash (exit other than 0 or 1) or a timeout is always a failure. Failures are compared with
# tests/xmlconf/expected-failures.txt (ID<TAB>reason): an unlisted failure fails the run, and so does a
# listed case that passes (remove it from the list). UPDATE_EXPECTED=1 rewrites the list's IDs from
# the current failures (keeping known reasons) for review. Details go to test-xml-conformance.log.
#
# MODES="events" selects the reading modes (events: XmlCanonical over XmlReader's events; document
# and stream modes join in later phases).
#
# Fetch the suite first with tests/fetch-suites.sh. Needs python3 (tests/xmlconf/manifest.py reads the
# catalogs until XmlBeef reads external entities itself).

BIN="${BIN:-./build/Debug_Linux64/XmlTester/XmlTester}"
SUITE="${SUITE:-tests/suites/xmlconf}"
SKIP="tests/xmlconf/skip.txt"
EXPECTED="tests/xmlconf/expected-failures.txt"
LOGFILE="test-xml-conformance.log"

if [ ! -x "$BIN" ]; then
	echo "ERROR: $BIN not found or not executable. Build first with: beefbuild"
	exit 1
fi
if [ ! -f "$SUITE/xmlconf.xml" ]; then
	echo "ERROR: $SUITE/xmlconf.xml not found. Fetch the suites with: tests/fetch-suites.sh"
	exit 1
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# The manifest, fields separated by 0x1F so that empty ones survive `read`
if ! python3 tests/xmlconf/manifest.py "$SUITE/xmlconf.xml" > "$tmpdir/manifest.tsv"; then
	echo "ERROR: reading the catalogs failed"
	exit 1
fi
awk -F'\t' -v OFS=$'\x1f' '{ $1 = $1; print }' "$tmpdir/manifest.tsv" > "$tmpdir/manifest"

declare -A skip_reason
if [ -f "$SKIP" ]; then
	while IFS=$'\t' read -r id reason; do
		[[ -z "$id" || "$id" == \#* ]] && continue
		skip_reason[$id]="$reason"
	done < "$SKIP"
fi
declare -A expected_reason
if [ -f "$EXPECTED" ]; then
	while IFS=$'\t' read -r id reason; do
		[[ -z "$id" || "$id" == \#* ]] && continue
		expected_reason[$id]="$reason"
	done < "$EXPECTED"
fi

{
	echo "=== W3C XML conformance suite log ==="
	echo "Date: $(date)"
	echo "Binary: $BIN"
	echo "Suite: $SUITE"
	echo ""
} > "$LOGFILE"

failed=0
declare -A failures
for mode in ${MODES:-events}; do
	flag=""
	[ "$mode" = events ] && flag="-events"

	accept_pass=0; accept_total=0
	reject_pass=0; reject_total=0
	canon_pass=0; canon_total=0
	ext_tolerated=0; ext_rejected=0
	error_accepted=0; error_rejected=0
	crashes=0
	skip_version=0; skip_edition=0; skip_listed=0
	nons=0
	unexpected=()
	fixed=()

	while IFS=$'\x1f' read -r id type entities namespace rec version edition uri output; do
		# Selection (docs/test-suites.md §6.1)
		if [ "$rec" = XML1.1 ] || [ "$rec" = NS1.1 ] || { [ -n "$version" ] && [[ " $version " != *" 1.0 "* ]]; }; then
			skip_version=$((skip_version + 1))
			continue
		fi
		if [ -n "$edition" ] && [[ " $edition " != *" 5 "* ]]; then
			skip_edition=$((skip_edition + 1))
			continue
		fi
		if [ -n "${skip_reason[$id]+x}" ]; then
			skip_listed=$((skip_listed + 1))
			continue
		fi
		if [ ! -f "$uri" ]; then
			echo "ERROR: $id: $uri does not exist"
			exit 1
		fi
		nsflag=""
		if [ "$namespace" = no ]; then
			nsflag="-no-ns"
			nons=$((nons + 1))
		fi

		timeout 10 "$BIN" $flag $nsflag -canonical "$uri" > "$tmpdir/out" 2> "$tmpdir/err"
		status=$?
		ok=1
		why=""
		if [ $status -gt 1 ]; then
			crashes=$((crashes + 1))
			ok=0
			why="CRASH ($status)"
		fi

		case "$type" in
		valid|invalid)
			accept_total=$((accept_total + 1))
			if [ $status -eq 0 ]; then
				accept_pass=$((accept_pass + 1))
				if [ -n "$output" ] && [ "$entities" = none ]; then
					canon_total=$((canon_total + 1))
					if cmp -s "$tmpdir/out" "$output"; then
						canon_pass=$((canon_pass + 1))
					else
						ok=0
						why="CANONICAL MISMATCH"
					fi
				fi
			elif [ $ok -eq 1 ]; then
				ok=0
				why="REJECTED ($type)"
			fi
			;;
		not-wf)
			if [ "$entities" != none ]; then
				if [ $status -eq 0 ]; then
					ext_tolerated=$((ext_tolerated + 1))
				elif [ $status -eq 1 ]; then
					ext_rejected=$((ext_rejected + 1))
				fi
			else
				reject_total=$((reject_total + 1))
				if [ $status -eq 1 ]; then
					reject_pass=$((reject_pass + 1))
				elif [ $ok -eq 1 ]; then
					ok=0
					why="ACCEPTED (not-wf)"
				fi
			fi
			;;
		error)
			if [ $status -eq 0 ]; then
				error_accepted=$((error_accepted + 1))
			elif [ $status -eq 1 ]; then
				error_rejected=$((error_rejected + 1))
			fi
			echo "error case $id [$mode]: exit $status $(head -c 200 "$tmpdir/err")" >> "$LOGFILE"
			;;
		esac

		if [ $ok -eq 0 ]; then
			failures[$id]=1
			if [ -n "${expected_reason[$id]+x}" ]; then
				echo "--- expected failure: $id [$mode]: $why" >> "$LOGFILE"
			else
				unexpected+=("$id")
				{
					echo "--- $why: $id [$mode] ($type, ENTITIES=$entities, NAMESPACE=$namespace) $uri ---"
					head -c 2000 "$uri"
					echo ""
					echo "stderr: $(head -c 500 "$tmpdir/err")"
					if [ "$why" = "CANONICAL MISMATCH" ]; then
						echo "Expected ($output):"
						head -c 2000 "$output"
						echo ""
						echo "Actual:"
						head -c 2000 "$tmpdir/out"
						echo ""
					fi
					echo ""
				} >> "$LOGFILE"
			fi
		elif [ -n "${expected_reason[$id]+x}" ] && [ "$type" != error ]; then
			fixed+=("$id")
			echo "--- listed in $EXPECTED but passes: $id [$mode]" >> "$LOGFILE"
		fi
	done < "$tmpdir/manifest"

	echo "[$mode] accepted:  $accept_pass/$accept_total (valid and invalid)"
	echo "[$mode] rejected:  $reject_pass/$reject_total (not-wf, no external entities)"
	echo "[$mode] canonical: $canon_pass/$canon_total outputs match"
	echo "[$mode] not-wf with external entities: $ext_rejected rejected, $ext_tolerated accepted (tolerated)"
	echo "[$mode] error cases (logged only): $error_accepted accepted, $error_rejected rejected"
	echo "[$mode] skipped: $skip_version XML 1.1, $skip_edition other editions, $skip_listed listed in $SKIP; $nons run with -no-ns"
	if [ $crashes -gt 0 ]; then
		echo "[$mode] crashes:   $crashes"
	fi
	if [ ${#unexpected[@]} -gt 0 ]; then
		echo "[$mode] unexpected failures (${#unexpected[@]}): ${unexpected[*]:0:20}$([ ${#unexpected[@]} -gt 20 ] && echo ' ...')"
		failed=1
	fi
	if [ ${#fixed[@]} -gt 0 ]; then
		echo "[$mode] listed in $EXPECTED but passing (remove them): ${fixed[*]}"
		failed=1
	fi
done

if [ -n "${UPDATE_EXPECTED:-}" ]; then
	{
		echo "# Known XmlBeef failures in the W3C suite (ID<TAB>reason); see test-xml-conformance.sh."
		for id in $(printf '%s\n' "${!failures[@]}" | sort); do
			printf '%s\t%s\n' "$id" "${expected_reason[$id]:-TODO: reason}"
		done
	} > "$EXPECTED"
	echo "Rewrote $EXPECTED from the current failures: review the diff"
fi

if [ $failed -ne 0 ]; then
	echo "FAIL: see $LOGFILE"
	exit 1
fi
echo "PASS"
