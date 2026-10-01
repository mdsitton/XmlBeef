using System;
using System.Collections;
using XmlBeef;
using static XmlBeef.XmlTestUtil;

namespace XmlBeef;

/// XmlReader's events and API, encodings, DTD modes, error locations and the security limits.
static class XmlReaderTests
{
	[Test]
	public static void Events_Sequence()
	{
		let reader = scope XmlReader("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n<!--c--><!DOCTYPE r><r a=\"1\"><e/>t<![CDATA[d]]><?p q?></r>");
		Expect(reader, .XmlDeclaration);
		Test.Assert(reader.Version == "1.0" && reader.Encoding == "UTF-8" && reader.Standalone == .No);
		Expect(reader, .Comment);
		Test.Assert(reader.Value == "c" && reader.Depth == 0);
		Expect(reader, .DocType);
		Test.Assert(reader.Name == "r" && !reader.HasPublicId && !reader.HasSystemId);
		Expect(reader, .StartElement);
		Test.Assert(reader.Name == "r" && reader.Depth == 0 && !reader.IsEmptyElement && reader.AttributeCount == 1);
		Test.Assert(reader.TryGetAttribute("a", let a) && a == "1");
		Test.Assert(!reader.TryGetAttribute("b", let b));
		Expect(reader, .StartElement);
		Test.Assert(reader.Name == "e" && reader.Depth == 1 && reader.IsEmptyElement);
		Expect(reader, .EndElement);
		Test.Assert(reader.Name == "e" && reader.Depth == 1);
		Expect(reader, .Text);
		Test.Assert(reader.Value == "t" && reader.Depth == 1);
		Expect(reader, .CData);
		Test.Assert(reader.Value == "d");
		Expect(reader, .ProcessingInstruction);
		Test.Assert(reader.Name == "p" && reader.Value == "q");
		Expect(reader, .EndElement);
		Test.Assert(reader.Name == "r" && reader.Depth == 0);
		Expect(reader, .EndOfDocument);
		Expect(reader, .EndOfDocument);
	}

	[Test]
	public static void Events_Offsets()
	{
		let reader = scope XmlReader("<r>ab<c/></r>");
		Expect(reader, .StartElement);
		Test.Assert(reader.Offset == 0 && reader.EndOffset == 3);
		Expect(reader, .Text);
		Test.Assert(reader.Offset == 3 && reader.EndOffset == 5);
		Expect(reader, .StartElement);
		Test.Assert(reader.Offset == 5 && reader.EndOffset == 9);
		Expect(reader, .EndElement);
		Expect(reader, .EndElement);
		Test.Assert(reader.Offset == 9 && reader.EndOffset == 13);
	}

	[Test]
	public static void Text_MergedAcrossReferences()
	{
		// One Text event for text, references and an entity's text; markup inside the entity splits it
		let reader = scope XmlReader("<!DOCTYPE r [<!ENTITY e \"x<b/>y\">]><r>a&amp;&e;z</r>");
		Expect(reader, .DocType);
		Expect(reader, .StartElement);
		Expect(reader, .Text);
		Test.Assert(reader.Value == "a&x");
		Expect(reader, .StartElement);
		Test.Assert(reader.Name == "b" && reader.Depth == 1);
		Expect(reader, .EndElement);
		Expect(reader, .Text);
		Test.Assert(reader.Value == "yz");
		Expect(reader, .EndElement);
	}

	[Test]
	public static void Text_ViewsWithoutDecoding()
	{
		let input = "<r>plain text</r>";
		let reader = scope XmlReader(input);
		Expect(reader, .StartElement);
		Expect(reader, .Text);
		Test.Assert(reader.Value.Ptr == input.Ptr + 3 && reader.IsWhitespace == false);
		let spaces = scope XmlReader("<r> \n\t</r>");
		Expect(spaces, .StartElement);
		Expect(spaces, .Text);
		Test.Assert(spaces.IsWhitespace);
	}

	[Test]
	public static void Attributes_NamespacesAndLookup()
	{
		let reader = scope XmlReader("<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"><use xlink:href=\"#a\" x=\"1\"/></svg>");
		Expect(reader, .StartElement);
		Test.Assert(reader.NamespaceUri == "http://www.w3.org/2000/svg" && reader.Prefix == "" && reader.LocalName == "svg");
		Expect(reader, .StartElement);
		Test.Assert(reader.TryGetAttribute("http://www.w3.org/1999/xlink", "href", let href) && href == "#a");
		Test.Assert(reader.TryGetAttribute("xlink:href", let byName) && byName == "#a");
		Test.Assert(reader.TryGetAttribute("", "x", let x) && x == "1");
		Test.Assert(!reader.TryGetAttribute("http://www.w3.org/2000/svg", "x", let none));
		Test.Assert(reader.AttributePrefix(0) == "xlink" && reader.AttributeLocalName(0) == "href");
	}

