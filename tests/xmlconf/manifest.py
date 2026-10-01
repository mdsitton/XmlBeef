#!/usr/bin/env python3
"""Prints the W3C XML conformance suite's test manifest as tab-separated lines.

    tests/xmlconf/manifest.py [tests/suites/xmlconf/xmlconf.xml]

One line per TEST element of the master catalog and the leaf catalogs it pulls in as external
general entities:

    ID  TYPE  ENTITIES  NAMESPACE  RECOMMENDATION  VERSION  EDITION  URI  OUTPUT

with the attribute defaults of testcases.dtd applied (ENTITIES none, RECOMMENDATION XML1.0,
NAMESPACE yes), VERSION and EDITION empty when absent, and URI and OUTPUT resolved against the
effective xml:base to paths relative to the current directory (OUTPUT empty when absent). The
20130923 catalog's eduni/misc base bug is mapped here (docs/test-suites.md section 1.1):
`eduni/namespaces/misc/` becomes `eduni/misc/`.

This is the stand-in docs/test-suites.md section 9.1 allows until XmlBeef reads external entities
itself (XmlTester -catalog); it uses Python's expat with external general entities enabled.
"""

import os
import sys
import xml.sax
import xml.sax.handler

MISC_BUG = "eduni/namespaces/misc/"
MISC_FIX = "eduni/misc/"


class Catalog(xml.sax.handler.ContentHandler):
    def __init__(self, root):
        super().__init__()
        self.root = root
        self.bases = [""]
        self.rows = []

    def startElement(self, name, attrs):
        base = self.bases[-1]
        if "xml:base" in attrs:
            base = base + attrs["xml:base"]
            if base.endswith(MISC_BUG):
                base = base[: -len(MISC_BUG)] + MISC_FIX
        self.bases.append(base)
        if name != "TEST":
            return

        def resolve(rel):
            return os.path.relpath(os.path.join(self.root, base, rel)) if rel else ""

        self.rows.append(
            [
                attrs["ID"],
                attrs["TYPE"],
                attrs.get("ENTITIES", "none"),
                attrs.get("NAMESPACE", "yes"),
                attrs.get("RECOMMENDATION", "XML1.0"),
                attrs.get("VERSION", ""),
                attrs.get("EDITION", ""),
                resolve(attrs["URI"]),
                resolve(attrs.get("OUTPUT", "")),
            ]
        )

    def endElement(self, name):
        self.bases.pop()


def main():
    master = sys.argv[1] if len(sys.argv) > 1 else "tests/suites/xmlconf/xmlconf.xml"
    handler = Catalog(os.path.dirname(master))
    parser = xml.sax.make_parser()
    parser.setFeature(xml.sax.handler.feature_external_ges, True)
    parser.setContentHandler(handler)
    parser.parse(master)
    for row in handler.rows:
        print("\t".join(row))


if __name__ == "__main__":
    main()
