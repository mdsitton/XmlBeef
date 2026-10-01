using System;
using System.Collections;
using XmlBeef;

namespace XmlBeef;

/// R13: a strict type whose attribute is in a namespace.
[XmlObject(Name = "r", Strict = true)]
class ReviewStrictModel
{
	[XmlName("a", Namespace = "urn:expected")] public String value ~ delete _;
	[XmlName("a", Namespace = "urn:second")] public String second ~ delete _;
}

/// Regressions for the findings of the 2026-10-01 code review (docs/review-2026-10-01.md), by number.
static class XmlReviewTests
{
	static void ExpectKind(Result<void, XmlParseError> result, XmlErrorKind kind, int line = Compiler.CallerLineNum)
	{
		switch (result)
		{
		case .Ok:
			Test.FatalError(scope $"line {line}: no error, expected {kind}");
		case .Err(let error):
			if (error.mKind != kind)
				Test.FatalError(scope $"line {line}: expected {kind}, got {error.mKind}: {error}");
		}
	}

	/// Reads `input` from memory and through streams of the given buffer sizes, with `config`.
	static void ReadAllWays(StringView input, XmlReadConfig config, delegate void(Result<void, XmlParseError> result, XmlDocument doc) check)
	{
		let doc = scope XmlDocument();
		check(doc.Read(input, config), doc);
		for (int buffer in int[](16, 65536))
		{
			var streamed = config;
			streamed.StreamBufferBytes = buffer;
			check(doc.Read(scope XmlStreamTests.TrickleStream(input, 13), streamed), doc);
		}
	}

	[Test]
	public static void R04_LateEncodingDeclarations()
	{
		// Latin-1 declared after 4,100 spaces: decoded as declared
		let latin1 = scope String("<?xml version=\"1.0\"");
		latin1.Append(' ', 4100);
		latin1.Append("encoding=\"ISO-8859-1\"?><r>\xE9</r>");
		ReadAllWays(latin1, .(), scope (result, doc) =>
			{
				Test.Assert(result case .Ok);
				Test.Assert(doc.Root.Text == "é" && doc.Encoding == .Latin1);
			});
		// US-ASCII declared late: a byte above 0x7F is an error
		let ascii = scope String("<?xml version=\"1.0\"");
		ascii.Append(' ', 4100);
		ascii.Append("encoding=\"US-ASCII\"?><r>\xC3\xA9</r>");
		ReadAllWays(ascii, .(), scope (result, doc) => ExpectKind(result, .InvalidEncoding));
		// Not past MaxTokenBytes: an error, not a guess
		var limited = XmlReadConfig();
		limited.MaxTokenBytes = 1000;
		ReadAllWays(latin1, limited, scope (result, doc) => ExpectKind(result, .ResourceLimitExceeded));
	}

	[Test]
	public static void R05_RetentionAfterAnEntity()
	{
		// Each construct is below MaxTokenBytes; the document before the reference is not
		let input = scope String("<!--");
		input.Append('x', 5000);
		input.Append("--><!DOCTYPE r [<!ENTITY e \"<c/>text\">]><r>&e;");
		input.Append('t', 1500);
		input.Append("</r>");
		var config = XmlReadConfig();
		config.MaxTokenBytes = 6000;
		ReadAllWays(input, config, scope (result, doc) =>
			{
				Test.Assert(result case .Ok);
				Test.Assert(doc.Root.LastChild.Value.Length == 1504);
			});
	}

	[Test]
	public static void R06_AmplificationSameEveryWay()
	{
		// 11,100 bytes expanded from about 200 read, then 100,000 bytes of comment that must not dilute it
		let input = scope String("<!DOCTYPE r [<!ENTITY e0 \"");
		input.Append('a', 100);
		input.Append("\"><!ENTITY e1 \"&e0;&e0;&e0;&e0;&e0;&e0;&e0;&e0;&e0;&e0;\"><!ENTITY e2 \"&e1;&e1;&e1;&e1;&e1;&e1;&e1;&e1;&e1;&e1;\">]><r>&e2;</r><!--");
		input.Append('t', 100000);
		input.Append("-->");
		var config = XmlReadConfig();
		config.EntityAmplificationThreshold = 0;
		ReadAllWays(input, config, scope (result, doc) => ExpectKind(result, .ResourceLimitExceeded));
		// Under the ratio: accepted every way
		config.MaxEntityAmplification = 100;
		ReadAllWays(input, config, scope (result, doc) => Test.Assert(result case .Ok));
	}

