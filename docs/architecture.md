# XmlBeef Architecture

How XmlBeef works today and why. It is not a task list: open work is in [status.md](status.md), the
phases still to come in [plan.md](plan.md), the XML rules in [spec-reference.md](spec-reference.md).
Code conventions and Beef gotchas are in `AGENTS.md`.

## 1. Overview

- An XML 1.0 (Fifth Edition) + Namespaces 1.0 library for Beef. Today it has a **pull reader**
  (`XmlReader`) over bytes in memory or a `Stream`, a **document** built on it (`XmlDocument` with
  `XmlNode` handles, lookups, optional source positions, mutation, a canonical writer and a
  style-preserving one), compile-time **typed mapping** (`[XmlObject]`, `XmlSerializer`) and the W3C
  suite's **canonical form** (`XmlCanonical`).
- **Strict.** Every well-formedness and namespace constraint is checked; the first error stops the
  read with a located `XmlParseError` (kind, message, line, column in code points, byte offset,
  length, source name), or with collect-errors every error is reported and the read goes on (§3).
- **Safe.** Nothing external is ever opened. The internal subset is read and applied; external
  entities and the external subset are reported, never fetched. Entity expansion is bounded by
  depth, total bytes and an amplification ratio, each a located `ResourceLimitExceeded`.
- **Few allocations.** Event strings are views of the input, of an entity's replacement text or of
  the name table; only text that needs decoding (references, CR line ends, attribute whitespace) is
  copied, into reusable buffers.

### FormatCore

