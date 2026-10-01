# XmlBeef status

Last reviewed: 2026-10-01 (after the code review's fixes).

## Verification baseline

| Check | Expected result |
|-------|-----------------|
| `beefbuild -test` (Debug checks) | 251/251 pass |
| `beefbuild -test -config=TestRelease` (Release settings) | 251/251 pass |
| `./test-xml-conformance.sh` (Debug `XmlTester`; run `beefbuild` first) | In each of the document, events, rewrite, stream, stream-events, collect and stream-collect modes (the stream modes through a 16-byte buffer; the collect modes with CollectErrors): 957/957 valid and invalid cases accepted, 950/951 not-wf cases rejected, each with its golden message (`tests/errors/<ID>.err`) (the one is `hst-lhs-007`, listed in `tests/xmlconf/expected-failures.txt`: `plan.md` §9 item 6), 262/262 canonical outputs byte for byte; in rewrite mode every accepted case's suite form also survives the canonical writer. 59 of the 66 not-wf cases with unread external entities accepted (tolerated); 27 error cases logged; 274 XML 1.1 and 310 other-edition cases skipped; the 9 NAMESPACE="no" cases run with `-no-ns` |
| `BIN=./build/Release_Linux64/XmlTester/XmlTester ./test-xml-conformance.sh` (run `beefbuild -config=Release` first) | Same as Debug |
| `./test-svg-corpus.sh` (and with the Release `BIN`) | 2390/2390 SVGs (W3C SVG 1.1 suite and resvg): read as a document, same suite form from events and from a stream with a 16-byte buffer, kept by the canonical writer, which is a fixed point |
| `./test-roundtrip.sh` (and with the Release `BIN`) | 3347 inputs (the 957 accepted suite cases and the 2390 corpus SVGs): written back byte for byte with PreserveStyle (`XmlTester -roundtrip`, in the document's encoding) from memory and through a 16-byte stream; random edits (`XmlTester -mutate`, 3 seeds of 8 edits each: 10041 runs) all read back into the edited document, compared in the suite form (defaulted attributes included). The edits include the DOCTYPE's processing instructions and its removal, and CRs in CDATA. Run with `SEEDS=10` (33470 runs) after the review's fixes (2026-10-01) |
| `./test-collect.sh` (and with the Release `BIN`) | Every suite case of the selection and every corpus SVG, mutated 10 times per seed for 2 seeds (8782 runs), read with CollectErrors from memory and through a 16-byte stream: no crash, no hang, the same errors and document both ways. Run with `SEEDS=5 ROUNDS=20` (21955 runs) at the end of the collect-errors work |
| `./test-leaks.sh` | No leaks (LeakSanitizer over the TestRelease `[Test]`s) |
| `./test-codegen.sh` | 18/18 `[XmlObject]` fixtures (`tests/codegen/src/Fixtures.bf`), each built alone: 16 mappings the generator must reject stop the build with their message (roles, collisions by name, alias and inheritance, invalid names, catch-alls, dictionaries, converters), 2 positive controls build |
| `beefbuild-win -test`, `beefbuild-win -test -config=TestRelease` (`~/development/beef-proton`) | 251/251 pass |
| `tests/fetch-suites.sh` | W3C XML Conformance Test Suite 20130923 (2,585 cases), W3C SVG 1.1 Second Edition suite (606 SVGs), resvg test SVGs (1,784), each verified by SHA-256 or commit |
| `bench/compare/run.sh` (XmlBeef's columns: `beefbuild -config=Release` first) | The existing implementations and `XmlBeef` / `XmlBeef reader`, whose check lines match libxml2's on all eight inputs; results in `bench/compare/results.md`, which does not exist yet: run.sh refuses to run above load average 2, and the machine has not been under it (P3T) |
| `bench/compare/run-typed.sh` (`./build.sh rust go cs`, `beefbuild -config=Release`) | XmlBeef `[XmlObject]`, quick-xml + serde, Go encoding/xml Unmarshal and .NET XmlSerializer read `osm.xml` into the same model; all four check lines equal the ElementTree reference. No timed table yet (P3T); a smoke run under load (8.65, not comparable) had XmlBeef 129 MB/s, quick-xml + serde 91, XmlSerializer 64, encoding/xml 24 |
| `bench/instructions.sh` (after `beefbuild -config=Release`) | The instruction counts below |

Any change to `.bf` files must keep these green in both Debug and Release.

## Performance baseline

No timed figures yet (P3T). The load-independent measure, user-space instructions per input byte
(`bench/instructions.sh`), before and after the phase 3 fast paths, after phase 5, before the
review's P02 (2026-10-01, after its R fixes) and now; the stream rows read the same inputs as a
`Stream` through the default 64 KiB buffer and a 4 KiB one:

| | svg-icons | svg-artwork | svg-generated | records | book | osm | atom | book-utf16 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Event pass, phase 2 | 27.5 | 17.0 | 16.4 | 36.1 | 22.3 | 44.9 | 35.5 | 43.0 |
| Event pass, phase 3 | 16.1 | 9.4 | 8.7 | 24.6 | 16.1 | 30.5 | 25.9 | 10.8 |
| Event pass, phase 5 | 16.3 | 9.1 | 8.6 | 25.5 | 16.3 | 30.4 | 26.3 | 11.3 |
| Event pass, before P02 | 16.4 | 9.1 | 8.6 | 25.9 | 16.8 | 30.6 | 26.8 | 11.6 |
| Event pass (now) | 16.1 | 8.9 | 7.9 | 25.7 | 16.7 | 30.1 | 26.5 | 11.5 |
| Document read, phase 2 | 32.3 | 18.0 | 17.3 | 45.8 | 26.1 | 53.9 | 43.5 | 44.9 |
| Document read, phase 3 | 18.3 | 10.0 | 9.2 | 30.9 | 18.6 | 36.1 | 30.8 | 12.4 |
| Document read, phase 5 | 18.4 | 9.6 | 9.1 | 31.5 | 18.8 | 35.0 | 30.9 | 12.9 |
| Document read, before P02 | 18.6 | 9.7 | 9.1 | 32.0 | 19.3 | 35.4 | 31.4 | 13.1 |
| Document read (now) | 18.3 | 9.4 | 8.4 | 31.8 | 19.2 | 34.8 | 31.1 | 13.1 |
| Stream events, before P02 | 31.6 | 45.4 | 43.0 | 64.9 | 54.1 | 67.1 | 64.5 | 30.4 |
| Stream events, after P02 | 22.5 | 13.1 | 11.8 | 35.7 | 22.8 | 37.1 | 34.6 | 14.6 |
| Stream events (now) | 19.0 | 10.9 | 9.2 | 32.6 | 19.4 | 33.8 | 31.3 | 12.9 |
| Stream events, 4 KiB buffer, before P02 | 34.3 | 44.2 | 42.1 | 65.0 | 54.2 | 66.8 | 64.6 | 30.5 |
| Stream events, 4 KiB buffer (now) | 19.3 | 11.0 | 9.5 | 33.0 | 19.9 | 34.2 | 31.7 | 13.3 |

The stream's cost had been mostly line counting (a column per code point, byte by byte, for every
start tag's position, and again for the bytes a refill drops). P02 counted 8 bytes at a time and once
and made the scans resume their words after a refill; SP1 then stopped locating start tags (only
elements still open when the buffer moves are located) and counts newlines alone, skipping words
without a byte below 0x0E (`architecture.md` §3). Streams now cost 1.1–1.3× the in-memory event pass.

Phases 4 and 5 (positions, streams, located stream errors, the style capture) cost the event pass
0–4% and the document read up to 4%, after two fixes found by comparing with the phase 3 build:
in-memory UTF-16/32 input was decoded twice (the detector decoded the whole input, not its 4 KB
prefix), and the document builder is now specialized per metadata mode. Collect-errors (phase 7)
costs the normal path 0.5–1.5% more (a check per start tag, and code size moving the compiler's
inlining; measured against the commit before it).

IPC on records' event pass is about 2.7 with few branch misses, so instructions track time closely
there. Orientation runs under load (not comparable, not recorded in results.md) put the event pass
ahead of quick-xml and the document ahead of roxmltree on every input; the timed run has to confirm
it.

## Feature status

| Area | State |
|------|-------|
| Pull reader (`XmlReader`) | Done (phases 1, 4): full XML 1.0 5th edition well-formedness and Namespaces 1.0 (or namespaces off), the internal subset applied (entities, attribute defaults and types, notations), entity frames, skipped-entity events, located errors with golden-tested messages, every limit tested, in-memory and `Stream` input (identical events and errors). See `architecture.md` §3 |
| Encodings | Done (phase 4): UTF-8 (BOM optional), UTF-16 and UTF-32 (BOM or byte pattern), US-ASCII, exact ISO-8859-1/-9/-11, the WHATWG single-byte tables (windows-125x, ISO-8859-x, KOI8, Mac, IBM866; 154 labels), the `EncodingConverter` hook, the opt-in Windows-1252 fallback; BOM/declaration conflicts per `plan.md` §9 item 6, the BOM override reported by `EncodingWarning` |
| Positions (`XmlMetadataMode.Positions`) | Done (phase 4): source ranges of nodes and attributes, `TryGetSourceRange`; reader `GetAttributeRange` |
| Document (`XmlDocument`, `XmlNode`) | Done (phase 2): node and attribute tables with the reader's name table adopted, navigation, `Find` by name or namespace, `Children.Named`/`Elements`, `Descendants`, typed attribute getters, `Text`/`AppendInnerText`, `ReadFile`. See `architecture.md` §4 |
| Canonical writer (`XmlDocument.WriteCanonical`) | Done (phase 2), with optional indentation of element-only content. See `architecture.md` §5 |
| PreserveStyle (`XmlMetadataMode.PreserveStyle`) | Done (phase 5): `Write` gives back an unchanged document byte for byte and regenerates only what changed; entity references kept until what they produced changes; `WriteBytes`/`WriteFile` in the document's encoding, with a choice for characters it cannot hold (`XmlWriteOptions.Unencodable`: error, character references, replacement, UTF-8, a handler). See `architecture.md` §4 |
| Mutation | Done (phase 5): add, insert, move, remove, rename, set values, text and attributes, with namespaces resolved again. See `architecture.md` §4 |
| Suite canonical form (`XmlCanonical.WriteSuiteForm`) | Done, from a reader or a document |
| Scripts | `test-xml-conformance.sh` (document, events, rewrite, stream, stream-events, collect, stream-collect; golden messages), `test-svg-corpus.sh`, `test-roundtrip.sh`, `test-collect.sh`, `test-codegen.sh`, `test-leaks.sh`, `bench/instructions.sh` |
| Speed (phase 3) | Fast paths done (`architecture.md` §3 "Fast paths"), `XmlTester -bench`/`-bench-loop`, XmlBeef in `bench/compare/run.sh`; the timed run is pending (P3T) |
| Typed mapping (`[XmlObject]`, `XmlSerializer`) | Done (phase 6): attributes, element text, own text, token-list attributes, repeated and wrapped lists of scalars and objects, child objects, `[XmlChildren]` dispatch, dictionaries in five shapes (`[XmlMap]`), namespaces, naming policies, aliases, required, strict types, converters, allocators, in-place writes that keep a PreserveStyle document. See `architecture.md` §6 |
| Collect-errors (`XmlReadConfig.CollectErrors`) | Done (phase 7): every error reported and the read goes on; the document keeps what it read and lists the errors (`Errors`). See `architecture.md` §3 |
| `ReadSubtree`, streaming writer, resolver | Planned "as needed": `plan.md` §6 phase 7 |

## Open items

The [2026-10-01 code review](review-2026-10-01.md) recorded fourteen reproduced correctness
findings (R01-R14), performance and memory opportunities, and proposed architecture and test
improvements. R01-R14, P01 and P03 are fixed, each with a regression in `XmlReviewTests.bf`; its
"Resolution" section records the fixes and the policy decisions (R06, R09, R11, R14). P02 (streamed
scans and line counting), P04 (`Compact`, `Clear(true)`, `MemoryUsage`) and A01-A04 followed; what
remains of them is below (RV-); the follow-up SP1 (no per-start-tag position work in streams) is done.

| ID | Item | Size |
|----|------|------|
| P3T | The timed benchmark: `cd bench/compare && ./run.sh > results.md && ./plot.py` (2–3 h) on a quiet machine (load average under 2; it was 6–19 all session), then set phase 3's numeric targets from it (`plan.md` §2.2) and check them | M |
| P7 | Phase 7's extras, as needed: `ReadSubtree`, the streaming writer, the external-entity resolver (`plan.md` §6) | M |
| P6T | The typed benchmark's timed run: `cd bench/compare && ./run-typed.sh` on a quiet machine, with P3T | S |
| RV-L | Known limits kept: a CR in a comment or PI data reads back as LF (no escape exists); removing a specified attribute that has a DTD default lets the default return on reading; references to unread entities stay as written after the DOCTYPE is removed (`architecture.md` §4 "Edit dependencies") | S |
| RV-A1 | Review A01 beyond the frame window: typed document offsets versus window offsets (today both are `int`, converted by `DocOffset`/`DocEnd`) would be a wide change to the core for a small gain; not done | S |