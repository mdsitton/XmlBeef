# XmlBeef status

Last reviewed: 2026-09-30.

## Verification baseline

| Check | Expected result |
|-------|-----------------|
| `beefbuild -test` (Debug checks) | 173/173 pass |
| `beefbuild -test -config=TestRelease` (Release settings) | 173/173 pass |
| `./test-xml-conformance.sh` (Debug `XmlTester`; run `beefbuild` first) | In each of the document, events and rewrite modes: 957/957 valid and invalid cases accepted, 950/951 not-wf cases rejected (the one is `hst-lhs-007`, listed in `tests/xmlconf/expected-failures.txt`: `plan.md` §9 item 6), 262/262 canonical outputs byte for byte; in rewrite mode every accepted case's suite form also survives the canonical writer. 59 of the 66 not-wf cases with unread external entities accepted (tolerated); 27 error cases logged; 274 XML 1.1 and 310 other-edition cases skipped; the 9 NAMESPACE="no" cases run with `-no-ns` |
| `BIN=./build/Release_Linux64/XmlTester/XmlTester ./test-xml-conformance.sh` (run `beefbuild -config=Release` first) | Same as Debug |
| `./test-svg-corpus.sh` (and with the Release `BIN`) | 2389/2390 SVGs (W3C SVG 1.1 suite and resvg): read as a document, same suite form from events, kept by the canonical writer, which is a fixed point. The exception is resvg's `not-UTF-8-encoding.svg` (Windows-1251, phase 4), listed in `tests/corpus/expected-failures.txt` |
| `./test-leaks.sh` | No leaks (LeakSanitizer over the TestRelease `[Test]`s) |
| `beefbuild-win -test`, `beefbuild-win -test -config=TestRelease` (`~/development/beef-proton`) | 173/173 pass |
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
| Pull reader (`XmlReader`) | Done (phase 1): full XML 1.0 5th edition well-formedness and Namespaces 1.0 (or namespaces off), the internal subset applied (entities, attribute defaults and types, notations), entity frames, skipped-entity events, located errors, limits, in-memory input. See `architecture.md` §3 |
| Encodings | UTF-8 (BOM optional), UTF-16 and UTF-32 (BOM or byte pattern), ISO-8859-1, US-ASCII; BOM/declaration conflicts per `plan.md` §9 item 6. Windows-125x and the other single-byte tables, the converter hook and the Windows-1252 fallback are phase 4 |
| Document (`XmlDocument`, `XmlNode`) | Done (phase 2): node and attribute tables with the reader's name table adopted, navigation, `Find` by name or namespace, `Children.Named`/`Elements`, `Descendants`, typed attribute getters, `Text`/`AppendInnerText`, `ReadFile`. See `architecture.md` §4 |
| Canonical writer (`XmlDocument.Write`) | Done (phase 2), with optional indentation of element-only content. See `architecture.md` §5 |
| Suite canonical form (`XmlCanonical.WriteSuiteForm`) | Done, from a reader or a document |
| Scripts | `test-xml-conformance.sh` (document, events, rewrite; stream joins in phase 4), `test-svg-corpus.sh`, `test-leaks.sh`, `bench/instructions.sh` |
| Speed (phase 3) | Fast paths done (`architecture.md` §3 "Fast paths"), `XmlTester -bench`/`-bench-loop`, XmlBeef in `bench/compare/run.sh`; the timed run is pending (P3T) |
| Streams, positions, PreserveStyle, mutation, `[XmlObject]`, collect-errors | Planned: `plan.md` §6 phases 4–7 |

## Open items

| ID | Item | Size |
|----|------|------|
| P3T | The timed benchmark: `cd bench/compare && ./run.sh > results.md && ./plot.py` (2–3 h) on a quiet machine (load average under 2; it was 6–19 all session), then set phase 3's numeric targets from it (`plan.md` §2.2) and check them | M |
| P4 | Phase 4: golden messages, Positions, every limit tested, streams, UTF-32 (done) and the single-byte tables, converter hook, fallback (`plan.md` §6) | L |
| W1 | Warnings have no channel yet: a UTF-8 BOM overriding an 8-bit declaration is accepted silently (the plan puts the warning in the Positions/PreserveStyle sidecar, phase 4–5) | S |
| M1 | Error messages are not golden-tested yet (phase 4); a scan of all 951 rejections found each rejected for the right reason, but name errors read "Expected X, found Y" rather than naming the bad character's rule | S |
| S1 | Streams (phase 4): the stream cursor must keep the outer window while an entity frame is read, and the DOCTYPE's `InternalSubset` view assumes the whole subset is in the window | M |
