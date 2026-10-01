// Java XML benchmark: xmlbench <sax|stax|dom|woodstox|aalto> <file-or-dir> <min-samples>
//   sax      - the JDK's SAXParser (its internal fork of Apache Xerces-J), namespace-aware, the
//              external DTD not loaded; a handler counts elements and attributes and adds up
//              attribute value and character data lengths.
//   stax     - the JDK's XMLStreamReader (XMLInputFactory.newDefaultFactory()), one pass over every
//              event; attribute values and text read as Strings (getAttributeValue, getText).
//   dom      - the JDK's DocumentBuilder into org.w3c.dom (namespace-aware, entity references
//              expanded, whitespace kept, the external DTD not loaded).
//   woodstox - Woodstox's XMLStreamReader (com.ctc.wstx.stax.WstxInputFactory), as stax.
//   aalto    - Aalto's XMLStreamReader (com.fasterxml.aalto.stax.InputFactoryImpl), as stax.
// Every parser reads from an InputStream over the bytes (encoding detected, UTF-16 by its BOM), DTDs
// allowed with the external subset resolved to nothing. The JDK parsers run with their default
// secure-processing limits. An input is a file or a directory (every file under it, sorted; one run
// parses each once). Prints the check line (see ../run.sh) first. Timings follow the shared rule (see
// measure); the 1 s warm-up also lets the JIT compile the parser.
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.StringReader;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.stream.Stream;
import javax.xml.parsers.DocumentBuilder;
import javax.xml.parsers.DocumentBuilderFactory;
import javax.xml.parsers.SAXParser;
import javax.xml.parsers.SAXParserFactory;
import javax.xml.stream.XMLInputFactory;
import javax.xml.stream.XMLStreamConstants;
import javax.xml.stream.XMLStreamReader;
import org.w3c.dom.Document;
import org.w3c.dom.NamedNodeMap;
import org.w3c.dom.Node;
import org.xml.sax.Attributes;
import org.xml.sax.InputSource;
import org.xml.sax.helpers.DefaultHandler;

public class XmlBench {
	interface Op {
		void run() throws Exception;
	}

	/** Warm up for at least 1 s, then time single runs until at least minSamples were taken and at
	 * least 60% lie within ±10% of their median, or 10 s / 1000 samples have passed. */
	static double[] measure(int minSamples, Op op) throws Exception {
		long warm = System.nanoTime();
		do
			op.run();
		while (System.nanoTime() - warm < 1_000_000_000L);
		long start = System.nanoTime();
		List<Double> samples = new ArrayList<>();
		while (true) {
			long t0 = System.nanoTime();
			op.run();
			samples.add((double) (System.nanoTime() - t0));
			List<Double> sorted = new ArrayList<>(samples);
			Collections.sort(sorted);
			int n = sorted.size();
			double median = n % 2 == 1 ? sorted.get(n / 2) : (sorted.get(n / 2 - 1) + sorted.get(n / 2)) / 2;
			if (n >= minSamples) {
				int within = 0;
				for (double s : samples)
					if (s >= median * 0.9 && s <= median * 1.1)
						within++;
				if (within >= 0.6 * n)
					return new double[] {median, n, 1};
			}
			if (n >= 1000 || System.nanoTime() - start >= 10_000_000_000L)
				return new double[] {median, n, 0};
		}
	}

	/** elements, attributes (without namespace declarations), attribute value chars, text chars */
	static final class Check {
		long elements, attributes, attrChars, textChars;

		void add(Check o) {
			elements += o.elements;
			attributes += o.attributes;
			attrChars += o.attrChars;
			textChars += o.textChars;
		}
	}

	/** Length in code points when checking, in UTF-16 units when timing (the timed runs only need to
	 * touch it) */
	static long len(String s, boolean exact) {
		return exact ? s.codePointCount(0, s.length()) : s.length();
	}

	static boolean isXmlns(String name) {
		return name.equals("xmlns") || name.startsWith("xmlns:");
	}

	// ---- SAX ----