	[Test]
	public static void Namespaces_Off()
	{
		var config = XmlReadConfig();
		config.Namespaces = false;
		let reader = scope XmlReader("<a:b xmlns:a=\"u\" c:d=\"1\"/>", config);
		Expect(reader, .StartElement);
		Test.Assert(reader.Name == "a:b" && reader.LocalName == "a:b" && reader.Prefix == "" && reader.NamespaceUri == "");
		Test.Assert(reader.AttributeLocalName(1) == "c:d" && reader.AttributeNamespaceUri(1) == "");
	}

	[Test]
	public static void Encodings_Detected()
	{
		let le = scope List<uint8>();
		Utf16("<?xml version=\"1.0\" encoding=\"UTF-16\"?><a>\u{1F600}</a>", false, true, le);
		Accepts(Bytes(le), "<a>\u{1F600}</a>");
		let be = scope List<uint8>();
		Utf16("<a>x</a>", true, true, be);
		Accepts(Bytes(be), "<a>x</a>");
		// UTF-16 without a byte order mark, declared
		let noBom = scope List<uint8>();
		Utf16("<?xml version=\"1.0\" encoding=\"UTF-16LE\"?><a/>", false, false, noBom);
		Accepts(Bytes(noBom), "<a></a>");
		// UTF-32BE with a byte order mark
		let utf32 = scope List<uint8>();
		for (let c in "\u{FEFF}<a>\u{10000}</a>".DecodedChars)
		{
			uint32 v = (uint32)c;
			utf32.Add((uint8)(v >> 24));
			utf32.Add((uint8)(v >> 16));
			utf32.Add((uint8)(v >> 8));
			utf32.Add((uint8)v);
		}
		Accepts(Bytes(utf32), "<a>\u{10000}</a>");
		let reader = scope XmlReader(Bytes(utf32));
		Expect(reader, .StartElement);
		Test.Assert(reader.DocumentEncoding == .Utf32BE);
	}

	[Test]
	public static void Encodings_Conflicts()
	{
		// A UTF-8 BOM wins over another ASCII-compatible declaration (plan.md §9 item 6)
		Accepts("\xEF\xBB\xBF<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><a>\xC3\xA9</a>", "<a>é</a>");
		Rejects("\xEF\xBB\xBF<?xml version=\"1.0\" encoding=\"UTF-16\"?><a/>", .UnsupportedEncoding);
		Rejects("\xEF\xBB\xBF<?xml version=\"1.0\" encoding=\"x-unknown\"?><a/>", .UnsupportedEncoding);
		// 8-bit bytes declaring UTF-16
		Rejects("<?xml version=\"1.0\" encoding=\"UTF-16\"?><a/>", .UnsupportedEncoding);
		Rejects("<?xml version=\"1.0\" encoding=\"US-ASCII\"?><a>\xE9</a>", .InvalidEncoding);
		Accepts("<?xml version=\"1.0\" encoding=\"us-ascii\"?><a>x</a>", "<a>x</a>");
		Rejects("\x4C\x6F\xA7\x94", .UnsupportedEncoding);
		Rejects("+/v8<a/>", .UnsupportedEncoding);
		// An unpaired surrogate in UTF-16
		let bad = scope List<uint8>();
		Utf16("<a>", false, true, bad);
		bad.Add(0x00);
		bad.Add(0xD8);
		Utf16("</a>", false, false, bad);
		Rejects(Bytes(bad), .InvalidEncoding);
	}

	[Test]
	public static void Dtd_Modes()
	{
		var prohibit = XmlReadConfig();
		prohibit.DtdMode = .Prohibit;
		RejectsWith("<!DOCTYPE a><a/>", .DtdProhibited, prohibit);
		var ignore = XmlReadConfig();
		ignore.DtdMode = .Ignore;
		let reader = scope XmlReader("<!DOCTYPE a [<!ENTITY e \"v\"><!ATTLIST a b CDATA \"d\">]><a>&e;</a>", ignore);
		Expect(reader, .DocType);
		Expect(reader, .StartElement);
		Test.Assert(reader.AttributeCount == 0);
		Expect(reader, .EntityReference);
		Test.Assert(reader.Name == "e");
		// Still checked for well-formedness
		RejectsWith("<!DOCTYPE a [<!ENTITY e \"v\" junk>]><a/>", .UnexpectedChar, ignore);
	}

