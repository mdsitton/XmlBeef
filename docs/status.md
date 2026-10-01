# XmlBeef status

Last reviewed: 2026-09-30.

## Verification baseline

| Check | Expected result |
|-------|-----------------|
| `beefbuild -test` (Debug checks) | 154/154 pass |
| `beefbuild -test -config=TestRelease` (Release settings) | 154/154 pass |
| `./test-xml-conformance.sh` (Debug `XmlTester`; run `beefbuild` first) | Events mode: 957/957 valid and invalid cases accepted, 950/951 not-wf cases rejected (the one is `hst-lhs-007`, listed in `tests/xmlconf/expected-failures.txt`: `plan.md` §9 item 6), 262/262 canonical outputs byte for byte; 59 of the 66 not-wf cases with unread external entities accepted (tolerated); 27 error cases logged; 274 XML 1.1 and 310 other-edition cases skipped; the 9 NAMESPACE="no" cases run with `-no-ns` |
| `BIN=./build/Release_Linux64/XmlTester/XmlTester ./test-xml-conformance.sh` (run `beefbuild -config=Release` first) | Same as Debug |
| `./test-leaks.sh` | No leaks (LeakSanitizer over the TestRelease `[Test]`s) |
| `beefbuild-win -test`, `beefbuild-win -test -config=TestRelease` (`~/development/beef-proton`) | 154/154 pass |
| `tests/fetch-suites.sh` | W3C XML Conformance Test Suite 20130923 (2,585 cases), W3C SVG 1.1 Second Edition suite (606 SVGs), resvg test SVGs (1,784), each verified by SHA-256 or commit |
| `bench/compare/run.sh` | The existing implementations; results in `bench/compare/results.md` (refuses to run above load average 2). XmlBeef joins in phase 3 |

Any change to `.bf` files must keep these green in both Debug and Release.

## Feature status

| Area | State |
|------|-------|
| Pull reader (`XmlReader`) | Done (phase 1): full XML 1.0 5th edition well-formedness and Namespaces 1.0 (or namespaces off), the internal subset applied (entities, attribute defaults and types, notations), entity frames, skipped-entity events, located errors, limits, in-memory input. See `architecture.md` §3 |
| Encodings | UTF-8 (BOM optional), UTF-16 and UTF-32 (BOM or byte pattern), ISO-8859-1, US-ASCII; BOM/declaration conflicts per `plan.md` §9 item 6. Windows-125x and the other single-byte tables, the converter hook and the Windows-1252 fallback are phase 4 |
| Suite canonical form (`XmlCanonical.WriteSuiteForm`) | Done |
| Conformance runner (`test-xml-conformance.sh`, `tests/xmlconf/`) | Done: events mode; document and stream modes join in phases 2 and 4 |
| Document, writers, streams, PreserveStyle, mutation, `[XmlObject]`, collect-errors | Planned: `plan.md` §6 phases 2–7 |

## Open items

| ID | Item | Size |
|----|------|------|
| P2 | Phase 2: document and canonical writer, `test-svg-corpus.sh` (`plan.md` §6). A quick event-reader pass over the corpora already accepts all 2,390 SVGs but the Windows-1251 one (phase 4) | L |
| W1 | Warnings have no channel yet: a UTF-8 BOM overriding an 8-bit declaration is accepted silently (the plan puts the warning in the Positions/PreserveStyle sidecar, phase 4–5) | S |
| M1 | Error messages are not golden-tested yet (phase 4); a scan of all 951 rejections found each rejected for the right reason, but name errors read "Expected X, found Y" rather than naming the bad character's rule | S |
| S1 | Streams (phase 4): the stream cursor must keep the outer window while an entity frame is read, and the DOCTYPE's `InternalSubset` view assumes the whole subset is in the window | M |
