// Rust XML benchmark: xmlbench <library> <file-or-dir> <min-samples>
//   quick-xml - quick_xml::Reader over the &[u8] (borrowing, no buffer), one pass over every event:
//               attribute values through normalized_value (entity and character references and
//               whitespace normalization), text through xml10_content (EOL normalization), each
//               GeneralRef event resolved (character references and the five predefined entities;
//               quick-xml does not read DTD entity declarations, so any other reference is an error).
//   roxmltree - roxmltree::Document::parse_with_options (DTDs allowed, no node limit) into its
//               read-only tree; &str input.
//   xmlparser - xmlparser::Tokenizer, one pass over every token. A tokenizer: values and text are
//               raw source spans (no reference expansion), so only the element and attribute counts
//               are compared.
//   xml-rs    - xml::EventReader (the xml-rs project, published as the `xml` crate since 1.0), one
//               pass over every event, whitespace and CDATA as their own events, comments skipped
//               (its default).
//   xmltree   - xmltree::Element::parse_with_config into its tree (built on xml-rs), with
//               whitespace-only text kept (whitespace_to_characters) and comments kept, as
//               Element::parse does.
// An input is a file or a directory (every file under it, sorted; one run parses each once). Libraries
// that read only UTF-8 (all but xml-rs and xmltree) exit 3 (n/a) on a UTF-16 input. Prints the check
// line (see ../run.sh) first. Timings follow the shared rule (see measure).
use std::borrow::Cow;
use std::time::Instant;

mod typed;

