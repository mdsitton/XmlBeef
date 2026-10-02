# XML implementations compared

Produced by run.sh on 2026-10-02 (AMD Ryzen 9 5900X 12-Core Processor, Linux x86-64, single thread; load average 6.80 at the start;
N=5 samples minimum per process; 3 to 9 processes per cell, until 3 agree within ±5%; LIMIT=60 s).
Pinned versions in fetch.sh and the harness manifests; inputs from gen-inputs.py. MB/s of input, higher is
better. FAIL = parse error, crash or a check line that differs from libxml2's; DNF = past the time limit;
n/a = no UTF-16 support; ~ = its runs did not agree within the tolerance (noisy: compare with care).

### Document builders (DOM and other trees)

| input | XmlBeef | libxml2 | pugixml | pugixml ws | Xerces-C | roxmltree | xmltree | etree | xmlquery | JDK DOM | XmlDocument | XDocument | XmlParser (C#) | ElementTree | lxml | fast-xml-parser | xml2js | nektro/zig-xml | Beef-Lang-XML | Xml-Beef |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| svg-icons | 695.4 | 135.05 | 1647.75 | 1690.1 | 48.1 | 351.9 | 38.2 | 49.3 | 38.4 | 128.7 | 168.7 | 219.4~ | 32.1 | 62.9 | 123.55 | 39.55 | 13.2 | 86.6 | FAIL | FAIL |
| svg-artwork | 1149.8~ | 259.15 | 1990.0 | 1985.6 | 83.25 | 698.15 | FAIL | 70.3 | 61.8 | 336.0 | 91.25 | 119.9 | 79.3 | 154.0 | 290.0 | FAIL | 18.75 | 122.8 | FAIL | FAIL |
| svg-generated | 1653.9 | 239.6 | FAIL | FAIL | 93.8 | 612.4 | 44.5 | FAIL | FAIL | FAIL | 96.6 | 98.4 | FAIL | 154.1 | 276.5 | FAIL | FAIL | 119.0 | FAIL | FAIL |
| records | 378.8 | 114.2 | 465.6 | 316.5 | 26.3 | 195.6 | 26.5 | 36.1 | 28.3 | 125.7 | 54.1 | 67.5 | 23.8 | 33.9 | 125.4 | FAIL | 6.2 | 36.7 | FAIL | FAIL |
| book | 512.0 | 164.1 | 636.0 | 555.8 | 2.6 | 196.7 | FAIL | 49.4 | 38.8 | 164.3 | 78 | 101.8 | 28.3 | 65.3 | 160.6 | FAIL | 14.0 | 60.05 | FAIL | FAIL |
| osm | 395.3 | 52.4 | 414.3 | 340.4 | 19.2 | 181.6 | 28.0 | 31.25 | 30.9 | 85.5 | 32 | 57.85 | 19.2 | 32.1 | 51.8 | 17.4 | 8.0 | 37.2 | FAIL | FAIL |
| atom | 396.7 | 108.8 | 488.0 | 372.6 | 24.1 | 200.4 | 16.4 | 35.0 | 26.9 | 100.1 | 48.3 | 65.0 | 19.2 | 38.2 | 109.0 | 17.2 | 7.5 | 40.7 | FAIL | FAIL |
| book-utf16 | 791.5 | 285.2 | 470.5 | 439.6 | 12.5 | n/a | FAIL | n/a | FAIL | 279.9 | 106.8 | 106.1 | n/a | 127.4 | 281.9 | n/a | n/a | n/a | FAIL | FAIL |

### Pull, event and SAX readers

| input | XmlBeef reader | libxml2 reader | expat | quick-xml | xmlparser | xml-rs | encoding/xml | JDK SAX | JDK StAX | Woodstox | Aalto | XmlReader | TurboXml | sax-js | zig-xml | BeefXml reader |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| svg-icons | 809.4 | 135.5 | 154.9 | 418.25 | 680.2 | 41.2 | 63.6 | 149.8 | 110.0 | 229.2 | 445.3 | 222.9~ | 535.1 | 43.6 | 144.8 | 49.8 |
| svg-artwork | 1553.3 | 280.7 | 276.9 | 569.2 | 820.7 | 46.55 | 83.7 | 354.6 | 359.6 | 230.8 | 598.7 | 148.6 | 665.9 | 41.2 | 223.3 | FAIL |
| svg-generated | 1840.3 | 261.4 | 295.4 | FAIL | 868.2 | 47.3 | FAIL | FAIL | FAIL | 309.55 | FAIL | 150.8 | FAIL | FAIL | FAIL | FAIL |
| records | 498.7 | 125.7 | 173.1 | 287.0 | 367.1 | 38.8 | 46.5 | 165.2 | 158.2 | 213.7 | 319.85 | 231.1 | 340.3 | 28.7 | 81.2 | 53.6 |
| book | 607.25 | 152.9 | 329.4 | 432.5 | 462.2 | 43.0 | 64.55 | 213.2 | 189.6 | 273.3 | 310.2 | 88.8 | 443.7 | 46.5 | 132.0 | FAIL |
| osm | 463.3 | 104.1 | 127.0 | 246.3 | 403.1 | 39.6 | 44.6 | 102.2 | 105.9 | 170.9 | 267.5 | 225.5 | 250.7 | 24.25 | 79.8 | 46.1 |
| atom | 476.0 | 109.8 | 148.0 | 300.5 | 411.1 | 25.0 | 44.3 | 128.3 | 126.9 | 190.05 | 302.8 | 232.3 | 330.2 | 28.6 | 75.1 | 46.2 |
| book-utf16 | 956.9 | 241.5 | 419.0 | n/a | n/a | 70.4 | n/a | 493.3 | 421.7 | 370.0 | 398.1 | 522.7 | 876.0 | n/a | 28.5 | FAIL |

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

Load average at the end: 11.59.
