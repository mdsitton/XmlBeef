#!/bin/bash
# Fetches the third-party XML conformance suites and corpora at pinned versions into tests/suites/
# (git-ignored). See docs/test-suites.md for what each one is, how the runner classifies its cases and
# why they are fetched rather than vendored (their licenses are mixed or restrict modified
# redistribution, so none of them is copied into this MIT repository).
#
#   tests/suites/xmlconf/  W3C XML Conformance Test Suite 20130923 (the latest release), unmodified.
#                          Catalog: tests/suites/xmlconf/xmlconf.xml.
#   tests/suites/svg11/    W3C SVG 1.1 Second Edition test suite 20110816: only the SVG documents
#                          (svg/*.svg plus the SVGs under images/ and resources/), no PNGs or harnesses.
#   tests/suites/resvg/    The resvg SVG regression tests (linebender/resvg, Apache-2.0 OR MIT) at a
#                          pinned commit: only the *.svg files and the two license files.
#
# Archives are verified against the SHA-256 sums below before extraction; the git checkout is pinned
# by commit hash. Each suite directory gets a .pinned stamp, and a suite whose stamp matches is left
# alone, so rerunning the script is cheap. Bump a pin deliberately and rerun the conformance scripts.
set -euo pipefail

XMLTS_URL="https://www.w3.org/XML/Test/xmlts20130923.tar.gz"
XMLTS_SHA256="9b61db9f5dbffa545f4b8d78422167083a8568c59bd1129f94138f936cf6fc1f"   # 641522 bytes

SVG11_URL="https://www.w3.org/Graphics/SVG/Test/20110816/archives/W3C_SVG_11_TestSuite.tar.gz"
SVG11_SHA256="b5f46cca1ad79b670f9179770b2366c57efd5c671d084144090feab4b7ff1030"   # 14651624 bytes

RESVG_REPO="https://github.com/linebender/resvg.git"
RESVG_COMMIT="${RESVG_COMMIT:-75b6bbadd7999d0516dcd7153b4a321bfdf8670a}"   # 2026-09-16

SUITES="$(cd "$(dirname "$0")" && pwd)/suites"
DOWNLOADS="$SUITES/.downloads"
mkdir -p "$DOWNLOADS"

# is_current <dir> <pin>: true when <dir> was fully extracted from <pin> by an earlier run.
is_current() {
	[ -f "$1/.pinned" ] && [ "$(cat "$1/.pinned")" = "$2" ]
}

# download <url> <sha256>: prints the path of a verified local copy, downloading it when needed.
download() {
	local url="$1" sha="$2"
	local file="$DOWNLOADS/$(basename "$url")"
	if [ ! -f "$file" ] || ! echo "$sha  $file" | sha256sum --check --status; then
		echo "downloading $url" >&2
		curl -fsSL --retry 3 -o "$file.part" "$url"
		if ! echo "$sha  $file.part" | sha256sum --check --status; then
			echo "checksum mismatch for $url: expected $sha, got $(sha256sum "$file.part" | cut -d' ' -f1)" >&2
			rm -f "$file.part"
			exit 1
		fi
		mv "$file.part" "$file"
	fi
	echo "$file"
}

# W3C XML Conformance Test Suite. The tarball's top-level directory is xmlconf/.
DIR="$SUITES/xmlconf"
if is_current "$DIR" "$XMLTS_SHA256"; then
	echo "xmlconf already at xmlts20130923"
else
	archive="$(download "$XMLTS_URL" "$XMLTS_SHA256")"
	rm -rf "$DIR" "$SUITES/.xmlconf.tmp"
	mkdir -p "$SUITES/.xmlconf.tmp"
	tar -xzf "$archive" -C "$SUITES/.xmlconf.tmp"
	mv "$SUITES/.xmlconf.tmp/xmlconf" "$DIR"
	rm -rf "$SUITES/.xmlconf.tmp"
	echo "$XMLTS_SHA256" > "$DIR/.pinned"
	echo "xmlconf at xmlts20130923: $(find "$DIR" -type f | wc -l) files"
fi

# W3C SVG 1.1 Second Edition test suite: keep only the SVG documents.
DIR="$SUITES/svg11"
if is_current "$DIR" "$SVG11_SHA256"; then
	echo "svg11 already at 20110816"
else
	archive="$(download "$SVG11_URL" "$SVG11_SHA256")"
	rm -rf "$DIR" "$SUITES/.svg11.tmp"
	mkdir -p "$SUITES/.svg11.tmp"
	tar -xzf "$archive" -C "$SUITES/.svg11.tmp" --wildcards 'svg/*' 'images/*.svg' 'resources/*.svg'
	mv "$SUITES/.svg11.tmp" "$DIR"
	echo "$SVG11_SHA256" > "$DIR/.pinned"
	echo "svg11 at 20110816: $(find "$DIR" -name '*.svg' | wc -l) SVG files"
fi

# resvg regression tests: a blobless, sparse checkout fetches only the SVG files (about 1 MB).
DIR="$SUITES/resvg"
if is_current "$DIR" "$RESVG_COMMIT" && [ "$(git -C "$DIR" rev-parse HEAD 2>/dev/null)" = "$RESVG_COMMIT" ]; then
	echo "resvg already at $RESVG_COMMIT"
else
	rm -rf "$DIR"
	git init -q "$DIR"
	git -C "$DIR" remote add origin "$RESVG_REPO"
	git -C "$DIR" config core.sparseCheckout true
	printf '%s\n' '/LICENSE-APACHE' '/LICENSE-MIT' '/crates/resvg/tests/tests/**/*.svg' '/crates/usvg/tests/**/*.svg' \
		> "$DIR/.git/info/sparse-checkout"
	git -C "$DIR" fetch -q --depth 1 --filter=blob:none origin "$RESVG_COMMIT"
	git -C "$DIR" checkout -q FETCH_HEAD
	echo "$RESVG_COMMIT" > "$DIR/.pinned"
	echo "resvg at $RESVG_COMMIT: $(find "$DIR" -name '*.svg' -not -path '*/.git/*' | wc -l) SVG files"
fi