Since 2026-10-03 XmlBeef is built on FormatCore (https://github.com/mdsitton/FormatCore, the shared core of
TomlBeef, KdlBeef, XmlBeef and JsonBeef; its `docs/architecture.md` has the designs, its
`docs/migration.md` §9 what moved here). XmlBeef keeps its grammar, reader core, error kinds and
messages, document, writers, recovery and typed-mapping roles; from FormatCore it takes: SWAR, UTF-8
and hex helpers and the validator (`Utf8.FindInvalid<XmlText>`), `ParseError`/`Diagnostic` (as
`XmlParseError`/`XmlDiagnostic`), the encodings (`Decoder`, `Encoder`, the generated single-byte
tables, the transcoding cursors, with XML's detection as `XmlDetector`), `LineCounter`, `LineIndex`,
`GrowList`, `TextArena`, `KeptSource`, `ReadShell`, `ByteHash` (the name table's hash), `DecimalParse`
(typed doubles), `Tree` (node links), `SideTable` and `Marks`, and the typed-mapping driver, registry,
naming and helpers (§6). The text below names the XML-side types; where it describes an algorithm
that moved (decoding, line counting, links), the code is FormatCore's.

## 2. Source layout

| File (`src/XmlBeef/`) | Responsibility |
|---|---|
| `XmlDocument.bf` | `XmlNodeKind`; `XmlDocument`: the node and attribute tables (`XmlNodeRecord`, `XmlAttributeRecord`), the declaration and DOCTYPE fields, `Read`/`ReadBytes`/`ReadFile` (the builder over `XmlReader`), `Clear`, `GetNode` |
| `XmlDocument.Write.bf` | `XmlWriteOptions`; `Write` (preserving or canonical), the canonical writer (`WriteCanonical`) and its escaping |
| `XmlDocument.Style.bf` | PreserveStyle: `XmlNodeStyle`/`XmlAttributeStyle` records, capture during a read, change marks, the preserving writer |
| `XmlDocument.Mutation.bf` | Links, removal, namespace resolution after changes, the attribute table's moves, name/text checks, `WriteBytes`/`WriteFile` |
| `XmlDocument.Compact.bf` | `XmlMemoryUsage`; `MemoryUsage`, `Compact`, `Clear(releaseMemory)` |
| `XmlNode.Mutation.bf` | The public mutation API on `XmlNode` |
| `XmlObjectAttribute.bf` | `[XmlObject]` and the field attributes, `XmlNaming`, `IXmlSerializable`, `IXmlConverter<T>` |
| `XmlSerializerPlan.bf` | The comptime generator's planning half: field kinds and roles (`FieldPlan`, `PlanField`, `PlanMap`), the chain's claimed names and conflicts (`ScanChain`), naming and type helpers (§6) |
| `XmlSerializerCodeGen.bf` | The comptime generator's entry (`Emit`) and emission: the code of `XmlRead`/`XmlWrite` from the plans (§6) |
| `XmlBind.bf` | The generated code's runtime: `XmlValueRef`, `XmlValueWriter`, the cursors, `XmlBind` |
| `XmlMap.bf` | Dictionaries' runtime: `XmlMapEntries` (reading), `XmlMapWriter` (writing in place) |
| `XmlSerializer.bf` | One-call `Read`/`ReadFile`/`Write`/`WriteFile` of whole documents as `[XmlObject]` types |
| `XmlNode.bf` | `XmlNodeId`, the `XmlNode` handle (kind, names, value, navigation), `XmlNodeList`, `XmlElementList`, `XmlAttribute`, `XmlAttributeList` |
| `XmlNode.Lookup.bf` | `Find` (by name, by namespace and local name), attribute lookups and typed getters, `Text`/`AppendText`/`AppendInnerText`, `XmlDescendants`, `XmlValueParser` |
| `XmlDocumentStore.bf` | Internal: the document's text (its copy of the input, decoded values) in an `XmlTextArena` |
| `XmlTextArena.bf`, `XmlStack.bf` | Internal typealiases of FormatCore's `TextArena` (a chunked byte arena that keeps its chunks across resets) and `GrowList<T>` (a growable array with inlined `Add`/`PopBack`/indexer) |
| `XmlReader.bf` | `XmlEvent`; `XmlReader` (public: events, names, namespaces, attributes, DOCTYPE and declaration fields), dispatching to the core |
| `XmlReaderCore.bf` | `XmlFailure`; `XmlReaderCore<TCursor>`: states and the step loop, prolog/epilog and content steps, entity input frames, expansion accounting, the window helpers, name scanning, `Fail` |
| `XmlReaderCore.Tags.bf` | Start and end tags, attribute values (normalization, references), ATTLIST defaults and types, namespace binding and resolution, duplicate checks |
| `XmlReaderCore.Text.bf` | Character data and references, comments, PIs, CDATA sections, the XML declaration |
| `XmlReaderCore.Recovery.bf` | Collect-errors: `Recover` and its resynchronization helpers |
| `XmlReaderCore.Dtd.bf` | DOCTYPE, the internal subset as a resumable state, ENTITY / ATTLIST / ELEMENT / NOTATION declarations, parameter-entity references |
| `XmlDtd.bf` | `XmlStandalone`, `XmlNotation` (public); `XmlEntity`, `XmlAttributeDecl`, `XmlDtd` (internal) |
| `XmlNameTable.bf` | `XmlNameId` (public); `XmlNameTable`: interning with stable text, cached QName split |
| `XmlEncoding.bf` | `XmlEncoding`, `XmlEncodingFallback`, `XmlEncodingConverter` (public typealiases of FormatCore's `TextEncoding`, `EncodingFallback`, `EncodingConverter`) |
| `XmlEncodingDetector.bf` | `XmlDetector` (FormatCore's `IEncodingDetector`): BOM and Appendix F detection, the declaration's encoding and the BOM/declaration conflicts |
| `XmlCursor.bf` | `IXmlCursor`, and `XmlByteCursor` (in memory) and `XmlBufferedStreamCursor` (a `Stream` through a bounded buffer): inlined adapters over FormatCore's transcoding cursors; `XmlLineCounter`, `XmlStreamState` (typealiases), `XmlInput` (settings and error mapping) |
| `XmlText.bf` | `XmlText`: XML's character rules as FormatCore's `ITextPolicy` (`Char`, LF/CR/CRLF) |
| `XmlSourceRange.bf` | `XmlSourceRange` (public): a node's or attribute's source position |
| `XmlChar.bf` | Name byte classes and the Fifth Edition ranges, `Char`, `S`, PubidChar; `FindInvalid` and line/column through FormatCore |
| `XmlCanonical.bf` | `XmlCanonical.WriteSuiteForm`: James Clark's canonical XML with Sun's notation block, from events |
| `XmlError.bf`, `XmlReadConfig.bf` | `XmlErrorKind`, `XmlParseError` (KdlBeef's model); `XmlReadConfig`, `XmlMetadataMode`, `XmlDtdMode` |
| `XmlDiagnostic.bf` | `XmlDiagnostic`: an error that owns its text (§4 "Lifetimes") |

Tests are in `src/XmlBeef/tests/` (`XmlEdgeCaseTests`: spec-reference §16 one test each;
`XmlReaderTests`: API, encodings, DTD modes, locations, security and limits; `XmlDocumentTests`:
the tree, lookups and the writer; `XmlEncodingTests`, `XmlStreamTests`, `XmlPositionsTests`,
`XmlFastPathTests`, `XmlPreserveTests`, `XmlMutationTests`, `XmlCompactTests`, `XmlObjectTests`,
`XmlCollectTests`, and `XmlReviewTests`: one regression per finding of the 2026-10-01 review). The CLI
is `XmlTester/src/Program.bf` (with `Bench.bf`, `Mutate.bf`, `Fuzz.bf` and `Memory.bf`); the scripts
are `test-codegen.sh` (the generator's build-time checks: `tests/codegen/` fixtures that must stop the
build with their message, or build), `test-roundtrip.sh` (PreserveStyle),
`test-collect.sh` (collect-errors under random damage) and
`test-xml-conformance.sh` (W3C suite in document, events, rewrite, stream, stream-events, collect and
stream-collect modes,
with golden messages; catalogs read by `tests/xmlconf/manifest.py`), `test-svg-corpus.sh` (the SVG
corpora, also streamed) and `test-leaks.sh`.

## 3. Reading

### Encodings and validation

(Since the FormatCore migration the decoder, the tables, `Prepare` and the stream cursor are
FormatCore's `Decoder`, `SingleByteTables`, `Transcoding.Prepare` and transcoding cursors; detection is
`XmlDetector`, and the whole-text check is `Utf8.FindInvalid<XmlText>` with JsonBeef's byte-naming
messages. The rules below are unchanged.)

`XmlEncodingDetector.Detect` runs once, at the cursor's `Begin`, over the first 4 KB. Byte order
marks (UTF-32's before UTF-16's, since `FF FE 00 00` starts like `FF FE`), then Appendix F's byte
patterns for BOM-less 16- and 32-bit input, EBCDIC and UTF-7 (rejected), else ASCII-compatible. The
`encoding=` of the XML declaration is pre-scanned leniently (only EncName syntax; the reader parses
the declaration strictly later); a declaration that goes on past the 4 KB prefix is "incomplete", not
"absent", and memory and stream preparation read on (doubling, up to `MaxTokenBytes`) until its
encoding is known. It picks the decoder of an ASCII-compatible document: UTF-8 is read
as is; US-ASCII is checked strictly; ISO-8859-1, -9 and -11 are the exact ISO standards (C1 controls
at 0x80–0x9F); every other single-byte label (windows-125x, ISO-8859-x, KOI8, Mac, IBM866) maps to a
table generated from the WHATWG index files by `tools/gen-encoding-tables.py` (pinned by SHA-256), an
unmapped byte being an `InvalidEncoding` error. `XmlDecoder` transcodes UTF-16, UTF-32 and the 8-bit
encodings to UTF-8 in chunks (an ASCII run is copied 8 bytes at a time), with surrogates checked, so
memory input decodes once into a buffer the reader owns and a stream decodes buffer by buffer. An
encoding the library does not know goes to `XmlReadConfig.EncodingConverter`, which gets the whole
input (`XmlEncoding.Custom`; its output is validated like any input) or else is
`UnsupportedEncoding`. `EncodingFallback = .Windows1252` reads undeclared input that is not valid
UTF-8 as Windows-1252 (opt-in; a declaration always decides). Conflicts follow the author's decision
(`plan.md` §9 item 6): a UTF-8 BOM wins over another ASCII-compatible declaration (the one suite
deviation, `hst-lhs-007`), reported by `XmlReader.EncodingWarning`/`XmlDocument.EncodingWarning`;
a 16/32-bit document declaring an 8-bit encoding, or the reverse, is an error. Error positions are in
UTF-8 terms with line and column, and decoding errors name the byte and the encoding.

`XmlChar.FindInvalid` then checks the whole UTF-8 text once: ill-formed sequences, and code points
outside `Char` (C0 controls other than tab/LF/CR, U+FFFE, U+FFFF; surrogates and overlongs as UTF-8
errors). Words of plain ASCII are skipped 8 bytes at a time. After that no scanner tests for illegal
characters: character references are checked where they are decoded.

### The window and the cursor

KdlBeef's design: `XmlReaderCore<TCursor>` reads `mData[offset]` for `mBase <= offset < mEnd`
through `Avail`/`AvailN`/`At`/`StartsWith`, which call `Grow` (and so `IXmlCursor.Fill`) at the
window's end. `XmlByteCursor`'s `Fill` is an inlined `false`, so for memory input the helpers fold to
compares; `XmlReader` holds one core per cursor type and dispatches on a flag.

`XmlBufferedStreamCursor` reads a `Stream` through a buffer of `StreamBufferBytes` (default 64 KB;
`XmlTester -stream N` and the scripts use 16 bytes to exercise every boundary). `Fill` drops the
bytes before `keep` (`mRetain`: the start of the current construct; the whole internal subset while
it is read, since the DOCTYPE exposes it as one view), reads and decodes more, and grows the buffer
only when one construct does not fit, up to `MaxTokenBytes` (a located `ResourceLimitExceeded`).
It never splits a CRLF or a UTF-8 sequence at the window's end. New bytes are validated as they
arrive, so an invalid character is reported where it is, after the events before it. When the
window moves, the core rebases every view it holds (`RebaseViews`: the name, value, declaration
fields, attribute views). Entity frames read stored replacement text, so `Grow` is off inside them
and the outer window is kept by `mRetain`. Line and column are counted forward only
(`LocatesOnlyForward`), so positions an error may need later (an open element's start) are located
before the bytes go. A start tag only marks its element unlocated; before `Grow` lets the buffer
move, the open elements read since the last time are located, in document order
(`ResolvePositions`), so an element that ends within the buffer, almost every one, is never located.
The line counter (`XmlLineCounter`) counts newlines only, every byte once (the bytes `Fill` drops, up
to the located elements, errors): two words at a time while neither has a byte below 0x0E (validated
text has none there but tab, LF and CR), else every LF and lone CR of a word at once. A column is
counted only when asked, from a base on the current line (its start, the drop point, or the last
column asked for) that moves up with it. An offset on the LF of a CRLF is on the line the CRLF ends,
after its CR, in every counter (the word and byte paths, `XmlChar.LineAndColumn`, the document's line
index), whatever input follows. Review P02 and SP1: streaming cost 2–5× the in-memory event
pass in instructions, now 1.1–1.3× (`bench/instructions.sh`'s `stream` and `stream4k` columns). A stream whose whole input fits in the first read is checked as memory input is,
so both paths give identical first errors: the scripts' stream modes compare every not-wf case's
message with the golden one.

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
`MaxEntityAmplification` times the document read so far, up to the end of the outermost reference
(`plan.md` §9 item 9): the same from memory and from a stream whatever its buffer, and input after
the reference cannot dilute it. The window's coordinates (`mData`, `mBase`, `mPos`, `mEnd`, `mRetain`)
are one `InputWindow` to a frame: `SaveWindow` and `RestoreWindow` are the one place that lists them,
used by `PushFrame`, `PopFrame` and collect-errors' unwinding (review A01; R05 was a frame that did
not restore `mRetain`). Offsets in a window are into its own text, so the retention offset is saved
and restored with the rest and an entity's window starts with none. ATTLIST defaults built from
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
measured choice). Messages name what was found and the rule broken (a character as `` `×` (U+00D7)
``), and every limit is a located `ResourceLimitExceeded` naming the setting; the suite's rejection
messages are golden files (`tests/errors/`, `test-suites.md`).

### Collect-errors

With `XmlReadConfig.CollectErrors` an error does not stop the read: `NextEvent` returns it and calls
`Recover` (`XmlReaderCore.Recovery.bf`, out of line in `AfterError`), which puts the reader where the
next call can go on; recovery never fails and never makes an error itself (the pending one's message
is in the per-thread buffer). It leaves every entity (reading goes on after the outermost reference;
elements opened in one are then closed by the document's tags), then resynchronizes by where the error
is, anchored at the error's offset (the reader's position may have moved on inside the broken
construct by an amount that depends on a stream's buffer, so it is not used):

- a start tag (`mTagStart`, tracked only in this mode, when it began in the document): past its `>`,
  quoted values stepped over; unless it was `<a/>` its name becomes a phantom, whose end tag at that
  depth is later consumed with no event and no error, so one broken tag is one error;
- a mismatched end tag: if an open element has its name, the elements down to it are closed, one
  EndElement per call (through the pending-end check, so the normal path pays nothing); otherwise it
  is dropped;
- a comment, a processing instruction or the XML declaration, a CDATA section (and `]]>` in text):
  past `-->`, `?>`, `]]>`; a broken reference in text: past its `;`;
- the internal subset: the next `<` or `]` (the subset stays in a stream's window, for the DocType
  event); a broken or misplaced DOCTYPE: skipped whole; a second root element: skipped whole;
- the end of the input: unclosed elements are reported once and closed one EndElement per call;
  outside the root the read ends.

An error at the same offset as the last one moves on a byte, so recovery always progresses. Encoding,
I/O and resource-limit errors, an error before the input was set up, and `MaxErrors` (100) still stop
the read. Text in the same run before an error in it is lost with it. `XmlDocument` keeps what it read,
copies each error's message into its store (`Errors`) and returns the first. The suite runs in two
more modes with it (`collect`, `stream-collect`: the first error must be the golden one), and
`test-collect.sh` reads random mutations of every suite input and corpus SVG from memory and through a
16-byte stream: both must finish and agree on the errors and the document, except where the encoding
check rejects the input (validated whole from memory, buffer by buffer from a stream). The normal path
pays about 1% in instructions (a check per start tag, code size).

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

- **Word-at-a-time scans**: text runs stop at `<`, `&`, `]` or CR, attribute values at their quote,
  `<`, `&` or a byte below 0x20, comments, PIs and CDATA sections at `-`, `?` or `]` and CR, 8 bytes at
  a time (`XmlChar.BytesEqual`, `BytesBelowSpace`; `ScanText`, `ScanValue`, `ScanUntil`); the word
  holding a stop, and the window's last bytes, are walked byte by byte (Beef has no trailing-zero-count
  intrinsic). After a stream's refill the words go on from where the scan was, and a start tag's
  inline value scan hands its position on to `ReadAttributeValue` (review P02).
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
`Descendants` and their enumerators) check it the same way (`CheckView`). A removed node keeps its
slot with the `Removed` flag until the document is cleared or compacted, so its handles become
invalid rather than naming another node.

`Build` turns the reader's events into records; it is generic over the metadata mode (a const
generic), so a read without metadata has no positions or style work in its loop, and it reads the
event's fields from the reader's core directly (the attribute records by pointer) rather than through
the dispatching properties.

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

### Positions

With `XmlMetadataMode.Positions` the builder records an `XmlRangeRecord` (offset, length, line,
column) per node ID and per attribute index, in side tables that stay empty otherwise, so the default
read pays nothing for them. Elements span from `<` to the end of their end tag (the length is set at
EndElement); attributes span the name through the closing quote (`XmlReader.GetAttributeRange`);
other nodes span their markup. A node read from an entity's replacement text gets the range of the
outermost reference. Offsets are in the UTF-8 text read (the transcoded text for other encodings),
lines and columns in code points. `XmlNode.TryGetSourceRange` and `XmlAttribute.TryGetSourceRange`
give an `XmlSourceRange` with the source name. From memory the document keeps the source and records
offsets only, computing line and column when asked (§6); streams locate forward as the builder goes,
so the ranges match memory input's exactly.

### Mutation

KdlBeef's handle API (`XmlNode.Mutation.bf`, the table operations in `XmlDocument.Mutation.bf`):
`AddElement`/`AddText`/`AddCData`/`AddComment`/`AddProcessingInstruction` append a child,
`InsertElementBefore`/`After` place one, `MoveInto`/`MoveBefore`/`MoveAfter` relink a subtree
(returning false for impossible moves: into itself, text outside the root, a second root), `Remove`
marks a subtree removed, `Rename`, `SetValue`, `SetText` (replaces the children), `SetAttribute`
(a DTD default becomes specified) and `RemoveAttribute`. Names and namespaces stay consistent:
an element's namespace is resolved from the `xmlns` attributes in scope when it is added, renamed or
moved, and setting or removing a declaration resolves the subtree under it again. What could not be
written as well-formed XML (an invalid name or character, `--` in a comment, `?>` in PI data, a
target `xml`) is a fatal error, as an invalid handle is; `XmlDocument.IsValidName` and `IsValidText`
check first. Prefixes need only be declared by the time the document is written: mutations may pass
through namespace-invalid states, `XmlDocument.CheckNamespaces()` applies the reader's rules (bound
prefixes, unique expanded attribute names, the `xml`/`xmlns` reservations, no undeclaring), and
`WriteBytes`/`WriteFile` run it whenever a mutation may have changed names (`mNamespacesChanged`).

Values the DTD supplied are not lost to edits: renaming an element turns its ATTLIST-defaulted
attributes into specified ones (the old name's declarations no longer apply), and removing the
DOCTYPE does so for every element and, in a PreserveStyle document, marks for regeneration the text
its entities produced and the attribute values whose source text is not their value (references,
type normalization). An `XmlAttribute` view names its attribute by element, name and generation: it
follows the record when the table moves and is invalid once the attribute, its element or the
document's content is gone.

The DOCTYPE's children are the internal subset's processing instructions, whose places in the
subset's text are recorded while reading (`mSubsetItems`). Both writers rebuild the subset around
them (`AppendInternalSubset`): one unchanged is kept as written, one changed (`Edited`) regenerated in
its place, one removed or moved away dropped with its line, and comments and processing instructions
added to the DOCTYPE appended before `]` (an internal subset is added to a DOCTYPE without one). A
PreserveStyle DOCTYPE keeps its own text around the subset. A processing instruction a parameter
entity wrote (`FromEntity`) cannot be changed, since the reference would write it again:
`XmlNode.IsEditable` tells, and changing one is a fatal error. An element's
attributes grow in place when they are the last in the table, else move to its end (the old range is
a hole until Clear or Compact); the side tables (positions, style) move with them.

### Edit dependencies

PreserveStyle's marks are structural: a node, its ancestors, its neighbors. What a node means can also
depend on things outside its subtree, and each such dependency has one owner that invalidates it
(review A02). The policy is conservative regeneration (rare edits such as removing the DOCTYPE redo
more than they strictly must) rather than a dependency graph.

| The document's meaning depends on | Changed by | What happens |
|---|---|---|
| ATTLIST defaults and types for an element name | `Rename` of the element | `MaterializeDefaults`: its defaulted attributes become specified; with PreserveStyle, values whose source is not their value (type normalization, references) are regenerated |
| The whole internal subset (defaults, types, entities) | Removing the DOCTYPE | `DocTypeRemoved`: every element's defaults become specified; with PreserveStyle, text and elements an entity produced, attribute values whose source differs from their value, and references to empty entities (no node: only source between nodes) are regenerated or dropped |
| Namespace declarations in scope | Moving a node, setting or removing an `xmlns` attribute, renaming | `ResolveNamespaces` under the changed element; `mNamespacesChanged`, checked by `CheckNamespaces` before `WriteBytes`/`WriteFile` |
| Source shared with siblings (an entity reference) | Changing, removing, moving or inserting next to one of them | `GroupDirty`: the group is regenerated, expanding the reference |
| The enclosing text (CDATA's `]]>`, text's `]]`) | Adjacent nodes | Decided while writing: escaping looks at the output written before (R03), CDATA is split (R10) |

Limits kept (status.md RV-L): removing a specified attribute that has a DTD default lets the default
come back on reading (XML has no way to say "absent" while the declaration stands); references to
unread entities stay as written after the DOCTYPE is removed (there is no value to write); a CR in a
comment or PI reads back as LF (no escape exists). Both writers share the escaping (`AppendTextEscaped`,
`AppendAttributeEscaped`, the CDATA and subset writers) and the checks made when values are set, so
what they generate is well-formed in the same way; `CheckNamespaces` works on the document's state, not
by reparsing output.

### PreserveStyle

`XmlMetadataMode.PreserveStyle` keeps the source and where every node and attribute is in it, so
`Write` gives back the document as it was read and regenerates only what changed. `test-roundtrip.sh`
checks every accepted suite input and corpus SVG byte for byte (`WriteFile`, in the document's own
encoding), from memory and through a 16-byte stream, and random edits of each (`XmlTester -mutate`)
for reading back into the edited document.

- **Source.** The document keeps the UTF-8 text the reader's offsets index: its copy of the input,
  or the transcoding of a document in another encoding. A stream is read whole first (the source is
  kept anyway), then read as memory input. Whether the input had a byte order mark is recorded.
- **Capture** (`XmlDocument.Style.bf`, by node ID and attribute index, in tables that stay empty in
  other modes). Each node gets its range, the offset where the text before it starts (the end of the
  previous construct at its level: whitespace in the prolog and epilog; in content all text is a
  node), and flags. An element also gets the end of its name, of its last attribute, of its start
  tag, and where its end tag starts; an attribute its range and its value's (between the quotes).
  The XML declaration and the text after the last node are document landmarks.
- **Entities.** A node read from an entity's replacement text has the range of the outermost
  reference (`InEntity`; `EntityTop` for the reference's own products). Siblings whose ranges
  overlap came from one reference (with the text merged around it) and are `Shared`: they are
  written as the source once, while none of them changed; a change in one, or a sibling removed,
  moved or put between them (`GroupDirty`), regenerates them all, which expands the reference. An
  element from an entity has no tags in the source and is regenerated whole when anything in it
  changes. References in attribute values stay in the raw value.
- **Marks.** The mutation API sets `NameDirty`, `ValueDirty`, `TagDirty` (attributes changed),
  `LeadingDirty` (moved: the text before it belonged to its old place) and, on every ancestor,
  `SubtreeDirty`, stopping at one already marked.
- **Writing** (`WritePreserving`) walks the tree without recursion. An unchanged node is the source
  from its leading text to its end. A changed element keeps what it can: its name and attribute text
  (a removed attribute takes the space before it; a changed value is regenerated in its original
  quotes; a new one is laid out like the last one read, on its own line when they are), its
  `/>` (turned into `>` and an end tag when it gets content) or its end tag. Other changed nodes,
  and everything new, are written canonically; a new node outside the root starts a line.
- **Bytes.** `WriteBytes`/`WriteFile` encode the text in the document's encoding (`XmlEncoder`: UTF-16
  and UTF-32 with surrogate pairs, Latin-1, ASCII, the single-byte tables reversed), the byte order
  mark coming from U+FEFF. Canonical documents are written in UTF-8. A character the encoding lacks
  (a value set in code) follows `XmlWriteOptions.Unencodable`: an error naming it (the default), a
  character reference where XML has one (text, attribute values, and CDATA split around it), a
  replacement string, the whole document in UTF-8 with its declaration saying so, or a handler that
  decides by context. The policy is applied to each piece the writer generates as it is written
  (`FixUnencodable`); what the source kept is in the encoding already, and what a policy cannot fix
  (names, a reference in a comment) is the encoder's error.

### Memory: Compact and Clear(releaseMemory)

Editing keeps history (review P04): `SetValue` and `SetAttribute` copy the new value into the text
arena and leave the old one, an attribute appended to an element whose attributes are not last in the
table moves them all to its end, and removed nodes keep their slots. That suits stable views and bulk
cleanup but lets memory follow the edit history. `MemoryUsage` reports slots and live counts, arena
bytes reserved, filled and live, and an approximate total. `Compact(newIds)` rebuilds the document
from what is live: nodes renumbered in document order (handles become invalid, as after `Clear`;
`newIds` maps old IDs to new), attributes contiguous, the side tables (positions, style, subset items)
remapped (a removed DOCTYPE processing instruction keeps its place in the subset's text, naming the
document node, so the writers still leave it out), and the live text copied into a new arena of exactly its size; the kept source (PreserveStyle
and positions) moves as one block, so offsets and the views into it stay valid. Names stay interned.
`Clear(true)` frees what `Clear()` keeps for the next read (arena chunks, table capacities, the name
table's growth, the DOCTYPE's tables, the errors, the reader's buffers): after an unusually large
document. `MemoryUsage` counts all of them.

`XmlTester -memory records.xml small.svg` (records.xml: 13.8 MB, 912,467 nodes), from the document's
own accounting (resident memory is the allocator's business):

| Step | Nodes (slots / live) | Attributes (slots / live) | Text (filled / live) | Total |
|---|---:|---:|---:|---:|
| Read | 912,467 / 912,467 | 76,518 / 76,518 | 15.2 / 7.7 MB | 85 MB |
| Every text value replaced 10× | same | same | 41.4 / 7.1 MB | 111 MB |
| An attribute added on every element, 5× | same | 5,340,603 / 1,703,683 | 43.0 / 8.8 MB | 370 MB |
| Every other child element of the root removed | 912,467 / 318,049 | 5,340,603 / 604,124 | 43.0 / 2.7 MB | 370 MB |
| `Compact` | 318,049 / 318,049 | 604,124 / 604,124 | 2.7 / 2.7 MB | 41 MB |
| (PreserveStyle: after the same edits, then `Compact`) | | | 43.0 → 15.3 MB | 718 → 91 MB |
| A small document read after records.xml | 3 / 3 | 4 / 4 | 342 bytes of a 15.9 MB arena | 85 MB |
| `Clear(true)` | 1 / 1 | 0 / 0 | 0 | 2 KB |

### Lifetimes

One contract for everything the document hands out (review A04):

| What | Valid until | Checked |
|---|---|---|
| `XmlNode`, `XmlNodeList`, `XmlElementList`, `XmlDescendants`, their enumerators | The document is read again, cleared or compacted (the generation changes), or the node is removed | `IsValid`; a stale list or enumerator is a fatal error (`CheckView`) |
| `XmlAttribute`, `XmlAttributeList` | The same, or the attribute is removed; it follows its record when the table moves | `IsValid`; reading a stale one is a fatal error |
| `XmlNodeId` | The same as the node (a number: it never checks itself; `GetNode` does) | `GetNode` returns an invalid handle |
| Strings the document returns (names, values, `Text`, the DOCTYPE's, `Errors`' messages) | The document is read again, cleared or compacted. A value replaced by `SetValue`/`SetAttribute` stays readable until then | No |
| Reader event strings (`Name`, `Value`, attribute values) | The next `Next` call | No |
| `XmlParseError.mMessage`/`mSource` | The next error made on the same thread | No: copy them, or keep an `XmlDiagnostic` |
| `XmlDiagnostic` | Deleted by its owner | Owns its text |

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

## 6. Typed mapping (`[XmlObject]`)

KdlBeef's `[KdlObject]` design (`plan.md` §4.12) with XML's roles.

- **Two stages (FormatCore's mapping driver).** `[XmlObject]`'s `ApplyToType` (`XmlSerializerCodeGen
  .Emit`) emits only signatures, `XmlElementName`, `XmlElementNamespace` and FormatCore's
  `MappingDriver` entry, a `[Comptime] XmlGen_(part)` method in the user's type. Every body (`XmlRead`,
  `XmlWrite`, the claimed element and attribute names, `XmlTakesAll*`/`XmlMapsText`,
  `XmlGeneratedSource`) is `System.Compiler.Mixin(XmlGen_(part))`, planned and written by
  `XmlSerializerCodeGen.Body` when it is compiled. There the comptime evaluation's current project is
  the user's, so the converter registry and `[XmlChildren]`/TypedEntries subtype lookups
  (`Registry.IsVisible`) see the user's project and its dependencies however many projects use XmlBeef
  (in `ApplyToType` they saw the user's declarations only while it was XmlBeef's one dependent:
  `tests/codegen`'s `OkRegisteredConverter` with the second project `Other`); every type is complete,
  so a type can hold itself; and the dispatch switches are written inline in the body (a nested mixin
  of an XmlBeef method would be an evaluation in XmlBeef's project again). Naming (`XmlNaming` is
  FormatCore's `NamingPolicy`), literals, integer bounds (uint64's minimum is 0) and type shapes are
  FormatCore's; roles, claims and emission are XML's.
- **Generation.** `XmlSerializerCodeGen.Body` classifies each public instance field and writes
  `XmlRead(XmlNode, allocator)` and `XmlWrite(XmlNode)`; the type gets `IXmlSerializable`.
  Emitted code is fully qualified, reaches fields through `this.` and uses `_`-prefixed locals; enums
  are generated switches over their case names. `ScanChain` collects the chain's claimed names and
  stops the build on conflicts, `PlanField` makes each field's plan (kinds, role, names; every check),
  then the code is written from the plans, so nothing is emitted for a type whose mapping fails. A
  base's methods are hidden (`new`) and called first. Planning and its checks are
  `XmlSerializerPlan.bf`, emission `XmlSerializerCodeGen.bf` (review A03); the plan (`FieldPlan`) and
  the claims in Clark notation are what the two share. `[XmlObject(ShowGenerated = true)]` also emits
  the generated code as `static StringView XmlGeneratedSource`, to print when debugging a mapping
  from the command line (the IDE shows emitted code itself). The checks that stop the build are
  tested by `test-codegen.sh`, which builds each fixture of `tests/codegen/` alone (a `[Test]` cannot
  see a build fail); what the emitted code does is tested by `XmlObjectTests`.
- **Roles.** Scalars (bool, integers, floats, String, enums, converter types) are attributes;
  `[XmlElement]` makes one a child element's text, `[XmlText]` the element's own text (its Text and
  CDATA children; other children stay when it is written). `[XmlAttribute] List<scalar>` is one
  attribute of space-separated tokens (`class`, `points`). `List<scalar>` is repeated child elements
  named after the field; `[XmlObject]` fields are child elements named after the field;
  `List<[XmlObject]>` repeated children named after the item type; `[XmlArray]` puts a list in a
  wrapper (`Item` names a scalar list's items, `item` by default), which is the type's child element in
  the field's namespace while the items keep their own type's. `[XmlChildren] List<T>` takes every
  child element no other field claims, dispatched by local name to the concrete `[XmlObject]` types
  assignable to T (found through `Type.TypeDeclarations` when the method is compiled, so they may
  derive from the type being generated) and written through the interface so each item's own type
  decides.
- **Dictionaries** (`Dictionary<K, V>`, K a String, integer or enum, V a scalar or `[XmlObject]`)
  take one of five shapes, `[XmlMap(Style = …)]`, since XML has no single one and formats differ:
  `TypedEntries`, the default (`<int32 name="retries">3</int32>`: the entry named after the value's
  type, explicit about types; a dictionary of a base class reads each entry as the subtype its name
  says), `Entries` (`<entry key="k">v</entry>`, or with `Value` `<add key="k" value="v"/>`),
  `KeyValueElements` (`<entry><key>k</key><value>v</value></entry>`, any key), `KeysAsNames`
  (`<k>v</k>`, keys that are names) and `Attributes` (`<limits a="1"/>`). `Key`, `Entry` and `Value`
  rename the parts. They sit in a wrapper element named after the field, or with `Wrapped = false` in
  the element itself, where `KeysAsNames` and `Attributes` become catch-alls for the child elements or
  attributes no other field maps. An object value is the entry element itself (TypedEntries, Entries)
  and carries the key attribute, which a strict value type then allows (`XmlBind.EnterEntry`); a
  value type that maps an attribute with the key's name stops the build. Reading (`XmlMapEntries`)
  checks a TypedEntries entry's type and lets the last of repeated keys win; writing
  (`XmlMapWriter`) indexes the entries by key once, updates each in place, appends new keys with
  their neighbors' indentation, removes the rest, and reports a key that cannot be written as a name.
- **Names and namespaces.** Names are as declared by default (`plan.md` §9 item 10), with
  `CamelCase`, `KebabCase`, `SnakeCase` and `Lower` policies per type, `[XmlName]` per field and
  `[XmlAlias]` for older names (read; renamed when written). A type's `Namespace` applies to its
  element and its fields' child elements; attributes are in no namespace unless `[XmlName(…,
  Namespace = …)]` gives one. Reading matches local names; an element name without a namespace
  matches any namespace (SVG elements read without declaring theirs), an attribute name without one
  matches only unprefixed attributes; a document read without namespaces matches whole names.
  Writing a name in a namespace uses a prefix bound in scope, or declares one (`xmlns` on a new
  element, `xmlns:ns0` for an attribute); the reserved namespaces always use `xml` and `xmlns`. The
  names fields claim (for collisions, strict checks, `[XmlChildren]` and catch-all dictionaries) carry
  their namespace (`local` or `{namespace}local`) and match by the same rules as reading. Since an
  element name without a namespace matches that name in every namespace, two element claims collide
  when their local names are equal and either has no namespace or both have the same one; attribute
  claims collide only when equal (`href` and `{xlink}href` are two attributes).
- **Runtime (`XmlBind`).** `Find*` locate a value as an `XmlValueRef` (element, attribute position,
  name, text); the first matching element wins. Names compare as interned IDs on the records, looked
  up once per call through the name table's recent-name cache (`FindCached`). `To*` convert with
  XML Schema's lexical forms (`XmlValueParser`: whitespace around numbers allowed, `INF`, `NaN`,
  `true`/`1`), range-checked; errors are `element: name: message`, located at the attribute or
  element (`XmlSerializer` raises the metadata mode to Positions). Writing goes through
  `XmlValueWriter` and changes nothing when the value is the same, so a PreserveStyle document stays
  byte-identical where the object did not change. Lists write in one pass (`XmlChildCursor`,
  `XmlFreeChildCursor`: existing elements reused by position, new ones inserted after the last with
  a copy of its indentation, leftovers removed with theirs).
- **Strict types** (`Strict = true`) reject, located, an attribute, child element or non-whitespace
  text no field in the chain maps (namespace declarations and `xml:` attributes allowed); the
  claimed names are virtual properties on classes, so a base's check sees its subclasses' fields.
- **Converters** (`IXmlConverter<T>`, `[XmlConverter(typeof(T))]`, `[XmlUseConverter]`) read an
  `XmlValueRef` and write text (or nothing, which removes the value).
- **Ownership** as KdlBeef: a null String, object or List field gets a new instance on read (from the
  allocator when one is given); replaced List items are deleted without an allocator.
- **Positions are lazy for memory input.** A read with positions from memory keeps the source and
  records offsets only; line and column are computed when asked (`TryGetSourceRange`, an error),
  through an index of line starts built on first use. Streams keep no source, so theirs are located
  as they are read. This halved the cost of `XmlSerializer` reads.
- **Benchmark.** `bench/compare/run-typed.sh` reads `osm.xml` into the same OpenStreetMap model with
  XmlBeef, quick-xml + serde, Go's `encoding/xml` Unmarshal and .NET's `XmlSerializer`, each checked
  against a reference computed by Python's ElementTree.
