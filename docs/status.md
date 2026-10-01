# XmlBeef status

Last reviewed: 2026-09-30.

## Verification baseline

| Check | Expected result |
|-------|-----------------|
| `beefbuild -test` (Debug checks) | 193/193 pass |
| `beefbuild -test -config=TestRelease` (Release settings) | 193/193 pass |
| `./test-xml-conformance.sh` (Debug `XmlTester`; run `beefbuild` first) | In each of the document, events, rewrite, stream and stream-events modes (the stream modes through a 16-byte buffer): 957/957 valid and invalid cases accepted, 950/951 not-wf cases rejected, each with its golden message (`tests/errors/<ID>.err`) (the one is `hst-lhs-007`, listed in `tests/xmlconf/expected-failures.txt`: `plan.md` §9 item 6), 262/262 canonical outputs byte for byte; in rewrite mode every accepted case's suite form also survives the canonical writer. 59 of the 66 not-wf cases with unread external entities accepted (tolerated); 27 error cases logged; 274 XML 1.1 and 310 other-edition cases skipped; the 9 NAMESPACE="no" cases run with `-no-ns` |
| `BIN=./build/Release_Linux64/XmlTester/XmlTester ./test-xml-conformance.sh` (run `beefbuild -config=Release` first) | Same as Debug |
| `./test-svg-corpus.sh` (and with the Release `BIN`) | 2390/2390 SVGs (W3C SVG 1.1 suite and resvg): read as a document, same suite form from events and from a stream with a 16-byte buffer, kept by the canonical writer, which is a fixed point |
| `./test-leaks.sh` | No leaks (LeakSanitizer over the TestRelease `[Test]`s) |
| `beefbuild-win -test`, `beefbuild-win -test -config=TestRelease` (`~/development/beef-proton`) | 193/193 pass |
| `tests/fetch-suites.sh` | W3C XML Conformance Test Suite 20130923 (2,585 cases), W3C SVG 1.1 Second Edition suite (606 SVGs), resvg test SVGs (1,784), each verified by SHA-256 or commit |
| `bench/compare/run.sh` (XmlBeef's columns: `beefbuild -config=Release` first) | The existing implementations and `XmlBeef` / `XmlBeef reader`, whose check lines match libxml2's on all eight inputs; results in `bench/compare/results.md`, which does not exist yet: run.sh refuses to run above load average 2, and the machine has not been under it (P3T) |
| `bench/instructions.sh` (after `beefbuild -config=Release`) | The instruction counts below |

Any change to `.bf` files must keep these green in both Debug and Release.

## Performance baseline

No timed figures yet (P3T). The load-independent measure, user-space instructions per input byte
(`bench/instructions.sh`, 2026-09-30), before and after the phase 3 fast paths:

| | svg-icons | svg-artwork | svg-generated | records | book | osm | atom | book-utf16 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Event pass, phase 2 | 27.5 | 17.0 | 16.4 | 36.1 | 22.3 | 44.9 | 35.5 | 43.0 |
| Event pass | 16.1 | 9.4 | 8.7 | 24.6 | 16.1 | 30.5 | 25.9 | 10.8 |
| Document read, phase 2 | 32.3 | 18.0 | 17.3 | 45.8 | 26.1 | 53.9 | 43.5 | 44.9 |
| Document read | 18.3 | 10.0 | 9.2 | 30.9 | 18.6 | 36.1 | 30.8 | 12.4 |

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
| Canonical writer (`XmlDocument.Write`) | Done (phase 2), with optional indentation of element-only content. See `architecture.md` §5 |
| Suite canonical form (`XmlCanonical.WriteSuiteForm`) | Done, from a reader or a document |
| Scripts | `test-xml-conformance.sh` (document, events, rewrite, stream, stream-events; golden messages), `test-svg-corpus.sh`, `test-leaks.sh`, `bench/instructions.sh` |
| Speed (phase 3) | Fast paths done (`architecture.md` §3 "Fast paths"), `XmlTester -bench`/`-bench-loop`, XmlBeef in `bench/compare/run.sh`; the timed run is pending (P3T) |
| PreserveStyle, mutation, `[XmlObject]`, collect-errors | Planned: `plan.md` §6 phases 5–7 |

## Open items

| ID | Item | Size |
|----|------|------|
| P3T | The timed benchmark: `cd bench/compare && ./run.sh > results.md && ./plot.py` (2–3 h) on a quiet machine (load average under 2; it was 6–19 all session), then set phase 3's numeric targets from it (`plan.md` §2.2) and check them | M |
| P5 | Phase 5: PreserveStyle sidecar, preserving writer, mutation API, `test-roundtrip.sh` (`plan.md` §6) | L |
