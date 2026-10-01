// C# XML benchmark: XmlBench <library> <file-or-dir> <min-samples>
//   turboxml    - TurboXml (xoofx), a SAX-style parser with struct callbacks, over a MemoryStream of the
//                 bytes (encoding detected). IgnoreDtd = true skips the DOCTYPE (TurboXml rejects one
//                 by default and never expands DTD entities).
//   xmlparser   - KirillOsenkov/XmlParser (Microsoft.Language.Xml): Parser.ParseText into its
//                 full-fidelity, error-tolerant syntax tree (an editor's parser: it keeps the source
//                 text, so only element and attribute counts are compared). String input (decoded
//                 outside the timing).
//   xmlreader   - System.Xml XmlReader (pull): every node read, every attribute visited, every value
//                 read (Value).
//   xmldocument - System.Xml XmlDocument.Load into its DOM (PreserveWhitespace).
//   xdocument   - System.Xml.Linq XDocument.Load into its tree (LoadOptions.PreserveWhitespace).
// The System.Xml readers parse DTDs (DtdProcessing.Parse) without an XmlResolver, so the external
// subset is not fetched. All but xmlparser read from a MemoryStream over the bytes (encoding detected,
// UTF-16 by its BOM). An input is a file or a directory (every file under it, sorted; one run parses
// each once). Prints the check line (see ../run.sh) first. Timings follow the shared rule (see Measure
// and ../run.sh); the 1 s warm-up also lets the JIT compile the parser.
using System.Diagnostics;
using System.Text;
using System.Xml;
using System.Xml.Linq;
using Microsoft.Language.Xml;
using TurboXml;

if (args.Length < 3)
{
	Console.Error.WriteLine("usage: XmlBench <turboxml|xmlparser|xmlreader|xmldocument|xdocument> <file-or-dir> <min-samples>");
	return 2;
}
string lib = args[0];
var files = new List<string>();
Collect(args[1], files);
var docs = files.Select(File.ReadAllBytes).ToList();
long total = docs.Sum(d => (long)d.Length);
int minSamples = int.Parse(args[2]);
bool utf16 = docs.Any(d => d.Length >= 2 && ((d[0] == 0xFF && d[1] == 0xFE) || (d[0] == 0xFE && d[1] == 0xFF)));

var readerSettings = new XmlReaderSettings
{
	DtdProcessing = DtdProcessing.Parse,
	XmlResolver = null,
	IgnoreWhitespace = false,
	IgnoreComments = false,
	IgnoreProcessingInstructions = false,
};
var turboOptions = new XmlParserOptions { IgnoreDtd = true };

var check = new Check();
Action op;
try
{
	switch (lib)
	{
		case "turboxml":
			foreach (var d in docs)
				check.Add(Turbo(d, true));
			op = () => { foreach (var d in docs) Turbo(d, false); };
			break;
		case "xmlparser":
		{
			if (utf16)
			{
				Console.Error.WriteLine("xmlparser takes a string; the harness decodes UTF-8 only");
				return 3;
			}
			var texts = docs.Select(d => Encoding.UTF8.GetString(d)).ToList();
			foreach (var t in texts)
				SyntaxWalk(Parser.ParseText(t).RootSyntax ?? throw new InvalidDataException("no root element"), check);
			check.AttrChars = check.TextChars = -1;
			op = () => { foreach (var t in texts) GC.KeepAlive(Parser.ParseText(t)); };
			break;
		}
		case "xmlreader":
			foreach (var d in docs)
				check.Add(Reader(d, true));
			op = () => { foreach (var d in docs) Reader(d, false); };
			break;
		case "xmldocument":
			foreach (var d in docs)
				DomWalk(LoadXmlDocument(d).DocumentElement!, check);
			op = () => { foreach (var d in docs) GC.KeepAlive(LoadXmlDocument(d)); };
			break;
		case "xdocument":
			foreach (var d in docs)
				LinqWalk(XDocument.Load(new MemoryStream(d), LoadOptions.PreserveWhitespace).Root!, check);
			op = () => { foreach (var d in docs) GC.KeepAlive(XDocument.Load(new MemoryStream(d), LoadOptions.PreserveWhitespace)); };
			break;
		default:
			Console.Error.WriteLine($"unknown library {lib}");
			return 2;
	}
}
catch (Exception e)
{
	Console.Error.WriteLine($"parse error: {e.Message}");
	return 1;
}
Console.WriteLine($"check: {Field(check.Elements)} {Field(check.Attributes)} {Field(check.AttrChars)} {Field(check.TextChars)}");
var result = Measure(minSamples, op);
double ms = result.MedianNs / 1e6;
Console.WriteLine($"{ms:F3} ms/op {total / 1048576.0 / (ms / 1000.0):F1} MB/s (n={result.Samples}, {(result.Converged ? "converged" : "capped")})");
return 0;

