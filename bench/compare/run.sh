#!/bin/bash
# Runs every XML implementation on every input and prints Markdown tables of parsing speed (MB/s of
# input, higher is better): document builders (DOM and other trees) first, then pull, event and SAX
# readers. Rows are inputs, columns implementations.
#
# Measurement rule, shared by every harness (c/bench.h, cpp, rust, go, java, cs, python, js, zig, beef):
#   1. Warm up: run the operation for at least 1 s (at least once), for native code and JITs alike.
#   2. Sample: time single operations until at least N samples (default 5) were taken and at least
#      60% of them lie within ±10% of their median ("converged"), or 10 s of measuring or 1000
#      samples have passed ("capped"). Report the median sample.
#   3. Repeat: run each cell in fresh processes, since memory layout, hash seeds, CPU clocks and the
#      machine's load differ between them, until the runs settle (measure.sh: at least REPEATS = 3,
#      then on until 3 lie within ±TOLERANCE = 5% of their median, at most MAX_REPEATS = 9), and take
#      the median. A cell that never settled is marked `~`.
# One operation parses the input once: a file, or for svg-icons and svg-artwork every file of the
# directory (all read into memory first). Every harness first prints "check: E A V T" (elements;
# attributes without namespace declarations; attribute value and text lengths in code points after
# reference expansion; see gen-inputs.py), compared with libxml2's: a field printed as "-" is not
# compared (the library cannot compute it; see its harness). FAIL: the parser rejected the input,
# crashed, or its check differs. DNF: a run did not finish within LIMIT seconds (default 60). n/a: the
# library does not read UTF-16 (the harness exits 3).
#
# Setup: ./fetch.sh && ./build.sh && ./gen-inputs.py
# XmlBeef's columns need the Release XmlTester: beefbuild -config=Release at the repository root.
# ONLY='XmlBeef.*' ./run.sh remeasures just those columns.
# Usage: run.sh [min-samples] [input names...]
# A full run prints the tables (save them as results.md and run plot.py to redraw the charts). With
# ONLY (merge.sh), for example ONLY='expat|pugixml.*' ./run.sh, only the matching implementations are
# measured and results.md is updated in place; inputs not named keep their saved rows.
# No quiet machine is assumed: repeated runs absorb the noise (step 3), and the load averages at the
# start and the end are printed with the tables.
set -uo pipefail
C="$(cd "$(dirname "$0")" && pwd)"
B="$C/bin"
PY="$C/python/.venv/bin/python"
source "$C/merge.sh"
source "$C/measure.sh"

load_start=$(cut -d' ' -f1 /proc/loadavg)
merge_into "$C/results.md" "$@"
N="${1:-5}"
shift || true
LIMIT="${LIMIT:-60}"
# Virtual memory limit (KiB) for the Beef libraries' cells: Xml-Beef grows without bound on long tags
BEEF_MEMORY="${BEEF_MEMORY:-4000000}"

