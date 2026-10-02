#!/usr/bin/env python3
"""Draws docs/benchmark.svg (chart) and docs/benchmark-table.svg (full results table) from results.md
(the Markdown tables run.sh prints; only the table rows are read).

    ./run.sh > results.md && ./plot.py

There is no XmlBeef parser yet, so speeds are relative to pugixml (parse_default), the speed reference;
once results.md has columns named XmlBeef (a document) and XmlBeef reader, they become the baselines
and are highlighted. Plain SVG with its own light/dark colors (prefers-color-scheme), so it renders
crisply on GitHub in either theme. No dependencies. Adapted from KdlBeef's bench/compare/plot.py.
"""
import math
import os
import re
import textwrap

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "results.md")
DOCS = os.path.join(HERE, "..", "..", "docs")
OUT = os.path.join(DOCS, "benchmark.svg")
TABLE_OUT = os.path.join(DOCS, "benchmark-table.svg")

LANGUAGE = {
    "XmlBeef": "Beef", "XmlBeef reader": "Beef",
    "libxml2": "C", "libxml2 reader": "C", "expat": "C", "pugixml": "C++", "pugixml ws": "C++",
    "Xerces-C": "C++", "roxmltree": "Rust", "xmltree": "Rust", "quick-xml": "Rust", "xmlparser": "Rust",
    "xml-rs": "Rust", "etree": "Go", "xmlquery": "Go", "encoding/xml": "Go", "JDK DOM": "Java",
    "JDK SAX": "Java", "JDK StAX": "Java", "Woodstox": "Java", "Aalto": "Java", "XmlDocument": "C#",
    "XDocument": "C#", "XmlParser (C#)": "C#", "XmlReader": "C#", "TurboXml": "C#", "ElementTree": "Python",
    "lxml": "Python", "fast-xml-parser": "JS", "xml2js": "JS", "sax-js": "JS", "nektro/zig-xml": "Zig",
    "zig-xml": "Zig", "Beef-Lang-XML": "Beef", "Xml-Beef": "Beef", "BeefXml reader": "Beef",
}
DISPLAY = {"pugixml ws": "pugixml (ws_pcdata)", "XmlParser (C#)": "XmlParser"}
REPO = {
    "XmlBeef": "mdsitton/XmlBeef", "XmlBeef reader": "mdsitton/XmlBeef",
    "libxml2": "GNOME/libxml2", "libxml2 reader": "GNOME/libxml2", "expat": "libexpat/libexpat",
    "pugixml": "zeux/pugixml", "pugixml ws": "zeux/pugixml", "Xerces-C": "apache/xerces-c",
    "roxmltree": "RazrFalcon/roxmltree", "xmltree": "eminence/xmltree-rs", "quick-xml": "tafia/quick-xml",
    "xmlparser": "RazrFalcon/xmlparser", "xml-rs": "kornelski/xml-rs", "etree": "beevik/etree",
    "xmlquery": "antchfx/xmlquery", "encoding/xml": "Go standard library", "JDK DOM": "OpenJDK 27",
    "JDK SAX": "OpenJDK 27", "JDK StAX": "OpenJDK 27", "Woodstox": "FasterXML/woodstox",
    "Aalto": "FasterXML/aalto-xml", "XmlDocument": ".NET 10 System.Xml", "XDocument": ".NET 10 System.Xml.Linq",
    "XmlParser (C#)": "KirillOsenkov/XmlParser", "XmlReader": ".NET 10 System.Xml", "TurboXml": "xoofx/TurboXml",
    "ElementTree": "Python 3.14 stdlib", "lxml": "lxml/lxml", "fast-xml-parser": "NaturalIntelligence/fast-xml-parser",
    "xml2js": "Leonidas-from-XIV/node-xml2js", "sax-js": "isaacs/sax-js", "nektro/zig-xml": "nektro/zig-xml",
    "zig-xml": "ianprime0509/zig-xml", "Beef-Lang-XML": "HorseTrain/Beef-Lang-XML",
    "Xml-Beef": "LauraRozier/Xml-Beef", "BeefXml reader": "Rune-Magic/BeefXml",
}
# Why a library fails some of the (valid) inputs, for its footnote
FAIL_REASON = {
    "pugixml": "leaves references to DTD-declared entities unexpanded",
    "pugixml ws": "leaves references to DTD-declared entities unexpanded",
    "xmltree": "keys attributes by local name, so xml:lang and lang collide",
    "xmlquery": "cannot decode UTF-16 with a BOM",
    "etree": "no DTD entities",
    "encoding/xml": "no DTD entities",
    "JDK DOM": "the JDK's default entity size limit",
    "JDK SAX": "the JDK's default entity size limit",
    "JDK StAX": "the JDK's default entity size limit",
    "Aalto": "no DTD entities",
    "quick-xml": "no DTD entities",
    "TurboXml": "no DTD entities",
    "XmlParser (C#)": "no DOCTYPE support",
    "fast-xml-parser": "leaves numeric character references undecoded; its default entity limits",
    "xml2js": "no DTD entities",
    "sax-js": "no DTD entities",
    "zig-xml": "no DTD support",
    "Beef-Lang-XML": "not an XML parser: text split into words, no references decoded",
    "Xml-Beef": "wrong counts; hangs on tags over 4 KB",
    "BeefXml reader": "no CDATA before text, fetches the external DTD, wrong values",
}
# Why a library times out, for its footnote
SLOW_REASON = {
    "Xml-Beef": "loops on constructs longer than its 4 KB buffer",
}
# Anything else a reader must know about a library's numbers
NOTE = {
    "pugixml": "parse_default drops whitespace-only text, so its text length is not compared",
    "xmlparser": "a tokenizer: values and text are raw spans, only counts are compared",
    "XmlParser (C#)": "an editor's syntax tree that keeps the source text; only counts are compared",
    "nektro/zig-xml": "trims spaces and newlines from both ends of every text run; text not compared",
    "BeefXml reader": "skips whitespace before every token; text not compared",
}
# The per-cell time limit run.sh used (DNF cells count at input size / LIMIT)
LIMIT = float(os.environ.get("LIMIT", "60"))
INPUTS = os.path.join(HERE, "inputs")
INPUT_LABELS = {"svg-icons": "SVG icons (17k files)", "svg-artwork": "SVG artwork (Inkscape)",
                "svg-generated": "SVG (Illustrator-style)", "records": "records (XMark-like)",
                "book": "book (XHTML text)", "osm": "OpenStreetMap", "atom": "Atom (namespaces)",
                "book-utf16": "book, UTF-16"}
