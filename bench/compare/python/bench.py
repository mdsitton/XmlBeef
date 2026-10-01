"""Python XML benchmark: bench.py <etree|lxml> <file-or-dir> <min-samples>

  etree - xml.etree.ElementTree.fromstring (the C accelerator over expat) into Elements; comments
          and processing instructions are dropped (its default).
  lxml  - lxml.etree.fromstring (libxml2) with its default parser (internal entities resolved, no
          network, comments kept).

Both parse bytes (encoding detected, UTF-16 by its BOM). An input is a file or a directory (every file
under it, sorted; one run parses each once). Prints the check line (see ../run.sh) first. Timings
follow the shared rule (see measure and ../run.sh).
"""
import os
import sys
import time


def measure(min_samples, op):
    warm = time.perf_counter_ns()
    while True:
        op()
        if time.perf_counter_ns() - warm >= 1_000_000_000:
            break
    start = time.perf_counter_ns()
    samples = []
    while True:
        t0 = time.perf_counter_ns()
        op()
        samples.append(time.perf_counter_ns() - t0)
        ordered = sorted(samples)
        n = len(ordered)
        median = ordered[n // 2] if n % 2 else (ordered[n // 2 - 1] + ordered[n // 2]) / 2
        if n >= min_samples and sum(median * 0.9 <= s <= median * 1.1 for s in samples) >= 0.6 * n:
            return median, n, True
        if n >= 1000 or time.perf_counter_ns() - start >= 10_000_000_000:
            return median, n, False


def collect(path, files):
    if os.path.isdir(path):
        for name in sorted(os.listdir(path)):
            collect(os.path.join(path, name), files)
    else:
        files.append(path)


def check_tree(root, is_element):
    """elements, attributes (namespace declarations are not attributes in either library), attribute
    value chars, text chars (len() of a str is its code point count)"""
    c = [0, 0, 0, 0]
    for node in root.iter():
        if is_element(node):
            c[0] += 1
            c[1] += len(node.attrib)
            c[2] += sum(len(v) for v in node.attrib.values())
            c[3] += len(node.text or "")
        if node is not root:
            c[3] += len(node.tail or "")
    return c


def main():
    if len(sys.argv) < 4:
        print("usage: bench.py <etree|lxml> <file-or-dir> <min-samples>", file=sys.stderr)
        sys.exit(2)
    lib, path, min_samples = sys.argv[1], sys.argv[2], int(sys.argv[3])
    files = []
    collect(path, files)
    docs = []
    for f in files:
        with open(f, "rb") as fh:
            docs.append(fh.read())
    total = sum(len(d) for d in docs)

    if lib == "etree":
        import xml.etree.ElementTree as ET
        parse = ET.fromstring
        is_element = lambda n: True
    elif lib == "lxml":
        from lxml import etree
        parser = etree.XMLParser()
        parse = lambda d: etree.fromstring(d, parser)
        is_element = lambda n: isinstance(n.tag, str)
    else:
        print("unknown library", lib, file=sys.stderr)
        sys.exit(2)

    c = [0, 0, 0, 0]
    try:
        for d in docs:
            for i, v in enumerate(check_tree(parse(d), is_element)):
                c[i] += v
    except Exception as e:
        print("parse error:", e, file=sys.stderr)
        sys.exit(1)
    print("check:", *c)

    def op():
        for d in docs:
            parse(d)

    median, n, converged = measure(min_samples, op)
    ms = median / 1e6
    print(f"{ms:.3f} ms/op {total / 1048576 / (ms / 1000):.1f} MB/s (n={n}, {'converged' if converged else 'capped'})")


if __name__ == "__main__":
    main()
