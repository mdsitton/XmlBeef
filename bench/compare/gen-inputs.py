#!/usr/bin/env python3
"""Writes the comparison benchmark inputs into inputs/ (git-ignored). Deterministic (fixed seed).
Run ./fetch.sh first: the real-world SVG corpora come from deps/corpora (pinned, sha256-checked).

XmlBeef's main use is reading data formats from disk, SVG above all, so three of the eight inputs are
SVG. Every input is UTF-8 with LF line endings, except book-utf16.

  input           kind       what                                                         size
  svg-icons       real, dir  17,387 small icon files: Material Design Icons 7.4.47 (Apache-2.0), ~15 MB
                             Tabler Icons 3.48.0 outline + filled (MIT), Twemoji 15.0.0 (CC-BY
                             4.0), exactly as published to npm. One sample parses every file,
                             so per-document overhead counts (MB/s over their total size).
  svg-artwork     real, dir  Inkscape's 13 About-screen artworks (contest entries, CC BY-SA 4.0), ~15 MB
                             decompressed from .svgz: Inkscape/sodipodi/RDF namespaces, long
                             path data, gradients, filters, embedded text.
  svg-generated   generated  an Adobe Illustrator-style export: internal DTD subset whose       ~12 MB
                             entities give the namespace URIs (xmlns="&ns_svg;") and styles
                             (style="&st3;"), i:/x:/graph: namespaces, a CDATA <style>, long
                             path data, groups with transforms, <use xlink:href>, gradients,
                             text, and a base64 <i:pgf> blob.
  records         generated  data-oriented, XMark-like auction data: many small elements and   ~14 MB
                             attributes, indentation whitespace, entity and char references,
                             non-ASCII names.
  book            generated  text-heavy XHTML: long paragraphs of mixed content (em, a, code,   ~10 MB
                             span), predefined entities, decimal and hex character references,
                             literal non-ASCII (including astral characters), comments, CDATA.
  osm             generated  attribute-heavy, OpenStreetMap XML shape: node/way/relation with   ~15 MB
                             6-8 attributes each, tag k/v pairs, both quote styles, escapes.
  atom            generated  namespace-heavy: an Atom feed with a dozen prefixes (dc, media,    ~10 MB
                             georss, thr, app, gd, ...), XHTML content switching the default
                             namespace, prefixes re-declared on entries, prefixed attributes.
  book-utf16      generated  a smaller book, encoded UTF-16LE with a BOM and                    ~10 MB
                             encoding="UTF-16"; libraries that only read UTF-8 report n/a.

Checksum ("check: E A V T", printed by every harness and compared by run.sh): E elements; A
attributes, not counting namespace declarations (xmlns, xmlns:*); V the total length of attribute
values; T the total length of character data inside the root element (text and CDATA, whitespace-only
text included); lengths in Unicode code points after entity and character reference expansion. No
input declares attribute defaults, so no parser adds attributes.
"""
import base64
import gzip
import os
import random
import shutil
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "inputs")
CORPORA = os.path.join(HERE, "deps", "corpora")

WORDS = ("the of and to in is was that for it with as his on be at by had not are but from or have an "
         "they which one you were all her she there would their we him been has when who will more no "
         "if out so said what up its about into than them can only other new some could time these two "
         "may then do first any my now such like our over man me even most made after also did many "
         "before must through back years where much your way well down should because each just those "
         "people how too little state good very make world still own see men work long get here between "
         "both life being under never day same another know while last might us great old year off come "
         "since against go came right used take three").split()
ACCENTED = ("café naïve résumé Zürich Straße façade jalapeño São Paulo Kraków Ærøskøbing smörgåsbord "
            "Ελλάδα Россия 東京 北京 서울 مرحبا שלום").split()
ASTRAL = ["😀", "🎉", "𝔘𝔫𝔦𝔠𝔬𝔡𝔢", "🦀", "𐍈"]


def write(name, text, encoding="utf-8"):
    data = text.encode(encoding)
    with open(os.path.join(OUT, name + ".xml"), "wb") as f:
        f.write(data)
    print(f"{name:14} {len(data):>10} bytes")


def sentence(rng, n=None, extra=()):
    words = [rng.choice(WORDS) for _ in range(n or rng.randrange(6, 18))]
    for e in extra:
        words.insert(rng.randrange(len(words) + 1), e)
    return " ".join(words)


