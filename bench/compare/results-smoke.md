# XML implementations compared: SMOKE RUN, NOT COMPARABLE

**Unreliable figures.** This table comes from a single smoke run on a loaded machine (1-minute load average 7-10 throughout), with N=1 sample and REPEATS=1 process per cell (`FORCE=1 REPEATS=1 ./run.sh 1`). It verifies that every harness builds, runs and passes (or fails) its check; the MB/s are only indicative and must not be quoted. The real run is `./run.sh > results.md` on a quiet machine (run.sh refuses to start above load 2).

Produced by run.sh on 2026-09-30 (AMD Ryzen 9 5900X 12-Core Processor, Linux x86-64, single thread; load average 9.67 at the start;
N=1 samples minimum, REPEATS=1 processes per cell, LIMIT=60 s). Pinned versions in fetch.sh and
the harness manifests; inputs from gen-inputs.py. MB/s of input, higher is better. FAIL = parse error,
crash or a check line that differs from libxml2's; DNF = past the time limit; n/a = no UTF-16 support.

### Document builders (DOM and other trees)

| input | libxml2 | pugixml | pugixml ws | Xerces-C | roxmltree | xmltree | etree | xmlquery | JDK DOM | XmlDocument | XDocument | XmlParser (C#) | ElementTree | lxml | fast-xml-parser | xml2js | nektro/zig-xml | Beef-Lang-XML | Xml-Beef |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| svg-icons | 138.7 | 1564.3 | 1562.5 | 45.6 | 342.8 | 41.8 | 50.6 | 39.4 | 127.7 | 51.7 | 61.2 | 37.8 | 66.5 | 131.9 | 41.0 | 17.8 | 91.9 | FAIL | FAIL |
| svg-artwork | 271.0 | 2301.6 | 2112.0 | 89.2 | 725.0 | FAIL | 71.6 | 62.7 | 315.5 | 86.0 | 100.9 | 80.7 | 150.0 | 269.2 | FAIL | 16.8 | 119.5 | FAIL | FAIL |
| svg-generated | 227.7 | FAIL | FAIL | 88.5 | 600.9 | 45.3 | FAIL | FAIL | FAIL | 61.3 | 84.2 | FAIL | 127.1 | 254.9 | FAIL | FAIL | 111.5 | FAIL | FAIL |
| records | 108.2 | 456.6 | 297.9 | 24.3 | 184.6 | 26.1 | 34.8 | 28.1 | 116.9 | 61.2 | 65.0 | 22.3 | 32.5 | 121.5 | FAIL | 6.1 | 34.1 | FAIL | FAIL |
| book | 153.8 | 606.0 | 483.6 | 2.5 | 194.7 | FAIL | 48.0 | 40.2 | 142.8 | 49.5 | 43.1 | 26.6 | 62.4 | 152.7 | FAIL | 11.1 | 58.9 | FAIL | FAIL |
| osm | 50.2 | 386.5 | 307.6 | 18.3 | 167.5 | 27.2 | 28.3 | 31.3 | 86.6 | 32.0 | 70.0 | 20.7 | 30.2 | 47.0 | 15.7 | 7.2 | 34.3 | FAIL | FAIL |
| atom | 106.2 | 439.2 | 353.9 | 23.7 | 188.9 | 15.7 | 34.4 | 26.3 | 103.3 | 41.4 | 63.9 | 22.1 | 35.7 | 103.0 | 15.3 | 7.3 | 39.4 | FAIL | FAIL |
| book-utf16 | 286.6 | 456.3 | 424.7 | 12.2 | n/a | FAIL | n/a | FAIL | 335.9 | 98.1 | 97.0 | n/a | 115.1 | 272.3 | n/a | n/a | n/a | FAIL | FAIL |

### Pull, event and SAX readers

| input | libxml2 reader | expat | quick-xml | xmlparser | xml-rs | encoding/xml | JDK SAX | JDK StAX | Woodstox | Aalto | XmlReader | TurboXml | sax-js | zig-xml | BeefXml reader |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| svg-icons | 127.3 | 154.8 | 476.2 | 579.5 | 39.2 | 59.3 | 149.8 | 103.5 | 225.7 | 436.1 | 104.0 | 488.8 | 40.2 | 140.1 | 48.0 |
| svg-artwork | 256.1 | 266.2 | 679.4 | 686.6 | 44.3 | 79.0 | 349.4 | 351.6 | 224.0 | 559.8 | 143.8 | 665.3 | 38.8 | 206.3 | FAIL |
| svg-generated | 252.3 | 305.3 | FAIL | 752.3 | 48.2 | FAIL | FAIL | FAIL | 314.0 | FAIL | 137.3 | FAIL | FAIL | FAIL | FAIL |
| records | 118.1 | 168.7 | 310.7 | 419.9 | 36.0 | 49.3 | 164.0 | 149.6 | 204.9 | 263.5 | 227.7 | 335.1 | 20.7 | 81.0 | 55.0 |
| book | 150.4 | 303.5 | 475.1 | 564.2 | 43.9 | 66.2 | 206.0 | 195.4 | 275.9 | 320.9 | 136.8 | 444.6 | 44.4 | 127.1 | FAIL |
| osm | 101.0 | 132.9 | 278.7 | 374.8 | 38.2 | 45.1 | 104.9 | 104.6 | 172.4 | 252.1 | 230.8 | 242.6 | 17.5 | 78.6 | 41.0 |
| atom | 109.3 | 139.4 | 306.6 | 434.5 | 24.7 | 48.9 | 118.9 | 127.0 | 187.1 | 299.6 | 228.7 | 326.4 | 20.4 | 73.3 | 46.1 |
| book-utf16 | 241.4 | 425.5 | n/a | n/a | 72.0 | n/a | 464.9 | 445.1 | 360.9 | 383.3 | 527.4 | 902.7 | n/a | 28.4 | FAIL |

### Notes

Inputs (gen-inputs.py has the details): **svg-icons** 15.1 MB in 17,387 files (Material Design Icons,
Tabler Icons, Twemoji, one run parses every file), **svg-artwork** 14.5 MB in 13 files (Inkscape's
About-screen artwork), **svg-generated** 12.1 MB (Adobe Illustrator-style export: internal DTD subset
whose entities are used in attribute values, including the namespace declarations), **records** 13.8
MB (XMark-like data), **book** 10.2 MB (text-heavy XHTML), **osm** 15.0 MB (OpenStreetMap-shaped,
attribute-heavy), **atom** 10.1 MB (namespace-heavy Atom), **book-utf16** 9.9 MB (UTF-16LE with a BOM).

Implementations (pinned in fetch.sh and the harness manifests; the harness sources say exactly what
each column times):

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
