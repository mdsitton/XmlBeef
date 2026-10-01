#!/bin/bash
# Builds every comparison harness into bin/ (git-ignored). Run fetch.sh first. C and C++ use -O3
# without -march=native (generic x86-64, like Beef's Release builds); libxml2, libexpat and xerces-c are
# built as static libraries from the pinned clones with CMake's Release flags. Pass harness names to
# build only those: libxml2 expat pugixml xerces rust go java js cs python zig beef
set -euo pipefail
C="$(cd "$(dirname "$0")" && pwd)"
D="$C/deps"
B="$C/bin"
L="$C/c/build"
mkdir -p "$B" "$L"

TARGETS=("$@")
want() { [ ${#TARGETS[@]} -eq 0 ] || [[ " ${TARGETS[*]} " == *" $1 "* ]]; }
step() { echo "== $1"; }
CFLAGS="-O3 -DNDEBUG"
JOBS=$(nproc)

if want libxml2; then
	step "libxml2 (C)"
	cmake -S "$D/libxml2" -B "$L/libxml2" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
		-DCMAKE_C_FLAGS_RELEASE="$CFLAGS" -DCMAKE_INSTALL_PREFIX="$L/libxml2/install" \
		-DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_ZLIB=OFF -DLIBXML2_WITH_ICU=OFF \
		-DLIBXML2_WITH_TESTS=OFF -DLIBXML2_WITH_PROGRAMS=OFF -DLIBXML2_WITH_DOCS=OFF > /dev/null
	cmake --build "$L/libxml2" -j "$JOBS" --target install > /dev/null
	cc $CFLAGS -std=gnu11 -I"$L/libxml2/install/include/libxml2" -o "$B/libxml2" "$C/c/libxml2.c" \
		"$L/libxml2/install/lib/libxml2.a" -lm
fi
if want expat; then
	step "libexpat (C)"
	cmake -S "$D/libexpat/expat" -B "$L/expat" -DCMAKE_BUILD_TYPE=Release -DEXPAT_SHARED_LIBS=OFF \
		-DCMAKE_C_FLAGS_RELEASE="$CFLAGS" -DCMAKE_INSTALL_PREFIX="$L/expat/install" \
		-DEXPAT_BUILD_TESTS=OFF -DEXPAT_BUILD_TOOLS=OFF -DEXPAT_BUILD_EXAMPLES=OFF -DEXPAT_BUILD_DOCS=OFF > /dev/null
	cmake --build "$L/expat" -j "$JOBS" --target install > /dev/null
	cc $CFLAGS -std=gnu11 -I"$L/expat/install/include" -o "$B/expat" "$C/c/expat.c" "$L/expat/install/lib/libexpat.a"
fi
if want pugixml; then
	step "pugixml (C++)"
	c++ $CFLAGS -std=c++20 -I"$D/pugixml/src" -o "$B/pugixml" "$C/cpp/pugixml.cpp" "$D/pugixml/src/pugixml.cpp"
fi
if want xerces; then
	step "xerces-c (C++)"
	cmake -S "$D/xerces-c" -B "$L/xerces" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
		-DCMAKE_CXX_FLAGS_RELEASE="$CFLAGS" -DCMAKE_C_FLAGS_RELEASE="$CFLAGS" \
		-DCMAKE_INSTALL_PREFIX="$L/xerces/install" -Dnetwork=OFF -Dtranscoder=gnuiconv \
		-Dmessage-loader=inmemory > /dev/null
	cmake --build "$L/xerces" -j "$JOBS" --target install > /dev/null
	c++ $CFLAGS -std=c++20 -I"$L/xerces/install/include" -o "$B/xerces" "$C/cpp/xerces.cpp" \
		"$L/xerces/install/lib/libxerces-c.a"
fi
if want rust; then
	step "rust (quick-xml, roxmltree, xmlparser, xml-rs, xmltree)"
	# Built from its directory so rustup picks the pinned toolchain in rust-toolchain.toml
	(cd "$C/rust" && cargo build -q --release --locked --target-dir "$C/rust/target")
	cp "$C/rust/target/release/xmlbench" "$B/rust-xmlbench"
fi
if want go; then
	step "go (encoding/xml, etree, xmlquery)"
	(cd "$C/go" && go build -mod=readonly -o "$B/go-xmlbench" .)
fi
if want java; then
	step "java (JDK SAX, StAX and DOM, Woodstox, Aalto)"
	# javac against the jars fetch.sh downloaded (the installed Gradle does not run on JDK 27); bin/java
	# gets the classes, the jars and a launcher script
	JARS="$D/jars/woodstox-core-7.3.0.jar:$D/jars/aalto-xml-1.4.0.jar:$D/jars/stax2-api-4.3.1.jar"
	rm -rf "$C/java/build" "$B/java"
	javac -nowarn -d "$C/java/build/classes" -cp "$JARS" "$C/java/src/XmlBench.java"
	mkdir -p "$B/java/bin" "$B/java/lib"
	cp -r "$C/java/build/classes" "$B/java/" && cp "$D"/jars/*.jar "$B/java/lib/"
	printf '#!/bin/sh\nH="$(cd "$(dirname "$0")/.." && pwd)"\nexec java -cp "$H/classes:$H/lib/*" XmlBench "$@"\n' > "$B/java/bin/xmlbench"
	chmod +x "$B/java/bin/xmlbench"
fi
if want cs; then
	step "c# (TurboXml, XmlParser, System.Xml XmlReader/XmlDocument, XDocument)"
	dotnet build -v q -nologo -c Release -o "$B/xmlbench-cs" "$C/cs/XmlBench.csproj" > /dev/null
fi
if want python; then
	step "python (xml.etree.ElementTree, lxml)"
	[ -x "$C/python/.venv/bin/python" ] || python3 -m venv "$C/python/.venv"
	# lxml's binary wheel (it bundles its own libxml2 and libxslt)
	"$C/python/.venv/bin/pip" install -q lxml==6.1.3
fi
if want js; then
	step "javascript (fast-xml-parser, xml2js, sax)"
	(cd "$C/js" && npm ci --silent --no-audit --no-fund --ignore-scripts)
fi
if want zig; then
	step "zig (zig-xml by ianprime0509, zig-xml by nektro)"
	ZIG="$D/zig/zig"
	ZC=(--cache-dir "$C/zig/.zig-cache" --global-cache-dir "$C/zig/.zig-cache")
	(cd "$C/zig" && "$ZIG" build-exe -O ReleaseFast --dep xml -Mroot=zig-xml.zig -Mxml="$D/zig-xml/src/xml.zig" \
		-femit-bin="$B/zig-xml" "${ZC[@]}")
	# nektro's zig-xml imports zig-tracer and zig-nio; shim/ stands in for both (see there)
	(cd "$C/zig" && "$ZIG" build-exe -O ReleaseFast --dep xml --dep nio -Mroot=nektro.zig \
		--dep tracer --dep extras --dep nio -Mxml="$D/nektro-zig-xml/mod.zig" -Mtracer=shim/tracer.zig \
		-Mextras="$D/zig-extras/src/lib.zig" -Mnio=shim/nio.zig -femit-bin="$B/nektro-zig-xml" "${ZC[@]}")
fi
if want beef; then
	step "beef (Beef-Lang-XML, Xml-Beef, BeefXml)"
	(cd "$C/beef" && beefbuild -config=Release > /dev/null)
	cp "$C/beef/build/Release_Linux64/XmlBeefBench/XmlBeefBench" "$B/beef-xmlbench"
fi