# ---- real-world SVG corpora ----

def svg_icons():
    """The icon sets as individual files in inputs/svg-icons/<set>/..."""
    target = os.path.join(OUT, "svg-icons")
    shutil.rmtree(target, ignore_errors=True)
    sets = (("mdi-svg-7.4.47.tgz", "package/svg/", "mdi"),
            ("tabler-icons-3.48.0.tgz", "package/icons/", "tabler"),
            ("twemoji-svg-15.0.0.tgz", "package/", "twemoji"))
    count = size = 0
    for tgz, prefix, name in sets:
        path = os.path.join(CORPORA, tgz)
        if not os.path.exists(path):
            raise SystemExit(f"{path} missing: run ./fetch.sh first")
        with tarfile.open(path) as tar:
            for member in tar.getmembers():
                if not (member.isfile() and member.name.startswith(prefix) and member.name.endswith(".svg")):
                    continue
                rel = member.name[len(prefix):]
                # Tabler: only icons/outline and icons/filled (the categories/ tree repeats them)
                out = os.path.join(target, name, rel)
                os.makedirs(os.path.dirname(out), exist_ok=True)
                data = tar.extractfile(member).read()
                with open(out, "wb") as f:
                    f.write(data)
                count += 1
                size += len(data)
    print(f"{'svg-icons':14} {size:>10} bytes in {count} files")


def svg_artwork():
    """Inkscape's About screens, decompressed, in inputs/svg-artwork/"""
    target = os.path.join(OUT, "svg-artwork")
    shutil.rmtree(target, ignore_errors=True)
    os.makedirs(target)
    names = sorted(n for n in os.listdir(CORPORA) if n.startswith("inkscape-about"))
    if len(names) != 13:
        raise SystemExit("deps/corpora/inkscape-about*.svgz missing: run ./fetch.sh first")
    size = 0
    for name in names:
        with gzip.open(os.path.join(CORPORA, name)) as f:
            data = f.read()
        with open(os.path.join(target, name[len("inkscape-"):-1]), "wb") as f:  # .svgz -> .svg
            f.write(data)
        size += len(data)
    print(f"{'svg-artwork':14} {size:>10} bytes in {len(names)} files")


# ---- generated inputs ----

def path_data(rng, points):
    x, y = rng.uniform(0, 1000), rng.uniform(0, 1000)
    out = [f"M{x:.3f},{y:.3f}"]
    for _ in range(points):
        kind = rng.random()
        if kind < 0.5:
            out.append(f"c{rng.uniform(-9, 9):.3f},{rng.uniform(-9, 9):.3f} {rng.uniform(-9, 9):.3f},"
                       f"{rng.uniform(-9, 9):.3f} {rng.uniform(-9, 9):.3f},{rng.uniform(-9, 9):.3f}")
        elif kind < 0.75:
            out.append(f"l{rng.uniform(-20, 20):.3f},{rng.uniform(-20, 20):.3f}")
        elif kind < 0.85:
            out.append(f"h{rng.uniform(-20, 20):.2f}")
        elif kind < 0.95:
            out.append(f"v{rng.uniform(-20, 20):.2f}")
        else:
            out.append(f"s{rng.uniform(-9, 9):.3f},{rng.uniform(-9, 9):.3f} {rng.uniform(-9, 9):.3f},{rng.uniform(-9, 9):.3f}")
    return "".join(out) + "z"


