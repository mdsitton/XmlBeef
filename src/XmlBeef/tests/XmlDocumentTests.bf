using System;
using System.Collections;
using System.IO;
using XmlBeef;

namespace XmlBeef;

/// XmlDocument: the tree built from the reader, navigation, lookups and the canonical writer.
static class XmlDocumentTests
{
	static XmlDocument Parse(XmlDocument doc, StringView input, int line = Compiler.CallerLineNum)
	{
		if (doc.Read(input) case .Err(let error))
			Test.FatalError(scope $"line {line}: rejected: {error}");
		return doc;
	}

	static void AssertWrite(StringView input, StringView expected, StringView indent = default, int line = Compiler.CallerLineNum)
	{
		let doc = scope XmlDocument();
		Parse(doc, input, line);
		let output = scope String();
		var options = XmlWriteOptions();
		options.Indent = indent;
		doc.Write(output, options);
		if (output != expected)
			Test.FatalError(scope $"line {line}: wrote `{output}`, expected `{expected}`");
	}

	[Test]
	public static void Tree_Structure()
	{
		let doc = Parse(scope XmlDocument(), "<?xml version=\"1.0\"?><!--c--><!DOCTYPE r><r a=\"1\">x<b/>y<![CDATA[z]]><?p d?></r><!--e-->");
		Test.Assert(doc.HasXmlDeclaration && doc.Version == "1.0" && doc.Standalone == .Unspecified);
		let top = doc.DocumentNode.Children;
		Test.Assert(top.Count == 4);
		Test.Assert(top.First.Kind == .Comment && top.First.Value == "c");
		Test.Assert(doc.DocType.Kind == .DocType && doc.DocType.Name == "r");
		let root = doc.Root;
		Test.Assert(root.IsElement && root.Name == "r" && root.Depth == 0 && root.Parent == doc.DocumentNode);
		Test.Assert(top.Last.Kind == .Comment && top.Last.Value == "e");
		Test.Assert(root.ChildCount == 5);
		let kinds = scope List<XmlNodeKind>();
		for (let child in root.Children)
			kinds.Add(child.Kind);
		Test.Assert(kinds.Count == 5 && kinds[0] == .Text && kinds[1] == .Element && kinds[2] == .Text && kinds[3] == .CData && kinds[4] == .ProcessingInstruction);
		let b = root.FirstChild.NextSibling;
		Test.Assert(b.Name == "b" && b.IsEmptyTag && b.Parent == root && b.Depth == 1);
		Test.Assert(b.PreviousSibling.Value == "x" && b.NextSibling.Value == "y");
		Test.Assert(root.LastChild.Name == "p" && root.LastChild.Value == "d");
		Test.Assert(!root.FirstChild.FirstChild.IsValid);
		Test.Assert(!doc.DocumentNode.Parent.IsValid);
	}

	[Test]
	public static void Attributes_Lookup()
	{
		let doc = Parse(scope XmlDocument(), "<!DOCTYPE r [<!ATTLIST r d CDATA \"def\">]><r xmlns:x=\"urn:x\" a=\"1\" x:b=\"2.5\" c=\" true \" n=\"-9223372036854775808\" big=\"9223372036854775808\"/>");
		let root = doc.Root;
		Test.Assert(root.AttributeCount == 7);
		Test.Assert(root.TryGetAttribute("a", let a) && a == "1");
		Test.Assert(root.TryGetAttribute("urn:x", "b", let b) && b == "2.5");
		Test.Assert(root.GetAttribute("x:b") == "2.5" && root.GetAttribute("missing", "fallback") == "fallback");
		Test.Assert(root.HasAttribute("d") && !root.HasAttribute("e"));
		Test.Assert(root.GetInt32("a") == 1 && root.GetDouble("x:b") == 2.5 && root.GetBool("c"));
		Test.Assert(root.GetInt64("n") == int64.MinValue && !root.TryGetInt64("big", let big) && root.GetInt32("x:b", 7) == 7);
		Test.Assert(root.TryGetBool("a", let flag) && flag);
		var specified = 0;
		for (let attribute in root.Attributes)
		{
			if (attribute.IsSpecified)
				specified++;
		}
		Test.Assert(specified == 6);
		let d = root.Attributes[6];
		Test.Assert(d.Name == "d" && d.Value == "def" && !d.IsSpecified);
		let xb = root.Attributes[2];
		Test.Assert(xb.Prefix == "x" && xb.LocalName == "b" && xb.NamespaceUri == "urn:x");
	}