all_inputs=(svg-icons svg-artwork svg-generated records book osm atom book-utf16)
if [ $# -gt 0 ]; then
	inputs=("$@")
else
	inputs=("${all_inputs[@]}")
fi
# A partial rerun rewrites results.md, so it lists every saved input
requested=" ${inputs[*]} "
if [ -n "${ONLY:-}" ]; then
	inputs=("${all_inputs[@]}")
fi

input_path() { # name
	if [ -d "$C/inputs/$1" ]; then echo "$C/inputs/$1"; else echo "$C/inputs/$1.xml"; fi
}

# XmlBeef: the Release XmlTester (beefbuild -config=Release at the repository root)
XT="$C/../../build/Release_Linux64/XmlTester/XmlTester"

# name|command prefix (the harness takes <file-or-dir> <min-samples> after it)
BUILDERS=(
	"XmlBeef|$XT -bench document"
	"libxml2|$B/libxml2 dom"
	"pugixml|$B/pugixml default"
	"pugixml ws|$B/pugixml ws"
	"Xerces-C|$B/xerces"
	"roxmltree|$B/rust-xmlbench roxmltree"
	"xmltree|$B/rust-xmlbench xmltree"
	"etree|$B/go-xmlbench etree"
	"xmlquery|$B/go-xmlbench xmlquery"
	"JDK DOM|$B/java/bin/xmlbench dom"
	"XmlDocument|$B/xmlbench-cs/XmlBench xmldocument"
	"XDocument|$B/xmlbench-cs/XmlBench xdocument"
	"XmlParser (C#)|$B/xmlbench-cs/XmlBench xmlparser"
	"ElementTree|$PY $C/python/bench.py etree"
	"lxml|$PY $C/python/bench.py lxml"
	"fast-xml-parser|node $C/js/bench.mjs fast-xml-parser"
	"xml2js|node $C/js/bench.mjs xml2js"
	"nektro/zig-xml|$B/nektro-zig-xml"
	"Beef-Lang-XML|$B/beef-xmlbench beef-lang-xml"
	"Xml-Beef|$B/beef-xmlbench xml-beef"
)
READERS=(
	"XmlBeef reader|$XT -bench events"
	"libxml2 reader|$B/libxml2 reader"
	"expat|$B/expat"
	"quick-xml|$B/rust-xmlbench quick-xml"
	"xmlparser|$B/rust-xmlbench xmlparser"
	"xml-rs|$B/rust-xmlbench xml-rs"
	"encoding/xml|$B/go-xmlbench encoding/xml"
	"JDK SAX|$B/java/bin/xmlbench sax"
	"JDK StAX|$B/java/bin/xmlbench stax"
	"Woodstox|$B/java/bin/xmlbench woodstox"
	"Aalto|$B/java/bin/xmlbench aalto"
	"XmlReader|$B/xmlbench-cs/XmlBench xmlreader"
	"TurboXml|$B/xmlbench-cs/XmlBench turboxml"
	"sax-js|node $C/js/bench.mjs sax"
	"zig-xml|$B/zig-xml"
	"BeefXml reader|$B/beef-xmlbench beefxml"
)

# Whether a harness's check line matches the reference, field by field ("-" is not compared)
check_ok() { # reference-line harness-output
	local got
	got=$(grep -m1 -E '^check:' <<< "$2") || return 1
	awk -v ref="$1" -v got="$got" 'BEGIN {
		n = split(ref, r, " "); m = split(got, g, " ")
		if (n != 5 || m != 5) exit 1
		for (i = 2; i <= 5; i++) if (g[i] != "-" && g[i] != r[i]) exit 1
		exit 0 }'
}

# One run of a cell in a fresh process: its MB/s, or FAIL / DNF / n/a
run_once() { # reference-line path command...
	local ref="$1" path="$2" out status
	shift 2
	# Both streams: the Zig harnesses print their results to stderr
	if [[ "$1" == "$B/beef-xmlbench" ]]; then
		out=$(ulimit -v "$BEEF_MEMORY"; timeout "$LIMIT" "$@" "$path" "$N" 2>&1)
	else
		out=$(timeout "$LIMIT" "$@" "$path" "$N" 2>&1)
	fi
	status=$?
	if [ $status -eq 124 ]; then echo DNF; return; fi
	if [ $status -eq 3 ]; then echo "n/a"; return; fi
	if [ $status -ne 0 ] || ! check_ok "$ref" "$out"; then echo FAIL; return; fi
	grep -oE '[0-9.]+ MB/s' <<< "$out" | head -1 | awk '{print $1}'
}

# One cell: the median MB/s of runs repeated until they settle (measure.sh), or FAIL / DNF / n/a
cell() { # reference-line path command...
	settle run_once "$@"
}

# The reference check line of every input: libxml2's tree
declare -A reference
for name in "${inputs[@]}"; do
	if [ -z "${ONLY:-}" ] || [[ "$requested" == *" $name "* ]]; then
		reference[$name]=$("$B/libxml2" dom "$(input_path "$name")" 1 | grep -m1 '^check:')
	fi
done