	[Test]
	public static void R07_TokenLimitWithFallback()
	{
		let input = scope String("<r><!--");
		input.Append('x', 1000);
		input.Append("--></r>");
		var config = XmlReadConfig();
		config.StreamBufferBytes = 16;
		config.MaxTextBytes = 0;
		config.MaxTokenBytes = 100;
		let doc = scope XmlDocument();
		ExpectKind(doc.Read(scope XmlStreamTests.TrickleStream(input, 13), config), .ResourceLimitExceeded);
		config.EncodingFallback = .Windows1252;
		ExpectKind(doc.Read(scope XmlStreamTests.TrickleStream(input, 13), config), .ResourceLimitExceeded);
	}

	[Test]
	public static void R08_NamespaceNamesInEveryProduction()
	{
		StringView[?] inputs = .(
			"<!DOCTYPE r [<!ELEMENT r (a:b:c)>]><r/>",
			"<!DOCTYPE r [<!ATTLIST r n NOTATION (a:b) #IMPLIED>]><r/>",
			"<!DOCTYPE r SYSTEM \"unused\"><r>&a:b;</r>",
			"<!DOCTYPE r SYSTEM \"unused\"><r x='&a:b;'/>",
			"<!DOCTYPE r [<!ENTITY e 'v&a:b;'>]><r/>"
		);
		var noNamespaces = XmlReadConfig();
		noNamespaces.Namespaces = false;
		for (let input in inputs)
		{
			let doc = scope XmlDocument();
			ExpectKind(doc.Read(input), .InvalidQName);
			Test.Assert(doc.Read(input, noNamespaces) case .Ok);
		}
		// Qualified names in a content model are fine
		Test.Assert(scope XmlDocument().Read("<!DOCTYPE r [<!ELEMENT r (p:a|q:b)*>]><r/>") case .Ok);
	}

	[Test]
	public static void R09_DtdValuesSurviveMutations()
	{
		// Renamed: the default stays, written
		let doc = scope XmlDocument();
		Test.Assert(doc.Read("<!DOCTYPE r [<!ATTLIST r a CDATA 'default'>]><r/>") case .Ok);
		doc.Root.Rename("s");
		let again = scope XmlDocument();
		ReadBack(doc, again);
		Test.Assert(again.Root.GetAttribute("a") == "default");
		// The DOCTYPE removed: the default stays
		Test.Assert(doc.Read("<!DOCTYPE r [<!ATTLIST r a CDATA 'default'>]><r/>") case .Ok);
		doc.DocType.Remove();
		ReadBack(doc, again);
		Test.Assert(again.Root.GetAttribute("a") == "default");
		// PreserveStyle: text and values that came from its entities are written expanded
		var config = XmlReadConfig();
		config.MetadataMode = .PreserveStyle;
		Test.Assert(doc.Read("<!DOCTYPE r [<!ENTITY e 'text'><!ENTITY f '<b/>'>]><r v='&e;'>a &e; b&f;</r>", config) case .Ok);
		doc.DocType.Remove();
		Test.Assert(doc.Write(.. scope String()) == "<r v='text'>a text b<b/></r>");
		ReadBack(doc, again);
		Test.Assert(again.Root.GetAttribute("v") == "text" && again.Root.FirstChild.Value == "a text b");
		// References to empty entities, which produced no node, go with it
		Test.Assert(doc.Read("<!DOCTYPE r [<!ENTITY e ''>]><r>&e;<a/>&e;<b>&e;</b>&e;</r>", config) case .Ok);
		doc.DocType.Remove();
		Test.Assert(doc.Write(.. scope String()) == "<r><a/><b></b></r>");
	}