	[Test]
	public static void Dtd_DocTypeFieldsAndNotations()
	{
		let reader = scope XmlReader("<!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\" \"svg11.dtd\" [ <!NOTATION n PUBLIC \"a  b\"> <?pi in dtd?> ]><svg/>");
		Expect(reader, .ProcessingInstruction);
		Test.Assert(reader.Name == "pi" && reader.Value == "in dtd");
		Expect(reader, .DocType);
		Test.Assert(reader.Name == "svg" && reader.PublicId == "-//W3C//DTD SVG 1.1//EN" && reader.SystemId == "svg11.dtd");
		Test.Assert(reader.InternalSubset == " <!NOTATION n PUBLIC \"a  b\"> <?pi in dtd?> ");
		Test.Assert(reader.Notations.Length == 1 && reader.Notations[0].mName == "n" && reader.Notations[0].mPublicId == "a b" && !reader.Notations[0].mHasSystemId);
	}

	[Test]
	public static void Dtd_IllustratorNamespaces()
	{
		// Illustrator's prolog: namespace names from internal-subset entities, under an external DTD
		let input = """
			<?xml version="1.0" encoding="utf-8"?>
			<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd" [
				<!ENTITY ns_svg "http://www.w3.org/2000/svg">
				<!ENTITY ns_xlink "http://www.w3.org/1999/xlink">
			]>
			<svg version="1.1" xmlns="&ns_svg;" xmlns:xlink="&ns_xlink;"><use xlink:href="#p"/>&nbsp;</svg>
			""";
		let reader = scope XmlReader(input);
		Expect(reader, .XmlDeclaration);
		Expect(reader, .DocType);
		Expect(reader, .StartElement);
		Test.Assert(reader.NamespaceUri == "http://www.w3.org/2000/svg");
		Expect(reader, .StartElement);
		Test.Assert(reader.TryGetAttribute("http://www.w3.org/1999/xlink", "href", let href) && href == "#p");
		Expect(reader, .EndElement);
		// The external DTD is not read, so `&nbsp;` is a skipped entity, not an error
		Expect(reader, .EntityReference);
		Test.Assert(reader.Name == "nbsp");
		Expect(reader, .EndElement);
		Expect(reader, .EndOfDocument);
	}

	[Test]
	public static void Errors_Located()
	{
		let reader = scope XmlReader("<a>\n  <b></c></a>");
		Expect(reader, .StartElement);
		Expect(reader, .Text);
		Expect(reader, .StartElement);
		switch (reader.Next())
		{
		case .Ok:
			Test.FatalError("Expected an error");
		case .Err(let error):
			Test.Assert(error.mKind == .MismatchedEndTag && error.mLine == 2 && error.mColumn == 6 && error.mOffset == 9);
			Test.Assert(error.ToString(.. scope .()) == "2:6: The end tag `</c>` does not match the start tag `<b>`");
		}
		// Sticky
		Test.Assert(reader.IsStopped);
		if (reader.Next() case .Err(let again))
			Test.Assert(again.mKind == .MismatchedEndTag);
		else
			Test.FatalError("Errors are sticky");
	}

	[Test]
	public static void Errors_InsideEntityAtReference()
	{
		var config = XmlReadConfig();
		config.SourceName = "doc.xml";
		let reader = scope XmlReader("<!DOCTYPE a [<!ENTITY e \"<b>\">]>\r\n<a>&e;</a>", config);
		Expect(reader, .DocType);
		Expect(reader, .StartElement);
		Expect(reader, .StartElement);
		switch (reader.Next())
		{
		case .Ok:
			Test.FatalError("Expected an error");
		case .Err(let error):
			Test.Assert(error.mKind == .UnclosedElement && error.mLine == 2 && error.mColumn == 4 && error.mLength == 3);
			Test.Assert(error.ToString(.. scope .()) == "doc.xml:2:4: The element `b` starts in the entity `e` but does not end in it (in the replacement text of the entity `e`)");
		}
	}

	[Test]
	public static void Errors_ColumnsCountCodePoints()
	{
		let reader = scope XmlReader("<é>中\u{10000}&bad;</é>");
		Expect(reader, .StartElement);
		switch (reader.Next())
		{
		case .Ok:
			Test.FatalError("Expected an error");
		case .Err(let error):
			Test.Assert(error.mKind == .UndeclaredEntity && error.mLine == 1 && error.mColumn == 6);
		}
	}