table() { # title implementations...
	local title="$1" header="| input |" rule="|---|" line lib name
	shift
	for lib in "$@"; do
		header+=" ${lib%%|*} |"
		rule+="---:|"
	done
	echo "### $title"
	echo
	echo "$header"
	echo "$rule"
	for name in "${inputs[@]}"; do
		line="| $name |"
		for lib in "$@"; do
			if selected "${lib%%|*}" && [[ "$requested" == *" $name "* ]]; then
				# Word splitting of the command prefix is intended
				# shellcheck disable=SC2086
				line+=" $(cell "${reference[$name]}" "$(input_path "$name")" ${lib#*|}) |"
			else
				line+=" $(saved_cell "$name" "${lib%%|*}") |"
			fi
		done
		echo "$line"
	done
	echo
}

# What each column is and why cells fail, printed under the tables
notes() {
	cat << 'EOF'
### Notes

Inputs (gen-inputs.py has the details): **svg-icons** 15.1 MB in 17,387 files (Material Design Icons,
Tabler Icons, Twemoji, one run parses every file), **svg-artwork** 14.5 MB in 13 files (Inkscape's
About-screen artwork), **svg-generated** 12.1 MB (Adobe Illustrator-style export: internal DTD subset
whose entities are used in attribute values, including the namespace declarations), **records** 13.8
MB (XMark-like data), **book** 10.2 MB (text-heavy XHTML), **osm** 15.0 MB (OpenStreetMap-shaped,
attribute-heavy), **atom** 10.1 MB (namespace-heavy Atom), **book-utf16** 9.9 MB (UTF-16LE with a BOM).

Implementations (pinned in fetch.sh and the harness manifests; the harness sources say exactly what
each column times):

- XmlBeef (this repository, Release `XmlTester -bench`, XmlTester/src/Bench.bf): `XmlBeef` reads each
  input into an XmlDocument (reused, as an application re-reading files would); `XmlBeef reader` passes
  over every XmlReader event, touching each value. Full well-formedness and namespace checks, the
  internal subset applied, UTF-16 transcoded to UTF-8.
- C, built from source with -O3: libxml2 2.15.4 (`libxml2`: xmlReadMemory with NOENT | NONET into its
  tree; `libxml2 reader`: xmlTextReader over the same buffer), libexpat 2.8.5 (namespace-aware, SAX
  callbacks).
- C++: pugixml 1.16 (`pugixml`: parse_default, the speed reference, which drops whitespace-only text,
  so its text length is not compared; `pugixml ws`: parse_default | parse_ws_pcdata, fully compared),
  Xerces-C 3.3.0 (XercesDOMParser, namespaces on, no validation, external DTD not loaded).
- Rust 1.98.1: quick-xml 0.42.0 (Reader, values unescaped and normalized), roxmltree 0.21.1,
  xmlparser 0.13.6 (a tokenizer: raw spans, so only the element and attribute counts are compared),
  xml-rs 1.4.0 (the `xml` crate), xmltree 0.12.0 (on xml-rs).
- Go 1.27.1: encoding/xml (Decoder.Token), beevik/etree 1.8.1, antchfx/xmlquery 1.5.1.
- Java (OpenJDK 27): the JDK's SAX, StAX and DOM (its internal Xerces-J fork, default secure-processing
  limits), Woodstox 7.3.0, Aalto 1.4.0 (both StAX).
- C# (.NET 10): TurboXml 2.1.0 (SAX-style, IgnoreDtd), KirillOsenkov/XmlParser 1.2.120 (an editor's
  full-fidelity syntax tree that keeps source text, so only counts are compared), System.Xml XmlReader,
  XmlDocument and System.Xml.Linq XDocument.
- Python 3.14: xml.etree.ElementTree (C accelerator over expat), lxml 6.1.3 (bundles libxml2 2.14.6).
- JavaScript (Node 26): fast-xml-parser 5.11.2 (preserveOrder), xml2js 0.6.2 (with the options that
  keep order and whitespace), sax 1.6.1 (`sax-js`, the event parser under xml2js).