def svg_generated(rng):
    """Adobe Illustrator-style SVG export. ~12 MB."""
    styles = 40
    out = ['<?xml version="1.0" encoding="utf-8"?>\n'
           "<!-- Generator: Adobe Illustrator 28.0.0, SVG Export Plug-In . SVG Version: 6.00 Build 0)  -->\n"
           '<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd" [\n'
           '\t<!ENTITY ns_extend "http://ns.adobe.com/Extensibility/1.0/">\n'
           '\t<!ENTITY ns_ai "http://ns.adobe.com/AdobeIllustrator/10.0/">\n'
           '\t<!ENTITY ns_graphs "http://ns.adobe.com/Graphs/1.0/">\n'
           '\t<!ENTITY ns_vars "http://ns.adobe.com/Variables/1.0/">\n'
           '\t<!ENTITY ns_imrep "http://ns.adobe.com/ImageReplacement/1.0/">\n'
           '\t<!ENTITY ns_sfw "http://ns.adobe.com/SaveForWeb/1.0/">\n'
           '\t<!ENTITY ns_custom "http://ns.adobe.com/GenericCustomNamespace/1.0/">\n'
           '\t<!ENTITY ns_adobe_xpath "http://ns.adobe.com/XPath/1.0/">\n'
           '\t<!ENTITY ns_svg "http://www.w3.org/2000/svg">\n'
           '\t<!ENTITY ns_xlink "http://www.w3.org/1999/xlink">\n']
    for i in range(styles):
        out.append(f'\t<!ENTITY st{i} "fill:#{rng.randrange(0x1000000):06X};stroke:#{rng.randrange(0x1000000):06X};'
                   f'stroke-width:{rng.uniform(0.1, 4):.2f};stroke-miterlimit:10;">\n')
    out.append("]>\n")
    out.append('<svg version="1.1" id="Layer_1" xmlns:x="&ns_extend;" xmlns:i="&ns_ai;" xmlns:graph="&ns_graphs;"\n'
               '\t xmlns="&ns_svg;" xmlns:xlink="&ns_xlink;" x="0px" y="0px" width="2000px" height="2000px"\n'
               '\t viewBox="0 0 2000 2000" style="enable-background:new 0 0 2000 2000;" xml:space="preserve">\n')
    out.append('<switch>\n\t<foreignObject requiredExtensions="&ns_ai;" x="0" y="0" width="1" height="1">\n'
               '\t\t<i:pgfRef  xlink:href="#adobe_illustrator_pgf">\n\t\t</i:pgfRef>\n\t</foreignObject>\n'
               '\t<g i:extraneous="self">\n')
    out.append('<style type="text/css">\n\t<![CDATA[\n')
    for i in range(styles):
        out.append(f"\t.cls{i}{{fill:#{rng.randrange(0x1000000):06X};stroke:#{rng.randrange(0x1000000):06X};"
                   f"stroke-width:{rng.uniform(0.1, 4):.2f};}}\n")
    out.append("\t.lbl>tspan{font-family:'MyriadPro-Regular';font-size:12px;}\n\t]]>\n</style>\n")
    out.append("<defs>\n")
    for i in range(60):
        out.append(f'\t<linearGradient id="SVGID_{i}_" gradientUnits="userSpaceOnUse" x1="{rng.uniform(0, 2000):.4f}" '
                   f'y1="{rng.uniform(0, 2000):.4f}" x2="{rng.uniform(0, 2000):.4f}" y2="{rng.uniform(0, 2000):.4f}" '
                   f'gradientTransform="matrix(1 0 0 -1 0 {rng.uniform(0, 2000):.4f})">\n')
        for s in range(rng.randrange(2, 6)):
            out.append(f'\t\t<stop  offset="{s / 5:.2f}" style="stop-color:#{rng.randrange(0x1000000):06X}"/>\n')
        out.append("\t</linearGradient>\n")
    for i in range(80):
        out.append(f'\t<symbol  id="sym_{i}" viewBox="-{rng.randrange(5, 50)} -{rng.randrange(5, 50)} 100 100">\n'
                   f'\t\t<path style="&st{rng.randrange(styles)};" d="{path_data(rng, rng.randrange(4, 40))}"/>\n'
                   "\t</symbol>\n")
    out.append("</defs>\n")
    layer = 0
    while sum(map(len, out)) < 11_000_000:
        out.append(f'<g id="Layer_{layer + 2}" i:layer="yes" i:dimmedPercent="50" i:rgbTrio="#4F008000FFFF">\n')
        for _ in range(rng.randrange(20, 60)):
            out.append(f'\t<g transform="translate({rng.uniform(0, 2000):.3f} {rng.uniform(0, 2000):.3f}) '
                       f'rotate({rng.uniform(-180, 180):.2f}) scale({rng.uniform(0.2, 3):.3f})">\n')
            for _ in range(rng.randrange(3, 12)):
                kind = rng.random()
                if kind < 0.45:
                    out.append(f'\t\t<path class="cls{rng.randrange(styles)}" d="{path_data(rng, rng.randrange(5, 120))}"/>\n')
                elif kind < 0.6:
                    out.append(f'\t\t<path style="&st{rng.randrange(styles)};" d="{path_data(rng, rng.randrange(5, 60))}"/>\n')
                elif kind < 0.7:
                    pts = " ".join(f"{rng.uniform(0, 500):.3f},{rng.uniform(0, 500):.3f}" for _ in range(rng.randrange(3, 30)))
                    out.append(f'\t\t<polygon style="fill:url(#SVGID_{rng.randrange(60)}_);" points="{pts}"/>\n')
                elif kind < 0.8:
                    out.append(f'\t\t<use xlink:href="#sym_{rng.randrange(80)}"  width="100" height="100" '
                               f'x="-{rng.randrange(5, 50)}" y="-{rng.randrange(5, 50)}" '
                               f'transform="matrix({rng.uniform(-1, 1):.4f} 0 0 {rng.uniform(-1, 1):.4f} '
                               f'{rng.uniform(0, 500):.4f} {rng.uniform(0, 500):.4f})" style="overflow:visible;"/>\n')
                elif kind < 0.9:
                    out.append(f'\t\t<text transform="matrix(1 0 0 1 {rng.uniform(0, 500):.4f} {rng.uniform(0, 500):.4f})" '
                               f'class="lbl"><tspan x="0" y="0" class="cls{rng.randrange(styles)}">'
                               f"{sentence(rng, 4).title()} &amp; {rng.choice(ACCENTED)}</tspan>"
                               f'<tspan x="0" y="14.4">{rng.randrange(1000)}&#x2009;km &#8211; &#169; 2024</tspan></text>\n')
                else:
                    out.append(f'\t\t<rect x="{rng.uniform(0, 500):.3f}" y="{rng.uniform(0, 500):.3f}" '
                               f'style="&st{rng.randrange(styles)};" width="{rng.uniform(1, 200):.3f}" '
                               f'height="{rng.uniform(1, 200):.3f}"/>\n'
                               f'\t\t<circle cx="{rng.uniform(0, 500):.3f}" cy="{rng.uniform(0, 500):.3f}" '
                               f'r="{rng.uniform(1, 50):.3f}" fill="#{rng.randrange(0x1000000):06X}"/>\n')
            out.append("\t</g>\n")
        out.append("</g>\n")
        layer += 1
    out.append("\t</g>\n</switch>\n")
    blob = base64.encodebytes(rng.randbytes(700_000)).decode()
    out.append('<i:pgf  id="adobe_illustrator_pgf">\n\t<![CDATA[\n\t' + blob.replace("\n", "\n\t") + "\t]]>\n</i:pgf>\n")
    out.append("</svg>\n")
    return "".join(out)