	[Test]
	public static void R11_NamespacesCheckedBeforeWriting()
	{
		let doc = scope XmlDocument();
		let bytes = scope List<uint8>();
		Test.Assert(doc.Read("<r/>") case .Ok);
		doc.Root.SetAttribute("p:a", "v");
		ExpectKind(doc.WriteBytes(bytes), .UnboundPrefix);
		// Declared afterwards: fine
		doc.Root.SetAttribute("xmlns:p", "urn:p");
		Test.Assert(doc.WriteBytes(bytes) case .Ok);
		// Two prefixes for one namespace and one local name
		Test.Assert(doc.Read("<r xmlns:p='urn:x' xmlns:q='urn:x' p:a='1'/>") case .Ok);
		doc.Root.SetAttribute("q:a", "2");
		ExpectKind(doc.CheckNamespaces(), .DuplicateAttribute);
		// Reserved bindings
		Test.Assert(doc.Read("<r/>") case .Ok);
		doc.Root.SetAttribute("xmlns:p", XmlNameTable.XmlNamespaceUri);
		ExpectKind(doc.CheckNamespaces(), .InvalidNamespaceDeclaration);
		// An element moved out of its declaration's scope
		Test.Assert(doc.Read("<r><s xmlns:p='urn:p'><p:t/></s></r>") case .Ok);
		Test.Assert(doc.Root.FirstChild.FirstChild.MoveInto(doc.Root));
		ExpectKind(doc.CheckNamespaces(), .UnboundPrefix);
	}

	[Test]
	public static void R13_StrictClaimsKeepNamespaces()
	{
		// Another namespace with the same local name is not the field's
		ExpectKind(XmlSerializer.Read("<r xmlns:p='urn:other' p:a='x'/>", scope ReviewStrictModel()), .UnexpectedContent);
		// Two namespaces, two fields, no collision
		let model = scope ReviewStrictModel();
		Test.Assert(XmlSerializer.Read("<r xmlns:p='urn:expected' xmlns:q='urn:second' p:a='1' q:a='2'/>", model) case .Ok);
		Test.Assert(model.value == "1" && model.second == "2");
	}

	[Test]
	public static void R14_ViewsFollowTheirAttributeOrFail()
	{
		let doc = scope XmlDocument();
		Test.Assert(doc.Read("<r a='1' b='2'/>") case .Ok);
		let a = doc.Root.Attributes[0];
		let b = doc.Root.Attributes[1];
		doc.Root.RemoveAttribute("a");
		Test.Assert(!a.IsValid);
		Test.Assert(b.IsValid && b.Name == "b" && b.Value == "2");
		// Moved with the element's attributes
		doc.Root.SetAttribute("c", "3");
		Test.Assert(b.Value == "2");
		// Gone after a read
		Test.Assert(doc.Read("<r other='3'/>") case .Ok);
		Test.Assert(!b.IsValid);
		// A document node handle from before a Clear is stale; a new one is not
		let saved = doc.DocumentNode;
		doc.Clear();
		Test.Assert(!saved.IsValid && doc.DocumentNode.IsValid);
	}

	[Test]
	public static void P01_ManyPrefixedAttributes()
	{
		let input = scope String("<r xmlns:p='urn:p' xmlns:q='urn:p'");
		for (int i < 40)
			input.AppendF(" p:a{}='{}'", i, i);
		input.Append(" q:a39='late'/>");
		ExpectKind(scope XmlDocument().Read(input), .DuplicateAttribute);
		input.Replace(" q:a39='late'", " q:b='fine'");
		Test.Assert(scope XmlDocument().Read(input) case .Ok);
	}

	[Test]
	public static void P03_TextLimitWhileDecoding()
	{
		let input = scope String("<r>");
		for (int i < 1000)
			input.Append("&amp;");
		input.Append("</r>");
		var config = XmlReadConfig();
		config.MaxTextBytes = 16;
		ReadAllWays(input, config, scope (result, doc) => ExpectKind(result, .ResourceLimitExceeded));
	}
	static XmlReadConfig Streamed(int buffer = 16)
	{
		var config = XmlReadConfig();
		config.StreamBufferBytes = buffer;
		return config;
	}

	/// The document read back from what `doc` writes.
	static void ReadBack(XmlDocument doc, XmlDocument again, int line = Compiler.CallerLineNum)
	{
		let written = doc.Write(.. scope String());
		if (again.Read(written) case .Err(let error))
			Test.FatalError(scope $"line {line}: `{written}` was rejected: {error}");
	}