INPUT_HEAD = {"svg-icons": ("SVG", "icons"), "svg-artwork": ("SVG", "artwork"), "svg-generated": ("SVG", "generated"),
              "records": ("records", ""), "book": ("book", ""), "osm": ("OSM", ""), "atom": ("Atom", ""),
              "book-utf16": ("book", "UTF-16")}

W = 920
FONT = "system-ui, -apple-system, 'Segoe UI', Helvetica, Arial, sans-serif"


def split(line):
    return [c.strip() for c in line.strip().strip("|").split("|")]


def input_size(name):
    path = os.path.join(INPUTS, name)
    if os.path.isdir(path):
        return sum(os.path.getsize(os.path.join(d, f)) for d, _, files in os.walk(path) for f in files)
    return os.path.getsize(path + ".xml")


def read_results():
    """Returns (builders, readers, table, timeouts): table[input][library] is MB/s or None (FAIL or
    DNF); a library with n/a for an input has no key in that row; timeouts[(input, library)] is the speed
    bound for a DNF cell, input size / LIMIT."""
    groups, current = [], None
    for line in open(RESULTS):
        if line.startswith("### "):
            current = []
            groups.append(current)
        elif current is not None and line.startswith("|") and not line.startswith("|---"):
            current.append(split(line))
    groups = [g for g in groups if g and g[0][0] == "input"][:2]
    table, timeouts, libraries = {}, {}, []
    for rows in groups:
        members = rows[0][1:]
        libraries.append(members)
        for cells in rows[1:]:
            name = cells[0]
            row = table.setdefault(name, {})
            for p, v in zip(members, cells[1:]):
                if v in ("n/a", "?"):
                    continue
                # A trailing ~ marks a cell whose runs did not settle (measure.sh): still its median
                row[p] = float(v.rstrip("~")) if re.match(r"^[0-9.]+~?$", v) else None
                if v == "DNF":
                    timeouts[(name, p)] = input_size(name) / 1048576.0 / LIMIT
    return libraries[0], libraries[1], table, timeouts