FIRST = "Anna Björn Chen Dmitri Élodie Fatima Giovanni Hiroshi Ingrid José Kwame Łukasz María Nguyễn Olga".split()
LAST = "Smith Müller Rossi García Tanaka O'Brien Nowak Dubois Kowalski Johansson Petrov Silva Kim".split()
COUNTRIES = "United States|Germany|Japan|Brazil|France|Côte d'Ivoire|Österreich|中国|India|Canada".split("|")


def records(rng):
    """XMark-like auction site: items, people, open and closed auctions. ~15 MB."""
    out = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<site>\n  <regions>\n']

    def text(indent):
        parts = []
        for _ in range(rng.randrange(1, 4)):
            r = rng.random()
            if r < 0.3:
                parts.append(f"<keyword>{sentence(rng, 2)}</keyword>")
            elif r < 0.5:
                parts.append(f"<emph>{sentence(rng, 3)}</emph>")
            parts.append(" " + sentence(rng) + rng.choice((" ", " &amp; ", " &lt;5% ", " &#8364;12 ", " ")))
        return f"{indent}<text>{''.join(parts).strip()}</text>\n"

    items, people, open_auctions = 6000, 5000, 4000
    per_region = items // 6
    for r, region in enumerate(("africa", "asia", "australia", "europe", "namerica", "samerica")):
        out.append(f"    <{region}>\n")
        for i in range(r * per_region, (r + 1) * per_region):
            out.append(f'      <item id="item{i}"{" featured=\"yes\"" if i % 11 == 0 else ""}>\n'
                       f"        <location>{rng.choice(COUNTRIES)}</location>\n"
                       f"        <quantity>{rng.randrange(1, 5)}</quantity>\n"
                       f"        <name>{sentence(rng, 3)}</name>\n"
                       f"        <payment>{rng.choice(('Creditcard', 'Money order', 'Personal Check', 'Cash'))}</payment>\n"
                       "        <description>\n" + text("          ") + "        </description>\n"
                       f"        <shipping>{rng.choice(('Will ship internationally', 'Buyer pays fixed shipping charges', 'See description for charges'))}</shipping>\n")
            for _ in range(rng.randrange(1, 4)):
                out.append(f'        <incategory category="category{rng.randrange(1000)}"/>\n')
            out.append("        <mailbox>\n")
            for _ in range(rng.randrange(0, 3)):
                out.append(f"          <mail>\n            <from>{rng.choice(FIRST)} {rng.choice(LAST)} mailto:{rng.choice(LAST).lower()}@example.com</from>\n"
                           f"            <to>{rng.choice(FIRST)} {rng.choice(LAST)}</to>\n"
                           f"            <date>{rng.randrange(1, 13):02d}/{rng.randrange(1, 29):02d}/{rng.randrange(1998, 2002)}</date>\n"
                           + text("            ") + "          </mail>\n")
            out.append("        </mailbox>\n      </item>\n")
        out.append(f"    </{region}>\n")
    out.append("  </regions>\n  <people>\n")
    for p in range(people):
        first, last = rng.choice(FIRST), rng.choice(LAST)
        out.append(f'    <person id="person{p}">\n      <name>{first} {last}</name>\n'
                   f"      <emailaddress>mailto:{last.lower().replace(chr(39), '')}@example.org</emailaddress>\n"
                   f"      <phone>+{rng.randrange(1, 99)} ({rng.randrange(100, 999)}) {rng.randrange(1000000, 9999999)}</phone>\n"
                   f"      <address>\n        <street>{rng.randrange(1, 99)} {rng.choice(LAST)} St</street>\n"
                   f"        <city>{rng.choice(ACCENTED)}</city>\n        <country>{rng.choice(COUNTRIES)}</country>\n"
                   f"        <zipcode>{rng.randrange(10000, 99999)}</zipcode>\n      </address>\n"
                   f'      <profile income="{rng.uniform(9000, 200000):.2f}">\n')
        for _ in range(rng.randrange(0, 4)):
            out.append(f'        <interest category="category{rng.randrange(1000)}"/>\n')
        out.append(f"        <education>{rng.choice(('High School', 'College', 'Graduate School', 'Other'))}</education>\n"
                   f"        <gender>{rng.choice(('male', 'female'))}</gender>\n        <business>{rng.choice(('Yes', 'No'))}</business>\n"
                   f"        <age>{rng.randrange(18, 90)}</age>\n      </profile>\n      <watches>\n")
        for _ in range(rng.randrange(0, 4)):
            out.append(f'        <watch open_auction="open_auction{rng.randrange(open_auctions)}"/>\n')
        out.append("      </watches>\n    </person>\n")
    out.append("  </people>\n  <open_auctions>\n")
    for a in range(open_auctions):
        out.append(f'    <open_auction id="open_auction{a}">\n      <initial>{rng.uniform(1, 300):.2f}</initial>\n')
        for _ in range(rng.randrange(0, 5)):
            out.append(f"      <bidder>\n        <date>{rng.randrange(1, 13):02d}/{rng.randrange(1, 29):02d}/2001</date>\n"
                       f"        <time>{rng.randrange(24):02d}:{rng.randrange(60):02d}:{rng.randrange(60):02d}</time>\n"
                       f'        <personref person="person{rng.randrange(people)}"/>\n'
                       f"        <increase>{rng.uniform(1, 50):.2f}</increase>\n      </bidder>\n")
        out.append(f"      <current>{rng.uniform(1, 900):.2f}</current>\n"
                   f'      <itemref item="item{rng.randrange(items)}"/>\n      <seller person="person{rng.randrange(people)}"/>\n'
                   "      <annotation>\n" + f'        <author person="person{rng.randrange(people)}"/>\n'
                   "        <description>\n" + text("          ") + "        </description>\n"
                   f"        <happiness>{rng.randrange(1, 11)}</happiness>\n      </annotation>\n"
                   f"      <quantity>1</quantity>\n      <type>{rng.choice(('Regular', 'Featured', 'Dutch'))}</type>\n"
                   "      <interval>\n        <start>01/01/2000</start>\n        <end>12/31/2001</end>\n      </interval>\n"
                   "    </open_auction>\n")
    out.append("  </open_auctions>\n  <closed_auctions>\n")
    for a in range(3000):
        out.append(f'    <closed_auction>\n      <seller person="person{rng.randrange(people)}"/>\n'
                   f'      <buyer person="person{rng.randrange(people)}"/>\n      <itemref item="item{rng.randrange(items)}"/>\n'
                   f"      <price>{rng.uniform(1, 900):.2f}</price>\n      <date>{rng.randrange(1, 13):02d}/{rng.randrange(1, 29):02d}/2000</date>\n"
                   f"      <quantity>1</quantity>\n      <type>Regular</type>\n    </closed_auction>\n")
    out.append("  </closed_auctions>\n</site>\n")
    return "".join(out)