static string Field(long v) => v < 0 ? "-" : v.ToString();

// Length in code points when checking, in UTF-16 units when timing (the timed runs only need to touch it)
static long Len(ReadOnlySpan<char> s, bool exact)
{
	if (!exact)
		return s.Length;
	long n = 0;
	foreach (char ch in s)
		n += char.IsLowSurrogate(ch) ? 0 : 1;
	return n;
}

static bool IsXmlns(ReadOnlySpan<char> name) => name.SequenceEqual("xmlns") || name.StartsWith("xmlns:");

Check Turbo(byte[] data, bool exact)
{
	var handler = new TurboHandler { Exact = exact };
	XmlParser.Parse(new MemoryStream(data), ref handler, turboOptions);
	return handler.C;
}

Check Reader(byte[] data, bool exact)
{
	var c = new Check();
	using var r = XmlReader.Create(new MemoryStream(data), readerSettings);
	while (r.Read())
	{
		switch (r.NodeType)
		{
			case XmlNodeType.Element:
				c.Elements++;
				if (r.MoveToFirstAttribute())
				{
					do
					{
						if (IsXmlns(r.Name))
							continue;
						c.Attributes++;
						c.AttrChars += Len(r.Value, exact);
					} while (r.MoveToNextAttribute());
					r.MoveToElement();
				}
				break;
			case XmlNodeType.Text:
			case XmlNodeType.CDATA:
			case XmlNodeType.Whitespace:
			case XmlNodeType.SignificantWhitespace:
				if (r.Depth > 0)
					c.TextChars += Len(r.Value, exact);
				break;
		}
	}
	return c;
}

XmlDocument LoadXmlDocument(byte[] data)
{
	var doc = new XmlDocument { PreserveWhitespace = true, XmlResolver = null };
	using var r = XmlReader.Create(new MemoryStream(data), readerSettings);
	doc.Load(r);
	return doc;
}

static void DomWalk(XmlNode node, Check c)
{
	if (node is XmlElement e)
	{
		c.Elements++;
		foreach (XmlAttribute a in e.Attributes)
		{
			if (IsXmlns(a.Name))
				continue;
			c.Attributes++;
			c.AttrChars += Len(a.Value, true);
		}
	}
	for (var child = node.FirstChild; child != null; child = child.NextSibling)
	{
		switch (child.NodeType)
		{
			case XmlNodeType.Element:
			case XmlNodeType.EntityReference:
				DomWalk(child, c);
				break;
			case XmlNodeType.Text:
			case XmlNodeType.CDATA:
			case XmlNodeType.Whitespace:
			case XmlNodeType.SignificantWhitespace:
				c.TextChars += Len(child.Value, true);
				break;
		}
	}
}

static void LinqWalk(XElement e, Check c)
{
	c.Elements++;
	foreach (var a in e.Attributes())
	{
		if (a.IsNamespaceDeclaration)
			continue;
		c.Attributes++;
		c.AttrChars += Len(a.Value, true);
	}
	foreach (var n in e.Nodes())
	{
		if (n is XElement child)
			LinqWalk(child, c);
		else if (n is XText t) // XCData derives from XText
			c.TextChars += Len(t.Value, true);
	}
}