def baselines(builders, readers):
    """The baseline of each group: XmlBeef's own columns once they exist, else pugixml for both"""
    return ("XmlBeef" if "XmlBeef" in builders else "pugixml",
            "XmlBeef reader" if "XmlBeef reader" in readers else "XmlBeef" if "XmlBeef" in builders else "pugixml")


def ours(p):
    return p.startswith("XmlBeef")


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(x, y, s, cls, anchor="start"):
    return f'<text x="{x:.1f}" y="{y:.1f}" class="{cls}" text-anchor="{anchor}">{esc(s)}</text>'


def relative_speeds(libraries, table, timeouts, base):
    """Each library's speed relative to the baseline: the geometric mean over the inputs both handled
    of its MB/s divided by the baseline's. A timed-out input counts at its speed bound, which favors that
    library; failed inputs are left out. Returns {library: (ratio, inputs)}."""
    speeds = {}
    for p in libraries:
        ratios = []
        for name, row in table.items():
            v = row.get(p) if row.get(p) is not None else timeouts.get((name, p))
            if v and row.get(base):
                ratios.append(v / row[base])
        if ratios:
            speeds[p] = (math.exp(sum(math.log(r) for r in ratios) / len(ratios)), len(ratios))
    return speeds


def listing(items):
    return items[0] if len(items) == 1 else ", ".join(items[:-1]) + " and " + items[-1]


def caveat(p, table, timeouts):
    """Footnote text for a library that failed or timed out on some inputs, or has a note, else None."""
    failed = [INPUT_LABELS.get(i, i) for i, row in table.items() if p in row and row[p] is None and (i, p) not in timeouts]
    slow = [INPUT_LABELS.get(i, i) for i, row in table.items() if (i, p) in timeouts]
    parts = []
    if failed:
        reason = FAIL_REASON.get(p, "rejected as invalid or a wrong check")
        passed = [INPUT_LABELS.get(i, i) for i, row in table.items() if row.get(p)]
        what = "every input" if not passed else "all but " + listing(passed) if len(failed) > len(passed) else listing(failed)
        parts.append(f"failed {what} ({reason})")
    if slow:
        why = f"{SLOW_REASON[p]}; " if p in SLOW_REASON else ""
        parts.append(f"did not finish {listing(slow)} within {LIMIT:.0f} s ({why}counted at that bound)")
    if p in NOTE:
        parts.append(NOTE[p])
    return f"{DISPLAY.get(p, p)} " + "; ".join(parts) + "." if parts else None


def relative_panel(title, subtitle, groups, table, timeouts, top, footnotes):
    """Horizontal bars: average speed relative to a baseline, one block per (heading, members, baseline)
    group, fastest first. Libraries with caveats get a footnote. Libraries that failed every input are
    listed under the block instead of drawn."""
    out = []
    name_x, bar_x, bar_w = 90, 440, 240
    row_h, bar_h = 25, 16
    y = top
    out.append(text(40, y, title, "title"))
    y += 22
    out.append(text(40, y, subtitle, "subtitle"))
    y += 18
    for heading, members, base in groups:
        speeds = relative_speeds(members, table, timeouts, base)
        peak = max(1.0, max(r for r, _ in speeds.values()))
        y += 22
        out.append(text(40, y, heading.upper(), "group"))
        y += 8
        for p in sorted(speeds, key=lambda p: -speeds[p][0]):
            ratio, _ = speeds[p]
            cy = y + row_h / 2
            name = DISPLAY.get(p, p)
            note_text = caveat(p, table, timeouts)
            if note_text:
                name += "*"
                footnotes.setdefault(note_text, "* " + note_text)
            highlight = ours(p) or p == base
            out.append(text(40, cy + 5, LANGUAGE.get(p, ""), "lang"))
            out.append(f'<text x="{name_x}" y="{cy + 5:.1f}"><tspan class="{"label ours" if highlight else "label"}">{esc(name)}</tspan>'
                       f'<tspan class="repo" dx="8">{esc(REPO.get(p, ""))}</tspan></text>')
            w = max(2.0, bar_w * ratio / peak)
            out.append(f'<rect x="{bar_x}" y="{cy - bar_h / 2:.1f}" width="{w:.1f}" height="{bar_h}" rx="3" class="{"bar-ours" if highlight else "bar"}"/>')
            shown = f"{ratio:.2f}×" if ratio >= 0.1 else f"{ratio:.3f}×"
            if p == base:
                note = "baseline"
            elif ratio > 1:
                note = f"{ratio:.1f}× faster than {DISPLAY.get(base, base)}"
            else:
                note = f"{DISPLAY.get(base, base)} {1 / ratio:.0f}× faster" if 1 / ratio >= 10 \
                    else f"{DISPLAY.get(base, base)} {1 / ratio:.1f}× faster"
            out.append(f'<text x="{bar_x + w + 8:.1f}" y="{cy + 5:.1f}" class="small">'
                       f'<tspan class="{"value ours" if highlight else "value"}">{shown}</tspan>'
                       f'<tspan class="note-plain" dx="8">{esc(note)}</tspan></text>')
            y += row_h
        unmeasured = [DISPLAY.get(p, p) for p in members if p not in speeds]
        if unmeasured:
            y += 18
            out.append(text(40, y, f"No comparable figure (failed every input): {', '.join(unmeasured)}", "footnote"))
            y += 4
    return out, y