- Zig 0.16.0: ianprime0509/zig-xml 0.2.0+ (`zig-xml`, pull reader), nektro/zig-xml (`nektro/zig-xml`,
  document; its tracer and nio dependencies are replaced by the harness's shims, see zig/shim).
- Beef (BeefBuild 0.43.6, Release): HorseTrain/Beef-Lang-XML, LauraRozier/Xml-Beef and Rune-Magic/BeefXml
  (its pull reader only; the project file in beef/libs leaves out src/Json, which does not build in
  Release). Skipped: disarray2077/BeefFNT (does not build; its XML is Xml-Beef's).
- Skipped: xmlwrapp (a C++ wrapper over libxml2's tree, so it would time libxml2 again), Apache
  Xerces-J itself (the JDK's parsers are its code, repackaged).

Why cells fail (all inputs are well-formed; each harness's check is compared with libxml2's):

- svg-generated declares its entities in the internal DTD subset, as Illustrator does. No DTD entity
  support, so the parse is rejected: quick-xml, encoding/xml, etree, xmlquery, Aalto, TurboXml, sax-js,
  xml2js, zig-xml (no DOCTYPE at all), XmlParser (C#) (no root found). pugixml leaves the references
  unexpanded (wrong values). The JDK's SAX, StAX and DOM stop at the default
  jdk.xml.totalEntitySizeLimit (100,000) and fast-xml-parser at its default expansion limit (100,000
  characters); BeefXml tries to open the external DTD as a local file.
- fast-xml-parser does not decode numeric character references by default (book, records,
  svg-artwork: wrong text).
- xmltree keys attributes by local name, so `xml:lang` and `lang` (book, book-utf16) or two prefixed
  attributes with one local name (svg-artwork) on one element collide: wrong count.
- xmlquery tries UTF-16 through its CharsetReader and fails on the BOM (book-utf16).
- Not compared: the text length of pugixml (parse_default), nektro/zig-xml (trims spaces and newlines
  from both ends of every run of character data) and BeefXml reader (skips whitespace before every
  token); values and text of xmlparser and XmlParser (C#).
- Beef-Lang-XML is not an XML parser (text split into words, no references decoded, declarations and
  comments counted as elements) and crashes on a second parse; Xml-Beef miscounts everything and loops
  with growing memory on any construct over its 4 KB buffer (run.sh caps the Beef cells' memory);
  BeefXml's reader rejects CDATA that does not follow text (book, book-utf16) and miscounts svg-artwork.
- Xerces-C passes everything but is very slow on book (about 2.5 MB/s, against 12-90 MB/s on the other
  inputs); the cause was not investigated.
- n/a (UTF-16 not read): quick-xml, roxmltree, xmlparser, encoding/xml, etree, fast-xml-parser, xml2js,
  sax-js (string inputs; the harness decodes UTF-8 only), XmlParser (C#), nektro/zig-xml.
EOF
}

cpu=$(grep -m1 'model name' /proc/cpuinfo | sed 's/.*: //')
if [ -n "${ONLY:-}" ]; then
	saved_preamble
	echo
	echo "Partial rerun on $(date +%F) (ONLY='$ONLY', inputs: $(echo $requested); load average $load_start at the start; N=$N, REPEATS=$REPEATS-$MAX_REPEATS, TOLERANCE=$TOLERANCE%, LIMIT=$LIMIT s)."
else
	echo "# XML implementations compared"
	echo
	echo "Produced by run.sh on $(date +%F) ($cpu, Linux x86-64, single thread; load average $load_start at the start;"
	echo "N=$N samples minimum per process; $REPEATS to $MAX_REPEATS processes per cell, until $REPEATS agree within ±$TOLERANCE%; LIMIT=$LIMIT s)."
	echo "Pinned versions in fetch.sh and the harness manifests; inputs from gen-inputs.py. MB/s of input, higher is"
	echo "better. FAIL = parse error, crash or a check line that differs from libxml2's; DNF = past the time limit;"
	echo "n/a = no UTF-16 support; ~ = its runs did not agree within the tolerance (noisy: compare with care)."
fi
echo
table "Document builders (DOM and other trees)" "${BUILDERS[@]}"
table "Pull, event and SAX readers" "${READERS[@]}"
notes
echo
echo "Load average at the end: $(cut -d' ' -f1 /proc/loadavg)."
