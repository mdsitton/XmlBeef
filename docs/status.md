# XmlBeef status

Last reviewed: 2026-09-30.

## Verification baseline

| Check | Expected result |
|-------|-----------------|
| `beefbuild -test` (Debug checks) | 1/1 pass (smoke test) |
| `beefbuild -test -config=TestRelease` (Release settings) | 1/1 pass |
| `tests/fetch-suites.sh` | W3C XML Conformance Test Suite 20130923 (2,585 cases), W3C SVG 1.1 Second Edition suite (606 SVGs), resvg test SVGs (1,784), each verified by SHA-256 or commit |
| `bench/compare/run.sh` | The existing implementations; results in `bench/compare/results.md` (refuses to run above load average 2) |

Any change to `.bf` files must keep these green in both Debug and Release.

## Feature status

| Area | State |
|------|-------|
| Workspace, `XmlTester` stub | Done |
| Research: spec reference, implementation survey, test suites, benchmark | Done (`docs/`) |
| Everything else | Planned: `docs/plan.md` §3 (requirements) and §6 (phases) |

## Open items

| ID | Item | Size |
|----|------|------|
| P1 | Phase 1: reader core and conformance runner (`plan.md` §6) | L |
| Q | Open questions for the author (`plan.md` §9) | — |