def fastest_panel(builders, readers, table, top):
    """Per input: the fastest document builder and the fastest reader, as labeled MB/s bars (and
    XmlBeef's when it has columns), each input's bars scaled to its own fastest."""
    out = []
    label_x, x, bar_w, bar_h, gap = 220, 240, 300, 13, 4
    y = top
    out.append(text(40, y, "The fastest per input", "title"))
    y += 22
    out.append(text(40, y, "MB/s · the fastest library that builds a document and the fastest reader · bars scaled per input",
                    "subtitle"))
    y += 24
    for name, results in table.items():
        picks = []
        for members in (builders, readers):
            ours_here = [(p, results[p]) for p in members if ours(p) and results.get(p)]
            rivals = {p: v for p, v in results.items() if p in members and not ours(p) and v}
            picks += ours_here
            if rivals:
                best = max(rivals, key=rivals.get)
                picks.append((best, rivals[best]))
        if not picks:
            continue
        row_h = len(picks) * (bar_h + gap) + 14
        out.append(f'<line x1="40" y1="{y:.1f}" x2="{W - 40}" y2="{y:.1f}" class="rule"/>')
        mid = y + row_h / 2
        out.append(text(label_x, mid + 5, INPUT_LABELS.get(name, name), "label", "end"))
        peak = max(v for _, v in picks)
        by = y + 7
        for lib, v in picks:
            w = max(2.0, bar_w * v / peak)
            is_ours = ours(lib)
            out.append(f'<rect x="{x}" y="{by:.1f}" width="{w:.1f}" height="{bar_h}" rx="2" class="{"bar-ours" if is_ours else "bar"}"/>')
            value = f"{v:.1f}" if v < 100 else f"{v:.0f}"
            kind = "reader" if lib in readers else "document"
            out.append(f'<text x="{x + w + 7:.1f}" y="{by + 11:.1f}" class="small">'
                       f'<tspan class="{"value ours" if is_ours else "value"}">{value}</tspan>'
                       f'<tspan class="{"libname ours" if is_ours else "libname"}" dx="6">{esc(DISPLAY.get(lib, lib))}</tspan>'
                       f'<tspan class="note-plain" dx="6">{LANGUAGE.get(lib, "")} {kind}</tspan></text>')
            by += bar_h + gap
        y += row_h
    out.append(f'<line x1="40" y1="{y:.1f}" x2="{W - 40}" y2="{y:.1f}" class="rule"/>')
    return out, y + 8


