# XmlBeef Architecture

How XmlBeef works today and why. It is not a task list: open work is in [status.md](status.md), the
phases still to come in [plan.md](plan.md), the XML rules in [spec-reference.md](spec-reference.md).
Code conventions and Beef gotchas are in `AGENTS.md`.

## 1. Overview

- An XML 1.0 (Fifth Edition) + Namespaces 1.0 library for Beef. Today it has a **pull reader**
  (`XmlReader`) over bytes in memory and the W3C suite's **canonical form** (`XmlCanonical`). The
  document, writers, streams, PreserveStyle and typed mapping follow (`plan.md` §6).
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
`XmlReaderTests`: API, encodings, DTD modes, locations, security and limits). The CLI is
`XmlTester/src/Program.bf`; the scripts are `test-xml-conformance.sh` (W3C suite, catalogs read by
`tests/xmlconf/manifest.py`) and `test-leaks.sh`.

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
open-addressing table over IDs with a seeded hash, text in a `BumpAllocator` that never moves. An
entry caches whether it is a valid QName and the IDs of its prefix and local part. End tags compare
bytes with the open element's interned name and do not intern again; duplicate attributes compare
IDs (pairwise up to 16, a set above).

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

## 4. The suite's canonical form

`XmlCanonical.WriteSuiteForm` drives a reader: start tags with attributes sorted by name bytes,
start-end pairs, the suite's escapes (`& < > "`, tab, LF, CR) in text and values, PIs as
`<?target data?>`, and at the DocType event a `<!DOCTYPE root [ … ]>` block of the declared notations
sorted by name (public identifiers normalized). It reproduces all 262 OUTPUT files of the selection.
