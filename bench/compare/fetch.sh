#!/bin/bash
# Fetches everything the comparison benchmark builds against into deps/ (git-ignored), each pinned so
# runs are comparable:
#   - git clones of the C, C++, Zig and Beef implementations, pinned to a commit (a release tag's commit
#     where the project tags releases);
#   - the Zig compiler both Zig libraries need, verified against its published checksum;
#   - the real-world SVG corpora gen-inputs.py unpacks into inputs/, verified by sha256.
# Libraries that come from a package registry are pinned where the language pins them: Cargo.lock
# (rust/), go.sum (go/), package-lock.json (js/), exact NuGet versions (cs/*.csproj), exact Maven
# versions (java/build.gradle) and an exact pip version (build.sh python).
set -euo pipefail
C="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$C/deps"
fetch() { # name url commit
	local dir="$C/deps/$1"
	if [ ! -d "$dir/.git" ]; then
		git init -q "$dir"
		git -C "$dir" remote add origin "$2"
	fi
	if [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" != "$3" ]; then
		git -C "$dir" fetch -q --depth 1 origin "$3"
		git -C "$dir" checkout -q --detach FETCH_HEAD
	fi
	echo "$1 $(git -C "$dir" rev-parse --short HEAD)"
}
# Pinned 2026-09-30 (the newest release, or the newest commit where there are no releases)
fetch libxml2        https://gitlab.gnome.org/GNOME/libxml2.git       96498992efa48d52b0e8b83058bd88dbdaf153c1  # v2.15.4
fetch libexpat       https://github.com/libexpat/libexpat.git         4b3f0b06f39fb5529cead381694f8929901bc273  # R_2_8_5 (2.8.5)
fetch pugixml        https://github.com/zeux/pugixml.git              c8033ce9d039e7f9d134877c363397b3cfe20816  # v1.16
fetch xerces-c       https://github.com/apache/xerces-c.git           31b4b3a06105dcd607db9fda9d1883ad7e489bfe  # v3.3.0
fetch zig-xml        https://github.com/ianprime0509/zig-xml.git      d73304c3d56d6331a0caca4d339607e7c740aab5  # 0.2.0 + master
fetch nektro-zig-xml https://github.com/nektro/zig-xml.git            9e957acfcf07e22b46a767dbc202c88eadaee270
fetch zig-extras     https://github.com/nektro/zig-extras.git         d1fe27b3b96cc14290a507c268681628de98a7c9  # nektro-zig-xml's
fetch Beef-Lang-XML  https://github.com/HorseTrain/Beef-Lang-XML.git  a1e5a7bb8bfb08da81860f80245257e206607024
fetch BeefXml        https://github.com/Rune-Magic/BeefXml.git        4bbf452421b37637315cfec04c4d93fcc921001a
fetch Xml-Beef       https://github.com/LauraRozier/Xml-Beef.git      405d35677cdea15d5e8f88b48b40503112e85854

# Zig itself (both Zig libraries need Zig 0.16), verified against the published checksum
ZIG_VERSION=0.16.0
ZIG_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
if [ ! -x "$C/deps/zig/zig" ]; then
	tarball="$C/deps/zig-$ZIG_VERSION.tar.xz"
	curl -fsSL -o "$tarball" "https://ziglang.org/download/$ZIG_VERSION/zig-x86_64-linux-$ZIG_VERSION.tar.xz"
	echo "$ZIG_SHA256  $tarball" | sha256sum -c --quiet -
	mkdir -p "$C/deps/zig"
	tar -xJf "$tarball" -C "$C/deps/zig" --strip-components=1
	rm "$tarball"
fi
echo "zig $("$C/deps/zig/zig" version)"

download() { # file url sha256
	local target="$C/deps/$1"
	if [ ! -f "$target" ] || ! echo "$3  $target" | sha256sum -c --quiet - 2> /dev/null; then
		curl -fsSL -o "$target.part" "$2"
		echo "$3  $target.part" | sha256sum -c --quiet -
		mv "$target.part" "$target"
	fi
}

# Woodstox and Aalto (StAX implementations) with the Stax2 API they share, from Maven Central (the
# newest on 2026-09-30). The Java harness is compiled with javac against these jars: the installed
# Gradle does not run on the installed JDK 27.
mkdir -p "$C/deps/jars"
MAVEN=https://repo1.maven.org/maven2
download jars/woodstox-core-7.3.0.jar "$MAVEN/com/fasterxml/woodstox/woodstox-core/7.3.0/woodstox-core-7.3.0.jar" \
	246cb4845991ab52196ef90ee8a361164512b5cc7ec0547c9fab8f3db75f2679
download jars/aalto-xml-1.4.0.jar "$MAVEN/com/fasterxml/aalto-xml/1.4.0/aalto-xml-1.4.0.jar" \
	1811be73195cad1d11f609c1f6527ca74a4ae1484bef73c6acaa0491991e5765
download jars/stax2-api-4.3.1.jar "$MAVEN/org/codehaus/woodstox/stax2-api/4.3.1/stax2-api-4.3.1.jar" \
	1953d9d443149769c8418fd4fb69284ba2f98adbbed304e9a050c360e28541c6
echo "jars: $(ls "$C/deps/jars" | wc -l) verified"

# Real-world SVG corpora (gen-inputs.py unpacks them; see its docstring for what each input is)
mkdir -p "$C/deps/corpora"
# Icon sets, as published to npm: Material Design Icons (Apache-2.0), Tabler Icons (MIT), Twemoji
# (graphics CC-BY 4.0)
download corpora/mdi-svg-7.4.47.tgz https://registry.npmjs.org/@mdi/svg/-/svg-7.4.47.tgz \
	de92e5dc9ce46c392ab5c53aa7190b19f82b40cb48872a083f788c7e13e91fef
download corpora/tabler-icons-3.48.0.tgz https://registry.npmjs.org/@tabler/icons/-/icons-3.48.0.tgz \
	28447dcf6f0bb2b8d92c59a1b3d30900a180de2e97d7db4d267e6320dc68f449
download corpora/twemoji-svg-15.0.0.tgz https://registry.npmjs.org/@twemoji/svg/-/svg-15.0.0.tgz \
	1d2907557a422c7c4e3feca50ef915c39da1db3d76b4a4d7e73fb59bce4403c3
# Inkscape's About-screen artwork (contest entries, CC BY-SA 4.0), saved by Inkscape as .svgz, from
# the Inkscape repository at a fixed commit
INKSCAPE=https://gitlab.com/inkscape/inkscape/-/raw/99b558096ca6b91bae9c66d4c82d53665a0f16e7/share/screens/about
while read -r name sha; do
	download "corpora/inkscape-$name" "$INKSCAPE/$name" "$sha"
done << 'EOF'
about00.svgz 89dd717a302c13749766512e283d98590b816e411126ab06f40f7882364e0129
about01.svgz 1c4b238fb09a01ae07b51631bce8765470a5f39a1a887160f1fb9ba032d2919a
about02.svgz 99d74a8d7a24fb9dd4152962ea8150ede20d1dfe06d5f67d19e4a74a80c4e298
about03.svgz 9b7fd1e8c41c55998023b13a76808d8810dc2c6ae5ba4369b5e6d88701ebcbe5
about04.svgz 7badef17aca9d332925e05dce38a1e870ce0ae813cec53ee9abffbd355a4be83
about05.svgz f1ca5446382c3bcef673586d3c6623ca4cbfedecd193c36dea1bb851f06578b4
about06.svgz febac7bdab16d0c4e72f750e8356469de96a5b68243382ace983e3d8114e9b82
about07.svgz c3faf97b323b90feee8f210d4deeb3cac922a50d6680f4d9a2a35ad3d48b0005
about08.svgz d43c14afe6a33b770c01b51329d8100c3cce224ff0663d1f4c265d0e98c617e9
about09.svgz 59a501804d94eb5d538b8e4caa16beb9d9ae39c72da2829209584bc2e30634ae
about10.svgz e28d55d22b3090c2aaaa6d3d606e161734ed58822a970d60caea5da90d09b62b
about11.svgz b2ffa334d9d941f2ab762dc6db0f93e1466175a634b8b21da5de9494bf48f404
about12.svgz 250ccf87785f3c942ae81b039377f25df80b88c5b803c50ba8a424419bb3ecfc
EOF
echo "corpora: $(ls "$C/deps/corpora" | wc -l) files verified"
