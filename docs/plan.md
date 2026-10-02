# XmlBeef: implementation plan and handoff

XmlBeef is an XML 1.0 (Fifth Edition) + Namespaces parser and writer for the Beef programming
language. Its main job is reading data formats from disk — SVG first, then configuration and data
XML, XHTML, project files, COLLADA, Tiled maps, Office parts — fast, fully checked and with located
errors, and writing them back, optionally preserving the original formatting. It is the third
sibling of TomlBeef (`~/development/TomlBeef`, TOML 1.1) and KdlBeef (`~/development/KdlBeef`,
KDL 2.0) and reuses their design, tooling and, where it fits, their code. KdlBeef is the closer
model: it is a markup tree with a pull reader under the document, just like XML.

This document is the handoff for the session that starts the implementation. It records what exists,
what the research found, the requirements, the design to build and the phases to build it in. Read
with it:

- `docs/spec-reference.md` — the XML 1.0 5th edition and Namespaces rules (productions, every WFC,
  the DTD and entity rules, encodings, security), what SVG needs, and 133 edge cases worth a test.
- `docs/implementation-survey.md` — the four existing Beef libraries (built and tested) and 25
  implementations in eight languages: what to copy, what to avoid.
- `docs/test-suites.md` — the W3C conformance suite (which release, how to run it, counts, the
  canonical output format), the SVG corpora, licensing, and the planned test scripts.
- `bench/compare/results.md` — the benchmark of the existing implementations (§2, §8).
- `AGENTS.md` — Beef conventions and gotchas, verification and commit rules.
- KdlBeef's `docs/architecture.md` and TomlBeef's — the designs this plan adapts.

## 1. State of the repository (2026-09-30)

| Path | What it is |
|---|---|
| `BeefSpace.toml`, `BeefProj.toml` | Workspace: the `XmlBeef` library (`src/XmlBeef/`) and the `XmlTester` CLI; `TestRelease` and Windows (LLVM toolset) configs as in the siblings |
| `src/XmlBeef/XmlVersion.bf` | Placeholder public type |
| `src/XmlBeef/tests/XmlSmokeTests.bf` | One smoke test so `beefbuild -test` runs (1/1) |
| `XmlTester/src/Program.bf` | Stub; becomes the conformance and benchmark CLI (phase 1) |
| `tests/fetch-suites.sh` | Fetches, at pinned versions with SHA-256 checks, the W3C XML Conformance Test Suite 20130923, the W3C SVG 1.1 Second Edition test suite (606 SVGs) and the resvg test SVGs (1,784) into `tests/suites/` (git-ignored; the licenses forbid vendoring, `test-suites.md` §8) |
| `bench/compare/` | The comparison benchmark (§2, §8): pinned clones, a harness per language, inputs, `run.sh` with the siblings' measurement rule and `ONLY=` partial reruns |
| `docs/` | This plan, the spec reference, the implementation survey, the test-suite reference, `status.md` |

Nothing parsed XML when this plan was written.

**Update (phase 1 done, 2026-09-30):** `XmlReader` (generic core over a cursor, entity input frames,
namespaces, the internal subset), the encoding detector, `XmlCanonical.WriteSuiteForm`, `XmlTester`,
`test-xml-conformance.sh` (catalogs read by `tests/xmlconf/manifest.py`) and `test-leaks.sh` exist;
the placeholder `XmlVersion` and the smoke test are gone. What was built and why is in
`architecture.md`, the baseline in `status.md`. Beyond the phase: UTF-32, ISO-8859-1 and US-ASCII are
read already (only UTF-8/16 were asked), and namespace-off mode exists, so the nine NAMESPACE="no"
cases run instead of being skipped.

## 2. What the research says

### 2.1 The existing Beef libraries

None is reusable (`implementation-survey.md`, "The existing Beef libraries", with a results table
over 13 tricky inputs):

- **Beef-Lang-XML** (2021, 513 lines) builds, but is a toy: no entity, CDATA or end-of-line
  handling, end tags never checked, text split into words.
- **Xml-Beef** (2021, a VerySimpleXml port) builds, but loops forever with growing memory on any tag
  longer than 4,096 bytes (a real 595 KB Inkscape SVG: over 2 minutes and 3 GB), drops text without
  whitespace, and its writer segfaults without an XML declaration.
- **BeefXml** (2025, 5.6k lines) is the only serious attempt: its pull reader counts real SVGs
  correctly, but its document builder asserts on every document, Release builds fail, every parse
  error calls `Debug.Break()`, and it opens external DTDs and entities from disk by default. Worth
  keeping: the enum-event pull-reader shape and comptime-generated character classes (as tables).
- **BeefFNT** does not build and only wraps Xml-Beef.

So Beef has no working XML library today; XmlBeef starts from the siblings, not from these.

### 2.2 The benchmark

33 configurations of 24 implementations in nine languages (C, C++, Rust, Go, Java, C#, Python,
JavaScript, Zig) plus the three Beef libraries that build, timed with the siblings' rule on eight
inputs of 10–15 MB:

- **svg-icons:** 17,387 real icon files (Material Design Icons, Tabler, Twemoji), one cell parsing
  every file, so per-file overhead counts.