def book(rng, chapters, declaration='<?xml version="1.0" encoding="UTF-8"?>\n'):
    """Text-heavy XHTML: chapters of long mixed-content paragraphs."""
    out = [declaration,
           '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">\n<head>\n'
           "  <title>A Generated Book</title>\n  <meta charset=\"utf-8\"/>\n"
           '  <link rel="stylesheet" type="text/css" href="book.css"/>\n</head>\n<body>\n']
    note = 0

    def paragraph():
        nonlocal note
        parts = []
        for _ in range(rng.randrange(3, 9)):
            s = sentence(rng, extra=[rng.choice(ACCENTED)] if rng.random() < 0.3 else ())
            r = rng.random()
            if r < 0.15:
                s = s.replace(" ", " <em>", 1) + "</em>"
            elif r < 0.25:
                note += 1
                s += f'<a href="#note{note}" class="noteref" id="ref{note}">[{note}]</a>'
            elif r < 0.32:
                s += ' <code>if (a &lt; b &amp;&amp; c &gt; d) return;</code>'
            elif r < 0.4:
                s = f"&#8220;{s}&#8221;"
            elif r < 0.45:
                s += f' <span lang="fr" xml:lang="fr">caf&#233; cr&#xE8;me</span>'
            elif r < 0.5:
                s += " " + rng.choice(ASTRAL)
            elif r < 0.55:
                s += " &#x1F600;"
            parts.append(s[0].upper() + s[1:] + rng.choice((". ", "; ", "&#8212;", ", ", "! ", "? ")))
        return "".join(parts).replace("'", "&#x2019;") if rng.random() < 0.5 else "".join(parts)

    for c in range(1, chapters + 1):
        out.append(f"<!-- Chapter {c} -->\n<section id=\"ch{c}\" class=\"chapter\" epub:type=\"chapter\" "
                   'xmlns:epub="http://www.idpf.org/2007/ops">\n'
                   f"  <h1>Chapter {c} &#8212; {sentence(rng, 3).title()}</h1>\n")
        for _ in range(rng.randrange(20, 40)):
            r = rng.random()
            if r < 0.8:
                out.append(f"  <p>{paragraph()}</p>\n")
            elif r < 0.88:
                out.append(f"  <blockquote>\n    <p>{paragraph()}</p>\n  </blockquote>\n")
            elif r < 0.94:
                out.append("  <ul>\n" + "".join(f"    <li>{sentence(rng)}</li>\n" for _ in range(rng.randrange(2, 7))) + "  </ul>\n")
            elif r < 0.97:
                out.append("  <pre><![CDATA[\nfor (int i = 0; i < n; i++)\n    if (a[i] > b && c) print(\"<tag>\");\n]]></pre>\n")
            else:
                out.append(f"  <!-- {sentence(rng)} -->\n")
        out.append("</section>\n")
    out.append("</body>\n</html>\n")
    return "".join(out)


