#!/bin/bash
# Instructions per input byte (user space) of the Release XmlTester's event pass and document read, per
# bench/compare input: a measure that, unlike time, does not depend on the machine's load, for comparing
# changes when a quiet machine is not available. (It is not speed: memory traffic and branch misses are
# not in it. Timed figures come from bench/compare/run.sh on a quiet machine.)
# Usage: bench/instructions.sh [input names...]      (beefbuild -config=Release first)
set -uo pipefail
cd "$(dirname "$0")/.."
T=./build/Release_Linux64/XmlTester/XmlTester
if ! command -v perf > /dev/null; then
	echo "ERROR: perf not found"
	exit 1
fi
if [ $# -gt 0 ]; then
	inputs=("$@")
else
	inputs=(svg-icons svg-artwork svg-generated records book osm atom book-utf16)
fi

count() { # "mode [option]" path iterations
	local mode=${1%% *} options=
	[ "$mode" != "$1" ] && options=${1#* }
	perf stat -x, -e instructions:u "$T" -bench-loop "$mode" "$2" "$3" $options 2>&1 > /dev/null | grep instructions | cut -d, -f1
}

printf '%-14s %8s %9s %8s %8s\n' input events document stream stream4k
for name in "${inputs[@]}"; do
	path=bench/compare/inputs/$name
	[ -f "$path.xml" ] && path=$path.xml
	bytes=$(du -sb --apparent-size "$path" | cut -f1)
	line=$(printf '%-14s' "$name")
	# The event pass from a Stream: the default 64 KiB buffer, and a 4 KiB one (more refills)
	for mode in events document stream "stream buffer=4096"; do
		# Two runs that differ by five iterations: reading the files and starting up cancel out
		one=$(count "$mode" "$path" 1)
		six=$(count "$mode" "$path" 6)
		line+=$(awk -v a="$one" -v b="$six" -v n="$bytes" 'BEGIN { printf " %8.2f", (b - a) / 5 / n }')
	done
	echo "$line"
done