- **svg-artwork:** Inkscape's About-screen artworks.
- **svg-generated:** Illustrator-style, with an internal DTD whose entities are used in attribute
  values (`xmlns="&ns_svg;"`).
- **records** (XMark-like), **book** (text-heavy XHTML), **osm** (attribute-heavy), **atom**
  (namespace-heavy), **book-utf16** (UTF-16LE).

Every harness reports a checksum (elements, attributes, attribute-value and text lengths after
decoding) checked against libxml2's; a wrong one is FAIL.

Before XmlBeef existed, a one-sample smoke table under load (`bench/compare/results-smoke.md`) gave
the picture below; the timed run with XmlBeef is at the end of this section. The smoke table's rough
picture:

- Document builders: pugixml leads at ~390–2,300 MB/s, then roxmltree 170–725, the JDK DOM, libxml2
  and lxml 50–330.
- Pull/event readers: xmlparser (a tokenizer) 375–750, TurboXml 240–900, quick-xml 280–680, Aalto
  250–560; expat, Woodstox, the JDK readers and .NET's XmlReader 100–530.
- The Beef libraries: 40–55 MB/s, and every one FAILs its checksum on most inputs.

Published references agree (`implementation-survey.md` "Speed references"): pugixml ~850 MB/s,
RapidXML ~700, expat and libxml2 SAX ~150, libxml2 DOM ~65; quick-xml 250–750 and roxmltree 215–370
on an M1.

**Correctness, which does not depend on load, is the bigger finding.** On well-formed inputs:

- **svg-generated** (internal DTD entities, what Illustrator writes) is rejected outright by
  quick-xml, Go's encoding/xml and etree and xmlquery, Aalto, TurboXml, sax-js, xml2js, zig-xml and
  XmlParser; the JDK parsers stop at their 100,000-byte entity-size limit and fast-xml-parser at its
  expansion limit; **pugixml leaves the references unexpanded** (wrong values); BeefXml tries to open
  the external DTD URL as a file. Only libxml2, expat, Xerces-C, roxmltree, xml-rs, xmltree,
  Woodstox, the three .NET models, ElementTree, lxml and nektro/zig-xml read it correctly.
- fast-xml-parser leaves numeric character references undecoded by default; xmltree keys attributes
  by local name (`xml:lang` and `lang` collide); nine libraries cannot read UTF-16 at all.

So the fast libraries that read real SVG correctly are roxmltree, expat and libxml2; pugixml is the
speed bar for a DOM but not a correct one. **The target for XmlBeef: roxmltree-or-better document
speed and quick-xml-class reader speed, while passing every input here and the whole W3C suite.**

**The timed run** (2026-10-02, `bench/compare/results.md`, charts in `docs/benchmark.svg`; load 7–12,
every cell rerun until 3 processes agreed within 5%, 3 of 304 cells did not): the XmlBeef document is
1.65–2.7× roxmltree on every input roxmltree reads, 3–8× libxml2's tree, and 41–98% of pugixml (which
fails svg-generated), ahead of it on book-utf16; the XmlBeef reader is 1.4–2.7× quick-xml, 1.15–1.9×
xmlparser (a tokenizer) and 3–7× expat and libxml2's reader, the fastest reader on every input. **The
numeric targets**, kept as regression guards: the document at least 1.5× roxmltree and the reader at
least 1.3× quick-xml on every input both read, with every input passing.

### 2.3 The test suite

The newest W3C XML Conformance Test Suite is **20130923** (2,585 cases); there is nothing newer and
no maintained fork (`test-suites.md` §1). The 2002 release predates the Fifth Edition: 309 of its
cases expect the wrong result for a 5th-edition parser. XmlBeef's selection (XML 1.0 5th edition +
Namespaces 1.0) is **2,001 cases**; without reading external entities: **957 must be accepted**
(valid and invalid, since a non-validating parser accepts invalid documents), **951 must be
rejected**, **262 have canonical output to compare byte for byte**, 66 not-wf cases may pass either
way (their error is in an unread external entity) and 27 error cases are logged only. The skip list
starts empty; one catalog path bug (the nine `hst-*` cases) is remapped by the runner. Real-world
corpora: 2,389 SVGs from the W3C SVG 1.1 suite and resvg, all well-formed, including a
Windows-1251 file and SVGs built from internal DTD entities.

## 3. Requirements

The goal set by the author: fast, high-quality code; a feature set like TomlBeef's and KdlBeef's;
reading data formats from disk with SVG as the main case. "Must" is the phase 1–5 scope.

