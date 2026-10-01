# XmlBeef status

Last reviewed: 2026-09-30.

## Verification baseline

| Check | Expected result |
|-------|-----------------|
| `beefbuild -test` (Debug checks) | 166/166 pass |
| `beefbuild -test -config=TestRelease` (Release settings) | 166/166 pass |
| `./test-xml-conformance.sh` (Debug `XmlTester`; run `beefbuild` first) | In each of the document, events and rewrite modes: 957/957 valid and invalid cases accepted, 950/951 not-wf cases rejected (the one is `hst-lhs-007`, listed in `tests/xmlconf/expected-failures.txt`: `plan.md` §9 item 6), 262/262 canonical outputs byte for byte; in rewrite mode every accepted case's suite form also survives the canonical writer. 59 of the 66 not-wf cases with unread external entities accepted (tolerated); 27 error cases logged; 274 XML 1.1 and 310 other-edition cases skipped; the 9 NAMESPACE="no" cases run with `-no-ns` |
| `BIN=./build/Release_Linux64/XmlTester/XmlTester ./test-xml-conformance.sh` (run `beefbuild -config=Release` first) | Same as Debug |
| `./test-svg-corpus.sh` (and with the Release `BIN`) | 2389/2390 SVGs (W3C SVG 1.1 suite and resvg): read as a document, same suite form from events, kept by the canonical writer, which is a fixed point. The exception is resvg's `not-UTF-8-encoding.svg` (Windows-1251, phase 4), listed in `tests/corpus/expected-failures.txt` |
| `./test-leaks.sh` | No leaks (LeakSanitizer over the TestRelease `[Test]`s) |
| `beefbuild-win -test`, `beefbuild-win -test -config=TestRelease` (`~/development/beef-proton`) | 166/166 pass |
| `tests/fetch-suites.sh` | W3C XML Conformance Test Suite 20130923 (2,585 cases), W3C SVG 1.1 Second Edition suite (606 SVGs), resvg test SVGs (1,784), each verified by SHA-256 or commit |
| `bench/compare/run.sh` | The existing implementations; results in `bench/compare/results.md` (refuses to run above load average 2). XmlBeef joins in phase 3 |

Any change to `.bf` files must keep these green in both Debug and Release.

## Feature status

| Area | State |
|------|-------|
| Pull reader (`XmlReader`) | Done (phase 1): full XML 1.0 5th edition well-formedness and Namespaces 1.0 (or namespaces off), the internal subset applied (entities, attribute defaults and types, notations), entity frames, skipped-entity events, located errors, limits, in-memory input. See `architecture.md` §3 |
| Encodings | UTF-8 (BOM optional), UTF-16 and UTF-32 (BOM or byte pattern), ISO-8859-1, US-ASCII; BOM/declaration conflicts per `plan.md` §9 item 6. Windows-125x and the other single-byte tables, the converter hook and the Windows-1252 fallback are phase 4 |
| Document (`XmlDocument`, `XmlNode`) | Done (phase 2): node and attribute tables with the reader's name table adopted, navigation, `Find` by name or namespace, `Children.Named`/`Elements`, `Descendants`, typed attribute getters, `Text`/`AppendInnerText`, `ReadFile`. See `architecture.md` §4 |
| Canonical writer (`XmlDocument.Write`) | Done (phase 2), with optional indentation of element-only content. See `architecture.md` §5 |
| Suite canonical form (`XmlCanonical.WriteSuiteForm`) | Done, from a reader or a document |
| Scripts | `test-xml-conformance.sh` (document, events, rewrite; stream joins in phase 4), `test-svg-corpus.sh`, `test-leaks.sh` |
| Speed, streams, positions, PreserveStyle, mutation, `[XmlObject]`, collect-errors | Planned: `plan.md` §6 phases 3–7 |

## Open items

| ID | Item | Size |
|----|------|------|
| P3 | Phase 3: speed (join `bench/compare`, profile, fast paths; `plan.md` §6). Needs a quiet machine (load average under 2) for any figure that is recorded | L |
| W1 | Warnings have no channel yet: a UTF-8 BOM overriding an 8-bit declaration is accepted silently (the plan puts the warning in the Positions/PreserveStyle sidecar, phase 4–5) | S |
| M1 | Error messages are not golden-tested yet (phase 4); a scan of all 951 rejections found each rejected for the right reason, but name errors read "Expected X, found Y" rather than naming the bad character's rule | S |
| S1 | Streams (phase 4): the stream cursor must keep the outer window while an entity frame is read, and the DOCTYPE's `InternalSubset` view assumes the whole subset is in the window | M |