// The syntax tree keeps the source text (whitespace between elements is trivia, references are not
// resolved in attribute values), so only the element and attribute counts are compared
static void SyntaxWalk(IXmlElementSyntax e, Check c)
{
	c.Elements++;
	foreach (var a in e.Attributes)
	{
		if (!IsXmlns(a.Name))
			c.Attributes++;
	}
	foreach (var n in e.Content)
	{
		if (n is IXmlElementSyntax child)
			SyntaxWalk(child, c);
	}
}

static void Collect(string path, List<string> files)
{
	if (Directory.Exists(path))
	{
		var entries = Directory.GetFileSystemEntries(path).OrderBy(p => p, StringComparer.Ordinal);
		foreach (var e in entries)
			Collect(e, files);
	}
	else
		files.Add(path);
}

// Warm up for at least 1 s (at least one run), then time single runs until at least minSamples were
// taken and at least 60% lie within ±10% of their median, or 10 s / 1000 samples have passed.
static (double MedianNs, int Samples, bool Converged) Measure(int minSamples, Action op)
{
	var warm = Stopwatch.StartNew();
	do
		op();
	while (warm.Elapsed.TotalSeconds < 1);
	var start = Stopwatch.StartNew();
	var samples = new List<double>();
	while (true)
	{
		long t0 = Stopwatch.GetTimestamp();
		op();
		samples.Add(Stopwatch.GetElapsedTime(t0).TotalMilliseconds * 1e6);
		var sorted = samples.Order().ToList();
		int n = sorted.Count;
		double median = n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
		if (n >= minSamples && samples.Count(s => s >= median * 0.9 && s <= median * 1.1) >= 0.6 * n)
			return (median, n, true);
		if (n >= 1000 || start.Elapsed.TotalSeconds >= 10)
			return (median, n, false);
	}
}

/// <summary>elements, attributes (without namespace declarations), attribute value chars, text chars</summary>
sealed class Check
{
	public long Elements, Attributes, AttrChars, TextChars;

	public void Add(Check o)
	{
		Elements += o.Elements;
		Attributes += o.Attributes;
		AttrChars += o.AttrChars;
		TextChars += o.TextChars;
	}
}

struct TurboHandler : IXmlReadHandler
{
	public Check C;
	public bool Exact;
	int _depth;

	public TurboHandler()
	{
		C = new Check();
	}

	public void OnBeginTag(ReadOnlySpan<char> name, int line, int column)
	{
		C.Elements++;
		_depth++;
	}

	public void OnEndTagEmpty() => _depth--;

	public void OnEndTag(ReadOnlySpan<char> name, int line, int column) => _depth--;

	public void OnAttribute(ReadOnlySpan<char> name, ReadOnlySpan<char> value, int nameLine, int nameColumn, int valueLine, int valueColumn)
	{
		if (name.SequenceEqual("xmlns") || name.StartsWith("xmlns:"))
			return;
		C.Attributes++;
		C.AttrChars += Exact ? CodePoints(value) : value.Length;
	}

	public void OnText(ReadOnlySpan<char> text, int line, int column)
	{
		if (_depth > 0)
			C.TextChars += Exact ? CodePoints(text) : text.Length;
	}

	public void OnCData(ReadOnlySpan<char> cdata, int line, int column)
	{
		if (_depth > 0)
			C.TextChars += Exact ? CodePoints(cdata) : cdata.Length;
	}

	public void OnError(string message, int line, int column) => throw new InvalidDataException($"{message} at {line}:{column}");

	static long CodePoints(ReadOnlySpan<char> s)
	{
		long n = 0;
		foreach (char ch in s)
			n += char.IsLowSurrogate(ch) ? 0 : 1;
		return n;
	}
}
