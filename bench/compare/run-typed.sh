#!/bin/bash
# The typed benchmark (docs/plan.md §6 phase 6): osm.xml read into an OpenStreetMap model of strings,
# numbers and lists (nodes with their tags, ways with their node references and tags, relations with
# their members and tags) by XmlBeef's [XmlObject] (XmlTester/src/Osm.bf), quick-xml + serde
# (rust/src/typed.rs), Go's encoding/xml Unmarshal (go/typed.go) and .NET's XmlSerializer
# (cs/Typed.cs). Prints a Markdown table of MB/s of input (higher is better).
#
# The measurement rule is run.sh's (warm-up, converged median of samples, fresh processes repeated
# until they settle as measure.sh describes, a LIMIT in seconds, DNF past it). Every harness first prints `check: N W R T D M S U P` (nodes, ways,
# relations, tags, node references, members, the sum of node ids and references, the UTF-8 bytes of
# the user names, the coordinates' sum in 1e-7 degrees), compared with one computed here by Python's
# ElementTree: FAIL if it differs.
#
# Setup: ./fetch.sh && ./build.sh rust go cs && ./gen-inputs.py; beefbuild -config=Release at the
# repository root for XmlBeef.
# Usage: run-typed.sh [min-samples]
set -uo pipefail
C="$(cd "$(dirname "$0")" && pwd)"
B="$C/bin"
XT="$C/../../build/Release_Linux64/XmlTester/XmlTester"
INPUT="$C/inputs/osm.xml"
source "$C/measure.sh"

load=$(cut -d' ' -f1 /proc/loadavg)
N="${1:-5}"
LIMIT="${LIMIT:-60}"

IMPLEMENTATIONS=(
	"XmlBeef|$XT -bench typed"
	"quick-xml + serde|$B/rust-xmlbench quick-xml-serde"
	"encoding/xml Unmarshal|$B/go-xmlbench encoding/xml-unmarshal"
	"XmlSerializer (.NET)|$B/xmlbench-cs/XmlBench xmlserializer"
)

reference=$(python3 - "$INPUT" << 'EOF'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
nodes, ways, relations = root.findall('node'), root.findall('way'), root.findall('relation')
everything = nodes + ways + relations
tags = sum(len(e.findall('tag')) for e in everything)
nds = [int(d.get('ref')) for w in ways for d in w.findall('nd')]
members = [int(m.get('ref')) for r in relations for m in r.findall('member')]
total = sum(int(n.get('id')) for n in nodes) + sum(nds) + sum(members)
users = sum(len(e.get('user').encode()) for e in everything)
coordinates = sum(round(float(n.get('lat')) * 1e7) + round(float(n.get('lon')) * 1e7) for n in nodes)
print('check:', len(nodes), len(ways), len(relations), tags, len(nds), len(members), total, users, coordinates)
EOF
)

# One run in a fresh process: its MB/s, or FAIL / DNF
run_once() { # command...
	local out status
	out=$(timeout "$LIMIT" "$@" "$INPUT" "$N" 2>&1)
	status=$?
	if [ $status -eq 124 ]; then echo DNF; return; fi
	if [ $status -ne 0 ] || [ "$(grep -m1 '^check:' <<< "$out")" != "$reference" ]; then echo FAIL; return; fi
	grep -oE '[0-9.]+ MB/s' <<< "$out" | head -1 | awk '{print $1}'
}

# One cell: the median MB/s of runs repeated until they settle (measure.sh), or FAIL / DNF
cell() { # command...
	settle run_once "$@"
}

header="| input |"
rule="|---|"
line="| osm |"
for impl in "${IMPLEMENTATIONS[@]}"; do
	header+=" ${impl%%|*} |"
	rule+="---:|"
	# Word splitting of the command prefix is intended
	# shellcheck disable=SC2086
	line+=" $(cell ${impl#*|}) |"
done
echo "### Typed reading (MB/s)"
echo
echo "$header"
echo "$rule"
echo "$line"
echo
echo "Load average $load at the start, $(cut -d' ' -f1 /proc/loadavg) at the end; $REPEATS to $MAX_REPEATS processes per cell, until $REPEATS agree within ±$TOLERANCE% (~: they did not). Reference: $reference"
