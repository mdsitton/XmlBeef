# Test suites and corpora

The reference for everything test-related in XmlBeef: which third-party conformance suites and
corpora are used, how they are organized, how a non-validating XML 1.0 (Fifth Edition) + Namespaces
1.0 processor must classify and judge each case, and the planned test scripts. Facts below were
checked on 2026-09-30; the counts were computed from the actual catalogs with a small script
(section 6 describes the selection rules precisely so they can be re-derived).

Fetch everything with `tests/fetch-suites.sh` (into the git-ignored `tests/suites/`):

| Directory | What | Pin | Size |
|---|---|---|---|
| `tests/suites/xmlconf/` | W3C XML Conformance Test Suite **20130923**, unmodified | `xmlts20130923.tar.gz`, SHA-256 `9b61db9f…6fc1f` | 0.64 MB download, 16 MB extracted, 2,585 cases |
| `tests/suites/svg11/` | W3C SVG 1.1 Second Edition test suite (20110816), SVG documents only | `W3C_SVG_11_TestSuite.tar.gz`, SHA-256 `b5f46cca…1ff1030` | 14.7 MB download, 606 SVG files (~6 MB on disk) |
| `tests/suites/resvg/` | resvg SVG regression tests, `*.svg` only (sparse, blobless checkout) | linebender/resvg commit `75b6bbad…` (2026-09-16) | 1,784 SVG files (~1.1 MB of content) |

Downloaded archives are kept in `tests/suites/.downloads/`; each suite directory has a `.pinned`
stamp so reruns are no-ops.

---

## 1. The W3C XML Conformance Test Suite: editions and which one to use

### 1.1 Every release

The suite's home is <https://www.w3.org/XML/Test/>. The page the question started from,
<https://www.w3.org/XML/Test/xmlconf-20020606.htm>, is only the *report* (test descriptions) of the
2002 release. All releases are still downloadable from the home page:

