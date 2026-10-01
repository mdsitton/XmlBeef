# XmlBeef Architecture

How XmlBeef works today and why. It is not a task list: open work is in [status.md](status.md), the
phases still to come in [plan.md](plan.md), the XML rules in [spec-reference.md](spec-reference.md).
Code conventions and Beef gotchas are in `AGENTS.md`.

## 1. Overview

- An XML 1.0 (Fifth Edition) + Namespaces 1.0 library for Beef. Today it has a **pull reader**
  (`XmlReader`) over bytes in memory, a **document** built on it (`XmlDocument` with `XmlNode`
  handles, lookups and a canonical writer) and the W3C suite's **canonical form** (`XmlCanonical`).
  Streams, positions, PreserveStyle, mutation and typed mapping follow (`plan.md` §6).
- **Strict.** Every well-formedness and namespace constraint is checked; the first error stops the
  read with a located `XmlParseError` (kind, message, line, column in code points, byte offset,
  length, source name).
- **Safe.** Nothing external is ever opened. The internal subset is read and applied; external
  entities and the external subset are reported, never fetched. Entity expansion is bounded by
  depth, total bytes and an amplification ratio, each a located `ResourceLimitExceeded`.
- **Few allocations.** Event strings are views of the input, of an entity's replacement text or of
  the name table; only text that needs decoding (references, CR line ends, attribute whitespace) is
  copied, into reusable buffers.

## 2. Source layout

| File (`src/XmlBeef/`) | Responsibility |
|---|---|
| `XmlDocument.bf` | `XmlNodeKind`; `XmlDocument`: the node and attribute tables (`XmlNodeRecord`, `XmlAttributeRecord`), the declaration and DOCTYPE fields, `Read`/`ReadBytes`/`ReadFile` (the builder over `XmlReader`), `Clear`, `GetNode` |
| `XmlDocument.Write.bf` | `XmlWriteOptions`; the canonical writer (`Write`) and its escaping |
| `XmlNode.bf` | `XmlNodeId`, the `XmlNode` handle (kind, names, value, navigation), `XmlNodeList`, `XmlElementList`, `XmlAttribute`, `XmlAttributeList` |
| `XmlNode.Lookup.bf` | `Find` (by name, by namespace and local name), attribute lookups and typed getters, `Text`/`AppendText`/`AppendInnerText`, `XmlDescendants`, `XmlValueParser` |
| `XmlDocumentStore.bf` | Internal: the document's text (its copy of the input, decoded values) in an `XmlTextArena` |
| `XmlTextArena.bf`, `XmlStack.bf` | Internal: a chunked byte arena that keeps its chunks across resets; a growable array with inlined `Add`/`PopBack`/indexer |
| `XmlReader.bf` | `XmlEvent`; `XmlReader` (public: events, names, namespaces, attributes, DOCTYPE and declaration fields), dispatching to the core |
| `XmlReaderCore.bf` | `XmlFailure`; `XmlReaderCore<TCursor>`: states and the step loop, prolog/epilog and content steps, entity input frames, expansion accounting, the window helpers, name scanning, `Fail` |
| `XmlReaderCore.Tags.bf` | Start and end tags, attribute values (normalization, references), ATTLIST defaults and types, namespace binding and resolution, duplicate checks |
| `XmlReaderCore.Text.bf` | Character data and references, comments, PIs, CDATA sections, the XML declaration |
| `XmlReaderCore.Dtd.bf` | DOCTYPE, the internal subset as a resumable state, ENTITY / ATTLIST / ELEMENT / NOTATION declarations, parameter-entity references |
| `XmlDtd.bf` | `XmlStandalone`, `XmlNotation` (public); `XmlEntity`, `XmlAttributeDecl`, `XmlDtd` (internal) |
| `XmlNameTable.bf` | `XmlNameId` (public); `XmlNameTable`: interning with stable text, cached QName split |
| `XmlEncoding.bf` | `XmlEncoding` (public); `XmlEncodingDetector`: BOM and Appendix F detection, the declaration's encoding, transcoding to UTF-8 |
| `XmlCursor.bf` | `IXmlCursor`, `XmlByteCursor` (in memory), `XmlLineCounter` |
| `XmlChar.bf` | Name byte classes and the Fifth Edition ranges, `Char`, `S`, PubidChar, UTF-8 decode/encode, `FindInvalid`, line/column |
| `XmlCanonical.bf` | `XmlCanonical.WriteSuiteForm`: James Clark's canonical XML with Sun's notation block, from events |
| `XmlError.bf`, `XmlReadConfig.bf` | `XmlErrorKind`, `XmlParseError` (KdlBeef's model); `XmlReadConfig`, `XmlMetadataMode`, `XmlDtdMode` |

Tests are in `src/XmlBeef/tests/` (`XmlEdgeCaseTests`: spec-reference §16 one test each;
`XmlReaderTests`: API, encodings, DTD modes, locations, security and limits; `XmlDocumentTests`:
the tree, lookups and the writer). The CLI is `XmlTester/src/Program.bf`; the scripts are
`test-xml-conformance.sh` (W3C suite in document, events and rewrite modes; catalogs read by
`tests/xmlconf/manifest.py`), `test-svg-corpus.sh` (the SVG corpora) and `test-leaks.sh`.

## 3. Reading

### Encodings and validation

`XmlEncodingDetector.Prepare` runs once, at the cursor's `Begin`. Byte order marks (UTF-32's before
UTF-16's, since `FF FE 00 00` starts like `FF FE`), then Appendix F's byte patterns for BOM-less
16- and 32-bit input, EBCDIC and UTF-7 (rejected), else ASCII-compatible. The `encoding=` of the XML
declaration is pre-scanned leniently (only EncName syntax; the reader parses the declaration
strictly later) and picks the decoder of an ASCII-compatible document: UTF-8 is read as is,
ISO-8859-1 and US-ASCII are transcoded or checked. UTF-16 and UTF-32 are transcoded to UTF-8 into a
buffer the reader owns, with surrogates checked. Conflicts follow the author's decision (`plan.md` §9
item 6): a UTF-8 BOM wins over another ASCII-compatible declaration (the one suite deviation,
`hst-lhs-007`); a 16/32-bit document declaring an 8-bit encoding, or the reverse, is an error. Error
positions are in UTF-8 terms with line and column.