| Feature | Priority | Notes |
|---|---|---|
| Full XML 1.0 5th edition well-formedness + Namespaces 1.0, checked by default | Must | Every WFC and NSC (`spec-reference.md`); speed from fast paths, never from skipping checks (the survey: every library that skips checks has correctness bugs) |
| W3C suite: all 957 accepted, all 951 rejected, 262 canonical outputs byte-exact | Must | `test-suites.md` §5–6; skip/expected-failure lists checked in, a listed failure that starts passing fails the run |
| Internal DTD subset: entity declarations and expansion, ATTLIST defaults and attribute-type normalization, notations kept | Must | Real SVG needs it (Illustrator: `xmlns="&ns_svg;"`); the suite's canonical outputs need defaults, normalization and notations. Entities and defaults apply before namespace resolution |
| Safe by default: never fetch anything external; entity expansion bounded (depth, bytes, amplification) | Must | One `XmlReadConfig` for every entry point; external entities and the external subset are reported (skipped entity), not read |
| Encodings: detection (BOMs, Appendix F, the declaration) ported from StrikeCore's `DetectEncoding`; UTF-8 fast path; UTF-16/32 and table-driven single-byte encodings (Windows-125x, ISO-8859-x, KOI8, …) transcoded at the cursor | Must | §9 item 7: a converter hook for legacy multi-byte encodings, an opt-in Windows-1252 fallback for undeclared non-UTF-8; BOM conflicts as most parsers (§9 item 6) |
| Pull reader (`XmlReader`) under the document builder | Must | StAX/zig-xml style events, views valid until the next call, indexed attributes; zero allocations per event on the fast path |
| Document model (`XmlDocument`, node IDs, handles) | Must | KdlBeef's ID-based node table; elements, text, CDATA, comments, PIs, the prolog and DOCTYPE; interned names |
| Canonical writer + the suite's canonical form | Must | Minimal escaping, `\n`, optional indentation that never touches mixed content; James Clark canonical form for the suite |
| Located errors (line, column, offset, length, source name) | Must | TomlBeef/KdlBeef `ParseError` model, computed on demand |
| Positions sidecar | Must | "path at icons.svg:12:5" diagnostics |
| Resource limits with safe defaults and a `Huge` preset | Must | Depth, nodes, attributes per element, name/text/token bytes, namespace bindings, entity limits, input size |
| Streams: `Read(Stream)` through a bounded window | Must | KdlBeef's buffered cursor; scans resume at the window end (expat's CVE-2023-52425 lesson) |
| PreserveStyle: unchanged documents write back byte for byte; edits regenerate only what changed | Must | The survey's XML slot list (§4.9); the bar is byte-exact on every accepted suite input and the SVG corpora |
| Mutation API | Must | KdlBeef's handle API: add, insert, move, remove, set attribute/text |
| Namespace-aware lookups | Must | `Find(ns, local)`, `TryGetAttribute(ns, local)`; resolved (namespace id, local id) with the prefix kept |
| Compile-time typed mapping (`[XmlObject]`) | Should | KdlBeef's generator with XML roles (§4.12) |
| `ReadSubtree` / skip-element on the reader | Should | Huge files: build a document for one element at a time |
| Namespace-off mode | Should | The suite's nine `NAMESPACE="no"` cases; colon names as plain names |
| Collect-errors with recovery | Must (before integration) | Harder for XML than KDL (resynchronize at `<`, synthesize end tags; KirillOsenkov/XmlParser is the model); phase 7 at the latest |
| Streaming writer (`XmlWriter` emitter) | Later | Generate large XML without a document |
| External entity resolver callback (opt-in, local files) | Later | Enables the suite's second run (1,017 rejects, 379 outputs) |
| XML 1.1 | Not planned | Nobody uses it (expat, .NET, browsers don't support it); `version="1.x"` is read as 1.0 as the 5th edition says |
| Validation (DTD/XSD), XInclude, XPath, XSLT | Not planned | A small path subset for lookups only if the API asks for it |

## 4. Design

### 4.1 Layers

```
bytes ─► encoding detection (BOM, Appendix F) ─► transcoding to UTF-8 if needed ─► UTF-8 validation
      ─► cursor (contiguous, or a bounded stream window)
      ─► XmlReaderCore<TCursor>: tokenizer + well-formedness state machine, entity frames,
         namespace binding stack, interned names
      ─► XmlReader (public pull events)
             ├─► document builder ─► XmlDocument (+ Positions / PreserveStyle sidecar)
             ├─► [XmlObject] generated readers (straight from events)
             └─► user code that wants no document (skimming large files)
XmlDocument ─► canonical writer | preserving writer | suite canonical form
```

KdlBeef's shape. Nothing is layered over the tree (libxml2's xmlReader) or over callbacks; a SAX-style
`Parse<THandler>` adapter over the reader is cheap if it is ever wanted.

### 4.2 Cursor, encodings, validation

- Port KdlBeef's `KdlCursor.bf` (401 lines): the in-memory cursor and the buffered stream cursor
  under one interface, reader core generic over it (`KdlReaderCore<TCursor>` pattern), absolute
  offsets, nested marks and retained spans, `MaxTokenBytes`, at least 8 readable bytes past the
  window end so SWAR scans need no tail loop.