KEYS = (("highway", ("residential", "primary", "footway", "service")), ("building", ("yes", "house", "apartments")),
        ("amenity", ("cafe", "restaurant", "bench", "parking")), ("surface", ("asphalt", "paved", "gravel")),
        ("source", ("bing", "survey", "Bing &amp; survey")), ("oneway", ("yes", "no")),
        ("addr:street", ("Hauptstraße", "Rue de l&apos;Église", "Main St")), ("lanes", ("1", "2", "3")))


def osm(rng):
    """OpenStreetMap XML: nodes, ways and relations with many attributes. ~15 MB."""
    users = [f"{rng.choice(FIRST)}_{rng.choice(LAST)}".replace("'", "&apos;") for _ in range(200)]
    out = ["<?xml version='1.0' encoding='UTF-8'?>\n<osm version=\"0.6\" generator=\"osmium/1.16.0\">\n"
           '  <bounds minlat="51.2867600" minlon="-0.5103800" maxlat="51.6918700" maxlon="0.3340000"/>\n']

    def meta(i):
        return (f'id="{i}" version="{rng.randrange(1, 12)}" timestamp="20{rng.randrange(10, 25)}-{rng.randrange(1, 13):02d}-'
                f'{rng.randrange(1, 29):02d}T{rng.randrange(24):02d}:{rng.randrange(60):02d}:00Z" '
                f'uid="{rng.randrange(1, 9_000_000)}" user="{rng.choice(users)}" changeset="{rng.randrange(1, 150_000_000)}"')

    def tags(indent, n):
        out = []
        for k, values in rng.sample(KEYS, n):
            if rng.random() < 0.5:
                out.append(f'{indent}<tag k="{k}" v="{rng.choice(values)}"/>\n')
            else:
                out.append(f"{indent}<tag k='{k}' v='{rng.choice(values)}'/>\n")
        if rng.random() < 0.1:
            out.append(f'{indent}<tag k="name" v="{rng.choice(ACCENTED)} &quot;{rng.choice(LAST).replace(chr(39), "&apos;")}&quot;"/>\n')
        return "".join(out)

    nodes, ways = 55000, 7000
    for i in range(nodes):
        head = f'  <node {meta(1000000 + i)} lat="{rng.uniform(51.28, 51.69):.7f}" lon="{rng.uniform(-0.51, 0.33):.7f}"'
        n = rng.randrange(0, 6) if rng.random() < 0.3 else 0
        out.append(head + ("/>\n" if n == 0 else ">\n" + tags("    ", n) + "  </node>\n"))
    for w in range(ways):
        out.append(f"  <way {meta(5000000 + w)}>\n")
        for _ in range(rng.randrange(2, 25)):
            out.append(f'    <nd ref="{1000000 + rng.randrange(nodes)}"/>\n')
        out.append(tags("    ", rng.randrange(1, 6)) + "  </way>\n")
    for r in range(1000):
        out.append(f"  <relation {meta(9000000 + r)}>\n")
        for _ in range(rng.randrange(2, 20)):
            if rng.random() < 0.7:
                out.append(f'    <member type="way" ref="{5000000 + rng.randrange(ways)}" role="{rng.choice(("outer", "inner", ""))}"/>\n')
            else:
                out.append(f'    <member type="node" ref="{1000000 + rng.randrange(nodes)}" role="stop"/>\n')
        out.append(tags("    ", rng.randrange(1, 5)) + "  </relation>\n")
    out.append("</osm>\n")
    return "".join(out)