def table_panel(builders, readers, table, timeouts, bases, top):
    """The full results: one row per library (document builders, then readers, each ordered by average
    speed relative to its baseline), one column per input, MB/s per cell. The fastest cell of each
    column within its group is bold, and every cell is shaded by its speed relative to that best (log
    scale)."""
    out = []
    name_x, first_col, col_w, row_h = 40, 450, 62, 28
    width = first_col + len(table) * col_w + 40
    inputs = list(table.keys())
    y = top
    out.append(text(40, y, "Full results", "title"))
    y += 22
    out.append(text(40, y, "MB/s of input, higher is better · bold = best in its group · shading = relative to that best "
                    "(log scale)", "subtitle"))
    y += 34
    for c, name in enumerate(inputs):
        top_line, bottom_line = INPUT_HEAD.get(name, (name, ""))
        cx = first_col + c * col_w + col_w / 2
        if bottom_line:
            out.append(text(cx, y, top_line, "colhead", "middle"))
            out.append(text(cx, y + 14, bottom_line, "colhead", "middle"))
        else:
            out.append(text(cx, y + 14, top_line, "colhead", "middle"))
    y += 20
    groups = (("BUILDS A DOCUMENT", builders, bases[0]), ("PULL, EVENT AND SAX READERS", readers, bases[1]))
    for group, members, base in groups:
        speeds = relative_speeds(members, table, timeouts, base)
        y += 20
        out.append(text(name_x, y, group, "group"))
        y += 6
        best = {i: max((table[i].get(p) or 0 for p in members), default=0) for i in inputs}
        for p in sorted(members, key=lambda p: -speeds.get(p, (0, 0))[0]):
            highlight = ours(p)
            out.append(f'<line x1="40" y1="{y:.1f}" x2="{width - 40}" y2="{y:.1f}" class="rule"/>')
            if highlight:
                out.append(f'<rect x="40" y="{y:.1f}" width="{width - 80}" height="{row_h}" class="row-ours"/>')
            mid = y + row_h / 2
            star = "*" if caveat(p, table, timeouts) else ""
            out.append(f'<text x="{name_x}" y="{mid + 4.5:.1f}"><tspan class="lang">{esc(LANGUAGE.get(p, ""))}</tspan>'
                       f'<tspan x="{name_x + 50}" class="{"label ours" if highlight else "label"}">{esc(DISPLAY.get(p, p) + star)}</tspan>'
                       f'<tspan class="repo" dx="7">{esc(REPO.get(p, ""))}</tspan></text>')
            for c, name in enumerate(inputs):
                x = first_col + c * col_w
                if p not in table[name]:
                    out.append(text(x + col_w - 7, mid + 4, "n/a", "cell-missing", "end"))
                    continue
                v = table[name][p]
                if v is None:
                    label = "DNF" if (name, p) in timeouts else "FAIL"
                    out.append(text(x + col_w - 6, mid + 4, label, "cell-missing", "end"))
                    continue
                # Shade: 1.0 at the column's best, fading over a 100× range
                level = max(0.0, 1.0 + math.log10(v / best[name]) / 2.0)
                out.append(f'<rect x="{x + 2}" y="{y + 3:.1f}" width="{col_w - 4}" height="{row_h - 6}" rx="3" '
                           f'class="heat" fill-opacity="{0.06 + 0.34 * level:.2f}"/>')
                cls = "cell" + (" best" if v == best[name] else "") + (" ours" if highlight else "")
                out.append(text(x + col_w - 7, mid + 4.5, f"{v:.1f}" if v < 100 else f"{v:.0f}", cls, "end"))
            y += row_h
        out.append(f'<line x1="40" y1="{y:.1f}" x2="{width - 40}" y2="{y:.1f}" class="rule"/>')
    y += 22
    out.append(text(40, y, f"Median of 3-9 processes, until 3 agree within 5% · FAIL = rejected, crashed or a wrong check · DNF = over {LIMIT:.0f} s · "
                    "n/a = no UTF-16 support · * see the notes in results.md", "footnote"))
    return out, y + 8, width