| Release | Files (all under `https://www.w3.org/XML/Test/`) | SHA-256 | Cases | What it added or changed |
|---|---|---|---:|---|
| 20020606 | `xmlts20020606.zip` (also `.tar`) | zip: `d58880ae46d51e98be0fae73ec652a56fc09b3802ac90fb24a0c659e9bb9677f` | 1,811 | "XML 1.0 (Second Edition) errata 20020320" suite, transferred from OASIS: James Clark's xmltest (364), Fuji Xerox Japanese (12), Sun (159), OASIS/NIST (348), IBM XML 1.0 (928). No EDITION/VERSION attributes. |
| 20031210 | `xmlts20031210.zip`, `.tar` | zip: `4f03503040be97dc04eb2fd5c7a448d197e720f069a6c6f33eba1b2c2bb17706` | 2,162 | IBM XML 1.1 tests (208) and Richard Tobin's (Edinburgh) collections: XML 1.0 2nd-edition errata, XML 1.1, Namespaces 1.0 and 1.1 (143). Fixed the ENTITIES attribute of a few Sun/IBM tests (`cond01`, `cond02`, `dtd07`, `encoding07`, the misspelled `paramenter` on `ibm30n01`/`ibm31n01`, `ibm62n02`). |
| 20080205 | `xmlts20080205.zip`, `.tar.gz`, `.tar` | tar.gz: `39ffe4a61be4187aac4b64b8fd34aa01bb004387527a1ec5dc9c8dd794a2562e` | 2,559 | Tests for XML 1.0 **Fifth Edition** (then proposed). New `EDITION` attribute. The 307 IBM P85–P89 not-wf tests (Appendix B character classes) and xmltest `not-wf-sa-140`/`141` became `EDITION="1 2 3 4"`; `eduni/errata-4e` (381) re-adds them as `EDITION="5"` valid/invalid cases (the 5th edition's broad Name ranges) plus new not-wf cases (surrogates, etc.). Also `eduni/errata-3e` (13) and Namespaces 1.0 errata (3). |
| 20080827 | `xmlts20080827.zip`, `.tar.gz`, `.tar` | tar.gz: `96151685cec997e1f9f3387e3626d61e6284d4d6e66e0e440c209286c03e9cc7` | 2,570 | "Tests for 5th edition changes other than the major character set change": BOMs in external general entities (`invalid-bo-1`…`9`) and `version="1.7"` (`x-rmt-008` for editions 1–4 vs `x-rmt-008b` valid in the 5th). The release libxml2 still uses. |
| **20130923** | `xmlts20130923.zip`, `.tar.gz`, `.tar` | tar.gz: `9b61db9f5dbffa545f4b8d78422167083a8568c59bd1129f94138f936cf6fc1f`; zip: `f9510b3532926e1b4c2e54855b021e4b8a66ec98a5337dcf4ff07e8a41968deb` | **2,585** | Minor release by Henry S. Thompson "in response to feedback" (public-xml-testsuite, September 2013): 15 new cases and 3 attribute fixes, listed below. **The latest release.** |

The 2013 `.zip` and `.tar.gz` extract to identical trees (verified). The zip hash above is the same
one pinned independently by lestrrat-go/helium-w3c-tests and vendored by xml-rs.

What 20130923 changed relative to 20080827 (diffing both trees):

- New cases: `valid-sa-017a` (xmltest's old `017.xml`, "two apparently wrong PIs make a right one"),
  while `valid-sa-017` itself was rewritten (`<?pi some data ?><?x?>`, output `<?pi some data ?><?x ?>`);
  `ht-ns10-047`/`048` (reserved-looking names are not an error); `ht-bh-ns11-007`/`008` (NS 1.1
  unbinding `xmlns`/`xml`); `x-rmt5-014a` (long s in a name, legal in the 5th edition); and the new
  `eduni/misc` collection `hst-bh-001`…`006`, `hst-lhs-007`…`009` (character references beyond
  U+10FFFF and beyond 32/64-bit integers, `xmlns:*` attributes and validation, BOM vs. encoding
  declaration conflicts).
- `encoding07` ENTITIES `parameter` → `general`; `rmt-ns11-003`/`004` TYPE `invalid` → `valid`
  (their files gained a DTD).
- A bug was introduced: the `eduni-misc` entry in both `xmlconf.xml` and `eduni/xmlconf.xml` sets
  `xml:base="eduni/namespaces/misc/"` (`"namespaces/misc/"`), but the files are in `eduni/misc/`. The 9
  `hst-*` cases therefore resolve to nonexistent paths. It was reported in December 2013
  (<https://lists.w3.org/Archives/Public/public-xml-testsuite/2013Dec/0000.html>) and never fixed.
  **The runner must map `eduni/namespaces/misc/` to `eduni/misc/`** (lddubeau/xml-conformance-suite
  does the same with sed; xml-rs reads `eduni/misc/ht-bh.xml` directly).

### 1.2 Is there anything newer? No.

- The home page lists 20130923 as the last release; probing for later names (for example
  `xmlts20150101.tar.gz`) returns 404. The linked report `xmlconf-20130923.html` is still the 2008
  report text.
- There is no W3C GitHub repository for it (`w3c/xmlconf`, `w3c/xml-test-suite`,
  `w3c/xml-conformance`, `w3c/xmlts` all 404; w3c has repositories for the XSD, XSLT and XQuery suites
  but not this one). The CVS the page points to (`dev.w3.org/cvsweb/2001/XML-Test-Suite/`) answers 403.
- The public-xml-testsuite mailing list's last messages are from February 2014; the XML Core Working
  Group is closed.
- No maintained, corrected fork exists. Everyone who runs the suite today uses 20130923 (or 20080827)
  as-is and keeps their own skip or expected-failure list (section 2).

**Use 20130923.** It is a strict superset of 20080827 with fixes, it is what current harnesses
(xml-rs, zig-xml, lddubeau, helium, moonbit xml-mbt and others) pin, and its only defect (the
`eduni/misc` base path) is a one-line mapping in the runner. The 2002 edition (still used by expat)
predates the Fifth Edition: 309 of its cases (P85–P89 and two xmltest name tests) have the wrong
expected result for a 5th-edition processor and it has no EDITION attribute to filter them.

---

## 2. How other implementations run it, and their skip lists

| Implementation | Edition | How cases are chosen | Skips / expected failures (and why) |
|---|---|---|---|
| **libxml2** (`runxmlconf.c`, GNOME/libxml2 master 2026-09-23) | 20080827 (CI downloads the tarball) | Catalog-driven. Runs RECOMMENDATION `XML1.0*`/`NS1.0*` with VERSION absent or `1.0`; EDITION without `5` runs with `XML_PARSE_OLD10`; ENTITIES ≠ `none` turns on DTD loading and entity substitution; valid/invalid run with DTD validation; namespace not-wf cases must produce a *namespace-domain* error. | Skips all `error` cases. Skip list: `rmt-ns10-035` only, from Daniel Veillard's 2008 report (<https://lists.w3.org/Archives/Public/public-xml-testsuite/2008Jul/0000.html>): the test ("repeated identical attribute" `a:attr="1" a:attr="2"`) is caught as a plain XML 1.0 duplicate-attribute error, not a namespace error, which libxml2's namespace-domain check rejects. Richard Tobin replied that the test is fine ("to pass the test all you have to do is reject the document"). It is a harness artifact, not a bad test. `NB_EXPECTED_ERRORS 5` tolerates five libxml2 failures. |
| **expat** (`expat/tests/xmltest.sh`, `xmltest.log.expected`) | 20020606 | Directory-driven, not catalog-driven: everything under `valid/`/`invalid/`/`*pass*` must parse, everything under `not-wf/`/`*fail*` must fail; compares `xmlwf -d` output with `out/` files. | 8 expected failures, all artifacts of ignoring the catalog: `oasis/p06fail1`, `p08fail1`, `p08fail2` are TYPE `invalid` (well-formed); `xmltest/not-wf/not-sa/005.xml` and `sun/not-wf/uri01.xml` are TYPE `error`; `ibm/not-wf/misc/432gewf.xml` is not in any catalog; `ibm/valid/P02/ibm02v01.xml` "output differs" (xmlwf's canonical form predates notation output); plus a missing-file message. |
| **xml-rs** (`tests/xmlconf.rs`, vendors `xmlts20130923.zip`) | 20130923 | Reads each leaf catalog (including `eduni/misc/ht-bh.xml`). Skips `EDITION="1 2 3 4"`. `valid`/`invalid` must parse; `not-wf` **and `error`** must fail. Ignores NAMESPACE and VERSION (runs the 1.1 catalogs too). | Per-catalog `*.fail.txt` expected-failure files (224 lines), regenerated with `PRINT_SPEC=1`; a known failure that starts passing is an error. They are xml-rs gaps (no external entities, DTD syntax checking), not claims about bad tests. |
| **zig-xml** (ianprime0509, `xmlconf/`) | 20130923 (pinned in `build.zig.zon`) | VERSION must include `1.0`, EDITION must include `5`, namespace awareness from NAMESPACE. | Skips all `error` cases ("no consistent standard by which we can evaluate these tests"); skips cases whose DOCTYPE or encoding it does not support. |
| **lddubeau/xml-conformance-suite** (JS; used by saxes) | 20130923, plus a flattened catalog with the `eduni/misc` path fix | Selections per driver; the base selection treats `invalid` and `error` as must-fail, drops `invalid` for non-validating drivers, and drops `not-wf`/`valid` with ENTITIES ≠ `none` for drivers that do not read external entities. | `BAD_TESTS`: `ibm-not-wf-P21-ibm21n02.xml` (tests CDEnd but uses lowercase `<![cdata[`; still not-wf, so harmless for a pass/fail runner), `rmt-e2e-15g`/`15h` (TYPE `invalid`, argued to be valid; irrelevant to a non-validating runner, which accepts them either way). One catalog fix: `not-wf-sa-077` SECTIONS `41. [68]` → `4.1 [68]`. |
| **helium** (lestrrat-go/helium-w3c-tests, Go) | 20130923 zip, pinned by SHA-256 | XML 1.0 + NS 1.0; 1.1 gated off. | xfail list: 6 NAMESPACE=`no` accept cases (`valid-sa-012` and the five `x-ibm-1-0.5-valid-P04/P05` ones) that it runs namespace-aware, and `hst-bh-005`/`006` (validity of undeclared `xmlns:*` attributes; validator-only). |
| quick-xml, roxmltree, xmlparser (Rust), Python lxml/pyexpat, Xerces-C/J, .NET System.Xml | — | None of them run this suite in their repositories (checked by grepping the quick-xml, roxmltree and xmlparser sources; lxml and CPython have their own tests; .NET's System.Private.Xml tests use their own TestFiles corpus). Historical Xerces/Crimson/etc. results against the 2000–2002 suite are in the xml.com and Piccolo conformance reports. | — |

### 2.1 Disputed or "bad" cases, judged for XmlBeef

Only cases that fall inside XmlBeef's selection (section 6) matter:

| Case | Catalog says | Dispute | Verdict for a non-validating 5th-edition NS processor |
|---|---|---|---|
| `rmt-e3e-13` | invalid | Tim Mills (2013Dec) argued it contradicts its own comment. The document references an undeclared general entity after an internal PE reference; per the 3rd-edition erratum E13 that makes "Entity Declared" a validity constraint. | **Accept** (catalog is right). libxml2 rejects it when loading DTDs; expat accepts. |
| `not-wf-sa-083` | not-wf | SJ Kissane (2014Feb): "Notation Declared" is a VC, so it should be invalid. | **Reject** (catalog is right, description misleading): `<doc>&e;</doc>` references an *unparsed* entity in content, which violates the WFC Parsed Entity. |
| `rmt-ns10-035` | not-wf | libxml2 skip (see above). | **Reject**: duplicate attribute is fatal under XML 1.0 anyway. |
| `hst-lhs-007`, `hst-lhs-008` | not-wf | None, but libxml2 and expat both accept them (UTF-8/UTF-16 BOM followed by an incompatible encoding declaration). | **Reject**: §4.3.3 makes an encoding declaration that contradicts the actual encoding fatal (see spec-reference §3). |
| `hst-bh-001`…`009` | various | Path bug (section 1.1). | Run with the path mapping. |
| `ibm-not-wf-P21-ibm21n02.xml` | not-wf | Wrong reason (lowercase `cdata`). | **Reject**; harmless. |
| 9 cases with `NAMESPACE="no"` (`valid-sa-012`, `o-p04pass1`, `o-p05pass1`, `o-p08pass1`, `x-ibm-1-0.5-valid-P04-ibm04v01.xml`, `x-ibm-1-0.5-valid-P05-ibm05v01/02/03/05.xml`) | valid/invalid | Names such as `:`, `A:._-0` or `a:b:c` are legal XML 1.0 Names but not QNames. | **Accept with namespace processing off**; with namespaces on they must be rejected (they are namespace-ill-formed). Run them in a no-namespaces mode, or skip them with that reason. |
| Pre-5th-edition name tests (307 IBM P85–P89 not-wf, `not-wf-sa-140`/`141`, `rmt-014`/`016`/`019`) | not-wf, `EDITION="1 2 3 4"` | Under the 5th edition these characters are legal in names. | Excluded by the EDITION filter; the errata-4e twins (`ibm-valid-P85…P89-*`, `invalid-sa-140`/`141`, `x-rmt5-*`) test the 5th-edition behavior. A 4th-edition parser such as expat fails 318 of those twins. |

Cross-check: a pyexpat-based oracle (namespace-aware, no external entities) disagrees with the
selection only on the 5th-edition name tests (expat implements 4th-edition name rules) and
`hst-lhs-007`; an lxml (libxml2 2.15.4, NAMESPACE=`no` cases excluded) oracle disagrees only on `ibm56i02`/`id02` (it reports duplicate
IDs even without validation), `rmt-e3e-13` and `hst-lhs-007`/`008`. No other case in the selection
looks wrong, so **the skip list can start empty**; entries should be deliberate non-support, each with
a reason.

---

## 3. How the suite is organized

### 3.1 Catalogs

`xmlconf/xmlconf.xml` is the master catalog (DTD `testcases.dtd`). It declares one external general
entity per collection catalog and wraps each reference in a `TESTCASES` element whose `xml:base` sets
the directory that the entries' `URI` and `OUTPUT` attributes are relative to:

```
TESTSUITE
  TESTCASES PROFILE="James Clark XML 1.0 Tests" xml:base="xmltest/"   &jclark-xmltest;  -> xmltest/xmltest.xml
  TESTCASES xml:base="japanese/"                                        &xerox-japanese;  -> japanese/japanese.xml
  TESTCASES xml:base="sun/"                    sun/sun-{valid,invalid,not-wf,error}.xml
  TESTCASES xml:base="oasis/"                  oasis/oasis.xml
  TESTCASES xml:base="ibm/"                    ibm/ibm_oasis_{invalid,not-wf,valid}.xml
  TESTCASES xml:base="ibm/xml-1.1/"            ibm/xml-1.1/ibm_{invalid,not-wf,valid}.xml
  TESTCASES xml:base="eduni/errata-2e/"        eduni/errata-2e/errata2e.xml
  TESTCASES xml:base="eduni/xml-1.1/"          eduni/xml-1.1/xml11.xml
  TESTCASES xml:base="eduni/namespaces/1.0/"   eduni/namespaces/1.0/rmt-ns10.xml
  TESTCASES xml:base="eduni/namespaces/1.1/"   eduni/namespaces/1.1/rmt-ns11.xml
  TESTCASES xml:base="eduni/errata-3e/"        eduni/errata-3e/errata3e.xml
  TESTCASES xml:base="eduni/errata-4e/"        eduni/errata-4e/errata4e.xml
  TESTCASES xml:base="eduni/namespaces/errata-1e/"  eduni/namespaces/errata-1e/errata1e.xml
  TESTCASES xml:base="eduni/namespaces/misc/"  eduni/misc/ht-bh.xml     <- wrong base (files are in eduni/misc/)
```

Some leaf catalogs are bare sequences of `TEST` elements with no root (the Sun ones), others have a
`TESTCASES` root; all are only meaningful as external entities of the master. `eduni/xmlconf.xml` and
`xmltest/xmlconf.xml` are alternative masters for those subtrees. A runner can either parse
`xmlconf.xml` with external general entities and `xml:base` (dogfooding XmlBeef's entity support), or
read each leaf file with the base directory known from the table above.

### 3.2 The TEST element

```
<!ATTLIST TEST
    ENTITIES        (both|none|parameter|general)   "none"
    ID              ID                              #REQUIRED
    OUTPUT          CDATA                           #IMPLIED
    OUTPUT3         CDATA                           #IMPLIED
    SECTIONS        CDATA                           #REQUIRED
    RECOMMENDATION  (XML1.0|XML1.1|NS1.0|NS1.1|XML1.0-errata2e|XML1.0-errata3e|XML1.0-errata4e|NS1.0-errata1e)  "XML1.0"
    TYPE            (valid|invalid|not-wf|error)    #REQUIRED
    VERSION         NMTOKENS                        #IMPLIED
    EDITION         NMTOKENS                        #IMPLIED
    URI             CDATA                           #REQUIRED
    NAMESPACE       (yes|no)                        "yes">
```

The element content is a human-readable description (with optional `EM`/`B` markup).

- **TYPE** (from `testcases.dtd`): all parsers must accept `valid`; non-validating parsers must also
  accept `invalid` (validating ones reject it); "no parser should accept a `not-wf` testcase unless
  it's a nonvalidating parser and the test contains external entities that the parser doesn't read";
  "parsers are not required to report `errors`" (the spec's *error*: a violation whose detection is
  optional).
- **ENTITIES**: which kinds of external entity the case uses (`general`, `parameter`, `both`,
  `none`, default `none`). A processor that does not read them may legitimately miss errors inside
  them, and its output will differ.
- **RECOMMENDATION**: which spec the case tests; the default is `XML1.0`. The `-errataNe` values mark
  cases for errata of the Nth edition.
- **VERSION**: XML versions the case applies to (`1.0`, `1.1`); absent means all. "Parsers should not
  run tests for versions they do not support."
- **EDITION**: XML 1.0 editions the case applies to (`5`, or `1 2 3 4`); absent means all.
- **NAMESPACE**: `no` marks cases that use colons in ways inconsistent with Namespaces; parsers
  "should enable namespace processing except for tests marked NAMESPACES=no".
- **SECTIONS**: spec sections and production numbers, for diagnostics only.
- **URI**: the test document, relative to the effective `xml:base`.
- **OUTPUT**: for accepted cases, a file holding the expected canonical output (section 4).
- **OUTPUT3**: Third Canonical Form output for validating parsers. **No case in 20130923 has it.**

### 3.3 Directory layout of the collections

- `xmltest/` (James Clark, 1998): `valid/{sa,ext-sa,not-sa}`, `invalid/`, `not-wf/{sa,ext-sa,not-sa}`;
  `sa` = standalone without external entities, `ext-sa` = uses external general entities (`*.ent`),
  `not-sa` = has an external subset. Each `valid/*/out/` holds canonical outputs.
- `sun/`: `valid/`, `invalid/`, `not-wf/`, with `out/` and `cxml.html` (the canonical forms spec).
- `oasis/`: flat `pNNpassM.xml` / `pNNfailM.xml` by production number. Note that some `fail` files
  are TYPE `invalid` or `error`, so never infer the expectation from the file name.
- `ibm/`: `valid/Pnn/`, `invalid/Pnn/`, `not-wf/Pnn/` (+ `not-wf/p28a`, `not-wf/misc`), with
  `out/` directories; `ibm/xml-1.1/` for XML 1.1. File names `ibmNN{v,i,n}MM.xml`. Some files on disk
  (for example `ibm/not-wf/misc/432gewf.xml`) are in no catalog.
- `japanese/`: the XML spec and a weekly report in UTF-8, UTF-16 (BE and LE), EUC-JP, ISO-2022-JP
  and Shift_JIS.
- `eduni/` (Richard Tobin and Henry Thompson, Edinburgh): `errata-2e`, `errata-3e`, `errata-4e`
  (the 5th-edition tests), `xml-1.1`, `namespaces/{1.0,1.1,errata-1e}`, `misc`.

---

## 4. The canonical output format (OUTPUT files)

The `out` files use James Clark's **Canonical XML** (<http://www.jclark.com/xml/canonxml.html>,
copied in `xmltest/canonxml.html`), extended by Sun's **Second Canonical Form** with notation
declarations (`sun/cxml.html`). This is unrelated to W3C Canonical XML (C14N). The format was
verified by writing a ~60-line canonicalizer over pyexpat events: it reproduces **all 379** OUTPUT
files of the recommended selection byte for byte (262 with no external entities, 117 with external
entities read). The rules:

1. **Encoding and framing**: UTF-8, no BOM, no XML declaration, no trailing newline. (XML 1.1 outputs,
   outside the selection, start with `<?xml version="1.1"?>` and escape C0/C1 controls.)
2. **Dropped**: the XML declaration, comments, the DOCTYPE and all markup declarations (except the
   notation block below), whitespace outside the root element, CDATA section delimiters (their content
   is ordinary text), and the distinction between literal text, entity references and character
   references (everything is reported expanded).
3. **Document**: the processing instructions before the DOCTYPE, then the notation block (if any), then
   the remaining prolog PIs, the root element, and the PIs after it, concatenated with nothing between
   them. Grammar: `CanonXML ::= Pi* element Pi*`. In practice the notation block is emitted at the
   position of the DOCTYPE: `ibm-valid-P29-ibm29v01.xml` expects
   `<?sound "This is a PI" ?><!DOCTYPE animal [ ... ]>\n<animal>` because its PI precedes the DOCTYPE.
4. **Notation block** (Second Canonical Form), only when at least one notation is declared (every
   declared notation, used or not, from the internal subset and from any external subset that was
   read):

   ```
   <!DOCTYPE root [\n
   <!NOTATION name PUBLIC 'pubid' 'sysid'>\n      (public and system identifier)
   <!NOTATION name PUBLIC 'pubid'>\n              (public identifier only)
   <!NOTATION name SYSTEM 'sysid'>\n              (system identifier only)
   ]>\n
   ```

   `root` is the DOCTYPE name, notations are sorted by name, literals are in single quotes, the public
   identifier is normalized (whitespace runs collapsed, trimmed) and the system identifier is output as
   written (all the suite's are simple relative names). 21 OUTPUT files in the selection have this
   block. Unparsed entity declarations belong to the Third Form only and never appear.
5. **Elements**: `<` qname attributes `>` content `</` qname `>`; empty elements are always written
   as a start-end pair (`<doc></doc>`), never `<doc/>`. Names are the qualified names as written
   (prefixes kept, no namespace resolution).
6. **Attributes**: every attribute the processor reports, which includes namespace declarations
   (`xmlns`, `xmlns:p`) and **defaulted attributes** from ATTLIST declarations the processor read,
   written as ` name="value"`, **sorted by name in Unicode code point order** (comparing UTF-8 bytes
   gives the same order). Values are after attribute-value normalization (§3.3.3): each literal
   whitespace character becomes a space, character references keep their character, and declared
   non-CDATA types are additionally trimmed and collapsed.
7. **Character escaping**, the same in text and attribute values: `&` → `&amp;`, `<` → `&lt;`,
   `>` → `&gt;`, `"` → `&quot;`, TAB → `&#9;`, LF → `&#10;`, CR → `&#13;`. Nothing else is escaped:
   `'` and all non-ASCII characters are written literally. Line-end normalization has already
   happened, so `&#13;` only appears for characters that came from `&#13;` references.
8. **Text**: all character data, including whitespace in element content ("ignorable" whitespace is
   significant in the first and second forms), adjacent runs concatenated.
9. **Processing instructions**: `<?` target ` ` data `?>` with exactly one space after the target even
   when the data is empty (`<?x?>` → `<?x ?>`); the data is as the parser reports it (leading
   whitespace after the target removed, trailing whitespace kept: `<?pi some data ?>` stays so).

---

## 5. Counts

### 5.1 All 2,585 cases of 20130923 by collection and TYPE

(`eduni/misc` counted at its real location.)

| collection | valid | invalid | not-wf | error | total | with OUTPUT |
|---|---:|---:|---:|---:|---:|---:|
| xmltest (James Clark) | 163 | 4 | 197 | 1 | 365 | 164 |
| japanese (Fuji Xerox) | 6 | 0 | 0 | 6 | 12 | 0 |
| sun | 28 | 74 | 56 | 1 | 159 | 27 |
| oasis (OASIS/NIST) | 46 | 54 | 247 | 1 | 348 | 0 |
| ibm (XML 1.0) | 149 | 40 | 730 | 9 | 928 | 188 |
| ibm/xml-1.1 | 53 | 2 | 153 | 0 | 208 | 9 |
| eduni/errata-2e | 17 | 11 | 3 | 3 | 34 | 2 |
| eduni/errata-3e | 3 | 9 | 1 | 0 | 13 | 0 |
| eduni/errata-4e | 310 | 18 | 61 | 4 | 393 | 6 |
| eduni/xml-1.1 | 25 | 11 | 16 | 5 | 57 | 36 |
| eduni/namespaces/1.0 | 7 | 17 | 21 | 3 | 48 | 0 |
| eduni/namespaces/1.1 | 5 | 0 | 3 | 0 | 8 | 0 |
| eduni/namespaces/errata-1e | 0 | 0 | 3 | 0 | 3 | 0 |
| eduni/misc | 0 | 2 | 7 | 0 | 9 | 0 |
| **total** | **812** | **242** | **1,498** | **33** | **2,585** | **432** |

Other distributions: RECOMMENDATION XML1.0 1,821, XML1.0-errata4e 393, XML1.1 265, NS1.0 48,
XML1.0-errata2e 34, XML1.0-errata3e 13, NS1.1 8, NS1.0-errata1e 3. EDITION absent 1,889, `5` 383,
`1 2 3 4` 313. ENTITIES none 2,262, parameter 181, general 75, both 67. NAMESPACE `no` 14.

### 5.2 The XmlBeef selection: XML 1.0 Fifth Edition + Namespaces 1.0

Removing XML 1.1 / NS 1.1 (274 cases) and pre-5th-edition-only cases (310 more) leaves **2,001**:

| collection | valid | invalid | not-wf | error | total | with OUTPUT |
|---|---:|---:|---:|---:|---:|---:|
| xmltest | 163 | 4 | 195 | 1 | 363 | 164 |
| japanese | 6 | 0 | 0 | 6 | 12 | 0 |
| sun | 28 | 74 | 56 | 1 | 159 | 27 |
| oasis | 46 | 54 | 247 | 1 | 348 | 0 |
| ibm | 149 | 40 | 423 | 9 | 621 | 188 |
| eduni/errata-2e | 16 | 11 | 3 | 3 | 33 | 2 |
| eduni/errata-3e | 3 | 9 | 1 | 0 | 13 | 0 |
| eduni/errata-4e | 310 | 18 | 61 | 3 | 392 | 6 |
| eduni/namespaces/1.0 | 7 | 17 | 21 | 3 | 48 | 0 |
| eduni/namespaces/errata-1e | 0 | 0 | 3 | 0 | 3 | 0 |
| eduni/misc | 0 | 2 | 7 | 0 | 9 | 0 |
| **total** | **728** | **229** | **1,017** | **27** | **2,001** | **387** |

ENTITIES within the selection: not-wf 951 none / 66 other; valid 601 none / 127 other; invalid 175
none / 54 other; error 9 none / 18 other. 9 selected cases are NAMESPACE=`no` (7 valid, 2 invalid,
all ENTITIES none; only `valid-sa-012` has an OUTPUT).

### 5.3 What the runner does with them

Columns: *accept* = valid + invalid (must parse); *reject A* = not-wf that must be rejected when
external entities are **not** read; *ext A* = not-wf that may be accepted in that mode; *canon A* =
OUTPUT comparisons possible without external entities; *reject B* / *canon B* = the same when external
entities are read.

| collection | accept | reject A | ext A | canon A | reject B | canon B | error |
|---|---:|---:|---:|---:|---:|---:|---:|
| xmltest | 167 | 181 | 14 | 118 | 195 | 164 | 1 |
| japanese | 6 | 0 | 0 | 0 | 0 | 0 | 6 |
| sun | 102 | 50 | 6 | 14 | 56 | 27 | 1 |
| oasis | 100 | 236 | 11 | 0 | 247 | 0 | 1 |
| ibm | 189 | 389 | 34 | 130 | 423 | 180 | 9 |
| eduni/errata-2e | 27 | 2 | 1 | 0 | 3 | 2 | 3 |
| eduni/errata-3e | 12 | 1 | 0 | 0 | 1 | 0 | 0 |
| eduni/errata-4e | 328 | 61 | 0 | 0 | 61 | 6 | 3 |
| eduni/namespaces/1.0 | 24 | 21 | 0 | 0 | 21 | 0 | 3 |
| eduni/namespaces/errata-1e | 0 | 3 | 0 | 0 | 3 | 0 | 0 |
| eduni/misc | 2 | 7 | 0 | 0 | 7 | 0 | 0 |
| **total** | **957** | **951** | **66** | **262** | **1,017** | **379** | **27** |

(8 `error` cases, `ibm68i01`–`04` and `ibm69i01`–`04`, also have OUTPUT files; they are not compared.)

**Recommended run without external entities (XmlBeef's default): 957 must-accept + 951 must-reject =
1,908 pass/fail cases, 262 canonical comparisons, 66 external-dependent not-wf cases where rejection
passes and acceptance is tolerated (expat and libxml2 reject 6 and 21 of them without reading
externals), 27 informational `error` cases.** With external entities read from local files: 957 +
1,017 = 1,974 pass/fail cases and 379 canonical comparisons.

Encodings: the must-accept cases only need UTF-8 (with or without BOM) and UTF-16 with a BOM (both
byte orders). ISO-8859-1, US-ASCII, EUC-JP, ISO-2022-JP and Shift_JIS appear only in XML 1.1 cases,
`error` cases (the six Japanese legacy-encoding documents, `rmt-ns10-006`) and not-wf cases (where
rejecting an unsupported encoding is itself correct, if for the wrong reason).

---

## 6. How XmlBeef's runner should classify cases

### 6.1 Selection (in this order, reporting each skip with its reason)

1. Resolve each case's file through the effective `xml:base`, mapping `eduni/namespaces/misc/` to
   `eduni/misc/`. A missing file is a runner error, never a silent skip.
2. Skip XML 1.1: RECOMMENDATION is `XML1.1` or `NS1.1`, or VERSION is present and does not contain
   `1.0` (274 cases). Keep `XML1.0-errata*` and `NS1.0*`.
3. Skip other editions: EDITION is present and does not contain `5` (310 cases).
4. NAMESPACE=`no`: parse with namespace processing off (9 cases). If XmlBeef has no such mode, skip
   them with the reason "requires namespace processing off"; do not expect them to fail.
5. Apply `tests/xmlconf/skip.txt` (IDs with reasons; initially expected to be empty or close to it,
   see section 2.1).

### 6.2 Expectations per TYPE for a non-validating processor

| TYPE | Pass means | Canonical comparison |
|---|---|---|
| `valid` | Parses without a fatal error (exit 0). | If OUTPUT is present and (ENTITIES is `none` or external entities were read): output equals the file byte for byte. |
| `invalid` | **Also parses without a fatal error.** Validity constraints are not checked; reporting one as fatal is a failure. | Same rule as `valid` (the IBM invalid cases have outputs). |
| `not-wf` | Rejected with a fatal error (exit 1). When ENTITIES ≠ `none` and external entities are not read, acceptance is recorded as "skipped: error may be in an unread external entity" instead of a failure; rejection still counts as a pass. | None. |
| `error` | Never a failure either way. Log accept/reject for information. Note that `invalid-bo-7`…`9` become genuine fatal errors (illegal character) when external general entities are read. | None. |

In every mode a crash (exit other than 0 or 1), a timeout, or a leak (in the leak-check script) is
a failure. The suite does not specify messages; XmlBeef's own are pinned by golden files in
`tests/errors/<ID>.err` (one per rejected not-wf case: kind, line, column and message), compared in
every mode, so memory and stream input must fail the same way. After an intended message change,
regenerate them with `UPDATE_GOLDEN=1 MODES=document ./test-xml-conformance.sh` and review the diff.

### 6.3 External entities

- **Default mode (no external entities)**: the SVG and data-file use case never wants network
  access, and an SVG 1.1 DOCTYPE (`"-//W3C//DTD SVG 1.1//EN"`) must not trigger a fetch. XmlBeef
  therefore does not read the external subset or external entities by default; per §5.1 it then
  stops processing later markup declarations after an unread parameter-entity reference unless
  `standalone="yes"`, and treats references to undeclared entities after that as not-fatal. This
  is the "A" column set above.
- **Resolver mode**: if XmlBeef offers a resolver for local files (relative to the document), run the
  whole selection a second time with it ("B" columns). The catalog itself (`xmlconf.xml` pulling in
  leaf catalogs by external general entity) is a natural first user of that resolver.

---

## 7. Other suites and corpora

### 7.1 Included in `fetch-suites.sh` (correctness corpora)

| Corpus | Source and pin | License | Size | Use |
|---|---|---|---|---|
| W3C SVG 1.1 Second Edition test suite | <https://www.w3.org/Graphics/SVG/Test/20110816/>, archive `archives/W3C_SVG_11_TestSuite.tar.gz` (SHA-256 `b5f46cca1ad79b670f9179770b2366c57efd5c671d084144090feab4b7ff1030`); keep `svg/*` (525 `.svg` + 1 `.svgz`), `images/*.svg` (57), `resources/*.svg` (21) | Files say "Copyright 2009 W3C … All Rights Reserved. See http://www.w3.org/Consortium/Legal/". W3C's current test-suite policy (dual 3-clause BSD / W3C Test Suite License) "does not affect existing test suites until they are modified", so the 2011 suite's terms are unclear: fetch, do not vendor. | 14.7 MB archive, ~6 MB kept | Well-formedness corpus of hand-written, namespace-heavy SVG (`xlink:`, SVG test-description namespaces with XHTML inside), 6 files with DOCTYPEs and 4 with internal-subset entities that expand to elements (`coords-viewattr-01-b.svg` etc.). All 603 `.svg` files are well-formed (checked with expat and libxml2). The `.svgz` is gzip: skip it. |
| resvg tests | <https://github.com/linebender/resvg> `crates/resvg/tests/tests/**` (1,722 SVGs by category: filters, masking, paint-servers, painting, shapes, structure, text) and `crates/usvg/tests/**` (62), commit `75b6bbadd7999d0516dcd7153b4a321bfdf8670a`. The older `linebender/resvg-test-suite` repository (MIT, last pushed 2024-10) is superseded by this directory. | Apache-2.0 OR MIT (repository license; the tests directory has no separate terms; the fonts beside them, not fetched, are OFL/Apache/MIT) | ~1.1 MB of SVG | Real-world-style SVG corpus: all must be well-formed. Edge cases: `structure/svg/not-UTF-8-encoding.svg` declares **Windows-1251**; `elements-via-ENTITY-reference-{1,2,3}.svg` and `attribute-value-via-ENTITY-reference.svg` use internal-subset entities under an SVG 1.1 PUBLIC DOCTYPE; `elements-via-ENTITY-reference-3.svg` puts an `xlink:` prefix inside entity replacement text that is only bound at the reference point (namespace-well-formed after expansion; libxml2 rejects it because it checks the entity content in isolation); `xmlns-validation.svg`, `mixed-namespaces.svg` and `rect-inside-a-non-SVG-element.svg` exercise default/prefixed namespace switching; several file names contain `=`. |

Both are also good round-trip inputs (parse → write → parse → compare) and quick smoke benchmarks.

### 7.2 Not fetched: other test suites worth knowing

| Suite | Where | License | Notes |
|---|---|---|---|
| Namespaces and XML 1.1 cases | already in xmlconf: `eduni/namespaces/*`, `eduni/xml-1.1`, `ibm/xml-1.1` | as xmlconf | The NS 1.1 and XML 1.1 cases (274) are the next step only if XML 1.1 is ever supported. |
| libxml2 `test/` + `result/` | <https://gitlab.gnome.org/GNOME/libxml2> | MIT | 1,473 files (9.5 MB) of inputs: attributes, entities (`ent*`), DTDs, namespaces (`ns*`), CDATA across buffer boundaries, huge names, encodings (EBCDIC, UTF-16), `test/errors/` (47 malformed documents). `result/` holds libxml2-specific serializations and SAX traces, not canonical XML, so reuse inputs only (well-formedness expectation = does libxml2 error). A good source of hand-picked fixtures. |
| expat `tests/` | <https://github.com/libexpat/libexpat> | MIT | ~14k lines of C unit tests with inline documents: namespaces (`ns_tests.c`), allocation failure, amplification/billion-laughs protection (`acc_tests.c`), buffer-boundary and encoding cases. Mine for fixtures by hand; not a runnable corpus. |
| Xerces-C / Xerces-J tests | <https://github.com/apache/xerces-c>, <https://github.com/apache/xerces2-j> | Apache-2.0 | Mostly API and schema tests; little beyond xmlconf for well-formedness. |
| html5lib-tests | <https://github.com/html5lib/html5lib-tests> | MIT | HTML parsing, not XML; relevant only if XHTML served as HTML ever matters. Not applicable. |
| feedparser tests | <https://github.com/kurtmckee/feedparser> `tests/` | BSD-2-Clause | 1,749 small RSS/Atom files plus `illformed/` (19) and encoding cases (82); feed-level "well-formed" is not always XML-well-formed (HTML entities without a DTD), so each file needs checking before use as a WF corpus. |
| Security fixtures | write them in-repo | ours | Billion laughs, quadratic blowup, deep nesting, huge names/attributes, XXE (`SYSTEM "file:///etc/passwd"`), external DTD over HTTP: expectations are XmlBeef's limits and must be hand-written. |

### 7.3 Real-world inputs and benchmark data (not downloaded)

The benchmark work chooses its own inputs; this table only records sources, licenses and suitability.
"WF corpus" = usable as a must-parse corpus; "bench" = large enough to time.

| Input | URL | License | Size | Suitability |
|---|---|---|---|---|
| Material Design Icons (Pictogrammers) | <https://github.com/Templarian/MaterialDesign-SVG> (`svg/`) | Pictogrammers Free License | ~7,000 single-path SVGs, repo ~5 MB | WF corpus (trivial structure) |
| Google Material Symbols | <https://github.com/google/material-design-icons> | Apache-2.0 | repo ~5 GB | too large to fetch whole; sparse `*.svg` only |
| Font Awesome Free | <https://github.com/FortAwesome/Font-Awesome> (`svgs/`) | icons CC BY 4.0, code MIT | ~2,000 SVGs, repo ~160 MB | WF corpus |
| Twemoji | <https://github.com/jdecked/twemoji> (`assets/svg`) | graphics CC BY 4.0, code MIT | ~3,700 SVGs, repo ~840 MB | WF corpus (sparse checkout) |
| Noto Emoji | <https://github.com/googlefonts/noto-emoji> (`svg/`) | Apache-2.0 (images), OFL-1.1 (fonts) | ~3,700 SVGs, repo ~1.5 GB | WF corpus with gradients and larger files |
| Inkscape-produced SVG | Inkscape `share/examples`, <https://gitlab.com/inkscape/inkscape> | GPL-2.0+ | small | `sodipodi:`/`inkscape:` namespaces, RDF metadata |
| Adobe Illustrator SVG | e.g. files discussed in <https://github.com/vault-development/react-native-svg-uri/issues/99> and <https://github.com/darylldoyle/svg-sanitizer/issues/30>; background in <https://oreillymedia.github.io/Using_SVG/extras/ch01-XML.html> | varies | small | Illustrator (10–CS6 "preserve editing") writes an SVG 1.1 PUBLIC DOCTYPE with an internal subset `<!ENTITY ns_extend "http://ns.adobe.com/Extensibility/1.0/">`, `ns_ai`, `ns_graphs`, `ns_vars`, `ns_imrep`, `ns_sfw`, `ns_svg`, `ns_xlink` and then `xmlns:x="&ns_extend;"`: namespace URIs come from entity references, so namespace binding must happen after attribute-value entity expansion. Write a license-clean fixture in this shape rather than fetching one. Illustrator 29.2.1 was reported to emit a duplicated `xmlns:xlink` attribute (<https://community.adobe.com/t5/illustrator-discussions/illustrator-v29-2-1-creating-invalid-svgs/td-p/15117893>), which is not well-formed and must be rejected. |
| Wikimedia Commons SVGs | <https://commons.wikimedia.org/> | per file (mostly CC BY-SA / PD) | any | Mixed generators, including Illustrator entity prologs |
| XMark auction data | <https://projects.cwi.nl/xmark/> (`xmlgen` source and binaries under Downloads) | research use, see the site's disclaimer | generated, scale factor 1 ≈ 100 MB | bench (classic, synthetic) |
| OpenStreetMap | <https://download.geofabrik.de/> (now PBF only; convert with osmium) or the API `https://api.openstreetmap.org/api/0.6/map?bbox=…` for small XML | ODbL 1.0 | KB to GB | bench (attribute-heavy, flat) |
| Wikipedia / Wiktionary dumps | <https://dumps.wikimedia.org/> (`simplewiki-latest-pages-articles.xml.bz2` is 356 MB compressed; small wikis are a few MB) | CC BY-SA 4.0 / GFDL | MB to GB | bench (text-heavy, large text nodes) |
| DBLP | <https://dblp.org/xml/dblp.xml.gz> (1.1 GB gz) + `dblp.dtd` | CC0 | ~4 GB uncompressed | bench; note it **needs its external DTD** for character entities such as `&uuml;` |
| UniProt Swiss-Prot | `https://ftp.uniprot.org/pub/databases/uniprot/current_release/knowledgebase/complete/uniprot_sprot.xml.gz` (942 MB gz) | CC BY 4.0 | ~6 GB | bench (namespaced, deep) |
| Mondial | <https://www.dbis.informatik.uni-goettingen.de/Mondial/mondial.xml> | free for research/teaching | 4.6 MB | small bench / WF input with internal DTD |
| UW XML Data Repository (TreeBank, SwissProt, etc.) | <https://aiweb.cs.washington.edu/research/projects/xmltk/xmldata/www/repository.html> | research use | e.g. `treebank_e.xml.gz` 32 MB, `SwissProt.xml.gz` 14 MB | bench (TreeBank is very deep) |
| Shakespeare plays (Jon Bosak) | <http://www.ibiblio.org/bosak/xml/eg/shaks200.zip>, single plays at <https://www.ibiblio.org/xml/examples/shakespeare/> | freely distributable (Bosak's notice) | 2.2 MB zip, 37 plays | classic small bench; each play references `play.dtd` |
| Religious texts incl. Bible (Jon Bosak) | <http://www.ibiblio.org/bosak/xml/eg/rel200.zip> | freely distributable | 2.0 MB zip | small bench |
| Office Open XML parts | any `.docx`/`.xlsx`/`.pptx` (ZIP); spec ECMA-376 | per document | KB to MB | real-world namespaced XML (`w:`, `r:`, `mc:Ignorable`), `standalone="yes"`; generate with LibreOffice |
| COLLADA `.dae` models | e.g. assimp test models <https://github.com/assimp/assimp> (`test/models/Collada`) | per model (assimp BSD-3 for code) | KB to MB | numeric-array-heavy text content |
| Android layouts / manifests | AOSP, <https://android.googlesource.com/> | Apache-2.0 | small | `android:` namespace, deeply attributed |
| Maven `pom.xml` | Maven Central / Apache projects | Apache-2.0 typical | small | config XML with default namespace |
| Visual Studio / MSBuild `.csproj` | e.g. <https://github.com/dotnet/runtime> | MIT | small | config XML (SDK style has no namespace; old style has one) |
| RSS / Atom feeds | any site; feedparser corpus above | per feed | small | CDATA, HTML entities (often not WF), encodings |
| GPX | <https://www.topografix.com/fells_loop.gpx> (sample, 30 KB), OSM GPS traces | per file | small to MB | namespaced, numeric attributes |

---

## 8. Licensing: why everything is fetched, not vendored

XmlBeef is MIT. The xmlconf archive mixes copyrights with incompatible or unclear terms:

- James Clark's xmltest: "Permission is granted to redistribute the file xmltest.zip … provided that
  no modifications of any kind are made to this file. Note that permission to distribute the
  collection in any other form is not granted" (`xmltest/readme.html`).
- Sun: "Copyright 1998 by Sun Microsystems, Inc. All Rights Reserved." on catalogs and some files;
  others say "May be freely redistributed provided copyright notice is retained".
- IBM: "(C) Copyright IBM Corp. 2000 All rights reserved."
- OASIS/NIST, Fuji Xerox (Japanese notices), Richard Tobin/Edinburgh ("Copyright Richard Tobin,
  HCRC February 2003").
- W3C: contributions are licensed to W3C under the W3C Software License (per the suite FAQ); the
  current dual BSD/W3C Test Suite License policy does not apply retroactively.

The SVG 1.1 suite carries "All Rights Reserved" W3C notices (see 7.1). resvg's tests are permissive
(Apache-2.0 OR MIT) and could be vendored, but they are fetched for the same pin-and-update workflow
and to keep the repository small. All three are fetched into the git-ignored `tests/suites/` at pinned
versions; nothing derived from them (such as a flattened manifest) is committed.

---

## 9. Planned test scripts and expectation files

Modeled on KdlBeef's `test-kdl-spec.sh` and TomlBeef's `test-official-toml.sh`.

### 9.1 XmlTester interface the scripts need

- `XmlTester [-no-ns] [-ext] -canonical FILE`: parse FILE, print the canonical form (section 4) to
  stdout, exit 0; on a well-formedness error print `line:column: message` to stderr and exit 1.
  `-no-ns` turns namespace processing off (NAMESPACE=`no` cases); `-ext` enables the local-file
  resolver for external entities (mode B). Anything else (crash, assertion) is exit > 1.
- The same reading modes as KdlBeef so every path is covered: whole document (default), reader events
  (`-events`), a Stream with a tiny buffer (`-stream 16`, so refills land inside names, references,
  CRLF pairs and multibyte characters).
- `XmlTester -catalog tests/suites/xmlconf/xmlconf.xml`: print one tab-separated line per TEST (ID,
  TYPE, ENTITIES, NAMESPACE, RECOMMENDATION, VERSION, EDITION, resolved URI, resolved OUTPUT) by
  parsing the catalog with XmlBeef itself (external general entities + `xml:base`). Until the
  resolver exists, a small `python3` helper can produce the same TSV.

### 9.2 `test-xml-conformance.sh`

1. Check that `$BIN` exists (default `./build/Debug_Linux64/XmlTester/XmlTester`, override with
   `BIN=./build/Release_Linux64/XmlTester/XmlTester`) and that `tests/suites/xmlconf/xmlconf.xml`
   exists (else: "run tests/fetch-suites.sh").
2. Produce the manifest (9.1), apply the `eduni/misc` path mapping, and apply the selection rules and
   `tests/xmlconf/skip.txt` (6.1), counting skips per reason.
3. For each case and mode (`MODES="document events stream"`, and `EXT=1` for mode B), run
   `timeout 10 $BIN [flags] -canonical FILE`, then judge by the table in 6.2: exit status against TYPE
   (with the ext-tolerance rule for not-wf), and `cmp` of stdout against OUTPUT when applicable.
4. Compare the failures with `tests/xmlconf/expected-failures.txt`: an unlisted failure fails the
   run, and a listed case that now passes also fails the run ("remove it from the list"), as xml-rs
   does. `UPDATE_EXPECTED=1` rewrites the file from the current failures for review.
5. Log details to `test-xml-conformance.log` (git-ignored by `test-*.log`) and print a summary per
   mode: accepted x/957, rejected x/951, canonical x/262, ext-tolerated, error-case outcomes, skips by
   reason, crashes.

### 9.3 `test-svg-corpus.sh` (or a `-corpus` mode of the same script)

Every `*.svg` under `tests/suites/svg11` and `tests/suites/resvg` must parse with namespaces on and no
external entities (none of them needs the external SVG DTD). Skip `*.svgz`. Then round-trip: canonical
output of the file, parsed again, must give the same canonical output. `tests/corpus/expected-failures.txt`
lists deliberate exceptions, for example `not-UTF-8-encoding.svg` if Windows-1251 is not supported.

### 9.4 Files the repository should carry

- `tests/xmlconf/skip.txt`: `ID<TAB>reason` for deliberately unsupported cases (for example the 9
  NAMESPACE=`no` cases if there is no no-namespace mode). Expected to stay short; section 2.1 found no
  case that is wrong for this processor profile.
- `tests/xmlconf/expected-failures.txt`: `ID<TAB>reason` for known XmlBeef gaps, kept honest by the
  "unexpected pass" rule; ideally empty at release.
- `tests/corpus/expected-failures.txt`: the same for the SVG corpora.
- Hand-written fixtures under `tests/` for what no suite covers well: the Illustrator entity prolog,
  security limits (7.2), namespace edge cases, encodings (Windows-1252/1251, ISO-8859-1), and buffer
  boundary cases. These are our own work and are committed.

### 9.5 Decisions the plan must make

- Whether XmlBeef ever reads external entities (a local-file resolver, opt-in) or never does. This
  decides whether mode B (1,017 rejects, 379 canonical comparisons) is run at all, and how the catalog
  is read (`-catalog` via XmlBeef, or a Python helper).
- Whether there is a namespace-off mode (9 cases run or skip).
- Which encodings beyond UTF-8/UTF-16 to support (none are needed by the must-accept cases; resvg has a
  Windows-1251 file; ISO-8859-1 and Windows-1252 are common in the wild).
- Whether DTD attribute defaults and non-CDATA normalization from the internal subset are applied
  (the canonical outputs require it: defaulted attributes appear in them) and whether notation
  declarations are exposed (21 canonical outputs need them).
- Whether `error` cases are only logged (recommended) or held to a chosen behavior.