def atom(rng):
    """Namespace-heavy Atom feed. ~10 MB."""
    out = ['<?xml version="1.0" encoding="utf-8"?>\n'
           '<feed xmlns="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/elements/1.1/"\n'
           '      xmlns:media="http://search.yahoo.com/mrss/" xmlns:georss="http://www.georss.org/georss"\n'
           '      xmlns:thr="http://purl.org/syndication/thread/1.0" xmlns:app="http://www.w3.org/2007/app"\n'
           '      xmlns:gd="http://schemas.google.com/g/2005" xmlns:openSearch="http://a9.com/-/spec/opensearch/1.1/"\n'
           '      xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:gml="http://www.opengis.net/gml"\n'
           '      xml:lang="en" gd:etag="W/&quot;D0cERnk-eip7ImA9WBBXGEg.&quot;">\n'
           "  <id>urn:uuid:60a76c80-d399-11d9-b93C-0003939e0af6</id>\n  <title type=\"text\">Generated Feed</title>\n"
           "  <updated>2024-05-01T12:00:00Z</updated>\n  <openSearch:totalResults>100000</openSearch:totalResults>\n"
           '  <link rel="self" type="application/atom+xml" href="https://example.org/feed.atom"/>\n']
    for e in range(6000):
        local = rng.random() < 0.3
        ns = ' xmlns:ext="urn:example:extension" xmlns:dc="http://purl.org/dc/terms/"' if local else ""
        out.append(f'  <entry{ns} gd:etag="&quot;{rng.randrange(10**8)}&quot;">\n'
                   f"    <id>tag:example.org,2024:entry-{e}</id>\n"
                   f'    <title type="html">{sentence(rng, 5).title()} &amp;lt;{rng.randrange(100)}&amp;gt;</title>\n'
                   f"    <updated>2024-{rng.randrange(1, 13):02d}-{rng.randrange(1, 29):02d}T{rng.randrange(24):02d}:00:00Z</updated>\n"
                   f"    <app:edited>2024-{rng.randrange(1, 13):02d}-{rng.randrange(1, 29):02d}T00:00:00Z</app:edited>\n"
                   f"    <author>\n      <name>{rng.choice(FIRST)} {rng.choice(LAST)}</name>\n"
                   f"      <uri>https://example.org/~{rng.randrange(1000)}</uri>\n      <gd:image rel=\"http://schemas.google.com/g/2005#thumbnail\" width=\"32\" height=\"32\" src=\"https://example.org/a/{rng.randrange(1000)}.png\"/>\n    </author>\n"
                   f"    <dc:subject>{rng.choice(WORDS)}</dc:subject>\n    <dc:creator>{rng.choice(FIRST)}</dc:creator>\n")
        for _ in range(rng.randrange(1, 4)):
            out.append(f'    <category scheme="https://example.org/tags" term="{rng.choice(WORDS)}" label="{rng.choice(WORDS).title()}"/>\n')
        out.append(f'    <link rel="alternate" type="text/html" href="https://example.org/{e}.html"/>\n'
                   f'    <link rel="replies" type="application/atom+xml" href="https://example.org/{e}/comments" thr:count="{rng.randrange(50)}" thr:updated="2024-05-01T00:00:00Z"/>\n'
                   f"    <thr:total>{rng.randrange(50)}</thr:total>\n")
        if rng.random() < 0.4:
            out.append(f'    <media:group>\n      <media:content url="https://example.org/v/{e}.mp4" type="video/mp4" medium="video" duration="{rng.randrange(600)}"/>\n'
                       f'      <media:thumbnail url="https://example.org/t/{e}.jpg" width="480" height="360"/>\n'
                       f'      <media:title type="plain">{sentence(rng, 4)}</media:title>\n    </media:group>\n')
        if rng.random() < 0.3:
            out.append(f"    <georss:where>\n      <gml:Point>\n        <gml:pos>{rng.uniform(-90, 90):.5f} {rng.uniform(-180, 180):.5f}</gml:pos>\n"
                       "      </gml:Point>\n    </georss:where>\n")
        if local:
            out.append(f'    <ext:rating ext:scale="5" ext:value="{rng.randrange(1, 6)}"/>\n')
        out.append('    <content type="xhtml">\n      <div xmlns="http://www.w3.org/1999/xhtml">\n')
        for _ in range(rng.randrange(1, 4)):
            out.append(f"        <p>{sentence(rng)} <a href=\"https://example.org/{rng.randrange(1000)}\">{rng.choice(WORDS)}</a> "
                       f"{sentence(rng)} <strong>{rng.choice(ACCENTED)}</strong>.</p>\n")
        if rng.random() < 0.2:
            out.append('        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="16" height="16">'
                       f'<use xlink:href="#icon-{rng.choice(WORDS)}"/></svg>\n')
        out.append("      </div>\n    </content>\n  </entry>\n")
    out.append("</feed>\n")
    return "".join(out)


def main():
    os.makedirs(OUT, exist_ok=True)
    svg_icons()
    svg_artwork()
    rng = random.Random(1)
    write("svg-generated", svg_generated(rng))
    write("records", records(rng))
    write("book", book(rng, 850))
    write("osm", osm(rng))
    write("atom", atom(rng))
    # UTF-16LE with a BOM: str.encode("utf-16") writes the platform byte order (little-endian here)
    # after a BOM; spell it out so the file does not depend on the platform
    text = book(rng, 420, '<?xml version="1.0" encoding="UTF-16"?>\n')
    with open(os.path.join(OUT, "book-utf16.xml"), "wb") as f:
        f.write(b"\xff\xfe" + text.encode("utf-16-le"))
    print(f"{'book-utf16':14} {os.path.getsize(os.path.join(OUT, 'book-utf16.xml')):>10} bytes (UTF-16LE)")


if __name__ == "__main__":
    main()