def style():
    return f"""
  <style>
    svg {{ font-family: {FONT}; }}
    .bg {{ fill: #ffffff; }}
    .title {{ font-size: 19px; font-weight: 650; fill: #1f2328; }}
    .subtitle, .footer, .axis {{ font-size: 12.5px; fill: #656d76; }}
    .group {{ font-size: 11px; font-weight: 650; letter-spacing: 0.08em; fill: #656d76; }}
    .label {{ font-size: 13.5px; fill: #1f2328; }}
    .lang {{ font-size: 11px; fill: #8c959f; }}
    .ours {{ font-weight: 700; }}
    .value {{ font-size: 12.5px; fill: #424a53; font-variant-numeric: tabular-nums; }}
    .value.ours {{ fill: #c2410c; }}
    .small {{ font-size: 12px; fill: #424a53; }}
    .note-plain {{ fill: #8c959f; }}
    .footnote {{ font-size: 12px; fill: #656d76; }}
    .repo {{ font-size: 11.5px; fill: #8c959f; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }}
    .bar {{ fill: #afb8c1; }}
    .bar-ours {{ fill: #ea580c; }}
    .rule {{ stroke: #d8dee4; stroke-width: 1; }}
    .libname {{ fill: #656d76; }}
    .libname.ours {{ fill: #c2410c; font-weight: 650; }}
    .colhead {{ font-size: 11px; font-weight: 600; fill: #424a53; }}
    .cell {{ font-size: 12px; fill: #424a53; font-variant-numeric: tabular-nums; }}
    .cell.best {{ font-weight: 700; fill: #1f2328; }}
    .cell.ours {{ fill: #c2410c; }}
    .cell-missing {{ font-size: 10px; fill: #8c959f; }}
    .heat {{ fill: #2da44e; }}
    .row-ours {{ fill: #ea580c; fill-opacity: 0.07; }}
    @media (prefers-color-scheme: dark) {{
      .bg {{ fill: #0d1117; }}
      .title, .label {{ fill: #e6edf3; }}
      .subtitle, .footer, .axis, .group {{ fill: #8d96a0; }}
      .lang, .note-plain {{ fill: #6e7681; }}
      .footnote {{ fill: #8d96a0; }}
      .repo {{ fill: #6e7681; }}
      .value, .small {{ fill: #c9d1d9; }}
      .value.ours {{ fill: #fb923c; }}
      .bar {{ fill: #3d444d; }}
      .bar-ours {{ fill: #f97316; }}
      .rule {{ stroke: #262c36; }}
      .libname {{ fill: #8d96a0; }}
      .libname.ours {{ fill: #fb923c; }}
      .colhead {{ fill: #c9d1d9; }}
      .cell {{ fill: #c9d1d9; }}
      .cell.best {{ fill: #f0f6fc; }}
      .cell.ours {{ fill: #fb923c; }}
      .cell-missing {{ fill: #6e7681; }}
      .heat {{ fill: #3fb950; }}
      .row-ours {{ fill: #f97316; fill-opacity: 0.10; }}
    }}
  </style>"""


def write_svg(path, width, height, body, label):
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" '
           f'aria-label="{esc(label)}">', style(),
           f'<rect class="bg" x="0" y="0" width="{width}" height="{height}" rx="10"/>']
    svg += body + ["</svg>"]
    with open(path, "w") as f:
        f.write("\n".join(svg) + "\n")
    print(f"wrote {os.path.relpath(path)}")


FOOTER = ("Linux x86-64, single thread · 1 s warm-up, then samples until 60% are within ±10% of their median · "
          "median of 3 processes · bench/compare")


def main():
    builders, readers, table, timeouts = read_results()
    bases = baselines(builders, readers)
    footnotes = {}
    base_name = DISPLAY.get(bases[0], bases[0])
    panel1, y = relative_panel(
        f"XML parsing: average speed relative to {base_name}",
        f"geometric mean over the inputs both handled of each library's MB/s ÷ {base_name}'s · higher is better",
        (("Builds a document", builders, bases[0]), ("Pull, event and SAX readers", readers, bases[1])),
        table, timeouts, 44, footnotes)
    panel2, y = fastest_panel(builders, readers, table, y + 56)
    body = panel1 + panel2
    for note in footnotes.values():
        for i, line in enumerate(textwrap.wrap(note, 135)):
            y += 20 if i == 0 else 16
            body.append(text(40 if i == 0 else 50, y, line, "footnote"))
    height = y + 44
    body.append(text(40, height - 16, FOOTER, "footer"))
    write_svg(OUT, W, height, body, "XML parsing throughput of existing implementations")

    body, y, width = table_panel(builders, readers, table, timeouts, bases, 44)
    write_svg(TABLE_OUT, width, y + 24, body, "Full XML benchmark results: MB/s per implementation and input")


if __name__ == "__main__":
    main()