/// The rule shared by every harness in bench/compare (see ../run.sh): warm up for at least 1 s, then
/// time single runs until at least `min_samples` were taken and at least 60% lie within ±10% of their
/// median, or 10 s / 1000 samples have passed. Returns the median sample in ns.
pub fn measure(min_samples: usize, mut op: impl FnMut()) -> (f64, usize, bool) {
    let warm = Instant::now();
    loop {
        op();
        if warm.elapsed().as_secs_f64() >= 1.0 {
            break;
        }
    }
    let start = Instant::now();
    let mut samples: Vec<f64> = Vec::new();
    loop {
        let t0 = Instant::now();
        op();
        samples.push(t0.elapsed().as_nanos() as f64);
        let mut sorted = samples.clone();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let n = sorted.len();
        let median = if n % 2 == 1 { sorted[n / 2] } else { (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0 };
        if n >= min_samples {
            let within = samples.iter().filter(|&&s| s >= median * 0.9 && s <= median * 1.1).count();
            if within as f64 >= 0.6 * n as f64 {
                return (median, n, true);
            }
        }
        if n >= 1000 || start.elapsed().as_secs_f64() >= 10.0 {
            return (median, n, false);
        }
    }
}

/// elements, attributes (without namespace declarations), attribute value chars, text chars; -1 is
/// "not computed" (printed as "-")
#[derive(Default, Clone, Copy)]
struct Check {
    elements: i64,
    attributes: i64,
    attr_chars: i64,
    text_chars: i64,
}

impl Check {
    fn add(&mut self, o: Check) {
        self.elements += o.elements;
        self.attributes += o.attributes;
        self.attr_chars += o.attr_chars;
        self.text_chars += o.text_chars;
    }
}

fn field(v: i64) -> String {
    if v < 0 { "-".into() } else { v.to_string() }
}

/// Length in code points when checking, in bytes when timing (the timed runs only need to touch it)
fn len(s: &str, check: bool) -> i64 {
    if check { s.chars().count() as i64 } else { s.len() as i64 }
}

fn is_xmlns(name: &str) -> bool {
    name == "xmlns" || name.starts_with("xmlns:")
}

fn fail(e: impl std::fmt::Display) -> ! {
    eprintln!("parse error: {e}");
    std::process::exit(1);
}

// ---- quick-xml ----

fn resolve_ref(r: &quick_xml::events::BytesRef) -> i64 {
    if r.is_char_ref() {
        return match r.resolve_char_ref() {
            Ok(Some(_)) => 1,
            _ => fail("bad character reference"),
        };
    }
    match quick_xml::escape::resolve_predefined_entity(r) {
        Some(_) => 1,
        None => fail(format!("undeclared entity &{};", &**r)),
    }
}

fn quick_xml_attrs(e: &quick_xml::events::BytesStart, c: &mut Check, check: bool) {
    for a in e.attributes() {
        let a = a.unwrap_or_else(|e| fail(e));
        if is_xmlns(a.key.as_ref()) {
            continue;
        }
        c.attributes += 1;
        let v = a.normalized_value(quick_xml::XmlVersion::Implicit1_0).unwrap_or_else(|e| fail(e));
        c.attr_chars += len(&v, check);
    }
}

fn quick_xml(text: &str, check: bool) -> Check {
    use quick_xml::events::Event;
    let mut reader = quick_xml::Reader::from_str(text);
    let mut c = Check::default();
    let mut depth = 0usize;
    loop {
        match reader.read_event() {
            Ok(Event::Start(e)) => {
                c.elements += 1;
                depth += 1;
                quick_xml_attrs(&e, &mut c, check);
            }
            Ok(Event::Empty(e)) => {
                c.elements += 1;
                quick_xml_attrs(&e, &mut c, check);
            }
            Ok(Event::End(_)) => depth -= 1,
            // Only character data inside the root element counts
            Ok(Event::Text(t)) if depth > 0 => c.text_chars += len(&t.xml10_content(), check),
            Ok(Event::CData(t)) if depth > 0 => c.text_chars += len(&t.xml10_content(), check),
            Ok(Event::GeneralRef(r)) if depth > 0 => c.text_chars += resolve_ref(&r),
            Ok(Event::Eof) => break,
            Ok(_) => {}
            Err(e) => fail(e),
        }
    }
    c
}

// ---- roxmltree ----

fn roxmltree_options<'a>() -> roxmltree::ParsingOptions<'a> {
    roxmltree::ParsingOptions { allow_dtd: true, nodes_limit: u32::MAX, ..Default::default() }
}

fn roxmltree_check(doc: &roxmltree::Document) -> Check {
    let mut c = Check::default();
    for node in doc.root_element().descendants() {
        if node.is_element() {
            c.elements += 1;
            for a in node.attributes() {
                c.attributes += 1;
                c.attr_chars += a.value().chars().count() as i64;
            }
        } else if node.is_text() {
            c.text_chars += node.text().unwrap_or("").chars().count() as i64;
        }
    }
    c
}

// ---- xmlparser ----

fn xmlparser(text: &str) -> Check {
    let mut c = Check { attr_chars: -1, text_chars: -1, ..Default::default() };
    for token in xmlparser::Tokenizer::from(text) {
        match token {
            Ok(xmlparser::Token::ElementStart { .. }) => c.elements += 1,
            Ok(xmlparser::Token::Attribute { prefix, local, .. }) => {
                if !(prefix.as_str() == "xmlns" || (prefix.is_empty() && local.as_str() == "xmlns")) {
                    c.attributes += 1;
                }
            }
            Ok(_) => {}
            Err(e) => fail(e),
        }
    }
    c
}

// ---- xml-rs ----

fn xml_rs(data: &[u8], check: bool) -> Check {
    use xml::reader::{EventReader, ParserConfig, XmlEvent};
    let mut c = Check::default();
    let reader = EventReader::new_with_config(data, ParserConfig::new());
    for event in reader {
        match event {
            Ok(XmlEvent::StartElement { attributes, .. }) => {
                c.elements += 1;
                for a in &attributes {
                    c.attributes += 1;
                    c.attr_chars += len(&a.value, check);
                }
            }
            Ok(XmlEvent::Characters(s)) | Ok(XmlEvent::Whitespace(s)) | Ok(XmlEvent::CData(s)) => {
                c.text_chars += len(&s, check)
            }
            Ok(_) => {}
            Err(e) => fail(e),
        }
    }
    c
}

// ---- xmltree ----

fn xmltree_parse(data: &[u8]) -> xmltree::Element {
    let config = xmltree::ParserConfig::new().whitespace_to_characters(true).ignore_comments(false);
    xmltree::Element::parse_with_config(data, config).unwrap_or_else(|e| fail(e))
}

fn xmltree_check(e: &xmltree::Element, c: &mut Check) {
    c.elements += 1;
    for v in e.attributes.values() {
        c.attributes += 1;
        c.attr_chars += v.chars().count() as i64;
    }
    for child in &e.children {
        match child {
            xmltree::XMLNode::Element(el) => xmltree_check(el, c),
            xmltree::XMLNode::Text(s) | xmltree::XMLNode::CData(s) => c.text_chars += s.chars().count() as i64,
            _ => {}
        }
    }
}

// ---- inputs ----

fn collect(path: &std::path::Path, files: &mut Vec<std::path::PathBuf>) {
    if path.is_dir() {
        let mut entries: Vec<_> = std::fs::read_dir(path).expect("read dir").map(|e| e.unwrap().path()).collect();
        entries.sort();
        for e in entries {
            collect(&e, files);
        }
    } else {
        files.push(path.to_path_buf());
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: xmlbench <quick-xml|roxmltree|xmlparser|xml-rs|xmltree> <file-or-dir> <min-samples>");
        std::process::exit(2);
    }
    let lib = args[1].as_str();
    let min_samples: usize = args[3].parse().expect("min samples");
    let mut files = Vec::new();
    collect(std::path::Path::new(&args[2]), &mut files);
    let docs: Vec<Vec<u8>> = files.iter().map(|f| std::fs::read(f).expect("read")).collect();
    let total: usize = docs.iter().map(|d| d.len()).sum();
    let utf16 = docs.iter().any(|d| d.starts_with(&[0xFF, 0xFE]) || d.starts_with(&[0xFE, 0xFF]));
    let bytes_input = lib == "xml-rs" || lib == "xmltree";
    if utf16 && !bytes_input {
        eprintln!("{lib} reads only UTF-8");
        std::process::exit(3);
    }
    // The &str libraries get the text decoded once, outside the timing
    let texts: Vec<Cow<str>> =
        if bytes_input { Vec::new() } else { docs.iter().map(|d| String::from_utf8_lossy(d)).collect() };

    let texts = &texts;
    let docs = &docs;
    if lib == "quick-xml-serde" {
        typed::run(&texts[0], min_samples, total);
        return;
    }
    let mut c = Check::default();
    let mut op: Box<dyn FnMut()> = match lib {
        "quick-xml" => {
            texts.iter().for_each(|t| c.add(quick_xml(t, true)));
            Box::new(|| {
                texts.iter().for_each(|t| {
                    std::hint::black_box(quick_xml(t, false));
                })
            })
        }
        "roxmltree" => {
            for t in texts {
                let doc = roxmltree::Document::parse_with_options(t, roxmltree_options()).unwrap_or_else(|e| fail(e));
                c.add(roxmltree_check(&doc));
            }
            Box::new(|| {
                for t in texts {
                    std::hint::black_box(roxmltree::Document::parse_with_options(t, roxmltree_options()).unwrap());
                }
            })
        }
        "xmlparser" => {
            let mut sum = Check::default();
            texts.iter().for_each(|t| sum.add(xmlparser(t)));
            c = Check { attr_chars: -1, text_chars: -1, ..sum };
            Box::new(|| {
                texts.iter().for_each(|t| {
                    std::hint::black_box(xmlparser(t));
                })
            })
        }
        "xml-rs" => {
            docs.iter().for_each(|d| c.add(xml_rs(d, true)));
            Box::new(|| {
                docs.iter().for_each(|d| {
                    std::hint::black_box(xml_rs(d, false));
                })
            })
        }
        "xmltree" => {
            for d in docs {
                xmltree_check(&xmltree_parse(d), &mut c);
            }
            Box::new(|| {
                for d in docs {
                    std::hint::black_box(xmltree_parse(d));
                }
            })
        }
        _ => {
            eprintln!("unknown library {lib}");
            std::process::exit(2);
        }
    };
    println!("check: {} {} {} {}", field(c.elements), field(c.attributes), field(c.attr_chars), field(c.text_chars));
    let (median, n, converged) = measure(min_samples, &mut op);
    let ms = median / 1e6;
    println!("{:.3} ms/op {:.1} MB/s (n={}, {})", ms, total as f64 / 1048576.0 / (ms / 1000.0), n,
        if converged { "converged" } else { "capped" });
}