	[Test]
	public static void Security_BillionLaughs()
	{
		let input = """
			<!DOCTYPE lolz [
			<!ENTITY lol "lol">
			<!ENTITY lol1 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
			<!ENTITY lol2 "&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;">
			<!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">
			<!ENTITY lol4 "&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;">
			<!ENTITY lol5 "&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;">
			<!ENTITY lol6 "&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;">
			<!ENTITY lol7 "&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;">
			<!ENTITY lol8 "&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;">
			<!ENTITY lol9 "&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;">
			]>
			<lolz>&lol9;</lolz>
			""";
		Rejects(input, .ResourceLimitExceeded);
		// The same through an attribute value
		let attribute = scope String(input);
		attribute.Replace("<lolz>&lol9;</lolz>", "<lolz a=\"&lol9;\"/>");
		Rejects(attribute, .ResourceLimitExceeded);
		// And through an attribute default applied to many elements
		let defaults = scope String(input);
		defaults.Replace("]>", "<!ATTLIST x a CDATA \"&lol6;\">]>");
		defaults.Replace("<lolz>&lol9;</lolz>", "<lolz>");
		for (int i < 2000)
			defaults.Append("<x/>");
		defaults.Append("</lolz>");
		Rejects(defaults, .ResourceLimitExceeded);
	}

	[Test]
	public static void Security_QuadraticBlowup()
	{
		let input = scope String();
		input.Append("<!DOCTYPE r [<!ENTITY big \"");
		input.Append('x', 100000);
		input.Append("\">]><r>");
		for (int i < 10000)
			input.Append("&big;");
		input.Append("</r>");
		Rejects(input, .ResourceLimitExceeded);
	}

	[Test]
	public static void Security_EntityDepth()
	{
		let input = scope String();
		input.Append("<!DOCTYPE r [<!ENTITY e0 \"x\">");
		for (int i = 1; i <= 30; i++)
			input.AppendF("<!ENTITY e{} \"&e{};\">", i, i - 1);
		input.Append("]><r>&e30;</r>");
		Rejects(input, .ResourceLimitExceeded);
		var config = XmlReadConfig();
		config.MaxEntityDepth = 0;
		let reader = scope XmlReader(input, config);
		Expect(reader, .DocType);
		Expect(reader, .StartElement);
		Expect(reader, .Text);
		Test.Assert(reader.Value == "x");
	}

	[Test]
	public static void Security_ExternalEntitiesNeverOpened()
	{
		let reader = scope XmlReader("<!DOCTYPE r [<!ENTITY x SYSTEM \"file:///etc/passwd\"><!ENTITY % p SYSTEM \"http://example.invalid/x.dtd\"> %p;]><r>&x;</r>");
		Expect(reader, .DocType);
		Expect(reader, .StartElement);
		Expect(reader, .EntityReference);
		Test.Assert(reader.Name == "x");
		Expect(reader, .EndElement);
		Expect(reader, .EndOfDocument);
	}

	[Test]
	public static void Limits_DepthAttributesNames()
	{
		let deep = scope String();
		for (int i < 300)
			deep.Append("<a>");
		for (int i < 300)
			deep.Append("</a>");
		Rejects(deep, .ResourceLimitExceeded);
		var config = XmlReadConfig();
		config.MaxDepth = 0;
		let reader = scope XmlReader(deep, config);
		let output = scope String();
		Test.Assert(XmlCanonical.WriteSuiteForm(reader, output) case .Ok);

		var few = XmlReadConfig();
		few.MaxAttributesPerElement = 2;
		RejectsWith("<a x=\"1\" y=\"2\" z=\"3\"/>", .ResourceLimitExceeded, few);
		var shortNames = XmlReadConfig();
		shortNames.MaxNameBytes = 4;
		RejectsWith("<abcde/>", .ResourceLimitExceeded, shortNames);
		var shortText = XmlReadConfig();
		shortText.MaxTextBytes = 4;
		RejectsWith("<a>abcde</a>", .ResourceLimitExceeded, shortText);
		RejectsWith("<a b=\"abcde\"/>", .ResourceLimitExceeded, shortText);
		var fewNodes = XmlReadConfig();
		fewNodes.MaxNodes = 2;
		RejectsWith("<a><b/><c/></a>", .ResourceLimitExceeded, fewNodes);
		var small = XmlReadConfig();
		small.MaxInputBytes = 4;
		RejectsWith("<abc/>", .ResourceLimitExceeded, small);
	}

	[Test]
	public static void Limits_ManyAttributesUseTheSet()
	{
		let input = scope String("<a");
		for (int i < 40)
			input.AppendF(" a{}=\"{}\"", i, i);
		input.Append(" a7=\"x\"/>");
		Rejects(input, .DuplicateAttribute);
	}

	[Test]
	public static void Reset_ReusesReader()
	{
		let reader = scope XmlReader("<a>&e;</a>");
		Expect(reader, .StartElement);
		Test.Assert(reader.Next() case .Err);
		reader.Reset("<!DOCTYPE b [<!ENTITY e \"v\">]><b>&e;</b>");
		Expect(reader, .DocType);
		Expect(reader, .StartElement);
		Test.Assert(reader.Name == "b");
		Expect(reader, .Text);
		Test.Assert(reader.Value == "v");
	}
}