	static SAXParser saxParser() throws Exception {
		SAXParserFactory f = SAXParserFactory.newInstance();
		f.setNamespaceAware(true);
		f.setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false);
		return f.newSAXParser();
	}

	static final class Handler extends DefaultHandler {
		final Check c = new Check();
		final boolean exact;

		Handler(boolean exact) {
			this.exact = exact;
		}

		@Override
		public void startElement(String uri, String local, String qName, Attributes atts) {
			c.elements++;
			for (int i = 0; i < atts.getLength(); i++) {
				if (isXmlns(atts.getQName(i)))
					continue;
				c.attributes++;
				c.attrChars += len(atts.getValue(i), exact);
			}
		}

		@Override
		public void characters(char[] ch, int start, int length) {
			c.textChars += exact ? Character.codePointCount(ch, start, length) : length;
		}

		@Override
		public void ignorableWhitespace(char[] ch, int start, int length) {
			characters(ch, start, length);
		}
	}

	static Check sax(SAXParser parser, byte[] data, boolean exact) throws Exception {
		Handler h = new Handler(exact);
		parser.parse(new ByteArrayInputStream(data), h);
		return h.c;
	}

	// ---- StAX (JDK, Woodstox, Aalto) ----

	static XMLInputFactory staxFactory(String lib) {
		XMLInputFactory f = switch (lib) {
			case "woodstox" -> new com.ctc.wstx.stax.WstxInputFactory();
			case "aalto" -> new com.fasterxml.aalto.stax.InputFactoryImpl();
			default -> XMLInputFactory.newDefaultFactory();
		};
		f.setProperty(XMLInputFactory.IS_NAMESPACE_AWARE, true);
		f.setProperty(XMLInputFactory.IS_COALESCING, false);
		f.setProperty(XMLInputFactory.IS_REPLACING_ENTITY_REFERENCES, true);
		f.setProperty(XMLInputFactory.IS_SUPPORTING_EXTERNAL_ENTITIES, false);
		f.setProperty(XMLInputFactory.SUPPORT_DTD, true);
		// The external DTD subset (svg11.dtd) resolves to nothing: no network access
		f.setXMLResolver((publicId, systemId, baseUri, namespace) -> new ByteArrayInputStream(new byte[0]));
		return f;
	}

	static Check stax(XMLInputFactory f, byte[] data, boolean exact) throws Exception {
		Check c = new Check();
		XMLStreamReader r = f.createXMLStreamReader(new ByteArrayInputStream(data));
		int depth = 0;
		while (r.hasNext()) {
			switch (r.next()) {
				case XMLStreamConstants.START_ELEMENT -> {
					c.elements++;
					depth++;
					for (int i = 0; i < r.getAttributeCount(); i++) {
						c.attributes++;
						c.attrChars += len(r.getAttributeValue(i), exact);
					}
				}
				case XMLStreamConstants.END_ELEMENT -> depth--;
				case XMLStreamConstants.CHARACTERS, XMLStreamConstants.CDATA, XMLStreamConstants.SPACE -> {
					if (depth > 0)
						c.textChars += len(r.getText(), exact);
				}
				default -> {
				}
			}
		}
		r.close();
		return c;
	}

	// ---- DOM ----

	static DocumentBuilder domBuilder() throws Exception {
		DocumentBuilderFactory f = DocumentBuilderFactory.newInstance();
		f.setNamespaceAware(true);
		f.setExpandEntityReferences(true);
		f.setCoalescing(false);
		f.setIgnoringElementContentWhitespace(false);
		f.setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false);
		return f.newDocumentBuilder();
	}

	static void walk(Node node, Check c) {
		for (Node child = node.getFirstChild(); child != null; child = child.getNextSibling()) {
			switch (child.getNodeType()) {
				case Node.ELEMENT_NODE -> {
					c.elements++;
					NamedNodeMap attrs = child.getAttributes();
					for (int i = 0; i < attrs.getLength(); i++) {
						Node a = attrs.item(i);
						if (isXmlns(a.getNodeName()))
							continue;
						c.attributes++;
						c.attrChars += len(a.getNodeValue(), true);
					}
					walk(child, c);
				}
				case Node.TEXT_NODE, Node.CDATA_SECTION_NODE -> c.textChars += len(child.getNodeValue(), true);
				default -> {
				}
			}
		}
	}

	static void collect(Path path, List<Path> files) throws IOException {
		if (Files.isDirectory(path)) {
			List<Path> entries;
			try (Stream<Path> s = Files.list(path)) {
				entries = new ArrayList<>(s.toList());
			}
			Collections.sort(entries);
			for (Path e : entries)
				collect(e, files);
		} else {
			files.add(path);
		}
	}

	public static void main(String[] args) throws Exception {
		if (args.length < 3) {
			System.err.println("usage: xmlbench <sax|stax|dom|woodstox|aalto> <file-or-dir> <min-samples>");
			System.exit(2);
		}
		String lib = args[0];
		List<Path> files = new ArrayList<>();
		collect(Path.of(args[1]), files);
		List<byte[]> docs = new ArrayList<>();
		long total = 0;
		for (Path f : files) {
			byte[] d = Files.readAllBytes(f);
			docs.add(d);
			total += d.length;
		}
		int minSamples = Integer.parseInt(args[2]);

		Check c = new Check();
		Op op;
		try {
			switch (lib) {
				case "sax" -> {
					SAXParser parser = saxParser();
					for (byte[] d : docs)
						c.add(sax(parser, d, true));
					op = () -> {
						for (byte[] d : docs)
							sax(parser, d, false);
					};
				}
				case "stax", "woodstox", "aalto" -> {
					XMLInputFactory f = staxFactory(lib);
					for (byte[] d : docs)
						c.add(stax(f, d, true));
					op = () -> {
						for (byte[] d : docs)
							stax(f, d, false);
					};
				}
				case "dom" -> {
					DocumentBuilder builder = domBuilder();
					// The external DTD subset resolves to nothing, as for SAX (load-external-dtd is off)
					builder.setEntityResolver((publicId, systemId) -> new InputSource(new StringReader("")));
					for (byte[] d : docs)
						walk(builder.parse(new ByteArrayInputStream(d)).getDocumentElement().getParentNode(), c);
					op = () -> {
						for (byte[] d : docs) {
							Document doc = builder.parse(new ByteArrayInputStream(d));
							if (doc == null)
								throw new IllegalStateException();
						}
					};
				}
				default -> {
					System.err.println("unknown library " + lib);
					System.exit(2);
					return;
				}
			}
		} catch (Exception e) {
			System.err.println("parse error: " + e.getMessage());
			System.exit(1);
			return;
		}
		System.out.printf("check: %d %d %d %d%n", c.elements, c.attributes, c.attrChars, c.textChars);
		double[] m = measure(minSamples, op);
		double ms = m[0] / 1e6;
		System.out.printf("%.3f ms/op %.1f MB/s (n=%d, %s)%n", ms, total / 1048576.0 / (ms / 1000.0), (int) m[1],
			m[2] == 1 ? "converged" : "capped");
	}
}
