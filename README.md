# XmlBeef

An XML 1.0 (Fifth Edition) + Namespaces parser and writer for the [Beef](https://www.beeflang.org/)
programming language, for reading data formats from disk (SVG first) fast, fully checked and with
located errors. The sibling of [TomlBeef](https://github.com/mdsitton/TomlBeef) and KdlBeef.

**Status: phase 1 of 7.** The pull reader (`XmlReader`) passes the W3C XML Conformance Test Suite's
XML 1.0 Fifth Edition + Namespaces selection (957 accepted, 950 of 951 rejected, the one a deliberate
encoding-conflict choice, and all 262 canonical outputs). The document model, writers, streams and
typed mapping are next. The plan, requirements and research are in `docs/`:

- [`docs/plan.md`](docs/plan.md) — requirements, design, phases, open questions
- [`docs/architecture.md`](docs/architecture.md) — how it works
- [`docs/status.md`](docs/status.md) — verification baseline and open items
- [`docs/spec-reference.md`](docs/spec-reference.md) — the XML 1.0 and Namespaces rules and edge cases
- [`docs/implementation-survey.md`](docs/implementation-survey.md) — existing implementations in Beef and
  eight other languages
- [`docs/test-suites.md`](docs/test-suites.md) — the W3C conformance suite and SVG corpora
- [`bench/compare/`](bench/compare/) — benchmark of the existing implementations

## License

MIT (see `LICENSE`).
