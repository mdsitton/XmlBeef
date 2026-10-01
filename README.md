# XmlBeef

An XML 1.0 (Fifth Edition) + Namespaces parser and writer for the [Beef](https://www.beeflang.org/)
programming language, for reading data formats from disk (SVG first) fast, fully checked and with
located errors. The sibling of [TomlBeef](https://github.com/mdsitton/TomlBeef) and KdlBeef.

**Status: planning.** Nothing parses XML yet. The plan, requirements and research are in `docs/`:

- [`docs/plan.md`](docs/plan.md) — requirements, design, phases, open questions
- [`docs/spec-reference.md`](docs/spec-reference.md) — the XML 1.0 and Namespaces rules and edge cases
- [`docs/implementation-survey.md`](docs/implementation-survey.md) — existing implementations in Beef and
  eight other languages
- [`docs/test-suites.md`](docs/test-suites.md) — the W3C conformance suite and SVG corpora
- [`bench/compare/`](bench/compare/) — benchmark of the existing implementations

## License

MIT (see `LICENSE`).
