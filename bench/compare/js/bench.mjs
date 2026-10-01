// JavaScript XML benchmark: node bench.mjs <fast-xml-parser|xml2js|sax> <file-or-dir> <min-samples>
//   fast-xml-parser - XMLParser.parse into plain objects with preserveOrder (document order, as SVG
//                     needs), attributes kept, values left as strings (no number parsing), text
//                     untrimmed; entities processed with its default limits.
//   xml2js          - parseString (synchronous) into plain objects, with the options that keep
//                     document order and every text node (explicitChildren, preserveChildrenOrder,
//                     charsAsChildren, includeWhiteChars); built on sax.
//   sax             - sax-js in strict mode, the event parser under xml2js: handlers count elements
//                     and attributes and add up attribute value and text lengths.
// All three take a JavaScript string: the harness decodes UTF-8 outside the timing; a UTF-16 input
// exits 3 (n/a). An input is a file or a directory (every file under it, sorted; one run parses each
// once). Prints the check line (see ../run.sh) first. Timings follow the shared rule (see measure and
// ../run.sh); the 1 s warm-up also lets V8 optimize the parser.
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { XMLParser } from "fast-xml-parser";
import sax from "sax";
import xml2js from "xml2js";

function measure(minSamples, op) {
  const warm = process.hrtime.bigint();
  do op();
  while (process.hrtime.bigint() - warm < 1_000_000_000n);
  const start = process.hrtime.bigint();
  const samples = [];
  for (;;) {
    const t0 = process.hrtime.bigint();
    op();
    samples.push(Number(process.hrtime.bigint() - t0));
    const sorted = [...samples].sort((a, b) => a - b);
    const n = sorted.length;
    const median = n % 2 ? sorted[(n - 1) / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
    if (n >= minSamples && samples.filter((s) => s >= median * 0.9 && s <= median * 1.1).length >= 0.6 * n)
      return { median, n, converged: true };
    if (n >= 1000 || process.hrtime.bigint() - start >= 10_000_000_000n) return { median, n, converged: false };
  }
}

function collect(path, files) {
  if (statSync(path).isDirectory()) {
    for (const name of readdirSync(path).sort()) collect(join(path, name), files);
  } else files.push(path);
}

// Code points: UTF-16 units that are not low surrogates
function chars(s) {
  let n = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c < 0xdc00 || c > 0xdfff) n++;
  }
  return n;
}

const isXmlns = (name) => name === "xmlns" || name.startsWith("xmlns:");

// ---- fast-xml-parser ----

const fxp = new XMLParser({
  preserveOrder: true,
  ignoreAttributes: false,
  attributeNamePrefix: "",
  parseTagValue: false,
  parseAttributeValue: false,
  trimValues: false,
  ignoreDeclaration: true,
  ignorePiTags: true,
});

// preserveOrder: every node is { name: [children], ":@": { attributes } } or { "#text": text }
function fxpCheck(nodes, c, inside) {
  for (const node of nodes) {
    for (const key in node) {
      if (key === ":@") continue;
      if (key === "#text") {
        if (inside) c[3] += chars(String(node[key]));
        continue;
      }
      if (key === "?xml" || key[0] === "!" || key[0] === "?") continue;
      c[0]++;
      const attrs = node[":@"];
      if (attrs)
        for (const name in attrs) {
          if (isXmlns(name)) continue;
          c[1]++;
          c[2] += chars(String(attrs[name]));
        }
      fxpCheck(node[key], c, true);
    }
  }
}

// ---- xml2js ----

const xml2jsOptions = {
  explicitChildren: true,
  preserveChildrenOrder: true,
  charsAsChildren: true,
  includeWhiteChars: true,
  trim: false,
  normalize: false,
  async: false,
};

function xml2jsParse(text) {
  let result, error;
  xml2js.parseString(text, xml2jsOptions, (err, r) => {
    error = err;
    result = r;
  });
  if (error) throw error;
  return result;
}

// An element is a string (text only) or an object: attributes in $, children (in order, text as
// __text__ nodes) in $$
function xml2jsElement(v, c) {
  c[0]++;
  if (typeof v === "string") {
    c[3] += chars(v);
    return;
  }
  if (v.$)
    for (const name in v.$) {
      if (isXmlns(name)) continue;
      c[1]++;
      c[2] += chars(v.$[name]);
    }
  for (const child of v.$$ || []) {
    if (child["#name"] === "__text__") c[3] += chars(child._);
    else xml2jsElement(child, c);
  }
}

// ---- sax ----

function saxRun(text, exact) {
  const c = [0, 0, 0, 0];
  const len = exact ? chars : (s) => s.length;
  let depth = 0;
  const p = sax.parser(true, { trim: false, normalize: false });
  p.onopentag = (node) => {
    c[0]++;
    depth++;
    for (const name in node.attributes) {
      if (isXmlns(name)) continue;
      c[1]++;
      c[2] += len(node.attributes[name]);
    }
  };
  p.onclosetag = () => depth--;
  p.ontext = (t) => {
    if (depth > 0) c[3] += len(t);
  };
  p.oncdata = p.ontext;
  p.onerror = (e) => {
    throw e;
  };
  p.write(text).close();
  return c;
}

const [lib, path, min] = process.argv.slice(2);
const files = [];
collect(path, files);
const buffers = files.map((f) => readFileSync(f));
const total = buffers.reduce((n, b) => n + b.length, 0);
if (buffers.some((b) => b.length >= 2 && ((b[0] === 0xff && b[1] === 0xfe) || (b[0] === 0xfe && b[1] === 0xff)))) {
  console.error(`${lib} parses JavaScript strings; the harness decodes UTF-8 only`);
  process.exit(3);
}
const texts = buffers.map((b) => new TextDecoder("utf-8", { fatal: true }).decode(b));

const c = [0, 0, 0, 0];
let op;
try {
  if (lib === "fast-xml-parser") {
    for (const t of texts) fxpCheck(fxp.parse(t), c, false);
    op = () => {
      for (const t of texts) fxp.parse(t);
    };
  } else if (lib === "xml2js") {
    for (const t of texts) {
      const r = xml2jsParse(t);
      xml2jsElement(r[Object.keys(r)[0]], c);
    }
    op = () => {
      for (const t of texts) xml2jsParse(t);
    };
  } else if (lib === "sax") {
    for (const t of texts) saxRun(t, true).forEach((v, i) => (c[i] += v));
    op = () => {
      for (const t of texts) saxRun(t, false);
    };
  } else {
    console.error("unknown library", lib);
    process.exit(2);
  }
} catch (e) {
  console.error("parse error:", e.message);
  process.exit(1);
}
console.log(`check: ${c.join(" ")}`);
const m = measure(Number(min), op);
const ms = m.median / 1e6;
console.log(`${ms.toFixed(3)} ms/op ${(total / 1048576 / (ms / 1000)).toFixed(1)} MB/s (n=${m.n}, ${m.converged ? "converged" : "capped"})`);
