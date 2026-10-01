# Survey of existing XML implementations

This survey covers what four Beef XML libraries and about twenty XML libraries in other languages do, how they do it, and what XmlBeef should take or avoid. The sources were read from shallow clones made on 2026-09-30 (last-commit dates are in the tables). The clones were scratch copies under `/tmp`, not pinned. The pinned copies for benchmarking live in `bench/compare/`. File references are relative to each clone.

The Beef libraries were also built with BeefBuild 0.43.6 and run against a set of tricky inputs. "Speed" figures are the published numbers from the cited sources unless marked as measured here. The KdlBeef and TomlBeef techniques this survey refers to are described in `~/development/KdlBeef/docs/architecture.md` and `~/development/TomlBeef/docs/architecture.md`.

## At a glance

| | architecture | API | names | attributes | text | DTD / entities | namespaces | encodings | errors / positions | round-trip | typed mapping |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **pugixml** (C++) | in-situ destructive parse into a NUL-sentinel buffer, 256-entry class tables, 4× unrolled scans | DOM | `char*` into the buffer (not interned) | linked list per node | in-situ, decoded in place (gap compaction) | DOCTYPE skipped, only the 5 predefined entities + char refs; unknown refs left verbatim | none (prefix is part of the name) | UTF-8/16/32, Latin-1, converted to UTF-8 up front | status enum + byte offset | no | no |
| **libxml2** (C) | push parser (UTF-8 internally, 250-byte growth) + SAX2 tree builder; xmlReader pulls over the push parser | SAX, DOM, pull | per-parser `xmlDict` interning, shared with the doc | `xmlAttr` nodes with text children | owned copies | full DTD, internal entities kept as refs unless `NOENT`; amplification limit | full | built-in UTF-8/16, Latin-1, ASCII; iconv/ICU | line/col, 100 errors max, recovery mode | partial (entity-ref nodes) | no |
| **expat** (C) | table-driven tokenizer compiled 3× (8-bit, UTF-16LE, UTF-16BE), incremental `XML_Parse` | SAX (push) | interned attribute ids | array per start tag | copied into the callback buffer | internal subset expanded; external only via a handler; billion-laughs limits | `uri<sep>local` via `ParserCreateNS` | UTF-8/16, Latin-1, ASCII + unknown-encoding hook | code + line/col | no | no |
| **System.Xml** (C#) | `XmlTextReaderImpl`: UTF-16 char buffer with a sentinel, in-place EOL/char-ref compaction; DOM and XLinq on top | pull, DOM, XLinq | `NameTable` atomization | lazy `NodeData` slices; XLinq: circular list | slices, materialized lazily | `DtdProcessing` Prohibit/Ignore/Parse, `MaxCharactersFromEntities` 1e7 | full, atomized | all .NET encodings | line/col, exception | no | `XmlSerializer` (IL codegen) |
| **TurboXml** (C#) | ref-struct callback parser, generic over handler and char source, SIMD stop-set scans | SAX | spans | spans | spans | DOCTYPE rejected or skipped | none | Decoder; ignores the declared encoding | line/col callback | no | no |
| **XmlParser** (C#, Osenkov) | Roslyn red/green tree with trivia | CST | tokens | tokens | tokens (raw + value) | none | syntactic only | string | diagnostics on nodes, recovery | **byte-exact** | no |
| **quick-xml** (Rust) | pull reader over a slice or `BufRead`; memchr scans; lazy attribute iterator | pull + serde | `&str` views | lazy parse of the tag slice | raw escaped `Cow`, unescape on demand | DOCTYPE opaque; predefined only + resolver | `NsReader` (binding stack) | UTF-8; others via a decoding wrapper | byte offset only | events verbatim |
| **roxmltree** (Rust) | one-pass read-only DOM, nodes in preorder in a `Vec` | DOM | views + namespace index | flat `Vec`, ranges | borrowed unless `&`/`\r`, else owned | internal entities (re-tokenized), loop detector; DTD off by default | resolved, deduplicated table | UTF-8 `&str` only | `TextPos` computed lazily | no | no |
| **xmlparser** (Rust) | zero-allocation tokenizer, `StrSpan` on every token | tokens | spans | one token each | spans | ENTITY decls only | syntactic | UTF-8 | construct + cause + pos | spans | no |
| **xml-rs** (Rust) | per-byte `Read`, per-char lexer, `String` per event | pull | owned | owned `Vec` | owned | internal entities, re-lexed via `VecDeque<char>` | resolved (map cloned per element) | UTF-8/16, Latin-1 | row/col (eager) | no | via serde-xml-rs |
| **Go encoding/xml** | `ReadByte` per byte, `Token()` / `RawToken()` | pull + reflection | `string` per name | `[]Attr` per start tag | copied | `Directive` opaque; `Entity` map | translated (prefix lost) | UTF-8 + `CharsetReader` | line/col | no | struct tags |
| **zig-xml** (ianprime0509) | pull reader over a sliding window; scan, then a separate check pass | pull | spans + arena | indexed, hash for duplicates | raw spans; refs are separate nodes | DOCTYPE **rejected** | full | UTF-8, UTF-16 | 35 error codes + location | via raw accessors | no |
| **ElementTree** (Python) | expat callbacks → TreeBuilder | tree, iterparse, `XMLPullParser` | Clark `{uri}local` | dict | `text`/`tail` | via expat | resolved (prefix lost) | via expat | line/col | no | no |
| **fast-xml-parser** (JS) | string loop + regex attributes | object | strings | object keys `@_x` | concatenated | entity limits | none | string | validator is a separate pass | no | object conventions |

## The existing Beef libraries

| | last commit | size | design | builds with 0.43.6? | verdict |
|---|---|---|---|---|---|
| **HorseTrain/Beef-Lang-XML** | 2021-02-19 (4 commits) | 513 lines, one file | whitespace/quote tokenizer → element tree | yes (1 warning) | a toy; not XML |
| **LauraRozier/Xml-Beef** | 2021-05-27 (9 commits) | 1,467 lines, one file | port of Delphi's VerySimpleXml: stream reader + class-per-node DOM + writer | yes | hangs on any tag longer than 4 KB; writer crashes; not usable |
| **Rune-Magic/BeefXml** | 2025-10-21 (16 commits) | 5,639 lines (XML + JSON + regex + "schema") | char-by-char `MarkupSource` → event reader (`XmlVisitable`) → visitor pipeline → `XmlElement` builder; comptime serializer | Debug only. Release fails (`Debug.Assert(source.PeekNext(var c, ...))` in `Json/JsonReader.bf:98`); its own tests fail to compile (the serializer's comptime emit) | the pull reader works on simple input; everything above it is broken |
| **disarray2077/BeefFNT** | 2021-11-23 (2 commits) | 2,794 lines | an AngelCode .fnt reader; its XML is Xml-Beef plus extension helpers (`src/Extensions/Xml*.bf`) | no: 6 errors, all `(int)bool` casts that current Beef rejects (`TextFormatUtility.bf:40`, `BitmapFontInfo.bf:99-106`) | not an XML library; nothing to reuse |

### Results on the tricky inputs (Debug builds)

"—" means the input was accepted when it should have been rejected, or the output was wrong without any error.

| input | expected | Beef-Lang-XML | Xml-Beef | BeefXml (reader) |
|---|---|---|---|---|
| `<a b="&lt;&#x41;"/>` | `b` = `<A` | `&lt;&#x41;` (no decoding) | `<&#x41;` (char refs not decoded) | `<A` (correct) |
| `<a><![CDATA[]]></a>` | empty CDATA | an element named `<![CDATA[]]>` | CDATA node (correct) | error: `char '!' is not valid`. CDATA only works after text has started |
| `<!DOCTYPE a [<!ENTITY e "x">]><a>&e;</a>` | text `x` | DOCTYPE becomes elements | `&e;` kept literally; DOCTYPE text is `]` | `x` (correct). Entity text is inserted verbatim, not re-parsed |
| UTF-16LE with BOM | `é` | (correct) (Beef's `File.ReadAllText` detects the BOM) | garbage with NULs: it picks UTF-8 from the default header | (correct) (StreamReader detects the BOM) |
| `<a>]]></a>` | error | — | — | — |
| `<a></b>` | error | — | — | error (correct) (in the pipeline) |
| `<a b="1" b="2"/>` | error | — (keeps the last) | — (keeps both) | reader: —; builder: `Dictionary.Add` assertion |
| `<p:a xmlns:q="u"/>` | NS error | — | — | — (no namespaces anywhere) |
| `<a/><b/>` | error | — | — | — |
| `<a b="x\r\ny\tz">1\r\n2\r3</a>` | `b` = `x y z`, text `1\n2\n3` | text split into words `1`, `2`, `3`; CR kept in `b` | CR kept in both | `b` = `x\ny\tz`; text keeps a lone `\r` |
| `<a>&undefined;</a>` | error | — | — | error (correct) |
| `<?pi data?>`, mixed text | kept | PI and comment become elements; `'`-quoted values unsupported | text containing no whitespace **is dropped** (`t&amp;u`, `tail` lost) | error `char '?' is not valid`: PIs are unsupported |
| 595 KB Inkscape SVG (2,570 elements) | 2,570 | 2,573 (the declaration and comments counted as elements); 10 ms Release | **never finishes**: >2 min, 3 GB RSS | 2,570 (correct); 52 ms Debug; its builder aborts |

### Beef-Lang-XML (HorseTrain)
- `XMLToken.ParseTokens` splits the input on `<`, `>`, `/`, `=`, quotes and whitespace into a `List<XMLToken>`, allocating a `String` per token. `XMLFile.ParseFromTokens` then walks the tokens with a fixed `XMLElement[10000]` stack.
- Text is stored as whitespace-separated words (`Data`), with no entities, EOL handling or CDATA. A `"` inside text starts a "string". End-tag names are never compared.
- Leftover debugging: `Console.WriteLine(Index)` prints on every parse.
- Memory: token strings go on a global `StringAllocationGarbage` list that is freed only by `StringMethods.XMLEnd()`. `XMLElement.ToString` **deletes each child after writing it**, so writing a document destroys it.
- Nothing is reusable.

### Xml-Beef (LauraRozier, a port of VerySimpleXml)
- `XmlStreamReader : StreamReader` copies the decoded buffer into a `String` and removes from its front with `buffStr.Remove(0, n)` at every step. It reaches into `StreamReader` privates with `[Friend]`.
- `ReadText(stopChars)` cannot make progress when a construct is longer than the 4,096-char buffer. It loops forever and memory grows: `<a d="xxxx…"/>` with 4,100 characters hangs. Every SVG with long path data hits this.
- The tag body is read up to the first `>`, even inside a quoted value. The name is split at the first space only, so `<svg\n id=…>` gives the name `svg\n`. Attributes are "flags" when they have no value (HTML-ish), and name lookups are case-insensitive.
- Entities are handled by `String.Replace` of the five predefined names; char refs are not decoded. A DOCTYPE internal subset is mangled.
- The encoding is chosen from the previous header, so BOM detection is off after the first load.
- Writer: `SaveToStream` dereferences a null `_header` when the input has no declaration (segfault on 12 of the 14 inputs). `Walk` writes `<` before every node type, so text becomes `<text` and CDATA `<<![CDATA[`.
- The node model is class-per-node, `String` per name and text, a `List` of attributes, and a single `Text` per element plus separate text nodes.
- Verdict: unusable, and nothing is reusable. BeefFNT inherits all of it.

### BeefXml (Rune-Magic)
- `MarkupSource` reads the stream **one char at a time** through `StreamReader.Read()` into a 128-char buffer. It keeps a line/column index and, in Debug, a copy of the current line for error display.
- `Consume` skips whitespace before every token, so `<  a  >` and `< ! -- -->` are accepted (asserted by its `TestXmlSource`).
- `XmlReader.ParseNext` returns an enum event: `OpeningTag`, `Attribute`, `OpeningEnd(bodyless)`, `ClosingTag`, `CharacterData`, `EOF`, `Err`. That is a reasonable pull shape, xmlparser's in fact.
- Every name and text is a `String` from a per-reader `BumpAllocator`, so memory grows with the document.
- Conformance:
  - Comments inside text are dropped. PIs are unsupported.
  - Whitespace is trimmed by default (`.Trim` flags). CDATA is merged into text.
  - DOCTYPE support includes **opening external SYSTEM/PUBLIC entities and DTDs from disk by default** (`MarkupUri.Open`, `SourceProvider.OpenSource`), which is an XXE hole, with no expansion limits.
  - Char classes are generated at compile time from EBNF strings (`Util.ParseAndEmitEBNFEnumaration`, a `[Comptime]` mixin). This is a neat trick, but it produces a linear chain of range comparisons per character.
- Errors are printed to `Console.Error` and followed by `Debug.Break()`, which raises SIGTRAP and kills the process outside a debugger. The error in `Result` carries no information.
- The visitor pipeline pops its tag stack after the builder's `Terminate` has cleared it (`XmlVisitor.bf:239`), so `XmlElement.Builder` aborts with a `List.PopBack` assertion on every document. `XmlElement` keeps only `PrecedingText` and `FooterText` (mixed content is lossy) and a `Dictionary` of attributes (unordered; duplicates assert).
- The comptime serializer (`[XmlAttributeSerialize]`, `[NoSerialize]`, `[ForceSerialize]`) does not compile with 0.43.6.
- Verdict: not reusable. The ideas worth keeping are the enum-event pull reader and comptime generation of character classes. XmlBeef should generate lookup tables at compile time, not comparison chains.

### Minimal element-count code, for the benchmark

These are the snippets used here. The HorseTrain file needs a `BeefProj.toml` with the source in `src/`. Xml-Beef hangs on any construct over 4 KB, so benchmark it only on inputs without long tags. BeefXml builds only in Debug unless `src/Json` is excluded.

```bf
// Xml-Beef
let xml = scope Xml_Beef.Xml();
xml.LoadFromFile(path);
static int Count(XmlNode n) { int c = n.NodeType == .Element ? 1 : 0; for (let ch in n.ChildNodes) c += Count(ch); return c; }
int count = 0; for (let n in xml.ChildNodes) count += Count(n);

// Beef-Lang-XML (namespace XML): Children is private
let text = File.ReadAllText(path, .. scope .());
let tokens = XMLToken.ParseTokens(text);
let file = scope XMLFile(); file.ParseFromTokens(tokens);
static int Count(XMLElement e) { int c = 1; for (let ch in e.[Friend]Children) c += Count(ch); return c; }
int count = 0; for (let e in file.RootElements) count += Count(e);
delete tokens; file.ClearMemory(); StringMethods.XMLEnd();

// BeefXml (namespace Xml): pull reader only, since the document builder aborts
StreamReader sr = scope .(); sr.Open(path);
MarkupSource src = scope .(sr, path);
XmlReader reader = scope .(src);
reader.ParseHeader();
int count = 0; bool first = true;
loop: while (true) { switch (reader.ParseNext(first)) { case .OpeningTag: count++; case .EOF, .Err: break loop; default: } first = false; }
```

## Notes per implementation

### C and C++

**pugixml** (`src/pugixml.cpp`, 2026-06-16) is the speed reference. The design is in Kapoulkine's "Parsing XML at the speed of light" (<https://aosabook.org/en/posa/parsing-xml-at-the-speed-of-light.html>).
- The whole input is converted to UTF-8 first (`convert_buffer_*`, :2186-2356). The parser then writes into that buffer, overwriting the last byte with a NUL sentinel (`endch`, :3608) so that no scan loop checks bounds.
- `chartype_table[256]` (:1911) holds 8 flag bits per byte: pcdata stop `\0 & \r <`, attribute stop, attribute whitespace, space, CDATA stop, comment stop, symbol, start symbol. Every byte ≥ 0x80 counts as a name character.
- `PUGI_IMPL_SCANWHILE_UNROLL` scans 4 bytes per iteration.
- Text conversion is chosen by template: `strconv_pcdata_impl<trim, eol, escape>` and `strconv_attribute_impl` (:2742-2983). This gives 8 + 16 variants picked once from the option mask, with no per-character option branches.
- Decoding happens **in place**: every entity or CRLF shrinks the text, and a `gap` (:2489) memmoves only the span since the previous gap.
- The tree loop is iterative (`parse_tree`, :3327).
- Memory:
  - 32 KiB pages with a bump pointer; blocks over page/4 get their own page.
  - The node header stores the page offset plus flags, including "name/value allocated" (heap) vs in-situ (:476-500), so mutation knows which strings it may free.
  - A node is 64 bytes; `prev_sibling_c` is cyclic, so `first_child->prev_sibling_c` is the last child and appends are O(1). Compact mode stores nodes in 12 bytes.
- Parse flags: `pi`, `comments`, `cdata`, `ws_pcdata`, `escapes`, `eol`, `wconv_attribute`, `wnorm_attribute`, `declaration`, `doctype`, `trim_pcdata`, `fragment`, `embed_pcdata`, `merge_pcdata`. The default is `cdata | escapes | wconv_attribute | eol`, which **drops comments, PIs, DOCTYPE and whitespace-only text**.
- It checks the end-tag name and that a root exists. It does not check duplicate attributes, Char ranges, non-ASCII Name rules, UTF-8 validity, `--` in comments, `]]>`, or declaration placement. Unknown entities are left as written. There are no namespaces and no DTD. Errors are a status and a byte offset.
- **RapidXML** is similar: in situ, with flags as a template parameter and a 64 KiB `memory_pool`. It parses recursively, checks closing tags only on request, and has been unmaintained since about 2009.

**xerces-c** (2024-10-21, nearly dormant). The map of what "full XML" means:
- XML 1.0 (3rd ed.) and 1.1, Namespaces 1.0 and 1.1
- DOM Level 1, Level 2 Core + Traversal/Range, Level 3 Core + Load & Save
- SAX 1 and 2
- XML Schema 1.0 (structures, datatypes, PSVI) and DTD validation
- XInclude 1.0
- grammar caching and pooling, catalogs, pluggable transcoders (ICU, iconv, Win32) and net accessors

Internally it is UTF-16 (a 48 KiB raw buffer feeding 16 Ki `XMLCh` with per-char offset arrays), so UTF-8 input pays a transcode. `SecurityManager` limits entity expansions to 50,000 only when one is installed. None of this beyond XML 1.0 + Namespaces is in scope for XmlBeef. Schema, XInclude and validation are separate products.

**libxml2** (2.15/2.16-dev, 2026-09-23)
- Always parses UTF-8. `xmlParserInputBuffer` converts from the raw encoding with built-in converters (UTF-8, UTF-16LE/BE, ISO-8859-x, ASCII) or iconv/ICU, and grows 250 bytes at a time (`INPUT_CHUNK`).
- Names are interned in a per-parser `xmlDict` (open addressing, random seed), which becomes `doc->dict`, so tree names are dictionary pointers.
- `xmlNode` is about 120 bytes (it has a `last` pointer for O(1) append). Attributes are `xmlAttr` nodes whose values are text children, which is heavy.
- `xmlreader.c` is a pull API layered over the push parser: it feeds 512-byte chunks and frees the tree behind it. That is the wrong way round for speed.
- Defaults: entities are kept as reference nodes (`NOENT` substitutes them), no external DTD (`DTDLOAD`), `NO_XXE` (2.13), and `NONET`. 2.15 removed the HTTP client.
- Limits (`parserInternals.h:40-87`), all raised by `XML_PARSE_HUGE`: depth 256 (2048), entity nesting 20 (40), text 10 MB (1 GB), name 50,000, lookup 10 MB, 100 errors.
- Entity amplification (reworked in 2.11, `xmlParserEntityCheck`, parser.c:434):
  - Saturating counters of consumed and expanded bytes, plus `XML_ENT_FIXED_COST` = 20 per reference, so empty-entity floods cost something too.
  - The check fails when expanded > 1,000,000 and expanded > 5 × consumed. The factor is settable with `xmlCtxtSetMaxAmplification`.

**expat** (2.8.5, 2026-09-29)
- `xmltok_impl.c` is compiled three times: 8-bit, UTF-16LE and UTF-16BE. **UTF-16 is tokenized natively**, not transcoded.
- Each encoding has a `type[256]` byte-class table (`BT_LT`, `BT_AMP`, `BT_LEAD2..4`, `BT_NMSTRT`, `BT_NONASCII`, …). Scanners return a token and its end, or `XML_TOK_PARTIAL`/`PARTIAL_CHAR` at the end of the buffer. The parser keeps the tail and retries when more data arrives.
- `XML_GetBuffer` + `XML_ParseBuffer` let the caller read directly into the parser's buffer.
- **Reparse deferral** (2.6.0, CVE-2023-52425): a token larger than the chunks was re-tokenized from its start on every call, which is quadratic. Now a retry waits until the available bytes have doubled (`callProcessor`, xmlparse.c:1195). `XML_SetReparseDeferralEnabled(false)` is for byte-at-a-time feeds.
- Duplicate attributes: names are interned ids, and the byte before each name is a "seen" flag that is set, then cleared, per start tag. With namespaces on, a hash of expanded names is cleared by bumping a version number.
- Billion laughs (2.4.0): the default maximum amplification is 100×, enforced after 8 MiB. The allocation tracker (2.7.2) caps heap use at 100× input after 64 MiB. Entity expansion has been iterative since 2.7.0.
- The internal subset is expanded. External entities load only through the application's handler.

### C# / .NET

**System.Xml** (`XmlTextReaderImpl.cs`, 9,751 lines)
- Buffering:
  - 4 KiB bytes by default (8 KiB for seekable streams over 64 KiB).
  - The char buffer has one extra slot for a `'\0'` **sentinel**, so `while (IsTextChar(c = chars[pos])) pos++` has no bounds check.
  - During the prolog it decodes at most 80 chars at a time, so it can switch encoding after `<?xml encoding=…?>` without having decoded too far (`ReadData`, `SwitchEncoding`). Detection follows XML Appendix F (4-byte sniff, UCS-4, UTF-16, EBCDIC rejected).
  - Consumed text is shifted to the front of the buffer.
- **EOL normalization and inline char refs are applied in place** in the char buffer using a gap (`ShiftBuffer`), as pugixml does. Text and attribute values stay `(chars, start, len)` slices, materialized lazily (`NodeData.StringValue`).
- Whitespace-only detection: `orChars |= c` over the scan, then `orChars <= 0x20`.
- Duplicate attributes are found after namespace lookup: an O(n²) comparison of atomized references below 64 attributes, a hash set above.
- **Name atomization.** `NameTable.Add(char[], start, len)` hashes without allocating and returns the one string for that name, so names compare by reference. Generated serializers atomize their expected names once (`InitIDs`) and compare references.
- Security: `XmlReader.Create` defaults to `DtdProcessing.Prohibit`, a null resolver, `MaxCharactersFromEntities` = 1e7 and `MaxCharactersInDocument` = 0 (unlimited). But the legacy `XmlTextReader`, used by `XmlDocument.Load`, defaults to DTD **Parse** and **no normalization**, and `XDocument.Load` uses Parse too. **The defaults depend on the entry point, which is a lesson in what not to do.**
- XLinq tricks:
  - `XName`/`XNamespace` are atomized globally (with weak references).
  - Attributes form a circular singly linked list.
  - `XContainer.content` is null for `<a/>`, a **string** for a single text child (`""` for `<a></a>`), or the last node of a circular list. So the common leaf element costs no text node, and the empty form is kept for free.
- XmlWriter defaults to `NewLineChars = Environment.NewLine` (platform-dependent; avoid). The raw writer escapes `\t\n\r` in attribute values as char refs so they survive normalization on re-read.
- `XmlSerializer` attributes: `[XmlRoot]`, `[XmlElement(Name, Namespace, Type, Order)]` (repeatable: polymorphic choice, unwrapped lists), `[XmlAttribute]`, `[XmlText]`, `[XmlArray]` + `[XmlArrayItem]` (wrapped lists), `[XmlIgnore]`, `[XmlEnum(Name)]`, `[XmlInclude]` (`xsi:type`), `[XmlAnyElement]`, `[XmlAnyAttribute]`, `[XmlNamespaceDeclarations]`. Presence is controlled by `FooSpecified` / `ShouldSerializeFoo()`. The serializer emits IL at run time, with a reflection fallback under AOT.

**TurboXml** (xoofx, 2026-07-13)
- `XmlParser.Parse<THandler>(…, ref THandler)` is generic over a struct handler and a char provider, so every callback is monomorphized. Beef generics with a struct `where T : IXmlHandler` do the same.
- The callbacks take spans valid only during the call: `OnBeginTag`, `OnEndTagEmpty`, `OnEndTag`, `OnAttribute`, `OnText`, `OnComment`, `OnCData`, `OnXmlDeclaration`, `OnProcessingInstruction`, `OnError`, each with line and column.
- One pooled buffer holds the stack of open names. **End tags are checked by comparing against the stacked start-tag bytes, 16 at a time**, not by parsing a name.
- Vector128/256 stop-set scans for text (`<`, `&`, controls, surrogates) and attribute values; a 64K class table for the scalar path. SIMD is abandoned near the end of the buffer (no slack).
- Gaps: no EOL normalization in text, no attribute-value normalization, no duplicate-attribute check (deliberate), BOM sniffing that seeks the stream, the declared encoding ignored, DOCTYPE rejected or skipped, no namespaces.
- README numbers (<https://github.com/xoofx/TurboXml>, .NET 8, Ryzen 9 7950X):
  - Tiger.svg: 54.6 µs vs `XmlReader` 75.3 µs.
  - 240 MSBuild files: 3.9 ms vs 4.4 ms.
  - 0 B / 13 KB allocated vs 194 KB / 6.2 MB.
- The win comes from allocation and atomization, not SIMD.

**KirillOsenkov/XmlParser** (2026-08-19)
- A port of the Roslyn VB XML-literal parser into a red/green tree: immutable green nodes with widths, and lazy red nodes with parents and positions.
- Whitespace inside tags is token trivia; whitespace in content is text.
- `ToFullString()` reproduces the input byte for byte. Entity tokens keep both the raw text and the decoded value.
- Error-tolerant, with missing tokens and skipped-token trivia. Incremental reparsing.
- No DTD and no namespace resolution. Self-described as not tuned for speed.
- This is the model for *what* round-trip must keep, but not for *how*: an object per token is far too heavy for a data library.

### Java
- The JDK ships a fork of Xerces-J (SAX, DOM, StAX). **JAXP limits**:
  - entity expansions 64,000
  - total entity size 5×10⁷
  - parameter entity size 10⁶
  - element attributes 10,000
  - XML name length 1,000
  - element depth unlimited
  
  Recent JDKs ship a stricter `jaxp-strict` configuration: 2,500 expansions, 100,000 bytes, depth 100, 200 attributes (<https://docs.oracle.com/en/java/javase/21/security/java-api-xml-processing-jaxp-security-guide.html>).
- **StAX `XMLStreamReader`** is the cleanest pull API to copy:
  - `next()` returns an event type.
  - `getLocalName`, `getPrefix`, `getNamespaceURI`.
  - Indexed attributes: `getAttributeCount`, `getAttributeLocalName(i)`, `getAttributeValue(i)`, `getAttributeValue(ns, local)`.
  - `getNamespaceCount`, `getNamespaceURI(i)`.
  - `getTextCharacters` (zero copy) vs `getText`.
  - `getElementText()` (text-only content), `nextTag()` (skips whitespace, comments and PIs), `require(type, ns, name)`.
  - `getLocation()`.
  - `IS_COALESCING`, off by default, so text may arrive in pieces.
- **Woodstox** is lazy: text is materialized on request, names come from symbol tables, and it has its own limits. **Aalto** is about 2× Woodstox according to its author, and offers non-blocking `feedInput`/`EVENT_INCOMPLETE` parsing.

### Rust

**quick-xml** (0.42, 2026-09-02)
- The pull reader has two front ends from one macro:
  - `read_event()` over `&[u8]`/`&str` borrows from the input.
  - `read_event_into(&mut buf)` over `BufRead` borrows from a caller buffer that grows to the largest token.
- Markup is found in two phases:
  1. A resumable `Parser::feed(chunk)` state machine finds the end, so tokens can straddle refills. The start tag is `memchr3('>', '\'', '"')` with a 3-state quote machine.
  2. The name and attributes are split **lazily**. `attributes()` is an iterator over the tag slice; duplicate checking uses a range list, then a hash set past a threshold.
- Text scanning uses `memchr2('<', '&')`; EOL scanning uses `memchr3('\r', 0xC2, 0xE2)`.
- Events: `Start`, `End`, `Empty`, `Text`, `CData`, `Comment`, `Decl`, `PI`, `DocType`, `GeneralRef`, `Eof`. They carry **raw escaped text**, so Reader → Writer round-trips exactly, and unescaping (`Cow`) happens on demand.
- `NsReader`: all bindings live in one `String` arena plus a `Vec` of ranges with levels, searched linearly in reverse. The pop is deferred so `End` still resolves. At most 128 bindings. An unknown prefix is a *value* (`ResolveResult::Unknown`), not an error.
- Lenient by default:
  - No Name or Char checks, `--` allowed in comments, no `]]>` or single-root checks, DOCTYPE opaque.
  - Byte offsets only.
  - UTF-16 only through a decoding wrapper.
- serde conventions (see the typed-mapping table): `@name` = attribute, `$text` = text content, `$value` = any content. Recursion is limited to 128, and the lookahead buffer is bounded (`overlapped-lists`).

**roxmltree** (0.21, 2026-09-22)
- Read-only DOM; `Document { text, nodes: Vec<NodeData>, attributes: Vec<AttributeData>, namespaces }`.
- `NodeId(NonZeroU32)`, nodes in preorder: `first_child = id+1`, and `next_subtree` gives the next sibling. Attributes are ranges into one `Vec`.
- Names are `(namespace index, &str)`.
- `StringStorage = Borrowed | Owned(Arc<str>)`: text stays a view unless `memchr2('&', '\r')` finds work (attributes: `& \t \n \r`). CDATA and adjacent text merge into one node.
- Namespaces are deduplicated (prefix, URI) pairs, and each element has a range of in-scope indices.
- Line and column are computed **lazily** from byte offsets, only for errors and on request (`text_pos_at`). Positions are a feature flag costing 8 bytes per node.
- 30+ located error kinds.
- `allow_dtd = false` by default (`DtdDetected`). With it on, internal entities are re-tokenized as markup, and `LoopDetector` limits depth to 10 and references per top-level reference to 255.
- `nodes_limit`; content is parsed iteratively (the latest commit fixes a stack overflow).
- The README feature table and numbers are the best cross-library summary available (<https://github.com/RazrFalcon/roxmltree#performance>). Peak memory is 6–8× the file size.

**xmlparser** (2023 release; forked into roxmltree)
- A zero-allocation tokenizer over `&str`. Every token carries a `StrSpan`. Attributes are one token each (`ElementStart`, then `Attribute`…, then `ElementEnd{Open|Close|Empty}`).
- A document-order state enum. Two-level errors: construct + cause + `TextPos`.
- Validates Names, Char, comments, `]]>` and references. Does not validate nesting or duplicates.
- `from_fragment` re-tokenizes entity text while keeping absolute positions.

**xml-rs** (1.4, 2026-09-19)
- Slow by construction:
  - `Read::bytes()` per byte, per-char lexer tokens, a `String` per name and value.
  - The in-scope namespace map is **cloned into a `BTreeMap` for every start element**.
  - Entities are re-lexed through a `VecDeque<char>`.
- About 23–39 MB/s in roxmltree's table.
- Useful ideas:
  - The W3C suite runner with per-suite known-failure lists (224 lines).
  - Named limits: name 2¹⁸, attributes 2¹⁶, attribute and data length 2³⁰, entity depth 10, entity length 10⁶.
  - Writer options: `normalize_empty_elements`, `autopad_comments`, escaping `--` and `]]>`.
- Lenient defaults: multiple roots allowed, comments dropped.

**xmltree-rs** is a DOM over xml-rs. It keys attributes by *local name only* in a `HashMap` (order lost unless a feature is enabled; prefixes lost), builds recursively, and drops whitespace and DOCTYPE. It shows the ergonomics (`get_child`, `take_child`, name or (name, ns) predicates) but none of the data model.

### Go
- **encoding/xml**:
  - `getc()` makes an interface `ReadByte` call per byte and allocates a `string` per name, a `[]Attr` per start tag and a boxed `Token`, then runs a second rune pass for the Char checks. The result is 8 allocations per element (golang/go#21823, open since 2017).
  - `Token()` translates namespaces and loses the prefix; `RawToken()` keeps it.
  - It accepts duplicate attributes, unbound prefixes and multiple roots (golang/go#68299 lists the missing checks). DOCTYPE is an opaque `Directive`.
  - Struct tags: `xml:"name,attr"`, `,chardata`, `,cdata`, `,innerxml`, `,comment`, `,any`, `,any,attr`, `,omitempty`, `-`, `a>b>c` paths, `XMLName`, `"ns local"`, plus `Unmarshaler`/`MarshalerAttr` hooks.
  - Unmatched data is discarded silently, and numbers are not checked for overflow.
  - Measured here: about 55–61 MB/s.
- **beevik/etree** is a DOM over `RawToken`:
  - Ordered `[]Attr`, `Child []Token`, and `CharData` with whitespace and CDATA flags.
  - Write settings: `CanonicalEndTags`, `AttrSingleQuote`, minimal escaping.
  - An XPath-subset `Path`.
  - It recovers CDATA by re-reading the raw bytes, a hack forced by the tokenizer.
- **antchfx/xmlquery**:
  - Linked DOM + XPath 1.0, and `CreateStreamParser(r, "/a/b")`, which yields matching subtrees. That is a nice API, but it evaluates XPath on every start tag.
  - It reconstructs prefixes through a global URI→prefix map (wrong when one URI has two prefixes) and synthesizes a missing XML declaration.

### Zig
- **ianprime0509/zig-xml** (2026-07-21) is the closest in spirit to XmlBeef. It targets XML 1.0 5th ed. + Namespaces and **rejects DOCTYPE**.
  - A pull `Reader` with `Static` and `Streaming` implementations over a sliding window that doubles without a cap (no token limit).
  - `read()` returns a node kind: `xml_declaration`, `element_start`, `element_end`, `comment`, `pi`, `text`, `cdata`, `character_reference`, `entity_reference`. **References are separate nodes**, so text is always a raw slice and the source spelling is never lost.
  - Scan, then check: `indexOfAnyPos("&<")` finds the end, and a separate pass checks UTF-8 (`assume_valid_utf8` skips it) and Char/`]]>`.
  - Location is updated once per token, not per byte.
  - Naming: `fooRaw()` / `foo()` (normalized, valid until the next read) / `fooAlloc()` / `fooWrite(writer)` / `fooNs()`, e.g. `attributeValue(i)`, `attributeIndexNs(ns, local)`, `readElementText`, `skipElement`.
  - 35 error codes with a location. A W3C runner with explicit skip categories, and AFL fuzzing.
- **nektro/zig-xml** is spec-mirroring recursive descent over code points into an SoA (`MultiArrayList`, u32 indices, interned strings). But it keeps the whole input resident, trims text, drops comments, turns undefined entities into warnings, and claims conformance from valid tests only.

### Python and JavaScript
- **ElementTree**:
  - expat → `TreeBuilder` target (`start`, `data`, `end`, `comment`, `pi`, `start_ns`).
  - `Element{tag, attrib, text, tail, children}`: text before the first child is `.text`, text after an element is its `.tail`. A simple model for data, but it cannot keep CDATA, references or tag whitespace.
  - C accelerator: 4 inline children, and tagged pointers for lazily joined text.
  - `iterparse` and `XMLPullParser.feed()/read_events()` (push in, pull out).
  - Prefixes are lost; the writer invents `ns0`.
  - Measured here: 52 MB/s.
- **lxml** (libxml2) defaults: `resolve_entities='internal'` (changed in 5.0), `load_dtd=False`, `no_network=True`, `huge_tree=False`, `strip_cdata=True`. Its 2026 CVEs (iterparse still resolving external entities) again show defaults drifting between entry points. Measured here: 112 MB/s.
- **fast-xml-parser** (v5):
  - Parses a whole string: CRLF is replaced up front, attributes are parsed by regex, and text is built with `+=` per char.
  - Object conventions: `@_` attributes, `#text`, `isArray`, `preserveOrder`.
  - Entity limits: size 10,000, expanded length 100,000, count 1,000, depth. Nesting limit 100.
  - It **never compares end-tag names** (`<a><b>1</c></a>` parses) unless the separate validator runs. Values are auto-typed by default.
  - 13–17 MB/s.
- **xml2js** (sax-js): `$` for attributes, `_` for text, `explicitArray`. Mixed content loses order. About 12 MB/s, and it failed on 13 MB inputs in fast-xml-parser's charts.

## Security and resource limits in the wild

| limit | libxml2 | expat | .NET | JDK (default / strict) | roxmltree | quick-xml | xml-rs | fast-xml-parser |
|---|---|---|---|---|---|---|---|---|
| DTD by default | parsed, refs kept | internal subset expanded | **Prohibit** (Create) | parsed | **rejected** | opaque | parsed | parsed |
| external entities | off (`DTDLOAD`, `NO_XXE`) | handler only | null resolver | on (!) | callback | user | no | no |
| entity amplification | 5× after 1 MB, +20 per ref | 100× after 8 MiB | 1e7 chars from entities | 64,000 expansions / 2,500 | depth 10, 255 refs per top-level ref | depth only | depth 10, 10⁶ chars | 1,000 entities, 100 K expanded |
| depth | 256 (2,048 huge) | none | none | none / 100 | none (iterative) | u16 | none | 100 |
| text / name size | 10 MB / 50 K | — | document unlimited | name 1,000 | — | — | 2³⁰ / 2¹⁸ | — |
| attributes per element | — | — | — | 10,000 / 200 | u32 | — | 2¹⁶ | — |
| namespace bindings | — | — | — | — | 65,535 unique | 128 in scope | — | — |

## Speed references for the benchmark

| implementation | throughput | source |
|---|---|---|
| pugixml (DOM, in situ) | median 854 MB/s x64 (481–1,706), MSVC 2015, i7 2.67 GHz, 9 files of 1–20 MB | <https://pugixml.org/benchmark.html> (data in `benchmark-data.js`) |
| RapidXML | median 699 MB/s | same |
| expat (SAX) / libxml2 SAX / libxml2 DOM | 157 / 156 / 66 MB/s | same |
| xerces SAX / DOM, tinyxml2 | 128 / 79, 117 MB/s | same |
| pugixml vs expat vs libxml2 DOM (i7-4850HQ, 1 MB) | 206 / 64.6 / 28.5 MB/s | <https://github.com/KrzysztofKowalski/libsimdxml> |
| quick-xml (`NsReader`, streaming) | ≈ 750 MB/s on medium.svg, ≈ 257 MB/s on large.plist (Apple M1 Pro, computed from ns/iter and file sizes) | roxmltree README |
| roxmltree (DOM) | ≈ 368 / 215 / 278 MB/s (svg / plist / huge) | roxmltree README |
| libxml2 (DOM, via rust-libxml) | ≈ 163 / 122 MB/s | roxmltree README |
| xml-rs, xmltree | ≈ 23–39, ≈ 20–36 MB/s | roxmltree README |
| TurboXml vs .NET XmlReader | 1.1–1.4× faster; zero allocation | TurboXml README |
| Go encoding/xml, ElementTree, lxml | 55–61, 52, 112 MB/s (measured here, 12 MB synthetic file) | this survey |
| fast-xml-parser, xml2js | 13–17, 12.5 MB/s (measured here) | this survey |
| KdlBeef event pass / TomlBeef | ≈ 330 MB/s KDL events (after the `KdlFailure` change) | KdlBeef `architecture.md` §3 |

Credible targets for XmlBeef:
- The **reader** should be in the quick-xml / pugixml class: several hundred MB/s on SVG-like input, with full well-formedness checking.
- The **document** should beat libxml2's DOM by 2× or more and approach roxmltree.
- Everything else in these tables (Go, Python, JS, xml-rs, the Beef libraries) is a floor, not a target.

pugixml and roxmltree are the two speed references to put in `bench/compare`. quick-xml is the reference for the pull layer, and libxml2 and expat are the conformant baselines.

## Typed mapping in other ecosystems

| role | serde + quick-xml | Go `encoding/xml` | .NET `XmlSerializer` | proposed XmlBeef |
|---|---|---|---|---|
| element name of the type | struct name / `rename` | `XMLName xml.Name` field | `[XmlRoot(Name, Namespace)]`, `[XmlType]` | `[XmlObject(Name = "svg", Namespace = …)]` |
| attribute | `#[serde(rename = "@x")]` | `xml:"x,attr"` | `[XmlAttribute("x")]` | `[XmlAttribute("x")]`; default for scalars |
| child element with a scalar | plain field | plain field | `[XmlElement("x")]` | `[XmlElement("x")]`; default for objects and lists |
| text content | `$text` | `,chardata` / `,cdata` | `[XmlText]` | `[XmlText]` (+ `AsCData`) |
| any content / choice | `$value`, enum by tag | `,any` | `[XmlAnyElement]`, repeated `[XmlElement(Type=…)]` | `[XmlChildren] List<Base>` dispatched by element name (KdlBeef's `[KdlChildren]`) |
| unwrapped list | `Vec<T>` field | `[]T` | `[XmlElement]` on a list | default: repeated elements named by the item |
| wrapped list | nested struct | `a>b` path | `[XmlArray("a")] [XmlArrayItem("b")]` | `[XmlArray("a", Item = "b")]` |
| raw markup | — | `,innerxml` | `XmlElement` field | `[XmlInnerXml] String` (source slice) |
| unknown attributes | — | `,any,attr` | `[XmlAnyAttribute]` | `Dictionary<String, String>` with `[XmlAnyAttribute]` |
| ignore / presence | `skip`, `Option` | `-`, `omitempty` | `[XmlIgnore]`, `FooSpecified` | `[XmlIgnore]`, nullable, `[XmlRequired]` |
| enum names | `rename` | `TextUnmarshaler` | `[XmlEnum("x")]` | case names through `XmlNaming`, `[XmlName]` per case |
| custom | `Deserialize` impl | `Unmarshaler`, `UnmarshalerAttr` | `IXmlSerializable` | `IXmlConverter<T>` / `IXmlSerializable` (KdlBeef's) |
| namespaces | prefix in the name | `"uri local"` in the tag | `Namespace =` on every attribute | `Namespace =` on type and member; matched by (URI, local) |

## Conclusions for XmlBeef

### Layering
Build three layers, the KdlBeef shape.
1. **Reader core** `XmlReaderCore<TCursor>`: KdlBeef's generic cursor (in-memory `ByteCursor` whose `Fill` folds to `false`, and `BufferedStreamCursor` with absolute offsets, `mRetain` and `MaxTokenBytes`), plus the internal `Result<T, XmlFailure>` with an empty error token.
2. **Public pull reader** `XmlReader`: StAX/zig-xml events with views valid until the next `Next()`.
3. **Document** `XmlDocument` built from the reader's events. No layer is built over the tree (libxml2's xmlReader) or over callbacks.

A struct-generic handler adapter (`Parse<THandler>`, TurboXml's style) is cheap to add on top of the reader if SAX style is wanted. It is not a separate parser.

### Scanning and checking
- **Validate UTF-8 once, before the reader sees the bytes.** KdlBeef's `FindInvalid` checks 8 bytes of plain ASCII at a time, over the whole input for memory or per refill for streams. The XML `Char` production then reduces to a control-byte test in the ASCII path plus U+FFFE/U+FFFF and surrogates, which the validator already excludes.
- Scanners look only for their stop bytes. For each state, keep a 256-entry class table (pugixml, expat), generated at comptime:
  - text: `< & \r ]` and controls
  - attribute value: the quote, `< & \r \n \t` and controls
  - comment: `-`
  - CDATA: `]`
  - PI: `?`
  
  For long runs use TomlBeef/KdlBeef's 8-byte SWAR `ScanRun`.
- Check the rare constraints only where they can occur:
  - `]]>` in text only after a `]`.
  - `--` in comments at each `-` found.
  - The full `NameStartChar`/`NameChar` ranges only for bytes ≥ 0x80: a table for ASCII, a cold range search for the rest (roxmltree).
- End tags: compare the bytes with the open element's name, TurboXml's style. Do not parse and intern the name again.
- Duplicate attributes: n² over interned name ids for small counts, and a version-stamped hash above about 16 (expat, .NET). Check again by (URI, local) after namespace resolution.
- Well-formedness is checked in full by default: every check pugixml, quick-xml, Go and fast-xml-parser skip. The spec and the W3C suite decide. Speed comes from the fast paths above, not from skipping checks. A "trusted input" switch can be a later measurement-driven option.

### Names
- **Intern names per document** in the document store: tag names, attribute names, prefixes and namespace URIs. An `XmlNameId` (u32) names an entry holding prefix, local name, the full QName text and a hash. SVG repeats a few dozen names thousands of times, so comparisons become integer compares and memory drops.
- Use a hash of the span that does not allocate (.NET `NameTable.Add(char[], start, len)`, libxml2's per-parser dict). Seed it, and bound it by the name limits. Never make it global (XLinq, the Go proposal, Python's prefix registry).
- The reader keeps its own small intern table so that duplicate checks and end-tag and namespace work stay allocation-free. The document may share it or copy it.
- A resolved name is (namespace id, local id) with the prefix kept alongside, for writing and round-trip. Every surveyed library that dropped the prefix (Go `Token`, ElementTree, xmlquery, xmltree) had to invent or hack it back.

### Attributes
- One ordered, contiguous list per element in a document-wide table: KdlBeef's `mEntries` with a start and count per element and `mEntryCapacity` for growth. Duplicates are an error, so lookup is a linear scan from the front. KdlBeef measured 28–64 ns for 4–16 properties, and SVG elements carry 2–15 attributes, so no index is needed.
- Each record holds a name id, value and flags (value had references, value is a raw view). In PreserveStyle it also holds the quote character, the whitespace before the name and around `=`, and the raw value.
- The reader exposes attributes by index (StAX, zig-xml: `AttributeCount`, `AttributeName(i)`, `AttributeValue(i)`, `TryGetAttribute(name)`) after the start tag has been fully read and checked. It does not use a modal cursor (.NET `MoveToAttribute`) or a token per attribute. Parse them eagerly: duplicate and namespace checks need them all, and a lazy iterator (quick-xml) would move those errors after the event.

### Text
- The reader returns **views into the window when nothing needs decoding**, found by scanning for `&` and `\r` (roxmltree, quick-xml's `Cow`). Otherwise it decodes into a reusable buffer (KdlBeef's decode buffers). Attribute values also normalize `\t`, `\n` and `\r` to spaces. Decoding in place in the window (pugixml's and .NET's gap technique) works too, and could be measured later, but it makes PreserveStyle's raw slices harder.
- Adjacent text and CDATA pieces are separate events. `CharacterReference` and `EntityReference` are not separate events in normal mode: their text is merged into the surrounding `Text` event. In PreserveStyle the reader reports the raw slices, so the writer keeps `&#x41;` vs `A` (zig-xml's split, done inside the reader).
- The document copies decoded text into its arena. Consider XLinq's trick: an element with exactly one text child stores it inline, so `<title>x</title>` costs no text record.
- Classify whitespace-only text during the scan (the .NET `orChars` trick) and flag it, so a document or mapping can skip indentation cheaply without trimming it by default.

### Entities and DTD
- **Default: parse the internal subset, never fetch anything external.** Real SVGs from Inkscape and Illustrator carry DOCTYPEs, and old ones declare entities for namespace URIs (`<!ENTITY ns_svg "http://www.w3.org/2000/svg">`), so zig-xml's and roxmltree's rejection is too strict for "read SVG from disk".
- Parse `<!ENTITY>` (general and parameter), and syntax-check `<!ELEMENT>`, `<!ATTLIST>`, `<!NOTATION>` and conditional sections only as far as the W3C not-wf tests require. The plan must decide whether ATTLIST defaults and attribute types (CDATA vs tokenized normalization) are applied. The spec requires it for non-validating processors reading the internal subset.
- Expansion: replacement text is re-read by the same reader core over a pushed input frame (a stack of windows). It is never spliced in as literal text (BeefXml, nektro). Expansion is iterative, with a loop check (expat before 2.7 recursed).
- Limits, all in `XmlReadConfig`:
  - `MaxEntityDepth` 8–10 (roxmltree 10)
  - `MaxEntityExpansionBytes` (e.g. 10 MB, .NET's 1e7)
  - an amplification ratio after a threshold: libxml2 uses 5× after 1 MB with 20 bytes per reference; expat uses 100× after 8 MiB
  - `DtdPolicy { Prohibit, Ignore, Internal }` with Internal as the default
- External entities and the external subset are reported, not loaded. A resolver callback can come later, off by default. One options struct serves every entry point: .NET and lxml show how defaults drift.

### Namespaces
- Keep a binding stack in the reader (quick-xml's `NamespaceResolver`): one byte arena plus `(prefix id, URI id, depth)` records. Pop by truncation, with a deferred pop so `EndElement` still resolves. Resolve by a reverse linear scan, since documents have few bindings.
- Enforce the constraints:
  - unbound prefix
  - the `xml` and `xmlns` reservations
  - `xmlns:p=""` in 1.0
  - duplicate (URI, local) attributes
  - no colon in the local parts
- Cap the bindings in scope (quick-xml 128).
- Cost: nothing for elements without a prefix and without `xmlns` attributes. Resolution is one lookup per prefixed name, and the result is cached with the interned name id.
- The document stores the element's namespace id and its own declarations. It never copies the in-scope set per element (xml-rs, xmltree, roxmltree's `tree_order`).

### Encodings
- UTF-8 is the fast path and the only internal form (libxml2, pugixml).
- Detect by BOM and first bytes (Appendix F: UTF-8, UTF-16LE/BE with or without BOM; reject UCS-4 and EBCDIC with a clear error). Then check the declaration's `encoding=` against what was detected. Never ignore it (TurboXml) or pick it from a stale state (Xml-Beef).
- **UTF-16 is transcoded to UTF-8 at the cursor**: a transcoding stream cursor for streams, and one up-front conversion for memory (pugixml). Positions are then reported in UTF-8 terms plus the line and column. Native UTF-16 tokenizing (expat) doubles the scanners for a rare case.
- Latin-1 and US-ASCII are cheap to add in the same transcoding cursor. Anything else is an error, or later a user converter hook (expat's unknown-encoding handler, Go's `CharsetReader`).
- The writer emits UTF-8 by default.

### Streaming
- KdlBeef's stream cursor carries over: a fixed-size window retained from the current construct, refilled with a memmove and doubled for long constructs up to `MaxTokenBytes`, then a hard error. zig-xml and quick-xml grow without bound. Xml-Beef shows the opposite failure: a construct bigger than the buffer never completes.
- Refill only when the scan hits the window's end. Resume the scan at the old end, not from the construct's start: this is expat's reparse-deferral lesson (quadratic re-tokenization of large tokens, CVE-2023-52425) and quick-xml's resumable `feed`.
- Keep the sentinel/slack idea from pugixml and .NET: at least 8 readable bytes past the window end, so the SWAR scans need no tail loop.

### Errors, positions, limits
- Use TomlBeef/KdlBeef's `XmlParseError`: kind, message, line, column, offset, length and source name. Line and column are computed from byte offsets on demand (roxmltree, KdlBeef `Locate`), never counted per byte (xml-rs). Error kinds are an enum, like zig-xml's 35 codes and xmlparser's construct + cause pair.
- Errors are sticky, and collect-errors with recovery is optional (KdlBeef).
- `XmlReadConfig` limits with conservative defaults:
  - `MaxInputBytes`
  - `MaxDepth` 256 (libxml2)
  - `MaxAttributesPerElement` (a few thousand; JDK strict uses 200, too low for data files)
  - `MaxNameBytes` (50,000, libxml2)
  - `MaxTextBytes` / `MaxTokenBytes`
  - `MaxNamespaceBindings`
  - the entity limits
  - `MaxNodes`
  
  Add a documented `Huge` preset (libxml2 `XML_PARSE_HUGE`). Content parsing is iterative, so depth costs frames, not stack.

### Style-preserving mode (PreserveStyle)
Use KdlBeef's mechanism: per-event source slices, copied into sidecar records only in this mode. An unchanged document then writes back byte for byte, and only dirty pieces are regenerated. For XML the slices must keep:
- **the prolog as text**: the XML declaration exactly as written (quote style, spacing, whether present), any BOM, the DOCTYPE including its internal subset verbatim, and comments, PIs and whitespace between prolog items and after the root
- **start tags**: the whitespace before each attribute, around `=` and before `>` or `/>`, including newlines (Inkscape writes one attribute per line); the quote character; the attribute order (already kept); the raw value (entity and char-ref spelling, e.g. `&#10;` vs a literal newline, which normalize differently)
- **the empty-element form**: `<a/>` vs `<a></a>` (a flag on the element: XLinq's null vs `""`), and the whitespace in `<a />`
- **end tags**: `</a >` whitespace
- **content**: CDATA vs escaped text (separate node kinds, never merged as roxmltree and pugixml do), the raw text of every text node (`&gt;` vs `>`, `&#xA0;` vs U+00A0, CRLF line endings, which normal mode folds to LF), whitespace-only nodes, comments and PIs
- **entity references to declared entities**: kept as references, so `&ns_svg;` is not replaced by its expansion when writing

A changed value drops its raw slice and is regenerated in the original's form (quote character kept, escaped minimally) while the surrounding whitespace is kept. This is KdlBeef's rule and bgotink's, and it avoids kdl-rs's stale-`value_repr` bug. A new attribute is written as ` name="value"` on the same line, or on its own line with the element's attribute indent when the start tag was multi-line.

Canonical writing, for any document: double quotes, minimal escaping (`&lt; &amp;`, `&gt;` after `]]`, `&quot;` in attributes, `&#9; &#10; &#13;` in attributes so they survive normalization), `<a/>` for empty elements, `\n` line endings, and an optional indent that never touches mixed content.

### Document and mutation
- Nodes are IDs into one record table (KdlBeef's `XmlNodeId`, generation-checked handles). Node kinds: element, text, CDATA, comment, PI, plus a document root; the prolog and DOCTYPE hang off the root. Links are parent, first and last child, next and previous sibling, the same as KdlBeef. roxmltree's implicit preorder is faster to build but cannot be mutated.
- Text is in the arena, and attributes are in the entry table as described above.
- The API follows KdlBeef:
  - lookups `Find(name)`, `Children.Named`, `Descendants`, `TryGetAttribute`, and typed getters for attributes
  - `Text` (concatenated child text), `InnerText`, a namespace-aware `Find(ns, local)`
  - mutation `AddElement`, `InsertBefore`, `Move*`, `Remove`, `SetAttribute`, `RemoveAttribute`, `SetText`
  - no query language to start with; etree's small path subset can come later if it is wanted
- An xmlquery/iterparse-style `ReadSubtree` (build a document only for the element at the reader's position) is cheap on the reader-first design, and is useful for huge files.

### Typed mapping (`[XmlObject]`)
- KdlBeef's comptime generator (`IComptimeTypeApply`, `FieldPlan`, emitted `XmlRead`/`XmlWrite`, converters, naming, inheritance and mapping checks) with the roles in the table above.
- Defaults: scalars are attributes; `[XmlObject]` fields are child elements named after the field; `List<[XmlObject]>` are repeated, unwrapped children named after the item type. `[XmlText]` is the element's text; `[XmlElement]` puts a scalar in a child `<name>value</name>`.
- Names are matched by interned id (the .NET `InitIDs` idea) and by namespace when one is declared. Unknown attributes and elements are ignored by default, with an optional strict mode (Go discards silently, with no option).
- Numbers are overflow-checked. Text is never auto-typed (fast-xml-parser). Lists are not wrapped in arrays by default (xml2js).
- Recursion and lookahead are bounded (quick-xml 128). Writing updates a PreserveStyle document in place, as KdlBeef does.
- The build stops on a reserved or colliding member name, the typed-mapping version of fast-xml-parser's prototype-pollution guards.

### API naming worth copying
- Reader:
  - `Next()` returns an `XmlEvent`: `StartElement`, `EndElement`, `Text`, `CData`, `Comment`, `ProcessingInstruction`, `XmlDeclaration`, `DocType`, `EndOfDocument`. The start event also covers the empty-element form, with `IsEmptyElement` (.NET), which is simpler than quick-xml's separate `Empty`.
  - `Name`, `LocalName`, `Prefix`, `NamespaceUri`, `Depth`, `Offset`, `Value`.
  - `AttributeCount`, `AttributeName(i)`, `AttributeValue(i)`, `TryGetAttribute(name)`.
  - `ReadElementText()` (StAX `getElementText`), `NextStartElement()` (`nextTag`), `SkipElement()`, `ReadSubtree()`.
  - `Locate(offset)`.
- zig-xml's triple for values: a view valid until the next call, `…Raw` for the source spelling, and `…(String outBuffer)` to append a copy. Append-into-a-caller-buffer is the Beef convention.
- Config: TomlBeef's `XmlReadConfig` with `MetadataMode { None, Positions, PreserveStyle }`, one struct for every entry point.

### What to avoid (merged from all of the above)
- Leniency by default: unchecked end tags (fast-xml-parser), duplicate attributes, multiple roots, unbound prefixes (Go, quick-xml, TurboXml, pugixml).
- Entry-point-dependent security defaults (.NET, lxml). External entity loading by default (BeefXml).
- Per-byte virtual reads and per-token allocations (Go, xml-rs, BeefXml's char-by-char `StreamReader`).
- Recursive building or expansion (RapidXML, xmltree, old expat).
- Unbounded stream buffers (zig-xml) and buffers that cannot grow (Xml-Beef).
- Dropping prefixes, comments, PIs, CDATA or whitespace by default (ElementTree, pugixml defaults, BeefXml's trimming).
- Unordered or hashed attribute storage (xmltree, BeefXml's `Dictionary`).
- Platform newlines in the writer (.NET).
- Errors that only print or trap (BeefXml's `Debug.Break`).
- Error positions as byte offsets only (quick-xml, pugixml).
- Claiming conformance from valid tests only (nektro). Run the W3C suite, including not-wf, with explicit skip lists (xml-rs, zig-xml).

## Decisions the plan must make

1. **DTD scope.** Internal subset with entity expansion by default (recommended above), or reject or skip DOCTYPE like zig-xml and roxmltree? If internal: are ATTLIST defaults and tokenized-type normalization applied (spec-required for the internal subset, and it affects attribute values)?
2. **Text decoding.** Decode into a separate buffer (simpler, keeps raw slices for PreserveStyle), or in place in the window (pugixml and .NET; faster, and it mutates the stream window)? Measure both on the SVG corpus.
3. **Name interning scope.** Per reader, copied to the document, or one table shared by reader and document? And is the document's `XmlName` an id (compact, fast compares) or a view?
4. **Event granularity.** Are references separate events in normal mode (zig-xml) or merged (recommended)? Is a start tag one event with indexed attributes (recommended) or one event per attribute (xmlparser, BeefXml)?
5. **Encodings beyond UTF-8/16.** Latin-1 and ASCII only, or a converter hook? UCS-4 and EBCDIC rejected?
6. **XML 1.1.** Treat it as out of scope (Go, zig-xml, roxmltree) or accept `version="1.1"` with its Char and line-end rules? The W3C suite has an xml11 section either way.
7. **Default limit values**, especially depth, attributes per element and entity expansion, and whether a `Huge` preset exists.
8. **Typed-mapping defaults.** Are scalars attributes (recommended; SVG and most data formats) or child elements (Go and .NET defaults)? And how do namespaces appear on members?
9. **PreserveStyle granularity.** Byte-exact round-trip of every valid W3C suite input (the KdlBeef bar), including the internal subset verbatim and CRLF text?
10. **Collect-errors.** Carry KdlBeef's recovery over at first, or later? XML recovery (resync at the next `<`, synthesize end tags, as XmlParser does) is more complex than KDL's.