	[Test]
	public static void R01_PublicIdentifiersSurviveRefills()
	{
		// The public literal must not be a view kept while the system literal moves the buffer
		for (int buffer in int[](16, 64, 65536))
		{
			let input = scope String("<!--");
			input.Append('z', 123);
			input.Append("--><!DOCTYPE r PUBLIC \"DOC_PUBLIC\"");
			input.Append(' ', 300);
			input.Append("\"doc.dtd\" [<!NOTATION n PUBLIC \"PUBLIC_IDENTIFIER\" \"");
			input.Append('s', 200);
			input.Append("\"><!ENTITY e PUBLIC \"ENTITY_PUBLIC\" \"");
			input.Append('e', 200);
			input.Append("\">]><r/>");
			let doc = scope XmlDocument();
			Test.Assert(doc.Read(scope XmlStreamTests.TrickleStream(input, 7), Streamed(buffer)) case .Ok);
			Test.Assert(doc.PublicId == "DOC_PUBLIC" && doc.SystemId == "doc.dtd");
			Test.Assert(doc.Notations.Length == 1 && doc.Notations[0].mPublicId == "PUBLIC_IDENTIFIER");
			Test.Assert(doc.Notations[0].mSystemId.Length == 200 && doc.Notations[0].mSystemId[0] == 's');
		}
	}

	[Test]
	public static void R02_DictionaryEntryWithoutValue()
	{
		// Removed when its key is gone
		let doc = scope XmlDocument();
		Test.Assert(doc.Read("<r><entry><key>a</key></entry></r>") case .Ok);
		let writer = scope XmlMapWriter(doc.Root, .KeyValueElements, "entry", "key", "value", "", default);
		writer.Finish();
		Test.Assert(doc.Write(.. scope String()) == "<r/>\n");
		// Completed when its key is written
		Test.Assert(doc.Read("<r><entry><key>a</key></entry><entry><key>a</key><value>1</value></entry></r>") case .Ok);
		let completing = scope XmlMapWriter(doc.Root, .KeyValueElements, "entry", "key", "value", "", default);
		Test.Assert(completing.SetScalar("a", "", "2") case .Ok);
		completing.Finish();
		Test.Assert(doc.Write(.. scope String()) == "<r><entry><key>a</key><value>2</value></entry></r>\n");
	}

	[Test]
	public static void R03_TextAcrossNodesNeverWritesCDataEnd()
	{
		StringView[3][?] splits = .(
			.("]]", ">", ""),
			.("]", "]>", ""),
			.("]", "]", ">")
		);
		for (let split in splits)
		{
			let doc = scope XmlDocument();
			Test.Assert(doc.Read("<r/>") case .Ok);
			for (let piece in split)
			{
				if (!piece.IsEmpty)
					doc.Root.AddText(piece);
			}
			let again = scope XmlDocument();
			ReadBack(doc, again);
			Test.Assert(again.Root.Text == "]]>");
		}
		// After source a PreserveStyle document kept
		var config = XmlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let preserved = scope XmlDocument();
		Test.Assert(preserved.Read("<r>a]]<b/></r>", config) case .Ok);
		preserved.Root.LastChild.Remove();
		preserved.Root.AddText(">");
		let again = scope XmlDocument();
		ReadBack(preserved, again);
		Test.Assert(again.Root.Text == "a]]>");
	}

	[Test]
	public static void R10_CarriageReturnsInCData()
	{
		StringView[?] values = .("\r", "a\r\nb", "\r\r", "]]>\r", "\r]]>");
		for (let value in values)
		{
			let doc = scope XmlDocument();
			Test.Assert(doc.Read("<r/>") case .Ok);
			doc.Root.AddCData(value);
			let again = scope XmlDocument();
			ReadBack(doc, again);
			let text = scope String();
			again.Root.AppendText(text);
			Test.Assert(text == value);
		}
		// From parsed input: a CR from a character reference in an entity, rewritten
		let doc = scope XmlDocument();
		Test.Assert(doc.Read("<!DOCTYPE r [<!ENTITY e \"<![CDATA[&#13;]]>\">]><r>&e;</r>") case .Ok);
		let again = scope XmlDocument();
		ReadBack(doc, again);
		Test.Assert(again.Root.Text == "\r");
	}

	[Test]
	public static void R12_TheXmlNamespaceUsesItsPrefix()
	{
		let doc = scope XmlDocument();
		Test.Assert(doc.Read("<r><c/></r>") case .Ok);
		XmlBind.SetAttribute(doc.Root, "lang", XmlNameTable.XmlNamespaceUri, "en");
		XmlBind.SetAttribute(doc.Root.FirstChild, "space", XmlNameTable.XmlNamespaceUri, "preserve");
		Test.Assert(doc.Write(.. scope String()) == "<r xml:lang=\"en\"><c xml:space=\"preserve\"/></r>\n");
		let again = scope XmlDocument();
		ReadBack(doc, again);
		Test.Assert(again.Root.TryGetAttribute(XmlNameTable.XmlNamespaceUri, "lang", let lang) && lang == "en");
	}
}