	[Test]
	public static void Values_Parsing()
	{
		let doc = Parse(scope XmlDocument(), "<r i=\" 42 \" j=\"+7\" k=\"4x\" d1=\"1e-3\" d2=\".5\" d3=\"5.\" d4=\"-INF\" d5=\"1,5\" d6=\"0x10\" b1=\"0\" b2=\"yes\"/>");
		let r = doc.Root;
		Test.Assert(r.GetInt32("i") == 42 && r.GetInt32("j") == 7 && !r.TryGetInt32("k", let k));
		Test.Assert(r.GetDouble("d1") == 0.001 && r.GetDouble("d2") == 0.5 && r.GetDouble("d3") == 5.0);
		Test.Assert(r.GetDouble("d4") == double.NegativeInfinity);
		Test.Assert(!r.TryGetDouble("d5", let d5) && !r.TryGetDouble("d6", let d6));
		Test.Assert(r.TryGetBool("b1", let b1) && !b1 && !r.TryGetBool("b2", let b2));
	}

	[Test]
	public static void Find_ChainsAndNamespaces()
	{
		let doc = Parse(scope XmlDocument(), """
			<svg xmlns="http://www.w3.org/2000/svg" xmlns:i="urn:i">
				<defs><linearGradient id="g"><stop offset="0"/><stop offset="1"/></linearGradient></defs>
				<g><path d="M0"/><i:path d="M1"/><g><path d="M2"/></g></g>
			</svg>
			""");
		let svg = doc.Root;
		Test.Assert(svg.Find("defs").Find("linearGradient").GetAttribute("id") == "g");
		Test.Assert(svg.Find("missing").Find("x").GetDouble("y", 3) == 3);
		Test.Assert(svg.Find("defs").Find("linearGradient").Children.Named("stop").Count == 2);
		let paths = scope List<StringView>();
		for (let path in svg.Descendants.Named("path"))
			paths.Add(path.GetAttribute("d"));
		Test.Assert(paths.Count == 2 && paths[0] == "M0" && paths[1] == "M2");
		Test.Assert(svg.Descendants.Named("http://www.w3.org/2000/svg", "path").Count == 2);
		Test.Assert(svg.Descendants.Named("urn:i", "path").First.GetAttribute("d") == "M1");
		Test.Assert(svg.Find("http://www.w3.org/2000/svg", "g").Children.Elements.Count == 3);
		Test.Assert(svg.Descendants.Count == 9);
		Test.Assert(svg.NamespaceUri == "http://www.w3.org/2000/svg" && svg.LocalName == "svg" && svg.Prefix == "");
		let ipath = svg.Descendants.Named("i:path").First;
		Test.Assert(ipath.Prefix == "i" && ipath.LocalName == "path" && ipath.NamespaceUri == "urn:i");
	}

	[Test]
	public static void Text_AndInnerText()
	{
		let doc = Parse(scope XmlDocument(), "<r><t>one</t><m>a<![CDATA[b]]>c</m><p>x <b>y <i>z</i></b> w</p><e/></r>");
		let r = doc.Root;
		Test.Assert(r.Find("t").Text == "one");
		Test.Assert(r.Find("m").Text == "abc");
		Test.Assert(r.Find("e").Text == "");
		Test.Assert(r.Find("p").Text == "x  w");
		let inner = scope String();
		r.Find("p").AppendInnerText(inner);
		Test.Assert(inner == "x y z w");
		Test.Assert(default(XmlNode).Text == "");
	}