- Refill only when a scan hits the window's end, and resume the scan there, never from the start of
  the construct (quadratic rescans are expat's CVE-2023-52425).
- Encoding (§9 items 6–7): detect by BOM and the first four bytes (Appendix F; StrikeCore's
  `DetectEncoding` ported and extended), then let the `encoding=` declaration pick the decoder.
  UTF-16, UTF-32 and the table-driven single-byte encodings are transcoded to UTF-8 at the cursor
  (one up-front conversion for memory input, a transcoding window for streams); legacy multi-byte
  encodings go through the user's converter hook; EBCDIC, UTF-7 and unknown names are a clear
  error. A UTF-8 BOM wins over a conflicting 8-bit declaration (a warning); a UTF-16/32 BOM with an
  8-bit declaration is an error. Positions are reported in UTF-8 terms plus line and column
  (columns count code points).
- Validate UTF-8 once, before the tokenizer sees the bytes (KdlBeef's `FindInvalid`, 8 ASCII bytes
  at a time). The `Char` production then reduces to a control-byte test in the scanners' slow path
  plus U+FFFE/U+FFFF.
- End-of-line normalization (`\r\n`, lone `\r` → `\n`) happens while copying decoded text, never as
  a separate pass; text without `\r` or `&` stays a view (§4.5).

### 4.3 Scanning

- One 256-entry class table per scanner state, generated at comptime: text stops at `< & \r ]` and
  controls; attribute values at the quote, `< & \r \n \t` and controls; comments at `-`; CDATA at
  `]`; PIs at `?`. Long runs use the siblings' 8-byte SWAR `ScanRun`.
- Rare constraints are checked only where they can occur: `]]>` in text after a `]`, `--` in
  comments at each `-`, the full NameStartChar/NameChar ranges only for bytes ≥ 0x80 (an ASCII table
  and a cold range search).
- End tags compare bytes with the open element's name (TurboXml); they are not parsed and interned
  again.
- Duplicate attributes: compare interned ids (n² up to ~16 attributes, a version-stamped hash above);
  again by (namespace, local) after namespace resolution.

### 4.4 Names

- Names are interned per document into `XmlNameId` (`uint32`): an entry holds the qualified name,
  prefix and local part (views into the store) and a hash. SVG repeats a few dozen names thousands
  of times: comparisons become integer compares and memory drops.
- The reader keeps its own intern table so duplicate, end-tag and namespace checks allocate nothing;
  the document builder adopts it (one table, not a copy) when the reader belongs to a document read.
- A resolved name is (namespace id, local id) with the prefix id kept, for writing and round trips.
- The hash is seeded and never global; names are bounded by `MaxNameBytes`.

### 4.5 Text and attribute values

- Views into the window when nothing needs decoding (no `&`, no `\r`, and for attributes no
  `\t \n`); otherwise decoded into a reusable buffer (KdlBeef's decode buffers). Attribute values
  get §3.3.3 normalization, and tokenized-type normalization when the internal subset declares the
  attribute's type.
- Character and entity references are merged into the surrounding text event in normal mode; in
  PreserveStyle the reader also reports the raw source slice so the writer keeps `&#x41;` vs `A`.
- Text and CDATA are separate events and separate node kinds (never merged, unlike pugixml and
  roxmltree). Whitespace-only text is flagged during the scan, so indentation can be skipped cheaply
  without trimming anything by default.
- The document copies decoded text into its arena (TomlBeef's `NewString`: plain bytes, `StringView`
  out). An element with exactly one text child can store it inline (XLinq), to be measured.

### 4.6 DTD and entities

- `DtdMode { Prohibit, Ignore, Internal }`, default `Internal`: parse the internal subset —
  `<!ENTITY>` (general and parameter, parsed and unparsed), `<!ATTLIST>` (defaults and types),
  `<!NOTATION>`, and syntax-check `<!ELEMENT>` as far as the not-wf cases require. Conditional
  sections are external-subset only, so they are a well-formedness error here.
- The §4.4 treatment table and §4.5 replacement-text construction are implemented exactly
  (`spec-reference.md` §7.3–7.4, Appendix D): character references in entity values are expanded
  when the entity is declared, general entity references when it is used; parameter entities only
  between declarations in the internal subset.
- Expansion pushes an input frame over the replacement text (a stack of windows read by the same
  core), never splices text; it is iterative, with a loop check (No Recursion) and the limits:
  `MaxEntityDepth` (default 20, libxml2's), `MaxEntityExpansionBytes` (default 10 MB, .NET's), and
  an amplification ratio after a threshold (libxml2: 5× with 20 bytes per reference; expat: 100×
  after 8 MiB — pick after measuring the corpora; default proposal 10× after 1 MB).
- Entity Declared: fatal without a DTD, with only an internal subset without parameter-entity
  references, or with `standalone="yes"`; otherwise (an external subset or parameter entity was not
  read) an undeclared reference is a **skipped entity** reported to the reader and kept as a
  reference node, not an error (XHTML's `&nbsp;`). Declarations after an unread external parameter
  entity are ignored unless `standalone="yes"` (`valid-sa-097`).
- External entities and the external subset: reported (public/system IDs kept for writing and for
  a later resolver), never opened.

### 4.7 Namespaces

- A binding stack in the reader: one byte arena plus (prefix id, URI id, depth) records, popped by
  truncation with a deferred pop so `EndElement` still resolves; resolution is a reverse scan (few
  bindings in practice), cached per interned name.
- Every NSC: unbound prefixes, the `xml`/`xmlns` reservations, `xmlns:p=""` in 1.0, colons in local
  parts and in entity/PI/notation names, duplicate (namespace, local) attributes. The default
  namespace does not apply to attributes.
- Cost: nothing for unprefixed elements without `xmlns` attributes.
- The document stores each element's namespace id and its own declarations, never a copy of the
  in-scope set.
- Namespace-off mode (should): names with colons are plain names; used by the suite's nine cases.

### 4.8 Document model

- `XmlDocument` owns everything through a store (TomlBeef/KdlBeef `DocumentStore`: a recycled
  `BumpAllocator`, arena strings as views, `ReleaseCachedMemory`).
- Nodes are IDs (`XmlNodeId`, `uint32`, 0 invalid) into one record table with parent / first child /
  last child / next / previous sibling links and a child count (KdlBeef). Kinds: document, element,
  text, CDATA, comment, PI, entity reference (a skipped or preserved reference), plus the prolog
  items (XML declaration, DOCTYPE) hanging off the document node.
- `XmlNode` is a 16-byte handle (document + ID) with properties that read and write through
  (`node.Name`, `node.Parent`, `node.Children`, `node.TryGetAttribute(...)`).
- Attributes: one document-wide ordered table, each element holding a start and count (KdlBeef's
  entries); records hold name id, value and flags (had references, raw view, defaulted from the
  DTD). No per-element index: lookups scan (KdlBeef measured 28–64 ns for 4–16 entries; SVG elements
  carry 2–15 attributes).
- Lookups (KdlBeef): `Find(name)`, `Find(ns, local)`, `Children.Named`, `Descendants`,
  `TryGetAttribute` with typed getters (`TryGetInt32`, `TryGetDouble`, `TryGetBool`), `Text`
  (concatenated child text), `InnerText`. No query language to start with.
- Mutation (KdlBeef): `AddElement`, `InsertBefore/After`, `Move*`, `Remove`, `SetAttribute`,
  `RemoveAttribute`, `SetText`, `Rename`.

### 4.9 Metadata sidecar: Positions and PreserveStyle

`MetadataMode { None, Positions, PreserveStyle }` in `XmlReadConfig`, as in the siblings: node IDs
key a sidecar, empty in `None`. PreserveStyle uses KdlBeef's mechanism (per-event source slices,
copied into sidecar records only in this mode; the writer reuses a slice while its node is clean):

- the prolog as text: BOM, the XML declaration exactly as written, the DOCTYPE with its internal
  subset verbatim, and comments, PIs and whitespace around the root;
- start tags: whitespace before each attribute, around `=` and before `>`/`/>` (Inkscape writes one
  attribute per line), the quote character, the raw value (reference spellings);
- `<a/>` vs `<a></a>` and `<a />` whitespace; `</a >` whitespace;
- CDATA vs escaped text, raw text (`&gt;` vs `>`, `&#xA0;`, CRLF), whitespace-only nodes, comments,
  PIs;
- references to declared entities stay references (`&ns_svg;` is not written as its expansion).

A changed value drops its raw slice and is regenerated in the original's form (quote kept, minimal
escaping); new attributes follow the element's layout (same line, or the attribute indent of a
multi-line tag). Bar: every accepted suite input and every corpus SVG writes back byte for byte;
edits keep neighbors untouched.

