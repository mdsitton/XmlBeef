# XmlBeef status

Last reviewed: 2026-10-01.

## Verification baseline

| Check | Expected result |
|-------|-----------------|
| `beefbuild -test` (Debug checks) | 224/224 pass |
| `beefbuild -test -config=TestRelease` (Release settings) | 224/224 pass |
| `./test-xml-conformance.sh` (Debug `XmlTester`; run `beefbuild` first) | In each of the document, events, rewrite, stream and stream-events modes (the stream modes through a 16-byte buffer): 957/957 valid and invalid cases accepted, 950/951 not-wf cases rejected, each with its golden message (`tests/errors/<ID>.err`) (the one is `hst-lhs-007`, listed in `tests/xmlconf/expected-failures.txt`: `plan.md` §9 item 6), 262/262 canonical outputs byte for byte; in rewrite mode every accepted case's suite form also survives the canonical writer. 59 of the 66 not-wf cases with unread external entities accepted (tolerated); 27 error cases logged; 274 XML 1.1 and 310 other-edition cases skipped; the 9 NAMESPACE="no" cases run with `-no-ns` |
| `BIN=./build/Release_Linux64/XmlTester/XmlTester ./test-xml-conformance.sh` (run `beefbuild -config=Release` first) | Same as Debug |
| `./test-svg-corpus.sh` (and with the Release `BIN`) | 2390/2390 SVGs (W3C SVG 1.1 suite and resvg): read as a document, same suite form from events and from a stream with a 16-byte buffer, kept by the canonical writer, which is a fixed point |
| `./test-roundtrip.sh` (and with the Release `BIN`) | 3347 inputs (the 957 accepted suite cases and the 2390 corpus SVGs): written back byte for byte with PreserveStyle (`XmlTester -roundtrip`, in the document's encoding) from memory and through a 16-byte stream; random edits (`XmlTester -mutate`, 3 seeds of 8 edits each: 10041 runs) all read back into the edited document. The edits include the DOCTYPE's processing instructions. Run with `SEEDS=10` (33470 runs) after the DOCTYPE edits (2026-10-01) |
| `./test-leaks.sh` | No leaks (LeakSanitizer over the TestRelease `[Test]`s) |
| `beefbuild-win -test`, `beefbuild-win -test -config=TestRelease` (`~/development/beef-proton`) | 224/224 pass |
| `tests/fetch-suites.sh` | W3C XML Conformance Test Suite 20130923 (2,585 cases), W3C SVG 1.1 Second Edition suite (606 SVGs), resvg test SVGs (1,784), each verified by SHA-256 or commit |
| `bench/compare/run.sh` (XmlBeef's columns: `beefbuild -config=Release` first) | The existing implementations and `XmlBeef` / `XmlBeef reader`, whose check lines match libxml2's on all eight inputs; results in `bench/compare/results.md`, which does not exist yet: run.sh refuses to run above load average 2, and the machine has not been under it (P3T) |
| `bench/compare/run-typed.sh` (`./build.sh rust go cs`, `beefbuild -config=Release`) | XmlBeef `[XmlObject]`, quick-xml + serde, Go encoding/xml Unmarshal and .NET XmlSerializer read `osm.xml` into the same model; all four check lines equal the ElementTree reference. No timed table yet (P3T); a smoke run under load (8.65, not comparable) had XmlBeef 129 MB/s, quick-xml + serde 91, XmlSerializer 64, encoding/xml 24 |
| `bench/instructions.sh` (after `beefbuild -config=Release`) | The instruction counts below |

Any change to `.bf` files must keep these green in both Debug and Release.

## Performance baseline

No timed figures yet (P3T). The load-independent measure, user-space instructions per input byte
(`bench/instructions.sh`, 2026-09-30), before and after the phase 3 fast paths, and now (phase 5):

| | svg-icons | svg-artwork | svg-generated | records | book | osm | atom | book-utf16 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Event pass, phase 2 | 27.5 | 17.0 | 16.4 | 36.1 | 22.3 | 44.9 | 35.5 | 43.0 |
| Event pass, phase 3 | 16.1 | 9.4 | 8.7 | 24.6 | 16.1 | 30.5 | 25.9 | 10.8 |
| Event pass | 16.3 | 9.1 | 8.6 | 25.5 | 16.3 | 30.4 | 26.3 | 11.3 |
| Document read, phase 2 | 32.3 | 18.0 | 17.3 | 45.8 | 26.1 | 53.9 | 43.5 | 44.9 |
| Document read, phase 3 | 18.3 | 10.0 | 9.2 | 30.9 | 18.6 | 36.1 | 30.8 | 12.4 |
| Document read | 18.4 | 9.6 | 9.1 | 31.5 | 18.8 | 35.0 | 30.9 | 12.9 |

Phases 4 and 5 (positions, streams, located stream errors, the style capture) cost the event pass
0–4% and the document read up to 4%, after two fixes found by comparing with the phase 3 build:
in-memory UTF-16/32 input was decoded twice (the detector decoded the whole input, not its 4 KB
prefix), and the document builder is now specialized per metadata mode.

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
| Scripts | `test-xml-conformance.sh` (document, events, rewrite, stream, stream-events; golden messages), `test-svg-corpus.sh`, `test-roundtrip.sh`, `test-leaks.sh`, `bench/instructions.sh` |
| Speed (phase 3) | Fast paths done (`architecture.md` §3 "Fast paths"), `XmlTester -bench`/`-bench-loop`, XmlBeef in `bench/compare/run.sh`; the timed run is pending (P3T) |
| Typed mapping (`[XmlObject]`, `XmlSerializer`) | Done (phase 6): attributes, element text, own text, token-list attributes, repeated and wrapped lists of scalars and objects, child objects, `[XmlChildren]` dispatch, dictionaries in five shapes (`[XmlMap]`), namespaces, naming policies, aliases, required, strict types, converters, allocators, in-place writes that keep a PreserveStyle document. See `architecture.md` §6 |
| Collect-errors, `ReadSubtree`, streaming writer, resolver | Planned: `plan.md` §6 phase 7 |

## Open items

| ID | Item | Size |
|----|------|------|
| P3T | The timed benchmark: `cd bench/compare && ./run.sh > results.md && ./plot.py` (2–3 h) on a quiet machine (load average under 2; it was 6–19 all session), then set phase 3's numeric targets from it (`plan.md` §2.2) and check them | M |
| P7 | Phase 7: collect-errors with recovery (required before the library is integrated), then `ReadSubtree`, the streaming writer, the external-entity resolver as needed (`plan.md` §6) | L |
| P6T | The typed benchmark's timed run: `cd bench/compare && ./run-typed.sh` on a quiet machine, with P3T | S |