`XmlChar.FindInvalid` then checks the whole UTF-8 text once: ill-formed sequences, and code points
outside `Char` (C0 controls other than tab/LF/CR, U+FFFE, U+FFFF; surrogates and overlongs as UTF-8
errors). Words of plain ASCII are skipped 8 bytes at a time. After that no scanner tests for illegal
characters: character references are checked where they are decoded.

### The window and the cursor

KdlBeef's design: `XmlReaderCore<TCursor>` reads `mData[offset]` for `mBase <= offset < mEnd`
through `Avail`/`AvailN`/`At`/`StartsWith`, which call `Grow` (and so `IXmlCursor.Fill`) at the
window's end. `XmlByteCursor`'s `Fill` is an inlined `false`, so for memory input the helpers fold to
compares. The stream cursor (phase 4) slots in here.

### Entity input frames

Entity replacement text is read by the same code as the document: a reference pushes an
`InputFrame` (the current window and the position after the reference) and makes the replacement
text the window; at its end (`Avail` is false, and `Grow` never refills inside a frame) the frame
pops. This one mechanism gives:

- **content** (§4.4.2 "included"): text continues across both ends of a reference and is merged
  into one Text event; markup inside the entity is read where it is; an element must end in the
  entity it starts in (`PopFrame` checks the element count, `ReadEndTag` the element's frame level);
  constructs cannot cross a frame's end because the window ends there;
- **attribute values** (§4.4.5 "included in literal"): the value loop pops frames itself; inside a
  frame a quote is data, `<` is the No-< error, and each whitespace character becomes a space;
- **the internal subset** (§4.4.8 "included as PE"): a parameter entity's replacement text is stored
  with a space at each end and read between declarations; a declaration must end in the frame it
  starts in.

Line ends are normalized in the document only: a CR in replacement text came from `&#13;` and is
data. Recursion is caught by an `mExpanding` flag per entity (No Recursion), depth by
`MaxEntityDepth`; every push adds the replacement text's length to the expansion count, checked
against `MaxEntityExpansionBytes` and, past `EntityAmplificationThreshold`, against
`MaxEntityAmplification` times the input size (`plan.md` §9 item 9). ATTLIST defaults built from
entity references count again each time they are applied. Errors inside an entity are located at
the outermost reference and name the entity.

### The state machine

`Next` resumes a loop over states, each step reading one construct and returning its event or none:

- **Prolog / Epilog**: whitespace, comments, PIs; in the prolog the XML declaration (only at the
  first content byte, after a BOM), one DOCTYPE, then the root's start tag; in the epilog nothing
  else.
- **InternalSubset**: declarations, comments and parameter-entity references are read until a PI
  (reported: the suite's canonical form keeps DTD PIs) or the closing `]`, then the DocType event.
- **Content**: start tags, end tags, text, comments, PIs, CDATA; the end of an entity frame pops it.
  The root's end moves to Epilog.

An empty-element tag reports StartElement (`IsEmptyElement`) and its EndElement on the next call,
so events always balance. Errors are sticky (`Failed`); internal methods return
`Result<T, XmlFailure>` with an empty error type and `Fail` records the real error (KdlBeef's
measured choice).

### Names

Element and attribute names (and namespace URIs) are interned in the reader's `XmlNameTable`: an
open-addressing table over IDs with a seeded hash, text in an `XmlTextArena` that never moves. Each
slot holds the ID and the hash, so a probe that misses reads no entry; the hash reads whole words
(overlapping at the end, never past it) and takes the slot bits from a final multiply's high half.
In front of it, a 256-entry direct-mapped cache (first byte, last byte, length) answers repeated names
with one compare. The four names the namespace rules need (`xml`, `xmlns` and their URIs) are static
entries at fixed IDs that survive `Clear`. An entry caches whether it is a valid QName and the IDs of
its prefix and local part. End tags compare bytes with the open element's interned name and do not
intern again; duplicate attributes compare IDs (pairwise up to 16, a set above).

### Fast paths

Phase 3 measured with instruction counts (`bench/instructions.sh`, which load does not distort) and
`perf`. What paid:

- **Word-at-a-time scans**: text runs stop at `<`, `&`, `]` or CR and attribute values at their quote,
  `<`, `&` or a byte below 0x20, 8 bytes at a time (`XmlChar.BytesEqual`, `BytesBelowSpace`); the
  word holding a stop is walked byte by byte (Beef has no trailing-zero-count intrinsic).
- **Validation**: `FindInvalid` checks 32 bytes per step, also when they hold tab, LF or CR (an LF in
  every 32-byte window of indented text had sent it to the 8-byte path, 5.7 instructions per byte).
- **What validation guarantees**: after it, a byte up to 0x20 in the window is space, tab, LF or CR,
  so the reader's whitespace test is one compare.
- **Start tags**: ASCII names scanned inline (`ScanAsciiName`, the full `ScanName` only for non-ASCII,
  the window's end or an error); a plain attribute value found inline; namespace processing skipped
  for a tag with no prefix and no `xmlns` (only the default namespace is looked up).
- **Inlining**: the per-event lists (open elements, bindings, a tag's attributes, the document's node
  and attribute tables) are `XmlStack`s with inlined `Add`/`PopBack`/indexer (corlib's `List.Add` is
  not inlined); `StepContent`, `TextEvent`, `EndElement` and `Intern` are `[Inline]`; no
  `Runtime.Assert` on a hot path (it stays in Release).
- **Transcoding**: UTF-16 is written into a buffer sized for the worst case, runs of ASCII four units
  at a time (book-utf16: 43 to 11 instructions per byte).
- **Per-document costs**: arenas (`XmlTextArena`) that keep their chunks across resets instead of
  allocators rebuilt per document, a DTD cleared only after a DOCTYPE, the document copying its input
  once and keeping values that view the copy (only decoded text is copied). A tiny document went from
  5,600 to 2,000 instructions, which mattered for 17,000 small SVG files.

### Attributes

A start tag's attributes are read eagerly into `mAttributes` records (name ID, value, buffer range,
offset, specified). A value is a view when nothing needs decoding, else it is decoded into one
buffer for the tag, and views into it are made once the tag is complete. Then, in order: duplicate
names; ATTLIST declarations of the element type (non-CDATA types trim and collapse spaces; defaults
added, unspecified); namespaces. Defaults therefore take part in namespace binding (`<!ATTLIST a
xmlns:p CDATA #FIXED "u">`).

### Namespaces

A binding stack of (prefix ID, URI ID); an element records its stack height, and its bindings are
popped on the call after its EndElement, so the EndElement event still resolves. Prefixes resolve by
a reverse scan. Every NSC is checked: QName syntax of element and attribute names (and of names in
DOCTYPE, ELEMENT and ATTLIST declarations), unbound prefixes, the `xml`/`xmlns` reservations, no
undeclaring in 1.0, `xmlns` element prefixes, unique (namespace, local) attributes, and no colons in
PI targets, entity and notation names. `XmlReadConfig.Namespaces = false` turns all of it off.

### The DTD

`XmlDtd` holds general and parameter entities (first declaration binds), attribute declarations by
element name ID (first definition binds), and notations. Entity values get character references
expanded and general references kept as written (§4.5); parameter-entity references inside
declarations are an error in the internal subset. Content models are checked for syntax only,
without recursion. Entity Declared (§4.1) is a WFC with no DTD, an internal subset with no external
subset and no parameter-entity references, or `standalone="yes"`; otherwise an undeclared reference
is an `EntityReference` event (a skipped entity) in content and dropped in attribute values. An
undeclared entity in an ATTLIST default is remembered and decided when the DOCTYPE ends. After an
unread parameter entity (external or undeclared) ENTITY and ATTLIST declarations are parsed but not
processed unless standalone (§5.1). `XmlDtdMode.Ignore` checks the DOCTYPE but applies nothing;
`Prohibit` rejects it.

## 4. Document

### Nodes are IDs

KdlBeef's model. A node is an `XmlNodeId` into `XmlDocument.mNodes`, a list of `XmlNodeRecord`s:
kind, flags, name ID, namespace ID, value, attribute range, child count and the links (parent, first
and last child, next and previous sibling; 0 is none). Record 0 is the document node, whose children
are the prolog's comments and PIs, the DOCTYPE node, the root element and what follows it; the
DOCTYPE node's children are the internal subset's PIs (the infoset's DTD item, which the builder
links when the DocType event comes, after them). `XmlNode` is a 16-byte handle (document, ID,
generation): the generation changes on every `Clear` and `Read`, so a stale handle is invalid rather
than showing other content, and the live views (`Children`, `Attributes`, `Named`, `Elements`,
`Descendants` and their enumerators) check it the same way (`CheckView`). The `Removed` flag is in
place for mutation (phase 5).

### Names, attributes and text

The document owns an `XmlNameTable` and hands it to its reader (`XmlReader.Reset(…, names)`), so the
reader interns straight into it: element, attribute, PI-target and entity names are IDs in the node
and attribute records, with no copy. Attributes are one document-wide table, each element holding a
start and count (KdlBeef's entries): name, local name and namespace IDs, the value, and a `Defaulted`
flag for ATTLIST defaults. Lookups scan an element's few attributes comparing names. The document
copies its input once into its store (`XmlDocumentStore`, an `XmlTextArena` whose chunks are reused
across reads) and reads that copy, so text and values that view it are kept as views; decoded ones
(references, line ends), the DOCTYPE's identifiers and internal subset are copied. The declaration
(version, encoding, standalone) and the notations are document fields.

### Lookups

`Find(name)` and `Find(ns, local)` give the first matching child element; `Children.Named`,
`Children.Elements` and `Descendants` (elements only, depth first, optionally `.Named`) walk the
links without allocating. Lookups and getters accept the empty handle a failed `Find` returns, so
chains end in the fallback. Typed attribute getters parse XML's forms, culture-independent:
`TryGetInt32`/`Int64` (sign and digits, overflow checked), `TryGetDouble` (decimal with fraction and
exponent, `INF`, `-INF`, `NaN`), `TryGetBool` (`true`, `false`, `1`, `0`), all with surrounding
whitespace allowed. `Text` joins the node's own Text and CDATA children (a view for a single piece, a
store copy for several); `AppendInnerText` collects every descendant's text.

## 5. Writing

`XmlDocument.Write` gives the canonical form (plan.md §4.11): the declaration (version as read,
`encoding="UTF-8"`, standalone if given), the DOCTYPE with its internal subset verbatim (it keeps the
entity and ATTLIST context, so skipped references are written back as `&name;` and defaulted
attributes are left to it), comments, PIs (`<?t?>` without data), CDATA sections (split at `]]>`),
`<a/>` for empty elements, double-quoted attributes. Escaping is minimal: text `&`, `<`, `>` only
after `]]`, CR as `&#13;`; attributes `&`, `<`, `"` and tab/LF/CR as character references. Each node
outside the root, and the root, ends a line. `XmlWriteOptions.Indent` indents the children of
element-only content (whitespace-only text there is replaced) and leaves mixed content, and everything
inside it, untouched. The walk follows the links, without recursion. Checked by the suite's rewrite
mode (every accepted case's suite form survives write and re-read) and the corpus script (also a
fixed point: writing the written document changes nothing).

`XmlCanonical.WriteSuiteForm` produces the suite's form from a reader or from a document: start tags
with attributes sorted by name bytes, start-end pairs, the suite's escapes (`& < > "`, tab, LF, CR) in
text and values, PIs as `<?target data?>`, and at the DOCTYPE its PIs and a `<!DOCTYPE root [ … ]>`
block of the declared notations sorted by name (public identifiers normalized). It reproduces all 262
OUTPUT files of the selection both ways.