### 4.10 Errors

`XmlParseError { Kind, Message, Line, Column, Offset, Length, Source }` as the siblings'
(per-thread message buffer, no cleanup, `source:line:column: message`), line and column computed on
demand. Kinds are an enum; messages name the construct and the rule ("`--` is not allowed inside a
comment", "prefix `xlink` is not bound"). Golden messages for a representative set of not-wf cases.
Errors are sticky; collect-errors is later (§3).

### 4.11 Writers

- Canonical: double quotes, minimal escaping (`&lt; &amp;`, `&gt;` after `]]`, `&quot;` in
  attributes, `&#9; &#10; &#13;` in attributes so they survive normalization), `<a/>` for empty
  elements, `\n`, optional indentation that never touches mixed content, UTF-8 output.
- Suite canonical form (James Clark's, with Sun's notation block; `test-suites.md` §4): used by
  `XmlTester` for the conformance run.
- Preserving writer: §4.9.

### 4.12 Typed mapping (`[XmlObject]`)

KdlBeef's comptime generator (`KdlSerializerCodeGen.bf`, `KdlBind.bf`, 2,260 lines) with XML roles:

| Member | Default role | Override |
|---|---|---|
| Scalar (numbers, bool, string, enums, date/time via converter) | Attribute, named after the member | `[XmlElement]` for `<name>value</name>`, `[XmlText]` for the element's text |
| `[XmlObject]` type | Child element named after the member | `[XmlName]` |
| `List<[XmlObject]>` | Repeated child elements named after the item type, unwrapped | `[XmlArray("wrapper")]` for a wrapper element |
| Polymorphic children | `[XmlChildren]` dispatch by element name (KdlBeef's `[KdlChildren]`) | |
| Namespaces | Per type (`[XmlObject(Namespace = "...")]`) and per member | |

Names match by interned id; unknown attributes and elements are ignored, with an opt-in strict mode;
numbers are overflow-checked, text is never auto-typed; names as declared by default (every surveyed
library and TomlBeef; §9 item 10), with type-level `CamelCase`/`KebabCase`/`Lower` policies and
`[XmlName]` per member, since one SVG element mixes `stroke-width` and `viewBox`; writing updates a
PreserveStyle document in place.

### 4.13 Resource limits (`XmlReadConfig`)

Defaults (proposals, to confirm on the corpora): `MaxInputBytes` 0 (unlimited), `MaxDepth` 256,
`MaxAttributesPerElement` 4,096, `MaxNameBytes` 50,000, `MaxTextBytes` 10 MB, `MaxTokenBytes`
(streams) 10 MB, `MaxNamespaceBindings` 1,024, `MaxNodes` 0, and the entity limits of §4.6. A `Huge`
preset raises them (libxml2 `XML_PARSE_HUGE`). Content parsing is iterative, so depth costs a frame
record, not stack.

### 4.14 Public API sketch

```beef
let doc = scope XmlDocument();
Try!(doc.ReadFile("icon.svg"));                         // or Read(StringView), ReadBytes, Read(Stream)
let svg = doc.Root;                                     // XmlNode handle
if (svg.TryGetAttribute("viewBox", let viewBox)) ...
for (let path in svg.Descendants.Named("path"))
	Console.WriteLine(path.GetAttribute("d"));

let reader = scope XmlReader();                         // no document
Try!(reader.Reset(stream, .() { MaxDepth = 64 }));
while (Try!(reader.Next()) case let ev && ev != .EndOfDocument)
	if (ev == .StartElement && reader.LocalName == "path") ...
```

## 5. Porting table

| Source file | Use in XmlBeef | Changes |
|---|---|---|
| KdlBeef `KdlCursor.bf` (401) | `XmlCursor.bf` | XML stop classes; transcoding window for UTF-16/single-byte encodings |
| KdlBeef `KdlChar.bf` (535) | `XmlChar.bf` | UTF-8 validation as is; XML Char, NameStartChar/NameChar tables and ranges, whitespace |
| KdlBeef `KdlReader.bf` (1,508) structure | `XmlReaderCore`, `XmlReader` | Generic core, sticky errors, decode buffers, marks; XML tokenizer, entity frames, namespace stack |
| KdlBeef `KdlDocumentStore.bf` (97), TomlBeef `TomlTextArena.bf` | `XmlDocumentStore.bf` | Name table added |
| KdlBeef `KdlDocument.bf`, `KdlNode*.bf`, `KdlDocument.Mutation.bf` (~1,850) | `XmlDocument`, `XmlNode*` | Node kinds, attributes instead of entries, namespaces |
| KdlBeef `KdlDocument.Style.bf` (423) | `XmlDocument.Style.bf` | XML slot list (§4.9) |
| KdlBeef `KdlCanonical.bf` (430) | `XmlCanonical.bf` | XML escaping rules; suite canonical form |
| KdlBeef `KdlError.bf` (172), `KdlSourceRange.bf`, `KdlReadConfig.bf` | same, `Xml` names | XML error kinds, limits, `DtdMode`, encodings |
| KdlBeef `KdlSerializerCodeGen.bf`, `KdlBind.bf`, `KdlObjectAttribute.bf`, `IKdlSerializable.bf`, `KdlSerializer.bf` (~2,600) | `[XmlObject]` | Roles of §4.12 |
| KdlBeef `test-leaks.sh`, `test-roundtrip.sh`, `test-kdl-spec.sh` | `test-leaks.sh`, `test-roundtrip.sh`, `test-xml-conformance.sh`, `test-svg-corpus.sh` | `test-suites.md` §9 |
| TomlBeef `bench/compare/merge.sh`, `update-tomlbeef.sh` | done in `bench/compare/` | |

Port a file when the phase needs it and test it in XmlBeef's own suite; no package dependency on the
siblings.

## 6. Phases

Each phase ends with Debug and Release tests, the leak check, the suite scripts on both binaries and
the Windows tests (`AGENTS.md`), committed.

**Phase 1 — Reader core and conformance runner.** *Done (2026-09-30): 957/957 accepted, 950/951
rejected (`hst-lhs-007` is the listed deviation of §9 item 6), 262/262 canonical outputs byte for
byte, in Debug and Release; DTD processing instructions are reported as events (the canonical outputs
keep them), and the internal subset is a resumable reader state.* Port the cursor, UTF-8 validation and char
tables; encoding detection with UTF-8/UTF-16; the tokenizer and well-formedness state machine
(elements, attributes, text, CDATA, comments, PIs, XML declaration, DOCTYPE with the internal subset,
entities, namespaces); `XmlReader` events; `XmlTester` prints the suite's canonical form from events;
`test-xml-conformance.sh` reads the catalogs (`test-suites.md` §9). Done when the 951 not-wf cases are
rejected, the 957 accepted, and the 262 canonical outputs match.

**Phase 2 — Document and canonical writer.** *Done (2026-09-30): the suite passes in document,
events and rewrite modes (the rewrite mode checks the writer on every accepted case); 2,389 of the
2,390 corpus SVGs pass, the Windows-1251 one waiting for phase 4. The document adopts the reader's
name table; DOCTYPE processing instructions are the DOCTYPE node's children.* Store, name table, node table, attributes, the builder
over reader events, canonical writer, lookups; `XmlTester` reads through the document (events kept as
a second mode, both checked by the script); `test-svg-corpus.sh` over the 2,389 SVGs.

**Phase 3 — Speed.** *Done (2026-10-02): `XmlTester -bench` joins `bench/compare/run.sh`
(`XmlBeef`, `XmlBeef reader`; check lines equal libxml2's on all eight inputs), the fast paths of
`architecture.md` §3 cut instructions per byte by 30–75% (`status.md`), and the timed run puts both
columns past the targets (§2.2).* Join `bench/compare` (a `beef` harness and `XmlTester -bench`), profile, fast
paths. Numeric targets come from the timed run (§2.2); the working targets: the event reader in
quick-xml's class, the document at or above roxmltree (the fastest correct DOM), several times
libxml2 and expat, all while passing every benchmark input and the W3C suite (pugixml is faster but
skips checks and leaves DTD entities unexpanded).

**Phase 4 — Errors, positions, limits, streams, encodings.** *Done (2026-09-30): `Read(Stream)`
through a bounded buffer passes the suite and the corpus with a 16-byte buffer, with the same events
and errors as memory input; 950 golden messages checked in all five script modes; Positions; every
limit tested; the WHATWG single-byte tables (`tools/gen-encoding-tables.py`), the converter hook,
the Windows-1252 fallback; the BOM override reported by `EncodingWarning` (a property rather than a
sidecar slot). See `architecture.md` §3, §4.* Golden messages, Positions sidecar,
every limit with tests, `Read(Stream)` (all input paths produce identical documents and errors),
UTF-32, the single-byte encoding tables (generated from the WHATWG index files by a script kept in
the repository), the converter hook and the opt-in fallback.

**Phase 5 — PreserveStyle and mutation.** *Done (2026-09-30): the 957 accepted suite inputs and
2,390 corpus SVGs write back byte for byte in their own encodings, from memory and from a 16-byte
stream (`test-roundtrip.sh`), and 33,470 runs of random edits read back into the edited documents.
The sidecar records source offsets per node and attribute rather than copied slices (the document
keeps the source), and entity references stay references until what they produced changes. See
`architecture.md` §4.* Sidecar slots of §4.9, preserving writer, mutation API;
byte-exact round trips of every accepted suite input and every corpus SVG; edits keep neighbors.

**Phase 6 — `[XmlObject]`.** *Done (2026-10-01): the generator with §4.12's roles plus token-list
attributes, `[XmlText]`, wrapped lists, aliases, strict types, converters and allocators
(`architecture.md` §6); `bench/compare/run-typed.sh` reads `osm.xml` into one model with XmlBeef,
quick-xml + serde, Go and .NET, all checked; its timed run waits for a quiet machine with P3T.
Dictionaries map in five shapes chosen per field (`[XmlMap]`; the author's default: TypedEntries,
`<int32 name="k">v</int32>`).* The generator with §4.12's roles; a typed benchmark
against quick-xml + serde, Go `encoding/xml` Unmarshal and .NET `XmlSerializer`.

**Phase 7 — Collect-errors, then extras.** *Collect-errors done (2026-10-01): every error reported
and the read goes on (resynchronizing per construct, mismatched end tags closing down to the element
they name, phantom start tags absorbing their end tags), checked by the suite in two more modes and by
`test-collect.sh`'s random damage from memory and streams (`architecture.md` §3). The extras remain,
as needed.* Collect-errors with recovery (required before the
library is integrated; earlier if convenient). Then, as needed: `ReadSubtree`, namespace-off mode
(if not done in phase 1), the streaming writer, the external-entity resolver.

## 7. Testing

- The W3C suite at the strengths of §2.3, with `tests/xmlconf/skip.txt` and
  `tests/xmlconf/expected-failures.txt` (a listed failure that starts passing fails the run); the
  one deliberate deviation, `hst-lhs-007` (§9 item 6), is listed there with its reason.
- The SVG corpora: every file parses; with PreserveStyle every file round-trips byte for byte.
- `[Test]` units per area from `spec-reference.md` §16 (each line is a test), Debug and Release;
  LeakSanitizer; Windows via `~/development/beef-proton`.
- Security tests: billion laughs, quadratic blowup, deep nesting, huge attributes, external entity
  references (must not be opened), each a located limit error.
- The benchmark inputs double as large-input tests (checksums must match the reference).

## 8. Rerunning the benchmark

```bash
tests/fetch-suites.sh                    # W3C XML suite, SVG corpora
cd bench/compare
./fetch.sh && ./build.sh                 # pinned clones and toolchains; every harness into bin/
./gen-inputs.py                          # inputs/
./run.sh > results.md && ./plot.py      # 2–3 h at any load: cells rerun until 3 runs agree within 5%
ONLY='XmlBeef.*' ./run.sh                # later: remeasure only XmlBeef, merged into results.md
```

## 9. Decisions and open questions for the author

Decided in this plan (from the research; override any):

1. **XML 1.1**: not supported; `version="1.1"` documents are read with 1.0 rules (the 5th edition's
   own rule for unknown 1.x versions).
2. **DTD**: the internal subset is parsed and applied (entities, ATTLIST defaults and types,
   notations); nothing external is ever read; no validation.
3. **Checks**: full well-formedness by default; no lenient mode until a measurement asks for one.
4. **PreserveStyle**: byte-exact (KdlBeef's bar), since the reader hands out source slices.
5. **Typed mapping**: scalars are attributes by default.

Decided by the author (2026-09-30):

6. **BOM vs `encoding=` conflicts: do what most parsers do** (measured, below): a **UTF-8 BOM wins**
   over a declaration naming another ASCII-compatible encoding (read as UTF-8, a warning in the
   Positions/PreserveStyle sidecar); a **UTF-16 BOM with a declaration of an 8-bit encoding is an
   error**. This deviates from the spec on one suite case, `hst-lhs-007`, which goes in the
   expected-deviations list with this reason. Measured with every benchmark harness on the suite's
   three cases (`eduni/misc/007–009.xml`; the libraries that cannot read UTF-16 are n/a for 008/009):

   | Case | Accept | Reject |
   |---|---|---|
   | 007: UTF-8 BOM + `encoding='iso-8859-1'` | 27: libxml2 (tree and reader), lxml, pugixml, Xerces-C, expat, ElementTree, roxmltree, quick-xml, xmlparser, the JDK's SAX/StAX/DOM, Woodstox, Aalto, the three .NET models, TurboXml, etree, xmlquery, fast-xml-parser, xml2js, sax-js, BeefXml, Xml-Beef | 7: xml-rs, xmltree, zig-xml, nektro/zig-xml, encoding/xml, XmlParser (C#), Beef-Lang-XML |
   | 008: UTF-16 BOM + `encoding='utf-8'` (UTF-16 bytes) | 7: libxml2 (both), lxml, pugixml (both), TurboXml, Xml-Beef | 17: expat, Xerces-C, ElementTree, the JDK's SAX/StAX/DOM, Woodstox, Aalto, the three .NET models, xml-rs, xmltree, xmlquery, zig-xml, BeefXml, Beef-Lang-XML |
   | 009: UTF-16 BOM, then UTF-8 bytes | 2: TurboXml, Xml-Beef (no checks) | everything else |
7. **Encodings: detection plus table-driven decoders.** Port the author's detector from StrikeCore
   (`~/development/strikeline/Packages/com.coda-digital.strikecore/Runtime/ChartParser/IO/FeedbackChart/ParsingTools.cs`,
   `DetectEncoding`: BOMs for UTF-8/16/32 and UTF-7's rejection, then strict UTF-8, then a
   single-byte fallback) and expand it with XML's rules:
   - Appendix F first: BOMs (UTF-8, UTF-16 LE/BE, UTF-32 LE/BE), then the `<?xm` byte patterns
     without a BOM; then the `encoding=` declaration selects the decoder (resvg's
     `not-UTF-8-encoding.svg` declares `Windows-1251`, so declared encodings are the real need).
   - Decoders: UTF-8 (fast path, no transcoding), UTF-16 and UTF-32 transcoded to UTF-8 at the
     cursor, and **table-driven single-byte encodings** generated from the WHATWG index files:
     Windows-874 and 1250–1258, ISO-8859-1…16, KOI8-R/U, IBM866, Macintosh (128 entries each, ~15 KB
     in all), plus US-ASCII. Legacy multi-byte encodings (Shift_JIS, EUC-JP, GBK/GB18030, Big5,
     EUC-KR) need large tables: a user converter hook (`XmlReadConfig.EncodingResolver`) rather than
     built-ins.
   - StrikeCore's heuristic (no BOM, no declaration, invalid UTF-8 → Latin-1) is not what the spec
     allows (undeclared non-UTF-8 is a fatal error), but is how hand-edited files in the wild get
     read: an opt-in `EncodingFallback` (Windows-1252, a superset of Latin-1's printable range), off
     by default and never used for the conformance run.
   - Unknown or unsupported declared encodings, UTF-7, EBCDIC: a clean located error.
8. **Error columns count characters** (code points), as in the siblings.
9. **Entity amplification**: 10× after 1 MB (between libxml2's 5× and expat's 100× after 8 MiB),
   with depth 20 and 10 MB total; to confirm against the corpora in phase 4.
10. **Typed-mapping names: as declared**, which is what every surveyed library does (.NET
    `XmlSerializer` and Go `encoding/xml` use the member name verbatim, serde the field name with an
    optional `rename_all`, JAXB the property name) and what TomlBeef does. Kebab-case (KdlBeef's
    default) would be wrong for XML formats as a default: SVG alone mixes `stroke-width` with
    `viewBox`, `gradientUnits` and `linearGradient`; Maven and Android use camelCase, `.csproj`
    PascalCase, Atom lowercase. Type-level policies (`CamelCase`, `KebabCase`, `Lower`) and
    per-member `[XmlName]` cover the rest.
11. **Collect-errors: required**, before the library is integrated anywhere; its phase does not
    matter (phase 7 at the latest, §6).