	[Test]
	public static void Write_Canonical()
	{
		AssertWrite("<a/>", "<a/>\n");
		AssertWrite("<?xml version='1.0' encoding='iso-8859-1' standalone='yes'?><a>\xE9</a>", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<a>é</a>\n");
		AssertWrite("<a b='x\"&lt;&#9;&#10;&#13;&gt;'>&lt;&amp;]]&gt;>&#13;</a>", "<a b=\"x&quot;&lt;&#9;&#10;&#13;>\">&lt;&amp;]]&gt;>&#13;</a>\n");
		AssertWrite("<a><![CDATA[x]]]]><![CDATA[>y]]><!--c--><?p?><?q r?></a>", "<a><![CDATA[x]]]]><![CDATA[>y]]><!--c--><?p?><?q r?></a>\n");
		AssertWrite("<!DOCTYPE a SYSTEM 'x\"y.dtd'><a>&e;</a>", "<!DOCTYPE a SYSTEM 'x\"y.dtd'>\n<a>&e;</a>\n");
		AssertWrite("<!DOCTYPE a PUBLIC '-//p' \"s\" [ <!ATTLIST a d CDATA 'v'> ]><a/>", "<!DOCTYPE a PUBLIC \"-//p\" \"s\" [ <!ATTLIST a d CDATA 'v'> ]>\n<a/>\n");
		AssertWrite("<a>\r\n</a>", "<a>\n</a>\n");
	}

	[Test]
	public static void Write_Indented()
	{
		AssertWrite("<a>\n<b><c/></b>  <d>text <e/> more</d><f>  </f></a>", "<a>\n  <b>\n    <c/>\n  </b>\n  <d>text <e/> more</d>\n  <f/>\n</a>\n", "  ");
		// Mixed content and everything inside it is kept as it is
		AssertWrite("<p>a<b><c/><d/></b></p>", "<p>a<b><c/><d/></b></p>\n", "\t");
	}

	[Test]
	public static void Write_ReadBackIsTheSame()
	{
		let input = "<?xml version=\"1.0\"?><!DOCTYPE r [<!ENTITY e \"<x a='1'/>t\"><!ATTLIST x b CDATA \"2\">]><r q=\"&quot;'\">&e;<![CDATA[]]]]>&gt;<?pi?></r>";
		let doc = Parse(scope XmlDocument(), input);
		let first = doc.Write(.. scope String());
		let again = Parse(scope XmlDocument(), first);
		let second = again.Write(.. scope String());
		Test.Assert(first == second);
		let a = XmlCanonical.WriteSuiteForm(doc, .. scope String());
		let b = XmlCanonical.WriteSuiteForm(again, .. scope String());
		Test.Assert(a == b && a == "<r q=\"&quot;'\"><x a=\"1\" b=\"2\"></x>t]]&gt;<?pi ?></r>");
	}

	[Test]
	public static void DocType_ProcessingInstructions()
	{
		let doc = Parse(scope XmlDocument(), "<?a?><!DOCTYPE r [<?b c?><!NOTATION n SYSTEM \"s\">]><r/><?d?>");
		Test.Assert(doc.DocType.ChildCount == 1 && doc.DocType.FirstChild.Name == "b" && doc.DocType.FirstChild.Parent == doc.DocType);
		Test.Assert(doc.Notations.Length == 1 && doc.Notations[0].mSystemId == "s" && doc.HasInternalSubset);
		Test.Assert(XmlCanonical.WriteSuiteForm(doc, .. scope String()) == "<?a ?><?b c?><!DOCTYPE r [\n<!NOTATION n SYSTEM 's'>\n]>\n<r></r><?d ?>");
		// Not among the elements
		Test.Assert(doc.DocumentNode.Descendants.Count == 1);
	}

	[Test]
	public static void Read_ErrorsAndReuse()
	{
		let doc = scope XmlDocument();
		doc.ReadConfig.SourceName = "in.xml";
		switch (doc.Read("<a><b></a>"))
		{
		case .Ok:
			Test.FatalError("Expected an error");
		case .Err(let error):
			Test.Assert(error.ToString(.. scope .()) == "in.xml:1:7: The end tag `</a>` does not match the start tag `<b>`");
		}
		Test.Assert(!doc.Root.IsValid && doc.DocumentNode.ChildCount == 0 && doc.SourceName == "in.xml");
		Parse(doc, "<x><y/></x>");
		let y = doc.Root.FirstChild;
		Test.Assert(y.Name == "y");
		Parse(doc, "<z/>");
		Test.Assert(!y.IsValid && doc.Root.Name == "z");
		doc.Clear();
		Test.Assert(!doc.Root.IsValid);
	}

	[Test]
	public static void Read_File()
	{
		let path = scope String();
		Path.GetTempFileName(path);
		defer File.Delete(path);
		File.WriteAllText(path, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<file ok=\"1\"/>\n");
		let doc = scope XmlDocument();
		Test.Assert(doc.ReadFile(path) case .Ok);
		Test.Assert(doc.Root.GetInt32("ok") == 1 && doc.SourceName == path);
		var config = XmlReadConfig();
		config.MaxInputBytes = 10;
		switch (doc.ReadFile(path, config))
		{
		case .Ok:
			Test.FatalError("Expected the size limit");
		case .Err(let error):
			Test.Assert(error.mKind == .ResourceLimitExceeded);
		}
		switch (doc.ReadFile("/nonexistent/x.xml"))
		{
		case .Ok:
			Test.FatalError("Expected an I/O error");
		case .Err(let error):
			Test.Assert(error.mKind == .IoError);
		}
	}

	[Test]
	public static void Names_AreShared()
	{
		// The reader interns into the document's table: equal names have equal IDs
		let doc = Parse(scope XmlDocument(), "<r><a x=\"1\"/><a x=\"2\"/></r>");
		let first = doc.Root.FirstChild;
		let second = first.NextSibling;
		Test.Assert(first.NameId == second.NameId && first.Attributes[0].NameId == second.Attributes[0].NameId);
		Test.Assert(first.NameId != doc.Root.NameId);
	}
}
